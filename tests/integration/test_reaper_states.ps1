# ============================================================================
# Stress test: install.ps1's REAPER integration (Step 4/5) across different
# starting states -- fresh, partial, already-configured, REAPER-running,
# re-run/idempotency -- without ever touching a real REAPER install.
#
# This is the PowerShell counterpart to
# tests/integration/test_reaper_states.sh -- same scenarios, same
# reasoning. See that file's header for the full explanation. In short:
# uses install.ps1 -ReaperOnly (skips venv/backend entirely -- fast, no
# PyTorch/MIDI-GPT download) plus two test-only env var overrides that
# install.ps1 itself supports for exactly this purpose:
#   MIDIGPT_REAPER_DIR           -- fake REAPER config dir instead of the
#                                    real one
#   MIDIGPT_FAKE_REAPER_RUNNING  -- true/false, simulates whether REAPER is
#                                    "running" without a real process
#
# This proves install.ps1 puts the right bytes/config in the right places
# for each starting state, correctly detects what's already there, and is
# idempotent. It does NOT and CANNOT prove REAPER itself loads any of this
# correctly -- that needs a real REAPER session.
#
# This does hit the real network for ReaPack's GitHub release (needed to
# test the actual download+checksum path for real) -- everything else here
# is local file state.
#
# Usage:
#   pwsh ./tests/integration/test_reaper_states.ps1
#   powershell.exe -File .\tests\integration\test_reaper_states.ps1
# ============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Resolve-Path (Join-Path $ScriptDir "..\..")
$InstallPs1 = Join-Path $RepoDir "install.ps1"

$script:Tests = 0
$script:Failures = 0

function Test-Pass { param($msg) Write-Host "  " -NoNewline; Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Test-Fail { param($msg) Write-Host "  " -NoNewline; Write-Host "FAIL " -ForegroundColor Red -NoNewline; Write-Host $msg; $script:Failures++ }
function Test-Scenario { param($msg) Write-Host ""; Write-Host "-- $msg --" -ForegroundColor White }

function Assert-True {
    param([string]$Desc, [scriptblock]$Condition)
    $script:Tests++
    if (& $Condition) { Test-Pass $Desc } else { Test-Fail $Desc }
}

function Assert-False {
    param([string]$Desc, [scriptblock]$Condition)
    $script:Tests++
    if (-not (& $Condition)) { Test-Pass $Desc } else { Test-Fail $Desc }
}

function Assert-Contains {
    param([string]$Desc, [string]$FilePath, [string]$Needle)
    $script:Tests++
    if ((Test-Path $FilePath) -and ((Get-Content $FilePath -Raw) -like "*$Needle*")) {
        Test-Pass $Desc
    } else {
        Test-Fail $Desc
    }
}

function Assert-GrepCount {
    param([string]$Desc, [int]$Expected, [string]$Needle, [string]$FilePath)
    $script:Tests++
    $Actual = 0
    if (Test-Path $FilePath) {
        $Actual = ([regex]::Matches((Get-Content $FilePath -Raw), [regex]::Escape($Needle))).Count
    }
    if ($Actual -eq $Expected) { Test-Pass "$Desc (found $Actual)" } else { Test-Fail "$Desc (expected $Expected, found $Actual)" }
}

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "midigpt-reaper-states-test-$([System.Guid]::NewGuid())"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Invoke-Install {
    param([string]$FakeReaperDir, [string]$FakeRunning)
    $env:MIDIGPT_REAPER_DIR = $FakeReaperDir
    $env:MIDIGPT_FAKE_REAPER_RUNNING = $FakeRunning
    $LogPath = Join-Path $WorkDir "last_run.log"
    & powershell.exe -ExecutionPolicy Bypass -File $InstallPs1 -ReaperOnly *> $LogPath
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        Write-Host "  [install.ps1 exited $ExitCode -- log follows]" -ForegroundColor Magenta
        Get-Content $LogPath | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "  [end log]" -ForegroundColor Magenta
    }
    return $ExitCode
}

Write-Host ""
Write-Host "=== REAPER integration state matrix (install.ps1) ===" -ForegroundColor White

# ============================================================================
Test-Scenario "Fresh: REAPER dir doesn't exist at all"
# ============================================================================
$Fake = Join-Path $WorkDir "s1_missing"
$ExitCode = Invoke-Install $Fake "false"
Assert-True "install.ps1 exits 0 when REAPER isn't installed yet" { $ExitCode -eq 0 }
Assert-Contains "warns REAPER config dir not found" (Join-Path $WorkDir "last_run.log") "REAPER config directory not found"
Assert-False "does not create the REAPER dir itself" { Test-Path $Fake }

