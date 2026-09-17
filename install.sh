#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER — One-Click Installer
#
# Installs everything needed to run MIDI-GPT in REAPER:
#   1. System dependencies (git, python)
#   2. Python virtual environment + torch
#   3. MIDI-GPT backend library
#   4. REAPER symlinks (Scripts), plus ReaPack and ReaImGui (the dashboard
#      UI's REAPER extension dependencies)
#   5. Verification of installation
#
# ReaPack itself is installed directly (it's just an extension binary,
# downloaded over HTTPS from its GitHub release and checksum-verified
# against GitHub's own published digest before use -- it isn't code-signed,
# so this is the only integrity check available for it). The dashboard
# UI's ReaImGui extension can only be installed through REAPER's own
# ReaPack API while REAPER is running, so this installer queues it to
# install automatically the next time REAPER starts (via a small
# Scripts/__startup.lua bootstrap) -- if REAPER is currently open, it asks
# permission to close it first (never force-killed; any unsaved project
# still prompts to save) so both this and the reaper.ini setup below can
# run in the same pass, then reopens REAPER for you.
#
# Usage:
#   ./install.sh              # Full install
#   ./install.sh --skip-deps  # Skip system dependency check (if already installed)
#   ./install.sh --help       # Show help
# ============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$REPO_DIR/.venv"
PYTHON_MIN_VERSION="3.10"
SKIP_DEPS=false
SKIP_REAPER_CONFIG=false

# Target MIDI-GPT source repo path. Auto-detected at the sibling path ../MIDI-GPT.
MIDIGPT_SRC=""

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

# ── Helpers ─────────────────────────────────────────────────────

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

step() {
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
}

check_cmd() {
    command -v "$1" &>/dev/null
}

reaper_is_running() {
    # Test-only override (see tests/integration/) -- simulates REAPER
    # being open without needing a real REAPER process running.
    if [ -n "${MIDIGPT_FAKE_REAPER_RUNNING:-}" ]; then
        [ "$MIDIGPT_FAKE_REAPER_RUNNING" = "true" ]
        return
    fi
    pgrep -x "REAPER" >/dev/null 2>&1 || pgrep -x "reaper" >/dev/null 2>&1
}

# Ask REAPER to quit gracefully (triggers its own "save changes?" prompt if
# needed -- never force-kills) and wait for the process to actually exit.
quit_reaper_and_wait() {
    info "Asking REAPER to quit -- any unsaved project will prompt you to save first..."
    if [ "$PLATFORM" = "macos" ]; then
        osascript -e 'tell application "REAPER" to quit' 2>/dev/null
    else
        pkill -TERM -x reaper 2>/dev/null
    fi

    local waited=0
    while reaper_is_running && [ "$waited" -lt 120 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    if reaper_is_running; then
        warn "REAPER is still open (it may be waiting on a save prompt)."
        read -rp "  Close it manually, then press Enter to continue (Ctrl+C to abort): " _
    fi
}

relaunch_reaper() {
    if [ "$PLATFORM" = "macos" ]; then
        open -a REAPER 2>/dev/null
    elif check_cmd reaper; then
        nohup reaper >/dev/null 2>&1 &
        disown 2>/dev/null || true
    else
        warn "Could not find a 'reaper' command to relaunch it automatically -- start it manually."
        return 1
    fi
    return 0
}

open_url() {
    local url="$1"
    if [ "$PLATFORM" = "macos" ]; then
        open "$url" 2>/dev/null
    elif [ "$PLATFORM" = "windows" ]; then
        cmd.exe /c start "" "$url" 2>/dev/null
    else
        xdg-open "$url" 2>/dev/null
    fi
}

# Downloads the Arachno GM SoundFont into this repo's own soundfonts/
# folder (kept alongside the plugin, not scattered into REAPER's resource
# dir), under its real filename -- REAPER_midigpt_setup_tracks.py reads
# whatever .sf2 is actually there rather than a hardcoded name, so this
# doesn't need to match anything else exactly. Arachno is freeware and this
# is the exact .zip Arachnosoft's own download page links to (mirrored on
# Dropbox) -- not a third-party scrape. Sforzando itself is a real
# application installer, not a data file, so it's intentionally NOT
# auto-installed the same way (see the instrument-setup prompt below).
download_arachno_soundfont() {
    if ! check_cmd unzip; then
        warn "'unzip' not found -- install it, or get Arachno manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
        return 1
    fi

    local dest_dir="$REPO_DIR/soundfonts"
    if find "$dest_dir" -iname "*.sf2" 2>/dev/null | grep -q .; then
        ok "Arachno SoundFont already present in $dest_dir"
        return 0
    fi

    info "Downloading Arachno SoundFont (~140MB, may take a few minutes)..."
    mkdir -p "$dest_dir"
    local tmp_zip
    tmp_zip="$(mktemp).zip"
    if ! curl -fL --max-time 900 -o "$tmp_zip" "https://www.dropbox.com/s/2rnpya9ecb9m4jh/arachno-soundfont-10-sf2.zip?dl=1"; then
        warn "Failed to download Arachno SoundFont -- get it manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
        rm -f "$tmp_zip"
        return 1
    fi

    local inner_name dest_file
    inner_name="$(unzip -Z1 "$tmp_zip" 2>/dev/null | grep -i '\.sf2$' | head -1)"
    dest_file="$dest_dir/$inner_name"
    if [ -z "$inner_name" ] || ! unzip -p "$tmp_zip" "$inner_name" > "$dest_file" 2>/dev/null; then
        warn "Downloaded archive didn't extract cleanly -- get Arachno manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
        rm -f "$tmp_zip" "$dest_file"
        return 1
    fi
    rm -f "$tmp_zip"
    ok "Arachno SoundFont installed: $dest_file"
    return 0
}

# ── Args ────────────────────────────────────────────────────────

REAPER_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --skip-deps) SKIP_DEPS=true ;;
        --skip-reaper-config) SKIP_REAPER_CONFIG=true ;;
        --reaper-only) REAPER_ONLY=true ;;
        --midigpt-src=*)
            MIDIGPT_SRC="${arg#*=}"
            ;;
        --help|-h)
            echo "MIDI-GPT for REAPER — Installer"
            echo ""
            echo "Usage: ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-deps          Skip system dependency check"
            echo "  --skip-reaper-config Skip automatic REAPER Python/ReaScript configuration"
            echo "  --reaper-only        Only do REAPER integration (Step 4/5: symlinks, ReaPack,"
            echo "                       ReaImGui, reaper.ini) -- skips venv/backend entirely."
            echo "                       Useful to redo just the REAPER side, or for testing."
            echo "  --midigpt-src=PATH   Path to the MIDI-GPT source repository (sibling folder by default)"
            echo "  --help               Show this help"
            echo ""
            echo "Examples:"
            echo "  ./install.sh                                   # Full installation"
            echo "  ./install.sh --midigpt-src=/custom/path        # Custom MIDI-GPT source path"
            echo "  ./install.sh --reaper-only                     # Just (re)do REAPER integration"
            exit 0
            ;;
        *) warn "Unknown option: $arg" ;;
    esac
