# -*- coding: utf-8 -*-
"""
MMM_initialize.py  --  One-time MMM setup script

Run this once after loading a project (or after starting the server).
It contacts the server, fetches the model list, rewrites the Model dropdown
in MMM Global Options.js with real names, and sets the Status slider to Ready.

After this runs, MMM_infill.py works without contacting the server on every
run (it uses REAPER's ExtState cache).

Assign to a toolbar button or keyboard shortcut for easy access.
"""

import os
import re
import sys
import json
from xmlrpc.client import ServerProxy

from reaper_python import *


# ---------------------------------------------------------------------------
# Config  (must match REAPER_mmm_infill.py)
# ---------------------------------------------------------------------------

SERVER_URL        = "http://127.0.0.1:3456"
GLOBAL_FX_ID      = 54964318
GLOBAL_FX_JS_PATH = "Effects/MMM/MMM Global Options.js"

# Param offsets inside Global Options JSFX
PARAM_JSFX_ID     = 0   # slider1 -- sentinel, never changes
PARAM_MMM_READY   = 1   # slider2 -- 0=not ready, 1=ready
PARAM_DO_INIT     = 2   # slider3 -- initialize trigger button
PARAM_MODEL_INDEX = 3   # slider4 -- model dropdown

# ExtState  (must match REAPER_mmm_infill.py)
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


def _ext_set(key, value):
    RPR_SetExtState(EXT_SECTION, key, str(value), True)


def _locate_global_fx():
    """Return (master_track, fx_full_index) or (None, -1)."""
    try:
        master = RPR_GetMasterTrack(-1)
        for i in range(100):
            idx = 0x1000000 + i
            if RPR_TrackFX_GetEnabled(master, idx):
                raw = RPR_TrackFX_GetParam(master, idx, PARAM_JSFX_ID, 0, 0)[0]
                if is_approx(raw, GLOBAL_FX_ID):
                    return master, idx
    except Exception:
        pass
    return None, -1


def _global_fx_js_path():
    return os.path.join(RPR_GetResourcePath(), GLOBAL_FX_JS_PATH)


# ---------------------------------------------------------------------------
# Dropdown rewrite
# ---------------------------------------------------------------------------

def rewrite_model_dropdown(model_labels: list, current_index: int) -> bool:
    """
    Rewrite slider4 in MMM Global Options.js so it shows a real enum dropdown.
    e.g.: slider4:model_index=0<0,1,1{Density+Poly,Tension}>Model
    """
    js_path = _global_fx_js_path()
    if not os.path.isfile(js_path):
        print(f"ERROR: Cannot find Global Options JSFX at:\n  {js_path}\n"
              f"Make sure the file is in your REAPER Effects folder.\n")
        return False

    with open(js_path, "r", encoding="utf-8") as f:
        source = f.read()

    n          = len(model_labels)
    safe_index = max(0, min(current_index, n - 1))
    enum_str   = ",".join(model_labels)
    new_slider = (
        f"slider4:model_index={safe_index}"
        f"<0,{n - 1},1{{{enum_str}}}>Model"
    )

    new_source, count = re.subn(
        r'^slider4:model_index=.*$',
        new_slider,
        source,
        flags=re.MULTILINE,
    )

    if count == 0:
        print("ERROR: slider4 line not found in Global Options JSFX.\n")
        return False

    if new_source == source:
        return True  # already correct

    with open(js_path, "w", encoding="utf-8") as f:
        f.write(new_source)

    return True


# ---------------------------------------------------------------------------
# FX reload (to pick up the rewritten .js)
# ---------------------------------------------------------------------------

