"""
mmm_server.py  --  Async job-queue inference server for MMM

Model is set via model_config.json at startup (active_model field).
No runtime model switching. The client calls get_model_schema() on each
run to get the AC schema + track_fx_id for the active model.
"""

import os
import sys
import uuid
import threading
import time
import json
import traceback
from collections import defaultdict, deque
from xmlrpc.server import SimpleXMLRPCServer

import torch
import time
from transformers import set_seed
from symusic import Score

from mmm.core.baseline import MMM
from mmm.inference.generate import generate
from mmm.inference.config import InferenceConfig, HyperParam
from mmm.core.config import MMMGenerationConfig, MMMConfig


# ---------------------------------------------------------------------------
# Server config
# ---------------------------------------------------------------------------

PORT        = 3456
DEBUG       = True
MAX_WORKERS = 1

MODEL_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "model_config.json")

# ---------------------------------------------------------------------------
# Model globals
# ---------------------------------------------------------------------------

MMM_MODEL:      MMM  = None
DEVICE               = torch.device("cuda" if torch.cuda.is_available() else "cpu")
MODEL_READY          = False
ACTIVE_MODEL_ID: str = None
ACTIVE_MODEL_ENTRY: dict = {}   # the full entry from model_config.json


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(msg: str):
    if DEBUG:
        print(f"[MMM-server] {msg}", flush=True)


# ---------------------------------------------------------------------------
# model_config.json
# ---------------------------------------------------------------------------

def _load_model_config() -> dict:
    with open(MODEL_CONFIG_PATH, "r") as f:
        return json.load(f)


def initialize_model(model_config_path: str = None) -> bool:
    global MMM_MODEL, MODEL_READY, ACTIVE_MODEL_ID, ACTIVE_MODEL_ENTRY, MODEL_CONFIG_PATH

    if model_config_path:
        MODEL_CONFIG_PATH = model_config_path

    try:
        cfg      = _load_model_config()
        model_id = cfg["active_model"]
        entry    = cfg["models"][model_id]

        _log(f"Active model  : {model_id} ({entry.get('label', '')})")
        _log(f"Config        : {entry['config']}")
        _log(f"Checkpoint    : {entry['ckpt']}")

        mmm_config = MMMConfig.load(entry["config"])
        MMM_MODEL  = MMM(mmm_config, pretrained=entry["ckpt"])
        MMM_MODEL.model.to(DEVICE)

        ACTIVE_MODEL_ID    = model_id
        ACTIVE_MODEL_ENTRY = entry
        MODEL_READY        = True

        _log(f"Model ready on {DEVICE}")
        return True

    except Exception as e:
        _log(f"Model initialization failed: {e}")
        traceback.print_exc()
        return False


# ---------------------------------------------------------------------------
# XMLRPC: schema endpoint
# ---------------------------------------------------------------------------

def get_model_schema() -> dict:
    """
    Returns everything the client needs to read track attribute controls:
      - ac_schema     : list of param defs (ac_key, label, min, max, default, format)
      - track_fx_id   : the jsfx_id sentinel the client should look for on tracks
      - model_id      : active model identifier
      - model_label   : human-readable label
    """
    if not MODEL_READY:
        return {"ok": False, "error": "Model not loaded"}

    return {
        "ok":          True,
        "model_id":    ACTIVE_MODEL_ID,
        "model_label": ACTIVE_MODEL_ENTRY.get("label", ACTIVE_MODEL_ID),
        "track_fx_id": ACTIVE_MODEL_ENTRY.get("track_fx_id", 0),
        "ac_schema":   ACTIVE_MODEL_ENTRY.get("ac_schema", []),
    }


# ---------------------------------------------------------------------------
# MIDI conversion
# ---------------------------------------------------------------------------

