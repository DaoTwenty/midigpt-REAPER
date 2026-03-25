#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER - Windows Bash Installer
#
# Installs everything needed to run MIDI-GPT on Windows from Git Bash / MSYS:
#   1. System dependencies (cmake, git, protobuf dev files, python, uv)
#   2. Python virtual environment + torch
#   3. mmm_refactored C++ backend (built from source via pip)
#   4. REAPER integration (junctions for Scripts + Effects)
#   5. REAPER Python/ReaScript configuration
#   6. Model checkpoint validation
#
# Usage:
#   ./install-windows.sh
#   ./install-windows.sh --skip-deps
#   ./install-windows.sh --mmm-zip=/c/path/to/mmm_refactored.zip
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$REPO_DIR/.venv"
UV_CMD="uv"
PYTHON_SPEC="3.12"
VCPKG_TRIPLET="x64-windows"
MMM_ZIP_URL="PLACEHOLDER_URL"
MMM_ZIP_LOCAL="./mmm_refactored.zip"
MMM_WHEEL_LOCAL=""
MMM_BUILD_DIR="${TEMP:-/tmp}/mmm-refactored-build"
SKIP_DEPS=false
SKIP_REAPER_CONFIG=false
REAPER_DIR_OVERRIDE=""

if [ -z "$MMM_ZIP_LOCAL" ] && [ -f "$REPO_DIR/mmm_refactored.zip" ]; then
    MMM_ZIP_LOCAL="$REPO_DIR/mmm_refactored.zip"
fi

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

step() {
    echo ""
    printf '%s\n' "----------------------------------------------------"
    printf '  %s\n' "$*"
    printf '%s\n' "----------------------------------------------------"
}

patch_mmm_windows_compat() {
    local src_dir="$1"
    local patch_script="$REPO_DIR/scripts/patch-mmm-windows-compat.sh"

    [ -d "$src_dir" ] || fail "mmm_refactored source directory not found: $src_dir"
    [ -f "$patch_script" ] || fail "Compatibility patch helper not found: $patch_script"

    info "Applying Windows compatibility patch to mmm_refactored..."
    bash "$patch_script" "$src_dir"
    ok "Applied Windows compatibility patch"
}

show_help() {
    cat <<'EOF'
MIDI-GPT for REAPER - Windows Bash Installer

Usage: ./install-windows.sh [OPTIONS]

Options:
  --skip-deps             Skip system dependency check
  --skip-reaper-config    Skip automatic REAPER Python/ReaScript configuration
  --reaper-dir=PATH       REAPER resource directory (required for portable installs)
  --mmm-wheel=PATH        Use a local prebuilt mmm_refactored wheel
  --mmm-zip=PATH          Use a local mmm_refactored zip instead of downloading
  --help, -h              Show this help
EOF
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

to_cmake_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -am "$input_path" | tr '\\' '/'
    else
        printf '%s\n' "$input_path" | tr '\\' '/'
    fi
}

to_posix_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -au "$input_path"
    else
        printf '%s\n' "$input_path" | tr '\\' '/'
    fi
}

resolve_reaper_dir() {
    if [ -n "$REAPER_DIR_OVERRIDE" ]; then
        REAPER_DIR="$(to_posix_path "$REAPER_DIR_OVERRIDE")"
    else
        REAPER_DIR="${APPDATA:-$USERPROFILE/AppData/Roaming}/REAPER"
    fi
}

get_default_vcpkg_root() {
    local base="${LOCALAPPDATA:-${USERPROFILE}\\AppData\\Local}"
    if check_cmd cygpath; then
        cygpath -au "$base/vcpkg"
    else
        printf '%s\n' "$base/vcpkg" | tr '\\' '/'
    fi
}

uv_pip_install() {
    "$UV_CMD" pip install --python "$VENV_PYTHON" "$@"
}

venv_python() {
    "$VENV_PYTHON" "$@"
}