done

# ── Banner ──────────────────────────────────────────────────────

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║     MIDI-GPT for REAPER Installer    ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect OS ───────────────────────────────────────────────────

OS="$(uname -s)"
case "$OS" in
    Darwin)       PLATFORM="macos" ;;
    Linux)        PLATFORM="linux" ;;
    MINGW*|MSYS*) PLATFORM="windows" ;;
    *)            fail "Unsupported OS: $OS. On Windows, use install.ps1 instead." ;;
esac
info "Platform: $PLATFORM ($OS)"

if [ "$REAPER_ONLY" = true ]; then
    step "Skipping system deps / venv / backend (--reaper-only)"
    # Still need a python to detect the ReaScript library path in Step 5.
    if [ -z "${PYTHON_CMD:-}" ]; then
        for cmd in python3.12 python3.11 python3.10 python3; do
            if check_cmd "$cmd"; then
                PYTHON_CMD="$cmd"
                break
            fi
        done
    fi
fi

# ====================================================================
# Step 1: System Dependencies
# ====================================================================

if [ "$REAPER_ONLY" = false ]; then

if [ "$SKIP_DEPS" = false ]; then
    step "Step 1/6: Checking system dependencies"

    MISSING=()

    # -- Python --
    if [ -n "${PYTHON_CMD:-}" ] && [ -f "$PYTHON_CMD" ]; then
        PY_VER="$($PYTHON_CMD -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
        ok "Python $PY_VER ($PYTHON_CMD) [override]"
    else
        PYTHON_CMD=""
        for cmd in python3.12 python3.11 python3.10 python3; do
            if check_cmd "$cmd"; then
                PY_VER="$($cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
                PY_MAJOR="$($cmd -c 'import sys; print(sys.version_info.major)')"
                PY_MINOR="$($cmd -c 'import sys; print(sys.version_info.minor)')"
                if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
                    PYTHON_CMD="$cmd"
                    break
                fi
            fi
        done

        if [ -z "$PYTHON_CMD" ]; then
            MISSING+=("python>=3.10")
            warn "Python >= $PYTHON_MIN_VERSION not found"
        else
            ok "Python $PY_VER ($PYTHON_CMD)"
        fi
    fi

    # -- git --
    if check_cmd git; then
        ok "git $(git --version | awk '{print $3}')"
    else
        MISSING+=("git")
        warn "git not found"
    fi

    # -- curl -- required for ReaPack/Arachno downloads (Step 4) and for
    # bootstrapping Homebrew below if that's needed too. Present by default
    # on macOS and most desktop Linux distros, but not guaranteed on
    # minimal/server/HPC-cluster Linux images.
    if check_cmd curl; then
        ok "curl $(curl --version | head -1 | awk '{print $2}')"
    else
        MISSING+=("curl")
        warn "curl not found"
    fi

    # -- Install missing deps --
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo ""
        warn "Missing dependencies: ${MISSING[*]}"
        echo ""

        # Try to auto-install git on macOS via Homebrew
        if [[ " ${MISSING[*]} " == *"git"* ]] && [ "$PLATFORM" = "macos" ]; then
            if check_cmd brew; then
                info "Installing git via Homebrew..."
                brew install git || fail "Homebrew install failed"
            else
                echo "  Install Homebrew first, then re-run:"
                echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                echo ""
                fail "Homebrew not found"
            fi
        elif [[ " ${MISSING[*]} " == *"git"* ]] && [ "$PLATFORM" = "linux" ]; then
            fail "Please install git (e.g. sudo apt install git) then re-run"
        fi

        if [[ " ${MISSING[*]} " == *"curl"* ]]; then
            if [ "$PLATFORM" = "linux" ]; then
                fail "Please install curl (e.g. sudo apt install curl, or ask your cluster admin / try 'module load curl') then re-run"
            else
                fail "Please install curl then re-run"
            fi
        fi

        # Python missing — give platform-specific install guidance
        if [[ " ${MISSING[*]} " == *"python"* ]]; then
            echo "  Python 3.10, 3.11, or 3.12 is required. Install options:"
            echo ""
            if [ "$PLATFORM" = "macos" ]; then
                echo "  Option A — Homebrew (recommended):"
                echo "    brew install python@3.12"
                echo ""
                echo "  Option B — Official installer:"
                echo "    https://www.python.org/downloads/"
                echo "    Download Python 3.12 for macOS and run the .pkg"
            elif [ "$PLATFORM" = "linux" ]; then
                echo "  Ubuntu/Debian:"
                echo "    sudo apt update && sudo apt install python3.12 python3.12-venv"
                echo ""
                echo "  Other distros: https://www.python.org/downloads/"
            else
                echo "  Download Python 3.12 from: https://www.python.org/downloads/"
            fi
            echo ""
            echo "  After installing Python, re-run this installer."
            fail "Python >= $PYTHON_MIN_VERSION is required"
        fi
    fi

    ok "All system dependencies satisfied"

