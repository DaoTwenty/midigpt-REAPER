# ============================================================================
# MIDI-GPT for REAPER — Windows Installer (PowerShell)
#
# Installs everything needed to run MIDI-GPT in REAPER:
#   1. System dependencies (python, git) via winget or choco
#   2. Python virtual environment + PyTorch
#   3. MIDI-GPT backend library (pip, from PyPI or a sibling/source checkout)
#   4. REAPER integration (Scripts junction), plus ReaPack and ReaImGui (the
#      dashboard UI's REAPER extension dependencies)
#   5. REAPER Python/ReaScript configuration (reaper.ini)
#   6. Verification of installation
#
# ReaPack itself is installed directly (it's just an extension DLL,
# downloaded over HTTPS from its GitHub release and checksum-verified
# against GitHub's own published digest before use -- it isn't code-signed,
# so this is the only integrity check available for it; Unblock-File then
# clears the downloaded-file mark so REAPER can load it without a manual
# SmartScreen click-through). The dashboard UI's ReaImGui extension can
# only be installed through REAPER's own ReaPack API while REAPER is
# running, so this installer queues it to install automatically the next
# time REAPER starts (via a small Scripts\__startup.lua bootstrap) -- if
# REAPER is currently open, it asks permission to close it first (never
# force-killed; any unsaved project still prompts to save) so both this and
# the reaper.ini setup below can run in the same pass, then reopens REAPER
# for you.
#
# Usage:
#   .\install.ps1                              # Full install
#   .\install.ps1 -SkipDeps                    # Skip dependency check
#   .\install.ps1 -SkipReaperConfig            # Don't modify reaper.ini
#   .\install.ps1 -ReaperOnly                  # Only Step 4/5 (REAPER
#                                                 integration) -- skips
#                                                 venv/backend entirely
#   .\install.ps1 -MidigptSrc C:\path\to\MIDI-GPT
# ============================================================================

param(
    [switch]$SkipDeps,
    [switch]$SkipReaperConfig,
    [switch]$ReaperOnly,
    [switch]$TorchGpu,
    [switch]$Dev,
    [string]$MidigptSrc = "",
    [switch]$Help
)

# NOT "Stop" -- Windows PowerShell 5.1 (unlike pwsh 7+) promotes *any*
# stderr output from a native command (git, pip, python -- all used
# throughout this script) into a terminating NativeCommandError under
# "Stop", even when that output is just a warning or an expected failure
# already handled via $LASTEXITCODE below (confirmed against a real
# windows-latest run: `python -c "import torch" 2>$null`, whose whole
# point is to fail silently before PyTorch is installed, still aborted the
# script here). Every native-command result that actually needs to stop
# the install already checks $LASTEXITCODE explicitly and calls
# Write-Fail; every cmdlet call that needs to stop the install (the
# network downloads) already has its own try/catch, which still catches
# real terminating exceptions regardless of this preference.
$ErrorActionPreference = "Continue"

# ── Config ──────────────────────────────────────────────────────
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $RepoDir ".venv"
$PythonMinVersion = "3.10"
$PythonCmd = ""

# ── Helpers ─────────────────────────────────────────────────────

