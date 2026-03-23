# -*- coding: utf-8 -*-
"""
REAPER_mmm_infill.py  --  REAPER-side MIDI-GPT client

On every run:
  1. Call get_model_schema() -- returns ac_schema, track_fx_id
  2. Use track_fx_id to find the correct Track Options JSFX on each track
  3. Read AC values from those sliders according to ac_schema
  4. Submit infill job

Model is set server-side at startup via model_config.json.
"""

import sys
import time
import traceback
from xmlrpc.client import ServerProxy

from reaper_python import *
from midi_extraction import (
    extract_midi_for_mmm,
    MIDISongByMeasure,
    MIDIMeasure,
)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SERVER_URL    = "http://127.0.0.1:3456"
POLL_INTERVAL = 0.1

GLOBAL_FX_ID = 54964318

# AC param slots in Track Options JSFX start at param offset 1
# (offset 0 is always the jsfx_id sentinel)
TRACK_OPTIONS_AC_OFFSET = 1


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
    """Convert raw slider float to the AC string the server expects."""
    fmt = schema_param.get("format", "int")
    if fmt == "float":
        return str(float(raw_value))
    return str(int(round(raw_value)))


# ---------------------------------------------------------------------------
# Global Options JSFX
# ---------------------------------------------------------------------------

class GlobalOptions:
    def __init__(self):
        self.temperature          = 1.0
        self.model_dim            = 4
        self.bars_per_step        = 1
        self.tracks_per_step      = 1
        self.mask_top_k           = 0.0
        self.polyphony_hard_limit = 0

    def to_gen_dict(self) -> dict:
        # Clamp bars_per_step to model_dim (protobuf constraint)
        bps = min(self.bars_per_step, self.model_dim)
        d = {
            "temperature"    : self.temperature,
            "model_dim"      : self.model_dim,
            "bars_per_step"  : bps,
            "tracks_per_step": self.tracks_per_step,
        }
        if self.mask_top_k > 0:
            d["mask_top_k"] = self.mask_top_k
        if self.polyphony_hard_limit > 0:
            d["polyphony_hard_limit"] = self.polyphony_hard_limit
        return d


def _locate_global_fx() -> int:
    """Find Global Options FX on master monitor chain. Returns full index or -1."""
    try:
        master = RPR_GetMasterTrack(0)
        for i in range(100):
            idx = 0x1000000 + i
            if RPR_TrackFX_GetEnabled(master, idx):
                raw = RPR_TrackFX_GetParam(master, idx, 0, 0, 0)[0]
                if is_approx(raw, GLOBAL_FX_ID):
                    return idx
    except Exception:
        pass
    return -1


def get_global_options() -> GlobalOptions:
    opts = GlobalOptions()
    try:
        master = RPR_GetMasterTrack(0)
        if not master:
            return opts
        fx_loc = _locate_global_fx()
        if fx_loc == -1:
            return opts
        # param 0 = jsfx_id
        # param 1 = temperature        (slider2)
        # param 2 = model_dim           (slider3)
        # param 3 = bars_per_step       (slider4)
        # param 4 = tracks_per_step     (slider5)
        # param 5 = mask_top_k          (slider6)
        # param 6 = polyphony_hard_limit(slider7)
        opts.temperature          = float(RPR_TrackFX_GetParam(master, fx_loc, 1, 0, 0)[0])
        opts.model_dim            = int(RPR_TrackFX_GetParam(master, fx_loc, 2, 0, 0)[0])
        opts.bars_per_step        = int(RPR_TrackFX_GetParam(master, fx_loc, 3, 0, 0)[0])
        opts.tracks_per_step      = int(RPR_TrackFX_GetParam(master, fx_loc, 4, 0, 0)[0])
        opts.mask_top_k           = float(RPR_TrackFX_GetParam(master, fx_loc, 5, 0, 0)[0])
        opts.polyphony_hard_limit = int(RPR_TrackFX_GetParam(master, fx_loc, 6, 0, 0)[0])
    except Exception:
        pass
    return opts


# ---------------------------------------------------------------------------
# Track Options JSFX  (schema-driven, id-matched)
# ---------------------------------------------------------------------------

def _locate_track_options_fx(track, track_fx_id: float) -> int:
    """
    Find the Track Options JSFX for the active model on this track.
    Matches by jsfx_id sentinel at param 0. Returns fx_index or -1.
    """
    try:
        for i in range(RPR_TrackFX_GetCount(track)):
            raw = RPR_TrackFX_GetParam(track, i, 0, 0, 0)[0]
            if is_approx(raw, track_fx_id):
                return i
    except Exception:
        pass
    return -1


def get_track_options(ac_schema: list, track_fx_id: float):
    """
    Read AC values and per-track behavior flags from every track that has
    the correct Track Options plugin.

    Returns a 3-tuple:
        per_track_acs       : {str(track_idx): {ac_key: formatted_value}}
        autoregressive_tracks: [track_idx, ...]
        ignore_tracks        : [track_idx, ...]
    """
    track_opts         = {}
    autoregressive_tracks = []
    ignore_tracks      = []

    for i in range(RPR_CountTracks(0)):
        track  = RPR_GetTrack(0, i)
        fx_loc = _locate_track_options_fx(track, track_fx_id)
        if fx_loc < 0:
            continue

        # -- Schema-driven AC params ------------------------------------------
        acs = {}
        for slot, param_def in enumerate(ac_schema):
            ac_key  = param_def.get("ac_key")
            default = float(param_def.get("default", 0))
            if not ac_key:
                continue
            try:
                raw = RPR_TrackFX_GetParam(
                    track, fx_loc, TRACK_OPTIONS_AC_OFFSET + slot, 0, 0)[0]
            except Exception:
                continue
            if is_approx(raw, default):
                continue    # "no preference" -- omit from AC dict
            acs[ac_key] = _format_ac_value(param_def, raw)

        if acs:
            track_opts[str(i)] = acs

        post_ac_idx = len(ac_schema) - 1

        # -- Fixed behavior flags (autoregressive / ignore) -------------------
        try:
            ar_raw = RPR_TrackFX_GetParam(
                track, fx_loc, TRACK_OPTIONS_AC_OFFSET + post_ac_idx + 1, 0, 0)[0]
            if round(ar_raw):
                autoregressive_tracks.append(i)
            ign_raw = RPR_TrackFX_GetParam(
                track, fx_loc, TRACK_OPTIONS_AC_OFFSET + post_ac_idx + 2, 0, 0)[0]
            if round(ign_raw):
                ignore_tracks.append(i)
        except Exception:
            pass

    return track_opts, autoregressive_tracks, ignore_tracks


