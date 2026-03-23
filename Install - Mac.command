#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER — macOS Installer (double-click to run)
#
# This .command file opens Terminal.app automatically when double-clicked.
# It runs the main install.sh script with full terminal output.
# ============================================================================

# cd to the directory containing this script (the release package root)
cd "$(dirname "$0")" || exit 1

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║         MIDI-GPT for REAPER — Installer         ║"
echo "  ║                                                  ║"
echo "  ║  This will install MIDI-GPT and all its         ║"
echo "  ║  dependencies. It takes about 5-10 minutes      ║"
echo "  ║  and may require an internet connection.         ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

# Set flag so install.sh shows "Press Enter to close" at the end
export MIDIGPT_INTERACTIVE=1

# Run the installer
bash ./install.sh "$@"