def midisong_dict_to_score(song_dict: dict) -> Score:
    from symusic import Score, Track, Note, Tempo, TimeSignature

    TPQ   = 480
    score = Score(TPQ, ttype="tick")

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
            num, denom = (ts[0], ts[1]) if isinstance(ts, (list, tuple)) else (4, 4)
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
            TimeSignature(time=tick, numerator=num, denominator=denom))

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

        score.tracks.append(symusic_track)

    score.sort(inplace=True)
    _log(f"Score: {len(score.tracks)} tracks, "
         f"{sum(len(t.notes) for t in score.tracks)} notes")
    return score


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


def _seed_empty_masked_bars(song_dict: dict, infill_masks: list):
    """Inject a ghost note into any masked bar that has no notes.

    The model needs at least one note in every bar it infills so it can
    build the bar's attribute-control token context.  When the user selects
    an empty measure we silently add a single inaudible note (velocity 1,
    duration = 1/32 of the bar) before converting to a Score object.

    ``infill_masks`` uses the *original* (pre-compaction) track indices
    because this runs before _strip_empty_tracks.

    Args:
        song_dict:    Raw song dict from the client (modified in-place).
        infill_masks: List of [track_idx, bar_idx] pairs to infill.
    """
    all_measures = song_dict.get("measures", [])
    seeded_count = 0

    for t, b in infill_masks:
        if t >= len(all_measures) or b >= len(all_measures[t]):
            continue
        measure = all_measures[t][b]
        if measure is None:
            continue
        if measure.get("notes"):
            continue  # Already has content — nothing to do

        instrument = measure.get("instrument", 0)
        pitch      = 36 if instrument == 128 else 60
        bar_dur    = float(measure.get("end_time", 0)) - float(measure.get("start_time", 0))
        note_dur   = max(0.01, bar_dur / 32.0)

        measure["notes"] = [{
            "pitch"     : pitch,
            "velocity"  : 1,
            "start_time": 0.0,
            "end_time"  : note_dur,
        }]
        seeded_count += 1

    if seeded_count:
        _log(f"Seeded {seeded_count} empty bar(s) with ghost notes.")


def _strip_empty_tracks(score, job):
    """Remove tracks that are completely empty AND not being infilled into.

    A track with no notes that is listed in infill_masks must be kept —
    the user explicitly asked to generate into it (and we just seeded it
    with a ghost note, so the Score will actually have a note there now).
    Only tracks with no notes AND no infill selections are discarded.
    """
    from symusic import Score as _Score

    infill_tracks = {t for t, b in job.infill_masks}

    orig_to_compact = {}
    compact_to_orig = {}
    compact_idx     = 0

    compact_score = _Score(score.tpq, ttype="tick")
    compact_score.tempos          = score.tempos
    compact_score.time_signatures = score.time_signatures

    for orig_idx, track in enumerate(score.tracks):
        is_empty    = len(track.notes) == 0
        is_infilled = orig_idx in infill_tracks
        if is_empty and not is_infilled:
            _log(f"  Stripping empty non-infill track {orig_idx} ({track.name!r})")
            continue
        orig_to_compact[orig_idx]    = compact_idx
        compact_to_orig[compact_idx] = orig_idx
        compact_score.tracks.append(track)
        compact_idx += 1

    def _remap(masks):
        return [[orig_to_compact[t], b] for t, b in masks if t in orig_to_compact]

    def _remap_list(lst):
        return [orig_to_compact[t] for t in lst if t in orig_to_compact]

    _log(f"  Tracks: {len(score.tracks)} -> {len(compact_score.tracks)}")
    return (compact_score, orig_to_compact, compact_to_orig,
            _remap(job.infill_masks), _remap(job.bar_masks),
            _remap_list(job.ignore_tracks), _remap_list(job.autoregressive_tracks))


