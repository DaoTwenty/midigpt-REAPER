"""Global generation settings tabs."""

import sys

from reaper_python import *

sys.path.append(RPR_GetResourcePath() + "/Scripts/ReaTeam Extensions/API")
import imgui

from . import hints
from .constants import MODEL_DIM_OPTIONS, VALIDATION_LABELS


def _draw_context_length(ctx, params, model_type):
    """A plain SliderInt implies any value 2-16 is valid, but a checkpoint
    may only actually accept a couple of specific ones (see
    MODEL_DIM_OPTIONS) -- offer exactly those as a radio choice instead of
    letting the slider promise something the model will reject, when
    they're known; otherwise fall back to the unconstrained slider."""
    dim_options = MODEL_DIM_OPTIONS.get(model_type)
    if not dim_options:
        changed, value = imgui.SliderInt(ctx, "Context Length (Bars)", params["model_dim"], 2, 16)
        hints.show(ctx, "global.context_length")
        if changed:
            params["model_dim"] = value
        return

    if params["model_dim"] not in dim_options:
        # Stale value from before this model was selected (or from a
        # model with different/no known constraint) -- snap to a valid
        # one rather than silently sending something this model rejects.
        params["model_dim"] = dim_options[0]

    imgui.Text(ctx, "Context Length (Bars)")
    hints.show(ctx, "global.context_length")
    choice_idx = dim_options.index(params["model_dim"])
    for i, option in enumerate(dim_options):
        changed, choice_idx = imgui.RadioButtonEx(ctx, f"{option} bars##dim_{option}", choice_idx, i)
        if changed:
            params["model_dim"] = dim_options[choice_idx]
        if i < len(dim_options) - 1:
            imgui.SameLine(ctx)


