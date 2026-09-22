"""Color theme support: a small set of named palettes applied to the whole
dashboard once per frame (MIDI-GPT.py's loop()), selectable
from the Settings popup (settings_panel.py). Persisted globally via
REAPER's ExtState (a UI preference, not a generation parameter), same
mechanism as the server URL in MIDI-GPT Generate.py.

Each theme is a handful of "roles" (background, panel, border, text,
accent, ...) rather than the ~30 individual ImGui colors actually needed --
_palette() derives hovered/active/etc. variants from those roles by
brightness, so adding or tweaking a theme means picking a few colors, not
hand-balancing thirty of them.

Every color the dashboard draws -- including the ones other panels reach
for directly (danger/failed button tints, error/warning text, the loading
pulse) -- comes from here, not a hardcoded constant sitting in whichever
panel happens to use it. That's not just tidiness: a color picked once
against the original dark theme (e.g. a bright red readable on a near-
black background) can quietly become illegible once a light theme exists
too (dark red text on white) -- routing everything through per-theme roles
means every theme gets to pick a value that actually works against its own
bg/text, instead of every new theme inheriting whatever the first one
happened to need. accent_text() below (used for the Cancel/failed-
candidate buttons) is the one deliberate exception: those buttons push a
fixed near-white text color over their own danger/failed fill regardless
of theme, since white-on-saturated-red/orange reads clearly no matter what
the surrounding theme's normal text color is.
"""

from reaper_python import *

import imgui
import math
import time

EXT_STATE_SECTION = "MIDI-GPT"
EXT_STATE_KEY = "theme"
DEFAULT_THEME = "Dark"

# How fast the in-flight indicator (see pulse_color()) pulses, in seconds
# per dim<->bright cycle.
_PULSE_PERIOD = 1.5


def _rgba(r, g, b, a=0xFF):
    return (r << 24) | (g << 16) | (b << 8) | a