else
    step "Step 1/6: Skipping dependency check (--skip-deps)"
    # Find python anyway
    if [ -n "${PYTHON_CMD:-}" ] && [ -f "$PYTHON_CMD" ]; then
        info "Using custom Python $PYTHON_CMD [override]"
    else
        PYTHON_CMD=""
        for cmd in python3.12 python3.11 python3.10 python3; do
            if check_cmd "$cmd"; then
                PY_MINOR="$($cmd -c 'import sys; print(sys.version_info.minor)')"
                if [ "$PY_MINOR" -ge 10 ]; then
                    PYTHON_CMD="$cmd"
                    break
                fi
            fi
        done
        [ -z "$PYTHON_CMD" ] && fail "Python >= $PYTHON_MIN_VERSION required but not found"
    fi
fi

# ====================================================================
# Step 2: Virtual Environment + Torch
# ====================================================================

step "Step 2/6: Setting up Python virtual environment"

if [ -d "$VENV_DIR" ]; then
    info "Existing venv found at $VENV_DIR"
    source "$VENV_DIR/bin/activate"
    ok "Activated existing venv"
else
    VENV_OPTS=""
    if [ "${MIDIGPT_SYSTEM_SITE_PACKAGES:-}" = "true" ]; then
        VENV_OPTS="--system-site-packages"
        info "Enabling system site packages for venv..."
    fi
    "$PYTHON_CMD" -m venv $VENV_OPTS "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip setuptools wheel -q
    ok "Created and activated venv at $VENV_DIR"
fi

# Verify PyTorch installation (required by the MIDI-GPT model)
info "Checking PyTorch..."
if python -c "import torch" 2>/dev/null; then
    TORCH_VER="$(python -c 'import torch; print(torch.__version__)')"
    ok "PyTorch $TORCH_VER already installed"
else
    info "Installing PyTorch (this may take a few minutes)..."
    if [ "$PLATFORM" = "linux" ]; then
        pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
    else
        pip install torch
    fi
    if python -c "import torch" 2>/dev/null; then
        TORCH_VER="$(python -c 'import torch; print(torch.__version__)')"
        ok "PyTorch $TORCH_VER installed"
    else
        echo ""
        warn "PyTorch could not be installed automatically."
        echo ""
        echo "  This usually means there is no pre-built PyTorch wheel for your"
        echo "  Python version or platform. Please install PyTorch manually:"
        echo ""
        echo "  1. Visit: https://pytorch.org/get-started/locally/"
        echo "  2. Select your OS, package manager (pip), and Python version"
        echo "  3. Run the install command it gives you (with this venv activated)"
        echo "  4. Then re-run this installer"
        echo ""
        fail "PyTorch installation failed. See instructions above."
    fi
