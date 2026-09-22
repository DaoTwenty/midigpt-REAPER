"""Dashboard Console and Information tabs."""

import math
import time

import imgui

# How fast the in-flight indicator pulses, in seconds per dim<->bright cycle.
_PULSE_PERIOD = 1.5
_PULSE_DIM = (0x30, 0x38, 0x58)
_PULSE_BRIGHT = (0x70, 0x80, 0xC8)


def _pulse_color():
    """An RRGGBBAA int cycling smoothly between _PULSE_DIM and _PULSE_BRIGHT,
    used to animate a frame background as an "it's alive" indicator."""
    phase = (math.sin(2 * math.pi * time.time() / _PULSE_PERIOD) + 1) / 2
    r, g, b = (int(dim + (bright - dim) * phase) for dim, bright in zip(_PULSE_DIM, _PULSE_BRIGHT))
    return (r << 24) | (g << 16) | (b << 8) | 0xFF


def _draw_console(ctx, log_lines):
    output = "\n".join(log_lines)
    if not output:
        imgui.TextDisabled(ctx, "Console output will appear here.")
        return
    # InputTextMultiline only ever draws a vertical scrollbar on its own --
    # a long line (e.g. the printed outgoing request JSON) is technically
    # scrollable (click in + arrow keys, or drag-select past the edge) but
    # with no visible way to know that or do it, so it just reads as cut
    # off. Wrap it in its own child with a real horizontal scrollbar, and
    # size the input to at least its longest line's width so overflow
    # actually reaches that child (and its scrollbar) instead of clipping
    # inside the input itself.
    content_w, _ = imgui.CalcTextSize(ctx, output)
    avail_w, _ = imgui.GetContentRegionAvail(ctx)
    imgui.BeginChild(ctx, "##console_scroll", 0, 0, False, imgui.WindowFlags_HorizontalScrollbar())
    imgui.InputTextMultiline(
        ctx, "##console_log", output, max(content_w + 20, avail_w), -1, imgui.InputTextFlags_ReadOnly()
    )
    imgui.EndChild(ctx)


