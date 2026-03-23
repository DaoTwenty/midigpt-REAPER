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
    [string]$MmmZip = "",
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ── Config ──────────────────────────────────────────────────────
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = Join-Path $RepoDir ".venv"
$PythonMinVersion = "3.10"
$MmmZipUrl = "PLACEHOLDER_URL"
$MmmBuildDir = Join-Path $env:TEMP "mmm-refactored-build"

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
    Write-Host "  -MmmZip PATH         Use a local mmm_refactored zip instead of downloading"
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

# Auto-detect bundled mmm_refactored.zip
$BundledZip = Join-Path $RepoDir "mmm_refactored.zip"
if (-not $MmmZip -and (Test-Path $BundledZip)) {
    $MmmZip = $BundledZip
}

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

    # -- cmake --
    if (Test-Command "cmake") {
        Write-OK "cmake found"
    } else {
        $Missing += "cmake"
        Write-Warn "cmake not found"
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
                    "cmake" {
                        if ($Installer -eq "winget") { winget install Kitware.CMake --accept-package-agreements --accept-source-agreements }
                        else { choco install cmake -y }
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

Write-Info "Checking PyTorch..."
$TorchCheck = python -c "import torch" 2>&1
if ($LASTEXITCODE -eq 0) {
    $TorchVer = python -c "import torch; print(torch.__version__)"
    Write-OK "PyTorch $TorchVer already installed"
} else {
    Write-Info "Installing PyTorch (this may take a few minutes)..."
    pip3 install torch torchvision -q
    $TorchVer = python -c "import torch; print(torch.__version__)"
    Write-OK "PyTorch $TorchVer installed"
}

Write-Info "Installing build dependencies..."
pip install scikit-build-core pybind11 -q
Write-OK "Build dependencies ready"

# ====================================================================
# Step 3: Build mmm_refactored C++ Backend
# ====================================================================

Write-Step "Step 3/6: Building mmm_refactored C++ backend"

$MmmCheck = python -c "import mmm_refactored" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "mmm_refactored already installed"
} else {
    # -- Resolve zip source --
    $MmmZipTmp = Join-Path $env:TEMP "mmm_refactored.zip"

    if ($MmmZip) {
        if (-not (Test-Path $MmmZip)) { Write-Fail "Local zip not found: $MmmZip" }
        Write-Info "Using local archive: $MmmZip"
        Copy-Item $MmmZip $MmmZipTmp -Force
        Write-OK "Copied"
    } else {
        if ($MmmZipUrl -eq "PLACEHOLDER_URL") {
            Write-Host ""
            Write-Host "  The MMM Refactored C++ backend is not yet configured for download."
            Write-Host ""
            Write-Host "  Either:"
            Write-Host "    1. Set the download URL in install.ps1 (`$MmmZipUrl variable)"
            Write-Host "    2. Pass a local zip file:  .\install.ps1 -MmmZip C:\path\to\mmm.zip"
            Write-Host ""
            Write-Fail "No MMM Refactored source available."
        }
        Write-Info "Downloading MMM Refactored archive..."
        Invoke-WebRequest -Uri $MmmZipUrl -OutFile $MmmZipTmp
        Write-OK "Downloaded"
    }

    # -- Unzip --
    Write-Info "Extracting archive..."
    if (Test-Path $MmmBuildDir) { Remove-Item $MmmBuildDir -Recurse -Force }
    Expand-Archive -Path $MmmZipTmp -DestinationPath $MmmBuildDir

    # Handle single top-level folder
    $Contents = Get-ChildItem $MmmBuildDir
    if ($Contents.Count -eq 1 -and $Contents[0].PSIsContainer) {
        $MmmSrcDir = $Contents[0].FullName
        Write-Info "Source directory: $($Contents[0].Name)"
    } else {
        $MmmSrcDir = $MmmBuildDir
    }

    # Verify
    if (-not (Test-Path (Join-Path $MmmSrcDir "CMakeLists.txt"))) {
        Write-Fail "Extracted archive doesn't look like mmm_refactored"
    }
    Write-OK "Archive extracted"

    # -- Build --
    $Pybind11Dir = python -c "import pybind11; print(pybind11.get_cmake_dir())" 2>$null
    $CmakeArgs = "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    if ($Pybind11Dir) {
        $CmakeArgs += " -Dpybind11_DIR=$Pybind11Dir"
        Write-Info "pybind11 cmake dir: $Pybind11Dir"
    }

    Write-Info "Building C++ extension (this takes 2-5 minutes)..."
    $env:CMAKE_ARGS = $CmakeArgs
    pip install $MmmSrcDir --no-build-isolation 2>&1 | Select-Object -Last 5

    # Verify
    $VerifyCheck = python -c "import mmm_refactored; print('mmm_refactored imported successfully')" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "mmm_refactored built and installed"
    } else {
        Write-Fail "mmm_refactored build failed. Check the output above for errors."
    }

    # Cleanup
    Remove-Item $MmmBuildDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $MmmZipTmp -Force -ErrorAction SilentlyContinue
    Write-Info "Cleaned up build files"
}