fi

# Virtual environment is ready

# ====================================================================
# Step 3: Install MIDI-GPT Backend
# ====================================================================

step "Step 3/6: Installing MIDI-GPT backend"

if [ -n "$MIDIGPT_SRC" ] && [ -d "$MIDIGPT_SRC" ]; then
    info "Installing midigpt[http,inference] from source: $MIDIGPT_SRC ..."
    pip install -e "${MIDIGPT_SRC}[http,inference]" 2>&1 | tail -5
else
    info "Installing midigpt[http,inference] from PyPI ..."
    if ! pip install "midigpt[http,inference]" 2>&1 | tail -5; then
        warn "PyPI install failed — falling back to cloning MIDI-GPT from GitHub ..."
        MIDIGPT_CLONE="$(cd "$REPO_DIR/.." && pwd)/MIDI-GPT"
        if [ ! -d "$MIDIGPT_CLONE/.git" ]; then
            git clone https://github.com/Metacreation-Lab/MIDI-GPT.git "$MIDIGPT_CLONE" \
                || fail "Failed to clone MIDI-GPT. Check your internet connection and try again."
        else
            info "Existing MIDI-GPT clone found at $MIDIGPT_CLONE"
        fi
        pip install -e "${MIDIGPT_CLONE}[http,inference]" 2>&1 | tail -5 \
            || fail "Source install from cloned MIDI-GPT also failed."
    fi
fi

if python -c "from midigpt.inference.engine import InferenceEngine" 2>/dev/null; then
    ok "midigpt backend installed successfully"
else
    fail "midigpt backend installation failed."
fi

info "Installing plugin dependencies..."
pip install -e "$REPO_DIR" -q 2>/dev/null || pip install -e "$REPO_DIR"
ok "Plugin dependencies installed"

fi # REAPER_ONLY == false (Steps 1-3)

# ====================================================================
# Step 4: REAPER Integration (Symlinks, ReaPack, ReaImGui)
# ====================================================================

step "Step 4/6: Setting up REAPER integration"

if [ -n "${MIDIGPT_REAPER_DIR:-}" ]; then
    # Test-only override (see tests/integration/) -- lets the REAPER
    # integration logic run against a disposable fake directory instead of
    # the real REAPER install, so different starting states (empty,
    # ReaPack already present, existing reaper.ini content, etc.) can be
    # exercised repeatably without ever touching a real machine's REAPER.
    REAPER_DIR="$MIDIGPT_REAPER_DIR"
elif [ "$PLATFORM" = "macos" ]; then
    REAPER_DIR="$HOME/Library/Application Support/REAPER"
elif [ "$PLATFORM" = "windows" ]; then
    REAPER_DIR="$APPDATA/REAPER"
else
    REAPER_DIR="$HOME/.config/REAPER"
fi

REAPER_WAS_CLOSED_BY_US=false

