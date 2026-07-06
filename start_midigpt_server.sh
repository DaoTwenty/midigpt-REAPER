#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT HTTP Server Launcher (macOS / Linux)
#
# Starts the stateless FastAPI HTTP server for REAPER generation.
# By default, runs the 'yellow' model on port 3456.
#
# Usage:
#   ./start_midigpt_server.sh                          # Runs yellow
#   ./start_midigpt_server.sh --pretrained ghost       # Runs ghost
#   ./start_midigpt_server.sh --ckpt path/to/model.pt  # Runs local checkpoint
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
echo "  Keep this window open while using MIDI-GPT in REAPER."
echo "  Press Ctrl+C to stop the server."
echo ""

# Default parameters: run 'yellow' model on port 3456 if no arguments are provided.
# If arguments are passed (e.g. --pretrained ghost or --ckpt ...), forward them.
if [ $# -eq 0 ]; then
    midigpt-http --pretrained yellow --port 3456
else
    midigpt-http --port 3456 "$@"
fi

# Keep window open on error
echo ""
echo "Server stopped."
read -rp "Press Enter to close..."
