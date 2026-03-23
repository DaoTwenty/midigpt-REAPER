#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER — One-Click Installer
#
# Installs everything needed to run MIDI-GPT in REAPER:
#   1. System dependencies (cmake, protobuf, python)
#   2. Python virtual environment + torch
#   3. mmm_refactored C++ backend (built from source via pip)
#   4. REAPER symlinks (Scripts + Effects)
#   5. Model checkpoint validation
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

# MMM Refactored source archive.
# This is a private repo distributed as a zip. Update this URL if the
# hosting location changes.
MMM_ZIP_URL="PLACEHOLDER_URL"
MMM_ZIP_LOCAL=""   # Set via --mmm-zip=/path/to/file.zip
MMM_BUILD_DIR="/tmp/mmm-refactored-build"
SKIP_DEPS=false
SKIP_REAPER_CONFIG=false

# Auto-detect bundled mmm_refactored.zip next to this script (for release packages)
if [ -z "$MMM_ZIP_LOCAL" ] && [ -f "$REPO_DIR/mmm_refactored.zip" ]; then
    MMM_ZIP_LOCAL="$REPO_DIR/mmm_refactored.zip"
fi

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

# ── Args ────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --skip-deps) SKIP_DEPS=true ;;
        --skip-reaper-config) SKIP_REAPER_CONFIG=true ;;
        --mmm-zip=*)
            MMM_ZIP_LOCAL="${arg#*=}"
            ;;
        --help|-h)
            echo "MIDI-GPT for REAPER — Installer"
            echo ""
            echo "Usage: ./install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-deps          Skip system dependency check"
            echo "  --skip-reaper-config Skip automatic REAPER Python/ReaScript configuration"
            echo "  --mmm-zip=PATH       Use a local mmm_refactored zip instead of downloading"
            echo "  --help               Show this help"
            echo ""
            echo "Examples:"
            echo "  ./install.sh                                   # Download and build everything"
            echo "  ./install.sh --mmm-zip=~/Downloads/mmm.zip     # Use a local zip file"
            echo "  ./install.sh --skip-deps --mmm-zip=./mmm.zip   # Skip deps, use local zip"
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

# ====================================================================
# Step 1: System Dependencies
# ====================================================================

