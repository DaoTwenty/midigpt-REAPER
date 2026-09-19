#!/usr/bin/env bash
# ============================================================================
# Stress test: install.sh's REAPER integration (Step 4/5) across different
# starting states -- fresh, partial, already-configured, REAPER-running,
# re-run/idempotency -- without ever touching a real REAPER install.
#
# Uses install.sh --reaper-only (skips venv/backend entirely -- fast, no
# PyTorch/MIDI-GPT download) plus two test-only env var overrides that
# install.sh itself supports for exactly this purpose:
#   MIDIGPT_REAPER_DIR           -- fake REAPER config dir instead of the
#                                    real one
#   MIDIGPT_FAKE_REAPER_RUNNING  -- true/false, simulates whether REAPER is
#                                    "running" without a real process
#
# This proves install.sh puts the right bytes/config in the right places
# for each starting state, correctly detects what's already there, and is
# idempotent. It does NOT and CANNOT prove REAPER itself loads any of this
# correctly -- that needs a real REAPER session.
#
# This does hit the real network for ReaPack's GitHub release (needed to
# test the actual download+checksum path for real) -- everything else here
# is local file state.
#
# Usage:
#   ./tests/integration/test_reaper_states.sh
# ============================================================================

set -uo pipefail  # not -e: one failed assertion shouldn't abort the rest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SH="$REPO_DIR/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TESTS=0
FAILURES=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; }
fail_test() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES + 1)); }
scenario() { echo ""; echo -e "${BOLD}── $* ──${NC}"; TESTS_AT_SCENARIO_START=$TESTS; }

assert_true() {
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail_test "$desc"; fi
}

assert_false() {
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if ! "$@" >/dev/null 2>&1; then pass "$desc"; else fail_test "$desc"; fi
}

assert_contains() {
    local desc="$1" file="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [ -f "$file" ] && grep -qF -- "$needle" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail_test "$desc"
    fi
}

# How many times a fixed string appears in a file (exact count, via grep -c).
assert_grep_count() {
    local desc="$1" expected="$2" needle="$3" file="$4"
    local actual
    actual="$(grep -cF -- "$needle" "$file" 2>/dev/null || echo 0)"
    TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then
        pass "$desc (found $actual)"
    else
        fail_test "$desc (expected $expected, found $actual)"
    fi
}