find_local_mmm_wheel() {
    local candidate=""

    if [ -n "$MMM_WHEEL_LOCAL" ]; then
        [ -f "$MMM_WHEEL_LOCAL" ] || fail "Local wheel not found: $MMM_WHEEL_LOCAL"
        printf '%s\n' "$MMM_WHEEL_LOCAL"
        return 0
    fi

    for candidate in \
        "$(find "$REPO_DIR/wheelhouse" -maxdepth 1 -type f -name 'mmm_refactored-*.whl' 2>/dev/null | sort | tail -1)" \
        "$(find "$REPO_DIR" -maxdepth 1 -type f -name 'mmm_refactored-*.whl' 2>/dev/null | sort | tail -1)"
    do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

get_venv_platlib() {
    venv_python -c 'import sysconfig; print(sysconfig.get_path("platlib"))' 2>/dev/null || true
}

mmm_extension_present() {
    local platlib_dir=""
    platlib_dir="$(get_venv_platlib)"
    [ -n "$platlib_dir" ] || return 1
    platlib_dir="$(to_posix_path "$platlib_dir")"
    [ -d "$platlib_dir" ] || return 1
    find "$platlib_dir" -maxdepth 1 -type f \( -name 'mmm_refactored*.pyd' -o -name 'mmm_refactored*.so' \) | grep -q .
}

bundle_mmm_runtime_dlls() {
    local platlib_dir=""
    local torch_lib_dir=""
    local protobuf_bin_dir=""
    local copied=0
    local dll_path=""

    platlib_dir="$(get_venv_platlib)"
    [ -n "$platlib_dir" ] || fail "Could not determine platlib/site-packages for the venv"
    platlib_dir="$(to_posix_path "$platlib_dir")"
    [ -d "$platlib_dir" ] || fail "platlib/site-packages directory not found: $platlib_dir"

    torch_lib_dir="$platlib_dir/torch/lib"
    if [ -d "$torch_lib_dir" ]; then
        info "Bundling Torch runtime DLLs into site-packages..."
        while IFS= read -r -d '' dll_path; do
            cp -f "$dll_path" "$platlib_dir/"
            copied=1
        done < <(find "$torch_lib_dir" -maxdepth 1 -type f -iname '*.dll' -print0)
    else
        warn "Torch DLL directory not found at $torch_lib_dir"
    fi

    if find_vcpkg; then
        protobuf_bin_dir="$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET/bin"
    else
        protobuf_bin_dir="$(to_posix_path "${LOCALAPPDATA:-$USERPROFILE/AppData/Local}/vcpkg/installed/$VCPKG_TRIPLET/bin")"
    fi
    if [ -d "$protobuf_bin_dir" ]; then
        info "Bundling protobuf runtime DLLs into site-packages..."
        while IFS= read -r -d '' dll_path; do
            cp -f "$dll_path" "$platlib_dir/"
            copied=1
        done < <(find "$protobuf_bin_dir" -maxdepth 1 -type f -iname '*.dll' -print0)
    else
        warn "protobuf runtime DLL directory not found at $protobuf_bin_dir"
    fi

    if [ "$copied" -eq 1 ]; then
        ok "Native runtime DLLs bundled next to mmm_refactored"
    else
        warn "No native runtime DLLs were copied; import may still rely on PATH"
    fi
}

verify_mmm_import() {
    venv_python -c "import mmm_refactored"
}

install_mmm_wheel() {
    local wheel_path="$1"

    [ -f "$wheel_path" ] || fail "Wheel not found: $wheel_path"

    info "Installing prebuilt wheel: $wheel_path"
    uv_pip_install "$wheel_path" || fail "Failed to install mmm_refactored wheel"

    if ! verify_mmm_import >/dev/null 2>&1; then
        warn "mmm_refactored import failed after wheel install. Diagnostics:"
        print_mmm_import_diagnostics || true
        fail "mmm_refactored wheel installed but the module still could not be imported"
    fi

    ok "mmm_refactored installed from wheel"
}

print_mmm_import_diagnostics() {
    venv_python - <<'PY'
import sys
import sysconfig
import os
import traceback
from pathlib import Path

print("[DIAG] Python executable:", sys.executable)
platlib = Path(sysconfig.get_path("platlib"))
print("[DIAG] platlib:", platlib)
if platlib.is_dir():
    for path in sorted(platlib.glob("mmm_refactored*")):
        print("[DIAG] found:", path.name)

torch_lib = platlib / "torch" / "lib"
print("[DIAG] torch lib dir:", torch_lib, "exists=" + str(torch_lib.is_dir()))
if torch_lib.is_dir():
    torch_dlls = sorted(torch_lib.glob("*.dll"))
    print("[DIAG] torch dll count:", len(torch_dlls))
    for path in torch_dlls[:10]:
        print("[DIAG] torch dll:", path.name)

vcpkg_root = os.environ.get("VCPKG_ROOT")
local_appdata = os.environ.get("LOCALAPPDATA", "")
protobuf_candidates = []
if vcpkg_root:
    protobuf_candidates.append(Path(vcpkg_root) / "installed" / "x64-windows" / "bin")
if local_appdata:
    protobuf_candidates.append(Path(local_appdata) / "vcpkg" / "installed" / "x64-windows" / "bin")
seen = set()
for candidate in protobuf_candidates:
    candidate = candidate.resolve() if candidate.exists() else candidate
    if str(candidate) in seen:
        continue
    seen.add(str(candidate))
    print("[DIAG] protobuf bin dir:", candidate, "exists=" + str(candidate.is_dir()))
    if candidate.is_dir():
        dlls = sorted(candidate.glob("*.dll"))
        print("[DIAG] protobuf dll count:", len(dlls))
        for path in dlls[:10]:
            print("[DIAG] protobuf dll:", path.name)

try:
    import mmm_refactored  # noqa: F401
    print("[DIAG] import mmm_refactored: OK")
except Exception:
    print("[DIAG] import mmm_refactored failed:")
    traceback.print_exc()
    raise
PY
}

ensure_windows_shell() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *)
            fail "This installer is for Windows bash environments only. Use ./install.sh on Linux/macOS."
            ;;
    esac
}

