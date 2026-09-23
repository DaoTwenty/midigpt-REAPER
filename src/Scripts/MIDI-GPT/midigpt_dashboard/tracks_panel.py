"""Horizontal mixer-style track panel."""

import sys
import importlib

from reaper_python import *

sys.path.append(RPR_GetResourcePath() + "/Scripts/ReaTeam Extensions/API")
import imgui

# "MIDI-GPT Setup Tracks.py" has a space in its filename, which isn't valid
# `import` statement syntax -- importlib.import_module() takes the literal
# string instead, resolved via the same path-based finder.
setup_tracks = importlib.import_module("MIDI-GPT Setup Tracks")
from midi_extraction import get_instrument_from_track_name

from . import hints
from .constants import NOTE_DURATION_LABELS, NOTE_NAMES, SCALE_LABELS, TRACK_ATTRIBUTE_SUPPORT, value_when_enabled


def _is_drum_track(name):
    """Best-effort drum/melodic guess from the track's current name alone
    -- cheap (no MIDI scan), using the same name rules generation applies
    first (exact GM name, then drum keywords like "kick" or "snare"; see
    get_instrument_from_track_name()). Only used to decide which Core
    controls to show; request-time detection also falls back to the MIDI
    content (channel 10) for names that match nothing, and is
    authoritative regardless of what this guesses."""
    return get_instrument_from_track_name((name or "").strip()) == 128


