# -*- coding: utf-8 -*-
"""
REAPER_mmm_infill.py  --  REAPER-side MMM client

Prerequisites:
  1. MMM_server.py must be running.
  2. MMM_initialize.py must have been run once this session to populate the
     model dropdown and set the Status slider to Ready.

After initialization, this script uses REAPER's ExtState cache for the model
list and only contacts the server when the model slider actually changes.
"""

import os
import re
import sys
import time
import json
import traceback
from xmlrpc.client import ServerProxy

from reaper_python import *
from midi_extraction import (
    extract_midi_for_mmm,
    MIDISongByMeasure,
    MIDIMeasure,
    MIDINote,
)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SERVER_URL        = "http://127.0.0.1:3456"
POLL_INTERVAL     = 0.1

GLOBAL_FX_ID          = 54964318
GLOBAL_FX_JS_PATH     = "Effects/MMM/MMM Global Options.js"
TRACK_OPTIONS_FX_ID   = 349583099
TRACK_OPTIONS_FX_NAME = "MMM Track Options"

# Param offsets in Global Options JSFX
PARAM_JSFX_ID     = 0
PARAM_MMM_READY   = 1   # slider2
PARAM_DO_INIT     = 2   # slider3
PARAM_MODEL_INDEX = 3   # slider4
PARAM_TEMPERATURE = 4   # slider5
PARAM_MODEL_DIM   = 5   # slider6
PARAM_BARS_STEP   = 6   # slider7
PARAM_TRACKS_STEP = 7   # slider8
PARAM_SEED        = 8   # slider9
PARAM_TOP_K       = 9   # slider10
PARAM_TOP_P       = 10  # slider11

TRACK_OPTIONS_AC_OFFSET = 1
TRACK_OPTIONS_MAX_SLOTS = 8

EXT_SECTION      = "MMM_Infill"
EXT_MODEL_ID     = "active_model_id"
EXT_MODEL_INDEX  = "active_model_index"
EXT_MODEL_IDS    = "model_ids_json"
EXT_MODEL_LABELS = "model_labels_json"


# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

class _ReaperConsole:
    def write(self, s):
        RPR_ShowConsoleMsg(s)
    def flush(self):
        pass

sys.stdout = sys.stderr = _ReaperConsole()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def is_approx(x, y, tol=0.0001):
    return abs(x - y) <= tol


def _format_ac_value(schema_param: dict, raw_value: float) -> str:
    fmt = schema_param.get("format", "int")
    v   = int(round(raw_value))
    if fmt == "density":
        return str(v) + ("+" if v == 18 else "")
    elif fmt == "float":
        return str(float(raw_value))
    return str(v)


# ---------------------------------------------------------------------------
# ExtState cache
# ---------------------------------------------------------------------------

def _ext_get(key, default=None):
    return RPR_GetExtState(EXT_SECTION, key) if RPR_HasExtState(EXT_SECTION, key) else default


def _ext_set(key, value):
    RPR_SetExtState(EXT_SECTION, key, str(value), True)


def get_cached_model_info():
    ids_raw    = _ext_get(EXT_MODEL_IDS)
    labels_raw = _ext_get(EXT_MODEL_LABELS)
    if ids_raw and labels_raw:
        try:
            return json.loads(ids_raw), json.loads(labels_raw)
        except Exception:
            pass
    return None, None


def cache_model_info(model_id, model_index, model_ids, model_labels):
    _ext_set(EXT_MODEL_ID,     model_id)
    _ext_set(EXT_MODEL_INDEX,  str(model_index))
    _ext_set(EXT_MODEL_IDS,    json.dumps(model_ids))
    _ext_set(EXT_MODEL_LABELS, json.dumps(model_labels))


# ---------------------------------------------------------------------------
# Global Options JSFX
# ---------------------------------------------------------------------------

def _locate_global_fx():
    """Return full monitor-chain fx index, or -1."""
    try:
        master = RPR_GetMasterTrack(-1)
        for i in range(100):
            idx = 0x1000000 + i
            if RPR_TrackFX_GetEnabled(master, idx):
                raw = RPR_TrackFX_GetParam(master, idx, PARAM_JSFX_ID, 0, 0)[0]
                if is_approx(raw, GLOBAL_FX_ID):
                    return idx
    except Exception:
        pass
    return -1


