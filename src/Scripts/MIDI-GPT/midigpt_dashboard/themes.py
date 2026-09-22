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
"""

from reaper_python import *

import imgui

EXT_STATE_SECTION = "MIDI-GPT"
EXT_STATE_KEY = "theme"
DEFAULT_THEME = "Dark"


def _rgba(r, g, b, a=0xFF):
    return (r << 24) | (g << 16) | (b << 8) | a


def _adjust(color, delta):
    """Lighten (delta > 0) or darken (delta < 0) an RRGGBBAA color by delta
    per channel (roughly -255..255); alpha untouched."""
    r, g, b, a = (color >> 24) & 0xFF, (color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF
    clamp = lambda v: max(0, min(255, v + delta))
    return _rgba(clamp(r), clamp(g), clamp(b), a)


THEMES = {
    "Dark": {
        "bg": _rgba(0x1E, 0x1F, 0x22), "panel_bg": _rgba(0x26, 0x28, 0x2B),
        "border": _rgba(0x3A, 0x3D, 0x42), "text": _rgba(0xE6, 0xE6, 0xE6),
        "text_disabled": _rgba(0x8A, 0x8D, 0x93), "frame_bg": _rgba(0x33, 0x36, 0x3A),
        # Muted brick red -- the same family as the app's existing
        # selected-candidate/Cancel red (0x992E2EFF), softened so every
        # checkbox/tab/slider doesn't read as a warning; that fully-
        # saturated red stays reserved for those explicit danger buttons.
        "accent": _rgba(0xC2, 0x55, 0x4D),
    },
    "Light": {
        "bg": _rgba(0xF3, 0xF3, 0xF1), "panel_bg": _rgba(0xFF, 0xFF, 0xFF),
        "border": _rgba(0xD0, 0xD0, 0xCE), "text": _rgba(0x1A, 0x1A, 0x1A),
        "text_disabled": _rgba(0x8A, 0x8A, 0x88), "frame_bg": _rgba(0xE8, 0xE8, 0xE6),
        "accent": _rgba(0xB3, 0x3A, 0x33),
    },
    "Midnight": {
        "bg": _rgba(0x14, 0x14, 0x1C), "panel_bg": _rgba(0x1C, 0x1C, 0x28),
        "border": _rgba(0x33, 0x33, 0x4A), "text": _rgba(0xE0, 0xE0, 0xF0),
        "text_disabled": _rgba(0x83, 0x83, 0x9C), "frame_bg": _rgba(0x24, 0x24, 0x38),
        "accent": _rgba(0x7C, 0x6F, 0xF0),  # violet, distinct from the brand red
    },
    "Solarized": {
        "bg": _rgba(0x0B, 0x2B, 0x33), "panel_bg": _rgba(0x12, 0x36, 0x40),
        "border": _rgba(0x1F, 0x46, 0x50), "text": _rgba(0xE6, 0xDC, 0xC6),
        "text_disabled": _rgba(0x7A, 0x91, 0x99), "frame_bg": _rgba(0x16, 0x3B, 0x45),
        "accent": _rgba(0xC9, 0xA2, 0x27),  # warm amber/gold
    },
    "Forest": {
        "bg": _rgba(0x16, 0x1C, 0x18), "panel_bg": _rgba(0x1E, 0x26, 0x20),
        "border": _rgba(0x35, 0x44, 0x3A), "text": _rgba(0xE2, 0xEC, 0xE4),
        "text_disabled": _rgba(0x89, 0x98, 0x8C), "frame_bg": _rgba(0x28, 0x35, 0x2C),
        "accent": _rgba(0x4C, 0xAF, 0x6D),  # fresh emerald
    },
    "Ocean": {
        "bg": _rgba(0x0B, 0x16, 0x22), "panel_bg": _rgba(0x11, 0x20, 0x2F),
        "border": _rgba(0x22, 0x34, 0x47), "text": _rgba(0xE3, 0xEE, 0xF7),
        "text_disabled": _rgba(0x7E, 0x93, 0xA6), "frame_bg": _rgba(0x16, 0x29, 0x3A),
        "accent": _rgba(0x35, 0xB3, 0xC7),  # teal/cyan
    },
    # Modeled on metacreation.net's own branding: light, minimalist,
    # cool-toned academic look -- white/off-white with charcoal text and a
    # navy-blue accent (their logo/graphics color), not the moody dark
    # palettes above.
    "Metacreation": {
        "bg": _rgba(0xF7, 0xF8, 0xFA), "panel_bg": _rgba(0xFF, 0xFF, 0xFF),
        "border": _rgba(0xD8, 0xDC, 0xE2), "text": _rgba(0x1C, 0x23, 0x2B),
        "text_disabled": _rgba(0x84, 0x8E, 0x99), "frame_bg": _rgba(0xED, 0xEF, 0xF3),
        "accent": _rgba(0x1F, 0x3F, 0x66),  # navy blue
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


def _palette(roles):
    frame, accent, panel = roles["frame_bg"], roles["accent"], roles["panel_bg"]
    tab = frame
    return {
        imgui.Col_Text(): roles["text"],
        imgui.Col_TextDisabled(): roles["text_disabled"],
        imgui.Col_TextLink(): accent,
        imgui.Col_WindowBg(): roles["bg"],
        imgui.Col_ChildBg(): panel,
        imgui.Col_PopupBg(): panel,
        imgui.Col_Border(): roles["border"],
        imgui.Col_FrameBg(): frame,
        imgui.Col_FrameBgHovered(): _adjust(frame, 20),
        imgui.Col_FrameBgActive(): _adjust(frame, 35),
        imgui.Col_TitleBg(): panel,
        imgui.Col_TitleBgActive(): _adjust(panel, 10),
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
        imgui.Col_SeparatorHovered(): accent,
        imgui.Col_SeparatorActive(): accent,
        imgui.Col_Tab(): tab,
        imgui.Col_TabHovered(): _adjust(tab, 25),
        imgui.Col_TabSelected(): _adjust(tab, 15),
        imgui.Col_TabSelectedOverline(): accent,
        imgui.Col_TabDimmed(): _adjust(tab, -10),
        imgui.Col_TabDimmedSelected(): tab,
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
