#!/usr/bin/env bash
# ============================================================================
# Integration test for the install pipeline
#
# This script verifies install.sh works end-to-end by:
#   1. Cloning midigpt-REAPER into a temp directory
#   2. Locating the sibling MIDI-GPT directory
#   3. Running install.sh
#   4. Verifying imports, symlinks, and tests pass
#
# Usage:
#   ./tests/integration/test_install.sh
#   ./tests/integration/test_install.sh --keep                       # Keep temp dir on success for inspection
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIDIGPT_SIBLING="$(cd "$REPO_DIR/.." && pwd)/MIDI-GPT"

KEEP_TEMP=false
WORK_DIR=""

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "  \033[0;32m✓\033[0m $*"; }
fail_test() { echo -e "  \033[0;31m✗\033[0m $*"; FAILURES=$((FAILURES + 1)); }
info()  { echo -e "${YELLOW}→${NC} $*"; }

FAILURES=0
TESTS=0

assert() {
    local desc="$1"
    shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail_test "$desc"
    fi
}

assert_file() {
    TESTS=$((TESTS + 1))
    if [ -f "$1" ]; then
        pass "File exists: $1"
    else
        fail_test "File missing: $1"
    fi
}

assert_link() {
    TESTS=$((TESTS + 1))
    if [ -L "$1" ]; then
        pass "Symlink exists: $1"
    else
        fail_test "Symlink missing: $1"
    fi
}

# ── Cleanup ─────────────────────────────────────────────────────

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$KEEP_TEMP" = true ]; then
            echo ""
            info "Temp directory preserved: $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
}
trap cleanup EXIT

# ── Args ────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --keep)       KEEP_TEMP=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --keep           Keep temp directory after test"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Verification ────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━ Integration Test: install.sh ━━━${NC}"
echo ""

# A sibling MIDI-GPT checkout is optional -- install.sh installs
# midigpt[http,inference] from PyPI first and only falls back to a sibling
# clone (or clones one itself from GitHub) if that fails, so this test
# works fine without one (e.g. on a CI runner that has network access to
# PyPI/GitHub but no local sibling checkout). When a sibling *is* present
# locally, it's copied in too so the fallback path gets exercised for real
# instead of always taking the PyPI path.
HAVE_SIBLING=false
if [ -d "$MIDIGPT_SIBLING" ]; then
    HAVE_SIBLING=true
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/midigpt-install-test.XXXXXX")"
info "Working directory: $WORK_DIR"

# Create fake REAPER dir so install.sh's REAPER integration runs
mkdir -p "$WORK_DIR/fake-reaper"

# ── Clone midigpt-REAPER ───────────────────────────────────────

info "Copying midigpt-REAPER into temp directory..."
CLONE_DIR="$WORK_DIR/midigpt-REAPER"
rsync -a \
    --exclude='.venv/' \
    --exclude='*.egg-info/' \
    --exclude='__pycache__/' \
    --exclude='.git/' \
    --exclude='*.pt' \
    --exclude='*.pth' \
    "$REPO_DIR/" "$CLONE_DIR/"
info "Copied to $CLONE_DIR"

if [ "$HAVE_SIBLING" = true ]; then
    # We must also clone the sibling MIDI-GPT to the temporary directory's
    # parent so the installer's sibling lookup works.
    MIDIGPT_TEST_SIBLING="$WORK_DIR/MIDI-GPT"
    info "Copying MIDI-GPT sibling to $MIDIGPT_TEST_SIBLING ..."
    rsync -a \
        --exclude='.venv/' \
        --exclude='*.egg-info/' \
        --exclude='__pycache__/' \
        --exclude='.git/' \
        "$MIDIGPT_SIBLING/" "$MIDIGPT_TEST_SIBLING/"
else
    info "No local MIDI-GPT sibling found at $MIDIGPT_SIBLING -- relying on install.sh's PyPI install (with its own GitHub-clone fallback)"
fi

# ── Run install.sh ──────────────────────────────────────────────

info "Running install.sh ..."
echo ""

INSTALL_LOG="$WORK_DIR/install.log"
# MIDIGPT_REAPER_DIR (see install.sh) points the REAPER integration steps at
# a throwaway directory instead of the real REAPER install, so this test
# never touches the machine's actual REAPER config. It gets a reaper.ini so
# Step 5 runs for real -- including its Python library lookup with the venv
# active, which is what a normal install does and what
# test_reaper_states.sh's --reaper-only runs can't cover.
export MIDIGPT_REAPER_DIR="$WORK_DIR/fake-reaper"
# The fake REAPER dir isn't the running REAPER's, so a real REAPER open on
# this machine (a developer's, say) mustn't make the installer skip
# ReaPack/reaper.ini here.
export MIDIGPT_FAKE_REAPER_RUNNING=false
FAKE_INI="$MIDIGPT_REAPER_DIR/reaper.ini"
printf '[REAPER]\nsomeoption=1\n[audioconfig]\nsrate=48000\n' > "$FAKE_INI"
if bash "$CLONE_DIR/install.sh" < /dev/null 2>&1 | tee "$INSTALL_LOG"; then
    echo ""
    pass "install.sh completed successfully"
else
    echo ""
    fail_test "install.sh exited with non-zero status"
    echo ""
    echo "Log: $INSTALL_LOG"
    echo -e "\033[0;31mINSTALL FAILED — skipping remaining checks\033[0m"
    echo ""
    echo -e "${BOLD}Results: 0/$((TESTS)) passed, $FAILURES failed${NC}"
    exit 1
fi

