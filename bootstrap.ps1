# ============================================================================
# One-line installer for MIDI-GPT for REAPER (Windows / PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/Metacreation-Lab/midigpt-REAPER/main/bootstrap.ps1 | iex
#
# Env vars:
#   MIDIGPT_REAPER_INSTALL_DIR  Where this plugin repo itself gets cloned
#                               (default: %USERPROFILE%\midigpt-REAPER).
#                               Rarely needed.
#   MIDIGPT_DIR                 Path to a local MIDI-GPT (the model) source
#                               checkout -- same as install.ps1's own
#                               -MidigptSrc flag, just exposed as an env
#                               var here since there's no clean way to pass
#                               a flag through an `irm | iex` one-liner.
#
# Everything runs inside a function and only ever `return`s, never `exit`s
# -- piped into `iex`, this script has no process boundary of its own, so a
# raw `exit` would close the caller's whole PowerShell window/session, not
# just abort the install.
# ============================================================================

function Install-MidigptReaper {
    $RepoUrl = "https://github.com/Metacreation-Lab/midigpt-REAPER.git"
    $InstallDir = if ($env:MIDIGPT_REAPER_INSTALL_DIR) { $env:MIDIGPT_REAPER_INSTALL_DIR } else { Join-Path $env:USERPROFILE "midigpt-REAPER" }

    Write-Host ""
    Write-Host "  +======================================+"
    Write-Host "  |     MIDI-GPT for REAPER Installer   |"
    Write-Host "  +======================================+"
    Write-Host ""
    Write-Host "  Installing to: $InstallDir"
    Write-Host ""

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
        Write-Host "git is required but not found."
        Write-Host ""
        Write-Host "  Install it: winget install Git.Git"
        return
    }

    if (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
        Write-Host "Updating existing installation..."
        git -C $InstallDir pull --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
            Write-Host "git pull failed. Check your internet connection."
            return
        }
    } else {
        Write-Host "[INFO] " -ForegroundColor Blue -NoNewline
        Write-Host "Cloning repository..."
        git clone --quiet $RepoUrl $InstallDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
            Write-Host "git clone failed. Check your internet connection."
            return
        }
    }
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host "Repository ready at $InstallDir"
    Write-Host ""

    # MIDIGPT_DIR (a local MIDI-GPT source checkout) maps to install.ps1's
    # own -MidigptSrc flag.
    $ExtraArgs = @()
    if ($env:MIDIGPT_DIR) {
        $ExtraArgs += "-MidigptSrc"
        $ExtraArgs += $env:MIDIGPT_DIR
    }

    $InstallScript = Join-Path $InstallDir "install.ps1"
    if (-not (Test-Path $InstallScript)) {
        Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
        Write-Host "install.ps1 not found at $InstallScript -- clone looks incomplete."
        return
    }

    & $InstallScript @ExtraArgs
}

Install-MidigptReaper
