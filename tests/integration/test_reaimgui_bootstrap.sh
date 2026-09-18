#!/usr/bin/env bash
# ============================================================================
# Test script for ReaImGui bootstrap functionality
#
# This script tests the ReaImGui bootstrap mechanism by:
#   1. Creating a fake REAPER directory
#   2. Removing any existing ReaImGui from UserPlugins
#   3. Running install.sh --reaper-only with the bootstrap
#   4. Verifying __startup.lua contains the bootstrap block
#   5. Instructions for manual REAPER launch to verify ImGui installs
#
# Usage:
#   ./tests/integration/test_reaimgui_bootstrap.sh
#   ./tests/integration/test_reaimgui_bootstrap.sh --keep   # Keep temp dir
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_DIR/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

KEEP_TEMP=false
WORK_DIR=""

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail_test() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}→${NC} $*"; }
scenario() { echo ""; echo -e "${BOLD}── $* ──${NC}"; }

FAILURES=0

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/midigpt-reaimgui-test.XXXXXX")"
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$KEEP_TEMP" = true ]; then
            info "Temp directory preserved: $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
}
trap cleanup EXIT

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP_TEMP=true ;;
        --help|-h)
            echo "Usage: $0 [--keep]"
            echo "  --keep    Keep temp directory after test for inspection"
            exit 0
            ;;
    esac
done

echo ""
echo -e "${BOLD}━━━ ReaImGui Bootstrap Test ━━━${NC}"
echo ""

# ── Setup: Create fake REAPER directory structure ──
FAKE_REAPER="$WORK_DIR/fake-reaper"
mkdir -p "$FAKE_REAPER/UserPlugins"
mkdir -p "$FAKE_REAPER/Scripts"

# Remove any existing ImGui (simulate fresh state)
find "$FAKE_REAPER/UserPlugins" -iname "*imgui*" -delete 2>/dev/null || true

info "Fake REAPER dir: $FAKE_REAPER"
info "UserPlugins: $(ls -la "$FAKE_REAPER/UserPlugins" 2>/dev/null || echo 'empty')"

# ── Run install.sh --reaper-only ──
scenario "Running install.sh --reaper-only with ImGui bootstrap"

MIDIGPT_REAPER_DIR="$FAKE_REAPER" \
MIDIGPT_FAKE_REAPER_RUNNING=false \
bash "$INSTALL_SH" --reaper-only --skip-reaper-config < /dev/null > "$WORK_DIR/install.log" 2>&1

INSTALL_EXIT=$?

if [ "$INSTALL_EXIT" -eq 0 ]; then
    pass "install.sh --reaper-only exited successfully"
else
    fail_test "install.sh --reaper-only failed (exit $INSTALL_EXIT)"
    cat "$WORK_DIR/install.log"
    exit 1
fi

# ── Verify __startup.lua has bootstrap block ──
STARTUP_LUA="$FAKE_REAPER/Scripts/__startup.lua"
scenario "Verifying __startup.lua bootstrap block"

if [ -f "$STARTUP_LUA" ]; then
    pass "__startup.lua created"
    if grep -q "BEGIN MIDI-GPT ReaImGui bootstrap" "$STARTUP_LUA"; then
        pass "Bootstrap block found in __startup.lua"
        echo ""
        info "Bootstrap block content:"
        sed -n '/BEGIN MIDI-GPT ReaImGui bootstrap/,/END MIDI-GPT ReaImGui bootstrap/p' "$STARTUP_LUA" | sed 's/^/  /'
    else
        fail_test "Bootstrap block NOT found in __startup.lua"
        cat "$STARTUP_LUA"
    fi
else
    fail_test "__startup.lua NOT created"
fi

# ── Verify ReaPack was installed (required for bootstrap to work) ──
scenario "Verifying ReaPack installation"

if find "$FAKE_REAPER/UserPlugins" -iname "reaper_reapack*" | grep -q .; then
    REAPACK_FILE=$(find "$FAKE_REAPER/UserPlugins" -iname "reaper_reapack*" | head -1)
    pass "ReaPack binary found: $(basename "$REAPACK_FILE")"
else
    fail_test "ReaPack binary NOT found in UserPlugins"
fi

# ── Summary ──
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED${NC}"
else
    echo -e "${RED}${BOLD}  $FAILURES CHECKS FAILED${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Manual verification instructions ──
echo -e "${BOLD}Manual verification (to test actual ReaImGui install):${NC}"
echo ""
echo "  1. Launch REAPER (real REAPER, not fake dir)"
echo "  2. REAPER will load __startup.lua from its Scripts folder"
echo "  3. ReaPack should auto-add 'ReaTeam Extensions' repo"
echo "  4. ReaImGui + other ReaTeam extensions will install"
echo "  5. Restart REAPER when prompted"
echo "  6. Verify: Extensions > ReaPack > Manage repositories > 'ReaTeam Extensions' exists"
echo "  7. Verify: UserPlugins/ contains reaper_imgui* binary"
echo ""
echo "  To test with the fake dir (requires REAPER config override):"
echo "    MIDIGPT_REAPER_DIR=\"$FAKE_REAPER\" REAPER # (if REAPER supports config dir override)"
echo ""
echo "  Temp dir (for inspection): $WORK_DIR"
echo "  Install log: $WORK_DIR/install.log"

exit "$FAILURES"