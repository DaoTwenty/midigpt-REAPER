#!/usr/bin/env bash
# Quick environment checks for install-windows.sh assumptions.
#
# Usage:
#   ./test-windows-env.sh
#   ./test-windows-env.sh --verbose

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILURES=0
WARNINGS=0
VERBOSE=false
VCPKG_TRIPLET="x64-windows"
REAPER_DIR_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --reaper-dir=*) REAPER_DIR_OVERRIDE="${arg#*=}" ;;
        --help|-h)
            cat <<'EOF'
Usage: ./test-windows-env.sh [--verbose] [--reaper-dir=PATH]

Checks the Windows/Git Bash assumptions used by install-windows.sh.
It reports required failures separately from warnings.
Use --reaper-dir for portable REAPER installs.
EOF
            exit 0
            ;;
        *)
            printf '[ERROR] Unknown option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
info() {
    if [ "$VERBOSE" = true ]; then
        printf '[INFO] %s\n' "$*"
    fi
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

trim_cr() {
    printf '%s' "$1" | tr -d '\r'
}

pick_python() {
    local cmd py_major py_minor py_ver
    for cmd in python python.exe python3 python3.exe py py.exe; do
        if ! check_cmd "$cmd"; then
            continue
        fi

        if [ "$cmd" = "py" ] || [ "$cmd" = "py.exe" ]; then
            py_major="$(trim_cr "$("$cmd" -3 -c "import sys; print(sys.version_info.major)" 2>/dev/null || true)")"
            py_minor="$(trim_cr "$("$cmd" -3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || true)")"
            py_ver="$(trim_cr "$("$cmd" -3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>/dev/null || true)")"
        else
            py_major="$(trim_cr "$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null || true)")"
            py_minor="$(trim_cr "$("$cmd" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || true)")"
            py_ver="$(trim_cr "$("$cmd" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>/dev/null || true)")"
        fi

        if [[ "$py_major" =~ ^[0-9]+$ ]] && [[ "$py_minor" =~ ^[0-9]+$ ]] && [ "$py_major" -ge 3 ] && [ "$py_minor" -ge 10 ]; then
            printf '%s|%s\n' "$cmd" "$py_ver"
            return 0
        fi
    done
    return 1
}

to_windows_path() {
    local input_path="$1"
    if check_cmd cygpath; then
        cygpath -aw "$input_path"
    else
        printf '%s\n' "$input_path"
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

smoke_test_junction() {
    local scratch src dst src_win dst_win

    scratch="${TMP:-${TEMP:-/tmp}}/midigpt-windows-env-test-$$"
    src="$scratch/src"
    dst="$scratch/dst"

    mkdir -p "$src" || return 1
    printf 'ok\n' > "$src/probe.txt" || return 1

    src_win="$(to_windows_path "$src")"
    dst_win="$(to_windows_path "$dst")"

    if ! cmd.exe //c mklink //J "$dst_win" "$src_win" >/dev/null 2>&1; then
        rm -rf "$scratch" >/dev/null 2>&1 || true
        return 1
    fi

    if [ ! -f "$dst/probe.txt" ]; then
        cmd.exe //c rmdir "$dst_win" >/dev/null 2>&1 || true
        rm -rf "$scratch" >/dev/null 2>&1 || true
        return 1
    fi

    cmd.exe //c rmdir "$dst_win" >/dev/null 2>&1 || true
    rm -rf "$scratch" >/dev/null 2>&1 || true
    return 0
}

echo "Checking install-windows.sh environment assumptions"
echo ""

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        pass "Bash environment looks Windows-compatible: $(uname -s)"
        ;;
    *)
        fail "Expected Git Bash / MSYS / Cygwin on Windows, got: $(uname -s)"
        ;;
esac

if check_cmd cmd.exe; then
    pass "cmd.exe is available"
else
    fail "cmd.exe is required for junction creation and launcher behavior"
fi

if check_cmd tasklist.exe; then
    pass "tasklist.exe is available"
else
    warn "tasklist.exe is not available; REAPER running-state detection may fail"
fi

if check_cmd cygpath; then
    pass "cygpath is available for Bash-to-Windows path conversion"
else
    warn "cygpath is missing; path conversion may fail in some shells"
fi

if check_cmd uv; then
    pass "uv is available"
else
    fail "uv is required for install-windows.sh"
fi

