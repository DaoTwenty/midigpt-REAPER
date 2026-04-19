"""
MMM_server.py  --  Async job-queue inference server using mmm_refactored

Uses the mmm_refactored C++ extension for inference via sample_multi_step().
Model checkpoint is set via model_config.json at startup.
No runtime model switching.
"""

import os
import sys
import uuid
import threading
import time
import json
import tempfile
import traceback
from collections import defaultdict, deque
from xmlrpc.server import SimpleXMLRPCServer

from symusic import Score, Track, Note, Tempo, TimeSignature
import mmm_refactored


# ---------------------------------------------------------------------------
# Server config
# ---------------------------------------------------------------------------

PORT        = 3456
DEBUG       = True
MAX_WORKERS = 1

MODEL_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "models", "config.json")

# Debug: save intermediate MIDI/JSON files for inspection.
# Set to a directory path to enable, or None to disable.
DEBUG_DUMP_DIR = None

# ---------------------------------------------------------------------------
# Model globals
# ---------------------------------------------------------------------------

ENCODER: mmm_refactored.ElVelocityDurationPolyphonyYellowEncoder = None
CKPT_PATH:   str  = None
MODEL_READY        = False
MODEL_LABEL: str  = ""
MODEL_CONFIG: dict = {}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(msg: str):
    if DEBUG:
        print(f"[MMM-server] {msg}", flush=True)


# ---------------------------------------------------------------------------
# GM instrument mapping  (MIDI program 0-127 → midigpt GM_TYPE string)
# ---------------------------------------------------------------------------

GM_PROGRAM_TO_TYPE = [
    'acoustic_grand_piano', 'bright_acoustic_piano', 'electric_grand_piano',
    'honky_tonk_piano', 'electric_piano_1', 'electric_piano_2', 'harpsichord',
    'clavi', 'celesta', 'glockenspiel', 'music_box', 'vibraphone', 'marimba',
    'xylophone', 'tubular_bells', 'dulcimer', 'drawbar_organ',
    'percussive_organ', 'rock_organ', 'church_organ', 'reed_organ',
    'accordion', 'harmonica', 'tango_accordion', 'acoustic_guitar_nylon',
    'acoustic_guitar_steel', 'electric_guitar_jazz', 'electric_guitar_clean',
    'electric_guitar_muted', 'overdriven_guitar', 'distortion_guitar',
    'guitar_harmonics', 'acoustic_bass', 'electric_bass_finger',
    'electric_bass_pick', 'fretless_bass', 'slap_bass_1', 'slap_bass_2',
    'synth_bass_1', 'synth_bass_2', 'violin', 'viola', 'cello', 'contrabass',
    'tremolo_strings', 'pizzicato_strings', 'orchestral_harp', 'timpani',
    'string_ensemble_1', 'string_ensemble_2', 'synth_strings_1',
    'synth_strings_2', 'choir_aahs', 'voice_oohs', 'synth_voice',
    'orchestra_hit', 'trumpet', 'trombone', 'tuba', 'muted_trumpet',
    'french_horn', 'brass_section', 'synth_brass_1', 'synth_brass_2',
    'soprano_sax', 'alto_sax', 'tenor_sax', 'baritone_sax', 'oboe',
    'english_horn', 'bassoon', 'clarinet', 'piccolo', 'flute', 'recorder',
    'pan_flute', 'blown_bottle', 'shakuhachi', 'whistle', 'ocarina',
    'lead_1_square', 'lead_2_sawtooth', 'lead_3_calliope', 'lead_4_chiff',
    'lead_5_charang', 'lead_6_voice', 'lead_7_fifths', 'lead_8_bass__lead',
    'pad_1_new_age', 'pad_2_warm', 'pad_3_polysynth', 'pad_4_choir',
    'pad_5_bowed', 'pad_6_metallic', 'pad_7_halo', 'pad_8_sweep',
    'fx_1_rain', 'fx_2_soundtrack', 'fx_3_crystal', 'fx_4_atmosphere',
    'fx_5_brightness', 'fx_6_goblins', 'fx_7_echoes', 'fx_8_sci_fi',
    'sitar', 'banjo', 'shamisen', 'koto', 'kalimba', 'bag_pipe', 'fiddle',
    'shanai', 'tinkle_bell', 'agogo', 'steel_drums', 'woodblock',
    'taiko_drum', 'melodic_tom', 'synth_drum', 'reverse_cymbal',
    'guitar_fret_noise', 'breath_noise', 'seashore', 'bird_tweet',
    'telephone_ring', 'helicopter', 'applause', 'gunshot',
]