def _adjust(color, delta):
    """Lighten (delta > 0) or darken (delta < 0) an RRGGBBAA color by delta
    per channel (roughly -255..255); alpha untouched."""
    r, g, b, a = (color >> 24) & 0xFF, (color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF
    clamp = lambda v: max(0, min(255, v + delta))
    return _rgba(clamp(r), clamp(g), clamp(b), a)


def _lerp(color_a, color_b, t):
    """Blend two RRGGBBAA colors, t=0 -> color_a, t=1 -> color_b."""
    ar, ag, ab, aa = (color_a >> 24) & 0xFF, (color_a >> 16) & 0xFF, (color_a >> 8) & 0xFF, color_a & 0xFF
    br, bg, bb, ba = (color_b >> 24) & 0xFF, (color_b >> 16) & 0xFF, (color_b >> 8) & 0xFF, color_b & 0xFF
    mix = lambda a, b: int(a + (b - a) * t)
    return _rgba(mix(ar, br), mix(ag, bg), mix(ab, bb), mix(aa, ba))


THEMES = {
    "Dark": {
        "bg": _rgba(0x1E, 0x1F, 0x22), "panel_bg": _rgba(0x26, 0x28, 0x2B),
        "border": _rgba(0x3A, 0x3D, 0x42), "text": _rgba(0xE6, 0xE6, 0xE6),
        "text_disabled": _rgba(0x8A, 0x8D, 0x93), "frame_bg": _rgba(0x33, 0x36, 0x3A),
        # Muted brick red -- the same family as danger/failed below, softened
        # so every checkbox/tab/slider doesn't read as a warning; the fully-
        # saturated tones stay reserved for those explicit danger buttons.
        "accent": _rgba(0xC2, 0x55, 0x4D),
        "accent2": _rgba(0x4E, 0x9C, 0x93),  # muted teal, for links/secondary emphasis
        "danger": _rgba(0x99, 0x2E, 0x2E),  # Cancel / selected-candidate button fill
        "failed": _rgba(0xAA, 0x44, 0x00),  # failed-candidate button fill
        "error": _rgba(0xFF, 0x66, 0x66),  # error text/popups -- bright enough for a dark bg
        "warning": _rgba(0xFF, 0xAA, 0x55),  # warning text/popups
    },
    "Light": {
        "bg": _rgba(0xF3, 0xF3, 0xF1), "panel_bg": _rgba(0xFF, 0xFF, 0xFF),
        "border": _rgba(0xD0, 0xD0, 0xCE), "text": _rgba(0x1A, 0x1A, 0x1A),
        "text_disabled": _rgba(0x8A, 0x8A, 0x88), "frame_bg": _rgba(0xE8, 0xE8, 0xE6),
        "accent": _rgba(0xB3, 0x3A, 0x33),
        "accent2": _rgba(0x2E, 0x8B, 0x84),  # muted teal
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xB8, 0x30, 0x2A),  # darker than Dark's -- needs to read on white
        "warning": _rgba(0xB8, 0x86, 0x0B),  # dark goldenrod -- light amber vanishes on white
    },
    "Midnight": {
        "bg": _rgba(0x14, 0x14, 0x1C), "panel_bg": _rgba(0x1C, 0x1C, 0x28),
        "border": _rgba(0x33, 0x33, 0x4A), "text": _rgba(0xE0, 0xE0, 0xF0),
        "text_disabled": _rgba(0x83, 0x83, 0x9C), "frame_bg": _rgba(0x24, 0x24, 0x38),
        "accent": _rgba(0x7C, 0x6F, 0xF0),  # violet, distinct from the brand red
        "accent2": _rgba(0x5F, 0xD0, 0xD8),  # soft cyan, stays in the cool "night" family
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xFF, 0x66, 0x66),
        "warning": _rgba(0xFF, 0xAA, 0x55),
    },
    "Solarized": {
        "bg": _rgba(0x0B, 0x2B, 0x33), "panel_bg": _rgba(0x12, 0x36, 0x40),
        "border": _rgba(0x1F, 0x46, 0x50), "text": _rgba(0xE6, 0xDC, 0xC6),
        "text_disabled": _rgba(0x7A, 0x91, 0x99), "frame_bg": _rgba(0x16, 0x3B, 0x45),
        "accent": _rgba(0xC9, 0xA2, 0x27),  # warm amber/gold
        "accent2": _rgba(0x2A, 0xA1, 0x98),  # the real Solarized palette's own cyan
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xFF, 0x66, 0x66),
        "warning": _rgba(0xFF, 0xAA, 0x55),
    },
    "Forest": {
        "bg": _rgba(0x16, 0x1C, 0x18), "panel_bg": _rgba(0x1E, 0x26, 0x20),
        "border": _rgba(0x35, 0x44, 0x3A), "text": _rgba(0xE2, 0xEC, 0xE4),
        "text_disabled": _rgba(0x89, 0x98, 0x8C), "frame_bg": _rgba(0x28, 0x35, 0x2C),
        "accent": _rgba(0x4C, 0xAF, 0x6D),  # fresh emerald
        "accent2": _rgba(0xD4, 0xA0, 0x17),  # warm gold, complements the green
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xFF, 0x66, 0x66),
        "warning": _rgba(0xFF, 0xAA, 0x55),
    },
    "Ocean": {
        "bg": _rgba(0x0B, 0x16, 0x22), "panel_bg": _rgba(0x11, 0x20, 0x2F),
        "border": _rgba(0x22, 0x34, 0x47), "text": _rgba(0xE3, 0xEE, 0xF7),
        "text_disabled": _rgba(0x7E, 0x93, 0xA6), "frame_bg": _rgba(0x16, 0x29, 0x3A),
        "accent": _rgba(0x35, 0xB3, 0xC7),  # teal/cyan
        "accent2": _rgba(0xE8, 0x83, 0x6B),  # warm coral, complements the teal
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xFF, 0x66, 0x66),
        "warning": _rgba(0xFF, 0xAA, 0x55),
    },
    # Metacreation Lab's official social media guidelines: #EB1C3B, black,
    # white, #279497 -- light/white base, black text, brand red as the
    # primary accent (matches the same red already used everywhere else in
    # the project -- README badges, docs/index.html's --accent), brand
    # teal as the secondary accent.
    "Metacreation": {
        "bg": _rgba(0xF7, 0xF7, 0xF7), "panel_bg": _rgba(0xFF, 0xFF, 0xFF),
        "border": _rgba(0xDD, 0xDD, 0xDD), "text": _rgba(0x00, 0x00, 0x00),
        "text_disabled": _rgba(0x8A, 0x8A, 0x8A), "frame_bg": _rgba(0xED, 0xED, 0xED),
        "accent": _rgba(0xEB, 0x1C, 0x3B),  # official brand red
        "accent2": _rgba(0x27, 0x94, 0x97),  # official brand teal
        "danger": _rgba(0x99, 0x2E, 0x2E),
        "failed": _rgba(0xAA, 0x44, 0x00),
        "error": _rgba(0xB8, 0x30, 0x2A),  # darker -- needs to read on white, like Light's
        "warning": _rgba(0xB8, 0x86, 0x0B),
    },
}

_theme_name = None


def names():
    return list(THEMES.keys())


def current():
    global _theme_name
    if _theme_name is None:
        saved = RPR_GetExtState(EXT_STATE_SECTION, EXT_STATE_KEY)
        _theme_name = saved if saved in THEMES else DEFAULT_THEME
    return _theme_name