def _reorder_for_ar(score, compact_infill, compact_bar_masks,
                    compact_ignore, compact_autoreg, per_track_acs_compact):
    """Reorder score tracks so the AR track is last among non-ignored tracks.

    InferenceConfig / encode_tokens requires the autoregressive track to have
    the highest track_idx among all non-ignored tracks (prune_score_tokens
    preserves sorted order so the AR track lands at sequences[-1] in the
    encoder).  The user can place their AR track anywhere in REAPER, so we
    fix the ordering here — moving the AR track to the end of the active
    block while leaving everything else in its original relative order.

    Ordering (stable within each group):
      1. Non-ignored, non-AR tracks
      2. The AR track (at most one)
      3. Ignored tracks (position irrelevant to encoder)

    All index-based data structures are remapped to the new positions.

    Returns:
        (reordered_score, new_infill, new_bar_masks,
         new_ignore, new_autoreg, new_per_track_acs, new_to_old)
        where new_to_old[new_idx] = old_compact_idx.
    """
    nt          = len(score.tracks)
    autoreg_set = set(compact_autoreg)
    ignore_set  = set(compact_ignore)

    ar_tracks     = [t for t in range(nt) if t in autoreg_set and t not in ignore_set]
    non_ar_tracks = [t for t in range(nt) if t not in autoreg_set and t not in ignore_set]
    ign_tracks    = [t for t in range(nt) if t in ignore_set]

    if len(ar_tracks) > 1:
        raise ValueError(
            f"At most one autoregressive track is supported; "
            f"found AR tracks at compact indices {ar_tracks}."
        )

    # Desired order: [non-AR active | AR | ignored]
    new_to_old = non_ar_tracks + ar_tracks + ign_tracks
    old_to_new = {old: new for new, old in enumerate(new_to_old)}

    if new_to_old == list(range(nt)):
        # Already in correct order — nothing to do.
        return (score, compact_infill, compact_bar_masks,
                compact_ignore, compact_autoreg,
                per_track_acs_compact, new_to_old)

    from symusic import Score as _Score
    reordered_score = _Score(score.tpq, ttype="tick")
    reordered_score.tempos          = score.tempos
    reordered_score.time_signatures = score.time_signatures
    for old_idx in new_to_old:
        reordered_score.tracks.append(score.tracks[old_idx])

    new_infill    = [[old_to_new[t], b] for t, b in compact_infill]
    new_bar_masks = [[old_to_new[t], b] for t, b in compact_bar_masks]
    new_ignore    = [old_to_new[t] for t in compact_ignore]
    new_autoreg   = [old_to_new[t] for t in compact_autoreg]
    new_acs       = {str(old_to_new[int(k)]): v
                     for k, v in per_track_acs_compact.items()
                     if int(k) in old_to_new}

    _log(f"  AR reorder: new_to_old={new_to_old}")
    return (reordered_score, new_infill, new_bar_masks,
            new_ignore, new_autoreg, new_acs, new_to_old)


def _remap_result_to_orig(result_dict, compact_to_orig):
    remapped = {}
    for k, measures in result_dict["tracks"].items():
        orig = compact_to_orig.get(int(k), int(k))
        remapped[str(orig)] = measures
    return {**result_dict, "tracks": remapped}