def _gm_program_to_type(program: int, is_drum: bool) -> str:
    """Convert MIDI program number to GM_TYPE string name."""
    if is_drum:
        return 'drums'
    if 0 <= program < len(GM_PROGRAM_TO_TYPE):
        return GM_PROGRAM_TO_TYPE[program]
    return 'acoustic_grand_piano'


# ---------------------------------------------------------------------------
# model_config.json
# ---------------------------------------------------------------------------

def _load_model_config() -> dict:
    with open(MODEL_CONFIG_PATH, "r") as f:
        return json.load(f)


def initialize_model(model_config_path: str = None) -> bool:
    global ENCODER, CKPT_PATH, MODEL_READY, MODEL_LABEL, MODEL_CONFIG
    global MODEL_CONFIG_PATH

    if model_config_path:
        MODEL_CONFIG_PATH = model_config_path

    try:
        cfg = _load_model_config()

        ckpt = cfg["ckpt"]
        # Resolve relative paths against config file directory
        base_dir = os.path.dirname(os.path.abspath(MODEL_CONFIG_PATH))
        if not os.path.isabs(ckpt):
            ckpt = os.path.join(base_dir, ckpt)

        CKPT_PATH    = ckpt
        MODEL_LABEL  = cfg.get("label", "MIDI-GPT")
        MODEL_CONFIG = cfg

        _log(f"Model  : {MODEL_LABEL}")
        _log(f"Ckpt   : {CKPT_PATH}")

        if not os.path.exists(CKPT_PATH):
            raise FileNotFoundError(
                f"Model checkpoint not found: {CKPT_PATH}. "
                "Set the correct path in src/Scripts/MMM/models/config.json "
                "or place model.pt next to that config file."
            )

        ENCODER     = mmm_refactored.ElVelocityDurationPolyphonyYellowEncoder()
        MODEL_READY = True

        _log("Encoder initialized, model ready")
        return True

    except Exception as e:
        _log(f"Initialization failed: {e}")
        traceback.print_exc()
        return False


# ---------------------------------------------------------------------------
# XMLRPC: schema endpoint
# ---------------------------------------------------------------------------

def get_model_schema() -> dict:
    """Returns AC schema + track_fx_id for the active model."""
    if not MODEL_READY:
        return {"ok": False, "error": "Model not loaded"}

    return {
        "ok":          True,
        "model_id":    "mmm_refactored",
        "model_label": MODEL_LABEL,
        "track_fx_id": MODEL_CONFIG.get("track_fx_id", 0),
        "ac_schema":   MODEL_CONFIG.get("ac_schema", []),
    }


# ---------------------------------------------------------------------------
# MIDI conversion  (song_dict → symusic Score)
# ---------------------------------------------------------------------------