def _draw_information(ctx, logic):
    info = logic.information()

    # Request (left) / Result (right) side by side -- two equal stretch
    # columns (the table's default sizing when ScrollX is off) -- then the
    # context bar spans the full cell width underneath both.
    if imgui.BeginTable(ctx, "##info_columns", 2):
        imgui.TableNextRow(ctx)

        imgui.TableSetColumnIndex(ctx, 0)
        imgui.SeparatorText(ctx, "Request")
        imgui.Text(ctx, f"Model: {info['model']}")
        bars, tracks = info["generated_bars"], info["generated_tracks"]
        if bars is not None:
            bar_word = "bar" if bars == 1 else "bars"
            track_word = "track" if tracks == 1 else "tracks"
            imgui.Text(ctx, f"Generated {bars} {bar_word} across {tracks} {track_word}")
        else:
            imgui.TextDisabled(ctx, "No request yet.")
        if info["tokens"].get("truncated"):
            imgui.TextColored(ctx, 0xFF6666FF, "Truncated -- hit the context limit.")

        imgui.TableSetColumnIndex(ctx, 1)
        imgui.SeparatorText(ctx, "Result")
        if info["status"]:
            imgui.Text(ctx, f"Status: {info['status']}")
        else:
            imgui.TextDisabled(ctx, "Status: --")
        if info["seed"] is not None:
            imgui.Text(ctx, f"Seed: {info['seed']}")
        else:
            imgui.TextDisabled(ctx, "Seed: --")
        if info["elapsed"] is not None:
            imgui.Text(ctx, f"Time: {info['elapsed']:.2f}s")
        else:
            imgui.TextDisabled(ctx, "Time: --")

        imgui.EndTable(ctx)

    # Context/token usage bar -- always drawn (with a placeholder state
    # before the first generation) so the panel layout doesn't jump around
    # as soon as real numbers arrive. See also the batch candidate row in
    # generation_panel.py, which follows the same "reserve the space"
    # approach for the same reason.
    if logic.active_generation is not None:
        handle = logic.active_generation["handle"]
        with handle.lock:
            notes_streamed = handle.notes_streamed
            stream_mode = handle.stream_mode
            cancel_sent = handle.cancel_sent
        if cancel_sent:
            status_text = "Cancelling..."
        elif stream_mode:
            status_text = f"Streaming -- {notes_streamed} note(s) received so far..."
        else:
            status_text = "Waiting for the server..."
        # There's no real fraction to show mid-flight (the eventual token
        # count isn't known yet), so keep the bar itself empty and pulse its
        # background between two brightness levels instead, purely as an
        # "it's alive" indicator (the Cancel button lives on the Generate
        # button itself -- generation_panel.py).
        imgui.PushStyleColor(ctx, imgui.Col_FrameBg(), _pulse_color())
        imgui.ProgressBar(ctx, 0.0, -1, 0, status_text)
        imgui.PopStyleColor(ctx, 1)
        imgui.TextDisabled(ctx, "Context: --")
        imgui.SameLine(ctx, 0, 20)
        imgui.TextDisabled(ctx, "Speed: --")
        return None

    tokens = info["tokens"]
    is_batch = bool(info["candidates"])
    context_tokens = tokens.get("context_tokens")
    generated_tokens = tokens.get("generated_tokens")
    max_tokens = tokens.get("max_context_tokens")
    # For a batch (num_candidates > 1) result, whatever context/generated
    # numbers the server puts in "tokens" aren't one candidate's actual
    # usage -- they read like a total summed across every candidate (e.g.
    # 4 candidates each ~50% of budget shows as ~200%), not an average or
    # a single representative value, so there's no honest fraction to
    # compute from them. Show that plainly instead of a bogus/misleading
    # percentage; gen_count (below) is real per-candidate data and still
    # shown either way.
    has_budget = not is_batch and context_tokens is not None and generated_tokens is not None and max_tokens
    if has_budget:
        used = context_tokens + generated_tokens
        utilization = max(0.0, min(1.0, used / max_tokens))
        overlay = f"{used} / {max_tokens} tokens ({utilization * 100:.0f}%)"
    elif is_batch:
        utilization = 0.0
        overlay = "Not available for batch generations"
    else:
        utilization = 0.0
        overlay = "No generation yet"
    imgui.ProgressBar(ctx, utilization, -1, 0, overlay)
    gen_count = info.get("candidate_gen_count")
    if has_budget:
        imgui.Text(ctx, f"Context: {context_tokens} prompt + {generated_tokens} generated")
    elif gen_count is not None:
        # Batch responses don't carry a per-candidate context/max-context
        # breakdown (see logic.py:information()) -- gen_count is the only
        # per-candidate token stat available, so show that instead, keyed
        # to whichever candidate is currently selected.
        imgui.Text(ctx, f"Generated: {gen_count} tokens (candidate {info['selected_candidate'] + 1})")
    else:
        imgui.TextDisabled(ctx, "Context: --")
    imgui.SameLine(ctx, 0, 20)
    speed = tokens.get("tokens_per_second")
    if speed is not None:
        imgui.Text(ctx, f"Speed: {speed:.1f} tokens/sec")
    else:
        imgui.TextDisabled(ctx, "Speed: --")
    return None


def draw(ctx, log_lines, logic):
    action = None
    if imgui.BeginTabBar(ctx, "ConsoleInformationTabs"):
        if imgui.BeginTabItem(ctx, "Information")[0]:
            action = _draw_information(ctx, logic)
            imgui.EndTabItem(ctx)
        if imgui.BeginTabItem(ctx, "Console")[0]:
            _draw_console(ctx, log_lines)
            imgui.EndTabItem(ctx)
        imgui.EndTabBar(ctx)
    return action