if [ "$SKIP_DEPS" = false ]; then
    step "Step 1/6: Checking system dependencies"

    MISSING=()

    # -- Python --
    PYTHON_CMD=""
    for cmd in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
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

    # -- cmake --
    if check_cmd cmake; then
        ok "cmake $(cmake --version | head -1 | awk '{print $3}')"
    else
        MISSING+=("cmake")
        warn "cmake not found"
    fi

    # -- protoc (protobuf compiler) --
    if check_cmd protoc; then
        ok "protoc $(protoc --version | awk '{print $2}')"
    else
        MISSING+=("protobuf")
        warn "protoc not found"
    fi

    # -- git --
    if check_cmd git; then
        ok "git $(git --version | awk '{print $3}')"
    else
        MISSING+=("git")
        warn "git not found"
    fi

    # -- Install missing deps --
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo ""
        warn "Missing dependencies: ${MISSING[*]}"
        echo ""

        if [ "$PLATFORM" = "macos" ]; then
            if check_cmd brew; then
                info "Installing via Homebrew..."
                BREW_PKGS=()
                for dep in "${MISSING[@]}"; do
                    case "$dep" in
                        "python>=3.10") BREW_PKGS+=("python@3.14") ;;
                        "cmake")        BREW_PKGS+=("cmake") ;;
                        "protobuf")     BREW_PKGS+=("protobuf@21") ;;
                        "git")          BREW_PKGS+=("git") ;;
                    esac
                done
                brew install "${BREW_PKGS[@]}" || fail "Homebrew install failed"

                # protobuf@21 needs to be linked/added to PATH
                if [[ " ${MISSING[*]} " =~ " protobuf " ]]; then
                    if [ -d "/usr/local/opt/protobuf@21" ]; then
                        export PATH="/usr/local/opt/protobuf@21/bin:$PATH"
                        export PKG_CONFIG_PATH="/usr/local/opt/protobuf@21/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
                        info "protobuf@21 added to PATH for this session"
                    elif [ -d "/opt/homebrew/opt/protobuf@21" ]; then
                        export PATH="/opt/homebrew/opt/protobuf@21/bin:$PATH"
                        export PKG_CONFIG_PATH="/opt/homebrew/opt/protobuf@21/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
                        info "protobuf@21 added to PATH for this session"
                    fi
                fi

                # Re-detect python after install
                if [ -z "$PYTHON_CMD" ]; then
                    for cmd in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
                        if check_cmd "$cmd"; then
                            PY_VER="$($cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
                            PY_MINOR="$($cmd -c 'import sys; print(sys.version_info.minor)')"
                            if [ "$PY_MINOR" -ge 10 ]; then
                                PYTHON_CMD="$cmd"
                                break
                            fi
                        fi
                    done
                fi
            else
                echo ""
                echo "Please install Homebrew first:"
                echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                echo ""
                echo "Then re-run this installer."
                fail "Homebrew not found"
            fi
        elif [ "$PLATFORM" = "linux" ]; then
            echo ""
            echo "Please install the missing dependencies manually:"
            echo ""
            echo "  Ubuntu/Debian:"
            echo "    sudo apt update && sudo apt install -y cmake protobuf-compiler libprotobuf-dev python3.10 python3.10-venv git"
            echo ""
            echo "  Fedora:"
            echo "    sudo dnf install -y cmake protobuf-compiler protobuf-devel python3.10 git"
            echo ""
            echo "  Arch:"
            echo "    sudo pacman -S cmake protobuf python git"
            echo ""
            fail "Please install missing dependencies and re-run"
        fi
    fi

    [ -z "$PYTHON_CMD" ] && fail "Python >= $PYTHON_MIN_VERSION required but not found"
    ok "All system dependencies satisfied"

else
    step "Step 1/6: Skipping dependency check (--skip-deps)"
    # Find python anyway
    PYTHON_CMD=""
    for cmd in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
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

# ====================================================================
# Step 2: Virtual Environment + Torch
# ====================================================================

step "Step 2/6: Setting up Python virtual environment"

if [ -d "$VENV_DIR" ]; then
    info "Existing venv found at $VENV_DIR"
    source "$VENV_DIR/bin/activate"
    ok "Activated existing venv"
else
    info "Creating venv with $PYTHON_CMD..."
    "$PYTHON_CMD" -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip setuptools wheel -q
    ok "Created and activated venv at $VENV_DIR"
fi

# Install torch first (needed as build dep for mmm_refactored)
info "Checking PyTorch..."
if python -c "import torch" 2>/dev/null; then
    TORCH_VER="$(python -c 'import torch; print(torch.__version__)')"
    ok "PyTorch $TORCH_VER already installed"
else
    info "Installing PyTorch (this may take a few minutes)..."
    if [ "$PLATFORM" = "linux" ]; then
        pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cpu -q 2>/dev/null
    else
        pip3 install torch torchvision -q 2>/dev/null
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

# Install other build deps
info "Installing build dependencies..."
pip install scikit-build-core pybind11 -q
ok "Build dependencies ready"

# ====================================================================
# Step 3: Build mmm_refactored C++ Backend
# ====================================================================

step "Step 3/6: Building mmm_refactored C++ backend"

if python -c "import mmm_refactored" 2>/dev/null; then
    ok "mmm_refactored already installed"
