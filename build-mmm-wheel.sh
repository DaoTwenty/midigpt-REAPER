#!/usr/bin/env bash
# ============================================================================
# Build a Windows wheel for mmm_refactored
#
# Produces a reusable wheel that can be shared with colleagues or bundled into
# a release, without running the full plugin installer.
#
# Usage:
#   ./build-mmm-wheel.sh
#   ./build-mmm-wheel.sh --mmm-src=/c/path/to/mmm_refactored
#   ./build-mmm-wheel.sh --mmm-zip=/c/path/to/mmm_refactored.zip
#   ./build-mmm-wheel.sh --output-dir=wheelhouse
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
UV_CMD="uv"
PYTHON_SPEC="3.12"
VCPKG_TRIPLET="x64-windows"
DEFAULT_MMM_SRC="$REPO_DIR/../mmm_refactored"
DEFAULT_MMM_ZIP="$REPO_DIR/mmm_refactored.zip"
OUTPUT_DIR="$REPO_DIR/wheelhouse"
BUILD_VENV_DIR="$REPO_DIR/.wheel-build-venv"
MMM_SRC=""
MMM_ZIP=""
EXTRACT_ROOT=""
BUILD_VENV_PYTHON=""
VERIFY_VENV_DIR=""

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

show_help() {
    cat <<'EOF'
Build a Windows wheel for mmm_refactored

Usage: ./build-mmm-wheel.sh [OPTIONS]

Options:
  --mmm-src=PATH      Path to unpacked mmm_refactored source
  --mmm-zip=PATH      Path to mmm_refactored zip
  --output-dir=PATH   Directory for the built wheel (default: ./wheelhouse)
  --python=VERSION    uv-managed Python version to build with (default: 3.12)
  --help, -h          Show this help
EOF
}

cleanup() {
    if [ -n "$EXTRACT_ROOT" ] && [ -d "$EXTRACT_ROOT" ]; then
        rm -rf "$EXTRACT_ROOT"
    fi
    if [ -n "$VERIFY_VENV_DIR" ] && [ -d "$VERIFY_VENV_DIR" ]; then
        rm -rf "$VERIFY_VENV_DIR"
    fi
}

trap cleanup EXIT

patch_mmm_windows_compat() {
    local src_dir="$1"
    local patch_script="$REPO_DIR/scripts/patch-mmm-windows-compat.sh"

    [ -d "$src_dir" ] || fail "mmm_refactored source directory not found: $src_dir"
    [ -f "$patch_script" ] || fail "Compatibility patch helper not found: $patch_script"

    info "Applying Windows compatibility patch to mmm_refactored..."
    bash "$patch_script" "$src_dir"
    ok "Applied Windows compatibility patch"
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

to_posix_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -au "$input_path"
    else
        printf '%s\n' "$input_path" | tr '\\' '/'
    fi
}

to_cmake_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -am "$input_path" | tr '\\' '/'
    else
        printf '%s\n' "$input_path" | tr '\\' '/'
    fi
}

to_windows_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -aw "$input_path"
    else
        printf '%s\n' "$input_path"
    fi
}

ensure_windows_shell() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) fail "This wheel builder is for Windows bash environments only." ;;
    esac
}

get_default_vcpkg_root() {
    local base="${LOCALAPPDATA:-${USERPROFILE}\\AppData\\Local}"
    if check_cmd cygpath; then
        cygpath -au "$base/vcpkg"
    else
        printf '%s\n' "$base/vcpkg" | tr '\\' '/'
    fi
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
    local bootstrap_bat_win=""

    check_cmd git || fail "git is required to bootstrap vcpkg"

    vcpkg_root="$(get_default_vcpkg_root)"
    if [ ! -d "$vcpkg_root/.git" ]; then
        info "Cloning vcpkg into $vcpkg_root..."
        git clone https://github.com/microsoft/vcpkg.git "$vcpkg_root" || fail "Failed to clone vcpkg"
    else
        info "Existing vcpkg clone found at $vcpkg_root"
    fi

    bootstrap_bat_win="$(to_windows_path "$vcpkg_root/bootstrap-vcpkg.bat")"
    info "Bootstrapping vcpkg..."
    cmd.exe //c call "$bootstrap_bat_win" -disableMetrics || fail "Failed to bootstrap vcpkg"

    export VCPKG_ROOT="$vcpkg_root"
    find_vcpkg || fail "vcpkg bootstrap completed but vcpkg could not be located"
    ok "vcpkg ready at $VCPKG_ROOT_RESOLVED"
}

