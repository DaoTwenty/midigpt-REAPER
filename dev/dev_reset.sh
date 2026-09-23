#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER -- Dev Reset (NOT for end users)
#
# Wipes everything install.sh sets up (and a few things it only points at),
# so you can re-run the installer and test the whole flow from scratch:
#   - This plugin's REAPER symlink
#   - ReaImGui, and the other ReaTeam Extensions packages (ReaBlink, ReaMCULive,
#     js_ReaScriptAPI) -- see install.sh's ReaPack/ReaImGui step
#   - ReaPack itself (extension + its registry/cache)
#   - The Arachno SoundFont this installer downloads
#   - Its converted .sfz presets: Setup Tracks' own (soundfonts/sfz) and
#     Aria's from a manual import (soundfonts/ARIAConverted, plus Aria's
#     pointer to that folder)
#   - Sforzando's plugin files, best-effort (it's a real app you install by
#     hand -- this only removes plugin bundles it can find, not any
#     system installer receipt)
#   - The ReaScript/Python config this installer writes to reaper.ini
#   - The Python virtual environment (.venv)
#   - The Desktop server-launcher shortcut
#
# This is scoped to what MIDI-GPT's installer actually touches, but ReaPack
# and ReaImGui are REAL REAPER extensions -- removing them (and the sibling
# packages bundled in the same repo) affects anything else in REAPER that
# depends on them too, not just this plugin. Asks before each category so
# you can skip whatever you want to keep.
#
# Usage:
#   ./dev_reset.sh          # asks before each category
#   ./dev_reset.sh --yes    # skips the per-category prompts (still shows
#                            # the upfront warning once)
# ============================================================================

set -uo pipefail  # no -e: one failed category shouldn't stop the rest

# This script lives in dev/ -- REPO_DIR resolves to the repo root (one
# level up), which is what every path below actually means by it.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=true ;;
        --help|-h)
            echo "Usage: ./dev_reset.sh [--yes]"
            echo "  --yes   Don't ask before each category (still shows the upfront warning)"
            exit 0
            ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { echo ""; echo -e "${BOLD}-- $* --${NC}"; }

confirm() {
    # confirm "question" -- returns 0 (yes) if ASSUME_YES, or the user answers y
    $ASSUME_YES && return 0
    local reply
    read -rp "  $1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

OS="$(uname -s)"
case "$OS" in
    Darwin)       PLATFORM="macos";   REAPER_DIR="$HOME/Library/Application Support/REAPER" ;;
    Linux)        PLATFORM="linux";   REAPER_DIR="$HOME/.config/REAPER" ;;
    MINGW*|MSYS*) PLATFORM="windows"; REAPER_DIR="${APPDATA:-}/REAPER" ;;
    *)            echo "Unsupported OS: $OS"; exit 1 ;;
esac

reaper_is_running() {
    pgrep -x "REAPER" >/dev/null 2>&1 || pgrep -x "reaper" >/dev/null 2>&1
}

echo -e "${BOLD}"
echo "  +--------------------------------------------+"
echo "  |  MIDI-GPT for REAPER -- Dev Reset           |"
echo "  +--------------------------------------------+"
echo -e "${NC}"
warn "This removes real REAPER extensions (ReaPack, ReaImGui) and plugin"
warn "files (Sforzando), not just this repo's own bits. Asks before each"
warn "category unless run with --yes."
echo "  REAPER config dir: $REAPER_DIR"
echo ""
if ! confirm "Continue?"; then
    info "Aborted -- nothing changed."
    exit 0
fi

# ============================================================================
# Close REAPER if running -- needed to safely touch UserPlugins/reaper.ini
# ============================================================================

REAPER_CLOSED=false
if reaper_is_running; then
    step "REAPER is running"
    warn "Removing extensions and editing reaper.ini both require REAPER closed."
    warn "Any unsaved project will prompt you to save first, same as quitting normally."
    if confirm "Close REAPER now?"; then
        if [ "$PLATFORM" = "macos" ]; then
            osascript -e 'tell application "REAPER" to quit' 2>/dev/null
        else
            pkill -TERM -x reaper 2>/dev/null
        fi
        waited=0
        while reaper_is_running && [ "$waited" -lt 120 ]; do
            sleep 2
            waited=$((waited + 2))
        done
        if reaper_is_running; then
            warn "REAPER is still open (maybe waiting on a save prompt)."
            read -rp "  Close it manually, then press Enter to continue (Ctrl+C to abort): " _
        fi
        REAPER_CLOSED=true
    else
        warn "Continuing with REAPER open -- steps that need it closed will be skipped."
    fi
fi

# ============================================================================
# This plugin's own REAPER integration
# ============================================================================

step "MIDI-GPT plugin integration"