def draw(ctx, state, model_type="yellow"):
    """Render side-by-side vertical track columns into the current child."""
    imgui.SeparatorText(ctx, "Tracks")
    track_count = RPR_CountTracks(0)
    if track_count == 0:
        imgui.TextDisabled(ctx, "No tracks in this project yet.")
        return

    tracks = []
    for index in range(track_count):
        track = RPR_GetTrack(0, index)
        guid = RPR_GetSetMediaTrackInfo_String(track, "GUID", "", False)[3]
        name = RPR_GetSetMediaTrackInfo_String(track, "P_NAME", "", False)[3]
        tracks.append((guid, name or f"Track {index + 1}", index + 1))

    visible_guids = {guid for guid, _, _ in tracks}
    state.forget_missing_tracks(visible_guids)

    imgui.BeginChild(ctx, "##track_mixer", 0, 0, False)
    try:
        for guid, name, number in tracks:
            settings = state.track(guid)
            role = "drum" if _is_drum_track(name) else "melodic"
            # None = model unknown/no constraint on record -- show every
            # control, unrestricted (see TRACK_ATTRIBUTE_SUPPORT's own
            # docstring in constants.py).
            supported = TRACK_ATTRIBUTE_SUPPORT.get(model_type, {}).get(role)
            imgui.PushID(ctx, guid)
            clipped_name = name if len(name) <= 28 else name[:25] + "..."
            header_y = imgui.GetCursorPosY(ctx)
            available_width, _ = imgui.GetContentRegionAvail(ctx)
            imgui.SetNextItemAllowOverlap(ctx)
            is_expanded, _ = imgui.CollapsingHeader(ctx, f"{number}. {clipped_name}###track_header")

            imgui.SetCursorPosY(ctx, header_y)
            imgui.SetCursorPosX(ctx, max(0.0, available_width - 64.0))
            changed, value = imgui.Checkbox(ctx, "I##ignore", bool(settings["ignore"]))
            hints.show(ctx, "tracks.ignore")
            if changed:
                settings["ignore"] = int(value)
            imgui.SameLine(ctx, 0, 2)
            changed, value = imgui.Checkbox(ctx, "A##autoregressive", bool(settings["autoregressive"]))
            hints.show(ctx, "tracks.autoregressive")
            if changed:
                settings["autoregressive"] = int(value)
            imgui.SetCursorPosY(ctx, header_y + 24.0)
            # SetCursorPosY above moves the cursor down to reserve room for
            # the checkbox row, but when the track is collapsed nothing
            # else gets submitted at/after that position -- ReaImGui warns
            # that the child's content bounds never actually grew to
            # include it ("submit an item e.g. Dummy() afterwards"), which
            # left it relying on undefined behavior to work out how tall
            # this child's content really was.
            imgui.Dummy(ctx, 0, 0)

            if is_expanded:
                if imgui.BeginTabBar(ctx, "TrackSettingsTabs"):
                    if imgui.BeginTabItem(ctx, "Core")[0]:
                        imgui.SeparatorText(ctx, "Core Controls")
                        show_density = supported is None or "density" in supported
                        show_polyphony = supported is None or "polyphony" in supported
                        show_duration = supported is None or "duration" in supported

                        if show_density:
                            changed, value = imgui.Checkbox(ctx, "Limit note density", settings["density_limit_enabled"])
                            hints.show(ctx, "tracks.density_limit_enabled")
                            if changed:
                                settings["density_limit_enabled"] = value
                                if value:
                                    settings["density"] = value_when_enabled("density", settings["density"])
                            imgui.BeginDisabled(ctx, not settings["density_limit_enabled"])
                            changed, value = imgui.SliderInt(ctx, "Max density", settings["density"], 1, 10)
                            hints.show(ctx, "tracks.density_max")
                            if changed:
                                settings["density"] = value
                            imgui.EndDisabled(ctx)
                            if not settings["density_limit_enabled"]:
                                settings["density"] = 0
                                imgui.TextDisabled(ctx, "Note density: Any")

                        if show_polyphony:
                            changed, value = imgui.Checkbox(ctx, "Limit voices", settings["polyphony_limit_enabled"])
                            hints.show(ctx, "tracks.polyphony_limit_enabled")
                            if changed:
                                settings["polyphony_limit_enabled"] = value
                                if value:
                                    settings["min_polyphony_q"] = value_when_enabled("min_polyphony_q", settings["min_polyphony_q"])
                                    settings["max_polyphony_q"] = value_when_enabled("max_polyphony_q", settings["max_polyphony_q"])
                            imgui.BeginDisabled(ctx, not settings["polyphony_limit_enabled"])
                            changed, value = imgui.SliderInt(ctx, "Minimum voices", settings["min_polyphony_q"], 1, 10)
                            hints.show(ctx, "tracks.polyphony_min")
                            if changed:
                                settings["min_polyphony_q"] = value
                            changed, value = imgui.SliderInt(ctx, "Maximum voices", settings["max_polyphony_q"], 1, 10)
                            hints.show(ctx, "tracks.polyphony_max")
                            if changed:
                                settings["max_polyphony_q"] = value
                            imgui.EndDisabled(ctx)
                            if not settings["polyphony_limit_enabled"]:
                                settings["min_polyphony_q"] = 0
                                settings["max_polyphony_q"] = 0
                                imgui.TextDisabled(ctx, "Voice limit: Any")

                        if show_duration:
                            changed, value = imgui.Combo(ctx, "Min duration", settings["min_note_duration_q"], "\0".join(NOTE_DURATION_LABELS) + "\0")
                            hints.show(ctx, "tracks.min_duration")
                            if changed:
                                settings["min_note_duration_q"] = value
                            changed, value = imgui.Combo(ctx, "Max duration", settings["max_note_duration_q"], "\0".join(NOTE_DURATION_LABELS) + "\0")
                            hints.show(ctx, "tracks.max_duration")
                            if changed:
                                settings["max_note_duration_q"] = value

                        if supported is not None:
                            hidden = {"density", "polyphony", "duration"} - supported
                            if hidden:
                                imgui.TextDisabled(
                                    ctx, f"{', '.join(sorted(hidden))} don't apply to {role} tracks on this model."
                                )
                        imgui.EndTabItem(ctx)

                    if imgui.BeginTabItem(ctx, "Pitch")[0]:
                        imgui.SeparatorText(ctx, "Pitch Mask")
                        changed, value = imgui.Combo(ctx, "Mask mode", settings["pitch_mask_mode"], "Off\0Scale\0Pitch Classes\0")
                        hints.show(ctx, "tracks.pitch_mask_mode")
                        if changed:
                            settings["pitch_mask_mode"] = value
                        if settings["pitch_mask_mode"] == 1:
                            changed, value = imgui.Combo(ctx, "Root", settings["pitch_mask_root"], "\0".join(NOTE_NAMES) + "\0")
                            hints.show(ctx, "tracks.pitch_mask_root")
                            if changed:
                                settings["pitch_mask_root"] = value
                            scale_index = SCALE_LABELS.index(settings["pitch_mask_scale"]) if settings["pitch_mask_scale"] in SCALE_LABELS else 0
                            changed, value = imgui.Combo(ctx, "Scale", scale_index, "\0".join(SCALE_LABELS) + "\0")
                            hints.show(ctx, "tracks.pitch_mask_scale")
                            if changed:
                                settings["pitch_mask_scale"] = SCALE_LABELS[value]
                        elif settings["pitch_mask_mode"] == 2:
                            imgui.Text(ctx, "Allowed pitch classes")
                            hints.show(ctx, "tracks.pitch_mask_classes")
                            pitch_class_flags = imgui.WindowFlags_HorizontalScrollbar()
                            imgui.BeginChild(ctx, "##pitch_class_scroll", 0, 42, False, pitch_class_flags)
                            try:
                                for pitch_class, note_name in enumerate(NOTE_NAMES):
                                    bit = 1 << pitch_class
                                    changed, value = imgui.Checkbox(ctx, f"{note_name}##pitch_class_{pitch_class}", bool(settings["pitch_mask_classes"] & bit))
                                    if changed:
                                        if value:
                                            settings["pitch_mask_classes"] |= bit
                                        else:
                                            settings["pitch_mask_classes"] &= ~bit
                                    if pitch_class < len(NOTE_NAMES) - 1:
                                        imgui.SameLine(ctx)
                            finally:
                                imgui.EndChild(ctx)
                        if settings["pitch_mask_mode"] != 0:
                            changed, value = imgui.Combo(ctx, "Soft shape", settings["pitch_shape_mode"], "Off\0Uniform Register\0Normal Register\0")
                            hints.show(ctx, "tracks.pitch_shape_mode")
                            if changed:
                                settings["pitch_shape_mode"] = value
                            if settings["pitch_shape_mode"] == 1:
                                changed, value = imgui.SliderInt(ctx, "Shape min pitch", settings["pitch_shape_min"], 0, 127)
                                hints.show(ctx, "tracks.pitch_shape_min")
                                if changed:
                                    settings["pitch_shape_min"] = value
                                changed, value = imgui.SliderInt(ctx, "Shape max pitch", settings["pitch_shape_max"], 0, 127)
                                hints.show(ctx, "tracks.pitch_shape_max")
                                if changed:
                                    settings["pitch_shape_max"] = value
                            elif settings["pitch_shape_mode"] == 2:
                                changed, value = imgui.SliderInt(ctx, "Shape mean pitch", settings["pitch_shape_mean"], 0, 127)
                                hints.show(ctx, "tracks.pitch_shape_mean")
                                if changed:
                                    settings["pitch_shape_mean"] = value
                                changed, value = imgui.SliderDouble(ctx, "Shape standard deviation", settings["pitch_shape_std"], 0.5, 40.0, "%.1f")
                                hints.show(ctx, "tracks.pitch_shape_std")
                                if changed:
                                    settings["pitch_shape_std"] = value
                        imgui.EndTabItem(ctx)

                    if imgui.BeginTabItem(ctx, "Remix")[0]:
                        imgui.SeparatorText(ctx, "Variation")
                        changed, value = imgui.Checkbox(ctx, "Remix this track's bars", bool(settings["remix_enabled"]))
                        hints.show(ctx, "tracks.remix_enabled")
                        if changed:
                            settings["remix_enabled"] = int(value)
                        if settings["remix_enabled"]:
                            imgui.TextDisabled(ctx, "Regenerates existing bars as a variation.")
                            changed, value = imgui.SliderDouble(ctx, "Remix amount", settings["remix_amount"], 0.0, 1.0, "%.2f")
                            hints.show(ctx, "tracks.remix_amount")
                            if changed:
                                settings["remix_amount"] = value
                            changed, value = imgui.Combo(ctx, "Remix mode", settings["remix_mode"], "Pitch Only\0Pitch + Duration\0")
                            hints.show(ctx, "tracks.remix_mode")
                            if changed:
                                settings["remix_mode"] = value
                        imgui.EndTabItem(ctx)

                    imgui.EndTabBar(ctx)

            imgui.PopID(ctx)
    finally:
        imgui.EndChild(ctx)