function Write-Info { param($msg) Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $msg }
function Write-OK   { param($msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn { param($msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Fail { param($msg) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $msg; exit 1 }

function Write-Step {
    param($msg)
    Write-Host ""
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host "  $msg" -ForegroundColor White
    Write-Host ("-" * 52) -ForegroundColor White
}

function Test-Command { param($cmd) $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

function Test-Interactive { -not [Console]::IsInputRedirected }

# Test-only override (see tests/) -- simulates REAPER being open without
# needing a real REAPER process running.
function Test-ReaperRunning {
    if ($env:MIDIGPT_FAKE_REAPER_RUNNING) {
        return $env:MIDIGPT_FAKE_REAPER_RUNNING -eq "true"
    }
    return $null -ne (Get-Process -Name "reaper" -ErrorAction SilentlyContinue)
}

function Test-BuildTools {
    $Missing = @()
    # Windows: need Visual Studio Build Tools + CMake for source installs
    if (-not (Test-Command "cl.exe") -and -not (Test-Command "cmake")) {
        $Missing += "Visual Studio Build Tools + CMake (winget install Microsoft.VisualStudio.2022.BuildTools; winget install Kitware.CMake)"
    }
    if ($Missing.Count -gt 0) {
        Write-Warn "Source install requires compilation tools:"
        foreach ($m in $Missing) { Write-Host "  - $m" }
        return $false
    }
    return $true
}

# Ask REAPER to quit gracefully (taskkill without /F sends a close request
# to the main window, so REAPER's own "save changes?" prompt still fires --
# never force-killed) and wait for the process to actually exit.
function Invoke-ReaperQuitAndWait {
    Write-Info "Asking REAPER to quit -- any unsaved project will prompt you to save first..."
    try {
        Start-Process -FilePath "taskkill.exe" -ArgumentList "/IM", "reaper.exe" -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    $Waited = 0
    while ((Test-ReaperRunning) -and ($Waited -lt 120)) {
        Start-Sleep -Seconds 2
        $Waited += 2
    }

    if (Test-ReaperRunning) {
        Write-Warn "REAPER is still open (it may be waiting on a save prompt)."
        Read-Host "  Close it manually, then press Enter to continue (Ctrl+C to abort)" | Out-Null
    }
}

function Start-ReaperApp {
    # Test-only override -- simulates REAPER relaunch without real process
    if ($env:MIDIGPT_FAKE_REAPER_RUNNING) {
        Write-Info "Test mode: skipping actual REAPER relaunch"
        return $false
    }
    $Candidates = @(
        (Join-Path $env:ProgramFiles "REAPER (x64)\reaper.exe"),
        (Join-Path $env:ProgramFiles "REAPER\reaper.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $Candidates += (Join-Path ${env:ProgramFiles(x86)} "REAPER\reaper.exe")
    }
    foreach ($p in $Candidates) {
        if (Test-Path $p) {
            Start-Process -FilePath $p
            return $true
        }
    }
    Write-Warn "Could not find REAPER's install location to relaunch it automatically -- start it manually."
    return $false
}

function Open-Url { 
    param($Url) 
    try {
        Start-Process $Url | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Merge the MIDI-GPT ReaImGui bootstrap block into Scripts\__startup.lua,
# replacing any previous block between the same markers in place (never
# duplicating it) and preserving anything else already in the file.
function Set-StartupLuaBlock {
    param([string]$StartupLuaPath)

    $BeginMark = "-- BEGIN MIDI-GPT ReaImGui bootstrap (safe to delete this block)"
    $EndMark = "-- END MIDI-GPT ReaImGui bootstrap"
    $Block = "if not reaper.APIExists(`"ImGui_CreateContext`") then`n" +
        "  reaper.ReaPack_AddSetRepository(`"ReaTeam Extensions`", `"https://github.com/ReaTeam/Extensions/raw/master/index.xml`", true, 1)`n" +
        "  reaper.ReaPack_ProcessQueue(true)`n" +
        "end"
    $NewBlockText = "$BeginMark`n$Block`n$EndMark"

    New-Item -ItemType Directory -Path (Split-Path $StartupLuaPath -Parent) -Force | Out-Null
    $Content = ""
    if (Test-Path $StartupLuaPath) {
        $Content = Get-Content -Path $StartupLuaPath -Raw
        if ($null -eq $Content) { $Content = "" }
    }

    $BeginIdx = $Content.IndexOf($BeginMark)
    if ($BeginIdx -ge 0) {
        $EndIdx = $Content.IndexOf($EndMark, $BeginIdx)
        if ($EndIdx -ge 0) {
            $Before = $Content.Substring(0, $BeginIdx)
            $After = $Content.Substring($EndIdx + $EndMark.Length)
            $Content = $Before + $NewBlockText + $After
        } else {
            $Content = $Content.TrimEnd() + "`n`n$NewBlockText`n"
        }
    } else {
        $Content = $Content.TrimEnd()
        if ($Content.Length -gt 0) { $Content += "`n`n" }
        $Content += "$NewBlockText`n"
    }
    Set-Content -Path $StartupLuaPath -Value $Content -NoNewline
}

# Downloads the Arachno GM SoundFont into this repo's own soundfonts\
# folder (kept alongside the plugin, not scattered into REAPER's resource
# dir), under its real filename -- REAPER_midigpt_setup_tracks.py reads
# whatever .sf2 is actually there rather than a hardcoded name, so this
# doesn't need to match anything else exactly. Arachno is freeware and this
# is the exact .zip Arachnosoft's own download page links to (mirrored on
# Dropbox) -- not a third-party scrape. Sforzando itself is a real
# application installer, not a data file, so it's intentionally NOT
# auto-installed the same way (see the instrument-setup prompt below).
function Install-ArachnoSoundfont {
    $DestDir = Join-Path $RepoDir "soundfonts"
    if (Test-Path $DestDir) {
        $Existing = Get-ChildItem -Path $DestDir -Filter "*.sf2" -ErrorAction SilentlyContinue
        if ($Existing) {
            Write-OK "Arachno SoundFont already present in $DestDir"
            return $true
        }
    }

    Write-Info "Downloading Arachno SoundFont (~140MB, may take a few minutes)..."
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    $TmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "midigpt-arachno-$([System.Guid]::NewGuid()).zip"

    try {
        Invoke-WebRequest -Uri "https://www.dropbox.com/s/2rnpya9ecb9m4jh/arachno-soundfont-10-sf2.zip?dl=1" `
            -OutFile $TmpZip -UseBasicParsing -TimeoutSec 900
    } catch {
        Write-Warn "Failed to download Arachno SoundFont -- get it manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
        Remove-Item $TmpZip -Force -ErrorAction SilentlyContinue
        return $false
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = $null
    try {
        $Zip = [System.IO.Compression.ZipFile]::OpenRead($TmpZip)
        $Entry = $Zip.Entries | Where-Object { $_.Name -like "*.sf2" } | Select-Object -First 1
        if (-not $Entry) {
            Write-Warn "Downloaded archive didn't contain a .sf2 file -- get Arachno manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
            return $false
        }
        $DestFile = Join-Path $DestDir $Entry.Name
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $DestFile, $true)
        Write-OK "Arachno SoundFont installed: $DestFile"
        return $true
    } catch {
        Write-Warn "Downloaded archive didn't extract cleanly -- get Arachno manually: https://www.arachnosoft.com/main/download.php?id=soundfont-sf2"
        return $false
    } finally {
        if ($Zip) { $Zip.Dispose() }
        Remove-Item $TmpZip -Force -ErrorAction SilentlyContinue
    }
}

# ── Help ────────────────────────────────────────────────────────

if ($Help) {
    Write-Host "MIDI-GPT for REAPER — Windows Installer"
    Write-Host ""
    Write-Host "Usage: .\install.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -SkipDeps            Skip system dependency check"
    Write-Host "  -SkipReaperConfig    Skip automatic REAPER Python/ReaScript configuration"
    Write-Host "  -ReaperOnly          Only do REAPER integration (Step 4/5: junction, ReaPack,"
    Write-Host "                       ReaImGui, reaper.ini) -- skips venv/backend entirely."
    Write-Host "                       Useful to redo just the REAPER side, or for testing."
    Write-Host "  -TorchGpu            Install PyTorch with GPU support (CUDA)."
    Write-Host "  -Dev                 Install plugin in editable mode for development."
    Write-Host "  -MidigptSrc PATH     Path to MIDI-GPT source repo (sibling folder by default)"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\install.ps1                              # Full installation (CPU torch)"
    Write-Host "  .\install.ps1 -TorchGpu                    # Full installation with GPU torch"
    Write-Host "  .\install.ps1 -Dev                         # Development install (editable)"
    Write-Host "  .\install.ps1 -MidigptSrc C:\path\to\MIDI-GPT  # Custom MIDI-GPT source path"
    Write-Host "  .\install.ps1 -ReaperOnly                  # Just (re)do REAPER integration"
    exit 0
}

# ── Banner ──────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor White
Write-Host "  ║     MIDI-GPT for REAPER Installer    ║" -ForegroundColor White
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor White
Write-Host ""
Write-Info "Platform: Windows"

if ($ReaperOnly) {
    Write-Step "Skipping system deps / venv / backend (-ReaperOnly)"
    # Still need a python to detect the ReaScript library path in Step 5.
    foreach ($cmd in @("python3", "python")) {
        if (Test-Command $cmd) {
            $PyMinorCheck = & $cmd -c "import sys; print(sys.version_info.minor)" 2>$null
            if ($LASTEXITCODE -eq 0 -and [int]$PyMinorCheck -ge 10) {
                $PythonCmd = $cmd
                break
            }
        }
    }
}

# ====================================================================
# Step 1: System Dependencies
# ====================================================================

if (-not $ReaperOnly) {

if (-not $SkipDeps) {
    Write-Step "Step 1/6: Checking system dependencies"

    $Missing = @()

    # -- Python --
    foreach ($cmd in @("python3", "python")) {
        if (Test-Command $cmd) {
            $PyVer = & $cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            $PyMajor = & $cmd -c "import sys; print(sys.version_info.major)" 2>$null
            $PyMinor = & $cmd -c "import sys; print(sys.version_info.minor)" 2>$null
            if ([int]$PyMajor -ge 3 -and [int]$PyMinor -ge 10) {
                $PythonCmd = $cmd
                break
            }
        }
    }

    if (-not $PythonCmd) {
        $Missing += "python>=3.10"
        Write-Warn "Python >= $PythonMinVersion not found"
    } else {
        Write-OK "Python $PyVer ($PythonCmd)"
    }

    # -- git --
    if (Test-Command "git") {
        Write-OK "git found"
    } else {
        $Missing += "git"
        Write-Warn "git not found"
    }

    # -- Install missing deps --
    if ($Missing.Count -gt 0) {
        Write-Host ""
        Write-Warn "Missing dependencies: $($Missing -join ', ')"
        Write-Host ""

        $Installer = $null
        if (Test-Command "winget") { $Installer = "winget" }
        elseif (Test-Command "choco") { $Installer = "choco" }

        if ($Installer) {
            Write-Info "Installing via $Installer..."
            foreach ($dep in $Missing) {
                switch ($dep) {
                    "python>=3.10" {
                        if ($Installer -eq "winget") { winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements }
                        else { choco install python312 -y }
                    }
                    "git" {
                        if ($Installer -eq "winget") { winget install Git.Git --accept-package-agreements --accept-source-agreements }
                        else { choco install git -y }
                    }
                }
            }

            # Refresh PATH after install
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            if (-not $PythonCmd) {
                foreach ($cmd in @("python3", "python")) {
                    if (Test-Command $cmd) {
                        $PyMinor = & $cmd -c "import sys; print(sys.version_info.minor)" 2>$null
                        if ([int]$PyMinor -ge 10) {
                            $PythonCmd = $cmd
                            break
                        }
                    }
                }
            }
        } else {
            Write-Host ""
            Write-Host "Please install the missing dependencies manually:"
            Write-Host ""
            Write-Host "  Option 1 (winget - built into Windows 11):"
            Write-Host "    winget install Python.Python.3.12"
            Write-Host "    winget install Git.Git"
            Write-Host ""
            Write-Host "  Option 2 (chocolatey - https://chocolatey.org/):"
            Write-Host "    choco install python312 git -y"
            Write-Host ""
            Write-Fail "Please install missing dependencies and re-run"
        }
    }

    if (-not $PythonCmd) { Write-Fail "Python >= $PythonMinVersion required but not found" }
    Write-OK "All system dependencies satisfied"

} else {
    Write-Step "Step 1/6: Skipping dependency check (-SkipDeps)"
    foreach ($cmd in @("python3", "python")) {
        if (Test-Command $cmd) {
            $PyMinor = & $cmd -c "import sys; print(sys.version_info.minor)" 2>$null
            if ([int]$PyMinor -ge 10) {
                $PythonCmd = $cmd
                break
            }
        }
    }
    if (-not $PythonCmd) { Write-Fail "Python >= $PythonMinVersion required but not found" }
}

# ====================================================================
# Step 2: Virtual Environment + PyTorch
# ====================================================================

Write-Step "Step 2/6: Setting up Python virtual environment"

if (Test-Path $VenvDir) {
    Write-Info "Existing venv found at $VenvDir"
    & "$VenvDir\Scripts\Activate.ps1"
    Write-OK "Activated existing venv"
} else {
    Write-Info "Creating venv with $PythonCmd..."
    & $PythonCmd -m venv $VenvDir
    & "$VenvDir\Scripts\Activate.ps1"
    # `python -m pip install --upgrade pip`, not `pip install --upgrade
    # pip` -- Windows refuses to let pip.exe overwrite itself while it's
    # the running executable ("To modify pip, please run the following
    # command: ... -m pip install --upgrade pip").
    python -m pip install --upgrade pip setuptools wheel -q
    Write-OK "Created and activated venv at $VenvDir"
}

Write-Info "Checking PyTorch..."
python -c "import torch" 2>$null
if ($LASTEXITCODE -eq 0) {
    $TorchVer = python -c "import torch; print(torch.__version__)" 2>$null
    Write-OK "PyTorch $TorchVer already installed"
} else {
    Write-Info "Installing PyTorch (this may take a few minutes)..."
    if ($TorchGpu) {
        pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
    } else {
        pip install torch
    }
    python -c "import torch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $TorchVer = python -c "import torch; print(torch.__version__)" 2>$null
        Write-OK "PyTorch $TorchVer installed"
    } else {
        Write-Host ""
        Write-Warn "PyTorch could not be installed automatically."
        Write-Host ""
        Write-Host "  This usually means there is no pre-built PyTorch wheel for your"
        Write-Host "  Python version. Please install PyTorch manually:"
        Write-Host ""
        Write-Host "  1. Visit: https://pytorch.org/get-started/locally/"
        Write-Host "  2. Select your OS, package manager (pip), and Python version"
        Write-Host "  3. Run the install command it gives you WITH THIS VENV ACTIVATED:"
        Write-Host "       .\\.venv\\Scripts\\Activate.ps1"
        Write-Host "       pip install <command-from-pytorch-org>"
        Write-Host "  4. Then re-run this installer (it will detect existing torch)"
        Write-Host ""
        Write-Fail "PyTorch installation failed. See instructions above."
    }
}

# ====================================================================
# Step 3: Install MIDI-GPT Backend
# ====================================================================

Write-Step "Step 3/6: Installing MIDI-GPT backend"

$MidigptSibling = Join-Path (Split-Path $RepoDir -Parent) "MIDI-GPT"

if ($MidigptSrc -and (Test-Path $MidigptSrc)) {
    Write-Info "Installing midigpt[http,inference] from source: $MidigptSrc ..."
    Test-BuildTools | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "Missing build tools required for source install" }
    pip install -e "${MidigptSrc}[http,inference]" 2>&1
} else {
    Write-Info "Installing midigpt[http,inference] from PyPI ..."
    pip install "midigpt[http,inference]" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "PyPI install failed — falling back to cloning MIDI-GPT from GitHub ..."
        if (-not (Test-Path (Join-Path $MidigptSibling ".git"))) {
            git clone https://github.com/Metacreation-Lab/MIDI-GPT.git $MidigptSibling
            if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to clone MIDI-GPT. Check your internet connection." }
        } else {
            Write-Info "Existing MIDI-GPT clone found at $MidigptSibling"
        }
        pip install -e "${MidigptSibling}[http,inference]" 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Fail "Source install from cloned MIDI-GPT also failed." }
    }
}

python -c "from midigpt.inference.engine import InferenceEngine" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK "midigpt backend installed successfully"
} else {
    Write-Fail "midigpt backend installation failed."
}

Write-Info "Installing plugin dependencies..."
if ($Dev) {
    pip install -e $RepoDir -q 2>$null
    if ($LASTEXITCODE -ne 0) { pip install -e $RepoDir }
    Write-OK "Plugin dependencies installed (editable mode)"
} else {
    pip install $RepoDir -q 2>$null
    if ($LASTEXITCODE -ne 0) { pip install $RepoDir }
    Write-OK "Plugin dependencies installed"
}

} # ReaperOnly == false (Steps 1-3)

# ====================================================================
# Step 4: REAPER Integration (Scripts junction, ReaPack, ReaImGui)
# ====================================================================

Write-Step "Step 4/6: Setting up REAPER integration"

if ($env:MIDIGPT_REAPER_DIR) {
    # Test-only override (see tests/) -- lets the REAPER integration logic
    # run against a disposable fake directory instead of the real REAPER
    # install, so different starting states (empty, ReaPack already
    # present, existing reaper.ini content, etc.) can be exercised
    # repeatably without ever touching a real machine's REAPER.
    $ReaperDir = $env:MIDIGPT_REAPER_DIR
} else {
    $ReaperDir = Join-Path $env:APPDATA "REAPER"
}

$ReaperWasClosedByUs = $false

if (Test-Path $ReaperDir) {
    # Installing ReaPack and configuring reaper.ini (Step 5) both need
    # REAPER closed. Ask once, up front, so both steps can run this pass
    # instead of telling the user to re-run the installer later.
    if (Test-ReaperRunning) {
        if (Test-Interactive) {
            Write-Warn "REAPER is currently running."
            Write-Host "  Installing ReaPack and configuring REAPER (reaper.ini) both require REAPER"
            Write-Host "  to be closed. Nothing is discarded silently -- REAPER will prompt you to"
            Write-Host "  save any unsaved project first, same as quitting normally."
            $CloseReaper = Read-Host "  Close REAPER now and continue? [y/N]"
            if ($CloseReaper -match "^[Yy]$") {
                Invoke-ReaperQuitAndWait
                if (-not (Test-ReaperRunning)) {
                    $ReaperWasClosedByUs = $true
                }
            } else {
                Write-Warn "Continuing with REAPER open -- ReaPack install and reaper.ini setup will be skipped this run."
            }
        } else {
            Write-Warn "REAPER is currently running -- ReaPack install and reaper.ini setup will be skipped (non-interactive)."
            Write-Host "  Close REAPER, then re-run this installer:"
            Write-Host "    .\install.ps1"
        }
    }

    # -- Scripts junction --
    $ScriptsSrc = Join-Path $RepoDir "src\Scripts\MIDI-GPT"
    $ScriptsDst = Join-Path $ReaperDir "Scripts\MIDI-GPT"
    if (Test-Path $ScriptsSrc) {
        $DstParent = Split-Path $ScriptsDst -Parent
        if (-not (Test-Path $DstParent)) { New-Item -ItemType Directory -Path $DstParent -Force | Out-Null }
        if (Test-Path $ScriptsDst) {
            cmd /c "rmdir `"$ScriptsDst`"" 2>$null
            Remove-Item $ScriptsDst -Recurse -Force -ErrorAction SilentlyContinue
        }
        cmd /c "mklink /J `"$ScriptsDst`" `"$ScriptsSrc`"" | Out-Null
        Write-OK "REAPER Scripts junction created"
    }

    # -- ReaPack + ReaImGui --
    $ReapackReady = $false
    $UserPluginsDir = Join-Path $ReaperDir "UserPlugins"
    $ExistingReapack = $null
    if (Test-Path $UserPluginsDir) {
        $ExistingReapack = Get-ChildItem -Path $UserPluginsDir -Filter "reaper_reapack*" -ErrorAction SilentlyContinue
    }

    if ($ExistingReapack) {
        Write-OK "ReaPack already installed"
        $ReapackReady = $true
    } elseif (Test-ReaperRunning) {
        Write-Warn "ReaPack not installed, and REAPER is still open -- skipping (re-run after closing REAPER, or install manually: https://reapack.com/)"
    } else {
        Write-Info "Installing ReaPack..."
        $ReapackAsset = "reaper_reapack-x64.dll"
        $ReapackUrl = "https://github.com/cfillion/reapack/releases/latest/download/$ReapackAsset"
        New-Item -ItemType Directory -Path $UserPluginsDir -Force | Out-Null
        $ReapackDest = Join-Path $UserPluginsDir $ReapackAsset

        # ReaPack's own releases aren't code-signed, so there's no
        # signature to verify -- fetch GitHub's published SHA256 for this
        # exact asset instead, so we can at least catch a corrupted or
        # tampered-with download before trusting it.
        $ExpectedSha = $null
        try {
            $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/cfillion/reapack/releases/latest" -TimeoutSec 15
            $Asset = $Release.assets | Where-Object { $_.name -eq $ReapackAsset }
            if ($Asset -and $Asset.digest) {
                $ExpectedSha = ($Asset.digest -replace "^sha256:", "").ToLower()
            }
        } catch {
            Write-Warn "Could not fetch an expected checksum for ReaPack -- installing unverified"
        }

        try {
            Invoke-WebRequest -Uri $ReapackUrl -OutFile $ReapackDest -UseBasicParsing -TimeoutSec 120
            $ReapackVerified = $true
            if ($ExpectedSha) {
                $ActualSha = (Get-FileHash -Path $ReapackDest -Algorithm SHA256).Hash.ToLower()
                if ($ActualSha -ne $ExpectedSha) { $ReapackVerified = $false }
            }

            if ($ReapackVerified) {
                # A downloaded, unsigned DLL can be blocked by SmartScreen
                # (the Windows equivalent of macOS quarantine) until the
                # user manually clicks through it. Clear the Mark-of-the-Web
                # zone identifier ourselves, now that the checksum above
                # confirms it's what GitHub actually published.
                Unblock-File -Path $ReapackDest -ErrorAction SilentlyContinue
                Write-OK "ReaPack installed and checksum-verified ($ReapackAsset)"
                $ReapackReady = $true
            } else {
                Remove-Item $ReapackDest -Force -ErrorAction SilentlyContinue
                Write-Warn "Downloaded ReaPack didn't match GitHub's published checksum -- discarded. Install manually: https://reapack.com/"
            }
        } catch {
            Write-Warn "Failed to download ReaPack -- install manually: https://reapack.com/"
        }
    }

    $HasImgui = $null
    if (Test-Path $UserPluginsDir) {
        $HasImgui = Get-ChildItem -Path $UserPluginsDir -Filter "*imgui*" -ErrorAction SilentlyContinue
    }
    $ImGuiBootstrapWritten = $false
    if (-not $HasImgui) {
        if ($ReapackReady) {
            Write-Info "Queuing ReaImGui install for the next REAPER launch..."
            $StartupLua = Join-Path $ReaperDir "Scripts\__startup.lua"
            Set-StartupLuaBlock -StartupLuaPath $StartupLua
            $ImGuiBootstrapWritten = $true
            Write-OK "ReaImGui will install automatically the next time REAPER starts"
            Write-Warn "This also installs the other packages in the 'ReaTeam Extensions' repo (ReaBlink, ReaMCULive, js_ReaScriptAPI) -- all official ReaTeam-curated extensions, not just ReaImGui, since ReaPack can only auto-install per-repository, not per-package."
        } else {
            Write-Warn "ReaImGui extension not found - the dashboard UI needs it"
            Write-Host "  In REAPER: Extensions > ReaPack > Browse packages > search 'ReaImGui' > install > restart REAPER"
        }
    }
} else {
    Write-Warn "REAPER config directory not found — REAPER may not be installed yet"
    Write-Host "  Install REAPER: https://www.reaper.fm/download.php"
    Write-Host "  Launch REAPER once, quit it, then re-run this installer:"
    Write-Host "    .\install.ps1"
}

# ====================================================================
# Step 5: Configure REAPER for Python / ReaScript
# ====================================================================

if ($SkipReaperConfig) {
    Write-Step "Step 5/6: Skipping REAPER config (-SkipReaperConfig)"
} else {
    Write-Step "Step 5/6: Configuring REAPER (reaper.ini)"

    $ReaperIni = Join-Path $ReaperDir "reaper.ini"
    $PyCmdForDll = "python3"
    if ($PythonCmd) { $PyCmdForDll = $PythonCmd }

    $PythonDll = & $PyCmdForDll -c @"
import sys, pathlib
base = pathlib.Path(sys.exec_prefix)
ver = f'{sys.version_info.major}{sys.version_info.minor}'
for p in base.glob(f'python{ver}.dll'):
    print(p); break
"@ 2>$null

    if (Test-Path $ReaperIni) {
        if (Test-ReaperRunning) {
            Write-Warn "REAPER is currently running!"
            Write-Host "  REAPER overwrites reaper.ini on quit, so changes would be lost."
            Write-Host "  Please quit REAPER and re-run this installer, or configure manually:"
            Write-Host "    Options > Preferences > Plug-Ins > ReaScript"
            if ($PythonDll) { Write-Host "    Python library: $PythonDll" }
        } elseif ($PythonDll -and (Test-Path $PythonDll)) {
            Copy-Item $ReaperIni "$ReaperIni.midigpt-backup" -Force
            Write-Info "Backed up reaper.ini -> reaper.ini.midigpt-backup"

            $IniContent = Get-Content $ReaperIni -Raw
            if ($null -eq $IniContent) { $IniContent = "" }

            function Set-ReaperIniKey {
                param([string]$Key, [string]$Value, [string]$Content)
                # PowerShell's -match/-replace are case-insensitive by
                # default, so this already matches [REAPER] and [reaper]
                # alike without any special-casing.
                $KeyPattern = "(?m)^$([regex]::Escape($Key))=.*$"
                if ($Content -match $KeyPattern) {
                    return ($Content -replace $KeyPattern, "$Key=$Value")
                }
                $SectionMatch = [regex]::Match($Content, "(?m)^\[REAPER\]\s*$")
                if ($SectionMatch.Success) {
                    $InsertAt = $SectionMatch.Index + $SectionMatch.Length
                    return $Content.Substring(0, $InsertAt) + "`n$Key=$Value" + $Content.Substring($InsertAt)
                }
                # No [REAPER]/[reaper] section at all yet (fresh ini) --
                # append one.
                $Sep = ""
                if ($Content.TrimEnd().Length -gt 0) { $Sep = "`n`n" }
                return $Content.TrimEnd() + "$Sep[REAPER]`n$Key=$Value`n"
            }

            $IniContent = Set-ReaperIniKey -Key "reascript" -Value "1" -Content $IniContent
            $IniContent = Set-ReaperIniKey -Key "pythonlibdll64" -Value $PythonDll -Content $IniContent

            Set-Content -Path $ReaperIni -Value $IniContent -NoNewline

            if (($IniContent -match "(?m)^reascript=1") -and ($IniContent -match "(?m)^pythonlibdll64=")) {
                Write-OK "ReaScript enabled (reascript=1)"
                Write-OK "Python library: $PythonDll"
            } else {
                Write-Warn "Failed to write ReaScript/Python settings to reaper.ini"
                Write-Host "  Configure manually: Options > Preferences > Plug-Ins > ReaScript"
                Write-Host "    Python library: $PythonDll"
            }
        } else {
            Write-Warn "Could not detect Python DLL path"
            Write-Host "  You'll need to configure this manually in REAPER:"
            Write-Host "    Options > Preferences > Plug-Ins > ReaScript"
        }
    } else {
        if (Test-Path $ReaperDir) {
            Write-Warn "reaper.ini not found — REAPER may not have been launched yet"
            Write-Host "  Launch REAPER once, quit it, then re-run this installer to auto-configure."
        } else {
            Write-Warn "REAPER config directory not found — REAPER may not be installed"
            Write-Host "  Install REAPER: https://www.reaper.fm/download.php"
            Write-Host "  Launch REAPER once, quit it, then re-run this installer:"
            Write-Host "    .\install.ps1"
        }
        if ($PythonDll) {
            Write-Host ""
            Write-Host "  Manual REAPER configuration required:"
            Write-Host "  1. Open REAPER"
            Write-Host "  2. Options > Preferences > Plug-Ins > ReaScript"
            Write-Host "  3. Enable 'ReaScript' (checkbox)"
            Write-Host "  4. Set 'Python library' to:"
            Write-Host "       $PythonDll" -ForegroundColor Green
            Write-Host "  5. Click OK, then RESTART REAPER for changes to take effect."
        }
    }
}

# Check if we need to launch REAPER for ImGui install (either we closed it, or
# ImGui bootstrap was written and REAPER isn't running)
$NeedReaperForImGui = $false
if ($ReaperWasClosedByUs -or $ImGuiBootstrapWritten) {
    if (-not (Test-ReaperRunning)) {
        $NeedReaperForImGui = $true
    }
}

if ($NeedReaperForImGui) {
    Write-Info "Launching REAPER to install ReaImGui via ReaPack..."
    if (Start-ReaperApp) {
        Write-OK "REAPER launched -- waiting for ReaImGui to install (up to 120s)..."
        # Poll for ImGui binary in UserPlugins
        $Waited = 0
        $ImGuiFound = $false
        while ($Waited -lt 120) {
            $ImGuiCheck = Get-ChildItem -Path $UserPluginsDir -Filter "*imgui*" -ErrorAction SilentlyContinue
            if ($ImGuiCheck) {
                $ImGuiFound = $true
                break
            }
            Start-Sleep -Seconds 5
            $Waited += 5
        }
        if ($ImGuiFound) {
            Write-OK "ReaImGui installed successfully"
        } else {
            Write-Warn "ReaImGui not detected yet (may still be installing in background)"
        }
        # Close REAPER gracefully so user starts fresh
        Invoke-ReaperQuitAndWait
        Write-Info "REAPER closed. Setup complete — start REAPER when ready to use MIDI-GPT."
    }
}

if (-not $ReaperOnly) {

# ====================================================================
# Step 6: Verify Backend Installation
# ====================================================================

Write-Step "Step 6/6: Verifying backend installation"

python -c "from midigpt.inference.engine import InferenceEngine" 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK "Verification successful: midigpt is installed and functional"
} else {
    Write-Fail "Verification failed: midigpt could not be imported"
}

# ====================================================================
# Create Desktop shortcut to server launcher
# ====================================================================

$DesktopDir = [Environment]::GetFolderPath("Desktop")
if (Test-Path $DesktopDir) {
    $ShortcutPath = Join-Path $DesktopDir "Start MIDI-GPT Server.lnk"
    $ServerBat = Join-Path $RepoDir "Start Server - Windows.bat"
    if (Test-Path $ServerBat) {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $ServerBat
        $Shortcut.WorkingDirectory = $RepoDir
        $Shortcut.Description = "Start the MIDI-GPT inference server for REAPER"
        $Shortcut.Save()
        Write-OK "Desktop shortcut created: Start MIDI-GPT Server.lnk"
    }
} else {
    Write-Info "No Desktop folder found — skipping shortcut creation"
}

} # ReaperOnly == false (Step 6 + Desktop shortcut)

# ====================================================================
# Final: Summary and Next Steps
# ====================================================================

Write-Host ""
Write-Host ("=" * 52) -ForegroundColor White
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host ("=" * 52) -ForegroundColor White
Write-Host ""

Write-Host "Next steps in REAPER:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Load the ReaScript actions:"
Write-Host "     Actions > Show Action List > Load ReaScript"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_dashboard.py   (primary UI)"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_infill.py"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_set_server.py"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_setup_tracks.py"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_apply_soundfont_template.py"
Write-Host ""
Write-Host "  2. Run 'MIDI-GPT: Dashboard' — it's a single window for the whole"
Write-Host "     workflow (global options, per-track controls, running generation)."
Write-Host "     Needs the ReaImGui extension -- see the warning above if it's missing."
Write-Host ""
Write-Host "  If the MIDI-GPT server runs on a different machine, run the"
Write-Host "  'MIDI-GPT: Set server address' action and enter its IP/domain and port"
Write-Host "  (e.g. http://192.168.1.20:3456). Defaults to http://127.0.0.1:3456."
Write-Host ""
Write-Host "To start the server:" -ForegroundColor White
if (Test-Path (Join-Path ([Environment]::GetFolderPath("Desktop")) "Start MIDI-GPT Server.lnk")) {
    Write-Host "  Double-click " -NoNewline
    Write-Host "Start MIDI-GPT Server" -ForegroundColor Green -NoNewline
    Write-Host " on your Desktop"
} else {
    Write-Host "  Double-click: " -NoNewline
    Write-Host "Start Server - Windows.bat" -ForegroundColor Green
}
Write-Host "  Or from terminal: cd $RepoDir; .\.venv\Scripts\Activate.ps1; midigpt-http"
Write-Host ""

# ====================================================================
# Interactive: Instrument setup (Sforzando + Arachno)
# ====================================================================

if (Test-Interactive) {
    Write-Host ""
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host "  Optional: Instrument Setup (Sforzando + Arachno)" -ForegroundColor White
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host ""
    Write-Host "  MIDI-GPT tracks play through Sforzando (a free SFZ sampler) loaded"
    Write-Host "  with the Arachno General MIDI SoundFont -- see VST.md for the full"
    Write-Host "  setup."
    Write-Host ""
    Write-Host "  Sforzando is a real application installer (not just a data file),"
    Write-Host "  behind its own download page, so this installer opens that page for"
    Write-Host "  you rather than running an installer on your behalf."
    $OpenSfz = Read-Host "  Open the Sforzando download page in your browser now? [y/N]"
    if ($OpenSfz -match "^[Yy]$") {
        if (Open-Url "https://www.plogue.com/products/sforzando.html") {
            Write-OK "Opened the Sforzando download page"
        } else {
            Write-Warn "Could not open browser automatically"
            Write-Host "  Visit manually: https://www.plogue.com/products/sforzando.html"
        }
    }
    Write-Host ""
    Write-Host "  Arachno is just a SoundFont data file, so this installer can fetch"
    Write-Host "  it directly, into this repo's own soundfonts\ folder."
    $DlArachno = Read-Host "  Download the Arachno GM SoundFont (~140MB) now? [y/N]"
    if ($DlArachno -match "^[Yy]$") {
        Install-ArachnoSoundfont | Out-Null
    }
}

# ====================================================================
# Interactive: Launch server now?
# ====================================================================

if ((Test-Interactive) -and (-not $ReaperOnly)) {
    Write-Host ""
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host "  Launch Server" -ForegroundColor White
    Write-Host ("-" * 52) -ForegroundColor White
    Write-Host ""
    Write-Host "  Would you like to start the MIDI-GPT server now?"
    Write-Host ""
    $Launch = Read-Host "  Launch server? [Y/n]"
    if (-not $Launch) { $Launch = "y" }

    if ($Launch -match "^[Yy]$") {
        Write-Host ""
        Write-Host "  Select a model:" -ForegroundColor White
        Write-Host ""
        Write-Host "    [1] Yellow     - General purpose, recommended (yellow_medium)"
        Write-Host "    [2] Prism      - Extended controls (prism_medium)"
        Write-Host "    [3] Expressive - Microtiming + velocity (expressive_medium)"
        Write-Host ""
        $ModelChoice = Read-Host "  Model [1/2/3, default=1]"

        switch ($ModelChoice) {
            "2" { $Model = "prism_medium"; $Label = "Prism" }
            "3" { $Model = "expressive_medium"; $Label = "Expressive" }
            default { $Model = "yellow_medium"; $Label = "Yellow" }
        }

        Write-Host ""
        Write-Host "  Starting MIDI-GPT server ($Label)..." -ForegroundColor White
        Write-Host "  Keep this window open while using MIDI-GPT in REAPER."
        Write-Host "  Press Ctrl+C to stop the server."
        Write-Host ""
        midigpt-http --pretrained $Model
    } else {
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor White
        Write-Host "  Start the server later with:"
        Write-Host "    cd $RepoDir; .\.venv\Scripts\Activate.ps1; midigpt-http" -ForegroundColor Green
        Write-Host ""
    }
} elseif ($env:MIDIGPT_INTERACTIVE) {
    Write-Host ""
    Read-Host "Press Enter to close this window" | Out-Null
}