PROTOC_PATH=""
PROTOBUF_INCLUDE_DIR=""
PROTOBUF_LIBRARY=""
VCPKG_ROOT_DETECTED=""
for protoc_candidate in protoc protoc.exe; do
    if check_cmd "$protoc_candidate"; then
        PROTOC_PATH="$(command -v "$protoc_candidate")"
        break
    fi
done

PROTOBUF_READY=false

if [ -n "$PROTOC_PATH" ]; then
    pass "protoc is available"
    PROTOBUF_ROOT="$(cd "$(dirname "$PROTOC_PATH")/.." && pwd 2>/dev/null || true)"
    if [ -n "$PROTOBUF_ROOT" ] && [ -d "$PROTOBUF_ROOT/include" ]; then
        PROTOBUF_INCLUDE_DIR="$PROTOBUF_ROOT/include"
        pass "Protobuf include dir found: $PROTOBUF_INCLUDE_DIR"
    else
        warn "Could not find a protobuf include directory next to protoc"
    fi

    for protobuf_lib_candidate in \
        "$PROTOBUF_ROOT/lib/libprotobuf.lib" \
        "$PROTOBUF_ROOT/lib64/libprotobuf.lib" \
        "$PROTOBUF_ROOT/lib/protobuf.lib" \
        "$PROTOBUF_ROOT/lib64/protobuf.lib"
    do
        if [ -f "$protobuf_lib_candidate" ]; then
            PROTOBUF_LIBRARY="$protobuf_lib_candidate"
            break
        fi
    done

    if [ -z "$PROTOBUF_LIBRARY" ] && [ -n "$PROTOBUF_ROOT" ]; then
        PROTOBUF_LIBRARY="$(find "$PROTOBUF_ROOT" -type f \( -iname 'libprotobuf.lib' -o -iname 'protobuf.lib' \) 2>/dev/null | head -1)"
    fi

    if [ -n "$PROTOBUF_LIBRARY" ] && [ -f "$PROTOBUF_LIBRARY" ]; then
        pass "Protobuf library found: $PROTOBUF_LIBRARY"
        PROTOBUF_READY=true
    else
        warn "Could not find libprotobuf next to protoc"
    fi
else
    warn "protoc is not on PATH"
fi

if [ -n "${VCPKG_ROOT:-}" ] && [ -f "${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" ]; then
    VCPKG_ROOT_DETECTED="${VCPKG_ROOT}"
elif check_cmd vcpkg || check_cmd vcpkg.exe; then
    VCPKG_CMD="$(command -v vcpkg 2>/dev/null || command -v vcpkg.exe 2>/dev/null || true)"
    if [ -n "$VCPKG_CMD" ]; then
        VCPKG_ROOT_DETECTED="$(cd "$(dirname "$VCPKG_CMD")/.." && pwd 2>/dev/null || true)"
    fi
fi

if [ -n "$VCPKG_ROOT_DETECTED" ] && [ -f "$VCPKG_ROOT_DETECTED/scripts/buildsystems/vcpkg.cmake" ]; then
    pass "vcpkg detected: $VCPKG_ROOT_DETECTED"
    if [ -x "$VCPKG_ROOT_DETECTED/vcpkg" ] || [ -f "$VCPKG_ROOT_DETECTED/vcpkg.exe" ]; then
        VCPKG_BIN="$VCPKG_ROOT_DETECTED/vcpkg"
        [ -f "$VCPKG_ROOT_DETECTED/vcpkg.exe" ] && VCPKG_BIN="$VCPKG_ROOT_DETECTED/vcpkg.exe"
        if "$VCPKG_BIN" version >/dev/null 2>&1; then
            pass "vcpkg command runs successfully"
        else
            fail "vcpkg was found, but the command does not run successfully"
        fi
    else
        fail "vcpkg root was found, but no vcpkg executable is present"
    fi
    if [ -f "$VCPKG_ROOT_DETECTED/installed/$VCPKG_TRIPLET/lib/libprotobuf.lib" ]; then
        pass "vcpkg protobuf library found: $VCPKG_ROOT_DETECTED/installed/$VCPKG_TRIPLET/lib/libprotobuf.lib"
        PROTOBUF_READY=true
    else
        warn "vcpkg detected, but protobuf:$VCPKG_TRIPLET does not appear to be installed"
    fi
else
    warn "vcpkg not detected; install-windows.sh will try to bootstrap it"
fi

if [ "$PROTOBUF_READY" != true ]; then
    if check_cmd git; then
        warn "No usable protobuf C++ development package found yet; install-windows.sh should be able to bootstrap vcpkg and install it"
    else
        fail "No usable protobuf C++ development package found, and git is missing so install-windows.sh cannot bootstrap vcpkg"
    fi
