# ============================================================================
# MIDI-GPT for REAPER — Windows Uninstaller (PowerShell)
# Usage: .\uninstall.ps1
#
# Removes: the Python virtual environment, the REAPER Scripts junction, and
# the downloaded Arachno soundfont.
# Leaves in place (see the "Left in place" section below for why): ReaPack,
# ReaImGui, Sforzando, and REAPER's ReaScript/Python settings.
# Asks first: whether to delete the cached model checkpoints from
# huggingface_hub's shared cache, and whether to delete this plugin folder
# itself (done last, once everything else is settled).
# ============================================================================

# NOT "Stop" -- this script's job is to remove as much as it safely can and
# report what's left, even if one step hits something unexpected; an early
# abort would leave a worse mess than a completed best-effort run. Same
# reasoning as install.ps1's own $ErrorActionPreference.
$ErrorActionPreference = "Continue"

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $RepoDir ".venv"
$SoundfontDir = Join-Path $RepoDir "soundfonts"

function Write-Info { param($msg) Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $msg }
function Write-OK   { param($msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn { param($msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }

function Write-Step {
    param($msg)
    Write-Host ""
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host "  $msg" -ForegroundColor White
    Write-Host ("-" * 52) -ForegroundColor White
}

function Test-Interactive { -not [Console]::IsInputRedirected }

Write-Host ""
Write-Host ("=" * 52) -ForegroundColor White
Write-Host "  MIDI-GPT for REAPER -- Uninstall" -ForegroundColor White
Write-Host ("=" * 52) -ForegroundColor White

# ── Locate REAPER config dir ─────────────────────────────────────
if ($env:MIDIGPT_REAPER_DIR) {
    # Test-only override (see tests/), same convention as install.ps1.
    $ReaperDir = $env:MIDIGPT_REAPER_DIR
} else {
    $ReaperDir = Join-Path $env:APPDATA "REAPER"
}

# ── Remove the REAPER Scripts junction ───────────────────────────
Write-Step "Removing REAPER Scripts integration"
$RemovedLinks = 0
if (Test-Path $ReaperDir) {
    foreach ($sub in @("Scripts\MIDI-GPT", "Effects\MIDI-GPT")) {
        # Effects\MIDI-GPT predates the dashboard-only refactor (legacy
        # JSFX support) -- install.ps1 hasn't created it in a long time,
        # this just cleans it up if it's a leftover from a much older
        # install rather than assuming everyone's already rid of it.
        $path = Join-Path $ReaperDir $sub
        $item = Get-Item -Path $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) {
            # install.ps1 creates this as an NTFS junction (mklink /J), not
            # a symlink -- Remove-Item on the junction path itself (no
            # -Recurse) removes just the link, not the target it points at.
            # cmd's rmdir is the more reliable way to drop a junction on
            # Windows; Remove-Item is the fallback, same pattern install.ps1
            # itself uses when replacing an existing junction.
            cmd /c "rmdir `"$path`"" 2>$null
            if (Test-Path $path) {
                Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path $path)) {
                Write-OK "Removed junction: $path"
                $RemovedLinks++
            } else {
                Write-Warn "Could not remove junction: $path"
            }
        } elseif (Test-Path $path) {
            Write-Warn "Found a real (non-junction) file/folder at $path -- leaving it alone (remove manually if it's ours)"
        }
    }
    if ($RemovedLinks -eq 0) {
        Write-Info "No REAPER Scripts junction found (already removed, or never installed)"
    }
} else {
    Write-Warn "REAPER config directory not found -- nothing to remove there"
}

# ── Remove the virtual environment ───────────────────────────────
Write-Step "Removing the Python virtual environment"
if (Test-Path $VenvDir) {
    Remove-Item $VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-OK "Removed $VenvDir"
} else {
    Write-Info "No virtual environment found at $VenvDir"
}

# ── Remove the downloaded soundfont ──────────────────────────────
Write-Step "Removing the downloaded soundfont"
if (Test-Path $SoundfontDir) {
    Remove-Item $SoundfontDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-OK "Removed $SoundfontDir"
} else {
    Write-Info "No soundfont folder found at $SoundfontDir"
}

# ── What's intentionally left behind, and why ────────────────────
Write-Step "Left in place (not this plugin's to remove)"
Write-Warn "ReaPack (REAPER extension) -- you may have it installed for other scripts too."
Write-Warn "ReaImGui (REAPER extension) -- likewise, other REAPER scripts may depend on it."
Write-Warn "Sforzando -- a separate application, installed outside REAPER entirely."
Write-Host "  Uninstall it the normal way for your OS if you don't want it anymore."
$ReaperIni = Join-Path $ReaperDir "reaper.ini"
if ((Test-Path $ReaperDir) -and (Test-Path $ReaperIni)) {
    Write-Warn "reaper.ini's ReaScript/Python settings were left as installed -- other"
    Write-Host "  ReaScripts likely depend on them too."
    $ReaperIniBackup = "$ReaperIni.midigpt-backup"
    if (Test-Path $ReaperIniBackup) {
        Write-Host "  A pre-install backup is still at:"
        Write-Host "    $ReaperIniBackup"
        Write-Host "  if you want to manually diff or restore it."
    }
}

# ── HuggingFace model cache ───────────────────────────────────────
# huggingface_hub's own cache -- resolved the same way it does:
# HF_HUB_CACHE if set, else HF_HOME/hub, else the default under
# %USERPROFILE%\.cache. Only the one model repo this plugin uses
# (Metacreation/MIDI-GPT, covering all of yellow/prism/expressive) is ever
# a candidate for removal -- never the whole cache, which other tools/
# projects may share.
if ($env:HF_HUB_CACHE) {
    $HfCacheDir = $env:HF_HUB_CACHE
} elseif ($env:HF_HOME) {
    $HfCacheDir = Join-Path $env:HF_HOME "hub"
} else {
    $HfCacheDir = Join-Path $env:USERPROFILE ".cache\huggingface\hub"
}
$HfModelDir = Join-Path $HfCacheDir "models--Metacreation--MIDI-GPT"

Write-Step "MIDI-GPT model checkpoints (HuggingFace cache)"
if (Test-Path $HfModelDir) {
    $HfSize = "{0:N0} MB" -f ((Get-ChildItem $HfModelDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB)
    Write-Warn "Downloaded model checkpoints are still cached at:"
    Write-Host "    $HfModelDir ($HfSize)"
    Write-Host "  This is huggingface_hub's own shared cache -- another tool or project using"
    Write-Host "  the same models would reuse it too, which is why it isn't removed automatically."
    if (Test-Interactive) {
        $DelHf = Read-Host "  Delete this cached MIDI-GPT model data? [y/N]"
        if ($DelHf -match "^[Yy]$") {
            Remove-Item $HfModelDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Removed $HfModelDir"
        } else {
            Write-Info "Left in place: $HfModelDir"
        }
    } else {
        Write-Info "Non-interactive session -- leaving it in place. Delete manually if you want it gone:"
        Write-Host "    Remove-Item -Recurse -Force `"$HfModelDir`""
    }
} else {
    Write-Info "No cached MIDI-GPT model checkpoints found at $HfModelDir"
}

# ── Delete the plugin folder itself ──────────────────────────────
Write-Step "Plugin folder"
Write-Host "  Everything above is done. All that's left is the plugin folder itself:"
Write-Host "    $RepoDir"
Write-Host ""

if (Test-Interactive) {
    $Del = Read-Host "  Delete it now? [y/N]"
    if (-not $Del) { $Del = "n" }
} else {
    $Del = "n"
}

if ($Del -match "^[Yy]$") {
    Write-Host ""
    Write-Warn "This will permanently delete: $RepoDir"
    $Confirm = Read-Host "  Type 'yes' to confirm"
    if ($Confirm -eq "yes") {
        Write-OK "Deleting $RepoDir ..."
        # Leave the directory before removing it out from under the
        # running shell -- and nothing below this line may depend on
        # anything inside $RepoDir (including this script itself).
        Set-Location $env:USERPROFILE -ErrorAction SilentlyContinue
        Remove-Item $RepoDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "Uninstall complete. " -ForegroundColor Green -NoNewline
        Write-Host "The plugin folder is gone."
        exit 0
    } else {
        Write-Info "Skipped -- folder not deleted."
    }
} else {
    Write-Info "Folder kept at $RepoDir."
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
if ($RemovedLinks -gt 0) {
    Write-Host "  REAPER Scripts have been removed. Restart REAPER to clear any cached references."
}
Write-Host ""