def _job_to_inference_dict(job) -> dict:
    nt = job.song_dict["num_tracks"]
    nm = job.song_dict["num_measures"]

    infill_mask         = [[False]*nm for _ in range(nt)]
    bar_mask            = [[False]*nm for _ in range(nt)]
    ignore_mask         = [False]*nt
    autoregressive_mask = [False]*nt

    for t, b in job.infill_masks:
        infill_mask[t][b] = True
    for t, b in job.bar_masks:
        bar_mask[t][b] = True
    for t in job.ignore_tracks:
        ignore_mask[t] = True
    for t in job.autoregressive_tracks:
        autoregressive_mask[t] = True

    # Extract structural HyperParam keys and inference-level overrides from
    # gen_config_dict before it is forwarded to MMMGenerationConfig.
    param = {}
    for pkey in ["model_dim", "tracks_per_step", "bars_per_step"]:
        if pkey in job.gen_config_dict:
            param[pkey] = job.gen_config_dict.pop(pkey)

    # Global autoregressive toggle from GlobalOptions JSFX slider.
    # When on, every non-ignored track that has bars to generate becomes AR.
    global_ar = job.gen_config_dict.pop("autoregressive", False)
    if global_ar:
        for t in range(nt):
            if not ignore_mask[t] and any(infill_mask[t]):
                autoregressive_mask[t] = True

    # Hard-limit logits processors (optional; absent = no limit).
    max_density   = job.gen_config_dict.pop("max_density",   None)
    max_polyphony = job.gen_config_dict.pop("max_polyphony", None)

    if "top_k" in job.gen_config_dict.keys():
        if job.gen_config_dict["top_k"] == 0.0:
            job.gen_config_dict.pop("top_k", None)

    if "top_p" in job.gen_config_dict.keys():
        if job.gen_config_dict["top_p"] == 0.0:
            job.gen_config_dict.pop("top_p", None)

    track_cfgs = []
    for t in range(nt):
        bar_cfgs = []
        for b in range(nm):
            bar_cfgs.append({
                "generate"          : infill_mask[t][b] and not ignore_mask[t],
                "mask"              : bar_mask[t][b]    and not ignore_mask[t],
                "attribute_controls": job.per_track_acs.get(str(t), {}) if infill_mask[t][b] else {},
            })
        track_cfgs.append({
            "track_idx"         : t,
            "bars"              : bar_cfgs,
            "autoregressive"    : autoregressive_mask[t],
            "ignore"            : ignore_mask[t],
            "attribute_controls": {},
        })

    inf = {"tracks": track_cfgs, "param": param}
    if max_density is not None:
        inf["max_density"] = max_density
    if max_polyphony is not None:
        inf["max_polyphony"] = max_polyphony
    return inf


def _preprocess_score(score: Score, end_measure: int) -> Score:
    for ti in reversed(range(len(score.time_signatures))):
        del score.time_signatures[ti]
    for ti in reversed(range(len(score.tempos))):
        del score.tempos[ti]
    clip_time = (end_measure + 1) * score.tpq * 4
    return score.clip(0, clip_time, clip_end=True, inplace=False)


def _score_to_result_dict(score: Score, masks, start_measure, end_measure) -> dict:
    tpq           = score.tpq
    ticks_per_bar = tpq * 4
    masked_set    = {(int(t), int(b)) for t, b in masks}
    tracks_out    = {}

    for track_idx, track in enumerate(score.tracks):
        for note in track.notes:
            measure_idx = note.time // ticks_per_bar
            if (track_idx, measure_idx) not in masked_set:
                continue
            m_key = str(measure_idx)
            tracks_out.setdefault(str(track_idx), {}).setdefault(m_key, []).append({
                "pitch"        : int(note.pitch),
                "velocity"     : int(note.velocity),
                "start_tick"   : int(note.time) - measure_idx * ticks_per_bar,
                "duration_tick": int(note.duration),
            })

    return {"start_measure": start_measure, "end_measure": end_measure,
            "tpq": tpq, "tracks": tracks_out}


# ---------------------------------------------------------------------------
# Job runner
# ---------------------------------------------------------------------------