if [ -L "$REAPER_DIR/Scripts/MIDI-GPT" ]; then
    if confirm "Remove the MIDI-GPT Scripts symlink?"; then
        rm -f "$REAPER_DIR/Scripts/MIDI-GPT"
        ok "Removed $REAPER_DIR/Scripts/MIDI-GPT"
    fi
else
    info "No MIDI-GPT Scripts symlink found"
fi

# ============================================================================
# ReaImGui + siblings (ReaBlink / ReaMCULive / js_ReaScriptAPI from ReaTeam Extensions)
# ============================================================================

step "ReaImGui (and ReaBlink / ReaMCULive / js_ReaScriptAPI from the same repo)"

if find "$REAPER_DIR/UserPlugins" -iname "*imgui*" 2>/dev/null | grep -q . || \
   [ -d "$REAPER_DIR/Scripts/ReaTeam Extensions" ]; then
    if confirm "Remove ReaImGui and the whole 'ReaTeam Extensions' package folder?"; then
        find "$REAPER_DIR/UserPlugins" -iname "*imgui*" -exec rm -f {} \; 2>/dev/null
        rm -rf "$REAPER_DIR/Scripts/ReaTeam Extensions"
        ok "Removed ReaImGui and ReaTeam Extensions packages"
    fi
else
    info "ReaImGui / ReaTeam Extensions not found"
fi

# ============================================================================
# ReaPack itself
# ============================================================================

step "ReaPack"

if find "$REAPER_DIR/UserPlugins" -iname "reaper_reapack*" 2>/dev/null | grep -q . || \
   [ -d "$REAPER_DIR/ReaPack" ] || [ -f "$REAPER_DIR/reapack.ini" ]; then
    if confirm "Remove ReaPack (extension + its registry/cache of ALL installed packages)?"; then
        find "$REAPER_DIR/UserPlugins" -iname "reaper_reapack*" -exec rm -f {} \; 2>/dev/null
        rm -rf "$REAPER_DIR/ReaPack"
        rm -f "$REAPER_DIR/reapack.ini"
        ok "Removed ReaPack"
    fi
else
    info "ReaPack not found"
fi

# ============================================================================
# Arachno SoundFont (downloaded by install.sh)
# ============================================================================

step "Arachno SoundFont"

ARACHNO_DIR="$REPO_DIR/soundfonts"
if find "$ARACHNO_DIR" -iname "*.sf2" 2>/dev/null | grep -q .; then
    if confirm "Remove the SoundFont(s) in $ARACHNO_DIR?"; then
        rm -f "$ARACHNO_DIR"/*.sf2
        rmdir "$ARACHNO_DIR" 2>/dev/null || true
        ok "Removed Arachno SoundFont"
    fi
else
    info "No SoundFont found in $ARACHNO_DIR"
fi

# ============================================================================
# Aria's converted SoundFont cache
# ============================================================================
# The first time a .sf2 is imported into Sforzando, its Aria engine converts
# it (Plogue's RIFF2sfz) into .sfz presets in an ARIAConverted/ folder next
# to the .sf2, and remembers that folder as its "Converted_path" -- loaded as
# Aria bank 4000, which is what Setup Tracks' generated instruments refer
# to. Remove both to get back to a machine where Arachno was never imported.
# Converted_path is Aria-global, so it's only cleared when it points at
# *this* repo's folder, never at some other SoundFont the user imported.

step "Converted SoundFont presets (soundfonts/sfz, ARIAConverted)"

# soundfonts/sfz is Setup Tracks' own one-time conversion (see
# ensure_arachno_sfz in MIDI-GPT Setup Tracks.py); ARIAConverted is Aria's,
# from a manual import into Sforzando.
SFZ_DIR="$ARACHNO_DIR/sfz"
if [ -d "$SFZ_DIR" ]; then
    if confirm "Remove $SFZ_DIR (Setup Tracks' converted presets)?"; then
        rm -rf "$SFZ_DIR"
        rmdir "$ARACHNO_DIR" 2>/dev/null || true
        ok "Removed $SFZ_DIR"
    fi
else
    info "No soundfonts/sfz folder found"
fi

ARIA_CONVERTED="$ARACHNO_DIR/ARIAConverted"
if [ -d "$ARIA_CONVERTED" ]; then
    if confirm "Remove $ARIA_CONVERTED?"; then
        rm -rf "$ARIA_CONVERTED"
        rmdir "$ARACHNO_DIR" 2>/dev/null || true
        ok "Removed $ARIA_CONVERTED"
    fi
else
    info "No ARIAConverted folder found"
fi

# Aria stores Converted_path in the registry on Windows. On macOS the key
# name is the same, but which preferences domain holds it isn't confirmed,
# so every Plogue domain is checked for it.
if [ "$PLATFORM" = "windows" ]; then
    ARIA_KEY='HKCU\Software\Plogue Art et Technologie, Inc\Aria'
    ARIA_PATH="$(reg query "$ARIA_KEY" //v Converted_path 2>/dev/null | sed -n 's/.*REG_SZ[[:space:]]*//p')"
    if [ -n "$ARIA_PATH" ]; then
        if [[ "$(cygpath -u "$ARIA_PATH" 2>/dev/null)" == "$ARIA_CONVERTED"* ]]; then
            if confirm "Clear Aria's Converted_path ($ARIA_PATH)?"; then
                reg delete "$ARIA_KEY" //v Converted_path //f >/dev/null && ok "Cleared Aria's Converted_path"
            fi
        else
            info "Aria's Converted_path points elsewhere ($ARIA_PATH) -- left alone"
        fi
    fi
