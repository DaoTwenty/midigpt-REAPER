"""Generation controls and the batch candidate selector."""

import imgui

from . import hints, themes

_CANDIDATE_BUTTON_W = 28
_CANDIDATE_BUTTON_H = 24
# Tall enough for the buttons *plus* the horizontal scrollbar that appears
# once candidates overflow the row -- otherwise the scrollbar eats into the
# available height, the buttons no longer fit, and a second (vertical)
# scrollbar kicks in to compensate, which looks broken.
_CANDIDATE_ROW_H = 40


def _draw_candidate_row(ctx, global_settings, logic):
    """Batch candidate picker, docked under the Generate button. Always
    drawn (with disabled placeholder slots before a batch exists) so the
    row doesn't appear/disappear and shove the rest of the panel around --
    see the matching comment on the context bar in console_panel.py. Slots
    beyond what fits on one line scroll horizontally instead of wrapping."""
    action = None
    info = logic.information()
    candidates = info["candidates"]
    selected = info["selected_candidate"]
    requested = int(global_settings.get("num_candidates", 1))
    # Once a real batch exists, show exactly that -- not a mix of it plus
    # however many slots the *live* slider currently asks for. Otherwise
    # dragging the slider after generating (e.g. from 4 up to 8) tacks
    # placeholder slots onto an already-finished batch, implying it has
    # candidates it doesn't. The slider only previews slot count pre-
    # generation, when there's nothing real yet to contradict.
    slot_count = len(candidates) if candidates else requested
    # A single variation isn't a "batch" -- there's nothing to pick between,
    # so don't imply otherwise with a picker that's really just one greyed
    # out button.
    is_batch = bool(candidates) or requested > 1
    failed_count = sum(1 for c in candidates if c.get("score") is None)

    if candidates and failed_count:
        # A greyed-out button alone looks identical to "not generated yet"
        # (see the placeholder-slot case below) -- spell out that it
        # actually failed instead of relying on the hover tooltip.
        plural = "s" if failed_count != 1 else ""
        imgui.TextColored(ctx, themes.warning_color(),
                           f"{failed_count} candidate{plural} failed -- hover a greyed button for why.")
    elif candidates:
        imgui.TextDisabled(ctx, "Batch candidates -- pick one to write it to REAPER.")
    elif is_batch:
        imgui.TextDisabled(ctx, "Batch candidates -- generate to fill these in.")
    else:
        imgui.TextDisabled(ctx, "Single variation -- raise it above 1 for a batch picker.")

    visible = imgui.BeginChild(
        ctx, "##batch_candidates", -1, _CANDIDATE_ROW_H, 0, imgui.WindowFlags_HorizontalScrollbar()
    )
    if visible and is_batch:
        for index in range(slot_count):
            if index:
                imgui.SameLine(ctx)
            candidate = candidates[index] if index < len(candidates) else None
            # A candidate with no score has either failed (real candidate,
            # server reported an error) or simply doesn't exist yet (empty
            # placeholder slot before/while generating) -- distinguish the
            # two so only genuine failures get the warning tint.
            failed = candidate is not None and candidate.get("score") is None
            enabled = candidate is not None and not failed
            is_selected = candidate is not None and selected == index

            if failed:
                # Pushing a fixed near-white text color alongside the
                # danger/failed fill (not the theme's own Col_Text()) --
                # see themes.py's module docstring for why.
                imgui.PushStyleColor(ctx, imgui.Col_Button(), themes.failed())
                imgui.PushStyleColor(ctx, imgui.Col_Text(), themes.DANGER_TEXT)
            if not enabled:
                imgui.BeginDisabled(ctx)
            if is_selected:
                imgui.PushStyleColor(ctx, imgui.Col_Button(), themes.danger())
                imgui.PushStyleColor(ctx, imgui.Col_Text(), themes.DANGER_TEXT)
            if imgui.Button(ctx, f"{index + 1}##batch_{index}", _CANDIDATE_BUTTON_W, _CANDIDATE_BUTTON_H):
                action = f"batch_select_{index}"
            if is_selected:
                imgui.PopStyleColor(ctx, 2)
            if not enabled:
                imgui.EndDisabled(ctx)
            if failed:
                imgui.PopStyleColor(ctx, 2)

            if candidate is not None and imgui.IsItemHovered(ctx):
                tip = f"seed {candidate.get('seed')}"
                if candidate.get("truncated"):
                    tip += "  (truncated -- hit context ceiling)"
                if failed:
                    tip += f"\nFAILED: {candidate.get('error')}"
                # Hint mode's explanation (with the real candidate number
                # filled into its {index} placeholder) goes on top of the
                # real per-candidate data above, rather than replacing it.
                hint_text = hints.text("generation.batch_candidate", index=index + 1)
                if hint_text:
                    tip = f"{hint_text}\n{tip}"
                imgui.SetTooltip(ctx, tip)
    imgui.EndChild(ctx)
    return action


def draw(ctx, global_settings, logic=None):
    action = None
    is_generating = logic is not None and logic.active_generation is not None

    imgui.SeparatorText(ctx, "Generation")
    imgui.BeginDisabled(ctx, is_generating)
    changed, value = imgui.SliderInt(ctx, "Variations to generate", global_settings["num_candidates"], 1, 16)
    hints.show(ctx, "generation.variations")
    if changed:
        global_settings["num_candidates"] = value
    imgui.EndDisabled(ctx)

    # The button doubles as Cancel while a generation is in flight -- once
    # it finishes (success, failure, or cancellation) active_generation
    # clears and this reverts to Generate on its own; there's no separate
    # disabled/idle state to manage.
    if is_generating:
        imgui.PushStyleColor(ctx, imgui.Col_Button(), themes.danger())
        imgui.PushStyleColor(ctx, imgui.Col_Text(), themes.DANGER_TEXT)
    clicked = imgui.Button(ctx, "Cancel" if is_generating else "Generate", -1, 32)
    if is_generating:
        imgui.PopStyleColor(ctx, 2)
    hints.show(ctx, "generation.generate")
    if clicked:
        action = "cancel" if is_generating else "generate"

    if logic is not None:
        action = _draw_candidate_row(ctx, global_settings, logic) or action
    return action
