# ============================================================================
# MIDI-GPT for REAPER -- Dev Reset, Windows (NOT for end users)
#
# PowerShell counterpart to dev_reset.sh. Wipes everything install.ps1 sets
# up (and a few things it only points at), so you can re-run the installer
# and test the whole flow from scratch:
#   - This plugin's REAPER Scripts junction
#   - ReaImGui, and the other ReaTeam Extensions packages (ReaBlink,
#     ReaMCULive, js_ReaScriptAPI) -- see install.ps1's ReaImGui step
#   - ReaPack itself (extension + its registry/cache)
#   - The Arachno SoundFont the installer downloads
#   - Its converted .sfz presets: Setup Tracks' own (soundfonts\sfz) and
#     Aria's from a manual import (soundfonts\ARIAConverted, plus Aria's
#     pointer to that folder)
#   - Sforzando's plugin files, best-effort (it's a real app you install by
#     hand -- this only removes plugin files it can find, not its installer
#     registration)
#   - The ReaScript/Python config the installer writes to reaper.ini
#   - The Python virtual environment (.venv)
#   - The Desktop server-launcher shortcut
#
# Deliberately NOT removed: Python, git, and the Microsoft Visual C++
# Runtime -- machine-wide components other software relies on. Test the
# install's handling of those on a clean VM instead (see README.md).
#
# This is scoped to what MIDI-GPT's installer actually touches, but ReaPack
# and ReaImGui are REAL REAPER extensions -- removing them (and the sibling
# packages bundled in the same repo) affects anything else in REAPER that
# depends on them too, not just this plugin. Asks before each category so
# you can skip whatever you want to keep.
#
# Usage:
#   .\dev\dev_reset.ps1          # asks before each category
#   .\dev\dev_reset.ps1 -Yes     # skips the per-category prompts (still
#                                # shows the upfront warning once)
# ============================================================================

param(
    [switch]$Yes,
    [switch]$Help
)

# Same reasoning as install.ps1's $ErrorActionPreference: "Stop" would turn
# harmless stderr from native commands into terminating errors. One failed
# category shouldn't stop the rest either.
$ErrorActionPreference = "Continue"

if ($Help) {
    Write-Host "Usage: .\dev\dev_reset.ps1 [-Yes]"
    Write-Host "  -Yes   Don't ask before each category (still shows the upfront warning)"
    exit 0
}

# This script lives in dev\ -- $RepoDir is the repo root (one level up).
$RepoDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReaperDir = Join-Path $env:APPDATA "REAPER"