def midisong_dict_to_score(song_dict: dict,
                           keep_alive_tracks: set = None) -> Score:
    """Convert song_dict to symusic Score.

    keep_alive_tracks: set of REAPER track indices that MUST survive the MIDI
        roundtrip even if they have no notes (e.g. empty AR tracks).  A silent
        placeholder note is added so the encoder doesn't drop them.
    """
    TPQ   = 480
    score = Score(TPQ, ttype="tick")
    if keep_alive_tracks is None:
        keep_alive_tracks = set()

    track_info_list = song_dict.get("track_info", [])
    all_measures    = song_dict.get("measures", [])

    origin_secs = None
    for track_measures in all_measures:
        for m in track_measures:
            if m is None:
                continue
            t = float(m["start_time"])
            if origin_secs is None or t < origin_secs:
                origin_secs = t
    if origin_secs is None:
        origin_secs = 0.0

    _log(f"midisong_dict_to_score: origin = {origin_secs:.3f}s")

    def _secs_to_ticks(secs: float, bpm: float) -> int:
        return int(round(secs * (bpm / 60.0) * TPQ))

    tempo_at_tick:   dict = {}
    timesig_at_tick: dict = {}

    for track_measures in all_measures:
        for m in track_measures:
            if m is None:
                continue
            bpm        = float(m.get("tempo", 120.0) or 120.0)
            ts         = m.get("time_signature", (4, 4))
            if isinstance(ts, (list, tuple)) and len(ts) >= 2:
                num = int(round(float(ts[0])))
                denom = int(round(float(ts[1])))
            else:
                num, denom = 4, 4
            if num <= 0:
                num = 4
            if denom <= 0:
                denom = 4
            rel_tick   = _secs_to_ticks(float(m["start_time"]) - origin_secs, bpm)
            tempo_at_tick.setdefault(rel_tick, bpm)
            timesig_at_tick.setdefault(rel_tick, (num, denom))

    tempo_at_tick.setdefault(0, 120.0)
    timesig_at_tick.setdefault(0, (4, 4))

    for tick in sorted(tempo_at_tick):
        score.tempos.append(Tempo(time=tick, qpm=tempo_at_tick[tick]))
    for tick in sorted(timesig_at_tick):
        num, denom = timesig_at_tick[tick]
        score.time_signatures.append(
            TimeSignature(time=int(tick), numerator=int(num), denominator=int(denom)))

    for track_idx, track_measures in enumerate(all_measures):
        info       = track_info_list[track_idx] if track_idx < len(track_info_list) else {}
        instrument = int(info.get("instrument", 0))
        is_drum    = (instrument == 128)

        symusic_track = Track(
            program = 0 if is_drum else instrument,
            is_drum = is_drum,
            name    = info.get("track_name", f"Track {track_idx}"),
        )

        for measure in track_measures:
            if measure is None:
                continue
            bpm              = float(measure.get("tempo", 120.0) or 120.0)
            measure_abs_tick = _secs_to_ticks(float(measure["start_time"]) - origin_secs, bpm)
            for note_dict in measure.get("notes", []):
                start_tick    = measure_abs_tick + _secs_to_ticks(float(note_dict["start_time"]), bpm)
                end_tick      = measure_abs_tick + _secs_to_ticks(float(note_dict["end_time"]), bpm)
                symusic_track.notes.append(Note(
                    time=start_tick, duration=max(1, end_tick - start_tick),
                    pitch=int(note_dict["pitch"]), velocity=int(note_dict["velocity"]),
                ))

        # If this track is empty but must survive the MIDI roundtrip
        # (e.g. empty AR track), add a silent placeholder note so the
        # encoder doesn't drop it.  Velocity=1 at tick 0, duration=1.
        if not symusic_track.notes and track_idx in keep_alive_tracks:
            symusic_track.notes.append(Note(
                time=0, duration=1,
                pitch=60, velocity=1,
            ))
            _log(f"  Added placeholder note for empty track {track_idx}")

        score.tracks.append(symusic_track)

    score.sort(inplace=True)
    _log(f"Score: {len(score.tracks)} tracks, "
         f"{sum(len(t.notes) for t in score.tracks)} notes")
    return score


# ---------------------------------------------------------------------------
# Result extraction  (symusic Score → result dict)
# ---------------------------------------------------------------------------

def _score_to_result_dict(score: Score, masks, start_measure, end_measure,
                          piece_to_reaper: dict) -> dict:
    """Extract notes from infilled bars, mapping Piece track indices back
    to REAPER track indices so the client can write them to the correct tracks.

    Both masks and Piece bars use RELATIVE indices (0-based from start of
    selection).  The result dict keys are also relative so that
    write_masked_result can look up measures via song.get_measure().
    """
    tpq        = score.tpq
    masked_set = {(int(t), int(b)) for t, b in masks}

    # Build bar boundary table from time signatures so non-4/4 works.
    # Each bar's tick-length = numerator / denominator * 4 * tpq.
    # Time signatures are sorted by time; we walk through bars.
    ts_list = sorted(score.time_signatures, key=lambda ts: ts.time)
    # Precompute cumulative bar start ticks.  We need enough bars to cover
    # all notes.  Start with a generous upper bound.
    max_tick = max(
        (n.time + n.duration for t in score.tracks for n in t.notes),
        default=0,
    )
    bar_starts = []   # bar_starts[i] = tick where bar i begins
    tick = 0
    ts_idx = 0
    cur_num, cur_den = (4, 4)
    if ts_list:
        cur_num, cur_den = ts_list[0].numerator, ts_list[0].denominator
    while tick <= max_tick:
        # Advance to a later time-signature if it falls at this tick
        while ts_idx < len(ts_list) and ts_list[ts_idx].time <= tick:
            cur_num = ts_list[ts_idx].numerator
            cur_den = ts_list[ts_idx].denominator
            ts_idx += 1
        bar_starts.append(tick)
        bar_len = int(round(cur_num / cur_den * 4 * tpq))
        tick += max(bar_len, 1)  # guard against degenerate 0-length
    # Sentinel so that bisect always has an upper bound
    bar_starts.append(tick)

    import bisect

    tracks_out = {}
    for piece_idx, track in enumerate(score.tracks):
        reaper_idx = piece_to_reaper.get(piece_idx)
        if reaper_idx is None:
            continue
        for note in track.notes:
            # Find which bar this note falls in
            bar_idx = bisect.bisect_right(bar_starts, note.time) - 1
            if bar_idx < 0:
                continue
            if (reaper_idx, bar_idx) not in masked_set:
                continue
            bar_start_tick = bar_starts[bar_idx]
            m_key = str(bar_idx)
            tracks_out.setdefault(str(reaper_idx), {}).setdefault(m_key, []).append({
                "pitch"        : int(note.pitch),
                "velocity"     : int(note.velocity),
                "start_tick"   : int(note.time) - bar_start_tick,
                "duration_tick": int(note.duration),
            })

    return {"start_measure": start_measure, "end_measure": end_measure,
            "tpq": tpq, "tracks": tracks_out}


