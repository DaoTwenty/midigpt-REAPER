#!/usr/bin/env bash
# ============================================================================
# Build a distributable MIDI-GPT for REAPER release package
#
# Creates a single zip file containing everything a user needs:
#   - midigpt-REAPER source (scripts, effects, installers, launchers)
#
# Usage:
#   ./build_release.sh                                    # Uses defaults
#   ./build_release.sh --output=release.zip               # Custom output name
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
# This script lives in dev/ -- SCRIPT_DIR resolves to the repo root (one
# level up), which is what every path below actually means by it.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
        --output=*)   OUTPUT="${arg#*=}" ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
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

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   MIDI-GPT for REAPER — Release Builder   ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Build staging directory ─────────────────────────────────────

STAGING="$(mktemp -d /tmp/midigpt-release.XXXXXX)"
RELEASE_DIR="$STAGING/MIDI-GPT-for-REAPER"
mkdir -p "$RELEASE_DIR"

info "Staging directory: $STAGING"

# ── 1. Copy midigpt-REAPER source ──────────────────────────────

info "Copying midigpt-REAPER source..."

# ── Installers & launchers (root level) ──
for f in \
    "install.sh" \
    "install.ps1" \
    "Install - Mac.command" \
    "Install - Linux.sh" \
    "Install - Windows.bat" \
    "start_midigpt_server.sh" \
    "Start Server - Mac.command" \
    "Start Server - Windows.bat" \
    "VST.md" \
    "INSTRUMENTS.md" \
    ; do
    [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$RELEASE_DIR/$f"
done

# ── Documentation ──
info "Regenerating docs/index.html from README.md + INSTRUMENTS.md + VST.md..."
python3 "$SCRIPT_DIR/build_docs.py"
cp "$SCRIPT_DIR/README.md" "$RELEASE_DIR/"
mkdir -p "$RELEASE_DIR/docs"
cp "$SCRIPT_DIR/docs/index.html" "$RELEASE_DIR/docs/"
# docs/index.html's JS rewrites the README's logo URL to a relative
# "assets/logo.svg" path so it works offline (file://) -- without actually
# copying docs/assets/ too, that image (and the dashboard screenshot) is
# broken in every shipped release.
cp -R "$SCRIPT_DIR/docs/assets" "$RELEASE_DIR/docs/"

# ── Source: Scripts (REAPER script, extraction) ──
mkdir -p "$RELEASE_DIR/src/Scripts/MIDI-GPT"
midigpt_scripts=(
    "MIDI-GPT Generate.py" "MIDI-GPT Set Server.py" "MIDI-GPT Setup Tracks.py"
    "MIDI-GPT Replace Instruments.py" "MIDI-GPT.py" "midi_extraction.py"
)
for f in "${midigpt_scripts[@]}"; do
    cp "$SCRIPT_DIR/src/Scripts/MIDI-GPT/$f" "$RELEASE_DIR/src/Scripts/MIDI-GPT/$f"
done
cp -R "$SCRIPT_DIR/src/Scripts/MIDI-GPT/midigpt_dashboard" "$RELEASE_DIR/src/Scripts/MIDI-GPT/"
find "$RELEASE_DIR/src/Scripts/MIDI-GPT/midigpt_dashboard" -name "__pycache__" -exec rm -rf {} +

ok "Source copied"

# ── 2. Create final release zip ────────────────────────────────

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
echo "    - midigpt-REAPER client scripts (dashboard UI)"
echo "    - Installers & launchers"
echo ""
echo "  Users extract the zip and double-click the installer for their OS."
echo ""