to_windows_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -aw "$input_path"
    else
        printf '%s\n' "$input_path"
    fi
}

activate_venv() {
    # shellcheck disable=SC1091
    source "$VENV_DIR/Scripts/activate"
}

find_protobuf() {
    PROTOC_PATH=""
    PROTOBUF_ROOT=""
    PROTOBUF_INCLUDE_DIR=""
    PROTOBUF_LIBRARY=""
    PROTOBUF_SOURCE=""

    local protoc_cmd="" root="" lib_candidate=""
    for candidate in protoc protoc.exe; do
        if check_cmd "$candidate"; then
            protoc_cmd="$(command -v "$candidate")"
            break
        fi
    done

    if [ -n "$protoc_cmd" ]; then
        root="$(cd "$(dirname "$protoc_cmd")/.." && pwd 2>/dev/null || true)"
        if [ -n "$root" ]; then
            if [ -d "$root/include" ]; then
                PROTOBUF_INCLUDE_DIR="$(to_cmake_path "$root/include")"
            fi

            for lib_candidate in \
                "$root/lib/libprotobuf.lib" \
                "$root/lib64/libprotobuf.lib" \
                "$root/lib/protobuf.lib" \
                "$root/lib64/protobuf.lib"
            do
                if [ -f "$lib_candidate" ]; then
                    PROTOBUF_LIBRARY="$(to_cmake_path "$lib_candidate")"
                    break
                fi
            done

            if [ -z "$PROTOBUF_LIBRARY" ]; then
                lib_candidate="$(find "$root" -type f \( -iname 'libprotobuf.lib' -o -iname 'protobuf.lib' \) 2>/dev/null | head -1)"
                if [ -n "$lib_candidate" ] && [ -f "$lib_candidate" ]; then
                    PROTOBUF_LIBRARY="$(to_cmake_path "$lib_candidate")"
                fi
            fi

            PROTOC_PATH="$(to_cmake_path "$protoc_cmd")"
            PROTOBUF_ROOT="$(to_cmake_path "$root")"

            if [ -n "$PROTOBUF_INCLUDE_DIR" ] && [ -n "$PROTOBUF_LIBRARY" ]; then
                PROTOBUF_SOURCE="system"
                return 0
            fi
        fi
    fi

    if find_vcpkg && [ -d "$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET/include" ]; then
        root="$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET"
        if [ -f "$root/lib/libprotobuf.lib" ]; then
            PROTOBUF_ROOT="$(to_cmake_path "$root")"
            PROTOBUF_INCLUDE_DIR="$(to_cmake_path "$root/include")"
            PROTOBUF_LIBRARY="$(to_cmake_path "$root/lib/libprotobuf.lib")"
            if [ -f "$root/tools/protobuf/protoc.exe" ]; then
                PROTOC_PATH="$(to_cmake_path "$root/tools/protobuf/protoc.exe")"
            fi
            PROTOBUF_SOURCE="vcpkg"
            return 0
        fi
    fi

    return 1
}

