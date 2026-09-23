# ============================================================================
# Integration test for the install pipeline (Windows / PowerShell)
#
# PowerShell counterpart to tests/integration/test_install.sh -- same
# reasoning, same verification steps. Verifies install.ps1 works end-to-end
# by:
#   1. Copying midigpt-REAPER into a temp directory
#   2. Locating the sibling MIDI-GPT directory (optional -- see below)
#   3. Running install.ps1 (all steps, including reaper.ini configuration,
#      against a throwaway REAPER dir)
#   4. Verifying imports (torch included), the REAPER Scripts junction,
#      ReaImGui, reaper.ini, that no unexpected warnings were logged, and
#      that unit tests pass
#
# What this can't cover: GitHub's windows-latest runners ship with the MSVC
# runtime preinstalled, so the missing-runtime path never runs here -- see
# test_install_helpers.ps1 and the clean-VM checklist in README.md.
#
# A sibling MIDI-GPT checkout is optional -- install.ps1 installs
# midigpt[http,inference] from PyPI first and only falls back to a sibling
# clone (or clones one itself from GitHub) if that fails, so this works
# fine on a CI runner with no local sibling checkout.
#
# Usage:
#   pwsh ./tests/integration/test_install.ps1
#   powershell.exe -File .\tests\integration\test_install.ps1
#   .\tests\integration\test_install.ps1 -Keep    # Keep temp dir on success
# ============================================================================

param(
    [switch]$Keep
)

# NOT "Stop" -- see install.ps1's own $ErrorActionPreference comment.
# This script shells out to robocopy/powershell.exe/python/pip/pytest too,
# and Windows PowerShell 5.1 promotes any of their stderr output into a
# terminating error under "Stop". Every failure this script cares about is
# already checked explicitly via $LASTEXITCODE or wrapped in try/finally.
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Resolve-Path (Join-Path $ScriptDir "..\..")
$MidigptSibling = Join-Path (Split-Path $RepoDir -Parent) "MIDI-GPT"

$script:Tests = 0
$script:Failures = 0

