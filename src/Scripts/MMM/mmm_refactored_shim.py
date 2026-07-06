"""
mmm_refactored_shim.py
======================

Drop-in replacement for the C++ ``mmm_refactored`` extension that routes
inference through the pure-Python ``midigpt_refactor`` library.

Exposes the same three symbols MMM_server.py uses:

  * ``ElVelocityDurationPolyphonyYellowEncoder`` — class with
    ``.midi_to_json(path)`` and ``.json_to_midi(piece_json, out_path)``.
  * ``sample_multi_step(piece_json, status_json, param_json)`` — runs
    inference and returns a result-piece JSON string.

Implementation note
-------------------
The C++ ``piece_json`` schema is large and proprietary to the C++ encoder.
This shim sidesteps reimplementing it: ``midi_to_json`` returns a tiny JSON
wrapper that carries a MIDI file path, and ``sample_multi_step`` reads the
MIDI directly via ``Score.from_midi``.  ``json_to_midi`` simply copies the
result MIDI to the server's requested output path.

Activate by setting ``MMM_BACKEND=refactor`` before starting MMM_server.py.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile

log = logging.getLogger("mmm_refactored_shim")
# Honor MMM_REFACTOR_DEBUG=1 to crank verbosity (token-level inside engine too).
if os.environ.get("MMM_REFACTOR_DEBUG", "").lower() in ("1", "true", "yes"):
    logging.basicConfig(level=logging.DEBUG,
                        format="[%(name)s] %(levelname)s %(message)s")
    log.setLevel(logging.DEBUG)
    # Also crank the engine's own debug (silence_check / novelty_check decisions)
    # and the C++ core verbosity (grammar constraints, step planner).
    logging.getLogger("midigpt_refactor.inference.session").setLevel(logging.DEBUG)
    try:
        _core.set_verbosity(_core.LogLevel.DEBUG)
    except Exception:
        pass

from midigpt_refactor._types import Score
from midigpt_refactor.inference.engine import InferenceEngine
from midigpt_refactor.inference.config import (
    GenerationRequest, TrackPrompt, SamplingConfig,
)
from midigpt_refactor.attributes.base import AttributeAnalyzer
from midigpt_refactor.tokenizer.tokenizer import Tokenizer
import midigpt_refactor._core as _core


# ---------------------------------------------------------------------------
# Engine cache.  Key = (checkpoint_path, encoder_config_path) so we can hold
# multiple engines if needed.
# ---------------------------------------------------------------------------

_ENGINE_CACHE: dict[tuple[str, str], InferenceEngine] = {}


def _build_engine(model_path: str, encoder_config_path: str) -> InferenceEngine:
    """Build an InferenceEngine from explicit paths.

    midigpt_refactor's default `from_checkpoint(dir)` expects a directory
    containing both `model.pt` and `config.json`.  Reaper's `model_config.json`
    serves a different purpose (server settings, ac_schema, …), so we side-step
    that convention and load the encoder config directly from the path
    declared in MODEL_CONFIG['refactor_encoder_config'].

    Mirrors run_generation.py's setup so we know we're invoking the engine
    the same way the reference script does.
    """
    import torch
    encoder_config = _core.EncoderConfig.from_json(
        open(encoder_config_path).read())
    model     = torch.jit.load(model_path, map_location="cpu")
    model.eval()
    tokenizer = Tokenizer(encoder_config)
    engine    = InferenceEngine(model, tokenizer, None)
    # Stash the resolution so callers can read MIDI with the matching tick rate
    # (reference: `_core.MidiReader(config.resolution).read(path)`).
    engine._encoder_resolution = encoder_config.resolution  # type: ignore[attr-defined]
    engine.warmup()
    return engine


def _get_engine(model_path: str, encoder_config_path: str) -> InferenceEngine:
    key = (model_path, encoder_config_path)
    if key not in _ENGINE_CACHE:
        _ENGINE_CACHE[key] = _build_engine(model_path, encoder_config_path)
    return _ENGINE_CACHE[key]


# ---------------------------------------------------------------------------
# Encoder shim
# ---------------------------------------------------------------------------

def _score_to_piece_signatures(score: Score) -> list[dict]:
    """Emit a `piece["tracks"]` list with the minimal fields MMM_server.py reads:
    `trackType`, `instrument`, and a `bars` list with the correct length."""
    tracks = []
    for t in score.tracks:
        tracks.append({
            "trackType":  "STANDARD_DRUM_TRACK" if t.track_type == "drum"
                          else "STANDARD_TRACK",
            "instrument": t.instrument,
            # MMM_server.py only uses `len(bars)` here, so empty dicts are fine.
            "bars":       [{} for _ in t.bars],
        })
    return tracks


class ElVelocityDurationPolyphonyYellowEncoder:
    """Passthrough encoder.

    ``piece_json`` wraps a stable MIDI path plus a minimal track-signature list
    so ``MMM_server.py`` can run its bar-count / track-mapping logic without
    needing the full C++ piece schema.  ``sample_multi_step`` reloads the MIDI
    from the wrapped path.
    """

    def midi_to_json(self, midi_path: str) -> str:
        # MMM_server.py unlinks its temp MIDI right after this call returns
        # (server.py:650), so we copy to a stable path the shim controls.
        fd, stable = tempfile.mkstemp(prefix="mmm_refactor_input_", suffix=".mid")
        os.close(fd)
        shutil.copyfile(midi_path, stable)
        score = Score.from_midi(stable)
        return json.dumps({
            "midi_path": stable,
            "tracks":    _score_to_piece_signatures(score),
        })

    def json_to_midi(self, piece_json: str, out_path: str) -> None:
        d = json.loads(piece_json)
        midi_path = d.get("midi_path")
        if not midi_path:
            raise ValueError(
                "mmm_refactored_shim.json_to_midi: expected piece_json with"
                " {midi_path: ...} (got keys: %s)" % list(d.keys()))
        shutil.copyfile(midi_path, out_path)


# ---------------------------------------------------------------------------
# status_json → GenerationRequest
# ---------------------------------------------------------------------------

# Map C++ StatusTrack attribute names → midigpt_refactor TrackPrompt keys.
_ATTR_MAP = {
    "polyphony_hard_limit": "onset_polyphony",
    "min_polyphony_q":      "min_polyphony",
    "max_polyphony_q":      "max_polyphony",
    "min_note_duration_q":  "min_note_duration",
    "max_note_duration_q":  "max_note_duration",
    "density":              "note_density",
}


def _build_request(status: dict, param: dict) -> GenerationRequest:
    track_prompts: list[TrackPrompt] = []
    for st in status.get("tracks", []):
        selected = st.get("selected_bars", [])
        bar_idxs = [i for i, sel in enumerate(selected) if sel]
        is_ar    = bool(st.get("autoregressive", False))
        is_ign   = bool(st.get("ignore", False))

        attrs: dict[str, int] = {}
        # Only attach attributes to tracks that are actually generating.
        # StatusTrack convention (matches original MIDI-GPT multi_step_sample.h
        # and control.h): for bucketed attributes, request value 0 = "any" (skip),
        # value >= 1 = explicit with actual token value being (value - 1).
        # polyphony_hard_limit is a direct concurrent-note count, not bucketed.
        _DIRECT_KEYS = {"polyphony_hard_limit"}
        if (is_ar or bar_idxs) and not is_ign:
            for src_key, dst_key in _ATTR_MAP.items():
                v = int(st.get(src_key, 0) or 0)
                if v:
                    attrs[dst_key] = v if src_key in _DIRECT_KEYS else v - 1

        track_prompts.append(TrackPrompt(
            id             = int(st["track_id"]),
            bars           = bar_idxs,
            autoregressive = is_ar,
            ignore         = is_ign,
            attributes     = attrs,
        ))

    cfg = SamplingConfig(
        temperature     = float(param.get("temperature", 1.0)),
        seed            = int(param.get("sampling_seed", -1)),
        model_dim       = int(param.get("model_dim", 4)),
        bars_per_step   = int(param.get("bars_per_step", 1)),
        tracks_per_step = int(param.get("tracks_per_step", 1)),
        shuffle         = bool(param.get("shuffle", False)),
        max_attempts    = 3,
    )
    return GenerationRequest(tracks=track_prompts, config=cfg)


def _resolve_model_path(ckpt: str) -> str:
    """The HyperParam.ckpt is a path to model.pt (refactor_ckpt from
    MODEL_CONFIG when MMM_BACKEND=refactor).  Accept either a model.pt path or
    a directory containing model.pt."""
    if not ckpt:
        raise ValueError("HyperParam.ckpt is empty — cannot load model")
    ckpt = os.path.expanduser(ckpt)
    if os.path.isdir(ckpt):
        return os.path.join(ckpt, "model.pt")
    return ckpt


def _resolve_encoder_config_path(param: dict, model_path: str) -> str:
    """Find the midigpt_refactor encoder config (token domains, time
    signatures, etc.).  Priority:
      1. `refactor_encoder_config` in HyperParam (injected by MMM_server.py)
      2. `encoder_config.json` next to the model checkpoint
      3. `config.json` next to the model checkpoint (legacy)
    """
    explicit = param.get("refactor_encoder_config", "")
    if explicit:
        explicit = os.path.expanduser(explicit)
        if os.path.exists(explicit):
            return explicit
    model_dir = os.path.dirname(model_path)
    for name in ("encoder_config.json", "config.json"):
        p = os.path.join(model_dir, name)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(
        "midigpt_refactor encoder config not found.  Set "
        "`refactor_encoder_config` in models/config.json or drop an "
        "encoder_config.json next to the model checkpoint.")


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def _decode_token(vocab, tok: int) -> str:
    """Render a token id as `<TokenType>:<value>` (best-effort)."""
    try:
        ttype = vocab.get_type(tok)
        ttype_name = getattr(ttype, "name", str(ttype))
    except Exception:
        ttype_name = "?"
    try:
        val = vocab.decode(tok)
    except Exception:
        val = "?"
    return f"{ttype_name}({val})[{tok}]"


def _patch_session_token_trace(session) -> None:
    """Install per-token logging by wrapping `_core.SessionState`.

    Each generated token is logged with its decoded TokenType + value.
    Context tokens are dumped once at session-state construction.
    The wrapper proxies all other attributes through to the real C++ object.
    """
    vocab = session._engine._tokenizer._vocab
    if getattr(_core, "_mmm_traced_state_installed", False):
        return  # already wrapped

    orig_state_cls = _core.SessionState
    MAX_CTX_DUMP = 256

    class _TracedSessionState:
        def __init__(self, *args, **kwargs):
            self._s = orig_state_cls(*args, **kwargs)
            ctx = list(self._s.context_tokens())
            log.debug("SessionState built: context_tokens=%d", len(ctx))
            head = ctx[:MAX_CTX_DUMP]
            for i, t in enumerate(head):
                log.debug("  ctx[%4d] %s", i, _decode_token(vocab, t))
            if len(ctx) > MAX_CTX_DUMP:
                log.debug("  ... %d more context tokens elided", len(ctx) - MAX_CTX_DUMP)

        def advance(self, tok):
            log.debug("  gen   -> %s", _decode_token(vocab, tok))
            return self._s.advance(tok)

        def __getattr__(self, name):
            return getattr(self._s, name)

    _core.SessionState = _TracedSessionState
    _core._mmm_traced_state_installed = True
    log.debug("token-trace installed (wrapping _core.SessionState)")


def sample_multi_step(piece_json: str, status_json: str, param_json: str) -> str:
    piece  = json.loads(piece_json)
    status = json.loads(status_json)
    param  = json.loads(param_json)

    midi_path = piece.get("midi_path")
    if not midi_path:
        raise ValueError(
            "mmm_refactored_shim.sample_multi_step: piece_json must wrap"
            " {midi_path: ...} (produced by the shim's midi_to_json)")

    model_path  = _resolve_model_path(param.get("ckpt", ""))
    enc_cfg     = _resolve_encoder_config_path(param, model_path)
    engine      = _get_engine(model_path, enc_cfg)

    # Read MIDI with the resolution the tokenizer was built for, matching
    # run_generation.py: `from_cpp(_core.MidiReader(config.resolution).read(p))`.
    from midigpt_refactor._converters import from_cpp
    score = from_cpp(_core.MidiReader(engine._encoder_resolution).read(midi_path))
    try: os.unlink(midi_path)
    except OSError: pass

    request  = _build_request(status, param)

    if log.isEnabledFor(logging.DEBUG):
        log.debug("=== sample_multi_step ===")
        log.debug("model_path=%s", model_path)
        log.debug("encoder_config=%s  resolution=%s",
                  enc_cfg, engine._encoder_resolution)
        log.debug("score: %d tracks, bars=%s",
                  len(score.tracks),
                  [len(t.bars) for t in score.tracks])
        log.debug("status_json=%s", json.dumps(status, indent=2))
        log.debug("param_json (sampling)=%s",
                  {k: param.get(k) for k in
                   ("temperature","model_dim","bars_per_step",
                    "tracks_per_step","sampling_seed","shuffle")})
        for tp in request.tracks:
            log.debug("  TrackPrompt id=%d bars=%s autoregressive=%s "
                      "ignore=%s attrs=%s",
                      tp.id, tp.bars, tp.autoregressive, tp.ignore,
                      tp.attributes)

    session = engine.session(score, request)
    if log.isEnabledFor(logging.DEBUG):
        session.enable_profiling = True
        _patch_session_token_trace(session)
    result = session.run()

    if log.isEnabledFor(logging.DEBUG):
        log.debug("result: %d tracks, notes-per-track=%s",
                  len(result.tracks),
                  [sum(len(b.notes) for b in t.bars) for t in result.tracks])
        log.debug("timing: encode=%.3fs forward=%.3fs decode=%.3fs tokens=%d",
                  session.encode_time, session.model_forward_time,
                  session.decode_time, session.gen_count)

    fd, out_path = tempfile.mkstemp(prefix="mmm_refactor_result_", suffix=".mid")
    os.close(fd)
    result.to_midi(out_path)
    return json.dumps({"midi_path": out_path})
