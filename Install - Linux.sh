#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER — Linux Installer (double-click or run from terminal)
#
# On most Linux desktops, double-clicking a .sh file will offer to run it
# in a terminal. You can also run it directly: ./Install\ -\ Linux.sh
# ============================================================================

# cd to the directory containing this script
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
