#!/usr/bin/env bash
# ============================================================================
# Test script for ReaImGui direct download mechanism
#
# Tests the complete mechanism:
#   1. ReaPack installed
#   2. ReaImGui downloaded directly from codeberg.org
#   3. ReaImGui binary placed in UserPlugins
#   4. No REAPER relaunch needed (direct download)
#   5. Idempotent: second run skips ImGui if already present
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
echo -e "${BOLD}━━━ ReaImGui Direct Download Test ━━━${NC}"
echo ""

# ── Setup: Create fake REAPER directory structure ──
FAKE_REAPER="$WORK_DIR/fake-reaper"
mkdir -p "$FAKE_REAPER/UserPlugins"
mkdir -p "$FAKE_REAPER/Scripts"

# Remove any existing ImGui (simulate fresh state)
find "$FAKE_REAPER/UserPlugins" -iname "*imgui*" -delete 2>/dev/null || true

info "Fake REAPER dir: $FAKE_REAPER"

# ── Run install.sh --reaper-only ──
# This tests the direct download mechanism:
# - ReaPack installed
# - ReaImGui downloaded directly from codeberg.org
# - No REAPER relaunch needed
scenario "Running install.sh --reaper-only (direct ReaImGui download)"

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

# ── Verify ReaPack was installed ──
scenario "Verifying ReaPack installation"

if find "$FAKE_REAPER/UserPlugins" -iname "reaper_reapack*" | grep -q .; then
    REAPACK_FILE=$(find "$FAKE_REAPER/UserPlugins" -iname "reaper_reapack*" | head -1)
    pass "ReaPack binary found: $(basename "$REAPACK_FILE")"
else
    fail_test "ReaPack binary NOT found in UserPlugins"
fi

# ── Verify ReaImGui was downloaded directly ──
scenario "Verifying ReaImGui direct download"

if find "$FAKE_REAPER/UserPlugins" -iname "*imgui*" | grep -q .; then
    IMGUI_FILE=$(find "$FAKE_REAPER/UserPlugins" -iname "*imgui*" | head -1)
    pass "ReaImGui binary found: $(basename "$IMGUI_FILE")"
else
    fail_test "ReaImGui binary NOT found in UserPlugins"
fi

# ── Verify no __startup.lua was created (no bootstrap) ──
scenario "Verifying no bootstrap (__startup.lua not created)"

if [ ! -f "$FAKE_REAPER/Scripts/__startup.lua" ]; then
    pass "__startup.lua NOT created (no bootstrap mechanism)"
else
    fail_test "__startup.lua was created (old bootstrap still exists)"
fi

# ── Verify direct download message in log ──
scenario "Verifying direct download log messages"

if grep -q "Installing ReaImGui" "$WORK_DIR/install.log" && \
   grep -q "ReaImGui native binary installed and checksum-verified" "$WORK_DIR/install.log" && \
   grep -q "Python API installed" "$WORK_DIR/install.log"; then
    pass "Direct download log messages found"
else
    fail_test "Direct download log messages NOT found"
    cat "$WORK_DIR/install.log"
fi

# ── Verify no REAPER relaunch for ImGui ──
scenario "Verifying no REAPER relaunch for ImGui"

if grep -q "Launching REAPER to install ReaImGui" "$WORK_DIR/install.log"; then
    fail_test "Installer incorrectly launched REAPER for ImGui"
else
    pass "Installer did NOT launch REAPER for ImGui (direct download used)"
fi

# ── Test idempotency: second run with ImGui already present ──
scenario "Testing idempotency (ImGui already present)"

# Run again - should detect ImGui already present, skip download
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

if grep -q "ReaImGui installed" "$WORK_DIR/install2.log"; then
    fail_test "Second run incorrectly tried to install ImGui again"
else
    pass "Second run correctly skipped ImGui install (already present)"
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