find_protobuf() {
    PROTOC_PATH=""
    PROTOBUF_ROOT=""
    PROTOBUF_INCLUDE_DIR=""
    PROTOBUF_LIBRARY=""

    if find_vcpkg && [ -d "$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET/include" ]; then
        local root="$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET"
        if [ -f "$root/lib/libprotobuf.lib" ]; then
            PROTOBUF_ROOT="$(to_cmake_path "$root")"
            PROTOBUF_INCLUDE_DIR="$(to_cmake_path "$root/include")"
            PROTOBUF_LIBRARY="$(to_cmake_path "$root/lib/libprotobuf.lib")"
            if [ -f "$root/tools/protobuf/protoc.exe" ]; then
                PROTOC_PATH="$(to_cmake_path "$root/tools/protobuf/protoc.exe")"
            fi
            return 0
        fi
    fi

    return 1
}

ensure_protobuf() {
    if find_protobuf; then
        ok "protobuf found in vcpkg ($VCPKG_TRIPLET)"
        return
    fi

    if ! find_vcpkg; then
        bootstrap_vcpkg
    fi

    info "Installing protobuf:$VCPKG_TRIPLET via vcpkg..."
    cmd.exe //c "$(to_windows_path "$VCPKG_ROOT_RESOLVED/vcpkg.exe")" install "protobuf:$VCPKG_TRIPLET" || fail "vcpkg protobuf install failed"
    find_protobuf || fail "protobuf install completed, but include/libprotobuf.lib could not be resolved"
    ok "protobuf ready"
}