# ---------------------------------------------------------------------------
# Progress bar
# ---------------------------------------------------------------------------

class ProgressBar:
    WIDTH = 32

    def __init__(self):
        self._prev = ""

    def update(self, pct, msg, elapsed):
        filled = int(self.WIDTH * pct / 100)
        line   = (f"[{'#'*filled}{'.'*(self.WIDTH-filled)}]"
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
# Main workflow
# ---------------------------------------------------------------------------

def run_mmm_infill():
    RPR_ClearConsole()
    proxy = ServerProxy(SERVER_URL, allow_none=True)

    # ---- 0. Health check ------------------------------------------------- #
    print("Checking MIDI-GPT server...\n")
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

    # ---- 1. Fetch model schema ------------------------------------------- #
    try:
        schema = proxy.get_model_schema()
        if not schema.get("ok"):
            raise RuntimeError(schema.get("error", "get_model_schema failed"))
    except Exception as e:
        print(f"Failed to fetch model schema: {e}\n")
        return

    ac_schema   = schema["ac_schema"]
    track_fx_id = float(schema["track_fx_id"])

    print(f"Active model : {schema['model_label']}\n")

    # ---- 2. Read global options ------------------------------------------ #
    options = get_global_options()
    print(f"Global options:")
    print(f"  Polyphony limit : {options.polyphony_hard_limit if options.polyphony_hard_limit > 0 else 'disabled'}\n")

    # ---- 3. Read per-track AC values ------------------------------------- #
    per_track_acs, autoregressive_tracks, ignore_tracks = get_track_options(ac_schema, track_fx_id)
    if per_track_acs:
        print("Track attribute controls:")
        for tidx, acs in per_track_acs.items():
            print(f"  Track {tidx}: {acs}")
        print()
    if autoregressive_tracks:
        print(f"Autoregressive tracks : {autoregressive_tracks}")
    if ignore_tracks:
        print(f"Ignored tracks        : {ignore_tracks}")
    if autoregressive_tracks or ignore_tracks:
        print()

    # ---- 4. Extract MIDI ------------------------------------------------- #
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

    # ---- 5. Submit job --------------------------------------------------- #
    print("Submitting job to MIDI-GPT server...\n")
    try:
        job_id = proxy.submit_job(
            extraction.song.to_dict(),
            extraction.masks.to_list(),
            extraction.skips.to_list(),
            ignore_tracks,
            autoregressive_tracks,
            options.to_gen_dict(),
            per_track_acs,
            extraction.start_measure,
            extraction.end_measure,
        )
    except Exception as e:
        print(f"Submission failed: {e}\n")
        return

    print(f"Job ID: {job_id}\n")

    TIMEOUT_NO_RESPONSE = 10.0  # seconds

    # ---- 6. Poll --------------------------------------------------------- #
    pb = ProgressBar()
    last_response_t = time.monotonic()

    while True:
        try:
            poll = proxy.get_job_status(job_id)
            last_response_t = time.monotonic()  # successful response
        except Exception as e:
            if time.monotonic() - last_response_t > TIMEOUT_NO_RESPONSE:
                pb.error("No response from server for 10s (assuming STATUS_ERROR)")
                return
            print(f"\nPolling error: {e}\n")
            time.sleep(POLL_INTERVAL)
            continue

        status  = poll["status"]
        elapsed = poll["elapsed"]

        if status in (STATUS_QUEUED, STATUS_RUNNING):
            pb.update(poll["progress"], poll["message"], elapsed)
            time.sleep(POLL_INTERVAL)

            # extra safety: timeout even without exceptions
            if time.monotonic() - last_response_t > TIMEOUT_NO_RESPONSE:
                pb.error("No response from server for 10s (assuming STATUS_ERROR)")
                return

        elif status == STATUS_DONE:
            pb.finish("Finished", elapsed)
            break

        elif status == STATUS_ERROR:
            pb.error(poll.get("error", "Unknown error"))
            return

        else:
            pb.error(f"Unexpected status '{status}'")
            return

    # ---- 7. Retrieve result ---------------------------------------------- #
    try:
        response = proxy.get_job_result(job_id)
    except Exception as e:
        print(f"Could not retrieve result: {e}\n")
        return

    if not response["ok"]:
        print(f"Generation failed: {response['error']}\n")
        return

    # ---- 8. Write back --------------------------------------------------- #
    print("Writing generated MIDI to REAPER...\n")
    try:
        write_masked_result(response["result"], extraction)
    except Exception:
        print(f"Write-back failed:\n{traceback.format_exc()}\n")
        return

    print("Done.\n")
    RPR_Undo_OnStateChange("MIDI-GPT Infill")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_mmm_infill()
