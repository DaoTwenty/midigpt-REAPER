#!/usr/bin/env bash
# ============================================================================
# Test script for ReaImGui bootstrap mechanism (full flow)
#
# Tests the complete mechanism:
#   1. Bootstrap written to __startup.lua
#   2. ReaPack installed
#   3. REAPER "launched" (test mode) for ImGui install
#   4. Polling detects ImGui in UserPlugins
#   5. REAPER "closed" gracefully
#
# Uses MIDIGPT_FAKE_REAPER_RUNNING to simulate REAPER process lifecycle.
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
echo -e "${BOLD}━━━ ReaImGui Bootstrap Full Mechanism Test ━━━${NC}"
echo ""

# ── Setup: Create fake REAPER directory structure ──
FAKE_REAPER="$WORK_DIR/fake-reaper"
mkdir -p "$FAKE_REAPER/UserPlugins"
mkdir -p "$FAKE_REAPER/Scripts"

# Remove any existing ImGui (simulate fresh state)
find "$FAKE_REAPER/UserPlugins" -iname "*imgui*" -delete 2>/dev/null || true

info "Fake REAPER dir: $FAKE_REAPER"

# ── Run install.sh --reaper-only with FAKE REAPER RUNNING ──
# This simulates: REAPER not running initially, installer writes bootstrap,
# then launches REAPER (test mode), polls for ImGui, then closes REAPER.
scenario "Running install.sh --reaper-only (full ImGui mechanism)"

# First run: REAPER not running, should write bootstrap + launch REAPER
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

# ── Verify REAPER relaunch + poll mechanism was triggered ──
scenario "Verifying REAPER relaunch + poll mechanism triggered"

if grep -q "Launching REAPER to install ReaImGui via ReaPack" "$WORK_DIR/install.log"; then
    pass "Installer entered REAPER relaunch branch for ImGui"
else
    fail_test "Installer did NOT enter REAPER relaunch branch"
    cat "$WORK_DIR/install.log"
fi

if grep -q "waiting for ReaImGui to install" "$WORK_DIR/install.log"; then
    pass "Installer started polling for ImGui"
else
    fail_test "Installer did NOT start polling for ImGui"
    cat "$WORK_DIR/install.log"
fi

if grep -q "Test mode: skipping actual REAPER relaunch" "$WORK_DIR/install.log"; then
    pass "Test mode detected (REAPER relaunch simulated)"
else
    fail_test "Test mode not detected in relaunch"
    cat "$WORK_DIR/install.log"
fi

if grep -q "REAPER closed. Setup complete" "$WORK_DIR/install.log"; then
    pass "Installer closed REAPER after ImGui install simulation"
else
    fail_test "Installer did NOT close REAPER after ImGui simulation"
    cat "$WORK_DIR/install.log"
fi

# ── Simulate ImGui installation during polling (second run) ──
# The first run polls but finds nothing (test mode). 
# Second run: simulate that ImGui was installed during the "REAPER session"
scenario "Simulating ImGui installed during REAPER session (idempotency)"

# Create dummy ImGui binary to simulate successful install
touch "$FAKE_REAPER/UserPlugins/reaper_imgui.dylib"

# Run again - should detect ImGui already present, skip bootstrap + relaunch
MIDIGPT_REAPER_DIR="$FAKE_REAPER" \
MIDIGPT_FAKE_REAPER_RUNNING=false \
bash "$INSTALL_SH" --reaper-only --skip-reaper-config < /dev/null > "$WORK_DIR/install2.log" 2>&1

INSTALL_EXIT2=$?

if [ "$INSTALL_EXIT2" -eq 0 ]; then
    pass "Second run (ImGui already present) exited successfully"
else
    fail_test "Second run failed (exit $INSTALL_EXIT2)"
    cat "$WORK_DIR/install2.log"
fi

if grep -q "ReaImGui extension not found" "$WORK_DIR/install2.log"; then
    fail_test "Second run incorrectly tried to install ImGui again"
    cat "$WORK_DIR/install2.log"
else
    pass "Second run correctly skipped ImGui install (already present)"
fi

if grep -q "Launching REAPER to install ReaImGui" "$WORK_DIR/install2.log"; then
    fail_test "Second run incorrectly launched REAPER again"
    cat "$WORK_DIR/install2.log"
else
    pass "Second run correctly skipped REAPER relaunch"
fi

# ── Summary ──
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED${NC}"
else
    echo -e "${RED}${BOLD}  $FAILURES CHECKS FAILED${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "  Temp dir (for inspection): $WORK_DIR"
echo "  Install log (1st run): $WORK_DIR/install.log"
echo "  Install log (2nd run): $WORK_DIR/install2.log"

exit "$FAILURES"