def reload_global_options_fx(master, fx_loc: int, current_index: int):
    """
    Remove and re-add the Global Options FX so REAPER re-reads the .js file.
    Restores all param values; sets mmm_ready=1 and the correct model_index.
    """
    # Snapshot all params
    saved = []
    for p in range(12):   # slider1..slider11 = params 0..10, +1 spare
        try:
            saved.append(RPR_TrackFX_GetParam(master, fx_loc, p, 0, 0)[0])
        except Exception:
            saved.append(0.0)

    chain_pos = fx_loc - 0x1000000
    RPR_TrackFX_Delete(master, fx_loc)

    # Re-add to monitor chain at same position
    # recFX=True targets the monitor/hardware-out chain on master
    new_idx = RPR_TrackFX_AddByName(master, "MMM Global Options", True, chain_pos)
    if new_idx < 0:
        new_idx = RPR_TrackFX_AddByName(master, "MMM Global Options", True, -1)

    if new_idx < 0:
        print("Warning: could not re-add Global Options FX after reload.\n"
              "Close and reopen the FX chain to see the updated dropdown.\n")
        return

    actual = 0x1000000 + (new_idx if new_idx < 0x1000000 else new_idx - 0x1000000)

    # Restore params, then override ready=1 and model_index
    for p, val in enumerate(saved):
        try:
            RPR_TrackFX_SetParam(master, actual, p, val)
        except Exception:
            pass

    RPR_TrackFX_SetParam(master, actual, PARAM_MMM_READY,   1.0)
    RPR_TrackFX_SetParam(master, actual, PARAM_DO_INIT,      0.0)  # reset button
    RPR_TrackFX_SetParam(master, actual, PARAM_MODEL_INDEX, float(current_index))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_initialize():
    RPR_ClearConsole()
    print("MMM Initialize\n" + "=" * 40 + "\n")

    # ---- Contact server --------------------------------------------------
    print("Connecting to MMM server...\n")
    proxy = ServerProxy(SERVER_URL, allow_none=True)
    try:
        srv = proxy.server_status()
    except Exception as e:
        print(f"Cannot reach server at {SERVER_URL}:\n  {e}\n\n"
              f"Make sure MMM_server.py is running before initializing.\n")
        return

    if not srv["model_ready"]:
        print("Server is running but model is not loaded yet.\n"
              "Wait a moment and try again.\n")
        return

    print(f"Server OK  |  active model: {srv.get('active_model', '?')}\n")

    # ---- Fetch model list ------------------------------------------------
    try:
        result = proxy.list_models()
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "list_models failed"))
    except Exception as e:
        print(f"Failed to fetch model list: {e}\n")
        return

    models       = result["models"]
    model_ids    = [m["id"]    for m in models]
    model_labels = [m["label"] for m in models]
    active_id    = result.get("active_model", model_ids[0] if model_ids else "")

    try:
        current_index = model_ids.index(active_id)
    except ValueError:
        current_index = 0

    print(f"Models found: {len(model_ids)}\n")
    for i, (mid, mlabel) in enumerate(zip(model_ids, model_labels)):
        marker = " <-- active" if mid == active_id else ""
        print(f"  [{i}] {mlabel}{marker}\n")
    print()

    # ---- Rewrite dropdown in .js file ------------------------------------
    print("Writing model dropdown to Global Options JSFX...\n")
    ok = rewrite_model_dropdown(model_labels, current_index)
    if not ok:
        return

    # ---- Find Global Options FX and reload it ----------------------------
    master, fx_loc = _locate_global_fx()
    if fx_loc == -1:
        print("Warning: Global Options FX not found on master monitor chain.\n"
              "Add 'MMM Global Options' to the master track's monitor FX chain,\n"
              "then run Initialize again.\n")
        # Still save the ExtState so infill works if it's added later
    else:
        print("Reloading Global Options FX to apply dropdown...\n")
        reload_global_options_fx(master, fx_loc, current_index)

    # ---- Fetch schema for the active model and apply track labels ---------
    try:
        schema_info = proxy.get_model_schema()
        if schema_info.get("ok"):
            ac_schema = schema_info.get("ac_schema", [])
            _apply_track_labels_all(ac_schema)
    except Exception:
        pass   # non-fatal, infill script will handle this on first run

    # ---- Persist to ExtState cache ---------------------------------------
    _ext_set(EXT_MODEL_ID,     active_id)
    _ext_set(EXT_MODEL_INDEX,  str(current_index))
    _ext_set(EXT_MODEL_IDS,    json.dumps(model_ids))
    _ext_set(EXT_MODEL_LABELS, json.dumps(model_labels))

    print("Initialization complete.\n"
          "The Model dropdown is now active in MMM Global Options.\n")


# ---------------------------------------------------------------------------
# Apply track slider labels (mirrors infill script logic)
# ---------------------------------------------------------------------------

TRACK_OPTIONS_FX_ID     = 349583099
TRACK_OPTIONS_AC_OFFSET = 1


def _apply_track_labels_all(schema: list):
    """Rewrite Track Options slider labels in any track that has the plugin."""
    num_tracks = RPR_CountTracks(0)
    updated = 0
    for i in range(num_tracks):
        track = RPR_GetTrack(0, i)
        # Detect Track Options FX
        has_fx = False
        for j in range(RPR_TrackFX_GetCount(track)):
            try:
                raw = RPR_TrackFX_GetParam(track, j, 0, 0, 0)[0]
                if is_approx(raw, TRACK_OPTIONS_FX_ID):
                    has_fx = True
                    break
            except Exception:
                pass
        if not has_fx:
            continue

        ok, chunk = RPR_GetTrackStateChunk(track, "", False)
        if not ok or not chunk:
            continue

        new_chunk = _rewrite_jsfx_slider_labels(chunk, schema)
        if new_chunk != chunk:
            RPR_SetTrackStateChunk(track, new_chunk, False)
            updated += 1

    if updated:
        print(f"Track Options slider labels updated on {updated} track(s).\n")


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
                slot_1based = int(sm.group(2))
                ac_index    = slot_1based - 2
                if 0 <= ac_index < len(schema):
                    p = schema[ac_index]
                    line = (sm.group(1) + sm.group(2) + sm.group(3) +
                            sm.group(4) + sm.group(5) +
                            str(p.get("min", -1))  + sm.group(7) +
                            str(p.get("max",  64)) + sm.group(9) +
                            p.get("label", f"AC Param {ac_index + 1}"))
            new_lines.append(line)
        return m.group(1) + '\n'.join(new_lines) + m.group(3)

    return js_block_re.sub(_rewrite_block, chunk)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_initialize()