find_vcpkg() {
    VCPKG_ROOT_RESOLVED=""
    VCPKG_TOOLCHAIN_FILE=""

    local vcpkg_cmd=""

    if [ -n "${VCPKG_ROOT:-}" ] && [ -f "${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" ]; then
        VCPKG_ROOT_RESOLVED="${VCPKG_ROOT}"
    else
        for candidate in vcpkg vcpkg.exe; do
            if check_cmd "$candidate"; then
                vcpkg_cmd="$(command -v "$candidate")"
                break
            fi
        done

        if [ -n "$vcpkg_cmd" ]; then
            VCPKG_ROOT_RESOLVED="$(cd "$(dirname "$vcpkg_cmd")/.." && pwd 2>/dev/null || true)"
        fi
    fi

    if [ -n "$VCPKG_ROOT_RESOLVED" ] && [ -f "$VCPKG_ROOT_RESOLVED/scripts/buildsystems/vcpkg.cmake" ]; then
        VCPKG_ROOT_RESOLVED="$(to_cmake_path "$VCPKG_ROOT_RESOLVED")"
        VCPKG_TOOLCHAIN_FILE="$VCPKG_ROOT_RESOLVED/scripts/buildsystems/vcpkg.cmake"
        return 0
    fi

    return 1
}

bootstrap_vcpkg() {
    local vcpkg_root=""
    local vcpkg_root_win=""
    local bootstrap_bat_win=""

    check_cmd git || fail "git is required to bootstrap vcpkg"

    vcpkg_root="$(get_default_vcpkg_root)"

    if [ ! -d "$vcpkg_root/.git" ]; then
        info "Cloning vcpkg into $vcpkg_root..."
        git clone https://github.com/microsoft/vcpkg.git "$vcpkg_root" || fail "Failed to clone vcpkg"
    else
        info "Existing vcpkg clone found at $vcpkg_root"
    fi

    vcpkg_root_win="$(to_windows_path "$vcpkg_root")"
    bootstrap_bat_win="$(to_windows_path "$vcpkg_root/bootstrap-vcpkg.bat")"
    info "Bootstrapping vcpkg..."
    cmd.exe //c call "$bootstrap_bat_win" -disableMetrics || fail "Failed to bootstrap vcpkg"

    export VCPKG_ROOT="$vcpkg_root"
    find_vcpkg || fail "vcpkg bootstrap completed but vcpkg could not be located"
    ok "vcpkg ready at $VCPKG_ROOT_RESOLVED"
}

make_reaper_junction() {
    local src="$1"
    local dst="$2"
    local dst_parent dst_win src_win dst_win

    [ -d "$src" ] || return 0

    dst_parent="$(dirname "$dst")"
    mkdir -p "$dst_parent"

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        cmd.exe //c rmdir "$(to_windows_path "$dst")" >/dev/null 2>&1 || true
        rm -rf "$dst" >/dev/null 2>&1 || true
    fi

    src_win="$(to_windows_path "$src")"
    dst_win="$(to_windows_path "$dst")"
    cmd.exe //c mklink //J "$dst_win" "$src_win" >/dev/null || fail "Could not create junction: $dst"
}

set_reaper_ini_value() {
    local ini_path="$1"
    local key="$2"
    local value="$3"

    "$VENV_PYTHON" - "$ini_path" "$key" "$value" <<'PY'
import pathlib
import re
import sys

ini_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = ini_path.read_text(encoding="utf-8", errors="ignore")
pattern = re.compile(rf"(?m)^{re.escape(key)}=.*$")
if pattern.search(text):
    text = pattern.sub(lambda _m: f"{key}={value}", text)
else:
    marker = "[REAPER]"
    if marker in text:
        text = text.replace(marker, f"{marker}\n{key}={value}", 1)
    else:
        text += f"\n[REAPER]\n{key}={value}\n"
ini_path.write_text(text, encoding="utf-8", newline="")
PY
}

reaper_running() {
    tasklist.exe //FI "IMAGENAME eq reaper.exe" 2>/dev/null | tr -d '\r' | grep -qi "reaper.exe"
}

create_desktop_launcher() {
    local desktop_dir shortcut_path repo_win server_win

    desktop_dir="${USERPROFILE:-}/Desktop"
    [ -d "$desktop_dir" ] || return 0

    shortcut_path="$desktop_dir/Start MIDI-GPT Server.cmd"
    repo_win="$(to_windows_path "$REPO_DIR")"
    server_win="$(to_windows_path "$REPO_DIR/Start Server - Windows.bat")"

    printf '%s\r\n' \
        '@echo off' \
        "cd /d \"$repo_win\"" \
        "call \"$server_win\"" > "$shortcut_path"

    ok "Desktop launcher created: Start MIDI-GPT Server.cmd"
}

for arg in "$@"; do
    case "$arg" in
        --skip-deps) SKIP_DEPS=true ;;
        --skip-reaper-config) SKIP_REAPER_CONFIG=true ;;
        --reaper-dir=*) REAPER_DIR_OVERRIDE="${arg#*=}" ;;
        --mmm-wheel=*) MMM_WHEEL_LOCAL="${arg#*=}" ;;
        --mmm-zip=*) MMM_ZIP_LOCAL="${arg#*=}" ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            fail "Unknown option: $arg"
            ;;
    esac
