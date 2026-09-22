"""Hover-hint ("hint mode") support: a JSON-backed tooltip system, toggled
on/off from the Settings popup (settings_panel.py). Off by default; once
on, hovering any wired-up control for a moment shows a plain-English
explanation of what it does, sourced from hints.json so the wording can be
edited/extended without touching any Python. A missing key is expected
(hints.json is a living first draft, not a complete set) and is just a
silent no-op, never an error.

Persisted globally via REAPER's ExtState (not per-project -- this is a UI
preference, not a generation parameter), same mechanism as the server URL
in MIDI-GPT Generate.py.
"""

import json
import os

from reaper_python import *

import imgui

EXT_STATE_SECTION = "MIDI-GPT"
EXT_STATE_KEY = "hints_enabled"

_HINTS_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hints.json")
_hints = None
_enabled = None


def _load():
    global _hints
    if _hints is None:
        try:
            with open(_HINTS_PATH, "r", encoding="utf-8") as f:
                _hints = json.load(f)
        except Exception:
            _hints = {}
    return _hints


def enabled():
    global _enabled
    if _enabled is None:
        _enabled = (RPR_GetExtState(EXT_STATE_SECTION, EXT_STATE_KEY) or "") == "1"
    return _enabled


def set_enabled(value):
    global _enabled
    _enabled = bool(value)
    RPR_SetExtState(EXT_STATE_SECTION, EXT_STATE_KEY, "1" if _enabled else "0", True)


def text(key, **kwargs):
    """The formatted hint text for `key` (kwargs fill in its {placeholder}s,
    e.g. text("generation.batch_candidate", index=3)), or None if hint mode
    is off or `key` has no entry yet."""
    if not enabled():
        return None
    template = _load().get(key)
    if not template:
        return None
    try:
        return template.format(**kwargs)
    except Exception:
        # A placeholder the caller didn't supply, or a stray {} in hand-
        # edited JSON -- show the raw template rather than nothing.
        return template


def show(ctx, key, **kwargs):
    """Attach `key`'s hint as a tooltip on the item just drawn, if hint
    mode is on and that key has an entry -- safe to call unconditionally
    after every widget, wired or not yet wired in hints.json."""
    resolved = text(key, **kwargs)
    if resolved:
        imgui.SetItemTooltip(ctx, resolved)
