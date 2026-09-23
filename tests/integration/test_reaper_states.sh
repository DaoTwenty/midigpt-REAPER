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
# Assertions check the resulting files, not just log wording: the installer
# deliberately exits 0 with a [WARN] when something it tried failed, so
# "the log mentions X" passes whether X succeeded or not.
#
# This hits the real network for ReaPack's GitHub release and ReaImGui's
# codeberg release (to test the actual download paths for real) --
# everything else here is local file state.
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

assert_not_contains() {
    local desc="$1" file="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [ -f "$file" ] && ! grep -qF -- "$needle" "$file" 2>/dev/null; then
        pass "$desc"
    else
        fail_test "$desc"
    fi
}

# Lines of reaper.ini's first [reaper] section (header matched
# case-insensitively, as REAPER does) -- i.e. what REAPER actually reads.
# Keys written into any other section, or a duplicate [REAPER] section
# further down, don't count.
reaper_section() {
    awk '
        /^\[.*\][ \t]*$/ {
            if (seen) exit
            in_s = (tolower($0) ~ /^\[reaper\][ \t]*$/)
            if (in_s) seen = 1
            next
        }
        in_s { print }
    ' "$1"
}

# Value of a key inside reaper.ini's [reaper] section (empty if absent).
reaper_key() { reaper_section "$1" | sed -n "s/^$2=//p" | head -n 1; }

