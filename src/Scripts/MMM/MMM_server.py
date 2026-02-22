"""
mmm_nn_server.py  --  Async job-queue inference server for MMM

Architecture:
  - Active model is defined by model_config.json (loaded at startup, hot-reloadable)
  - REAPER calls set_active_model(model_id) to switch models live (no restart)
  - REAPER calls get_model_schema() to fetch the AC schema for the active model
  - REAPER calls submit_job()  -> gets back a job_id immediately
  - REAPER polls  get_job_status(job_id) -> {status, progress, message, elapsed}
  - When status == "done", REAPER calls get_job_result(job_id) -> generated notes dict
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

# Path to the model manifest -- resolved relative to this script's directory.
MODEL_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "model_config.json")

# ---------------------------------------------------------------------------
# Model globals
# ---------------------------------------------------------------------------

MMM_MODEL:    MMM   = None
DEVICE              = torch.device("cuda" if torch.cuda.is_available() else "cpu")
MODEL_READY         = False
ACTIVE_MODEL_ID:str = None   # key into manifest["models"]
MODEL_CONFIG:  dict = {}     # full parsed manifest
MODEL_LOCK          = threading.Lock()  # guards model swap


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(msg: str):
    if DEBUG:
        print(f"[MMM-server] {msg}", flush=True)


# ---------------------------------------------------------------------------
# model_config.json helpers
# ---------------------------------------------------------------------------

def _load_model_config() -> dict:
    """Parse model_config.json from disk. Raises on error."""
    with open(MODEL_CONFIG_PATH, "r") as f:
        cfg = json.load(f)
    required = {"active_model", "models"}
    if not required.issubset(cfg):
        raise ValueError(f"model_config.json missing keys: {required - cfg.keys()}")
    return cfg


def _save_model_config(cfg: dict):
    """Persist updated manifest back to disk."""
    with open(MODEL_CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


def _model_entry(cfg: dict, model_id: str) -> dict:
    """Return the manifest entry for model_id, or raise KeyError."""
    try:
        return cfg["models"][model_id]
    except KeyError:
        available = list(cfg["models"].keys())
        raise KeyError(f"Unknown model '{model_id}'. Available: {available}")


# ---------------------------------------------------------------------------
# Model initialisation / live reload
# ---------------------------------------------------------------------------

def _load_model(model_id: str, cfg: dict) -> bool:
    """
    Load (or reload) the model for model_id.
    Acquires MODEL_LOCK so in-flight jobs finish before the swap.
    Returns True on success.
    """
    global MMM_MODEL, MODEL_READY, ACTIVE_MODEL_ID, MODEL_CONFIG

    entry = _model_entry(cfg, model_id)
    config_path = entry["config"]
    ckpt_path   = entry["ckpt"]

    _log(f"Loading model '{model_id}'")
    _log(f"  config     : {config_path}")
    _log(f"  checkpoint : {ckpt_path}")

    try:
        mmm_config = MMMConfig.load(config_path)
        new_model  = MMM(mmm_config, pretrained=ckpt_path)
        new_model.model.to(DEVICE)
    except Exception as e:
        _log(f"Model load failed: {e}")
        traceback.print_exc()
        return False

    with MODEL_LOCK:
        MMM_MODEL       = new_model
        ACTIVE_MODEL_ID = model_id
        MODEL_CONFIG    = cfg
        MODEL_READY     = True

    _log(f"Model '{model_id}' ready on {DEVICE}")
    return True


def initialize_model(model_config_path: str = None) -> bool:
    """
    Load the active model from model_config.json.
    model_config_path overrides MODEL_CONFIG_PATH (for CLI --config flag).
    """
    global MODEL_CONFIG_PATH
    if model_config_path:
        MODEL_CONFIG_PATH = model_config_path

    try:
        cfg      = _load_model_config()
        model_id = cfg["active_model"]
        return _load_model(model_id, cfg)
    except Exception as e:
        _log(f"Initialization failed: {e}")
        traceback.print_exc()
        return False


# ---------------------------------------------------------------------------
# XMLRPC: model management
# ---------------------------------------------------------------------------

def get_model_schema() -> dict:
    """
    Return the AC schema for the currently active model.

    Response:
    {
        "ok":           bool,
        "model_id":     str,
        "model_label":  str,
        "model_index":  int,   # 0-based index in manifest order (for JSFX slider)
        "model_ids":    [str, ...],  # ordered list of all model IDs
        "ac_schema":    [...],       # list of AC param defs
        "seeded_bar_ac": {...}
    }
    """
    try:
        cfg      = _load_model_config()   # always fresh from disk
        model_id = ACTIVE_MODEL_ID or cfg["active_model"]
        entry    = _model_entry(cfg, model_id)
        model_ids = list(cfg["models"].keys())
        return {
            "ok":            True,
            "model_id":      model_id,
            "model_label":   entry.get("label", model_id),
            "model_index":   model_ids.index(model_id),
            "model_ids":     model_ids,
            "ac_schema":     entry.get("ac_schema", []),
            "seeded_bar_ac": entry.get("seeded_bar_ac", {}),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


def set_active_model(model_id: str) -> dict:
    """
    Switch to a different model live (no server restart).
    Blocks until the new model is loaded.

    Returns {"ok": bool, "model_id": str, "error": str}
    """
    _log(f"set_active_model called: '{model_id}'")
    try:
        cfg = _load_model_config()
        _model_entry(cfg, model_id)   # validate early

        ok = _load_model(model_id, cfg)
        if not ok:
            return {"ok": False, "model_id": model_id,
                    "error": "Model load failed -- check server logs"}

        # Persist the selection so next server start uses it too
        cfg["active_model"] = model_id
        _save_model_config(cfg)

        schema = get_model_schema()
        schema["ok"] = True
        return schema

    except Exception as e:
        _log(f"set_active_model error: {e}")
        traceback.print_exc()
        return {"ok": False, "model_id": model_id, "error": str(e)}


def list_models() -> dict:
    """Return all available model IDs and their labels."""
    try:
        cfg = _load_model_config()
        return {
            "ok": True,
            "models": [
                {"id": mid, "label": entry.get("label", mid)}
                for mid, entry in cfg["models"].items()
            ],
            "active_model": ACTIVE_MODEL_ID or cfg["active_model"],
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ---------------------------------------------------------------------------
# MIDI conversion helpers (unchanged from original)
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
                duration_tick = max(1, end_tick - start_tick)
                symusic_track.notes.append(Note(
                    time=start_tick, duration=duration_tick,
                    pitch=int(note_dict["pitch"]), velocity=int(note_dict["velocity"]),
                ))

        score.tracks.append(symusic_track)

    score.sort(inplace=True)
    _log(f"midisong_dict_to_score: {len(score.tracks)} tracks, "
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
    def __init__(self, job_id, song_dict, infill_masks,
                 bar_masks, ignore_tracks, autoregressive_tracks, gen_config_dict,
                 per_track_acs, seeded_bar_positions, seeded_bar_ac,
                 start_measure, end_measure):
        self.job_id                = job_id
        self.song_dict             = song_dict
        self.infill_masks          = infill_masks
        self.bar_masks             = bar_masks
        self.ignore_tracks         = ignore_tracks
        self.autoregressive_tracks = autoregressive_tracks
        self.gen_config_dict       = gen_config_dict
        self.per_track_acs         = per_track_acs
        self.seeded_bar_positions  = seeded_bar_positions
        self.seeded_bar_ac         = seeded_bar_ac
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
# Job queue
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


# ---------------------------------------------------------------------------
# Worker pool
# ---------------------------------------------------------------------------

def _worker_loop():
    while True:
        job = _dequeue()
        if job is None:
            time.sleep(0.25)
            continue
        _run_job(job)


def _start_workers():
    for _ in range(MAX_WORKERS):
        t = threading.Thread(target=_worker_loop, daemon=True)
        t.start()
    _log(f"Started {MAX_WORKERS} worker thread(s)")


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def _update(job: Job, progress: int, message: str):
    job.progress = progress
    job.message  = message
    _log(f"Job {job.job_id} [{progress:3d}%] {message}")


def _strip_empty_tracks(score, job):
    from symusic import Score as _Score

    orig_to_compact = {}
    compact_to_orig = {}
    compact_idx     = 0

    compact_score = _Score(score.tpq, ttype="tick")
    compact_score.tempos          = score.tempos
    compact_score.time_signatures = score.time_signatures

    for orig_idx, track in enumerate(score.tracks):
        if len(track.notes) == 0:
            _log(f"  Stripping empty track {orig_idx} ({track.name!r})")
            continue
        orig_to_compact[orig_idx]  = compact_idx
        compact_to_orig[compact_idx] = orig_idx
        compact_score.tracks.append(track)
        compact_idx += 1

    def _remap_masks(masks):
        return [[orig_to_compact[t], b] for t, b in masks if t in orig_to_compact]

    def _remap_track_list(lst):
        return [orig_to_compact[t] for t in lst if t in orig_to_compact]

    _log(f"  Tracks: {len(score.tracks)} -> {len(compact_score.tracks)} after stripping empties")

    return (
        compact_score, orig_to_compact, compact_to_orig,
        _remap_masks(job.infill_masks),
        _remap_masks(job.bar_masks),
        _remap_track_list(job.ignore_tracks),
        _remap_track_list(job.autoregressive_tracks),
    )


def _remap_result_to_orig(result_dict, compact_to_orig):
    remapped = {}
    for compact_t_key, measures in result_dict["tracks"].items():
        orig_idx = compact_to_orig.get(int(compact_t_key), int(compact_t_key))
        remapped[str(orig_idx)] = measures
    return {**result_dict, "tracks": remapped}


def _run_job(job: Job):
    job.status     = STATUS_RUNNING
    job.started_at = time.time()
    _update(job, 5, "Starting")

    try:
        _update(job, 10, "Converting MIDI representation to Score")
        score: Score = midisong_dict_to_score(job.song_dict)

        _update(job, 15, "Stripping empty tracks")
        (score, orig_to_compact, compact_to_orig,
         compact_infill, compact_bar_masks,
         compact_ignore, compact_autoreg) = _strip_empty_tracks(score, job)

        if len(score.tracks) == 0:
            raise ValueError("All tracks are empty -- nothing to generate")

        _update(job, 20, "Building inference config")

        class _CompactJob:
            pass
        _cj = _CompactJob()
        _cj.song_dict             = {"num_tracks": len(score.tracks),
                                     "num_measures": job.song_dict["num_measures"]}
        _cj.infill_masks          = compact_infill
        _cj.bar_masks             = compact_bar_masks
        _cj.ignore_tracks         = compact_ignore
        _cj.autoregressive_tracks = compact_autoreg
        _cj.per_track_acs         = {
            str(orig_to_compact[int(k)]): v
            for k, v in job.per_track_acs.items()
            if int(k) in orig_to_compact
        }
        _cj.seeded_bar_positions  = [
            [orig_to_compact[t], b]
            for t, b in job.seeded_bar_positions
            if t in orig_to_compact
        ]
        _cj.seeded_bar_ac  = job.seeded_bar_ac
        _cj.gen_config_dict = job.gen_config_dict

        inf           = _job_to_inference_dict(_cj)
        inference_cfg = InferenceConfig.convert_from_dict(inf)
        print(json.dumps(inference_cfg.to_dict(), indent=4))

        _update(job, 25, "Building generation config")
        g       = job.gen_config_dict
        gen_cfg = MMMGenerationConfig.convert_from_dict(g)
        gen_cfg.temperature = max(0.5, min(2.0, gen_cfg.temperature))

        if gen_cfg.seed is not None:
            torch.manual_seed(gen_cfg.seed)
            torch.cuda.manual_seed_all(gen_cfg.seed)
        else:
            seed = torch.seed()
            torch.manual_seed(seed)
            torch.cuda.manual_seed_all(seed)

        generate_kwargs = {"generation_config": gen_cfg.to_hf()}

        _update(job, 30, "Pre-processing score")
        num_measures_in_selection = job.end_measure - job.start_measure
        score = _preprocess_score(score, num_measures_in_selection)

        _update(job, 35, "Running MMM model  (this takes a while...)")

        # Take a reference to the model under lock so a concurrent
        # set_active_model doesn't pull the rug mid-generation.
        with MODEL_LOCK:
            model_snapshot = MMM_MODEL

        gen_score: Score = generate(
            mmm              = model_snapshot,
            score_or_path    = score,
            inference_config = inference_cfg,
            generate_kwargs  = generate_kwargs,
            device           = DEVICE,
        )

        _update(job, 90, "Packaging result")
        raw_result = _score_to_result_dict(gen_score, compact_infill,
                                           job.start_measure, job.end_measure)
        job.result  = _remap_result_to_orig(raw_result, compact_to_orig)
        job.status  = STATUS_DONE
        job.ended_at = time.time()
        elapsed = round(job.ended_at - job.started_at, 1)
        _update(job, 100, f"Done in {elapsed}s")

    except NotImplementedError as e:
        job.status  = STATUS_ERROR
        job.error   = str(e)
        job.message = "Not implemented: " + str(e)
        job.ended_at = time.time()
        _log(f"Job {job.job_id} NOT IMPLEMENTED: {e}")

    except Exception as e:
        job.status  = STATUS_ERROR
        job.error   = str(e)
        job.message = f"Error: {e}"
        job.ended_at = time.time()
        _log(f"Job {job.job_id} FAILED: {e}")
        traceback.print_exc()


# ---------------------------------------------------------------------------
# Inference dict builder
# ---------------------------------------------------------------------------

def _job_to_inference_dict(job) -> dict:
    nt = job.song_dict['num_tracks']
    nm = job.song_dict['num_measures']

    infill_mask       = [[False]*nm for _ in range(nt)]
    bar_mask          = [[False]*nm for _ in range(nt)]
    ignore_mask       = [False]*nt
    autoregressive_mask = [False]*nt

    for t, b in job.infill_masks:
        infill_mask[t][b] = True
    for t, b in job.bar_masks:
        bar_mask[t][b] = True
    for t in job.ignore_tracks:
        ignore_mask[t] = True
    for t in job.autoregressive_tracks:
        autoregressive_mask[t] = True

    seeded_set = {(t, b) for t, b in job.seeded_bar_positions}

    param = {}
    for pkey in ["model_dim", "tracks_per_step", "bars_per_step"]:
        if pkey in job.gen_config_dict:
            param[pkey] = job.gen_config_dict.pop(pkey)

    track_cfgs = []
    for t in range(nt):
        bar_cfgs = []
        for b in range(nm):
            bar_ac = job.seeded_bar_ac if (t, b) in seeded_set \
                     else job.per_track_acs.get(str(t), {})
            bar_cfgs.append({
                "generate"          : infill_mask[t][b] and not ignore_mask[t],
                "mask"              : bar_mask[t][b] and not ignore_mask[t],
                "attribute_controls": bar_ac if infill_mask[t][b] else {},
            })
        track_cfgs.append({
            "track_idx"       : t,
            "bars"            : bar_cfgs,
            "autoregressive"  : autoregressive_mask[t],
            "ignore"          : ignore_mask[t],
            "attribute_controls": {},
        })

    return {"tracks": track_cfgs, "param": param}


def _preprocess_score(score: Score, end_measure: int) -> Score:
    for ti in reversed(range(len(score.time_signatures))):
        del score.time_signatures[ti]
    for ti in reversed(range(len(score.tempos))):
        del score.tempos[ti]
    clip_time = (end_measure + 1) * score.tpq * 4
    return score.clip(0, clip_time, clip_end=True, inplace=False)


def _score_to_result_dict(score: Score, masks: list,
                          start_measure: int, end_measure: int) -> dict:
    tpq           = score.tpq
    ticks_per_bar = tpq * 4
    masked_set    = {(int(t), int(b)) for t, b in masks}
    tracks_out    = {}

    for track_idx, track in enumerate(score.tracks):
        t_key = str(track_idx)
        for note in track.notes:
            measure_idx = note.time // ticks_per_bar
            if (track_idx, measure_idx) not in masked_set:
                continue
            m_key = str(measure_idx)
            tracks_out.setdefault(t_key, {}).setdefault(m_key, []).append({
                "pitch"        : int(note.pitch),
                "velocity"     : int(note.velocity),
                "start_tick"   : int(note.time) - measure_idx * ticks_per_bar,
                "duration_tick": int(note.duration),
            })

    return {
        "start_measure": start_measure,
        "end_measure"  : end_measure,
        "tpq"          : tpq,
        "tracks"       : tracks_out,
    }


# ---------------------------------------------------------------------------
# XMLRPC API
# ---------------------------------------------------------------------------

def submit_job(song_dict, infill_masks, bar_masks, ignore_tracks,
               autoregressive_tracks, gen_config_dict, per_track_acs,
               seeded_bar_positions, seeded_bar_ac,
               start_measure, end_measure) -> str:
    if not MODEL_READY:
        raise RuntimeError("Model not loaded -- cannot accept jobs")

    job_id = str(uuid.uuid4())
    job    = Job(job_id, song_dict, infill_masks, bar_masks, ignore_tracks,
                 autoregressive_tracks, gen_config_dict, per_track_acs,
                 seeded_bar_positions, seeded_bar_ac, start_measure, end_measure)
    _enqueue(job)
    return job_id


def get_job_status(job_id: str) -> dict:
    with _lock:
        job = _jobs.get(job_id)
    if job is None:
        return {"job_id": job_id, "status": "unknown",
                "progress": 0, "message": "Job not found", "error": "", "elapsed": 0.0}
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
    return {"ok": False, "error": f"Job not finished yet (status={job.status})"}


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
# Server startup
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

    ok = initialize_model(model_config_path)
    if not ok:
        print("WARNING: model failed to load -- server will reject all jobs")

    _start_workers()

    server = SimpleXMLRPCServer(
        ("127.0.0.1", PORT),
        logRequests = DEBUG,
        allow_none  = True,
    )
    server.register_function(submit_job,        "submit_job")
    server.register_function(get_job_status,    "get_job_status")
    server.register_function(get_job_result,    "get_job_result")
    server.register_function(cancel_job,        "cancel_job")
    server.register_function(server_status,     "server_status")
    server.register_function(get_model_schema,  "get_model_schema")
    server.register_function(set_active_model,  "set_active_model")
    server.register_function(list_models,       "list_models")

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
                        help="Path to model_config.json  (default: ./model_config.json)")
    parser.add_argument("--port",    type=int, default=PORT)
    parser.add_argument("--workers", type=int, default=MAX_WORKERS)
    parser.add_argument("--debug",   action="store_true", default=DEBUG)
    args = parser.parse_args()

    PORT        = args.port
    DEBUG       = args.debug
    MAX_WORKERS = args.workers

    start_server(args.config)