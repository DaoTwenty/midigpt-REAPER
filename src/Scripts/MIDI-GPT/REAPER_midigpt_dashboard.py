# -*- coding: utf-8 -*-
"""
MIDI-GPT Dashboard - Native imgui Table Layout (Fixed Size)
"""

import sys
from reaper_python import *
sys.path.append(RPR_GetResourcePath() + "/Scripts/ReaTeam Extensions/API")
import imgui

MGPT_BANNER = (
    "\u2588\u2588\u2588\u2557   \u2588\u2588\u2588\u2557      \u2588\u2588\u2588\u2588\u2588\u2588\u2557   \u2588\u2588\u2588\u2588\u2588\u2588\u2557   \u2588\u2588\u2588\u2588\u2588\u2557              \u2588\u2588\u2588\u2588\u2588\u2588\u2557   \u2588\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557\n"
    "\u2588\u2588\u2588\u2588\u2557 \u2588\u2588\u2588\u2588\u2551      \u2588\u2588\u2554\u2550\u2550\u2550\u255d   \u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557  \u255a\u2550\u2588\u2588\u2554\u255d             \u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d   \u2588\u2588\u2554\u2550\u2550\u2588\u2588\u2557 \u255a\u2550\u2550\u2588\u2588\u2554\u2550\u2550\u255d\n"
    "\u2588\u2588\u2554\u2588\u2588\u2588\u2588\u2554\u2588\u2588\u2551      \u2588\u2588\u2551       \u2588\u2588\u2551  \u2588\u2588\u2551    \u2588\u2588\u2551    \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2551  \u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d    \u2588\u2588\u2551   \n"
    "\u2588\u2588\u2551\u255a\u2588\u2588\u2554\u255d\u2588\u2588\u2551      \u2588\u2588\u2551       \u2588\u2588\u2551  \u2588\u2588\u2551    \u2588\u2588\u2551    \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u255d  \u2588\u2588\u2551   \u2588\u2588\u2551  \u2588\u2588\u2554\u2550\u2550\u2550\u255d     \u2588\u2588\u2551   \n"
    "\u2588\u2588\u2551 \u255a\u2550\u255d \u2588\u2588\u2551  \u25e2\u2588\u2588\u2588\u2588\u2588\u2557       \u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d  \u2588\u2588\u2588\u2588\u2588\u2557             \u255a\u2588\u2588\u2588\u2588\u2588\u2588\u2554\u255d  \u2588\u2588\u2551         \u2588\u2588\u2551   \n"
    "\u255a\u2550\u255d     \u255a\u2550\u255d  \u2588\u2588\u2588\u2588\u2588\u2588\u2551       \u255a\u2550\u2550\u2550\u2550\u2550\u255d   \u255a\u2550\u2550\u2550\u2550\u255d              \u255a\u2550\u2550\u2550\u2550\u2550\u255d   \u255a\u2550\u255d         \u255a\u2550\u255d   \n"
    "             \u255a\u2588\u2588\u2588\u2588\u2588\u2554\u255d"
)
MGPT_BANNER_FONT_SIZE = 5.5

# Grid height proportions (15%, 55%, 30%)
ROW_RATIOS = [0.15, 0.55, 0.30]

# Adjust this padding (in pixels) if you need extra clearance at the bottom
BOTTOM_PADDING = 0

def draw_logo_panel(cell_w, cell_h):
    """(0,0) Banner / Logo section"""
    imgui.PushFont(ctx, mono_font, MGPT_BANNER_FONT_SIZE)
    banner_w, banner_h = imgui.CalcTextSize(ctx, MGPT_BANNER)
    imgui.PopFont(ctx)

    imgui.BeginChild(ctx, "##banner", cell_w, cell_h, True)
    try:
        imgui.SetCursorPos(ctx, max(0.0, (cell_w - banner_w) / 2),
                            max(0.0, (cell_h - banner_h) / 2))
        imgui.PushFont(ctx, mono_font, MGPT_BANNER_FONT_SIZE)
        try:
            imgui.Text(ctx, MGPT_BANNER)
        finally:
            imgui.PopFont(ctx)
    finally:
        imgui.EndChild(ctx)