if [ -d "$REAPER_DIR" ]; then
    # Installing ReaPack and configuring reaper.ini (Step 5) both need REAPER
    # closed. Ask once, up front, so both steps can run this pass instead of
    # telling the user to re-run the installer later.
    if reaper_is_running; then
        if [ -t 0 ]; then
            warn "REAPER is currently running."
            echo "  Installing ReaPack and configuring REAPER (reaper.ini) both require REAPER"
            echo "  to be closed. Nothing is discarded silently -- REAPER will prompt you to"
            echo "  save any unsaved project first, same as quitting normally."
            read -rp "  Close REAPER now and continue? [y/N]: " _CLOSE_REAPER
            if [[ "$_CLOSE_REAPER" =~ ^[Yy]$ ]]; then
                quit_reaper_and_wait
                if ! reaper_is_running; then
                    REAPER_WAS_CLOSED_BY_US=true
                fi
            else
                warn "Continuing with REAPER open -- ReaPack install and reaper.ini setup will be skipped this run."
            fi
        else
            warn "REAPER is currently running -- ReaPack install and reaper.ini setup will be skipped (non-interactive)."
        fi
    fi

    for pair in \
        "$REPO_DIR/src/Scripts/MIDI-GPT:$REAPER_DIR/Scripts/MIDI-GPT"
    do
        src="${pair%%:*}"
        dst="${pair##*:}"
        [ -d "$src" ] || continue
        mkdir -p "$(dirname "$dst")"
        [ -e "$dst" ] || [ -L "$dst" ] && rm -rf "$dst"
        ln -sf "$src" "$dst"
    done
    ok "REAPER symlinks created"

    # -- ReaPack + ReaImGui --
    REAPACK_READY=false
    if find "$REAPER_DIR/UserPlugins" -iname "reaper_reapack*" 2>/dev/null | grep -q .; then
        ok "ReaPack already installed"
        REAPACK_READY=true
    elif reaper_is_running; then
        warn "ReaPack not installed, and REAPER is still open -- skipping (re-run after closing REAPER, or install manually: https://reapack.com/)"
    else
        info "Installing ReaPack..."
        ARCH="$(uname -m)"
        REAPACK_ASSET=""
        case "$PLATFORM:$ARCH" in
            macos:arm64|macos:aarch64) REAPACK_ASSET="reaper_reapack-arm64.dylib" ;;
            macos:x86_64)              REAPACK_ASSET="reaper_reapack-x86_64.dylib" ;;
            linux:aarch64|linux:arm64) REAPACK_ASSET="reaper_reapack-aarch64.so" ;;
            linux:x86_64)              REAPACK_ASSET="reaper_reapack-x86_64.so" ;;
            linux:armv7l)              REAPACK_ASSET="reaper_reapack-armv7l.so" ;;
            linux:i686)                REAPACK_ASSET="reaper_reapack-i686.so" ;;
            windows:*)                 REAPACK_ASSET="reaper_reapack-x64.dll" ;;
        esac

        if [ -n "$REAPACK_ASSET" ]; then
            mkdir -p "$REAPER_DIR/UserPlugins"
            REAPACK_URL="https://github.com/cfillion/reapack/releases/latest/download/$REAPACK_ASSET"
            REAPACK_DEST="$REAPER_DIR/UserPlugins/$REAPACK_ASSET"

            # ReaPack's own releases aren't code-signed, so there's no
            # signature to verify -- fetch GitHub's published SHA256 for
            # this exact asset instead, so we can at least catch a
            # corrupted or tampered-with download before trusting it.
            # Fetched with curl (system trust store, same as the download
            # itself) rather than python's urllib -- a python installed
            # without its CA bootstrap (common with the official
            # python.org macOS installer, before running its "Install
            # Certificates.command") would otherwise fail here silently.
            # python is only used to parse the already-fetched JSON text.
            REAPACK_EXPECTED_SHA=""
            REAPACK_RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/cfillion/reapack/releases/latest" 2>/dev/null)"
            if [ -n "$REAPACK_RELEASE_JSON" ] && check_cmd python3; then
                REAPACK_EXPECTED_SHA="$(printf '%s' "$REAPACK_RELEASE_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for a in data.get('assets', []):
        if a['name'] == '$REAPACK_ASSET':
            print(a.get('digest', '').replace('sha256:', ''))
            break
except Exception:
    pass
" 2>/dev/null)"
            fi

            if curl -fsSL "$REAPACK_URL" -o "$REAPACK_DEST"; then
                REAPACK_VERIFIED=true
                if [ -n "$REAPACK_EXPECTED_SHA" ]; then
                    REAPACK_ACTUAL_SHA="$( (shasum -a 256 "$REAPACK_DEST" 2>/dev/null || sha256sum "$REAPACK_DEST" 2>/dev/null) | awk '{print $1}')"
                    if [ "$REAPACK_ACTUAL_SHA" != "$REAPACK_EXPECTED_SHA" ]; then
                        REAPACK_VERIFIED=false
                    fi
                else
                    warn "Could not fetch an expected checksum for ReaPack -- installing unverified"
                fi

                if [ "$REAPACK_VERIFIED" = true ]; then
                    if [ "$PLATFORM" = "macos" ]; then
                        # curl-downloaded files can still end up quarantined
                        # on recent macOS, which silently blocks REAPER
                        # from loading the extension until the user
                        # manually approves it in System Settings > Privacy
                        # & Security. Strip it ourselves, now that the
                        # checksum above confirms it's what GitHub actually
                        # published -- this is our own file, in our own
                        # user directory, so no elevated privileges needed.
                        xattr -d com.apple.quarantine "$REAPACK_DEST" 2>/dev/null || true
                    fi
                    ok "ReaPack installed and checksum-verified ($REAPACK_ASSET)"
                    REAPACK_READY=true
                else
                    rm -f "$REAPACK_DEST"
                    warn "Downloaded ReaPack didn't match GitHub's published checksum -- discarded. Install manually: https://reapack.com/"
                fi
            else
                warn "Failed to download ReaPack -- install manually: https://reapack.com/"
            fi
        else
            warn "Unrecognized platform/architecture ($PLATFORM/$ARCH) -- install ReaPack manually: https://reapack.com/"
        fi
    fi

    if ! find "$REAPER_DIR/UserPlugins" -iname "*imgui*" 2>/dev/null | grep -q .; then
        if [ "$REAPACK_READY" = true ]; then
            info "Queuing ReaImGui install for the next REAPER launch..."
            STARTUP_LUA="$REAPER_DIR/Scripts/__startup.lua"
            BEGIN_MARK="-- BEGIN MIDI-GPT ReaImGui bootstrap (safe to delete this block)"
            END_MARK="-- END MIDI-GPT ReaImGui bootstrap"
            mkdir -p "$(dirname "$STARTUP_LUA")"
            touch "$STARTUP_LUA"

            BLOCK_TMP="$(mktemp)"
            cat > "$BLOCK_TMP" << 'LUA_EOF'