def _run_job(job: Job):
    job.status     = STATUS_RUNNING
    job.started_at = time.time()
    _update(job, 5, "Starting")

    try:
        # Step 1: Seed empty masked bars BEFORE converting to Score.
        # Tracks selected for infill may be completely empty; seeding ensures
        # they survive _strip_empty_tracks and have valid encoder context.
        _update(job, 10, "Seeding empty masked bars")
        _seed_empty_masked_bars(job.song_dict, job.infill_masks)

        # Step 2: Convert to symusic Score.
        _update(job, 13, "Converting MIDI to Score")
        score = midisong_dict_to_score(job.song_dict)

        # Step 3: Drop tracks that are empty AND not being infilled.
        _update(job, 15, "Stripping empty tracks")
        (score, orig_to_compact, compact_to_orig,
         compact_infill, compact_bar_masks,
         compact_ignore, compact_autoreg) = _strip_empty_tracks(score, job)

        if len(score.tracks) == 0:
            raise ValueError("All tracks are empty — nothing to generate")

        # Step 4: Remap per-track AC overrides to compact indices.
        compact_per_track_acs = {
            str(orig_to_compact[int(k)]): v
            for k, v in job.per_track_acs.items()
            if int(k) in orig_to_compact
        }

        # Step 5: Move the AR track to the end of the non-ignored block.
        # encode_tokens treats the last track in the pruned sequence as AR;
        # InferenceConfig validates that the AR track has the highest track_idx.
        _update(job, 17, "Reordering tracks for autoregressive mode")
        (score, compact_infill, compact_bar_masks,
         compact_ignore, compact_autoreg,
         compact_per_track_acs, new_to_old) = _reorder_for_ar(
            score, compact_infill, compact_bar_masks,
            compact_ignore, compact_autoreg, compact_per_track_acs
        )
        # Carry the reordering through to the orig-index lookup used for write-back.
        compact_to_orig = {new: compact_to_orig[old] for new, old in enumerate(new_to_old)}

        # Step 6: Build InferenceConfig.
        _update(job, 20, "Building inference config")

        class _CJ:
            pass
        _cj = _CJ()
        _cj.song_dict             = {"num_tracks": len(score.tracks),
                                     "num_measures": job.song_dict["num_measures"]}
        _cj.infill_masks          = compact_infill
        _cj.bar_masks             = compact_bar_masks
        _cj.ignore_tracks         = compact_ignore
        _cj.autoregressive_tracks = compact_autoreg
        _cj.per_track_acs         = compact_per_track_acs
        _cj.gen_config_dict       = job.gen_config_dict

        inf           = _job_to_inference_dict(_cj)
        inference_cfg = InferenceConfig.convert_from_dict(inf)

        # Step 7: Build generation config (temperature, seed, top-k/p …).
        _update(job, 25, "Building generation config")
        gen_cfg = MMMGenerationConfig.convert_from_dict(job.gen_config_dict)
        gen_cfg.temperature = max(0.5, min(2.0, gen_cfg.temperature))

        if gen_cfg.seed is not None and gen_cfg.seed > 0:
            _log(f"Setting seed {gen_cfg.seed}")
            set_seed(gen_cfg.seed)
            #torch.manual_seed(gen_cfg.seed)
            #torch.cuda.manual_seed_all(gen_cfg.seed)
        else:
            seed = int(time.time() * 1000000) % (2 ** 32)
            set_seed(seed)
            #torch.manual_seed(seed)
            #torch.cuda.manual_seed_all(seed)

        # Step 8: Pre-process score (strip tempo map, clip length).
        _update(job, 30, "Pre-processing score")
        score = _preprocess_score(score, job.end_measure - job.start_measure)

        # Step 9: Run the model.
        _update(job, 35, "Running MMM model...")
        gen_score = generate(
            mmm              = MMM_MODEL,
            score_or_path    = score,
            inference_config = inference_cfg,
            generate_kwargs  = {"generation_config": gen_cfg.to_hf()},
            device           = DEVICE,
        )

        # Step 10: Package and remap results back to original track indices.
        _update(job, 90, "Packaging result")
        raw          = _score_to_result_dict(gen_score, compact_infill,
                                             job.start_measure, job.end_measure)
        job.result   = _remap_result_to_orig(raw, compact_to_orig)
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
        "active_model" : ACTIVE_MODEL_ID or "",
        "device"       : str(DEVICE),
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
    print("MMM Inference Server")
    print("=" * 60)
    print(f"  Port        : {PORT}")
    print(f"  Device      : {DEVICE}")
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
    server.register_function(cancel_job,       "cancel_job")
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
    parser = argparse.ArgumentParser(description="MMM inference server")
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