# ---------------------------------------------------------------------------
# Job state
# ---------------------------------------------------------------------------

STATUS_QUEUED  = "queued"
STATUS_RUNNING = "running"
STATUS_DONE    = "done"
STATUS_ERROR   = "error"


class Job:
    def __init__(self, job_id, song_dict, infill_masks, bar_masks,
                 ignore_tracks, autoregressive_tracks, gen_config_dict,
                 per_track_acs, start_measure, end_measure):
        self.job_id                = job_id
        self.song_dict             = song_dict
        self.infill_masks          = infill_masks
        self.bar_masks             = bar_masks
        self.ignore_tracks         = ignore_tracks
        self.autoregressive_tracks = autoregressive_tracks
        self.gen_config_dict       = gen_config_dict
        self.per_track_acs         = per_track_acs
        self.start_measure         = start_measure
        self.end_measure           = end_measure

        self.status     = STATUS_QUEUED
        self.progress   = 0
        self.message    = "Waiting in queue"
        self.result     = None
        self.error      = None
        self.created_at = time.time()
        self.started_at = None
        self.ended_at   = None

    def status_dict(self) -> dict:
        return {
            "job_id"  : self.job_id,
            "status"  : self.status,
            "progress": self.progress,
            "message" : self.message,
            "error"   : self.error or "",
            "elapsed" : round(time.time() - self.created_at, 1),
        }


# ---------------------------------------------------------------------------
# Job queue + worker
# ---------------------------------------------------------------------------

_jobs:  dict  = {}
_queue: deque = deque()
_lock         = threading.Lock()


def _enqueue(job: Job):
    with _lock:
        _jobs[job.job_id] = job
        _queue.append(job)
    _log(f"Enqueued job {job.job_id}  (queue depth {len(_queue)})")


def _dequeue():
    with _lock:
        return _queue.popleft() if _queue else None


def _worker_loop():
    while True:
        job = _dequeue()
        if job is None:
            time.sleep(0.25)
            continue
        _run_job(job)


def _start_workers():
    for _ in range(MAX_WORKERS):
        threading.Thread(target=_worker_loop, daemon=True).start()
    _log(f"Started {MAX_WORKERS} worker thread(s)")


# ---------------------------------------------------------------------------
# Generation helpers
# ---------------------------------------------------------------------------

def _update(job, progress, message):
    job.progress = progress
    job.message  = message
    _log(f"Job {job.job_id} [{progress:3d}%] {message}")