fi

if [ -n "${APPDATA:-}" ]; then
    pass "APPDATA is set: $APPDATA"
elif [ -n "${USERPROFILE:-}" ]; then
    warn "APPDATA is not set; installer will fall back to USERPROFILE"
else
    fail "Neither APPDATA nor USERPROFILE is set"
fi

if [ -n "${USERPROFILE:-}" ]; then
    pass "USERPROFILE is set: $USERPROFILE"
else
    fail "USERPROFILE is not set"
fi

TEMP_DIR="${TMP:-${TEMP:-/tmp}}"
if mkdir -p "$TEMP_DIR" >/dev/null 2>&1 && [ -w "$TEMP_DIR" ]; then
    pass "Temporary directory is writable: $TEMP_DIR"
else
    fail "Temporary directory is not writable: $TEMP_DIR"
fi

if python_info="$(pick_python)"; then
    PY_CMD="${python_info%%|*}"
    PY_VER="${python_info#*|}"
    pass "Optional system Python is available via '$PY_CMD' ($PY_VER)"
else
    pass "No system Python detected; install-windows.sh can let uv manage Python 3.12"
fi

if check_cmd cmake; then
    pass "cmake is available"
else
    warn "cmake is missing; installer will need winget/choco or manual install"
fi

if check_cmd git; then
    pass "git is available"
else
    warn "git is missing; installer will need winget/choco or manual install"
fi

if check_cmd unzip; then
    pass "unzip is available"
else
    fail "unzip is required to extract mmm_refactored.zip"
fi

if check_cmd curl || check_cmd wget; then
    pass "A download tool is available ($(check_cmd curl && printf 'curl' || printf 'wget'))"
else
    warn "Neither curl nor wget is available; local --mmm-zip would be required"
fi

if check_cmd winget; then
    pass "winget is available for dependency installation"
elif check_cmd choco; then
    pass "choco is available for dependency installation"
else
    warn "Neither winget nor choco is available; missing deps must be installed manually"
fi

if [ -d "$REPO_DIR/.venv" ]; then
    if [ -f "$REPO_DIR/.venv/Scripts/activate" ]; then
        pass "Existing venv has Git Bash activation script: .venv/Scripts/activate"
    else
        warn "Existing .venv does not contain .venv/Scripts/activate"
    fi
    if [ -f "$REPO_DIR/.venv/Scripts/python.exe" ]; then
        pass "Existing venv has Python executable: .venv/Scripts/python.exe"
        VENV_DLL_PATH="$("$REPO_DIR/.venv/Scripts/python.exe" -c "import pathlib, sys; base = pathlib.Path(sys.base_exec_prefix); dll = next(base.glob(f'python{sys.version_info.major}{sys.version_info.minor}.dll'), None); print(dll or '')" 2>/dev/null || true)"
        if [ -n "$VENV_DLL_PATH" ] && [ -f "$VENV_DLL_PATH" ]; then
            pass "Existing venv can resolve base Python DLL: $VENV_DLL_PATH"
        else
            warn "Existing venv could not resolve a base pythonXY.dll"
        fi
    else
        warn "Existing .venv does not contain .venv/Scripts/python.exe"
    fi
fi

if smoke_test_junction; then
    pass "Junction creation via 'cmd.exe /c mklink /J' works"
else
    fail "Junction smoke test failed; REAPER integration will likely fail"
fi

if [ -n "$REAPER_DIR_OVERRIDE" ]; then
    REAPER_DIR="$(to_posix_path "$REAPER_DIR_OVERRIDE")"
    pass "Using user-specified REAPER resource dir: $REAPER_DIR"
else
    REAPER_DIR="${APPDATA:-${USERPROFILE:-}/AppData/Roaming}/REAPER"
    warn "Using default REAPER resource dir: $REAPER_DIR (portable installs should pass --reaper-dir)"
fi
if [ -d "$REAPER_DIR" ]; then
    pass "REAPER config directory exists: $REAPER_DIR"
    if [ -f "$REAPER_DIR/reaper.ini" ]; then
        pass "reaper.ini exists"
    else
        warn "REAPER config dir exists but reaper.ini is missing; launch REAPER once first"
    fi
else
    warn "REAPER config directory not found: $REAPER_DIR"
fi

echo ""
printf 'Result: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

exit 0
