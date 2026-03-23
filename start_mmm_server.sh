#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT Server Launcher (macOS / Linux)
#
# Double-click this file or run from terminal to start the inference server.
# The server must be running before using MIDI-GPT in REAPER.
# ============================================================================

# cd to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Activate the virtual environment
if [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
else
    echo "ERROR: Virtual environment not found at .venv/"
    echo "Please run the installer first."
    echo ""
    read -rp "Press Enter to close..."
    exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║      MIDI-GPT Server Starting...     ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  The server will listen on 127.0.0.1:3456"
echo "  Keep this window open while using MIDI-GPT in REAPER."
echo "  Press Ctrl+C to stop the server."
echo ""

python src/Scripts/MMM/MMM_server.py --config src/Scripts/MMM/models/config.json

# If the server exits, keep the window open so the user can see errors
echo ""
echo "Server stopped."
read -rp "Press Enter to close..."