done

ensure_windows_shell

echo ""
echo "  ======================================"
echo "      MIDI-GPT for REAPER Installer"
echo "  ======================================"
echo ""
info "Platform: Windows (bash)"

if [ "$SKIP_DEPS" = false ]; then
    step "Step 1/6: Checking system dependencies"

    MISSING=()

    if check_cmd "$UV_CMD"; then
        ok "uv found"
    else
        MISSING+=("uv")
        warn "uv not found"
    fi

    if find_protobuf; then
        ok "protobuf found ($PROTOBUF_SOURCE)"
    else
        MISSING+=("protobuf")
        warn "protobuf dev files not found"
    fi

    if check_cmd cmake; then
        ok "cmake found"
    else
        MISSING+=("cmake")
        warn "cmake not found"
    fi

    if check_cmd git; then
        ok "git found"
    else
        MISSING+=("git")
        warn "git not found"
    fi

    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo ""
        warn "Missing dependencies: ${MISSING[*]}"
        echo ""

        INSTALLER=""
        if check_cmd winget; then
            INSTALLER="winget"
        elif check_cmd choco; then
            INSTALLER="choco"
        fi

        if [ -n "$INSTALLER" ]; then
            info "Installing via $INSTALLER..."
            for dep in "${MISSING[@]}"; do
                case "$dep" in
                    "protobuf")
                        if ! find_vcpkg; then
                            bootstrap_vcpkg
                        fi
                        info "Installing protobuf:$VCPKG_TRIPLET via vcpkg..."
                        cmd.exe //c "$(to_windows_path "$VCPKG_ROOT_RESOLVED/vcpkg.exe")" install "protobuf:$VCPKG_TRIPLET" || fail "vcpkg protobuf install failed"
                        ;;
                    "uv")
                        if [ "$INSTALLER" = "winget" ]; then
                            winget install --id=astral-sh.uv -e --accept-package-agreements --accept-source-agreements
                        else
                            choco install uv -y
                        fi
                        ;;
                    "cmake")
                        if [ "$INSTALLER" = "winget" ]; then
                            winget install Kitware.CMake --accept-package-agreements --accept-source-agreements
                        else
                            choco install cmake -y
                        fi
                        ;;
                    "git")
                        if [ "$INSTALLER" = "winget" ]; then
                            winget install Git.Git --accept-package-agreements --accept-source-agreements
                        else
                            choco install git -y
                        fi
                        ;;
                esac
            done
        else
            echo "Please install the missing dependencies manually, then re-run:"
            echo "  winget install --id=astral-sh.uv -e"
            echo "  winget install Kitware.CMake"
            echo "  winget install Git.Git"
            echo "  git clone https://github.com/microsoft/vcpkg.git \"$(get_default_vcpkg_root)\""
            echo "  cmd /c \"$(to_windows_path "$(get_default_vcpkg_root)")\\bootstrap-vcpkg.bat -disableMetrics\""
            echo "  vcpkg install protobuf:$VCPKG_TRIPLET"
            fail "Missing dependencies"
        fi
    fi

    check_cmd "$UV_CMD" || fail "uv is required but not found"
    hash -r
    find_protobuf || fail "protobuf is required but could not be resolved to include/ and libprotobuf.lib. Install protobuf:$VCPKG_TRIPLET via vcpkg."
    ok "All system dependencies satisfied"
else
    step "Step 1/6: Skipping dependency check (--skip-deps)"
    check_cmd "$UV_CMD" || fail "uv is required but not found"
    find_protobuf || fail "protobuf is required but could not be resolved to include/ and libprotobuf.lib. Install protobuf:$VCPKG_TRIPLET via vcpkg."
fi

step "Step 2/6: Setting up Python virtual environment"

info "Ensuring uv-managed Python $PYTHON_SPEC is available..."
"$UV_CMD" python install "$PYTHON_SPEC"

if [ -d "$VENV_DIR" ]; then
    info "Existing venv found at $VENV_DIR"
    activate_venv
    VENV_PYTHON="$VENV_DIR/Scripts/python.exe"
    ok "Activated existing venv"
else
    info "Creating venv with uv-managed Python $PYTHON_SPEC..."
    "$UV_CMD" venv --python "$PYTHON_SPEC" "$VENV_DIR"
    activate_venv
    VENV_PYTHON="$VENV_DIR/Scripts/python.exe"
    uv_pip_install --upgrade pip setuptools wheel >/dev/null
    ok "Created and activated venv at $VENV_DIR"