def _build_status(job, track_info_list: list, num_bars: int,
                   reaper_to_piece: dict) -> dict:
    """Build MIDI-GPT Status JSON dict from job parameters.

    Rules enforced by MIDI-GPT's validate_status:
      - Every StatusTrack must have selectedBars with length >= model_dim.
      - All selectedBars arrays must have the SAME length.
      - All trackId values must be unique.
      - If autoregressive=true, ALL bars must be selected.
      - If ignore=true, NO bars may be selected (track must be CONDITION).
      - trackId must reference a valid Piece track index.

    Only REAPER tracks that survived the MIDI roundtrip (present in
    reaper_to_piece) are included in the Status.
    """
    nt = len(track_info_list)

    # Build per-track infill mask (using REAPER indices).
    # infill_masks contain ABSOLUTE measure indices from REAPER (e.g. 34, 35),
    # but the Piece has bars indexed 0..num_bars-1 relative to start_measure.
    # infill_masks use RELATIVE bar indices (0-based from start of selection),
    # matching the Piece's bar indexing.
    _log(f"  _build_status: nt={nt}, num_bars={num_bars}, "
         f"start_measure={job.start_measure}")
    _log(f"  infill_masks ({len(job.infill_masks)} entries): "
         f"{job.infill_masks[:20]}")
    infill = [[False] * num_bars for _ in range(nt)]
    mapped_count = 0
    for t, b in job.infill_masks:
        if t < nt and 0 <= b < num_bars:
            infill[t][b] = True
            mapped_count += 1
    _log(f"  Mapped {mapped_count}/{len(job.infill_masks)} mask entries")

    ignore_set = set(job.ignore_tracks)
    ar_set     = set(job.autoregressive_tracks)

    # Global AR toggle from gen_config_dict
    cfg       = dict(job.gen_config_dict)
    global_ar = bool(cfg.get("autoregressive", False))

    # Global polyphony hard limit (0 means "no limit" in JSFX)
    global_poly_limit = int(cfg.get("polyphony_hard_limit", 0))

    tracks = []
    for reaper_idx in range(nt):
        # Skip tracks that were dropped during MIDI roundtrip (empty tracks)
        if reaper_idx not in reaper_to_piece:
            continue
        piece_idx = reaper_to_piece[reaper_idx]

        info       = track_info_list[reaper_idx]
        instrument = int(info.get("instrument", 0))
        is_drum    = (instrument == 128)
        is_ignored = reaper_idx in ignore_set

        # Determine selected_bars
        if is_ignored:
            # Ignored tracks must be CONDITION: no bars selected
            selected = [False] * num_bars
            is_ar = False
        else:
            selected = list(infill[reaper_idx])
            # Autoregressive
            is_ar = reaper_idx in ar_set
            if global_ar and any(selected):
                is_ar = True
            # MIDI-GPT constraint: AR requires all bars selected
            if is_ar:
                selected = [True] * num_bars

        # Parse per-track AC overrides (keyed by REAPER index)
        acs = job.per_track_acs.get(str(reaper_idx), {})
        def _ac_int(key, default=0):
            try: return int(float(acs[key]))
            except (KeyError, ValueError, TypeError): return default
        def _ac_float(key, default=1.0):
            try: return float(acs[key])
            except (KeyError, ValueError, TypeError): return default

        trk_temp = max(0.5, min(2.0, _ac_float("temperature", 1.0)))

        # Polyphony hard limit: 0 means "disabled/no limit" in JSFX.
        # C++ treats 0 as "limit of 0 notes" (blocks all onsets).
        # Fall back: per-track → global → 100 (effectively no limit).
        trk_poly = _ac_int("polyphony_hard_limit", 0)
        if trk_poly == 0:
            trk_poly = global_poly_limit
        if trk_poly == 0:
            trk_poly = 100  # protobuf maxval, effectively unlimited

        # Build StatusTrack — all fields present with defaults.
        # track_id must reference the Piece track index, not the REAPER index.
        # YELLOW encoder controls: density (drums), polyphony_q, note_duration_q
        st = {
            "track_id"              : piece_idx,
            "track_type"            : "STANDARD_DRUM_TRACK" if is_drum else "STANDARD_TRACK",
            "instrument"            : _gm_program_to_type(instrument, is_drum),
            "selected_bars"         : selected,
            "autoregressive"        : is_ar,
            "ignore"                : is_ignored,
            "density"               : _ac_int("density", 0),
            "min_polyphony_q"       : _ac_int("min_polyphony_q", 0),
            "max_polyphony_q"       : _ac_int("max_polyphony_q", 0),
            "min_note_duration_q"   : _ac_int("min_note_duration_q", 0),
            "max_note_duration_q"   : _ac_int("max_note_duration_q", 0),
            "polyphony_hard_limit"  : trk_poly,
            "temperature"           : trk_temp,
        }

        tracks.append(st)

    return {"tracks": tracks}