def check_initialized() -> bool:
    """
    Return True if the Global Options FX exists and mmm_ready == 1.
    Prints a helpful message if not.
    """
    fx_loc = _locate_global_fx()
    if fx_loc == -1:
        print("MMM Global Options FX not found on the master monitor chain.\n"
              "Add it there, then run MMM Initialize.\n")
        return False

    master = RPR_GetMasterTrack(0)
    ready  = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_MMM_READY, 0, 0)[0])
    if ready != 1:
        print("MMM is not initialized.\n"
              "Run the 'MMM Initialize' script first (or click Initialize\n"
              "in the Global Options FX).\n")
        return False

    return True


class GlobalOptions:
    def __init__(self):
        self.model_index     = 0
        self.temperature     = 1.0
        self.model_dim       = 4
        self.bars_per_step   = 1
        self.tracks_per_step = 1
        self.sampling_seed   = -1
        self.mask_top_k      = 0
        self.mask_top_p      = 0.0

    def to_gen_dict(self):
        return {
            "temperature"    : self.temperature,
            "model_dim"      : self.model_dim,
            "bars_per_step"  : self.bars_per_step,
            "tracks_per_step": self.tracks_per_step,
            "seed"           : self.sampling_seed,
            "top_k"          : self.mask_top_k,
            "top_p"          : self.mask_top_p,
        }


def get_global_options() -> GlobalOptions:
    opts = GlobalOptions()
    try:
        master = RPR_GetMasterTrack(0)
        if not master:
            return opts
        fx_loc = _locate_global_fx()
        if fx_loc == -1:
            return opts
        opts.model_index     = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_MODEL_INDEX, 0, 0)[0])
        opts.temperature     = float(RPR_TrackFX_GetParam(master, fx_loc, PARAM_TEMPERATURE, 0, 0)[0])
        opts.model_dim       = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_MODEL_DIM,   0, 0)[0])
        opts.bars_per_step   = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_BARS_STEP,   0, 0)[0])
        opts.tracks_per_step = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_TRACKS_STEP, 0, 0)[0])
        opts.sampling_seed   = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_SEED,        0, 0)[0])
        opts.mask_top_k      = int(RPR_TrackFX_GetParam(master, fx_loc, PARAM_TOP_K,       0, 0)[0])
        opts.mask_top_p      = float(RPR_TrackFX_GetParam(master, fx_loc, PARAM_TOP_P,     0, 0)[0])
    except Exception:
        pass
    return opts


# ---------------------------------------------------------------------------
# Track Options FX
# ---------------------------------------------------------------------------

def _locate_track_options_fx(track) -> int:
    try:
        for i in range(RPR_TrackFX_GetCount(track)):
            raw = RPR_TrackFX_GetParam(track, i, 0, 0, 0)[0]
            if is_approx(raw, TRACK_OPTIONS_FX_ID):
                return i
    except Exception:
        pass
    return -1


def _remove_track_options_fx(track):
    for i in range(RPR_TrackFX_GetCount(track) - 1, -1, -1):
        try:
            if is_approx(RPR_TrackFX_GetParam(track, i, 0, 0, 0)[0], TRACK_OPTIONS_FX_ID):
                RPR_TrackFX_Delete(track, i)
        except Exception:
            pass


def _install_track_options_fx(track, schema, restore_values=None) -> int:
    fx_idx = RPR_TrackFX_AddByName(track, TRACK_OPTIONS_FX_NAME, False, -1)
    if fx_idx < 0:
        print(f"  Warning: could not add '{TRACK_OPTIONS_FX_NAME}'\n")
        return -1
    for slot, param_def in enumerate(schema):
        val = float((restore_values or {}).get(slot, param_def.get("default", -1)))
        RPR_TrackFX_SetParam(track, fx_idx, TRACK_OPTIONS_AC_OFFSET + slot, val)
    return fx_idx


# ---------------------------------------------------------------------------
# Chunk-based slider label rewriting
# ---------------------------------------------------------------------------

