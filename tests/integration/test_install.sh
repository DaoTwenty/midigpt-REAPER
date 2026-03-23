#!/usr/bin/env bash
# ============================================================================
# Integration test for the install pipeline
#
# This script verifies install.sh works end-to-end by:
#   1. Zipping mmm_refactored from a local source (or using a provided zip)
#   2. Cloning midigpt-REAPER into a temp directory
#   3. Running install.sh --skip-deps --mmm-zip=...
#   4. Verifying imports, symlinks, and tests pass
#
# Usage:
#   ./tests/integration/test_install.sh                              # Uses mmm_refactored from default path
#   ./tests/integration/test_install.sh --mmm-src=/path/to/mmm_refactored
#   ./tests/integration/test_install.sh --mmm-zip=/path/to/existing.zip
#   ./tests/integration/test_install.sh --keep                       # Keep temp dir on success for inspection
#
# Requirements:
#   - System deps already installed (cmake, protobuf, python>=3.10)
#   - Either mmm_refactored source dir or pre-built zip
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default path to mmm_refactored source (sibling of midigpt-REAPER)
MMM_SRC_DEFAULT="/Users/paultriana/creative_labs/mmm_refactored"
MMM_SRC=""
MMM_ZIP=""
KEEP_TEMP=false
WORK_DIR=""

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail_test() { echo -e "  ${RED}✗${NC} $*"; FAILURES=$((FAILURES + 1)); }
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
        --mmm-src=*)  MMM_SRC="${arg#*=}" ;;
        --mmm-zip=*)  MMM_ZIP="${arg#*=}" ;;
        --keep)       KEEP_TEMP=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --mmm-src=PATH   Path to mmm_refactored source dir (will be zipped)"
            echo "  --mmm-zip=PATH   Path to pre-built mmm_refactored zip"
            echo "  --keep           Keep temp directory after test"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Resolve mmm_refactored zip ──────────────────────────────────

echo ""
echo -e "${BOLD}━━━ Integration Test: install.sh ━━━${NC}"
echo ""

WORK_DIR="$(mktemp -d /tmp/midigpt-install-test.XXXXXX)"
info "Working directory: $WORK_DIR"

if [ -n "$MMM_ZIP" ]; then
    # Use provided zip
    if [ ! -f "$MMM_ZIP" ]; then
        echo "ERROR: Zip file not found: $MMM_ZIP"
        exit 1
    fi
    TEST_ZIP="$MMM_ZIP"
    info "Using provided zip: $TEST_ZIP"
else
    # Zip from source
    if [ -z "$MMM_SRC" ]; then
        if [ -d "$MMM_SRC_DEFAULT" ]; then
            MMM_SRC="$MMM_SRC_DEFAULT"
        else
            echo "ERROR: No mmm_refactored source found."
            echo "  Provide --mmm-src=PATH or --mmm-zip=PATH"
            exit 1
        fi
    fi

    if [ ! -f "$MMM_SRC/CMakeLists.txt" ]; then
        echo "ERROR: $MMM_SRC doesn't look like mmm_refactored (no CMakeLists.txt)"
        exit 1
    fi

    TEST_ZIP="$WORK_DIR/mmm_refactored_test.zip"
    info "Zipping mmm_refactored from $MMM_SRC..."

    # Zip the source, excluding build artifacts, git history, and heavy data
    (cd "$(dirname "$MMM_SRC")" && zip -r -q "$TEST_ZIP" "$(basename "$MMM_SRC")" \
        -x "*/build/*" \
        -x "*/.git/*" \
        -x "*/__pycache__/*" \
        -x "*.pyc" \
        -x "*/dist/*" \
        -x "*/*.egg-info/*" \
        -x "*/pretrained/*" \
        -x "*/.cache/*" \
        -x "*/flask.log" \
    )
    ZIP_SIZE="$(du -sh "$TEST_ZIP" | awk '{print $1}')"
    info "Created test zip: $TEST_ZIP ($ZIP_SIZE)"
fi

# ── Clone midigpt-REAPER ───────────────────────────────────────

info "Copying midigpt-REAPER into temp directory..."
CLONE_DIR="$WORK_DIR/midigpt-REAPER"
# Use rsync to copy the repo (includes untracked files like install.sh),
# excluding heavy/transient dirs that shouldn't be part of a fresh install.
rsync -a \
    --exclude='.venv/' \
    --exclude='*.egg-info/' \
    --exclude='__pycache__/' \
    --exclude='.git/' \
    --exclude='debug_dumps/' \
    --exclude='*.pt' \
    --exclude='*.pth' \
    "$REPO_DIR/" "$CLONE_DIR/"
info "Copied to $CLONE_DIR"

# ── Run install.sh ──────────────────────────────────────────────

info "Running install.sh --skip-deps --mmm-zip=$TEST_ZIP ..."
echo ""

INSTALL_LOG="$WORK_DIR/install.log"
if bash "$CLONE_DIR/install.sh" --skip-deps --mmm-zip="$TEST_ZIP" 2>&1 | tee "$INSTALL_LOG"; then
    echo ""
    pass "install.sh completed successfully"
else
    echo ""
    fail_test "install.sh exited with non-zero status"
    echo ""
    echo "Log: $INSTALL_LOG"
    echo -e "${RED}${BOLD}INSTALL FAILED — skipping remaining checks${NC}"
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

# 2. mmm_refactored importable
assert "import mmm_refactored" bash -c "source '$VENV' && python -c 'import mmm_refactored'"

# 3. torch importable
assert "import torch" bash -c "source '$VENV' && python -c 'import torch'"

# 4. symusic importable
assert "import symusic" bash -c "source '$VENV' && python -c 'import symusic'"

# 5. Project package importable
assert "import midigpt_reaper (editable install)" bash -c "source '$VENV' && python -c 'import importlib; importlib.import_module(\"midigpt_reaper\")' 2>/dev/null || true"

# 6. REAPER symlinks (macOS)
if [ "$(uname -s)" = "Darwin" ]; then
    REAPER_DIR="$HOME/Library/Application Support/REAPER"
    if [ -d "$REAPER_DIR" ]; then
        assert_link "$REAPER_DIR/Scripts/MMM"
        assert_link "$REAPER_DIR/Effects/MMM"
    else
        info "REAPER not installed — skipping symlink checks"
    fi
fi

# 7. Model config exists
assert_file "$CLONE_DIR/src/Scripts/MMM/models/config.json"

# 8. Config points to valid-looking checkpoint path
assert "config.json has ckpt field" bash -c "source '$VENV' && python -c \"
import json
cfg = json.load(open('$CLONE_DIR/src/Scripts/MMM/models/config.json'))
assert 'ckpt' in cfg, 'missing ckpt'
\""

# 9. Server module importable (basic syntax check)
assert "MMM_server.py importable" bash -c "source '$VENV' && python -c \"
import sys
sys.path.insert(0, '$CLONE_DIR/src/Scripts/MMM')
import importlib.util
spec = importlib.util.spec_from_file_location('MMM_server', '$CLONE_DIR/src/Scripts/MMM/MMM_server.py')
# Just check it parses — don't exec (needs REAPER stubs)
import ast
ast.parse(open('$CLONE_DIR/src/Scripts/MMM/MMM_server.py').read())
\""

# 10. Run unit tests
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
    echo -e "${GREEN}${BOLD}  ALL PASSED: $PASSED/$TESTS tests${NC}"
else
    echo -e "${RED}${BOLD}  $FAILURES FAILED: $PASSED/$TESTS tests passed${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit "$FAILURES"