function Test-Pass { param($msg) Write-Host "  " -NoNewline; Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Test-Fail { param($msg) Write-Host "  " -NoNewline; Write-Host "FAIL " -ForegroundColor Red -NoNewline; Write-Host $msg; $script:Failures++ }
function Info { param($msg) Write-Host "-> " -ForegroundColor Yellow -NoNewline; Write-Host $msg }

function Assert-FileExists {
    param([string]$Desc, [string]$Path)
    $script:Tests++
    if (Test-Path $Path -PathType Leaf) { Test-Pass $Desc } else { Test-Fail $Desc }
}

function Assert-DirExists {
    param([string]$Desc, [string]$Path)
    $script:Tests++
    if (Test-Path $Path -PathType Container) { Test-Pass $Desc } else { Test-Fail $Desc }
}

Write-Host ""
Write-Host "=== Integration Test: install.ps1 ===" -ForegroundColor White
Write-Host ""

$HaveSibling = Test-Path $MidigptSibling -PathType Container

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "midigpt-install-test-$([System.Guid]::NewGuid())"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Info "Working directory: $WorkDir"

try {
    # -- Copy midigpt-REAPER --
    Info "Copying midigpt-REAPER into temp directory..."
    $CloneDir = Join-Path $WorkDir "midigpt-REAPER"
    robocopy $RepoDir $CloneDir /E /NFL /NDL /NJH /NJS /XD ".git" ".venv" "__pycache__" "*.egg-info" /XF "*.pt" "*.pth" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying repo (exit $LASTEXITCODE)" }
    Info "Copied to $CloneDir"

    if ($HaveSibling) {
        # We must also copy the sibling MIDI-GPT to the temp directory's
        # parent so the installer's sibling lookup works.
        $MidigptTestSibling = Join-Path $WorkDir "MIDI-GPT"
        Info "Copying MIDI-GPT sibling to $MidigptTestSibling ..."
        robocopy $MidigptSibling $MidigptTestSibling /E /NFL /NDL /NJH /NJS /XD ".git" ".venv" "__pycache__" | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying MIDI-GPT sibling (exit $LASTEXITCODE)" }
    } else {
        Info "No local MIDI-GPT sibling found at $MidigptSibling -- relying on install.ps1's PyPI install (with its own GitHub-clone fallback)"
    }

    # -- Run install.ps1 --
    Info "Running install.ps1 ..."
    Write-Host ""

    $InstallLog = Join-Path $WorkDir "install.log"
    # MIDIGPT_REAPER_DIR (see install.ps1) points the REAPER integration
    # steps at a throwaway directory instead of the real REAPER install, so
    # this test never touches the machine's actual REAPER config. It gets a
    # reaper.ini shaped like the one REAPER writes on Windows ([reaper],
    # CRLF) so Step 5 runs for real -- including its Python DLL lookup with
    # the venv active, which is what a normal install does and what
    # test_reaper_states.ps1's -ReaperOnly runs can't cover.
    $FakeReaperDir = Join-Path $WorkDir "fake-reaper"
    New-Item -ItemType Directory -Path $FakeReaperDir -Force | Out-Null
    $FakeIni = Join-Path $FakeReaperDir "reaper.ini"
    [System.IO.File]::WriteAllText($FakeIni, "[reaper]`r`nsomeoption=1`r`n[audioconfig]`r`nsrate=48000`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $env:MIDIGPT_REAPER_DIR = $FakeReaperDir
    # The fake REAPER dir isn't the running REAPER's, so a real REAPER open
    # on this machine (a developer's, say) mustn't make the installer skip
    # ReaPack/reaper.ini here.
    $env:MIDIGPT_FAKE_REAPER_RUNNING = "false"

    $InstallPs1 = Join-Path $CloneDir "install.ps1"
    & powershell.exe -ExecutionPolicy Bypass -File $InstallPs1 *> $InstallLog
    $InstallExit = $LASTEXITCODE
    Get-Content $InstallLog | Write-Host

    if ($InstallExit -eq 0) {
        Write-Host ""
        Test-Pass "install.ps1 completed successfully"
        $script:Tests++
    } else {
        Write-Host ""
        Test-Fail "install.ps1 exited with non-zero status ($InstallExit)"
        Write-Host ""
        Write-Host "Log: $InstallLog"
        Write-Host "INSTALL FAILED -- skipping remaining checks" -ForegroundColor Red
        Write-Host ""
        Write-Host "Results: 0/$($script:Tests) passed, $($script:Failures) failed" -ForegroundColor White
        exit 1
    }

    # -- Verification --
    Write-Host ""
    Write-Host "=== Verification ===" -ForegroundColor White
    Write-Host ""

    $VenvPython = Join-Path $CloneDir ".venv\Scripts\python.exe"

    # 1. Venv exists
    Assert-FileExists "Venv python exists" $VenvPython

    # 2. midigpt importable
    $script:Tests++
    & $VenvPython -c "import midigpt" 2>$null
    if ($LASTEXITCODE -eq 0) { Test-Pass "import midigpt" } else { Test-Fail "import midigpt" }

    # 3. midigpt.inference importable
    $script:Tests++
    & $VenvPython -c "from midigpt.inference.engine import InferenceEngine" 2>$null
    if ($LASTEXITCODE -eq 0) { Test-Pass "import midigpt.inference" } else { Test-Fail "import midigpt.inference" }

    # 4. torch actually loads (not just "is installed") -- the failure mode
    # a machine without the MSVC runtime hits.
    $script:Tests++
    & $VenvPython -c "import torch" 2>$null
    if ($LASTEXITCODE -eq 0) { Test-Pass "import torch" } else { Test-Fail "import torch" }

    # 5. REAPER Scripts junction, in the fake MIDIGPT_REAPER_DIR set above
    # (not a real REAPER install).
    Assert-DirExists "REAPER Scripts junction exists" (Join-Path $FakeReaperDir "Scripts\MIDI-GPT")

    # 6. ReaImGui: the extension DLL plus the Python API the dashboard imports.
    Assert-FileExists "ReaImGui DLL installed" (Join-Path $FakeReaperDir "UserPlugins\reaper_imgui-x64.dll")
    Assert-FileExists "ReaImGui Python API installed (imgui.py)" (Join-Path $FakeReaperDir "Scripts\ReaTeam Extensions\API\imgui.py")

    # 7. reaper.ini: keys in the existing [reaper] section (the only one
    # REAPER reads), pointing at the base Python's DLL -- not the venv's
    # directory, which has none.
    $IniRaw = [System.IO.File]::ReadAllText($FakeIni)
    $script:Tests++
    if (([regex]::Matches($IniRaw, '(?im)^\[reaper\]')).Count -eq 1) { Test-Pass "reaper.ini has exactly one [reaper] section" } else { Test-Fail "reaper.ini has a duplicate [reaper]/[REAPER] section" }
    $SectionBody = [regex]::Match($IniRaw, '(?is)^\[reaper\]\r?\n(.*?)(?=^\[|\z)', 'Multiline').Groups[1].Value
    $script:Tests++
    if ($SectionBody -match '(?m)^reascript=1\r?$') { Test-Pass "reascript=1 inside [reaper]" } else { Test-Fail "reascript=1 inside [reaper]" }
    # REAPER's format: pythonlibpath64 = directory, pythonlibdll64 = bare
    # file name (a full path there -> "No compatible version of Python was
    # found").
    $LibDir = [regex]::Match($SectionBody, '(?m)^pythonlibpath64=([^\r\n]*)').Groups[1].Value
    $LibFile = [regex]::Match($SectionBody, '(?m)^pythonlibdll64=([^\r\n]*)').Groups[1].Value
    $script:Tests++
    if ($LibFile -match '^python3\d+\.dll$') { Test-Pass "pythonlibdll64 is a bare file name ($LibFile)" } else { Test-Fail "pythonlibdll64 should be a bare python3XX.dll file name (got '$LibFile')" }
    $script:Tests++
    if ($LibDir -and $LibFile -and (Test-Path (Join-Path $LibDir $LibFile) -PathType Leaf) -and ($LibDir -notmatch '\\\.venv(\\|$)')) {
        Test-Pass "pythonlibpath64 inside [reaper] is the base Python's directory ($LibDir)"
    } else {
        Test-Fail "pythonlibpath64\pythonlibdll64 should be an existing base-Python DLL outside the venv (got '$LibDir' / '$LibFile')"
    }
    $script:Tests++
    if ($IniRaw -notmatch "[^`r]`n") { Test-Pass "reaper.ini kept its CRLF line endings" } else { Test-Fail "reaper.ini has bare LF line endings" }

    # 8. No unexpected warnings. install.ps1 deliberately exits 0 when a
    # step fails but has a manual fallback -- a [WARN] line is the only
    # trace of that, so every warning a clean install can legitimately
    # print is listed here and anything else fails the test.
    $AllowedWarnings = @(
        # codeberg publishes no checksums for ReaImGui (see install.ps1).
        "No published checksum for ReaImGui"
    )
    $Unexpected = @(Get-Content $InstallLog | Where-Object { $_ -match '^\[WARN\]' } | Where-Object {
        $Line = $_
        -not ($AllowedWarnings | Where-Object { $Line.Contains($_) })
    })
    $script:Tests++
    if ($Unexpected.Count -eq 0) {
        Test-Pass "no unexpected [WARN] lines in the install log"
    } else {
        Test-Fail "unexpected [WARN] lines in the install log:"
        $Unexpected | ForEach-Object { Write-Host "        $_" }
    }

    # 9. Run unit tests
    Write-Host ""
    Info "Installing pytest and running unit tests..."
    $script:Tests++
    & $VenvPython -m pip install pytest -q
    Push-Location $CloneDir
    try {
        # -k filter matches the dedicated unit-tests CI job: test_piano_default
        # is a known pre-existing failure unrelated to install correctness
        # (see .github/workflows/test-install.yml for why).
        & $VenvPython -m pytest tests/ -v --tb=short -k "not test_piano_default"
        $PytestExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($PytestExit -eq 0) { Test-Pass "Unit tests passed" } else { Test-Fail "Unit tests failed" }

    # -- Summary --
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor White
    $Passed = $script:Tests - $script:Failures
    if ($script:Failures -eq 0) {
        Write-Host "  ALL PASSED: $Passed/$($script:Tests) tests" -ForegroundColor Green
    } else {
        Write-Host "  $($script:Failures) FAILED: $Passed/$($script:Tests) tests passed" -ForegroundColor Red
    }
    Write-Host "======================================================" -ForegroundColor White
    Write-Host ""

    exit $script:Failures
} finally {
    Remove-Item Env:\MIDIGPT_REAPER_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\MIDIGPT_FAKE_REAPER_RUNNING -ErrorAction SilentlyContinue
    if (-not $Keep) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host ""
        Info "Temp directory preserved: $WorkDir"
    }
}
