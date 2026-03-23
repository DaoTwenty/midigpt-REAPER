#!/usr/bin/env bash
# ============================================================================
# Build a distributable MIDI-GPT for REAPER release package
#
# Creates a single zip file containing everything a user needs:
#   - midigpt-REAPER source (scripts, effects, installer)
#   - mmm_refactored C++ source (minimal build-only files)
#   - Model checkpoint (model.pt)
#
# Usage:
#   ./build_release.sh                                    # Uses defaults
#   ./build_release.sh --mmm-src=/path/to/mmm_refactored  # Custom mmm path
#   ./build_release.sh --model=/path/to/model.pt          # Custom model path
#   ./build_release.sh --output=release.zip               # Custom output name
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MMM_SRC="${SCRIPT_DIR}/../mmm_refactored"
MODEL_PT="${SCRIPT_DIR}/src/Scripts/MMM/models/model.pt"
OUTPUT=""
VERSION="$(date +%Y%m%d)"

# ── Colors ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

# ── Args ────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --mmm-src=*)  MMM_SRC="${arg#*=}" ;;
        --model=*)    MODEL_PT="${arg#*=}" ;;
        --output=*)   OUTPUT="${arg#*=}" ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --mmm-src=PATH   Path to mmm_refactored source (default: ../mmm_refactored)"
            echo "  --model=PATH     Path to model.pt checkpoint (default: src/Scripts/MMM/models/model.pt)"
            echo "  --output=PATH    Output zip path (default: MIDI-GPT-for-REAPER-YYYYMMDD.zip)"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) warn "Unknown option: $arg" ;;
    esac
done

if [ -z "$OUTPUT" ]; then
    OUTPUT="${SCRIPT_DIR}/MIDI-GPT-for-REAPER-${VERSION}.zip"
fi

# ── Validate inputs ─────────────────────────────────────────────

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   MIDI-GPT for REAPER — Release Builder   ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

if [ ! -d "$MMM_SRC" ]; then
    fail "mmm_refactored source not found at: $MMM_SRC"
fi

if [ ! -f "$MMM_SRC/CMakeLists.txt" ]; then
    fail "$MMM_SRC doesn't look like mmm_refactored (no CMakeLists.txt)"
fi

if [ ! -f "$MODEL_PT" ]; then
    warn "Model checkpoint not found at: $MODEL_PT"
    echo "  The release will be created without model.pt."
    echo "  Users will need to provide their own."
    HAS_MODEL=false
else
    HAS_MODEL=true
    MODEL_SIZE="$(du -sh "$MODEL_PT" | awk '{print $1}')"
    info "Model checkpoint: $MODEL_PT ($MODEL_SIZE)"
fi

# ── Build staging directory ─────────────────────────────────────

STAGING="$(mktemp -d /tmp/midigpt-release.XXXXXX)"
RELEASE_DIR="$STAGING/MIDI-GPT-for-REAPER"
mkdir -p "$RELEASE_DIR"

info "Staging directory: $STAGING"

# ── 1. Copy midigpt-REAPER source ──────────────────────────────

info "Copying midigpt-REAPER source (include-list only)..."

# ── Installers & launchers (root level) ──
for f in \
    "install.sh" \
    "install.ps1" \
    "Install - Mac.command" \
    "Install - Linux.sh" \
    "Install - Windows.bat" \
    "start_mmm_server.sh" \
    "Start Server - Mac.command" \
    "Start Server - Windows.bat" \
    ; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$RELEASE_DIR/$f"
done

# ── Documentation ──
cp "$SCRIPT_DIR/README.md" "$RELEASE_DIR/"
cp "$SCRIPT_DIR/docs.html" "$RELEASE_DIR/"

# ── Python package metadata ──
cp "$SCRIPT_DIR/pyproject.toml" "$RELEASE_DIR/"

# ── Setup script (creates REAPER symlinks) ──
mkdir -p "$RELEASE_DIR/scripts"
cp "$SCRIPT_DIR/scripts/setup.py" "$RELEASE_DIR/scripts/"

# ── Source: Scripts (server, REAPER script, extraction, config) ──
mkdir -p "$RELEASE_DIR/src/Scripts/MMM/models"
for f in MMM_server.py REAPER_mmm_infill.py midi_extraction.py; do
    cp "$SCRIPT_DIR/src/Scripts/MMM/$f" "$RELEASE_DIR/src/Scripts/MMM/$f"
done
cp "$SCRIPT_DIR/src/Scripts/MMM/models/config.json" "$RELEASE_DIR/src/Scripts/MMM/models/"