if not reaper.APIExists("ImGui_CreateContext") then
  reaper.ReaPack_AddSetRepository("ReaTeam Extensions", "https://github.com/ReaTeam/Extensions/raw/master/index.xml", true, 1)
  reaper.ReaPack_ProcessQueue(true)
end
LUA_EOF

            if grep -qF -- "$BEGIN_MARK" "$STARTUP_LUA"; then
                awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blockfile="$BLOCK_TMP" '
                    BEGIN { block = ""; while ((getline line < blockfile) > 0) block = block line "\n" }
                    $0 == b { print; printf "%s", block; skip=1; next }
                    $0 == e { print; skip=0; next }
                    skip { next }
                    { print }
                ' "$STARTUP_LUA" > "${STARTUP_LUA}.tmp" && mv "${STARTUP_LUA}.tmp" "$STARTUP_LUA"
            else
                {
                    echo ""
                    echo "$BEGIN_MARK"
                    cat "$BLOCK_TMP"
                    echo "$END_MARK"
                } >> "$STARTUP_LUA"
            fi
            rm -f "$BLOCK_TMP"
            ok "ReaImGui will install automatically the next time REAPER starts"
            warn "This also installs the other packages in the 'ReaTeam Extensions' repo (ReaBlink, ReaMCULive, js_ReaScriptAPI) -- all official ReaTeam-curated extensions, not just ReaImGui, since ReaPack can only auto-install per-repository, not per-package."
        else
            warn "ReaImGui extension not found — the dashboard UI needs it"
            echo "  In REAPER: Extensions > ReaPack > Browse packages > search 'ReaImGui' > install > restart REAPER"
        fi
    fi
else
    warn "REAPER config directory not found — REAPER may not be installed yet"
fi

# ====================================================================
# Step 5: Configure REAPER for Python / ReaScript
# ====================================================================

if [ "$SKIP_REAPER_CONFIG" = true ]; then
    step "Step 5/6: Skipping REAPER config (--skip-reaper-config)"
else
step "Step 5/6: Configuring REAPER (reaper.ini)"

REAPER_INI="$REAPER_DIR/reaper.ini"

# Detect the Python dynamic library (dylib/so/dll) for REAPER
PYTHON_DLL_PATH="$("${PYTHON_CMD:-python3}" -c '
import sysconfig, pathlib, sys, os
ver = f"{sys.version_info.major}.{sys.version_info.minor}"
if sys.platform == "win32":
    base = pathlib.Path(sys.exec_prefix)
    for p in sorted(base.glob(f"python{sys.version_info.major}{sys.version_info.minor}.dll")):
        print(p); break
else:
    libdir = pathlib.Path(sysconfig.get_config_var("LIBDIR"))
    for ext in [".dylib", ".so"]:
        for p in sorted(libdir.glob(f"libpython{ver}*{ext}")):
            print(p); break
        else: continue
        break
')"

if [ -f "$REAPER_INI" ]; then
    if reaper_is_running; then
        warn "REAPER is currently running!"
        echo "  REAPER overwrites reaper.ini on quit, so changes would be lost."
        echo "  Please quit REAPER and re-run this installer, or configure manually:"
        echo "    Options > Preferences > Plug-Ins > ReaScript"
        if [ -n "$PYTHON_DLL_PATH" ]; then
            echo "    Python library: $PYTHON_DLL_PATH"
        fi
    else
        if [ -n "$PYTHON_DLL_PATH" ] && [ -f "$PYTHON_DLL_PATH" ]; then
            PY_LIB_DIR="$(dirname "$PYTHON_DLL_PATH")"
            PY_LIB_FILE="$(basename "$PYTHON_DLL_PATH")"

            set_reaper_ini() {
                local key="$1" value="$2" file="$3"
                if grep -q "^${key}=" "$file" 2>/dev/null; then
                    awk -v k="$key" -v v="$value" '
                        $0 ~ "^" k "=" { print k "=" v; next }
                        { print }
                    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
                else
                    # REAPER writes the section header as [reaper] (lowercase)
                    # on some versions/platforms and [REAPER] on others -- match
                    # either. If no such section exists yet (fresh reaper.ini),
                    # append one at the end of the file.
                    awk -v k="$key" -v v="$value" '
                        BEGIN { done = 0 }
                        {
                            print
                            if (!done && tolower($0) == "[reaper]") {
                                print k "=" v
                                done = 1
                            }
                        }
                        END {
                            if (!done) {
                                print ""
                                print "[REAPER]"
                                print k "=" v
                            }
                        }
                    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
                fi
            }

            cp "$REAPER_INI" "${REAPER_INI}.midigpt-backup"
            info "Backed up reaper.ini → reaper.ini.midigpt-backup"

            set_reaper_ini "reascript" "1" "$REAPER_INI"
            if [ "$PLATFORM" = "windows" ]; then
                set_reaper_ini "pythonlibdll64" "$PYTHON_DLL_PATH" "$REAPER_INI"
            else
                set_reaper_ini "pythonlibpath64" "$PY_LIB_DIR" "$REAPER_INI"
                set_reaper_ini "pythonlibdll64" "$PY_LIB_FILE" "$REAPER_INI"
            fi

            if grep -q "^reascript=1" "$REAPER_INI" && grep -q "^pythonlibdll64=" "$REAPER_INI"; then
                ok "ReaScript enabled (reascript=1)"
                ok "Python library: $PY_LIB_DIR/$PY_LIB_FILE"
            else
                warn "Failed to write ReaScript/Python settings to reaper.ini"
                echo "  Configure manually: Options > Preferences > Plug-Ins > ReaScript"
                echo "    Python library: $PY_LIB_DIR/$PY_LIB_FILE"
            fi
        else
            warn "Could not detect Python dynamic library path"
            echo "  You'll need to configure this manually in REAPER:"
            echo "    Options > Preferences > Plug-Ins > ReaScript"
        fi
    fi
