#!/usr/bin/env bash
# Uninstall MIDI-GPT for REAPER
# Usage: ./uninstall.sh
#
# Removes: the Python virtual environment, the REAPER Scripts symlink, and
# the downloaded Arachno soundfont.
# Leaves in place (see the "Left in place" section below for why): ReaPack,
# ReaImGui, Sforzando, and REAPER's ReaScript/Python settings.
# Asks first: whether to delete the cached model checkpoints from
# huggingface_hub's shared cache, and whether to delete this plugin folder
# itself (done last, once everything else is settled).

# Not `-e`: this script's job is to remove as much as it safely can and
# report what's left, even if one step hits something unexpected -- an
# early abort would leave a worse mess than a completed best-effort run.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$REPO_DIR/.venv"
SOUNDFONT_DIR="$REPO_DIR/soundfonts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

step() {
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
}

echo -e "${BOLD}"
echo "  +--------------------------------------+"
echo "  |  MIDI-GPT for REAPER  -- Uninstall  |"
echo "  +--------------------------------------+"
echo -e "${NC}"

# ── Locate REAPER config dir ─────────────────────────────────────
if [ -n "${MIDIGPT_REAPER_DIR:-}" ]; then
    # Test-only override (see tests/integration/), same convention as
    # install.sh.
    REAPER_DIR="$MIDIGPT_REAPER_DIR"
else
    OS="$(uname -s)"
    case "$OS" in
        Darwin)       REAPER_DIR="$HOME/Library/Application Support/REAPER" ;;
        Linux)        REAPER_DIR="$HOME/.config/REAPER" ;;
        MINGW*|MSYS*) REAPER_DIR="$APPDATA/REAPER" ;;
        *)            REAPER_DIR="" ;;
    esac
fi

# ── Remove the REAPER Scripts symlink ────────────────────────────
step "Removing REAPER Scripts integration"
REMOVED_LINKS=0
if [ -n "$REAPER_DIR" ] && [ -d "$REAPER_DIR" ]; then
    for path in \
        "$REAPER_DIR/Scripts/MIDI-GPT" \
        "$REAPER_DIR/Effects/MIDI-GPT"
    do
        # Effects/MIDI-GPT predates the dashboard-only refactor (legacy
        # JSFX support) -- install.sh hasn't created it in a long time,
        # this just cleans it up if it's a leftover from a much older
        # install rather than assuming everyone's already rid of it.
        if [ -L "$path" ]; then
            rm "$path"
            ok "Removed symlink: $path"
            REMOVED_LINKS=$((REMOVED_LINKS + 1))
        elif [ -e "$path" ]; then
            warn "Found a real (non-symlink) file/folder at $path -- leaving it alone (remove manually if it's ours)"
        fi
    done
    if [ "$REMOVED_LINKS" -eq 0 ]; then
        info "No REAPER Scripts symlink found (already removed, or never installed)"
    fi
else
    warn "REAPER config directory not found -- nothing to remove there"
fi

# ── Remove the virtual environment ───────────────────────────────
step "Removing the Python virtual environment"
if [ -d "$VENV_DIR" ]; then
    rm -rf "$VENV_DIR"
    ok "Removed $VENV_DIR"
else
    info "No virtual environment found at $VENV_DIR"
fi

# ── Remove the downloaded soundfont ──────────────────────────────
step "Removing the downloaded soundfont"
if [ -d "$SOUNDFONT_DIR" ]; then
    rm -rf "$SOUNDFONT_DIR"
    ok "Removed $SOUNDFONT_DIR"
else
    info "No soundfont folder found at $SOUNDFONT_DIR"
fi

# ── What's intentionally left behind, and why ────────────────────
step "Left in place (not this plugin's to remove)"
warn "ReaPack (REAPER extension) -- you may have it installed for other scripts too."
warn "ReaImGui (REAPER extension) -- likewise, other REAPER scripts may depend on it."
warn "Sforzando -- a separate application, installed outside REAPER entirely."
if [ "$(uname -s)" = "Linux" ]; then
    echo "  If you don't want it anymore, remove Plogue's packages (plogue-aria is"
    echo "  the engine every Plogue instrument shares -- removing it also removes"
    echo "  any other Plogue instrument you have):"
    echo "    sudo apt remove plogue-sforzando plogue-tablewarp2 plogue-aria"