def _rewrite_jsfx_slider_labels(chunk: str, schema: list) -> str:
    js_block_re = re.compile(
        r'(<JS\s+[^\n]*MMM\s+Track\s+Options[^\n]*\n)(.*?)(>)',
        re.DOTALL | re.IGNORECASE,
    )
    def _rewrite_block(m):
        lines = m.group(2).split('\n')
        new_lines = []
        for line in lines:
            sm = re.match(
                r'^(\s*SLIDER\s+)(\d+)(\s+)([^\s]+)(\s+)([^\s]+)(\s+)([^\s]+)(\s+)(.*)$',
                line,
            )
            if sm:
                ac_index = int(sm.group(2)) - 2
                if 0 <= ac_index < len(schema):
                    p    = schema[ac_index]
                    line = (sm.group(1) + sm.group(2) + sm.group(3) +
                            sm.group(4) + sm.group(5) +
                            str(p.get("min", -1))  + sm.group(7) +
                            str(p.get("max",  64)) + sm.group(9) +
                            p.get("label", f"AC Param {ac_index + 1}"))
            new_lines.append(line)
        return m.group(1) + '\n'.join(new_lines) + m.group(3)
    return js_block_re.sub(_rewrite_block, chunk)


def apply_slider_labels_all_tracks(schema: list):
    updated = 0
    for i in range(RPR_CountTracks(0)):
        track = RPR_GetTrack(0, i)
        if _locate_track_options_fx(track) < 0:
            continue
        ok, chunk = RPR_GetTrackStateChunk(track, "", False)
        if not ok or not chunk:
            continue
        new_chunk = _rewrite_jsfx_slider_labels(chunk, schema)
        if new_chunk != chunk:
            RPR_SetTrackStateChunk(track, new_chunk, False)
            updated += 1
    if updated:
        print(f"Slider labels updated on {updated} track(s).\n")


# ---------------------------------------------------------------------------
# Model switching
# ---------------------------------------------------------------------------

def replace_track_options_fx_all_tracks(schema: list):
    replaced = 0
    for i in range(RPR_CountTracks(0)):
        track  = RPR_GetTrack(0, i)
        fx_loc = _locate_track_options_fx(track)
        if fx_loc < 0:
            continue
        old_values = {}
        for slot in range(TRACK_OPTIONS_MAX_SLOTS):
            try:
                old_values[slot] = RPR_TrackFX_GetParam(
                    track, fx_loc, TRACK_OPTIONS_AC_OFFSET + slot, 0, 0)[0]
            except Exception:
                break
        _remove_track_options_fx(track)
        _install_track_options_fx(track, schema, restore_values=old_values)
        replaced += 1
    if replaced:
        print(f"Replaced Track Options FX on {replaced} track(s).\n")
    apply_slider_labels_all_tracks(schema)


def sync_model_if_needed(proxy, desired_index: int) -> dict:
    """
    Uses ExtState cache. Only hits the server if the model slider changed.
    Guaranteed to only be called after check_initialized() passes, so the
    cache is always warm (MMM_initialize.py populates it).
    """
    cached_ids, cached_labels = get_cached_model_info()

    # Cache is always populated after init -- but guard defensively
    if not cached_ids:
        raise RuntimeError(
            "Model list not in cache. Run MMM Initialize first.")

    model_ids    = cached_ids
    model_labels = cached_labels

    safe_index    = max(0, min(desired_index, len(model_ids) - 1))
    desired_model = model_ids[safe_index]
    cached_id     = _ext_get(EXT_MODEL_ID)
    cached_index  = _ext_get(EXT_MODEL_INDEX)
    model_changed = (cached_id != desired_model or cached_index != str(desired_index))

    if model_changed:
        print(f"Model changed: '{cached_id or 'none'}' -> '{desired_model}'\n")
        schema_info = proxy.set_active_model(desired_model)
        if not schema_info.get("ok"):
            raise RuntimeError(f"set_active_model failed: {schema_info.get('error')}")
        replace_track_options_fx_all_tracks(schema_info.get("ac_schema", []))
        cache_model_info(desired_model, desired_index, model_ids, model_labels)
        print(f"Active model: {schema_info.get('model_label', desired_model)}\n")
    else:
        schema_info = proxy.get_model_schema()
        if not schema_info.get("ok"):
            raise RuntimeError(f"get_model_schema failed: {schema_info.get('error')}")

    return schema_info


# ---------------------------------------------------------------------------
# Per-track AC values
# ---------------------------------------------------------------------------