fi

[ -f "$VENV_PYTHON" ] || fail "Venv python not found at $VENV_PYTHON"

info "Checking PyTorch..."
if venv_python -c "import torch" 2>/dev/null; then
    TORCH_VER="$(venv_python -c 'import torch; print(torch.__version__)')"
    ok "PyTorch $TORCH_VER already installed"
else
    info "Installing PyTorch (this may take a few minutes)..."
    uv_pip_install torch torchvision
    TORCH_VER="$(venv_python -c 'import torch; print(torch.__version__)')"
    ok "PyTorch $TORCH_VER installed"
fi

info "Installing build dependencies..."
uv_pip_install scikit-build-core pybind11 >/dev/null
ok "Build dependencies ready"

resolve_reaper_dir
if [ -n "$REAPER_DIR_OVERRIDE" ]; then
    info "Using user-specified REAPER resource dir: $REAPER_DIR"
else
    info "Using default REAPER resource dir: $REAPER_DIR"
    info "If you use a portable REAPER install, re-run with --reaper-dir=/path/to/REAPER-resource-dir"
fi

step "Step 3/6: Building mmm_refactored C++ backend"

if mmm_extension_present; then
    info "Existing mmm_refactored extension found; refreshing bundled runtime DLLs..."
    bundle_mmm_runtime_dlls
fi

if verify_mmm_import >/dev/null 2>&1; then
    ok "mmm_refactored already installed"
elif mmm_extension_present; then
    warn "mmm_refactored is installed, but import still fails after refreshing runtime DLLs."
    print_mmm_import_diagnostics || true
    fail "mmm_refactored is already built but cannot be imported; refusing to rebuild blindly"
elif MMM_WHEEL_PATH="$(find_local_mmm_wheel 2>/dev/null)"; then
    info "Local mmm_refactored wheel detected; using it instead of building from source."
    install_mmm_wheel "$MMM_WHEEL_PATH"