elif [ "$PLATFORM" = "macos" ]; then
    for plist in "$HOME"/Library/Preferences/*[Pp]logue*.plist; do
        [ -f "$plist" ] || continue
        domain="$(basename "$plist" .plist)"
        ARIA_PATH="$(defaults read "$domain" Converted_path 2>/dev/null || true)"
        [ -n "$ARIA_PATH" ] || continue
        if [[ "$ARIA_PATH" == "$ARIA_CONVERTED"* ]]; then
            if confirm "Clear Aria's Converted_path in $domain ($ARIA_PATH)?"; then
                defaults delete "$domain" Converted_path && ok "Cleared Converted_path in $domain"
            fi
        else
            info "Converted_path in $domain points elsewhere ($ARIA_PATH) -- left alone"
        fi
    done
fi

# ============================================================================
# Sforzando (best-effort -- a real app installed outside this plugin)
# ============================================================================

step "Sforzando plugin files"

SFZ_PATHS=()
if [ "$PLATFORM" = "macos" ]; then
    SFZ_PATHS=(
        "/Library/Audio/Plug-Ins/VST/sforzando.vst"
        "/Library/Audio/Plug-Ins/VST3/sforzando.vst3"
        "/Library/Audio/Plug-Ins/Components/sforzando.component"
        "/Library/Audio/Plug-Ins/CLAP/Plogue/sforzando.clap"
        "$HOME/Library/Audio/Plug-Ins/VST/sforzando.vst"
        "$HOME/Library/Audio/Plug-Ins/VST3/sforzando.vst3"
        "$HOME/Library/Audio/Plug-Ins/Components/sforzando.component"
        "$HOME/Library/Audio/Plug-Ins/CLAP/Plogue/sforzando.clap"
    )
elif [ "$PLATFORM" = "windows" ]; then
    SFZ_PATHS=(
        "${PROGRAMFILES:-/c/Program Files}/Common Files/VST3/sforzando.vst3"
        "${PROGRAMFILES:-/c/Program Files}/VSTPlugins/sforzando.dll"
        "${PROGRAMFILES:-/c/Program Files}/Steinberg/VstPlugins/sforzando.dll"
    )
elif [ "$PLATFORM" = "linux" ]; then
    # Plogue's Linux beta (install_sforzando.sh) apt-installs its .debs on
    # Debian-based distros, or copies their contents to these same places
    # elsewhere. /opt/Plogue/Aria is the engine every Plogue instrument
    # shares, so it's only removed through apt, when nothing else needs it.
    SFZ_PATHS=(
        "/usr/lib/vst3/sforzando.vst3"
        "/usr/lib/clap/sforzando.clap"
        "/opt/Plogue/sforzando"
        "$HOME/.vst3/sforzando.vst3"
        "$HOME/.clap/sforzando.clap"
        "$HOME/.config/Plogue/sforzando"
    )
    deb_installed() {
        command -v dpkg-query >/dev/null 2>&1 &&
            dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
    }
    if deb_installed plogue-sforzando; then
        SFZ_PKGS=(plogue-sforzando)
        deb_installed plogue-tablewarp2 && SFZ_PKGS+=(plogue-tablewarp2)
        OTHER_PLOGUE="$(dpkg-query -W -f='${Package} ${Status}\n' 'plogue-*' 2>/dev/null |
            awk '/install ok installed/ && $1 !~ /^plogue-(aria|sforzando|tablewarp2)$/ { print $1 }')"
        if deb_installed plogue-aria; then
            if [ -z "$OTHER_PLOGUE" ]; then
                SFZ_PKGS+=(plogue-aria)
            else
                info "Keeping plogue-aria -- still needed by: $(echo $OTHER_PLOGUE)"
            fi
        fi
        if confirm "Remove Sforzando's packages (${SFZ_PKGS[*]}) with sudo apt remove?"; then
            if sudo apt-get remove -y "${SFZ_PKGS[@]}"; then
                ok "Removed ${SFZ_PKGS[*]}"
                # Aria's per-user logs and plugin caches go with the engine.
                [[ " ${SFZ_PKGS[*]} " == *" plogue-aria "* ]] && SFZ_PATHS+=("$HOME/.config/Plogue/Aria")
            else
                warn "apt remove failed -- remove manually: sudo apt remove ${SFZ_PKGS[*]}"
            fi
        fi
    fi
fi

FOUND_SFZ=()
for p in "${SFZ_PATHS[@]:-}"; do
    [ -e "$p" ] && FOUND_SFZ+=("$p")
done

if [ ${#FOUND_SFZ[@]} -eq 0 ]; then
    info "No Sforzando plugin files found in standard locations"
else
    echo "  Found:"
    printf '    %s\n' "${FOUND_SFZ[@]}"
    if confirm "Remove these Sforzando plugin files?"; then
        FAILED_SFZ=()
        for p in "${FOUND_SFZ[@]}"; do
            if rm -rf "$p" 2>/dev/null; then
                ok "Removed $p"
            else
                FAILED_SFZ+=("$p")
            fi
        done
        if [ ${#FAILED_SFZ[@]} -gt 0 ]; then
            warn "These need admin rights -- you may be asked for your password or Touch ID:"
            printf '    %s\n' "${FAILED_SFZ[@]}"
            if sudo rm -rf "${FAILED_SFZ[@]}"; then
                ok "Removed with admin rights"
            else
                warn "Still couldn't remove them -- remove manually: sudo rm -rf <path>"
            fi
        fi
    fi
fi

# ============================================================================
# ReaScript/Python config in reaper.ini
# ============================================================================

step "reaper.ini ReaScript/Python config"

REAPER_INI="$REAPER_DIR/reaper.ini"
# On Linux install.sh also appends /usr/lib/vst3 (Sforzando's VST3 folder)
# to vstpath; strip just that entry, leaving any paths the user added.
if [ -f "$REAPER_INI" ] && { grep -qE '^(reascript|pythonlibpath64|pythonlibdll64)=' "$REAPER_INI" ||
        { [ "$PLATFORM" = "linux" ] && grep -qE '^vstpath=(.*;)?/usr/lib/vst3(;|$)' "$REAPER_INI"; }; } 2>/dev/null; then
    if reaper_is_running; then
        warn "REAPER is still open -- skipping reaper.ini (it would just get overwritten on quit)"
    elif confirm "Remove reascript=1 / pythonlibpath64 / pythonlibdll64$([ "$PLATFORM" = "linux" ] && echo " and vstpath's /usr/lib/vst3") from reaper.ini?"; then
        cp "$REAPER_INI" "${REAPER_INI}.dev-reset-backup"
        awk -v linux="$([ "$PLATFORM" = "linux" ] && echo 1)" '
            /^reascript=/ { next }
            /^pythonlibpath64=/ { next }
            /^pythonlibdll64=/ { next }
            linux && /^vstpath=/ {
                n = split(substr($0, 9), parts, ";"); out = ""
                for (i = 1; i <= n; i++)
                    if (parts[i] != "/usr/lib/vst3") out = out (out == "" ? "" : ";") parts[i]
                print "vstpath=" out; next
            }
            { print }
        ' "$REAPER_INI" > "${REAPER_INI}.tmp" && mv "${REAPER_INI}.tmp" "$REAPER_INI"
        ok "Removed ReaScript/Python config (backup: ${REAPER_INI}.dev-reset-backup)"
    fi
else
    info "No ReaScript/Python config found in reaper.ini"
fi

# ============================================================================
# Python virtual environment
# ============================================================================

step "Python virtual environment"

if [ -d "$REPO_DIR/.venv" ]; then
    if confirm "Remove $REPO_DIR/.venv?"; then
        rm -rf "$REPO_DIR/.venv"
        ok "Removed .venv"
    fi
else
    info "No .venv found"
fi

# ============================================================================
# Desktop shortcut
# ============================================================================

step "Desktop shortcut"

for shortcut in \
    "$HOME/Desktop/Start MIDI-GPT Server.command" \
    "$HOME/Desktop/Start MIDI-GPT Server.desktop"
do
    if [ -f "$shortcut" ]; then
        if confirm "Remove '$shortcut'?"; then
            if rm -f "$shortcut" 2>/dev/null; then
                ok "Removed $shortcut"
            else
                warn "Couldn't remove $shortcut (permission denied -- on macOS this can mean the process running this script needs Full Disk Access for ~/Desktop) -- remove it manually"
            fi
        fi
    fi
done

# ============================================================================
# Done
# ============================================================================

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Dev reset complete.${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "  Re-run ./install.sh to test the full install flow from scratch."
echo ""