# ── Source: Effects (JSFX) ──
mkdir -p "$RELEASE_DIR/src/Effects/MMM"
cp "$SCRIPT_DIR/src/Effects/MMM/MMM Global Options.js" "$RELEASE_DIR/src/Effects/MMM/"
cp "$SCRIPT_DIR/src/Effects/MMM/MMM Track Options (Density-Polyphony).js" "$RELEASE_DIR/src/Effects/MMM/"

ok "Source copied"

# ── 1b. Rebuild docs.html with embedded README ───────────────────
# Run build_docs.py from the source tree against the release copy

info "Embedding README.md into docs.html..."
python3 -c "
import pathlib, re

root = pathlib.Path('$RELEASE_DIR')
readme = (root / 'README.md').read_text()
readme_safe = readme.replace('</script>', '<\\\\/script>')

html_path = root / 'docs.html'
html = html_path.read_text()

script_re = re.compile(
    r'(<script id=\"readme-source\" type=\"text/plain\">)\n.*?\n(</script>)',
    re.DOTALL,
)
if script_re.search(html):
    html = script_re.sub(lambda m: f'{m.group(1)}\n{readme_safe}\n{m.group(2)}', html)
    html_path.write_text(html)
    print(f'docs.html updated ({len(readme)} chars)')
else:
    print('WARNING: could not find readme-source tag in docs.html')
"
ok "docs.html updated"

# ── 2. Build minimal mmm_refactored zip ────────────────────────

info "Building minimal mmm_refactored archive..."

# Only include files needed for `pip install .` (C++ build)
MMM_STAGING="$STAGING/mmm_build"
mkdir -p "$MMM_STAGING/mmm_refactored"

# Root build files
cp "$MMM_SRC/CMakeLists.txt" "$MMM_STAGING/mmm_refactored/"
cp "$MMM_SRC/pyproject.toml" "$MMM_STAGING/mmm_refactored/"

# C++ source
rsync -a \
    "$MMM_SRC/src/" "$MMM_STAGING/mmm_refactored/src/" \
    --exclude='__pycache__/' \
    --exclude='*.pyc'

# Include headers
if [ -d "$MMM_SRC/include" ]; then
    rsync -a "$MMM_SRC/include/" "$MMM_STAGING/mmm_refactored/include/"
fi

# Libraries (protobuf schemas + midifile — needed for CMake)
mkdir -p "$MMM_STAGING/mmm_refactored/libraries"

# protobuf library (proto files + headers + CMakeLists)
rsync -a \
    "$MMM_SRC/libraries/protobuf/" "$MMM_STAGING/mmm_refactored/libraries/protobuf/" \
    --exclude='build/' \
    --exclude='out/' \
    --exclude='.vs/'

# midifile library (headers + core source + tools + CMakeLists)
rsync -a \
    "$MMM_SRC/libraries/midifile/" "$MMM_STAGING/mmm_refactored/libraries/midifile/" \
    --exclude='visual-studio/' \
    --exclude='build/'

# Create the zip
(cd "$MMM_STAGING" && zip -r -q "$RELEASE_DIR/mmm_refactored.zip" mmm_refactored/)
MMM_ZIP_SIZE="$(du -sh "$RELEASE_DIR/mmm_refactored.zip" | awk '{print $1}')"
ok "mmm_refactored.zip created ($MMM_ZIP_SIZE)"

# ── 3. Copy model checkpoint ───────────────────────────────────

if [ "$HAS_MODEL" = true ]; then
    info "Copying model checkpoint..."
    mkdir -p "$RELEASE_DIR/models"
    cp "$MODEL_PT" "$RELEASE_DIR/models/model.pt"
    ok "model.pt copied"
fi

# ── 4. Create final release zip ────────────────────────────────

info "Creating release archive..."
rm -f "$OUTPUT"
(cd "$STAGING" && zip -r -q "$OUTPUT" "MIDI-GPT-for-REAPER/")

# ── Cleanup ─────────────────────────────────────────────────────

rm -rf "$STAGING"

# ── Summary ─────────────────────────────────────────────────────

RELEASE_SIZE="$(du -sh "$OUTPUT" | awk '{print $1}')"

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Release package created!${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  File: $OUTPUT"
echo "  Size: $RELEASE_SIZE"
echo ""
echo "  Contents:"
echo "    - midigpt-REAPER source"
echo "    - mmm_refactored.zip (minimal build files: $MMM_ZIP_SIZE)"
if [ "$HAS_MODEL" = true ]; then
    echo "    - models/model.pt ($MODEL_SIZE)"
fi
echo "    - Install - Mac.command (macOS double-click installer)"
echo "    - Install - Linux.sh (Linux installer)"
echo "    - Install - Windows.bat (Windows installer)"
echo ""
echo "  Users extract the zip and double-click the installer for their OS."
echo ""