else
    if [ -d "$REAPER_DIR" ]; then
        warn "reaper.ini not found — REAPER may not have been launched yet"
        echo "  Launch REAPER once, quit it, then re-run this installer to auto-configure."
    else
        warn "REAPER config directory not found — REAPER may not be installed"
    fi
    if [ -n "$PYTHON_DLL_PATH" ]; then
        echo "  When ready, set the Python library path to:"
        echo -e "    ${GREEN}$PYTHON_DLL_PATH${NC}"
    fi
fi
fi

if [ "$REAPER_WAS_CLOSED_BY_US" = true ]; then
    info "Reopening REAPER so ReaPack can load and finish setup automatically..."
    if relaunch_reaper; then
        ok "REAPER relaunched -- ReaImGui installs in the background over the next minute or two."
    fi
fi

if [ "$REAPER_ONLY" = false ]; then
# ====================================================================
# Step 6: Verify Backend Installation
# ====================================================================

step "Step 6/6: Verifying backend installation"

if python -c "from midigpt.inference.engine import InferenceEngine" 2>/dev/null; then
    ok "Verification successful: midigpt is installed and functional"
else
    fail "Verification failed: midigpt could not be imported"
fi

# ====================================================================
# Create Desktop shortcut to server launcher
# ====================================================================

DESKTOP_DIR="$HOME/Desktop"
if [ -d "$DESKTOP_DIR" ]; then
    if [ "$PLATFORM" = "macos" ]; then
        LAUNCHER="$REPO_DIR/Start Server - Mac.command"
        SHORTCUT="$DESKTOP_DIR/Start MIDI-GPT Server.command"
        if [ -f "$LAUNCHER" ]; then
            cat > "$SHORTCUT" << 'LAUNCHER_EOF'
#!/usr/bin/env bash
LAUNCHER_EOF
            echo "cd \"$(printf '%s' "$REPO_DIR")\" && bash \"./start_midigpt_server.sh\"" >> "$SHORTCUT"
            chmod +x "$SHORTCUT"
            ok "Desktop shortcut created: Start MIDI-GPT Server.command"
        fi
    elif [ "$PLATFORM" = "linux" ]; then
        SHORTCUT="$DESKTOP_DIR/Start MIDI-GPT Server.desktop"
        cat > "$SHORTCUT" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Start MIDI-GPT Server
Exec=bash -c 'cd "$REPO_DIR" && bash ./start_midigpt_server.sh'
Terminal=true
Icon=utilities-terminal
Comment=Start the MIDI-GPT inference server for REAPER
DESKTOP_EOF
        chmod +x "$SHORTCUT"
        ok "Desktop shortcut created: Start MIDI-GPT Server.desktop"
    fi
else
    info "No Desktop folder found — skipping shortcut creation"
fi
fi # REAPER_ONLY == false (Step 6 + Desktop shortcut)

# ====================================================================
# Final: Summary and Next Steps
# ====================================================================

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Installation Complete!${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BOLD}Next steps in REAPER:${NC}"
echo ""
echo "  1. Load the ReaScript actions:"
echo "     Actions > Show Action List > Load ReaScript"
echo "     Select: $REAPER_DIR/Scripts/MIDI-GPT/REAPER_midigpt_dashboard.py   (primary UI)"
echo "     Select: $REAPER_DIR/Scripts/MIDI-GPT/REAPER_midigpt_infill.py"
echo "     Select: $REAPER_DIR/Scripts/MIDI-GPT/REAPER_midigpt_set_server.py"
echo "     Select: $REAPER_DIR/Scripts/MIDI-GPT/REAPER_midigpt_setup_tracks.py"
echo "     Select: $REAPER_DIR/Scripts/MIDI-GPT/REAPER_midigpt_apply_soundfont_template.py"
echo ""
echo "  2. Run 'MIDI-GPT: Dashboard' — it's a single window for the whole"
echo "     workflow (global options, per-track controls, running generation)."
echo "     Needs the ReaImGui extension -- see the warning above if it's missing."
echo ""
echo "  If the MIDI-GPT server runs on a different machine, run the"
echo "  'MIDI-GPT: Set server address' action and enter its IP/domain and port"
echo "  (e.g. http://192.168.1.20:3456). Defaults to http://127.0.0.1:3456."
echo ""
echo -e "${BOLD}To start the server:${NC}"
if [ -d "$HOME/Desktop" ]; then
    echo -e "  Double-click ${GREEN}Start MIDI-GPT Server${NC} on your Desktop"
