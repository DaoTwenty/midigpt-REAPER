"""Settings popup: repo/docs link, hint-mode toggle, theme selector. Same
modal-popup pattern as the server-address and track-setup popups in
setup_panel.py (centered over the dashboard window, dims it behind)."""

import imgui

from . import hints, themes

SETTINGS_POPUP_ID = "Settings##settings_popup"
_REPO_URL = "https://github.com/Metacreation-Lab/midigpt-REAPER"


def draw(ctx, window_center):
    """Draws the popup body if it's open. The caller is responsible for
    placing whatever button opens it and calling
    imgui.OpenPopup(ctx, SETTINGS_POPUP_ID) (see draw_logo_panel() in
    MIDI-GPT.py)."""
    imgui.SetNextWindowPos(ctx, window_center[0], window_center[1], imgui.Cond_Appearing(), 0.5, 0.5)
    imgui.PushStyleVar(ctx, imgui.StyleVar_WindowPadding(), 16, 16)
    visible, _ = imgui.BeginPopupModal(ctx, SETTINGS_POPUP_ID, None, imgui.WindowFlags_AlwaysAutoResize())
    imgui.PopStyleVar(ctx, 1)
    if not visible:
        return

    imgui.TextLinkOpenURL(ctx, "Repo && Documentation", _REPO_URL)

    imgui.SeparatorText(ctx, "Hints")
    hints_on = hints.enabled()
    changed, hints_on = imgui.Checkbox(ctx, "Show hover hints", hints_on)
    hints.show(ctx, "settings.hints_toggle")
    if changed:
        hints.set_enabled(hints_on)
    imgui.TextDisabled(ctx, "Hover a control for a moment to see what it does.")

    imgui.SeparatorText(ctx, "Theme")
    theme_names = themes.names()
    current = themes.current()
    index = theme_names.index(current) if current in theme_names else 0
    imgui.SetNextItemWidth(ctx, 200)
    changed, index = imgui.Combo(ctx, "##theme", index, "\0".join(theme_names) + "\0")
    hints.show(ctx, "settings.theme")
    if changed:
        themes.set_current(theme_names[index])

    imgui.Separator(ctx)
    if imgui.Button(ctx, "Close", 100, 0):
        imgui.CloseCurrentPopup(ctx)
    imgui.EndPopup(ctx)