def _build_param(job, *, use_per_track_temperature: bool = False) -> dict:
    """Build HyperParam JSON dict from gen_config_dict."""
    cfg = dict(job.gen_config_dict)  # copy to avoid mutating original

    # 0 means "disabled/no limit" in both JSFX and C++ (default_sample_param
    # does NOT set polyphony_hard_limit — the line is commented out).
    polyphony_limit = int(cfg.get("polyphony_hard_limit", 0))
    mask_top_k      = float(cfg.get("mask_top_k", 0))

    model_dim     = int(cfg.get("model_dim", 4))
    bars_per_step = min(int(cfg.get("bars_per_step", 1)), model_dim)

    param = {
        "ckpt"                    : CKPT_PATH,
        "model_dim"               : model_dim,
        "bars_per_step"           : bars_per_step,
        "tracks_per_step"         : int(cfg.get("tracks_per_step", 1)),
        "temperature"             : max(0.5, min(2.0, float(cfg.get("temperature", 1.0)))),
        "use_per_track_temperature": use_per_track_temperature,
        "percentage"              : 100,
        "batch_size"              : 1,
        "shuffle"                 : True,
        "verbose"                 : DEBUG,
        "max_steps"               : 0,
        "polyphony_hard_limit"    : polyphony_limit,
        "mask_top_k"              : mask_top_k,
    }

    return param


# ---------------------------------------------------------------------------
# Job runner
# ---------------------------------------------------------------------------

def _debug_dump(job_id: str, name: str, data, ext: str = ".json"):
    """Save an intermediate artifact to DEBUG_DUMP_DIR for inspection."""
    if not DEBUG_DUMP_DIR:
        return None
    os.makedirs(DEBUG_DUMP_DIR, exist_ok=True)
    short_id = job_id[:8]
    path = os.path.join(DEBUG_DUMP_DIR, f"{short_id}_{name}{ext}")
    if ext == ".mid":
        # data is a symusic Score or a file path to copy
        if isinstance(data, str):
            import shutil
            shutil.copy2(data, path)
        else:
            data.dump_midi(path)
    elif ext == ".json":
        if isinstance(data, str):
            with open(path, "w") as f:
                f.write(data)
        else:
            with open(path, "w") as f:
                json.dump(data, f, indent=2)
    _log(f"  DEBUG DUMP: {path}")
    return path