def get_track_options(schema: list) -> dict:
    track_opts = {}
    for i in range(RPR_CountTracks(0)):
        track  = RPR_GetTrack(0, i)
        fx_loc = _locate_track_options_fx(track)
        if fx_loc < 0:
            continue
        acs = {}
        for slot, param_def in enumerate(schema):
            ac_key  = param_def.get("ac_key")
            default = float(param_def.get("default", -1))
            if not ac_key:
                continue
            try:
                raw = RPR_TrackFX_GetParam(
                    track, fx_loc, TRACK_OPTIONS_AC_OFFSET + slot, 0, 0)[0]
            except Exception:
                continue
            if is_approx(raw, default):
                continue
            acs[ac_key] = _format_ac_value(param_def, raw)
        if acs:
            track_opts[str(i)] = acs
    return track_opts


# ---------------------------------------------------------------------------
# Progress bar
# ---------------------------------------------------------------------------

class ProgressBar:
    WIDTH = 32
    def __init__(self):
        self._prev = ""
    def update(self, pct, msg, elapsed):
        filled = int(self.WIDTH * pct / 100)
        line = (f"[{'#'*filled}{'.'*(self.WIDTH-filled)}]"
                f" {pct:3d}%  {msg}  ({elapsed:.1f}s)")
        if line != self._prev:
            RPR_ShowConsoleMsg("\r" + line)
            self._prev = line
    def finish(self, msg, elapsed):
        RPR_ShowConsoleMsg(f"\r[{'#'*self.WIDTH}] 100%  {msg}  ({elapsed:.1f}s)\n")
    def error(self, msg):
        RPR_ShowConsoleMsg(f"\n  ERROR: {msg}\n")


STATUS_QUEUED  = "queued"
STATUS_RUNNING = "running"
STATUS_DONE    = "done"
STATUS_ERROR   = "error"


# ---------------------------------------------------------------------------
# Result write-back
# ---------------------------------------------------------------------------

def write_masked_result(result_dict: dict, extraction) -> None:
    from midi_extraction import MIDINote, REAPERMIDIWriter
    tpq    = result_dict["tpq"]
    writer = REAPERMIDIWriter(extraction.tempo_map)

    for t_key, measures_dict in result_dict.get("tracks", {}).items():
        track_idx  = int(t_key)
        track_info = extraction.song.get_track_info(track_idx)
        if not track_info:
            continue
        for m_key, notes_list in measures_dict.items():
            measure = extraction.song.get_measure(track_idx, int(m_key))
            if not measure:
                continue
            bpm           = measure.tempo if measure.tempo > 0 else 120.0
            secs_per_tick = 60.0 / (bpm * tpq)
            measure.notes = [
                MIDINote(
                    pitch      = n["pitch"],
                    velocity   = n["velocity"],
                    start_time = n["start_tick"] * secs_per_tick,
                    end_time   = (n["start_tick"] + n["duration_tick"]) * secs_per_tick,
                )
                for n in notes_list
            ]
            take = writer._get_midi_take_for_measure(track_info.track, measure)
            if not take:
                print(f"Warning: no MIDI take for track {track_info.track_name}, "
                      f"measure {measure.measure_number}\n")
                continue
            writer._delete_notes_in_measure(take, measure)
            writer._write_measure_notes(take, measure, notes_are_selected=True)
            RPR_MIDI_Sort(take)


# ---------------------------------------------------------------------------
# Empty bar seeding
# ---------------------------------------------------------------------------

def _seed_empty_masked_bars(extraction) -> list:
    seeded = []
    for track_idx, bar_idx in extraction.masks.to_list():
        measure = extraction.song.get_measure(track_idx, bar_idx)
        if not measure or not measure.is_empty:
            continue
        dur   = measure.end_time - measure.start_time
        pitch = 36 if measure.instrument == 128 else 60
        measure.notes = [MIDINote(pitch=pitch, velocity=1,
                                  start_time=0.0, end_time=max(0.01, dur / 32.0))]
        seeded.append([track_idx, bar_idx])
    return seeded


# ---------------------------------------------------------------------------
# Main workflow
# ---------------------------------------------------------------------------