# The shape checks every reaper.ini the installer touched must pass.
assert_ini_well_formed() {
    local label="$1" ini="$2" libdir libfile
    assert_true "$label -- exactly one [reaper] section (case-insensitive)" \
        bash -c "[ \$(grep -ci '^\[reaper\]' '$ini') -eq 1 ]"
    assert_true "$label -- reascript=1 is inside the [reaper] section" \
        test "$(reaper_key "$ini" reascript)" = "1"
    libdir="$(reaper_key "$ini" pythonlibpath64)"
    libfile="$(reaper_key "$ini" pythonlibdll64)"
    assert_true "$label -- pythonlibpath64/pythonlibdll64 are inside the [reaper] section" \
        test -n "$libdir" -a -n "$libfile"
    assert_true "$label -- they point to an existing libpython ($libdir/$libfile)" \
        test -f "$libdir/$libfile"
    assert_false "$label -- the library isn't inside a venv" \
        bash -c "case '$libdir' in */.venv/*|*/.venv) exit 0 ;; *) exit 1 ;; esac"
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
assert_contains "ReaPack checksum-verified against GitHub's digest" "$WORK_DIR/last_run.log" \
    "ReaPack installed and checksum-verified"
# Check the files, not the log: "ReaImGui not installed" also mentions ReaImGui.
assert_true  "ReaImGui native binary installed (non-empty)" \
    bash -c "find '$FAKE/UserPlugins' -name 'reaper_imgui-*' -size +100k | grep -q ."
assert_true  "ReaImGui Python API installed (imgui.py -- the dashboard imports it)" \
    test -s "$FAKE/Scripts/ReaTeam Extensions/API/imgui.py"
assert_not_contains "no ReaImGui download-failure warning" "$WORK_DIR/last_run.log" "ReaImGui download failed"
assert_contains "reports reaper.ini not found (fresh REAPER, never launched)" "$WORK_DIR/last_run.log" \
    "reaper.ini not found"

# ============================================================================
scenario "Re-run on the same state (idempotency)"
# ============================================================================
run_install "$FAKE" false
assert_contains "second run detects ReaPack already installed (no re-download)" "$WORK_DIR/last_run.log" \
    "ReaPack already installed"
assert_contains "second run detects ReaImGui already installed" "$WORK_DIR/last_run.log" \
    "ReaImGui already installed"
assert_not_contains "no ReaImGui re-download on re-run" "$WORK_DIR/last_run.log" "Installing ReaImGui"
assert_line_count "exactly one ReaPack binary present (no duplicate downloads)" 1 \
    find "$FAKE/UserPlugins" -iname "reaper_reapack*"

# ============================================================================
scenario "Only the ReaImGui binary present (e.g. older installer) -- repaired"
# ============================================================================
FAKE="$WORK_DIR/s3_binary_only"
mkdir -p "$FAKE/UserPlugins"
touch "$FAKE/UserPlugins/reaper_imgui-placeholder"
run_install "$FAKE" false
assert_true  "missing imgui.py gets installed" test -s "$FAKE/Scripts/ReaTeam Extensions/API/imgui.py"
assert_true  "the real native binary gets installed" \
    bash -c "find '$FAKE/UserPlugins' -name 'reaper_imgui-*' -size +100k | grep -q ."
assert_false "no __startup.lua written (direct download, no ReaPack bootstrap)" test -f "$FAKE/Scripts/__startup.lua"
assert_true  "ReaPack still installed independently" bash -c "find '$FAKE/UserPlugins' -iname 'reaper_reapack*' | grep -q ."

# ============================================================================
scenario "Pre-existing __startup.lua with unrelated user content (unchanged)"
# ============================================================================
FAKE="$WORK_DIR/s4_user_startup"
mkdir -p "$FAKE/Scripts"
cat > "$FAKE/Scripts/__startup.lua" << 'EOF'
-- my own startup stuff, unrelated to MIDI-GPT
reaper.ShowConsoleMsg("hello from my own script\n")
EOF
run_install "$FAKE" false
assert_contains "user's own startup content survives" "$FAKE/Scripts/__startup.lua" "hello from my own script"
run_install "$FAKE" false
assert_contains "user's content still survives after a second run" "$FAKE/Scripts/__startup.lua" \
    "hello from my own script"

# ============================================================================
scenario "REAPER 'running' (non-interactive) -- installer exits with error"
# ============================================================================
FAKE="$WORK_DIR/s5_running"
mkdir -p "$FAKE"
run_install "$FAKE" true
# Should exit with non-zero because REAPER is running and we're non-interactive
RUN_EXIT=$?
TESTS=$((TESTS + 1))
if [ "$RUN_EXIT" -ne 0 ]; then pass "install.sh exits non-zero when REAPER is running (non-interactive)"; else fail_test "install.sh should exit non-zero when REAPER is running (non-interactive)"; fi
assert_false "symlink NOT created (install exits early)" test -L "$FAKE/Scripts/MIDI-GPT"
assert_false "ReaPack NOT downloaded" bash -c "find '$FAKE/UserPlugins' -iname 'reaper_reapack*' 2>/dev/null | grep -q ."
assert_contains "explains REAPER must be closed" "$WORK_DIR/last_run.log" \
    "REAPER is currently running"

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
cp "$FAKE/reaper.ini" "$WORK_DIR/s6_original.ini"
run_install "$FAKE" false
RUN_EXIT=$?
# The reaper.ini keys below are written partway through Step 5, so they can
# all look right even if the installer died later in that step (set -e).
TESTS=$((TESTS + 1))
if [ "$RUN_EXIT" -eq 0 ]; then pass "install.sh exits 0"; else fail_test "install.sh exited $RUN_EXIT"; fi
assert_contains "installer runs to completion" "$WORK_DIR/last_run.log" "Installation Complete"
assert_ini_well_formed "after first run" "$FAKE/reaper.ini"
assert_true "unrelated options survive in the [reaper] section" \
    bash -c "[ \"\$1\" = 1 ] && [ \"\$2\" = hello ]" _ \
    "$(reaper_key "$FAKE/reaper.ini" someoption)" "$(reaper_key "$FAKE/reaper.ini" otheroption)"
assert_true "reaper.ini.midigpt-backup holds the original" cmp -s "$FAKE/reaper.ini.midigpt-backup" "$WORK_DIR/s6_original.ini"
if [ "$(uname -s)" = "Linux" ]; then
    # No vstpath key yet: REAPER's own default, kept literal (not ~-expanded), plus /usr/lib/vst3.
    assert_true "vstpath = REAPER's default + /usr/lib/vst3 (Linux)" \
        test "$(reaper_key "$FAKE/reaper.ini" vstpath)" = "~/.vst;~/.vst3;/usr/lib/vst3"
fi

# ── Re-run: keys should update in place, not duplicate ──
run_install "$FAKE" false
assert_ini_well_formed "after second run" "$FAKE/reaper.ini"
assert_line_count "exactly one reascript= line after two runs" 1 grep "^reascript=" "$FAKE/reaper.ini"
assert_line_count "exactly one pythonlibdll64= line after two runs" 1 grep "^pythonlibdll64=" "$FAKE/reaper.ini"

# ============================================================================
scenario "reaper.ini with the user's own VST paths"
# ============================================================================
# On Linux the installer appends /usr/lib/vst3 (where Sforzando's .deb puts its
# VST3; REAPER only scans ~/.vst;~/.vst3 by default). Elsewhere it must not
# touch vstpath at all.
FAKE="$WORK_DIR/s6b_user_vstpath"
mkdir -p "$FAKE"
printf '[REAPER]\nvstpath=/my/plugins;~/.vst3\n' > "$FAKE/reaper.ini"
run_install "$FAKE" false
run_install "$FAKE" false
if [ "$(uname -s)" = "Linux" ]; then
    assert_true "user's paths kept, /usr/lib/vst3 appended (Linux)" \
        test "$(reaper_key "$FAKE/reaper.ini" vstpath)" = "/my/plugins;~/.vst3;/usr/lib/vst3"
else
    assert_true "vstpath left exactly as it was (non-Linux)" \
        test "$(reaper_key "$FAKE/reaper.ini" vstpath)" = "/my/plugins;~/.vst3"
fi
assert_line_count "exactly one vstpath= line after two runs" 1 grep "^vstpath=" "$FAKE/reaper.ini"

# ============================================================================
scenario "reaper.ini with lowercase [reaper] section header and another section"
# ============================================================================
FAKE="$WORK_DIR/s7_lowercase_section"
mkdir -p "$FAKE"
cat > "$FAKE/reaper.ini" << 'EOF'
[reaper]
someoption=1
[audioconfig]
srate=48000
EOF
run_install "$FAKE" false
assert_ini_well_formed "lowercase header" "$FAKE/reaper.ini"
assert_true "keys didn't land in the other section" \
    bash -c "! sed -n '/^\[audioconfig\]/,\$p' '$FAKE/reaper.ini' | grep -qE '^(reascript|pythonlib)'"

# ============================================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
PASSED=$((TESTS - FAILURES))
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ALL PASSED: $PASSED/$TESTS assertions${NC}"
else
    echo -e "${RED}${BOLD}  $FAILURES FAILED: $PASSED/$TESTS assertions passed${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit "$FAILURES"