def draw_setup_panel():
    """(0,1) Setup controls section"""
    imgui.SeparatorText(ctx, "Setup")
    
    imgui.PushItemWidth(ctx, -1)
    
    # Example setup parameter inputs
    imgui.Text(ctx, "Target Track / Channel")
    _, _ = imgui.InputText(ctx, "##setup_track", "Track 1")
    
    imgui.Spacing(ctx)
    if imgui.Button(ctx, "Initialize MIDIGEN Bridge", -1, 0):
        pass
        
    imgui.PopItemWidth(ctx)

def init():
    global ctx, mono_font
    ctx = imgui.CreateContext('MIDI-GPT Dashboard')
    mono_font = imgui.CreateFont('Menlo')
    imgui.Attach(ctx, mono_font)
    loop()

def loop():
    # 1. Set fixed window size (Always sets size to 800x600 every frame)
    imgui.SetNextWindowSize(ctx, 800, 600, imgui.Cond_Always())

    # 2. Add NoResize flag to lock window dimensions
    window_flags = (
        imgui.WindowFlags_NoResize() | 
        imgui.WindowFlags_NoScrollbar() | 
        imgui.WindowFlags_NoScrollWithMouse()
    )

    visible, open_state = imgui.Begin(ctx, 'Proportional Grid Demo', True, window_flags)
    if visible:
        # Get available dimensions and subtract bottom padding to prevent row clipping
        raw_w, raw_h = imgui.GetContentRegionAvail(ctx)
        avail_w = raw_w - 4  # Accounts for table outer border width
        avail_h = raw_h - BOTTOM_PADDING

        imgui.PushStyleVar(ctx, imgui.StyleVar_CellPadding(), 4, 4)
        imgui.PushStyleVar(ctx, imgui.StyleVar_WindowPadding(), 0, 0)

        # 3. Create 2-Column Table Layout
        table_flags = imgui.TableFlags_SizingFixedFit() | imgui.TableFlags_NoHostExtendY()
        if imgui.BeginTable(ctx, 'GridTable', 2, table_flags, avail_w, avail_h):
            
            # Setup equal 50% width columns
            col_w = avail_w * 0.5
            imgui.TableSetupColumn(ctx, 'Col1', imgui.TableColumnFlags_WidthFixed(), col_w)
            imgui.TableSetupColumn(ctx, 'Col2', imgui.TableColumnFlags_WidthFixed(), col_w)

            # --- ROW 0 (15% height) ---
            row_0_h = int(avail_h * ROW_RATIOS[0])
            imgui.TableNextRow(ctx, imgui.TableRowFlags_None(), row_0_h)

            # Cell (0,0) - Logo
            imgui.TableSetColumnIndex(ctx, 0)
            if imgui.BeginChild(ctx, "CellChild_Logo", col_w, row_0_h, True):
                draw_logo_panel(col_w, row_0_h)
                imgui.EndChild(ctx)

            # Cell (0,1) - Setup
            imgui.TableSetColumnIndex(ctx, 1)
            if imgui.BeginChild(ctx, "CellChild_Setup", col_w, row_0_h, True):
                draw_setup_panel()
                imgui.EndChild(ctx)

            # --- ROW 1 (55% height) ---
            row_1_h = int(avail_h * ROW_RATIOS[1])
            imgui.TableNextRow(ctx, imgui.TableRowFlags_None(), row_1_h)
            for col in range(2):
                imgui.TableSetColumnIndex(ctx, col)
                if imgui.BeginChild(ctx, f"CellChild_R1C{col}", col_w, row_1_h, True):
                    imgui.Text(ctx, f"Row 1 Column {col} (Placeholder)")
                    imgui.EndChild(ctx)

            # --- ROW 2 (30% height) ---
            row_2_h = int(avail_h * ROW_RATIOS[2])
            imgui.TableNextRow(ctx, imgui.TableRowFlags_None(), row_2_h)
            for col in range(2):
                imgui.TableSetColumnIndex(ctx, col)
                if imgui.BeginChild(ctx, f"CellChild_R2C{col}", col_w, row_2_h, True):
                    imgui.Text(ctx, f"Row 2 Column {col} (Placeholder)")
                    imgui.EndChild(ctx)

            imgui.EndTable(ctx)

        imgui.PopStyleVar(ctx, 2)
        imgui.End(ctx)

    if open_state:
        RPR_defer("loop()")

RPR_defer("init()")