def _run_job(job: Job):
    job.status     = STATUS_RUNNING
    job.started_at = time.time()
    _update(job, 5, "Starting")

    input_path  = None
    output_path = None

    try:
        # Step 1: Convert song_dict → symusic Score → temp MIDI file.
        _update(job, 10, "Converting MIDI data")

        # Tracks that are in infill_masks or autoregressive must survive
        # the MIDI roundtrip even if empty (so the model has a slot).
        masked_tracks = {int(t) for t, b in job.infill_masks}
        ar_tracks     = set(job.autoregressive_tracks)
        keep_alive    = masked_tracks | ar_tracks

        score = midisong_dict_to_score(job.song_dict, keep_alive)

        fd, input_path = tempfile.mkstemp(suffix=".mid")
        os.close(fd)
        score.dump_midi(input_path)

        # DEBUG: Save input MIDI (what REAPER sent us, converted to MIDI)
        _debug_dump(job.job_id, "1_input", score, ".mid")

        # Step 2: Encode MIDI → Piece JSON via encoder.
        _update(job, 20, "Encoding MIDI to Piece")
        piece_json = ENCODER.midi_to_json(input_path)
        os.unlink(input_path)
        input_path = None

        # DEBUG: Save Piece JSON (what the encoder produced)
        _debug_dump(job.job_id, "2_piece", piece_json, ".json")

        # Verify bar / track counts and build track mapping.
        # The MIDI roundtrip (symusic → MIDI file → encoder parser) may drop
        # empty tracks, so Piece track indices can differ from REAPER indices.
        piece_dict = json.loads(piece_json)
        track_info = job.song_dict.get("track_info", [])
        num_bars   = (len(piece_dict["tracks"][0]["bars"])
                      if piece_dict.get("tracks") else 0)

        # Build reaper_idx → piece_idx mapping.
        piece_tracks = piece_dict.get("tracks", [])
        _log(f"Piece: {len(piece_tracks)} tracks, "
             f"{num_bars} bars (expected {job.song_dict['num_measures']})")

        # Detect which REAPER tracks are empty (no notes in any measure)
        # AND were not kept alive with a placeholder.  Those tracks were
        # dropped during the MIDI roundtrip and have no Piece track.
        all_measures = job.song_dict.get("measures", [])
        reaper_empty = set()
        for reaper_idx, track_measures in enumerate(all_measures):
            has_notes = False
            for m in track_measures:
                if m is not None and m.get("notes"):
                    has_notes = True
                    break
            if not has_notes and reaper_idx not in keep_alive:
                reaper_empty.add(reaper_idx)
                _log(f"  REAPER track {reaper_idx} is empty — skipping in mapping")

        # Build a list of (is_drum, instrument) for each Piece track
        piece_signatures = []
        for pt in piece_tracks:
            pt_type = pt.get("trackType", "STANDARD_TRACK")
            pt_drum = (pt_type == "STANDARD_DRUM_TRACK")
            pt_inst = int(pt.get("instrument", 0))
            piece_signatures.append((pt_drum, pt_inst))

        # Map REAPER track indices to Piece track indices.
        # Skip empty REAPER tracks (they were dropped from the Piece).
        reaper_to_piece = {}   # reaper_idx → piece_idx
        piece_to_reaper = {}   # piece_idx  → reaper_idx
        piece_claimed = set()

        for reaper_idx, info in enumerate(track_info):
            if reaper_idx in reaper_empty:
                continue  # no Piece track for this empty REAPER track
            instrument = int(info.get("instrument", 0))
            is_drum = (instrument == 128)
            # Find best matching unclaimed piece track
            for piece_idx, (p_drum, p_inst) in enumerate(piece_signatures):
                if piece_idx in piece_claimed:
                    continue
                if p_drum == is_drum:
                    reaper_to_piece[reaper_idx] = piece_idx
                    piece_to_reaper[piece_idx]  = reaper_idx
                    piece_claimed.add(piece_idx)
                    break

        _log(f"Track mapping (reaper→piece): {reaper_to_piece}")

        # Step 3: Build Status JSON.
        _update(job, 25, "Building generation parameters")
        status      = _build_status(job, track_info, num_bars, reaper_to_piece)
        status_json = json.dumps(status)

        # Step 4: Build HyperParam JSON.
        has_per_track_temp = any(
            "temperature" in acs
            for acs in job.per_track_acs.values())
        param      = _build_param(job, use_per_track_temperature=has_per_track_temp)
        param_json = json.dumps(param)

        _log(f"Status : {len(status['tracks'])} tracks")
        for st in status['tracks']:
            sel_count = sum(st['selected_bars'])
            _log(f"  track_id={st['track_id']} "
                 f"type={st['track_type']} "
                 f"ignore={st['ignore']} "
                 f"ar={st['autoregressive']} "
                 f"selected={sel_count}/{len(st['selected_bars'])}")
        _log(f"Param  : model_dim={param['model_dim']}, "
             f"bars_per_step={param['bars_per_step']}, "
             f"temp={param['temperature']}, "
             f"mask_top_k={param['mask_top_k']}")

        # DEBUG: Save Status and HyperParam JSON
        _debug_dump(job.job_id, "3_status", status_json, ".json")
        _debug_dump(job.job_id, "4_param", param_json, ".json")

        # Step 5: Run inference.
        _update(job, 35, "Running model...")
        result_json = mmm_refactored.sample_multi_step(
            piece_json, status_json, param_json,
        )
        _log("Generation complete")

        # DEBUG: Save result Piece JSON (what the model produced)
        _debug_dump(job.job_id, "5_result_piece", result_json, ".json")

        # Step 6: Convert result Piece JSON → MIDI → symusic Score.
        _update(job, 85, "Processing result")
        fd, output_path = tempfile.mkstemp(suffix=".mid")
        os.close(fd)
        ENCODER.json_to_midi(result_json, output_path)
        result_score = Score(output_path)

        # DEBUG: Save result MIDI (what the encoder decoded back to MIDI)
        _debug_dump(job.job_id, "6_result", result_score, ".mid")

        os.unlink(output_path)
        output_path = None

        # Step 7: Extract notes from infilled bars → result dict.
        _update(job, 90, "Packaging result")
        _log(f"Result score: {len(result_score.tracks)} tracks, "
             f"{sum(len(t.notes) for t in result_score.tracks)} notes, "
             f"tpq={result_score.tpq}")
        job.result   = _score_to_result_dict(
            result_score, job.infill_masks, job.start_measure,
            job.end_measure, piece_to_reaper)
        total_notes = sum(
            len(nl) for md in job.result.get("tracks", {}).values()
            for nl in md.values())
        _log(f"Result dict: {len(job.result.get('tracks', {}))} tracks, "
             f"{total_notes} notes extracted")

        # DEBUG: Save final result dict (what gets sent back to REAPER)
        _debug_dump(job.job_id, "7_result_dict", job.result, ".json")

        job.status   = STATUS_DONE
        job.ended_at = time.time()
        _update(job, 100, f"Done in {round(job.ended_at - job.started_at, 1)}s")

    except Exception as e:
        job.status   = STATUS_ERROR
        job.error    = str(e)
        job.message  = f"Error: {e}"
        job.ended_at = time.time()
        _log(f"Job {job.job_id} FAILED: {e}")
        traceback.print_exc()

    finally:
        for p in (input_path, output_path):
            if p and os.path.exists(p):
                try:
                    os.unlink(p)
                except OSError:
                    pass