# ============================================================================
Test-Scenario "Fresh: REAPER dir exists, nothing configured yet"
# ============================================================================
$Fake = Join-Path $WorkDir "s2_fresh"
New-Item -ItemType Directory -Path $Fake -Force | Out-Null
$ExitCode = Invoke-Install $Fake "false"
Assert-True "install.ps1 exits 0" { $ExitCode -eq 0 }
Assert-True "Scripts junction created" { Test-Path (Join-Path $Fake "Scripts\MIDI-GPT") }
Assert-True "ReaPack binary downloaded" { (Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -gt 0 }
Assert-Contains "ReaPack reported checksum-verified" (Join-Path $WorkDir "last_run.log") "checksum-verified"
# With direct ReaImGui download, no bootstrap is written
Assert-Contains "ReaImGui installed and checksum-verified" (Join-Path $WorkDir "last_run.log") "ReaImGui installed"
Assert-Contains "reports reaper.ini not found (fresh REAPER, never launched)" (Join-Path $WorkDir "last_run.log") "reaper.ini not found"

# ============================================================================
Test-Scenario "Re-run on the same state (idempotency)"
# ============================================================================
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "second run detects ReaPack already installed (no re-download)" (Join-Path $WorkDir "last_run.log") "ReaPack already installed"
# Direct download should detect ImGui already present, no bootstrap needed.
Assert-True "no duplicate ImGui install on re-run" { -not ((Get-Content (Join-Path $WorkDir "last_run.log")) -like "*Downloading ReaImGui*") }
Assert-True "exactly one ReaPack binary present (no duplicate downloads)" { (Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -eq 1 }

# ============================================================================
Test-Scenario "ReaImGui already installed -- no bootstrap created"
# ============================================================================
$Fake = Join-Path $WorkDir "s3_has_imgui"
New-Item -ItemType Directory -Path (Join-Path $Fake "UserPlugins") -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $Fake "UserPlugins\reaper_imgui.dll") -Force | Out-Null
Invoke-Install $Fake "false" | Out-Null
Assert-False "no __startup.lua written when ReaImGui already present (direct download)" { Test-Path (Join-Path $Fake "Scripts\__startup.lua") }
Assert-True "ReaPack still installed independently" { (Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -gt 0 }

# ============================================================================
Test-Scenario "Pre-existing __startup.lua with unrelated user content (unchanged)"
# ============================================================================
$Fake = Join-Path $WorkDir "s4_user_startup"
New-Item -ItemType Directory -Path (Join-Path $Fake "Scripts") -Force | Out-Null
Set-Content -Path (Join-Path $Fake "Scripts\__startup.lua") -Value "-- my own startup stuff, unrelated to MIDI-GPT`nreaper.ShowConsoleMsg(`"hello from my own script`n`")"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "user's own startup content survives" (Join-Path $Fake "Scripts\__startup.lua") "hello from my own script"
# With direct download, __startup.lua is never touched.
Assert-Contains "user's content still survives after a second run" (Join-Path $Fake "Scripts\__startup.lua") "hello from my own script"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "user's content still survives after a second run" (Join-Path $Fake "Scripts\__startup.lua") "hello from my own script"

# ============================================================================
Test-Scenario "REAPER 'running' (non-interactive) -- ReaPack/reaper.ini must be skipped"
# ============================================================================
$Fake = Join-Path $WorkDir "s5_running"
New-Item -ItemType Directory -Path $Fake -Force | Out-Null
Invoke-Install $Fake "true" | Out-Null
Assert-True "junction still created (doesn't need REAPER closed)" { Test-Path (Join-Path $Fake "Scripts\MIDI-GPT") }
Assert-False "ReaPack NOT downloaded while REAPER is 'running'" { (Test-Path (Join-Path $Fake "UserPlugins")) -and ((Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -gt 0) }
Assert-Contains "explains ReaPack was skipped because REAPER is open" (Join-Path $WorkDir "last_run.log") "REAPER is still open"

# ============================================================================
Test-Scenario "reaper.ini exists with unrelated content, REAPER not running"
# ============================================================================
$Fake = Join-Path $WorkDir "s6_existing_ini"
New-Item -ItemType Directory -Path $Fake -Force | Out-Null
Set-Content -Path (Join-Path $Fake "reaper.ini") -Value "[REAPER]`nsomeoption=1`notheroption=hello"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "unrelated pre-existing option survives" (Join-Path $Fake "reaper.ini") "someoption=1"
Assert-Contains "unrelated pre-existing option survives (2)" (Join-Path $Fake "reaper.ini") "otheroption=hello"
Assert-Contains "reascript=1 was added" (Join-Path $Fake "reaper.ini") "reascript=1"
Assert-Contains "pythonlibdll64 was added" (Join-Path $Fake "reaper.ini") "pythonlibdll64="
Assert-True "reaper.ini.midigpt-backup was created" { Test-Path (Join-Path $Fake "reaper.ini.midigpt-backup") }

Invoke-Install $Fake "false" | Out-Null
Assert-GrepCount "exactly one reascript= line after two runs" 1 "reascript=1" (Join-Path $Fake "reaper.ini")

# ============================================================================
Test-Scenario "reaper.ini with lowercase [reaper] section header"
# ============================================================================
$Fake = Join-Path $WorkDir "s7_lowercase_section"
New-Item -ItemType Directory -Path $Fake -Force | Out-Null
Set-Content -Path (Join-Path $Fake "reaper.ini") -Value "[reaper]`nsomeoption=1"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "reascript=1 added under lowercase [reaper] section" (Join-Path $Fake "reaper.ini") "reascript=1"

# ============================================================================
Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\MIDIGPT_REAPER_DIR -ErrorAction SilentlyContinue
Remove-Item Env:\MIDIGPT_FAKE_REAPER_RUNNING -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "======================================================" -ForegroundColor White
$Passed = $script:Tests - $script:Failures
if ($script:Failures -eq 0) {
    Write-Host "  ALL PASSED: $Passed/$($script:Tests) assertions" -ForegroundColor Green
} else {
    Write-Host "  $($script:Failures) FAILED: $Passed/$($script:Tests) assertions passed" -ForegroundColor Red
}
Write-Host "======================================================" -ForegroundColor White
Write-Host ""

exit $script:Failures