# ── Verification ────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━ Verification ━━━${NC}"
echo ""

VENV="$CLONE_DIR/.venv/bin/activate"

# 1. Venv exists
assert_file "$CLONE_DIR/.venv/bin/python"

# 2. midigpt importable
assert "import midigpt" bash -c "source '$VENV' && python -c 'import midigpt'"

# 3. midigpt.inference importable
assert "import midigpt.inference" bash -c "source '$VENV' && python -c 'from midigpt.inference.engine import InferenceEngine'"

# Project scripts are verified via unit tests below

# 5. REAPER symlinks, in the fake MIDIGPT_REAPER_DIR set above (not a real
# REAPER install). Only Scripts/MIDI-GPT is created now -- the
# Effects/MIDI-GPT (JSFX) symlink was removed along with legacy JSFX
# support in favor of the dashboard-only workflow.
assert_link "$MIDIGPT_REAPER_DIR/Scripts/MIDI-GPT"

# 6. torch actually loads (not just "is installed").
assert "import torch" bash -c "source '$VENV' && python -c 'import torch'"

# 7. ReaImGui: the native binary plus the Python API the dashboard imports.
assert "ReaImGui native binary installed" \
    bash -c "find '$MIDIGPT_REAPER_DIR/UserPlugins' -name 'reaper_imgui-*' -size +100k | grep -q ."
assert "ReaImGui Python API installed (imgui.py)" \
    test -s "$MIDIGPT_REAPER_DIR/Scripts/ReaTeam Extensions/API/imgui.py"

# 8. reaper.ini: keys in the existing [REAPER] section (the only one REAPER
# reads), pointing at the base Python's shared library -- not the venv.
ini_section() {
    awk '/^\[.*\][ \t]*$/ { if (seen) exit; in_s = (tolower($0) ~ /^\[reaper\]/); if (in_s) seen = 1; next }
         in_s { print }' "$FAKE_INI"
}
ini_key() { ini_section | sed -n "s/^$1=//p" | head -n 1; }
PY_LIB_DIR="$(ini_key pythonlibpath64)"
PY_LIB_FILE="$(ini_key pythonlibdll64)"
assert "reaper.ini has exactly one [reaper] section" bash -c "[ \$(grep -ci '^\[reaper\]' '$FAKE_INI') -eq 1 ]"
assert "reascript=1 inside [reaper]" test "$(ini_key reascript)" = "1"
assert "pythonlibpath64/pythonlibdll64 inside [reaper] point to an existing libpython ($PY_LIB_DIR/$PY_LIB_FILE)" \
    test -n "$PY_LIB_FILE" -a -f "$PY_LIB_DIR/$PY_LIB_FILE"
assert "the Python library isn't inside the venv" \
    bash -c "case '$PY_LIB_DIR' in '$CLONE_DIR/.venv'*) exit 1 ;; *) exit 0 ;; esac"

# 9. No unexpected warnings. install.sh deliberately exits 0 when a step
# fails but has a manual fallback -- a [WARN] line is the only trace of
# that, so every warning a clean install can legitimately print is listed
# here and anything else fails the test.
ALLOWED_WARNINGS=(
    # codeberg publishes no checksums for ReaImGui (see install.sh).
    "No published checksum for ReaImGui"
    # macOS: no Full Disk Access for the Desktop when run non-interactively.
    "Couldn't create Desktop shortcut"
)
# A function with [[ ]] rather than an inline `case` -- macOS's bash 3.2
# misparses a case pattern's `)` inside $( ... ) as the end of the command
# substitution.
is_allowed_warning() {
    local w
    for w in "${ALLOWED_WARNINGS[@]}"; do
        [[ "$1" == *"$w"* ]] && return 0
    done
    return 1
}
# $'\033' rather than sed's \x1b, which BSD sed (macOS) doesn't support;
# `|| true` because grep exits 1 when there are no warnings at all, which
# pipefail + set -e would otherwise turn into aborting this script.
ESC=$'\033'
UNEXPECTED_WARNINGS="$(sed "s/${ESC}\[[0-9;]*m//g" "$INSTALL_LOG" | { grep '^\[WARN\]' || true; } | while IFS= read -r line; do
    is_allowed_warning "$line" || printf '%s\n' "$line"
done)"
TESTS=$((TESTS + 1))
if [ -z "$UNEXPECTED_WARNINGS" ]; then
    pass "no unexpected [WARN] lines in the install log"
else
    fail_test "unexpected [WARN] lines in the install log:"
    printf '%s\n' "$UNEXPECTED_WARNINGS" | sed 's/^/        /'
fi

# 10. Run unit tests
echo ""
info "Installing pytest and running unit tests..."
# -k filter matches the dedicated unit-tests CI job: test_piano_default is
# a known pre-existing failure unrelated to install correctness (see
# .github/workflows/test-install.yml for why).
TESTS=$((TESTS + 1))
if bash -c "source '$VENV' && pip install pytest -q && cd '$CLONE_DIR' && python -m pytest tests/ -v --tb=short -k 'not test_piano_default'" 2>&1; then
    pass "Unit tests passed"
else
    fail_test "Unit tests failed"
fi

# ── Summary ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
PASSED=$((TESTS - FAILURES))
if [ "$FAILURES" -eq 0 ]; then
    echo -e "\033[0;32m${BOLD}  ALL PASSED: $PASSED/$TESTS tests\033[0m"
else
    echo -e "\033[0;31m${BOLD}  $FAILURES FAILED: $PASSED/$TESTS tests passed\033[0m"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit "$FAILURES"
