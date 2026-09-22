"""Error/warning popups -- surfaces a failure or caution loudly instead of
leaving it sitting in the Console tab where it's easy to miss. Call
error()/warning() from anywhere (they're plain Python, no imgui context
needed -- logic.py's the main caller); MIDI-GPT.py's
loop() calls draw() once per frame to actually show whichever one is
pending.

Deliberately reserved for genuine failures and things worth interrupting
for (a truncated generation, a request that's likely to fail server-side)
-- not routine progress/status messages, which stay console-only. Popping
a dialog for every ordinary console line would just train people to
reflexively dismiss it."""

import imgui

from . import themes

ERROR_POPUP_ID = "Error##notify_error_popup"
WARNING_POPUP_ID = "Warning##notify_warning_popup"

_message = None  # {"kind": "error"|"warning", "text": str}
_message_id = 0
_shown_id = 0


def error(text):
    _set("error", text)


def warning(text):
    _set("warning", text)


def _set(kind, text):
    global _message, _message_id
    _message = {"kind": kind, "text": text}
    _message_id += 1


def draw(ctx, window_center):
    global _shown_id
    if _message is not None and _shown_id != _message_id:
        popup_id = ERROR_POPUP_ID if _message["kind"] == "error" else WARNING_POPUP_ID
        imgui.OpenPopup(ctx, popup_id)
        _shown_id = _message_id

    for popup_id, accent in ((ERROR_POPUP_ID, themes.error_color()), (WARNING_POPUP_ID, themes.warning_color())):
        imgui.SetNextWindowPos(ctx, window_center[0], window_center[1], imgui.Cond_Appearing(), 0.5, 0.5)
        imgui.PushStyleVar(ctx, imgui.StyleVar_WindowPadding(), 16, 16)
        visible, _ = imgui.BeginPopupModal(ctx, popup_id, None, imgui.WindowFlags_AlwaysAutoResize())
        imgui.PopStyleVar(ctx, 1)
        if visible:
            imgui.PushTextWrapPos(ctx, imgui.GetCursorPosX(ctx) + 420)
            imgui.TextColored(ctx, accent, _message["text"] if _message else "")
            imgui.PopTextWrapPos(ctx)
            imgui.Separator(ctx)
            if imgui.Button(ctx, "OK", 100, 0):
                imgui.CloseCurrentPopup(ctx)
            imgui.EndPopup(ctx)