# Install remaining Python deps
Write-Info "Installing Python dependencies..."
pip install -e $RepoDir -q 2>$null
if ($LASTEXITCODE -ne 0) { pip install -e $RepoDir }
pip install symusic -q
Write-OK "Python dependencies installed"

# ====================================================================
# Step 4: REAPER Integration (Symlinks / Junctions)
# ====================================================================

Write-Step "Step 4/6: Setting up REAPER integration"

$ReaperDir = Join-Path $env:APPDATA "REAPER"

python (Join-Path $RepoDir "scripts\setup.py")

$ScriptsLink = Join-Path $ReaperDir "Scripts\MMM"
$EffectsLink = Join-Path $ReaperDir "Effects\MMM"

if ((Test-Path $ScriptsLink) -and (Test-Path $EffectsLink)) {
    Write-OK "REAPER symlinks created"
} else {
    Write-Warn "REAPER symlinks could not be verified (REAPER may not be installed yet)"
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
# Step 6: Model Checkpoint Validation
# ====================================================================

Write-Step "Step 6/6: Validating model setup"

$ModelConfig = Join-Path $RepoDir "src\Scripts\MMM\models\config.json"
$ModelDir = Join-Path $RepoDir "src\Scripts\MMM\models"

# Auto-copy bundled model.pt
$BundledModel = Join-Path $RepoDir "models\model.pt"
$TargetModel = Join-Path $ModelDir "model.pt"
if ((Test-Path $BundledModel) -and -not (Test-Path $TargetModel)) {
    Write-Info "Copying bundled model checkpoint..."
    Copy-Item $BundledModel $TargetModel
    Write-OK "Model copied to $TargetModel"
}

if (Test-Path $ModelConfig) {
    $CkptPath = python -c @"
import json, os
cfg = json.load(open(r'$ModelConfig'))
ckpt = cfg['ckpt']
if not os.path.isabs(ckpt):
    ckpt = os.path.join(os.path.dirname(os.path.abspath(r'$ModelConfig')), ckpt)
print(ckpt)
"@
    if (Test-Path $CkptPath) {
        $CkptSize = (Get-Item $CkptPath).Length / 1MB
        Write-OK ("Model checkpoint found: $CkptPath ({0:N0} MB)" -f $CkptSize)
    } else {
        Write-Warn "Model checkpoint not found at: $CkptPath"
        Write-Host ""
        Write-Host "  Place a model checkpoint (.pt file) at that path,"
        Write-Host "  or update src\Scripts\MMM\models\config.json"
    }
} else {
    Write-Warn "Model config not found at $ModelConfig"
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
Write-Host "     Select: $ReaperDir\Scripts\MMM\REAPER_mmm_infill.py"
Write-Host ""
Write-Host "  2. Add JSFX plugins:"
Write-Host "     - Add 'MMM Global Options' to Monitor FX (View > Monitoring Effects)"
Write-Host "     - Add 'MMM Track Options (Density-Polyphony)' to tracks you want to control"
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