def draw(ctx, params, model_type="yellow"):
    if not imgui.BeginTabBar(ctx, "GlobalSettingsTabs"):
        return

    if imgui.BeginTabItem(ctx, "Plan")[0]:
        imgui.SeparatorText(ctx, "Generation Plan")
        _draw_context_length(ctx, params, model_type)
        changed, value = imgui.SliderInt(ctx, "Bars per Step", min(params["bars_per_step"], params["model_dim"]), 1, params["model_dim"])
        hints.show(ctx, "global.bars_per_step")
        if changed:
            params["bars_per_step"] = value
        changed, value = imgui.SliderInt(ctx, "Tracks per Step", params["tracks_per_step"], 1, 16)
        hints.show(ctx, "global.tracks_per_step")
        if changed:
            params["tracks_per_step"] = value
        changed, value = imgui.Checkbox(ctx, "Shuffle processing steps", bool(params["shuffle"]))
        hints.show(ctx, "global.shuffle")
        if changed:
            params["shuffle"] = int(value)

        imgui.SeparatorText(ctx, "Reproducibility")
        changed, _ = imgui.RadioButtonEx(ctx, "Manual seed", 0 if params["manual_seed"] else 1, 0)
        hints.show(ctx, "global.manual_seed")
        if changed:
            params["manual_seed"] = not params["manual_seed"]
        imgui.SameLine(ctx)
        imgui.BeginDisabled(ctx, not params["manual_seed"])
        changed, value = imgui.InputInt(ctx, "Seed", max(0, params["seed"]), 1, 100)
        hints.show(ctx, "global.seed")
        if changed:
            params["seed"] = max(0, value)
        imgui.EndDisabled(ctx)
        if not params["manual_seed"]:
            params["seed"] = -1
            imgui.TextDisabled(ctx, "The server selects a fresh seed for each generation.")
        imgui.EndTabItem(ctx)

    if imgui.BeginTabItem(ctx, "Sampling")[0]:
        imgui.SeparatorText(ctx, "Sampling")
        changed, value = imgui.SliderDouble(ctx, "Temperature", params["temperature"], 0.5, 2.0, "%.2f")
        hints.show(ctx, "global.temperature")
        if changed:
            params["temperature"] = value
        changed, value = imgui.Checkbox(ctx, "Enable Top-p", params["top_p_enabled"])
        hints.show(ctx, "global.top_p_enabled")
        if changed:
            params["top_p_enabled"] = value
        imgui.BeginDisabled(ctx, not params["top_p_enabled"])
        changed, value = imgui.SliderDouble(ctx, "Top-p", params["top_p"], 0.0, 1.0, "%.2f")
        hints.show(ctx, "global.top_p")
        if changed:
            params["top_p"] = value
        imgui.EndDisabled(ctx)
        if not params["top_p_enabled"]:
            params["top_p"] = 1.0
        changed, value = imgui.Checkbox(ctx, "Enable Top-k", params["top_k_enabled"])
        hints.show(ctx, "global.top_k_enabled")
        if changed:
            params["top_k_enabled"] = value
        imgui.BeginDisabled(ctx, not params["top_k_enabled"])
        changed, value = imgui.SliderInt(ctx, "Top-k", params["top_k"], 1, 500)
        hints.show(ctx, "global.top_k")
        if changed:
            params["top_k"] = value
        imgui.EndDisabled(ctx)
        if not params["top_k_enabled"]:
            params["top_k"] = 0
        imgui.SeparatorText(ctx, "Advanced Sampling")
        changed, value = imgui.Checkbox(ctx, "Enable mask probability", params["mask_p_enabled"])
        hints.show(ctx, "global.mask_p_enabled")
        if changed:
            params["mask_p_enabled"] = value
        imgui.BeginDisabled(ctx, not params["mask_p_enabled"])
        changed, value = imgui.SliderDouble(ctx, "Mask probability", params["mask_p"], 0.0, 0.95, "%.2f")
        hints.show(ctx, "global.mask_p")
        if changed:
            params["mask_p"] = value
        imgui.EndDisabled(ctx)
        if not params["mask_p_enabled"]:
            params["mask_p"] = 0.0
        changed, value = imgui.Checkbox(ctx, "Enable mask count", params["mask_k_enabled"])
        hints.show(ctx, "global.mask_k_enabled")
        if changed:
            params["mask_k_enabled"] = value
        imgui.BeginDisabled(ctx, not params["mask_k_enabled"])
        changed, value = imgui.SliderInt(ctx, "Mask count", params["mask_k"], 1, 100)
        hints.show(ctx, "global.mask_k")
        if changed:
            params["mask_k"] = value
        imgui.EndDisabled(ctx)
        if not params["mask_k_enabled"]:
            params["mask_k"] = 0
        imgui.EndTabItem(ctx)

    if imgui.BeginTabItem(ctx, "Constraints")[0]:
        imgui.SeparatorText(ctx, "Musical Constraints")
        changed, value = imgui.Checkbox(ctx, "Limit polyphony", params["polyphony_limit_enabled"])
        hints.show(ctx, "global.polyphony_limit_enabled")
        if changed:
            params["polyphony_limit_enabled"] = value
        imgui.BeginDisabled(ctx, not params["polyphony_limit_enabled"])
        changed, value = imgui.SliderInt(ctx, "Maximum voices", params["polyphony_hard_limit"], 1, 32)
        hints.show(ctx, "global.polyphony_max")
        if changed:
            params["polyphony_hard_limit"] = value
        imgui.EndDisabled(ctx)
        if not params["polyphony_limit_enabled"]:
            params["polyphony_hard_limit"] = 0
            imgui.TextDisabled(ctx, "Polyphony limit: Off")
        changed, value = imgui.Checkbox(ctx, "Limit note density", params["density_limit_enabled"])
        hints.show(ctx, "global.density_limit_enabled")
        if changed:
            params["density_limit_enabled"] = value
        imgui.BeginDisabled(ctx, not params["density_limit_enabled"])
        changed, value = imgui.SliderInt(ctx, "Maximum notes", params["density_hard_limit"], 1, 64)
        hints.show(ctx, "global.density_max")
        if changed:
            params["density_hard_limit"] = value
        imgui.EndDisabled(ctx)
        if not params["density_limit_enabled"]:
            params["density_hard_limit"] = 0
            imgui.TextDisabled(ctx, "Note density limit: Off")
        imgui.EndTabItem(ctx)

    if imgui.BeginTabItem(ctx, "Quality")[0]:
        imgui.SeparatorText(ctx, "Validation")
        checks_idx = params["checks_idx"]
        for index, label in enumerate(VALIDATION_LABELS):
            changed, checks_idx = imgui.RadioButtonEx(ctx, label, checks_idx, index)
            hints.show(ctx, "global.validation")
            if changed:
                params["checks_idx"] = checks_idx
            if index < 3:
                imgui.SameLine(ctx)
        imgui.SeparatorText(ctx, "Recovery")
        changed, value = imgui.SliderInt(ctx, "Maximum attempts", params["max_attempts"], 1, 10)
        hints.show(ctx, "global.max_attempts")
        if changed:
            params["max_attempts"] = value
        changed, value = imgui.Checkbox(ctx, "Increase temp on retry", params["temp_escalation_enabled"])
        hints.show(ctx, "global.temp_escalation_enabled")
        if changed:
            params["temp_escalation_enabled"] = value
        imgui.BeginDisabled(ctx, not params["temp_escalation_enabled"])
        changed, value = imgui.SliderDouble(ctx, "Temp multiplier", params["temp_escalation"], 1.0, 3.0, "%.2f")
        hints.show(ctx, "global.temp_escalation")
        if changed:
            params["temp_escalation"] = value
        imgui.EndDisabled(ctx)
        if not params["temp_escalation_enabled"]:
            params["temp_escalation"] = 1.0
        imgui.EndTabItem(ctx)

    imgui.EndTabBar(ctx)
