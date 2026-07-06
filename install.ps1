# ============================================================================
# MIDI-GPT for REAPER — Windows Installer (PowerShell)
#
# Installs everything needed to run MIDI-GPT in REAPER:
#   1. System dependencies (cmake, protobuf, python) via winget or choco
#   2. Python virtual environment + torch
#   3. mmm_refactored C++ backend (built from source via pip)
#   4. REAPER integration (symlinks/junctions)
#   5. REAPER Python/ReaScript configuration
#   6. Model checkpoint validation
#
# Usage:
#   .\install.ps1                              # Full install
#   .\install.ps1 -SkipDeps                    # Skip dependency check
#   .\install.ps1 -MmmZip C:\path\to\mmm.zip   # Use local zip
#   .\install.ps1 -SkipReaperConfig            # Don't modify reaper.ini
# ============================================================================

param(
    [switch]$SkipDeps,
    [switch]$SkipReaperConfig,
    [string]$MidigptSrc = "",
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ── Config ──────────────────────────────────────────────────────
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $RepoDir ".venv"
$PythonMinVersion = "3.10"

# ── Helpers ─────────────────────────────────────────────────────

function Write-Info    { param($msg) Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $msg }
function Write-OK      { param($msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn    { param($msg) Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Fail    { param($msg) Write-Host "[ERROR] " -ForegroundColor Red -NoNewline; Write-Host $msg; exit 1 }

function Write-Step {
    param($msg)
    Write-Host ""
    Write-Host ("─" * 52) -ForegroundColor White
    Write-Host "  $msg" -ForegroundColor White
    Write-Host ("─" * 52) -ForegroundColor White
}

function Test-Command { param($cmd) $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# ── Help ────────────────────────────────────────────────────────

if ($Help) {
    Write-Host "MIDI-GPT for REAPER — Windows Installer"
    Write-Host ""
    Write-Host "Usage: .\install.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -SkipDeps            Skip system dependency check"
    Write-Host "  -SkipReaperConfig    Skip automatic REAPER Python/ReaScript configuration"
    Write-Host "  -MidigptSrc PATH     Path to MIDI-GPT source repo (sibling folder by default)"
    Write-Host "  -Help                Show this help"
    exit 0
}

# ── Banner ──────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor White
Write-Host "  ║     MIDI-GPT for REAPER Installer    ║" -ForegroundColor White
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor White
Write-Host ""
Write-Info "Platform: Windows"

# ====================================================================
# Step 1: System Dependencies
# ====================================================================

$PythonCmd = ""

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

        # Try winget first, then choco
        $Installer = $null
        if (Test-Command "winget") { $Installer = "winget" }
        elseif (Test-Command "choco") { $Installer = "choco" }

        if ($Installer) {
            Write-Info "Installing via $Installer..."
            foreach ($dep in $Missing) {
                switch ($dep) {
                    "python>=3.10" {
                        if ($Installer -eq "winget") { winget install Python.Python.3.14 --accept-package-agreements --accept-source-agreements }
                        else { choco install python314 -y }
                    }
                    "git" {
                        if ($Installer -eq "winget") { winget install Git.Git --accept-package-agreements --accept-source-agreements }
                        else { choco install git -y }
                    }
                }
            }

            # Refresh PATH after install
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            # Re-detect python
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
            Write-Host "    winget install Kitware.CMake"
            Write-Host ""
            Write-Host "  Option 2 (chocolatey - https://chocolatey.org/):"
            Write-Host "    choco install python312 cmake git -y"
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
# Step 2: Virtual Environment + Torch
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
    pip install --upgrade pip setuptools wheel -q
    Write-OK "Created and activated venv at $VenvDir"
}

# ====================================================================
# Step 3: Install MIDI-GPT Backend
# ====================================================================

Write-Step "Step 3/6: Installing MIDI-GPT backend"

$MidigptSibling = Join-Path (Split-Path $RepoDir -Parent) "MIDI-GPT"

if ($MidigptSrc -and (Test-Path $MidigptSrc)) {
    Write-Info "Installing midigpt[http,inference] from source: $MidigptSrc ..."
    pip install -e "${MidigptSrc}[http,inference]" 2>&1
} elseif (Test-Path $MidigptSibling) {
    Write-Info "Installing midigpt[http,inference] from sibling repo: $MidigptSibling ..."
    pip install -e "${MidigptSibling}[http,inference]" 2>&1
} else {
    Write-Info "Installing midigpt[http,inference] from PyPI ..."
    $PyPIResult = pip install "midigpt[http,inference]" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "PyPI install failed — falling back to cloning MIDI-GPT from GitHub ..."
        $MidigptClone = Join-Path (Split-Path $RepoDir -Parent) "MIDI-GPT"
        if (-not (Test-Path (Join-Path $MidigptClone ".git"))) {
            git clone https://github.com/Metacreation-Lab/MIDI-GPT.git $MidigptClone
            if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to clone MIDI-GPT. Check your internet connection." }
        } else {
            Write-Info "Existing MIDI-GPT clone found at $MidigptClone"
        }
        pip install -e "${MidigptClone}[http,inference]" 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Fail "Source install from cloned MIDI-GPT also failed." }
    }
}

$VerifyCheck = python -c "from midigpt.inference.engine import InferenceEngine" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "midigpt backend installed successfully"
} else {
    Write-Fail "midigpt backend installation failed."
}

Write-Info "Installing plugin dependencies..."
pip install -e $RepoDir -q 2>$null
if ($LASTEXITCODE -ne 0) { pip install -e $RepoDir }
Write-OK "Plugin dependencies installed"

# ====================================================================
# Step 4: REAPER Integration (Symlinks / Junctions)
# ====================================================================

Write-Step "Step 4/6: Setting up REAPER integration"

$ReaperDir = Join-Path $env:APPDATA "REAPER"

function New-ReaperJunction {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { return }
    $DstParent = Split-Path $Dst -Parent
    if (-not (Test-Path $DstParent)) { New-Item -ItemType Directory -Path $DstParent -Force | Out-Null }
    if (Test-Path $Dst) { cmd /c "rmdir `"$Dst`"" 2>$null; Remove-Item $Dst -Recurse -Force -ErrorAction SilentlyContinue }
    cmd /c "mklink /J `"$Dst`" `"$Src`"" | Out-Null
}

if (Test-Path $ReaperDir) {
    New-ReaperJunction (Join-Path $RepoDir "src\Scripts\MIDI-GPT") (Join-Path $ReaperDir "Scripts\MIDI-GPT")
    New-ReaperJunction (Join-Path $RepoDir "src\Effects\MIDI-GPT") (Join-Path $ReaperDir "Effects\MIDI-GPT")
    Write-OK "REAPER junctions created"
} else {
    Write-Warn "REAPER config directory not found — REAPER may not be installed yet"
}

# ====================================================================
# Step 5: Configure REAPER for Python / ReaScript
# ====================================================================

if ($SkipReaperConfig) {
    Write-Step "Step 5/6: Skipping REAPER config (-SkipReaperConfig)"
} else {
    Write-Step "Step 5/6: Configuring REAPER (reaper.ini)"

    $ReaperIni = Join-Path $ReaperDir "reaper.ini"

    # Detect Python DLL
    $PythonDll = python -c @"
import sys, pathlib
base = pathlib.Path(sys.exec_prefix)
ver = f'{sys.version_info.major}{sys.version_info.minor}'
for p in base.glob(f'python{ver}.dll'):
    print(p); break
"@ 2>$null

    if (Test-Path $ReaperIni) {
        # Check if REAPER is running
        $ReaperProc = Get-Process -Name "reaper" -ErrorAction SilentlyContinue
        if ($ReaperProc) {
            Write-Warn "REAPER is currently running!"
            Write-Host "  REAPER overwrites reaper.ini on quit, so changes would be lost."
            Write-Host "  Please quit REAPER and re-run this installer."
            if ($PythonDll) { Write-Host "  Python library: $PythonDll" }
        } elseif ($PythonDll -and (Test-Path $PythonDll)) {
            # Back up
            Copy-Item $ReaperIni "$ReaperIni.midigpt-backup"
            Write-Info "Backed up reaper.ini"

            $IniContent = Get-Content $ReaperIni -Raw

            function Set-ReaperIni {
                param($Key, $Value, $Content)
                if ($Content -match "(?m)^$Key=.*$") {
                    $Content = $Content -replace "(?m)^$Key=.*$", "$Key=$Value"
                } else {
                    $Content = $Content -replace "(?m)(\[REAPER\])", "`$1`n$Key=$Value"
                }
                return $Content
            }

            $IniContent = Set-ReaperIni "reascript" "1" $IniContent
            $IniContent = Set-ReaperIni "pythonlibdll64" $PythonDll $IniContent

            Set-Content -Path $ReaperIni -Value $IniContent -NoNewline
            Write-OK "ReaScript enabled (reascript=1)"
            Write-OK "Python library: $PythonDll"
        } else {
            Write-Warn "Could not detect Python DLL path"
            Write-Host "  Configure manually: Options > Preferences > Plug-Ins > ReaScript"
        }
    } else {
        if (Test-Path $ReaperDir) {
            Write-Warn "reaper.ini not found — REAPER may not have been launched yet"
        } else {
            Write-Warn "REAPER config directory not found — REAPER may not be installed"
        }
        if ($PythonDll) {
            Write-Host "  When ready, set the Python library path to:"
            Write-Host "    $PythonDll" -ForegroundColor Green
        }
    }
}

# ====================================================================
# Step 6: Verify Backend Installation
# ====================================================================

Write-Step "Step 6/6: Verifying backend installation"

$VerifyCheck = python -c "from midigpt.inference.engine import InferenceEngine" 2>&1
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
}

# ====================================================================
# Final
# ====================================================================

Write-Host ""
Write-Host ("═" * 52) -ForegroundColor White
Write-Host "  Installation Complete!" -ForegroundColor Green
Write-Host ("═" * 52) -ForegroundColor White
Write-Host ""

Write-Host "Next steps in REAPER:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Load the ReaScript action:"
Write-Host "     Actions > Show Action List > Load ReaScript"
Write-Host "     Select: $ReaperDir\Scripts\MIDI-GPT\REAPER_midigpt_infill.py"
Write-Host ""
Write-Host "  2. Add JSFX plugins:"
Write-Host "     - Add 'MIDI-GPT Global Options' to Monitor FX (View > Monitoring Effects)"
Write-Host "     - Add 'MIDI-GPT Track Options (Yellow-Ghost)' or 'MIDI-GPT Track Options (Expressive)' to tracks"
Write-Host ""
Write-Host "To start the server:" -ForegroundColor White
Write-Host "  Double-click " -NoNewline
Write-Host "Start MIDI-GPT Server" -ForegroundColor Green -NoNewline
Write-Host " on your Desktop"
Write-Host ""

# Keep window open when launched from double-click
if ($env:MIDIGPT_INTERACTIVE) {
    Write-Host ""
    Read-Host "Press Enter to close this window"
}
