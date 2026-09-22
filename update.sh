#!/usr/bin/env bash
# Update MIDI-GPT for REAPER to the latest version
# Usage: ./update.sh [any install.sh flag, e.g. --torch-gpu, --dev, --midigpt-src=PATH]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo -e "${BOLD}"
echo "  +--------------------------------------+"
echo "  |   MIDI-GPT for REAPER  -- Update    |"
echo "  +--------------------------------------+"
echo -e "${NC}"

# ── Pull latest plugin code ──────────────────────────────────────
info "Pulling latest plugin code..."
git -C "$REPO_DIR" pull || fail "git pull failed. Check your internet connection."
ok "Plugin code up to date"

# ── Refresh the venv/backend via install.sh ──────────────────────
# Reuses install.sh's own venv/backend logic (Steps 1-3, 6) instead of
# duplicating a simplified version of it here -- this used to just run
# `pip install --upgrade "midigpt[http,inference]"` unconditionally, which
# is only correct for a PyPI install; for an editable/source install (a
# sibling MIDI-GPT checkout, or install.sh's own clone-and-editable
# fallback) it would silently try to replace that with a PyPI wheel
# instead of updating the actual source. install.sh already knows which
# of those this environment is using and updates it correctly.
#
# --backend-only skips every REAPER-side step (symlinks, ReaPack,
# reaper.ini) entirely, so this never needs REAPER closed and never
# re-asks the one-time Sforzando/Arachno questions; `< /dev/null` also
# suppresses install.sh's own interactive "start the server now?" prompt
# so only this script's copy of that question runs.
[ -f "$REPO_DIR/install.sh" ] || fail "install.sh not found -- this checkout looks incomplete."
info "Refreshing the Python venv/backend..."
bash "$REPO_DIR/install.sh" --backend-only --skip-deps "$@" < /dev/null

# ── Done ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Update complete.${NC}"
echo ""

if [ -t 0 ]; then
    read -rp "  Start the server now? [Y/n]: " _LAUNCH
    _LAUNCH="${_LAUNCH:-y}"
    if [[ "$_LAUNCH" =~ ^[Yy]$ ]]; then
        echo ""
        echo "    [1] Yellow     (default)"
        echo "    [2] Prism"
        echo "    [3] Expressive"
        echo ""
        read -rp "  Model [1/2/3, default=1]: " _M
        case "${_M:-1}" in
            2) _MODEL="prism_medium"      ;;
            3) _MODEL="expressive_medium" ;;
            *) _MODEL="yellow_medium"     ;;
        esac
        echo ""
        bash "$REPO_DIR/start_midigpt_server.sh" --pretrained "$_MODEL"
    fi
fi