resolve_mmm_source() {
    if [ -n "$MMM_SRC" ]; then
        [ -f "$MMM_SRC/CMakeLists.txt" ] || fail "mmm_refactored source is missing CMakeLists.txt: $MMM_SRC"
        EXTRACT_ROOT="$(mktemp -d "${TEMP:-/tmp}/mmm-wheel-build.XXXXXX")"
        info "Staging mmm_refactored source into $EXTRACT_ROOT..."
        cp -R "$MMM_SRC" "$EXTRACT_ROOT/"
        MMM_SRC="$EXTRACT_ROOT/$(basename "$MMM_SRC")"
        return
    fi

    if [ -z "$MMM_ZIP" ] && [ -f "$DEFAULT_MMM_ZIP" ]; then
        MMM_ZIP="$DEFAULT_MMM_ZIP"
    fi

    if [ -z "$MMM_ZIP" ] && [ -d "$DEFAULT_MMM_SRC" ]; then
        MMM_SRC="$DEFAULT_MMM_SRC"
        [ -f "$MMM_SRC/CMakeLists.txt" ] || fail "mmm_refactored source is missing CMakeLists.txt: $MMM_SRC"
        EXTRACT_ROOT="$(mktemp -d "${TEMP:-/tmp}/mmm-wheel-build.XXXXXX")"
        info "Staging mmm_refactored source into $EXTRACT_ROOT..."
        cp -R "$MMM_SRC" "$EXTRACT_ROOT/"
        MMM_SRC="$EXTRACT_ROOT/$(basename "$MMM_SRC")"
        return
    fi

    [ -n "$MMM_ZIP" ] || fail "Provide --mmm-src or --mmm-zip, or place mmm_refactored.zip next to this script"
    [ -f "$MMM_ZIP" ] || fail "mmm_refactored zip not found: $MMM_ZIP"

    EXTRACT_ROOT="$(mktemp -d "${TEMP:-/tmp}/mmm-wheel-build.XXXXXX")"
    info "Extracting mmm_refactored zip..."
    unzip -q "$MMM_ZIP" -d "$EXTRACT_ROOT"

    local contents=("$EXTRACT_ROOT"/*)
    if [ "${#contents[@]}" -eq 1 ] && [ -d "${contents[0]}" ]; then
        MMM_SRC="${contents[0]}"
    else
        MMM_SRC="$EXTRACT_ROOT"
    fi

    [ -f "$MMM_SRC/CMakeLists.txt" ] || fail "Extracted zip does not look like mmm_refactored"
}

ensure_build_venv() {
    info "Ensuring uv-managed Python $PYTHON_SPEC is available..."
    "$UV_CMD" python install "$PYTHON_SPEC"

    if [ ! -d "$BUILD_VENV_DIR" ]; then
        info "Creating wheel build venv..."
        "$UV_CMD" venv --python "$PYTHON_SPEC" "$BUILD_VENV_DIR"
    else
        info "Reusing wheel build venv at $BUILD_VENV_DIR"
    fi

    BUILD_VENV_PYTHON="$BUILD_VENV_DIR/Scripts/python.exe"
    [ -f "$BUILD_VENV_PYTHON" ] || fail "Build venv python not found at $BUILD_VENV_PYTHON"

    info "Installing build dependencies into wheel venv..."
    "$UV_CMD" pip install --python "$BUILD_VENV_PYTHON" --upgrade pip setuptools wheel >/dev/null
    "$UV_CMD" pip install --python "$BUILD_VENV_PYTHON" torch torchvision scikit-build-core pybind11 >/dev/null
    ok "Wheel build venv ready"
}

get_build_venv_platlib() {
    "$BUILD_VENV_PYTHON" -c 'import sysconfig; print(sysconfig.get_path("platlib"))' 2>/dev/null || true
}

find_built_wheel() {
    find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.whl' | sort | tail -1
}

build_wheel() {
    local pybind11_cmake_dir=""
    local python_base_prefix=""
    local python_include_dir=""
    local python_library_path=""
    local output_dir_abs=""
    local cmake_args=""

    output_dir_abs="$OUTPUT_DIR"
    mkdir -p "$output_dir_abs"

    pybind11_cmake_dir="$("$BUILD_VENV_PYTHON" -c 'import pybind11; print(pybind11.get_cmake_dir())' 2>/dev/null || true)"
    python_base_prefix="$("$BUILD_VENV_PYTHON" -c 'import sys; print(sys.base_prefix)' 2>/dev/null || true)"
    python_include_dir="$("$BUILD_VENV_PYTHON" -c 'import pathlib, sys; print(pathlib.Path(sys.base_prefix) / "include")' 2>/dev/null || true)"
    python_library_path="$("$BUILD_VENV_PYTHON" -c 'import pathlib, sys; ver = f"{sys.version_info.major}{sys.version_info.minor}"; print(pathlib.Path(sys.base_prefix) / "libs" / f"python{ver}.lib")' 2>/dev/null || true)"

    cmake_args="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    if [ -n "$pybind11_cmake_dir" ]; then
        cmake_args="$cmake_args -Dpybind11_DIR=$(to_cmake_path "$pybind11_cmake_dir")"
    fi
    if [ -n "$python_base_prefix" ]; then
        cmake_args="$cmake_args -DPython_ROOT_DIR=$(to_cmake_path "$python_base_prefix") -DPython3_ROOT_DIR=$(to_cmake_path "$python_base_prefix")"
    fi
    if [ -n "$python_include_dir" ]; then
        cmake_args="$cmake_args -DPython_INCLUDE_DIR=$(to_cmake_path "$python_include_dir") -DPython3_INCLUDE_DIR=$(to_cmake_path "$python_include_dir")"
    fi
    if [ -f "$python_library_path" ]; then
        cmake_args="$cmake_args -DPython_LIBRARY=$(to_cmake_path "$python_library_path") -DPython3_LIBRARY=$(to_cmake_path "$python_library_path")"
    fi

    find_protobuf || fail "protobuf must be available before building the wheel"
    cmake_args="$cmake_args -DProtobuf_PROTOC_EXECUTABLE=$PROTOC_PATH -DProtobuf_INCLUDE_DIR=$PROTOBUF_INCLUDE_DIR -DProtobuf_LIBRARY=$PROTOBUF_LIBRARY -DProtobuf_LIBRARIES=$PROTOBUF_LIBRARY"

    if find_vcpkg; then
        cmake_args="$cmake_args -DCMAKE_TOOLCHAIN_FILE=$VCPKG_TOOLCHAIN_FILE -DVCPKG_TARGET_TRIPLET=$VCPKG_TRIPLET -DCMAKE_PREFIX_PATH=$PROTOBUF_ROOT"
    else
        cmake_args="$cmake_args -DCMAKE_PREFIX_PATH=$PROTOBUF_ROOT"
    fi

    info "Building wheel from $MMM_SRC..."
    (
        cd "$MMM_SRC"
        CMAKE_ARGS="$cmake_args" "$UV_CMD" build --wheel --out-dir "$output_dir_abs" --python "$BUILD_VENV_PYTHON" --no-build-isolation
    ) || fail "Wheel build failed"
}

bundle_runtime_dlls_into_wheel() {
    local wheel_path="$1"
    local wheel_unpack_dir=""
    local wheel_work_root=""
    local platlib_dir=""
    local torch_lib_dir=""
    local protobuf_bin_dir=""
    local dll_count=0
    local dll_path=""
    local packed_wheel=""
    local wheel_name=""

    [ -f "$wheel_path" ] || fail "Wheel not found: $wheel_path"

    platlib_dir="$(get_build_venv_platlib)"
    [ -n "$platlib_dir" ] || fail "Could not determine build venv platlib"
    platlib_dir="$(to_posix_path "$platlib_dir")"
    [ -d "$platlib_dir" ] || fail "Build venv platlib not found: $platlib_dir"

    wheel_work_root="$(mktemp -d "${TEMP:-/tmp}/mmm-wheel-patch.XXXXXX")"
    wheel_unpack_dir="$wheel_work_root/unpacked"
    mkdir -p "$wheel_unpack_dir"

    info "Unpacking wheel to bundle runtime DLLs..."
    "$BUILD_VENV_PYTHON" -m wheel unpack --dest "$wheel_unpack_dir" "$wheel_path" >/dev/null || fail "Failed to unpack wheel"

    wheel_name="$(basename "$wheel_path" .whl)"
    wheel_unpack_dir="$(find "$wheel_unpack_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$wheel_unpack_dir" ] || fail "Wheel unpack did not produce a directory"

    torch_lib_dir="$platlib_dir/torch/lib"
    if [ -d "$torch_lib_dir" ]; then
        info "Bundling Torch runtime DLLs into wheel..."
        while IFS= read -r -d '' dll_path; do
            cp -f "$dll_path" "$wheel_unpack_dir/"
            dll_count=$((dll_count + 1))
        done < <(find "$torch_lib_dir" -maxdepth 1 -type f -iname '*.dll' -print0)
    else
        warn "Torch DLL directory not found in build venv: $torch_lib_dir"
    fi

    if find_vcpkg; then
        protobuf_bin_dir="$VCPKG_ROOT_RESOLVED/installed/$VCPKG_TRIPLET/bin"
    else
        protobuf_bin_dir="$(to_posix_path "${LOCALAPPDATA:-$USERPROFILE/AppData/Local}/vcpkg/installed/$VCPKG_TRIPLET/bin")"
    fi
    if [ -d "$protobuf_bin_dir" ]; then
        info "Bundling protobuf runtime DLLs into wheel..."
        while IFS= read -r -d '' dll_path; do
            cp -f "$dll_path" "$wheel_unpack_dir/"
            dll_count=$((dll_count + 1))
        done < <(find "$protobuf_bin_dir" -maxdepth 1 -type f -iname '*.dll' -print0)
    else
        warn "protobuf runtime DLL directory not found: $protobuf_bin_dir"
    fi

    [ "$dll_count" -gt 0 ] || fail "No runtime DLLs were bundled into the wheel"

    rm -f "$wheel_path"
    "$BUILD_VENV_PYTHON" -m wheel pack --dest-dir "$OUTPUT_DIR" "$wheel_unpack_dir" >/dev/null || fail "Failed to repack wheel"

    packed_wheel="$(find_built_wheel)"
    [ -n "$packed_wheel" ] || fail "Repacked wheel not found"
    ok "Bundled $dll_count runtime DLLs into $(basename "$packed_wheel")"

    rm -rf "$wheel_work_root"
}

verify_wheel_import() {
    local wheel_path="$1"
    local verify_python=""

    [ -f "$wheel_path" ] || fail "Wheel not found for verification: $wheel_path"

    VERIFY_VENV_DIR="$(mktemp -d "${TEMP:-/tmp}/mmm-wheel-verify.XXXXXX")"
    rm -rf "$VERIFY_VENV_DIR"

    info "Creating clean verification venv..."
    "$UV_CMD" venv --python "$PYTHON_SPEC" "$VERIFY_VENV_DIR" >/dev/null || fail "Failed to create verification venv"
    verify_python="$VERIFY_VENV_DIR/Scripts/python.exe"
    [ -f "$verify_python" ] || fail "Verification venv python not found"

    info "Installing wheel into verification venv..."
    "$UV_CMD" pip install --python "$verify_python" "$wheel_path" >/dev/null || fail "Failed to install built wheel for verification"

    info "Verifying mmm_refactored import in clean venv..."
    "$verify_python" -c "import mmm_refactored; print('mmm_refactored import ok')" || fail "Wheel installed but mmm_refactored import failed"
    ok "Wheel import verified in clean venv"
}

for arg in "$@"; do
    case "$arg" in
        --mmm-src=*) MMM_SRC="${arg#*=}" ;;
        --mmm-zip=*) MMM_ZIP="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --python=*) PYTHON_SPEC="${arg#*=}" ;;
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
check_cmd "$UV_CMD" || fail "uv is required"
check_cmd cmake || fail "cmake is required"

resolve_mmm_source
patch_mmm_windows_compat "$MMM_SRC"
ensure_protobuf
ensure_build_venv
build_wheel

WHEEL_PATH="$(find_built_wheel)"
[ -n "$WHEEL_PATH" ] || fail "Wheel build completed but no wheel was found in $OUTPUT_DIR"

bundle_runtime_dlls_into_wheel "$WHEEL_PATH"
WHEEL_PATH="$(find_built_wheel)"
[ -n "$WHEEL_PATH" ] || fail "Wheel repack completed but no wheel was found in $OUTPUT_DIR"

verify_wheel_import "$WHEEL_PATH"

ok "Wheel created: $WHEEL_PATH"