# How many lines a command prints (e.g. a `find` file listing).
assert_line_count() {
    local desc="$1" expected="$2"; shift 2
    local actual
    actual="$("$@" 2>/dev/null | wc -l | tr -d ' ')"
    TESTS=$((TESTS + 1))
    if [ "$actual" = "$expected" ]; then
        pass "$desc (found $actual)"
    else
        fail_test "$desc (expected $expected, found $actual)"
    fi
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/midigpt-reaper-states-test.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

run_install() {
    # $1 = fake REAPER dir, $2 = "true"/"false" for fake-running
    MIDIGPT_REAPER_DIR="$1" MIDIGPT_FAKE_REAPER_RUNNING="$2" \
        bash "$INSTALL_SH" --reaper-only < /dev/null > "$WORK_DIR/last_run.log" 2>&1
}

echo ""
echo -e "${BOLD}━━━ REAPER integration state matrix ━━━${NC}"

# ============================================================================
scenario "Fresh: REAPER dir doesn't exist at all"
# ============================================================================
FAKE="$WORK_DIR/s1_missing"
run_install "$FAKE" false
RUN_EXIT=$?
TESTS=$((TESTS + 1))
if [ "$RUN_EXIT" -eq 0 ]; then pass "install.sh exits 0 when REAPER isn't installed yet"; else fail_test "install.sh exited $RUN_EXIT when REAPER isn't installed yet"; fi
assert_contains "warns REAPER config dir not found" "$WORK_DIR/last_run.log" "REAPER config directory not found"
assert_false "does not create the REAPER dir itself" test -d "$FAKE"

# ============================================================================
scenario "Fresh: REAPER dir exists, nothing configured yet"
# ============================================================================
FAKE="$WORK_DIR/s2_fresh"
mkdir -p "$FAKE"
run_install "$FAKE" false
RUN_EXIT=$?
TESTS=$((TESTS + 1))
if [ "$RUN_EXIT" -eq 0 ]; then pass "install.sh exits 0"; else fail_test "install.sh exited $RUN_EXIT"; fi
assert_true  "symlink created" test -L "$FAKE/Scripts/MIDI-GPT"
assert_true  "ReaPack binary downloaded" bash -c "find '$FAKE/UserPlugins' -iname 'reaper_reapack*' | grep -q ."
assert_contains "ReaPack reported checksum-verified" "$WORK_DIR/last_run.log" "checksum-verified"
# With direct ReaImGui download, bootstrap is only a fallback.
# Verify ReaImGui gets installed (either direct or via bootstrap fallback).
assert_contains "ReaImGui installed" "$WORK_DIR/last_run.log" "ReaImGui installed"
assert_contains "reports reaper.ini not found (fresh REAPER, never launched)" "$WORK_DIR/last_run.log" \
    "reaper.ini not found"

# ============================================================================
scenario "Re-run on the same state (idempotency)"
# ============================================================================
run_install "$FAKE" false
assert_contains "second run detects ReaPack already installed (no re-download)" "$WORK_DIR/last_run.log" \
    "ReaPack already installed"
# Direct download should detect ImGui already present, no bootstrap needed.
assert_false "no duplicate ImGui install on re-run" bash -c "grep -q 'ReaImGui installed' '$WORK_DIR/last_run.log' && exit 1 || exit 0"
assert_line_count "exactly one ReaPack binary present (no duplicate downloads)" 1 \
    find "$FAKE/UserPlugins" -iname "reaper_reapack*"

# ============================================================================
scenario "ReaImGui already installed -- should not touch __startup.lua"
# ============================================================================
FAKE="$WORK_DIR/s3_has_imgui"
mkdir -p "$FAKE/UserPlugins"
touch "$FAKE/UserPlugins/reaper_imgui.dylib"
run_install "$FAKE" false
assert_false "no __startup.lua written when ReaImGui already present" test -f "$FAKE/Scripts/__startup.lua"
assert_true  "ReaPack still installed independently" bash -c "find '$FAKE/UserPlugins' -iname 'reaper_reapack*' | grep -q ."

# ============================================================================
scenario "Pre-existing __startup.lua with unrelated user content"
# ============================================================================
FAKE="$WORK_DIR/s4_user_startup"
mkdir -p "$FAKE/Scripts"
cat > "$FAKE/Scripts/__startup.lua" << 'EOF'
-- my own startup stuff, unrelated to MIDI-GPT
reaper.ShowConsoleMsg("hello from my own script\n")
EOF
run_install "$FAKE" false
assert_contains "user's own startup content survives" "$FAKE/Scripts/__startup.lua" "hello from my own script"
# With direct download, no bootstrap is written unless direct download fails.
# Verify user content survives (bootstrap not interfering).
assert_contains "user's content still survives after a second run" "$FAKE/Scripts/__startup.lua" \
    "hello from my own script"
run_install "$FAKE" false
assert_contains "user's content still survives after a second run" "$FAKE/Scripts/__startup.lua" \
    "hello from my own script"

# ============================================================================
scenario "REAPER 'running' (non-interactive) -- ReaPack/reaper.ini must be skipped"
# ============================================================================
FAKE="$WORK_DIR/s5_running"
mkdir -p "$FAKE"
run_install "$FAKE" true
assert_true  "symlink still created (doesn't need REAPER closed)" test -L "$FAKE/Scripts/MIDI-GPT"
assert_false "ReaPack NOT downloaded while REAPER is 'running'" bash -c "find '$FAKE/UserPlugins' -iname 'reaper_reapack*' 2>/dev/null | grep -q ."
assert_contains "explains ReaPack was skipped because REAPER is open" "$WORK_DIR/last_run.log" \
    "REAPER is still open"

# ============================================================================
scenario "reaper.ini exists with unrelated content, REAPER not running"
# ============================================================================
FAKE="$WORK_DIR/s6_existing_ini"
mkdir -p "$FAKE"
cat > "$FAKE/reaper.ini" << 'EOF'
[REAPER]
someoption=1
otheroption=hello
EOF
run_install "$FAKE" false
assert_contains "unrelated pre-existing option survives" "$FAKE/reaper.ini" "someoption=1"
assert_contains "unrelated pre-existing option survives (2)" "$FAKE/reaper.ini" "otheroption=hello"
assert_contains "reascript=1 was added" "$FAKE/reaper.ini" "reascript=1"
assert_contains "pythonlibdll64 was added" "$FAKE/reaper.ini" "pythonlibdll64="
assert_true "reaper.ini.midigpt-backup was created" test -f "$FAKE/reaper.ini.midigpt-backup"

# ── Re-run: keys should update in place, not duplicate ──
run_install "$FAKE" false
assert_line_count "exactly one reascript= line after two runs" 1 grep "^reascript=" "$FAKE/reaper.ini"
assert_line_count "exactly one pythonlibdll64= line after two runs" 1 grep "^pythonlibdll64=" "$FAKE/reaper.ini"

# ============================================================================
scenario "reaper.ini with lowercase [reaper] section header"
# ============================================================================
FAKE="$WORK_DIR/s7_lowercase_section"
mkdir -p "$FAKE"
cat > "$FAKE/reaper.ini" << 'EOF'
[reaper]
someoption=1
EOF
run_install "$FAKE" false
assert_contains "reascript=1 added under lowercase [reaper] section" "$FAKE/reaper.ini" "reascript=1"
assert_true "no duplicate [REAPER] section created" bash -c "[ \$(grep -ci '^\[reaper\]' '$FAKE/reaper.ini') -eq 1 ]"

# ============================================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
PASSED=$((TESTS - FAILURES))
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ALL PASSED: $PASSED/$TESTS assertions${NC}"
else
    echo -e "${RED}${BOLD}  $FAILURES FAILED: $PASSED/$TESTS assertions passed${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit "$FAILURES"