def set_current(name):
    global _theme_name
    if name not in THEMES:
        return
    _theme_name = name
    RPR_SetExtState(EXT_STATE_SECTION, EXT_STATE_KEY, name, True)


def _roles():
    return THEMES[current()]


def accent():
    return _roles()["accent"]


def accent2():
    return _roles()["accent2"]


def danger():
    """Button-fill color for Cancel / the selected-candidate slot."""
    return _roles()["danger"]


def failed():
    """Button-fill color for a failed batch-candidate slot -- distinct hue
    from danger() so "this candidate errored" doesn't read as "this is
    selected"."""
    return _roles()["failed"]


def error_color():
    """Text/popup color for error messages."""
    return _roles()["error"]


def warning_color():
    """Text/popup color for warning messages (also used for the
    failed-candidates summary line, which is a caution, not a hard error)."""
    return _roles()["warning"]


# Fixed regardless of theme -- see the module docstring for why this is the
# one color that's deliberately NOT theme-sourced.
DANGER_TEXT = _rgba(0xFF, 0xFF, 0xFF)


def pulse_color():
    """An RRGGBBAA int cycling smoothly between the current theme's
    frame_bg and accent, used to animate a frame background as an "it's
    alive" indicator (e.g. the context bar while a generation is in
    flight)."""
    phase = (math.sin(2 * math.pi * time.time() / _PULSE_PERIOD) + 1) / 2
    return _lerp(_roles()["frame_bg"], _roles()["accent"], phase)


def _palette(roles):
    frame, accent, panel = roles["frame_bg"], roles["accent"], roles["panel_bg"]
    tab = frame
    return {
        imgui.Col_Text(): roles["text"],
        imgui.Col_TextDisabled(): roles["text_disabled"],
        imgui.Col_TextLink(): roles["accent2"],
        imgui.Col_WindowBg(): roles["bg"],
        imgui.Col_ChildBg(): panel,
        imgui.Col_PopupBg(): panel,
        imgui.Col_Border(): roles["border"],
        imgui.Col_FrameBg(): frame,
        imgui.Col_FrameBgHovered(): _adjust(frame, 20),
        imgui.Col_FrameBgActive(): _adjust(frame, 35),
        imgui.Col_TitleBg(): panel,
        imgui.Col_TitleBgActive(): _adjust(panel, 10),
        # Never set before -- fell back to ImGui's own default (near-opaque
        # black), which is unreadable under this panel's own black title
        # text on every light theme (Light/Metacreation): black-on-black
        # the instant the dashboard window is collapsed.
        imgui.Col_TitleBgCollapsed(): panel,
        imgui.Col_MenuBarBg(): panel,
        imgui.Col_ScrollbarBg(): panel,
        imgui.Col_ScrollbarGrab(): frame,
        imgui.Col_ScrollbarGrabHovered(): _adjust(frame, 20),
        imgui.Col_ScrollbarGrabActive(): _adjust(frame, 35),
        imgui.Col_CheckMark(): accent,
        imgui.Col_SliderGrab(): accent,
        imgui.Col_SliderGrabActive(): _adjust(accent, 25),
        imgui.Col_Button(): frame,
        imgui.Col_ButtonHovered(): _adjust(frame, 25),
        imgui.Col_ButtonActive(): _adjust(frame, 40),
        imgui.Col_Header(): _adjust(frame, 10),
        imgui.Col_HeaderHovered(): _adjust(frame, 25),
        imgui.Col_HeaderActive(): _adjust(frame, 40),
        imgui.Col_Separator(): roles["border"],
        imgui.Col_SeparatorHovered(): roles["accent2"],
        imgui.Col_SeparatorActive(): roles["accent2"],
        imgui.Col_Tab(): tab,
        imgui.Col_TabHovered(): _adjust(tab, 25),
        imgui.Col_TabSelected(): _adjust(tab, 15),
        imgui.Col_TabSelectedOverline(): roles["accent2"],
        imgui.Col_TabDimmed(): _adjust(tab, -10),
        imgui.Col_TabDimmedSelected(): tab,
        # The context/token progress bar's filled portion -- previously
        # unset, so it rendered in ReaImGui's own unthemed default (a
        # fixed orange/yellow) no matter which theme was active.
        imgui.Col_PlotHistogram(): accent,
        imgui.Col_PlotHistogramHovered(): _adjust(accent, 20),
    }


def push(ctx):
    """Push the current theme's full color palette. Returns the count to
    pass to PopStyleColor -- call once near the very top of the frame
    (before Begin) and pop the same count once at the very end, regardless
    of whether the window was actually visible that frame."""
    palette = _palette(THEMES[current()])
    for idx, color in palette.items():
        imgui.PushStyleColor(ctx, idx, color)
    return len(palette)
