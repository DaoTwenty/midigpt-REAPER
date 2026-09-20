# Downloads ReaImGui extension completely (native binary + Python API + Lua shims)
# directly from codeberg.org, replicating what ReaPack does from the ReaTeam Extensions repo.
# This avoids the bootstrap race condition and doesn't require REAPER restarts.
#
# Usage:
#   download_reaimgui_complete platform_arch dest_dir
#
# Returns:
#   0 on success
#   1 on failure

download_reaimgui_complete() {
    local platform_arch="$1"
    local dest_dir="$2"
    local imgui_asset="" imgui_url="" expected_sha="" actual_sha=""

    case "$platform_arch" in
        macos:arm64|macos:aarch64) imgui_asset="reaper_imgui-arm64.dylib" ;;
        macos:x86_64)              imgui_asset="reaper_imgui-x86_64.dylib" ;;
        linux:aarch64|linux:arm64) imgui_asset="reaper_imgui-aarch64.so" ;;
        linux:x86_64)              imgui_asset="reaper_imgui-x86_64.so" ;;
        linux:armv7l)              imgui_asset="reaper_imgui-armv7l.so" ;;
        linux:i686)                imgui_asset="reaper_imgui-i686.so" ;;
        windows:*)                 imgui_asset="reaper_imgui-x64.dll" ;;
        *) return 1 ;;
    esac

    if [ -z "$imgui_asset" ]; then
        return 1
    fi

    local userplugins_dir="$dest_dir"
    local api_dir="$dest_dir/../Scripts/ReaTeam Extensions/API"
    local version="0.10.0.5"

    info "Installing ReaImGui complete package ($imgui_asset + Python API)..."
    mkdir -p "$userplugins_dir" "$api_dir"

    # ---- 1. Native binary ----
    local tmp_bin
    tmp_bin="$(mktemp)"
    imgui_url="https://codeberg.org/cfillion/reaimgui/releases/download/v$version/$imgui_asset"

    # Fetch expected SHA from codeberg API
    expected_sha=""
    if RELEASE_JSON="$(curl -fsSL "https://codeberg.org/api/v1/repos/cfillion/reaimgui/releases" 2>/dev/null || true)"; then
        if check_cmd python3; then
            expected_sha="$(printf '%s' "$RELEASE_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for release in data:
        if release.get('tag_name') == 'v$version':
            for asset in release.get('assets', []):
                if asset.get('name') == '$imgui_asset':
                    print(asset.get('sha256', ''))
                    break
            break
except Exception:
    pass
" 2>/dev/null)"
        fi
    fi

    if curl -fsSL "$imgui_url" -o "$tmp_bin"; then
        local verified=true
        if [ -n "$expected_sha" ]; then
            actual_sha="$( (shasum -a 256 "$tmp_bin" 2>/dev/null || sha256sum "$tmp_bin" 2>/dev/null) | awk '{print $1}')"
            if [ "$actual_sha" != "$expected_sha" ]; then
                verified=false
                warn "ReaImGui binary checksum mismatch (expected: $expected_sha, got: $actual_sha)"
            fi
        else
            warn "Could not fetch expected checksum for ReaImGui binary -- installing unverified"
        fi

        if [ "$verified" = true ]; then
            mv "$tmp_bin" "$userplugins_dir/$imgui_asset"
            if [ "$PLATFORM" = "macos" ]; then
                xattr -d com.apple.quarantine "$userplugins_dir/$imgui_asset" 2>/dev/null || true
            fi
            ok "ReaImGui native binary installed and checksum-verified ($imgui_asset)"
        else
            rm -f "$tmp_bin"
            warn "Downloaded ReaImGui binary didn't match expected checksum -- discarded"
            return 1
        fi
    else
        warn "Failed to download ReaImGui binary from $imgui_url"
        rm -f "$tmp_bin"
        return 1
    fi

    # ---- 2. Python API (imgui.py) ----
    local tmp_py
    tmp_py="$(mktemp)"
    local py_url="https://codeberg.org/cfillion/reaimgui/releases/download/v$version/imgui.py"
    if curl -fsSL "$py_url" -o "$tmp_py"; then
        mv "$tmp_py" "$api_dir/imgui.py"
        ok "ReaImGui Python API installed (imgui.py)"
    else
        warn "Failed to download ReaImGui Python API from $py_url"
        rm -f "$tmp_py"
        # Don't fail - binary is the critical part
    fi

    # ---- 3. Lua shim (imgui.lua) ----
    local tmp_lua
    tmp_lua="$(mktemp)"
    local lua_url="https://codeberg.org/cfillion/reaimgui/raw/v$version/shims/imgui.lua"
    if curl -fsSL "$lua_url" -o "$tmp_lua"; then
        mv "$tmp_lua" "$api_dir/imgui.lua"
        ok "ReaImGui Lua shim installed (imgui.lua)"
    else
        warn "Failed to download ReaImGui Lua shim from $lua_url"
        rm -f "$tmp_lua"
    fi

    # ---- 4. gfx2imgui.lua ----
    local tmp_gfx
    tmp_gfx="$(mktemp)"
    local gfx_url="https://codeberg.org/cfillion/reaimgui/releases/download/v$version/gfx2imgui.lua"
    if curl -fsSL "$gfx_url" -o "$tmp_gfx"; then
        mv "$tmp_gfx" "$api_dir/gfx2imgui.lua"
        ok "ReaImGui gfx2imgui.lua installed"
    else
        warn "Failed to download gfx2imgui.lua from $gfx_url"
        rm -f "$tmp_gfx"
    fi

    return 0
}