else
    # -- Resolve zip source: local file or download --
    MMM_ZIP="/tmp/mmm_refactored.zip"

    if [ -n "$MMM_ZIP_LOCAL" ]; then
        # Local file provided via --mmm-zip=PATH
        if [ ! -f "$MMM_ZIP_LOCAL" ]; then
            fail "Local zip not found: $MMM_ZIP_LOCAL"
        fi
        info "Using local archive: $MMM_ZIP_LOCAL"
        cp "$MMM_ZIP_LOCAL" "$MMM_ZIP"
        ok "Copied $(du -sh "$MMM_ZIP" | awk '{print $1}')"
    else
        # Download from URL
        if [ "$MMM_ZIP_URL" = "PLACEHOLDER_URL" ]; then
            echo ""
            echo "  The MMM Refactored C++ backend is not yet configured for download."
            echo ""
            echo "  Either:"
            echo "    1. Set the download URL in install.sh (MMM_ZIP_URL variable)"
            echo "    2. Pass a local zip file:  ./install.sh --mmm-zip=/path/to/mmm_refactored.zip"
            echo ""
            fail "No MMM Refactored source available."
        fi

        info "Downloading MMM Refactored archive..."
        if check_cmd curl; then
            curl -L -o "$MMM_ZIP" "$MMM_ZIP_URL" || fail "Download failed. Check the URL in install.sh."
        elif check_cmd wget; then
            wget -O "$MMM_ZIP" "$MMM_ZIP_URL" || fail "Download failed. Check the URL in install.sh."
        else
            fail "Neither curl nor wget found. Install one and re-run."
        fi

        if [ ! -f "$MMM_ZIP" ] || [ ! -s "$MMM_ZIP" ]; then
            fail "Downloaded file is empty or missing. The hosting link may have expired."
        fi
        ok "Downloaded $(du -sh "$MMM_ZIP" | awk '{print $1}')"
    fi

    # -- Unzip --
    info "Extracting archive..."
    rm -rf "$MMM_BUILD_DIR"
    mkdir -p "$MMM_BUILD_DIR"
    unzip -q "$MMM_ZIP" -d "$MMM_BUILD_DIR"

    # Handle the common case where the zip contains a single top-level folder
    # (e.g. mmm_refactored-main/). If so, use that folder as the build dir.
    CONTENTS=("$MMM_BUILD_DIR"/*)
    if [ ${#CONTENTS[@]} -eq 1 ] && [ -d "${CONTENTS[0]}" ]; then
        MMM_SRC_DIR="${CONTENTS[0]}"
        info "Source directory: $(basename "$MMM_SRC_DIR")"
    else
        MMM_SRC_DIR="$MMM_BUILD_DIR"
    fi

    # Verify it looks like the right repo
    if [ ! -f "$MMM_SRC_DIR/CMakeLists.txt" ] || [ ! -d "$MMM_SRC_DIR/libraries/protobuf" ]; then
        fail "Extracted archive doesn't look like mmm_refactored (missing CMakeLists.txt or libraries/protobuf/)."
    fi
    ok "Archive extracted"

    # -- Build --
    CMAKE_EXTRA_ARGS=""
    if [ "$PLATFORM" = "macos" ]; then
        # Try Homebrew protobuf@21 locations
        for prefix in /usr/local/opt/protobuf@21 /opt/homebrew/opt/protobuf@21; do
            if [ -d "$prefix" ]; then
                CMAKE_EXTRA_ARGS="-DCMAKE_PREFIX_PATH=$prefix"
                info "Using protobuf at $prefix"
                break
            fi
        done
    fi

    # Get pybind11 cmake dir from the venv so CMake can find it
    PYBIND11_CMAKE_DIR="$(python -c 'import pybind11; print(pybind11.get_cmake_dir())' 2>/dev/null || true)"
    if [ -n "$PYBIND11_CMAKE_DIR" ]; then
        if [ -n "$CMAKE_EXTRA_ARGS" ]; then
            # Append pybind11 path to existing CMAKE_PREFIX_PATH
            CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS%;*}"  # clean up if needed
            CMAKE_EXTRA_ARGS="-DCMAKE_PREFIX_PATH=$(echo "${CMAKE_EXTRA_ARGS#*=};$PYBIND11_CMAKE_DIR")"
        else
            CMAKE_EXTRA_ARGS="-Dpybind11_DIR=$PYBIND11_CMAKE_DIR"
        fi
        info "pybind11 cmake dir: $PYBIND11_CMAKE_DIR"
    fi

    info "Building C++ extension (this takes 2-5 minutes)..."
    CMAKE_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 $CMAKE_EXTRA_ARGS" \
        pip install "$MMM_SRC_DIR" --no-build-isolation 2>&1 | tail -5

    # Verify
    if python -c "import mmm_refactored; print('mmm_refactored imported successfully')" 2>/dev/null; then
        ok "mmm_refactored built and installed"
    else
        fail "mmm_refactored build failed. Check the output above for errors."
    fi

    # Cleanup
    rm -rf "$MMM_BUILD_DIR" "$MMM_ZIP"
    info "Cleaned up build files"
fi

# Install remaining Python deps (symusic, etc.)
info "Installing Python dependencies..."
pip install -e "$REPO_DIR" -q 2>/dev/null || pip install -e "$REPO_DIR"
pip install symusic -q
ok "Python dependencies installed"

# ====================================================================
# Step 4: REAPER Integration (Symlinks)
# ====================================================================

step "Step 4/6: Setting up REAPER integration"

python "$REPO_DIR/scripts/setup.py"

# Verify symlinks
if [ "$PLATFORM" = "macos" ]; then
    REAPER_DIR="$HOME/Library/Application Support/REAPER"
elif [ "$PLATFORM" = "windows" ]; then
    REAPER_DIR="$APPDATA/REAPER"
else
    REAPER_DIR="$HOME/.config/REAPER"
fi

if [ -L "$REAPER_DIR/Scripts/MMM" ] && [ -L "$REAPER_DIR/Effects/MMM" ]; then
    ok "REAPER symlinks created"
else
    warn "REAPER symlinks could not be verified (REAPER may not be installed yet)"
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
PYTHON_DLL_PATH="$(python -c '
import sysconfig, pathlib, sys, os
ver = f"{sys.version_info.major}.{sys.version_info.minor}"
if sys.platform == "win32":
    # Windows: python3X.dll is next to python.exe
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
    # Check if REAPER is currently running — it overwrites reaper.ini on quit
    if pgrep -x "REAPER" >/dev/null 2>&1 || pgrep -x "reaper" >/dev/null 2>&1; then
        warn "REAPER is currently running!"
        echo "  REAPER overwrites reaper.ini on quit, so changes would be lost."
        echo "  Please quit REAPER and re-run this installer, or configure manually:"
        echo "    Options > Preferences > Plug-Ins > ReaScript"
        if [ -n "$PYTHON_DLL_PATH" ]; then
            echo "    Python library: $PYTHON_DLL_PATH"
        fi
    else
        # Split the dylib path into directory and filename for reaper.ini
        if [ -n "$PYTHON_DLL_PATH" ] && [ -f "$PYTHON_DLL_PATH" ]; then
            PY_LIB_DIR="$(dirname "$PYTHON_DLL_PATH")"
            PY_LIB_FILE="$(basename "$PYTHON_DLL_PATH")"

            # Helper: set a key=value in reaper.ini under [REAPER] section.
            # If the key exists, replace it. If not, insert after the [REAPER] header.
            set_reaper_ini() {
                local key="$1" value="$2" file="$3"
                if grep -q "^${key}=" "$file" 2>/dev/null; then
                    # Replace existing line
                    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
                else
                    # Insert after [REAPER] header (newline trick works on both macOS and GNU sed)
                    sed -i.bak "/^\[REAPER\]/a\\
${key}=${value}
" "$file"
                fi
            }

            # Back up reaper.ini before modifying
            cp "$REAPER_INI" "${REAPER_INI}.midigpt-backup"
            info "Backed up reaper.ini → reaper.ini.midigpt-backup"

            set_reaper_ini "reascript" "1" "$REAPER_INI"
            if [ "$PLATFORM" = "windows" ]; then
                # Windows REAPER uses a single full path
                set_reaper_ini "pythonlibdll64" "$PYTHON_DLL_PATH" "$REAPER_INI"
            else
                set_reaper_ini "pythonlibpath64" "$PY_LIB_DIR" "$REAPER_INI"
                set_reaper_ini "pythonlibdll64" "$PY_LIB_FILE" "$REAPER_INI"
            fi

            # Clean up sed backup files (our manual backup is .midigpt-backup)
            rm -f "${REAPER_INI}.bak"

            ok "ReaScript enabled (reascript=1)"
            ok "Python library: $PY_LIB_DIR/$PY_LIB_FILE"
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
fi  # end skip-reaper-config

# ====================================================================
# Step 6: Model Checkpoint Validation
# ====================================================================

step "Step 6/6: Validating model setup"

MODEL_CONFIG="$REPO_DIR/src/Scripts/MMM/models/config.json"
MODEL_DIR="$REPO_DIR/src/Scripts/MMM/models"

# Auto-copy bundled model.pt if present next to install script but not yet in models/
if [ -f "$REPO_DIR/models/model.pt" ] && [ ! -f "$MODEL_DIR/model.pt" ]; then
    info "Copying bundled model checkpoint..."
    cp "$REPO_DIR/models/model.pt" "$MODEL_DIR/model.pt"
    ok "Model copied to $MODEL_DIR/model.pt"
fi
if [ -f "$MODEL_CONFIG" ]; then
    # Resolve the checkpoint path from config
    CKPT_PATH="$(python -c "
import json, os
cfg = json.load(open('$MODEL_CONFIG'))
ckpt = cfg['ckpt']
if not os.path.isabs(ckpt):
    ckpt = os.path.join(os.path.dirname(os.path.abspath('$MODEL_CONFIG')), ckpt)
print(ckpt)
")"
    if [ -f "$CKPT_PATH" ]; then
        CKPT_SIZE="$(du -sh "$CKPT_PATH" | awk '{print $1}')"
        ok "Model checkpoint found: $CKPT_PATH ($CKPT_SIZE)"
    else
        warn "Model checkpoint not found at: $CKPT_PATH"
        echo ""
        echo "  You need to place a model checkpoint (.pt file) at that path,"
        echo "  or update src/Scripts/MMM/models/config.json to point to your checkpoint."
    fi
else
    warn "Model config not found at $MODEL_CONFIG"
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
            # Create a small .command script on the Desktop that calls the real launcher
            cat > "$SHORTCUT" << 'LAUNCHER_EOF'
#!/usr/bin/env bash
LAUNCHER_EOF
            echo "cd \"$(printf '%s' "$REPO_DIR")\" && bash \"./start_mmm_server.sh\"" >> "$SHORTCUT"
            chmod +x "$SHORTCUT"
            ok "Desktop shortcut created: Start MIDI-GPT Server.command"
        fi
    elif [ "$PLATFORM" = "linux" ]; then
        SHORTCUT="$DESKTOP_DIR/Start MIDI-GPT Server.desktop"
        cat > "$SHORTCUT" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Start MIDI-GPT Server
Exec=bash -c 'cd "$REPO_DIR" && bash ./start_mmm_server.sh'
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
echo "  1. Load the ReaScript action:"
echo "     Actions > Show Action List > Load ReaScript"
echo "     Select: $REAPER_DIR/Scripts/MMM/REAPER_mmm_infill.py"
echo ""
echo "  2. Add JSFX plugins:"
echo "     - Add 'MMM Global Options' to Monitor FX (View > Monitoring Effects)"
echo "     - Add 'MMM Track Options (Density-Polyphony)' to tracks you want to control"
echo ""
echo -e "${BOLD}To start the server:${NC}"
if [ -d "$HOME/Desktop" ]; then
    echo "  Double-click ${GREEN}Start MIDI-GPT Server${NC} on your Desktop"
elif [ "$PLATFORM" = "macos" ]; then
    echo "  Double-click: ${GREEN}Start Server - Mac.command${NC}"
elif [ "$PLATFORM" = "windows" ]; then
    echo "  Double-click: ${GREEN}Start Server - Windows.bat${NC}"
else
    echo "  Run: ${GREEN}./start_mmm_server.sh${NC}"
fi
echo "  Or from terminal: cd $REPO_DIR && source .venv/bin/activate && python src/Scripts/MMM/MMM_server.py"
echo ""

# Keep terminal open when launched from a double-click installer
if [ -n "${MIDIGPT_INTERACTIVE:-}" ]; then
    echo ""
    read -rp "Press Enter to close this window..."
fi