# ---------------------------------------------------------------------------
# XMLRPC API
# ---------------------------------------------------------------------------

def submit_job(song_dict, infill_masks, bar_masks, ignore_tracks,
               autoregressive_tracks, gen_config_dict, per_track_acs,
               start_measure, end_measure) -> str:
    if not MODEL_READY:
        raise RuntimeError("Model not loaded -- cannot accept jobs")
    job_id = str(uuid.uuid4())
    _enqueue(Job(job_id, song_dict, infill_masks, bar_masks, ignore_tracks,
                 autoregressive_tracks, gen_config_dict, per_track_acs,
                 start_measure, end_measure))
    return job_id


def get_job_status(job_id: str) -> dict:
    with _lock:
        job = _jobs.get(job_id)
    if job is None:
        return {"job_id": job_id, "status": "unknown", "progress": 0,
                "message": "Job not found", "error": "", "elapsed": 0.0}
    return job.status_dict()


def get_job_result(job_id: str) -> dict:
    with _lock:
        job = _jobs.get(job_id)
    if job is None:
        return {"ok": False, "error": "Job not found"}
    if job.status == STATUS_DONE:
        return {"ok": True, "result": job.result}
    if job.status == STATUS_ERROR:
        return {"ok": False, "error": job.error}
    return {"ok": False, "error": f"Job not finished (status={job.status})"}


def cancel_job(job_id: str) -> bool:
    with _lock:
        job = _jobs.get(job_id)
        if job and job.status == STATUS_QUEUED:
            try:
                _queue.remove(job)
            except ValueError:
                pass
            job.status  = STATUS_ERROR
            job.error   = "Cancelled by client"
            job.message = "Cancelled"
            return True
    return False


def server_status() -> dict:
    with _lock:
        counts = defaultdict(int)
        for j in _jobs.values():
            counts[j.status] += 1
    return {
        "model_ready"  : MODEL_READY,
        "active_model" : "mmm_refactored",
        "device"       : "managed by mmm_refactored",
        "max_workers"  : MAX_WORKERS,
        "queued"       : counts[STATUS_QUEUED],
        "running"      : counts[STATUS_RUNNING],
        "done"         : counts[STATUS_DONE],
        "errors"       : counts[STATUS_ERROR],
    }


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

def start_server(model_config_path: str = None):
    print("=" * 60)
    print("MIDI-GPT Inference Server")
    print("=" * 60)
    print(f"  Port        : {PORT}")
    print(f"  Max workers : {MAX_WORKERS}")
    print(f"  Config      : {MODEL_CONFIG_PATH}")
    print("=" * 60)

    if not initialize_model(model_config_path):
        print("WARNING: model failed to load -- server will reject all jobs")

    _start_workers()

    server = SimpleXMLRPCServer(("127.0.0.1", PORT), logRequests=DEBUG, allow_none=True)
    server.register_function(submit_job,       "submit_job")
    server.register_function(get_job_status,   "get_job_status")
    server.register_function(get_job_result,   "get_job_result")
    server.register_function(cancel_job,        "cancel_job")
    server.register_function(server_status,    "server_status")
    server.register_function(get_model_schema, "get_model_schema")

    print(f"\nListening on 127.0.0.1:{PORT} ...\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="MIDI-GPT inference server")
    parser.add_argument("--config",  default=None,
                        help="Path to model_config.json (default: ./model_config.json)")
    parser.add_argument("--port",    type=int, default=PORT)
    parser.add_argument("--workers", type=int, default=MAX_WORKERS)
    parser.add_argument("--debug",   action="store_true", default=DEBUG)
    args = parser.parse_args()

    PORT        = args.port
    DEBUG       = args.debug
    MAX_WORKERS = args.workers

    start_server(args.config)