function Write-Info { param($msg) Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $msg }
function Write-OK   { param($msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn { param($msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Step { param($msg) Write-Host ""; Write-Host "-- $msg --" -ForegroundColor White }

# Returns $true if -Yes was given or the user answers y.
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { return $true }
    $Reply = Read-Host "  $Question [y/N]"
    return $Reply -match "^[Yy]$"
}

function Test-ReaperRunning { return $null -ne (Get-Process -Name "reaper" -ErrorAction SilentlyContinue) }

Write-Host ""
Write-Host "  +--------------------------------------------+" -ForegroundColor White
Write-Host "  |  MIDI-GPT for REAPER -- Dev Reset (Windows) |" -ForegroundColor White
Write-Host "  +--------------------------------------------+" -ForegroundColor White
Write-Host ""
Write-Warn "This removes real REAPER extensions (ReaPack, ReaImGui) and plugin"
Write-Warn "files (Sforzando), not just this repo's own bits. Asks before each"
Write-Warn "category unless run with -Yes."
Write-Host "  REAPER config dir: $ReaperDir"
Write-Host ""
if (-not (Confirm-Step "Continue?")) {
    Write-Info "Aborted -- nothing changed."
    exit 0
}

# ============================================================================
# Close REAPER if running -- needed to safely touch UserPlugins/reaper.ini
# ============================================================================

if (Test-ReaperRunning) {
    Write-Step "REAPER is running"
    Write-Warn "Removing extensions and editing reaper.ini both require REAPER closed."
    Write-Warn "Any unsaved project will prompt you to save first, same as quitting normally."
    if (Confirm-Step "Close REAPER now?") {
        # taskkill without /F asks REAPER to quit normally (save prompts still fire).
        & taskkill.exe /IM reaper.exe | Out-Null
        $Waited = 0
        while ((Test-ReaperRunning) -and ($Waited -lt 120)) {
            Start-Sleep -Seconds 2
            $Waited += 2
        }
        if (Test-ReaperRunning) {
            Write-Warn "REAPER is still open (maybe waiting on a save prompt)."
            Read-Host "  Close it manually, then press Enter to continue (Ctrl+C to abort)" | Out-Null
        }
    } else {
        Write-Warn "Continuing with REAPER open -- steps that need it closed will be skipped."
    }
}

# ============================================================================
# This plugin's own REAPER integration
# ============================================================================

Write-Step "MIDI-GPT plugin integration"

$ScriptsLink = Join-Path $ReaperDir "Scripts\MIDI-GPT"
$LinkItem = Get-Item $ScriptsLink -Force -ErrorAction SilentlyContinue
if ($LinkItem -and ($LinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    if (Confirm-Step "Remove the MIDI-GPT Scripts junction?") {
        # rmdir on a junction removes only the link. Remove-Item -Recurse on a
        # junction can delete the target's contents -- here, the repo's own
        # src\Scripts\MIDI-GPT.
        & cmd.exe /c "rmdir `"$ScriptsLink`""
        if (-not (Test-Path $ScriptsLink)) { Write-OK "Removed $ScriptsLink" } else { Write-Warn "Couldn't remove $ScriptsLink" }
    }
} elseif ($LinkItem) {
    Write-Warn "$ScriptsLink exists but isn't a junction -- left alone (remove it by hand if it's stale)"
} else {
    Write-Info "No MIDI-GPT Scripts junction found"
}

# ============================================================================
# ReaImGui + siblings (ReaBlink / ReaMCULive / js_ReaScriptAPI from ReaTeam Extensions)
# ============================================================================

Write-Step "ReaImGui (and ReaBlink / ReaMCULive / js_ReaScriptAPI from the same repo)"

$UserPlugins = Join-Path $ReaperDir "UserPlugins"
$ReaTeamDir = Join-Path $ReaperDir "Scripts\ReaTeam Extensions"
$ImguiFiles = @(Get-ChildItem $UserPlugins -Filter "*imgui*" -File -ErrorAction SilentlyContinue)
if ($ImguiFiles.Count -gt 0 -or (Test-Path $ReaTeamDir)) {
    if (Test-ReaperRunning) {
        Write-Warn "REAPER is still open -- skipping (it has the ReaImGui DLL loaded)"
    } elseif (Confirm-Step "Remove ReaImGui and the whole 'ReaTeam Extensions' package folder?") {
        $ImguiFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item $ReaTeamDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Removed ReaImGui and ReaTeam Extensions packages"
    }
} else {
    Write-Info "ReaImGui / ReaTeam Extensions not found"
}

# ============================================================================
# ReaPack itself
# ============================================================================

Write-Step "ReaPack"

$ReapackFiles = @(Get-ChildItem $UserPlugins -Filter "reaper_reapack*" -File -ErrorAction SilentlyContinue)
$ReapackDir = Join-Path $ReaperDir "ReaPack"
$ReapackIni = Join-Path $ReaperDir "reapack.ini"
if ($ReapackFiles.Count -gt 0 -or (Test-Path $ReapackDir) -or (Test-Path $ReapackIni)) {
    if (Test-ReaperRunning) {
        Write-Warn "REAPER is still open -- skipping (it has the ReaPack DLL loaded)"
    } elseif (Confirm-Step "Remove ReaPack (extension + its registry/cache of ALL installed packages)?") {
        $ReapackFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item $ReapackDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $ReapackIni -Force -ErrorAction SilentlyContinue
        Write-OK "Removed ReaPack"
    }
} else {
    Write-Info "ReaPack not found"
}

# ============================================================================
# Arachno SoundFont (downloaded by install.ps1)
# ============================================================================

Write-Step "Arachno SoundFont"

$SoundfontDir = Join-Path $RepoDir "soundfonts"
$Sf2Files = @(Get-ChildItem $SoundfontDir -Filter "*.sf2" -File -ErrorAction SilentlyContinue)
if ($Sf2Files.Count -gt 0) {
    if (Confirm-Step "Remove the SoundFont(s) in $SoundfontDir?") {
        $Sf2Files | Remove-Item -Force
        Write-OK "Removed Arachno SoundFont"
    }
} else {
    Write-Info "No SoundFont found in $SoundfontDir"
}

# ============================================================================
# Aria's converted SoundFont cache
# ============================================================================
# The first time a .sf2 is imported into Sforzando, its Aria engine converts
# it (Plogue's RIFF2sfz.exe) into .sfz presets in an ARIAConverted\ folder
# next to the .sf2, and records that folder as Converted_path in the
# registry -- loaded as Aria bank 4000, which is what Setup Tracks'
# generated instruments refer to. Remove both to get back to a machine where
# Arachno was never imported. Converted_path is Aria-global, so it's only
# cleared when it points at *this* repo's folder, never at some other
# SoundFont the user imported.

Write-Step "Converted SoundFont presets (soundfonts\sfz, ARIAConverted)"

# soundfonts\sfz is Setup Tracks' own one-time conversion (see
# ensure_arachno_sfz in MIDI-GPT Setup Tracks.py); ARIAConverted is Aria's,
# from a manual import into Sforzando.
$SfzDir = Join-Path $SoundfontDir "sfz"
if (Test-Path $SfzDir) {
    if (Confirm-Step "Remove $SfzDir (Setup Tracks' converted presets)?") {
        Remove-Item $SfzDir -Recurse -Force
        Write-OK "Removed $SfzDir"
    }
} else {
    Write-Info "No soundfonts\sfz folder found"
}

$AriaConverted = Join-Path $SoundfontDir "ARIAConverted"
if (Test-Path $AriaConverted) {
    if (Confirm-Step "Remove $AriaConverted?") {
        Remove-Item $AriaConverted -Recurse -Force
        Write-OK "Removed $AriaConverted"
    }
} else {
    Write-Info "No ARIAConverted folder found"
}

$AriaKey = "HKCU:\Software\Plogue Art et Technologie, Inc\Aria"
$AriaPath = (Get-ItemProperty $AriaKey -Name Converted_path -ErrorAction SilentlyContinue).Converted_path
if ($AriaPath) {
    # Aria writes it with mixed separators (...\soundfonts/ARIAConverted).
    $Normalized = [IO.Path]::GetFullPath(($AriaPath -replace '/', '\')).TrimEnd('\')
    if ($Normalized -ieq [IO.Path]::GetFullPath($AriaConverted).TrimEnd('\')) {
        if (Confirm-Step "Clear Aria's Converted_path ($AriaPath)?") {
            Remove-ItemProperty $AriaKey -Name Converted_path
            Write-OK "Cleared Aria's Converted_path"
        }
    } else {
        Write-Info "Aria's Converted_path points elsewhere ($AriaPath) -- left alone"
    }
} else {
    Write-Info "Aria's Converted_path isn't set"
}

if ((Test-Path $SoundfontDir) -and -not (Get-ChildItem $SoundfontDir -Force -ErrorAction SilentlyContinue)) {
    Remove-Item $SoundfontDir -Force
}

# ============================================================================
# Sforzando (best-effort -- a real app installed outside this plugin)
# ============================================================================

Write-Step "Sforzando plugin files"

$CommonFiles = [Environment]::GetFolderPath("CommonProgramFiles")
$SfzPaths = @(
    (Join-Path $CommonFiles "VST3\sforzando.vst3"),
    (Join-Path $CommonFiles "VST2\Plogue Art et Technologie, Inc\sforzando VST_x64.dll"),
    (Join-Path $env:ProgramFiles "VSTPlugins\sforzando VST_x64.dll"),
    (Join-Path $env:ProgramFiles "Steinberg\VstPlugins\sforzando VST_x64.dll")
)
$FoundSfz = @($SfzPaths | Where-Object { Test-Path $_ })
if ($FoundSfz.Count -eq 0) {
    Write-Info "No Sforzando plugin files found in standard locations"
} else {
    Write-Host "  Found:"
    $FoundSfz | ForEach-Object { Write-Host "    $_" }
    if (Confirm-Step "Remove these Sforzando plugin files?") {
        foreach ($P in $FoundSfz) {
            try {
                Remove-Item $P -Recurse -Force -ErrorAction Stop
                Write-OK "Removed $P"
            } catch {
                Write-Warn "Couldn't remove $P (needs administrator rights) -- re-run this from an elevated PowerShell, or uninstall Sforzando from Settings > Apps"
            }
        }
    }
}

# ============================================================================
# ReaScript/Python config in reaper.ini
# ============================================================================

Write-Step "reaper.ini ReaScript/Python config"

$ReaperIni = Join-Path $ReaperDir "reaper.ini"
$KeyPattern = '(?m)^(reascript|pythonlibpath64|pythonlibdll64)=[^\r\n]*(\r?\n)?'
if ((Test-Path $ReaperIni) -and ([IO.File]::ReadAllText($ReaperIni) -match $KeyPattern)) {
    if (Test-ReaperRunning) {
        Write-Warn "REAPER is still open -- skipping reaper.ini (it would just get overwritten on quit)"
    } elseif (Confirm-Step "Remove reascript / pythonlibpath64 / pythonlibdll64 from reaper.ini?") {
        Copy-Item $ReaperIni "$ReaperIni.dev-reset-backup" -Force
        # UTF-8 without BOM, line endings untouched -- same as install.ps1.
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $Content = [IO.File]::ReadAllText($ReaperIni, $Utf8NoBom)
        [IO.File]::WriteAllText($ReaperIni, ($Content -replace $KeyPattern, ''), $Utf8NoBom)
        Write-OK "Removed ReaScript/Python config (backup: $ReaperIni.dev-reset-backup)"
    }
} else {
    Write-Info "No ReaScript/Python config found in reaper.ini"
}

# ============================================================================
# Python virtual environment
# ============================================================================

Write-Step "Python virtual environment"

$Venv = Join-Path $RepoDir ".venv"
if (Test-Path $Venv) {
    if (Confirm-Step "Remove $Venv?") {
        Remove-Item $Venv -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $Venv) {
            Write-Warn "Some of .venv couldn't be removed -- is the MIDI-GPT server still running?"
        } else {
            Write-OK "Removed .venv"
        }
    }
} else {
    Write-Info "No .venv found"
}

# ============================================================================
# Desktop shortcut
# ============================================================================

Write-Step "Desktop shortcut"

$Shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "Start MIDI-GPT Server.lnk"
if (Test-Path $Shortcut) {
    if (Confirm-Step "Remove '$Shortcut'?") {
        Remove-Item $Shortcut -Force
        Write-OK "Removed $Shortcut"
    }
} else {
    Write-Info "No Desktop shortcut found"
}

# ============================================================================
# Done
# ============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  Dev reset complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor White
Write-Host ""
Write-Host "  Re-run .\install.ps1 to test the full install flow from scratch."
Write-Host ""