def run_mmm_infill():
    RPR_ClearConsole()

    # ---- 0. Initialization gate ------------------------------------------ #
    if not check_initialized():
        return   # message already printed

    # ---- 1. Health check ------------------------------------------------- #
    print("Checking MMM server...\n")
    proxy = ServerProxy(SERVER_URL, allow_none=True)
    try:
        srv = proxy.server_status()
    except Exception as e:
        print(f"Cannot reach server at {SERVER_URL}:\n  {e}\n")
        return
    if not srv["model_ready"]:
        print("Server is up but model is not loaded yet.\n")
        return
    queue_depth = srv["queued"] + srv["running"]
    if queue_depth:
        print(f"Note: {queue_depth} job(s) already running/queued.\n")

    # ---- 2. Read global options ------------------------------------------ #
    options = get_global_options()

    # ---- 3. Sync model (server only if slider changed) ------------------- #
    try:
        schema_info = sync_model_if_needed(proxy, options.model_index)
    except Exception as e:
        print(f"Model sync failed: {e}\n")
        return

    ac_schema     = schema_info.get("ac_schema", [])
    seeded_bar_ac = schema_info.get("seeded_bar_ac", {})

    # ---- 4. Read per-track AC values ------------------------------------- #
    per_track_acs = get_track_options(ac_schema)
    if per_track_acs:
        print("Track attribute controls:")
        for tidx, acs in per_track_acs.items():
            print(f"  Track {tidx}: {acs}")
        print()

    # ---- 5. Extract MIDI ------------------------------------------------- #
    print("Extracting MIDI from REAPER...\n")
    try:
        extraction = extract_midi_for_mmm(
            mask_selected_items=True,
            mask_empty_items=False,
        )
    except Exception:
        print(f"Extraction failed:\n{traceback.format_exc()}\n")
        return
    if extraction.song.num_measures == 0:
        print("No MIDI found in selection.\n")
        return
    if extraction.masks.count == 0:
        print("No measures to infill -- select some MIDI items first.\n")
        return
    print(f"Tracks   : {extraction.song.num_tracks}")
    print(f"Measures : {extraction.start_measure}-{extraction.end_measure}")
    print(f"Masked   : {extraction.masks.count} (track, bar) positions\n")

    # ---- 6. Seed empty bars ---------------------------------------------- #
    seeded_positions = _seed_empty_masked_bars(extraction)
    if seeded_positions:
        print(f"Seeded {len(seeded_positions)} empty bar(s) with placeholder notes.\n")

    # ---- 7. Submit job --------------------------------------------------- #
    print("Submitting job to MMM server...\n")
    try:
        job_id = proxy.submit_job(
            extraction.song.to_dict(),
            extraction.masks.to_list(),
            extraction.skips.to_list(),
            extraction.ignore,
            extraction.autoregressive,
            options.to_gen_dict(),
            per_track_acs,
            seeded_positions,
            seeded_bar_ac,
            extraction.start_measure,
            extraction.end_measure,
        )
    except Exception as e:
        print(f"Submission failed: {e}\n")
        return
    print(f"Job ID: {job_id}\n")

    # ---- 8. Poll --------------------------------------------------------- #
    pb = ProgressBar()
    while True:
        try:
            poll = proxy.get_job_status(job_id)
        except Exception as e:
            print(f"\nPolling error: {e}\n")
            time.sleep(POLL_INTERVAL)
            continue
        status  = poll["status"]
        elapsed = poll["elapsed"]
        if status in (STATUS_QUEUED, STATUS_RUNNING):
            pb.update(poll["progress"], poll["message"], elapsed)
            time.sleep(POLL_INTERVAL)
        elif status == STATUS_DONE:
            pb.finish("Finished", elapsed)
            break
        elif status == STATUS_ERROR:
            pb.error(poll.get("error", "Unknown error"))
            return
        else:
            print(f"\nUnexpected status '{status}' -- aborting.\n")
            return

    # ---- 9. Retrieve result ---------------------------------------------- #
    try:
        response = proxy.get_job_result(job_id)
    except Exception as e:
        print(f"Could not retrieve result: {e}\n")
        return
    if not response["ok"]:
        print(f"Generation failed: {response['error']}\n")
        return

    # ---- 10. Write back -------------------------------------------------- #
    print("Writing generated MIDI to REAPER...\n")
    try:
        write_masked_result(response["result"], extraction)
    except Exception:
        print(f"Write-back failed:\n{traceback.format_exc()}\n")
        return
    print("Done.\n")
    RPR_Undo_OnStateChange("MMM Infill")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_mmm_infill()