elif [ "$PLATFORM" = "macos" ]; then
    echo -e "  Double-click: ${GREEN}Start Server - Mac.command${NC}"
elif [ "$PLATFORM" = "windows" ]; then
    echo -e "  Double-click: ${GREEN}Start Server - Windows.bat${NC}"
else
    echo -e "  Run: ${GREEN}./start_midigpt_server.sh${NC}"
fi
echo "  Or from terminal: cd $REPO_DIR && source .venv/bin/activate && midigpt-http"
echo ""

# ====================================================================
# Interactive: Instrument setup (Sforzando + Arachno)
# ====================================================================

if [ -t 0 ]; then
    echo ""
    echo -e "${BOLD}----------------------------------------------------${NC}"
    echo -e "${BOLD}  Optional: Instrument Setup (Sforzando + Arachno)${NC}"
    echo -e "${BOLD}----------------------------------------------------${NC}"
    echo ""
    echo "  MIDI-GPT tracks play through Sforzando (a free SFZ sampler) loaded"
    echo "  with the Arachno General MIDI SoundFont -- see VST.md for the full"
    echo "  setup."
    echo ""
    echo "  Sforzando is a real application installer (not just a data file),"
    echo "  behind its own download page, so this installer opens that page for"
    echo "  you rather than running an installer on your behalf."
    read -rp "  Open the Sforzando download page in your browser now? [y/N]: " _OPEN_SFZ
    if [[ "$_OPEN_SFZ" =~ ^[Yy]$ ]]; then
        open_url "https://www.plogue.com/products/sforzando.html"
        ok "Opened the Sforzando download page"
    fi
    echo ""
    echo "  Arachno is just a SoundFont data file, so this installer can fetch"
    echo "  it directly, into this repo's own soundfonts/ folder."
    read -rp "  Download the Arachno GM SoundFont (~140MB) now? [y/N]: " _DL_ARACHNO
    if [[ "$_DL_ARACHNO" =~ ^[Yy]$ ]]; then
        download_arachno_soundfont || true
    fi
fi

# ====================================================================
# Interactive: Launch server now?
# ====================================================================

if [ -t 0 ] && [ "$REAPER_ONLY" = false ]; then
    echo ""
    echo -e "${BOLD}----------------------------------------------------${NC}"
    echo -e "${BOLD}  Launch Server${NC}"
    echo -e "${BOLD}----------------------------------------------------${NC}"
    echo ""
    echo "  Would you like to start the MIDI-GPT server now?"
    echo ""
    read -rp "  Launch server? [Y/n]: " _LAUNCH
    _LAUNCH="${_LAUNCH:-y}"

    if [[ "$_LAUNCH" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${BOLD}  Select a model:${NC}"
        echo ""
        echo "    [1] Yellow     - General purpose, recommended (yellow_medium)"
        echo "    [2] Prism      - Extended controls (prism_medium)"
        echo "    [3] Expressive - Microtiming + velocity (expressive_medium)"
        echo ""
        read -rp "  Model [1/2/3, default=1]: " _MODEL_CHOICE

        case "${_MODEL_CHOICE:-1}" in
            2) _MODEL="prism_medium"      ; _LABEL="Prism"      ;;
            3) _MODEL="expressive_medium" ; _LABEL="Expressive" ;;
            *) _MODEL="yellow_medium"     ; _LABEL="Yellow"     ;;
        esac

        echo ""
        echo -e "${BOLD}  Starting MIDI-GPT server (${_LABEL})...${NC}"
        echo "  Keep this terminal open while using MIDI-GPT in REAPER."
        echo "  Press Ctrl+C to stop the server."
        echo ""
        bash "$REPO_DIR/start_midigpt_server.sh" --pretrained "$_MODEL"
    else
        echo ""
        echo -e "${BOLD}Next steps:${NC}"
        echo "  Start the server later with:"
        echo -e "    ${GREEN}cd $REPO_DIR && ./start_midigpt_server.sh${NC}"
        echo ""
    fi
elif [ -n "${MIDIGPT_INTERACTIVE:-}" ]; then
    echo ""
    read -rp "Press Enter to close this window..."
fi