else
    echo "  Uninstall it the normal way for your OS if you don't want it anymore."
fi
if [ -n "$REAPER_DIR" ] && [ -f "$REAPER_DIR/reaper.ini" ]; then
    warn "reaper.ini's ReaScript/Python settings were left as installed -- other"
    echo "  ReaScripts likely depend on them too."
    if [ "$(uname -s)" = "Linux" ]; then
        echo "  Likewise /usr/lib/vst3 in its VST plug-in paths (Plogue's and other"
        echo "  system-wide VST3 plugins install there)."
    fi
    if [ -f "$REAPER_DIR/reaper.ini.midigpt-backup" ]; then
        echo "  A pre-install backup is still at:"
        echo "    $REAPER_DIR/reaper.ini.midigpt-backup"
        echo "  if you want to manually diff or restore it."
    fi
fi

# ── HuggingFace model cache ───────────────────────────────────────
# huggingface_hub's own cache (see REAPER_midigpt's start_midigpt_server.sh
# / the midigpt package) -- resolved the same way it does: HF_HUB_CACHE if
# set, else HF_HOME/hub, else the ~/.cache default. Only the one model
# repo this plugin uses (Metacreation/MIDI-GPT, covering all of
# yellow/prism/expressive) is ever a candidate for removal -- never the
# whole cache, which other tools/projects may share.
if [ -n "${HF_HUB_CACHE:-}" ]; then
    HF_CACHE_DIR="$HF_HUB_CACHE"
elif [ -n "${HF_HOME:-}" ]; then
    HF_CACHE_DIR="$HF_HOME/hub"
else
    HF_CACHE_DIR="$HOME/.cache/huggingface/hub"
fi
HF_MODEL_DIR="$HF_CACHE_DIR/models--Metacreation--MIDI-GPT"

step "MIDI-GPT model checkpoints (HuggingFace cache)"
if [ -d "$HF_MODEL_DIR" ]; then
    HF_SIZE="$(du -sh "$HF_MODEL_DIR" 2>/dev/null | cut -f1)"
    warn "Downloaded model checkpoints are still cached at:"
    echo "    $HF_MODEL_DIR${HF_SIZE:+ ($HF_SIZE)}"
    echo "  This is huggingface_hub's own shared cache -- another tool or project using"
    echo "  the same models would reuse it too, which is why it isn't removed automatically."
    if [ -t 0 ]; then
        read -rp "  Delete this cached MIDI-GPT model data? [y/N]: " _DEL_HF
        if [[ "$_DEL_HF" =~ ^[Yy]$ ]]; then
            rm -rf "$HF_MODEL_DIR"
            ok "Removed $HF_MODEL_DIR"
        else
            info "Left in place: $HF_MODEL_DIR"
        fi
    else
        info "Non-interactive session -- leaving it in place. Delete manually if you want it gone:"
        echo "    rm -rf \"$HF_MODEL_DIR\""
    fi
else
    info "No cached MIDI-GPT model checkpoints found at $HF_MODEL_DIR"
fi

# ── Delete the plugin folder itself ──────────────────────────────
step "Plugin folder"
echo "  Everything above is done. All that's left is the plugin folder itself:"
echo "    $REPO_DIR"
echo ""

if [ -t 0 ]; then
    read -rp "  Delete it now? [y/N]: " _DEL
    _DEL="${_DEL:-n}"
else
    _DEL="n"
fi

if [[ "$_DEL" =~ ^[Yy]$ ]]; then
    echo ""
    warn "This will permanently delete: $REPO_DIR"
    read -rp "  Type 'yes' to confirm: " _CONFIRM
    if [ "$_CONFIRM" = "yes" ]; then
        ok "Deleting $REPO_DIR ..."
        # Leave the directory before removing it out from under the
        # running shell -- and nothing below this line may depend on
        # anything inside $REPO_DIR (including this script itself).
        cd "$HOME" 2>/dev/null || cd /
        rm -rf "$REPO_DIR"
        echo -e "${GREEN}${BOLD}Uninstall complete.${NC} The plugin folder is gone."
        exit 0
    else
        info "Skipped -- folder not deleted."
    fi
else
    info "Folder kept at $REPO_DIR."
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
if [ "$REMOVED_LINKS" -gt 0 ]; then
    echo "  REAPER Scripts have been removed. Restart REAPER to clear any cached references."
fi
echo ""
