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
GREEN='\033[0;32'
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

if [ ! -d "$MIDIGPT_SIBLING" ]; then
    echo "ERROR: MIDI-GPT sibling directory not found at $MIDIGPT_SIBLING"
    exit 1
fi

WORK_DIR="$(mktemp -d "$REPO_DIR/tmp/midigpt-install-test.XXXXXX")"
info "Working directory: $WORK_DIR"

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

# We must also clone the sibling MIDI-GPT to the temporary directory's parent
# so the installer's sibling lookup works.
MIDIGPT_TEST_SIBLING="$WORK_DIR/MIDI-GPT"
info "Copying MIDI-GPT sibling to $MIDIGPT_TEST_SIBLING ..."
rsync -a \
    --exclude='.venv/' \
    --exclude='*.egg-info/' \
    --exclude='__pycache__/' \
    --exclude='.git/' \
    "$MIDIGPT_SIBLING/" "$MIDIGPT_TEST_SIBLING/"

# ── Run install.sh ──────────────────────────────────────────────

info "Running install.sh ..."
echo ""

INSTALL_LOG="$WORK_DIR/install.log"
# Run with REAPER config skip to prevent mutating system reaper.ini in tests
export MIDIGPT_SYSTEM_SITE_PACKAGES=true
export PYTHON_CMD="/Users/paultriana/creative_labs/MIDI-GPT/.venv/bin/python"
if bash "$CLONE_DIR/install.sh" --skip-reaper-config 2>&1 | tee "$INSTALL_LOG"; then
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

# 5. REAPER symlinks (macOS)
if [ "$(uname -s)" = "Darwin" ]; then
    REAPER_DIR="$HOME/Library/Application Support/REAPER"
    if [ -d "$REAPER_DIR" ]; then
        assert_link "$REAPER_DIR/Scripts/MIDI-GPT"
        assert_link "$REAPER_DIR/Effects/MIDI-GPT"
    else
        info "REAPER not installed — skipping symlink checks"
    fi
fi

# 6. Run unit tests
echo ""
info "Installing pytest and running unit tests..."
if bash -c "source '$VENV' && pip install pytest -q && cd '$CLONE_DIR' && python -m pytest tests/ -v --tb=short" 2>&1; then
    pass "Unit tests passed"
    TESTS=$((TESTS + 1))
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