else
    MMM_ZIP_TMP="${TEMP:-/tmp}/mmm_refactored.zip"

    if [ -n "$MMM_ZIP_LOCAL" ]; then
        [ -f "$MMM_ZIP_LOCAL" ] || fail "Local zip not found: $MMM_ZIP_LOCAL"
        info "Using local archive: $MMM_ZIP_LOCAL"
        cp "$MMM_ZIP_LOCAL" "$MMM_ZIP_TMP"
        ok "Copied archive"
    else
        if [ "$MMM_ZIP_URL" = "PLACEHOLDER_URL" ]; then
            echo "The MMM Refactored C++ backend is not yet configured for download."
            echo "Either set MMM_ZIP_URL in install-windows.sh or pass:"
            echo "  ./install-windows.sh --mmm-zip=/path/to/mmm_refactored.zip"
            fail "No MMM Refactored source available"
        fi

        info "Downloading MMM Refactored archive..."
        if check_cmd curl; then
            curl -L -o "$MMM_ZIP_TMP" "$MMM_ZIP_URL"
        elif check_cmd wget; then
            wget -O "$MMM_ZIP_TMP" "$MMM_ZIP_URL"
        else
            fail "Neither curl nor wget found"
        fi
        ok "Downloaded archive"
    fi

    info "Extracting archive..."
    rm -rf "$MMM_BUILD_DIR"
    mkdir -p "$MMM_BUILD_DIR"
    unzip -q "$MMM_ZIP_TMP" -d "$MMM_BUILD_DIR"

    CONTENTS=("$MMM_BUILD_DIR"/*)
    if [ "${#CONTENTS[@]}" -eq 1 ] && [ -d "${CONTENTS[0]}" ]; then
        MMM_SRC_DIR="${CONTENTS[0]}"
        info "Source directory: $(basename "$MMM_SRC_DIR")"
    else
        MMM_SRC_DIR="$MMM_BUILD_DIR"
    fi

    [ -f "$MMM_SRC_DIR/CMakeLists.txt" ] || fail "Extracted archive doesn't look like mmm_refactored"
    ok "Archive extracted"
    patch_mmm_windows_compat "$MMM_SRC_DIR"

    PYBIND11_CMAKE_DIR="$(venv_python -c 'import pybind11; print(pybind11.get_cmake_dir())' 2>/dev/null || true)"
    PYTHON_BASE_PREFIX="$(venv_python -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
    PYTHON_BASE_EXEC_PREFIX="$(venv_python -c 'import sys; print(sys.base_exec_prefix)' 2>/dev/null || true)"
    PYTHON_INCLUDE_DIR="$(venv_python -c 'import pathlib, sys; print(pathlib.Path(sys.base_prefix) / "include")' 2>/dev/null || true)"
    PYTHON_LIBRARY_PATH="$(venv_python -c 'import pathlib, sys; ver = f"{sys.version_info.major}{sys.version_info.minor}"; print(pathlib.Path(sys.base_prefix) / "libs" / f"python{ver}.lib")' 2>/dev/null || true)"

    CMAKE_EXTRA_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    if [ -n "$PYBIND11_CMAKE_DIR" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -Dpybind11_DIR=$(to_cmake_path "$PYBIND11_CMAKE_DIR")"
        info "pybind11 cmake dir: $PYBIND11_CMAKE_DIR"
    fi

    if [ -n "$PYTHON_BASE_PREFIX" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DPython_ROOT_DIR=$(to_cmake_path "$PYTHON_BASE_PREFIX") -DPython3_ROOT_DIR=$(to_cmake_path "$PYTHON_BASE_PREFIX")"
    fi
    if [ -n "$PYTHON_BASE_EXEC_PREFIX" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DPython_EXECUTABLE=$(to_cmake_path "$VENV_PYTHON") -DPython3_EXECUTABLE=$(to_cmake_path "$VENV_PYTHON")"
    fi
    if [ -n "$PYTHON_INCLUDE_DIR" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DPython_INCLUDE_DIR=$(to_cmake_path "$PYTHON_INCLUDE_DIR") -DPython3_INCLUDE_DIR=$(to_cmake_path "$PYTHON_INCLUDE_DIR")"
    fi
    if [ -f "$PYTHON_LIBRARY_PATH" ]; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DPython_LIBRARY=$(to_cmake_path "$PYTHON_LIBRARY_PATH") -DPython3_LIBRARY=$(to_cmake_path "$PYTHON_LIBRARY_PATH")"
    fi

    if find_protobuf; then
        CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DProtobuf_PROTOC_EXECUTABLE=$PROTOC_PATH -DProtobuf_INCLUDE_DIR=$PROTOBUF_INCLUDE_DIR -DProtobuf_LIBRARY=$PROTOBUF_LIBRARY -DProtobuf_LIBRARIES=$PROTOBUF_LIBRARY"
        if [ "$PROTOBUF_SOURCE" = "vcpkg" ] && find_vcpkg; then
            CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN_FILE -DVCPKG_TARGET_TRIPLET=$VCPKG_TRIPLET -DCMAKE_PREFIX_PATH=$PROTOBUF_ROOT"
            info "protobuf via vcpkg: $PROTOBUF_ROOT"
            info "vcpkg toolchain: $VCPKG_TOOLCHAIN_FILE"
        else
            CMAKE_EXTRA_ARGS="$CMAKE_EXTRA_ARGS -DCMAKE_PREFIX_PATH=$PROTOBUF_ROOT"
            info "protobuf root: $PROTOBUF_ROOT"
        fi
        info "protobuf library: $PROTOBUF_LIBRARY"
    fi

    info "Building C++ extension (this takes 2-5 minutes)..."
    CMAKE_ARGS="$CMAKE_EXTRA_ARGS" "$UV_CMD" pip install --python "$VENV_PYTHON" "$MMM_SRC_DIR" --no-build-isolation

    bundle_mmm_runtime_dlls
    if ! verify_mmm_import >/dev/null 2>&1; then
        warn "mmm_refactored import failed after build. Diagnostics:"
        print_mmm_import_diagnostics || true
        fail "mmm_refactored build completed but the module still could not be imported"
    fi
    ok "mmm_refactored built and installed"

    rm -rf "$MMM_BUILD_DIR" "$MMM_ZIP_TMP"
    info "Cleaned up build files"
fi

info "Installing Python dependencies..."
uv_pip_install -e "$REPO_DIR" >/dev/null 2>&1 || uv_pip_install -e "$REPO_DIR"
uv_pip_install symusic >/dev/null
ok "Python dependencies installed"

step "Step 4/6: Setting up REAPER integration"

SCRIPTS_SRC="$REPO_DIR/src/Scripts/MMM"
EFFECTS_SRC="$REPO_DIR/src/Effects/MMM"
SCRIPTS_DST="$REAPER_DIR/Scripts/MMM"
EFFECTS_DST="$REAPER_DIR/Effects/MMM"

if [ -d "$REAPER_DIR" ]; then
    make_reaper_junction "$SCRIPTS_SRC" "$SCRIPTS_DST"
    make_reaper_junction "$EFFECTS_SRC" "$EFFECTS_DST"
    ok "REAPER junctions created"
else
    warn "REAPER config directory not found - REAPER may not be installed yet"
fi

if [ "$SKIP_REAPER_CONFIG" = true ]; then
    step "Step 5/6: Skipping REAPER config (--skip-reaper-config)"
else
    step "Step 5/6: Configuring REAPER (reaper.ini)"

    REAPER_INI="$REAPER_DIR/reaper.ini"
    # REAPER only needs a valid Python runtime DLL for ReaScript.
    # The server uses the venv's packages, but the DLL should come from the
    # base interpreter behind the uv-managed venv, not from the venv prefix.
    PYTHON_DLL_PATH="$(venv_python -c 'import pathlib, sys; base = pathlib.Path(sys.base_exec_prefix); dll = next(base.glob(f"python{sys.version_info.major}{sys.version_info.minor}.dll"), None); print(dll or "")' 2>/dev/null)"

    if [ -f "$REAPER_INI" ]; then
        if reaper_running; then
            warn "REAPER is currently running"
            echo "Please quit REAPER and re-run this installer, or configure ReaScript manually."
            [ -n "$PYTHON_DLL_PATH" ] && echo "Python library: $PYTHON_DLL_PATH"
        elif [ -n "$PYTHON_DLL_PATH" ] && [ -f "$PYTHON_DLL_PATH" ]; then
            cp "$REAPER_INI" "$REAPER_INI.midigpt-backup"
            info "Backed up reaper.ini"

            set_reaper_ini_value "$REAPER_INI" "reascript" "1"
            set_reaper_ini_value "$REAPER_INI" "pythonlibdll64" "$PYTHON_DLL_PATH"

            ok "ReaScript enabled (reascript=1)"
            ok "Python library: $PYTHON_DLL_PATH"
        else
            warn "Could not detect Python DLL path"
            echo "Configure manually in REAPER: Options > Preferences > Plug-Ins > ReaScript"
        fi
    else
        if [ -d "$REAPER_DIR" ]; then
            warn "reaper.ini not found - launch REAPER once, quit it, then re-run this installer"
        else
            warn "REAPER config directory not found - REAPER may not be installed"
        fi
        [ -n "$PYTHON_DLL_PATH" ] && echo "When ready, set the Python library path to: $PYTHON_DLL_PATH"
    fi
fi

step "Step 6/6: Validating model setup"

MODEL_CONFIG="$REPO_DIR/src/Scripts/MMM/models/config.json"
MODEL_DIR="$REPO_DIR/src/Scripts/MMM/models"
TARGET_MODEL="$MODEL_DIR/model.pt"
MODEL_CONFIG_WIN="$(to_windows_path "$MODEL_CONFIG")"

if [ -f "$REPO_DIR/models/model.pt" ] && [ ! -f "$TARGET_MODEL" ]; then
    info "Copying bundled model checkpoint..."
    cp "$REPO_DIR/models/model.pt" "$TARGET_MODEL"
    ok "Model copied to $TARGET_MODEL"
fi

if [ -f "$MODEL_CONFIG" ]; then
    CKPT_PATH="$(venv_python -c "import json, os; cfg_path = r'$MODEL_CONFIG_WIN'; cfg = json.load(open(cfg_path)); ckpt = cfg['ckpt']; print(ckpt if os.path.isabs(ckpt) else os.path.join(os.path.dirname(os.path.abspath(cfg_path)), ckpt))")"
    if [ -f "$CKPT_PATH" ]; then
        ok "Model checkpoint found: $CKPT_PATH"
    else
        warn "Model checkpoint not found at: $CKPT_PATH"
        echo "Place a model checkpoint (.pt file) there or update src/Scripts/MMM/models/config.json"
    fi
else
    warn "Model config not found at $MODEL_CONFIG"
fi

create_desktop_launcher

echo ""
echo "===================================================="
echo "  Installation Complete!"
echo "===================================================="
echo ""
echo "Next steps in REAPER:"
echo "  1. Actions > Show Action List > Load ReaScript"
echo "  2. Select: $REAPER_DIR/Scripts/MMM/REAPER_mmm_infill.py"
echo "  3. In the FX browser, search for 'MMM' or 'JS: MMM'"
echo "  4. Add 'JS: MMM Global Options' to Monitor FX"
echo "  5. Add 'JS: MMM Track Options (MIDI-GPT)' to the tracks you want to control"
echo ""
echo "To start the server:"
echo "  Double-click Start MIDI-GPT Server.cmd on your Desktop"
echo "  or run Start Server - Windows.bat from the repo root"
