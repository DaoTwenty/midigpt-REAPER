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
# Assertions check the resulting files, not just log wording: the installer
# deliberately exits 0 with a [WARN] when something it tried failed, so
# "the log mentions X" passes whether X succeeded or not.
#
# The -ReaperOnly path never activates the venv, so Step 5's Python DLL
# lookup under an active venv is covered by test_install.ps1 instead.
#
# This hits the real network for ReaPack's GitHub release and ReaImGui's
# codeberg release (to test the actual download paths for real) --
# everything else here is local file state.
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

# Plain substring match -- not -like, which treats [ ] in the needle as a
# wildcard character class (so "[audioconfig]" would never match itself).
function Test-FileContains {
    param([string]$FilePath, [string]$Needle)
    return [System.IO.File]::ReadAllText($FilePath).Contains($Needle)
}

function Assert-Contains {
    param([string]$Desc, [string]$FilePath, [string]$Needle)
    $script:Tests++
    if ((Test-Path $FilePath) -and (Test-FileContains $FilePath $Needle)) {
        Test-Pass $Desc
    } else {
        Test-Fail $Desc
    }
}

function Assert-NotContains {
    param([string]$Desc, [string]$FilePath, [string]$Needle)
    $script:Tests++
    if ((Test-Path $FilePath) -and -not (Test-FileContains $FilePath $Needle)) {
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

# Key=value pairs of reaper.ini's first [reaper] section (header matched
# case-insensitively, as REAPER does) -- i.e. what REAPER actually reads.
# Keys written into any other section, or a duplicate [REAPER] section
# further down, don't count.
function Get-ReaperSection {
    param([string]$IniPath)
    $Keys = @{}
    $InSection = $false
    $SeenSection = $false
    foreach ($Line in [System.IO.File]::ReadAllLines($IniPath)) {
        if ($Line -match '^\[(.*)\]\s*$') {
            if ($SeenSection) { break }
            $InSection = ($Matches[1] -eq "reaper")
            if ($InSection) { $SeenSection = $true }
            continue
        }
        if ($InSection -and $Line -match '^([^=]+)=(.*)$') { $Keys[$Matches[1]] = $Matches[2] }
    }
    return $Keys
}

# The shape checks every reaper.ini the installer touched must pass.
function Assert-IniWellFormed {
    param([string]$Label, [string]$IniPath)
    $Raw = [System.IO.File]::ReadAllText($IniPath)
    $script:Tests++
    $Headers = ([regex]::Matches($Raw, '(?im)^\[reaper\]')).Count
    if ($Headers -eq 1) { Test-Pass "$Label -- no duplicate [REAPER] section" } else { Test-Fail "$Label -- $Headers [reaper]/[REAPER] headers" }
    $Section = Get-ReaperSection $IniPath
    Assert-True "$Label -- reascript=1 is inside the [reaper] section" { $Section["reascript"] -eq "1" }
    # REAPER's format: pythonlibpath64 = directory, pythonlibdll64 = bare
    # file name. A full path in pythonlibdll64 makes REAPER report "No
    # compatible version of Python was found".
    Assert-True "$Label -- pythonlibpath64 and pythonlibdll64 are inside the [reaper] section" {
        $Section.ContainsKey("pythonlibpath64") -and $Section.ContainsKey("pythonlibdll64")
    }
    Assert-True "$Label -- pythonlibdll64 is a bare python3XX.dll file name, not a path" { "$($Section["pythonlibdll64"])" -match '^python3\d+\.dll$' }
    Assert-True "$Label -- pythonlibpath64\pythonlibdll64 exists" {
        $Section["pythonlibpath64"] -and (Test-Path (Join-Path $Section["pythonlibpath64"] "$($Section["pythonlibdll64"])") -PathType Leaf)
    }
    Assert-False "$Label -- pythonlibpath64 isn't inside a venv" { "$($Section["pythonlibpath64"])" -match '\\\.venv(\\|$)' }
}

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "midigpt-reaper-states-test-$([System.Guid]::NewGuid())"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$Log = Join-Path $WorkDir "last_run.log"

function Invoke-Install {
    param([string]$FakeReaperDir, [string]$FakeRunning)
    $env:MIDIGPT_REAPER_DIR = $FakeReaperDir
    $env:MIDIGPT_FAKE_REAPER_RUNNING = $FakeRunning
    & powershell.exe -ExecutionPolicy Bypass -File $InstallPs1 -ReaperOnly *> $Log
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        Write-Host "  [install.ps1 exited $ExitCode -- log follows]" -ForegroundColor Magenta
        Get-Content $Log | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "  [end log]" -ForegroundColor Magenta
    }
    return $ExitCode
}

# Writes an ini with exact bytes (Set-Content would add its own line
# endings and, in Windows PowerShell 5.1, re-encode to ANSI).
function Write-Ini {
    param([string]$Path, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

$ImguiDll = "UserPlugins\reaper_imgui-x64.dll"
$ImguiPy = "Scripts\ReaTeam Extensions\API\imgui.py"

Write-Host ""
Write-Host "=== REAPER integration state matrix (install.ps1) ===" -ForegroundColor White

# ============================================================================
Test-Scenario "Fresh: REAPER dir doesn't exist at all"
# ============================================================================
$Fake = Join-Path $WorkDir "s1_missing"
$ExitCode = Invoke-Install $Fake "false"
Assert-True "install.ps1 exits 0 when REAPER isn't installed yet" { $ExitCode -eq 0 }
Assert-Contains "warns REAPER config dir not found" $Log "REAPER config directory not found"
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
Assert-Contains "ReaPack checksum-verified against GitHub's digest" $Log "ReaPack installed and checksum-verified"
Assert-True "ReaImGui DLL installed" { Test-Path (Join-Path $Fake $ImguiDll) -PathType Leaf }
Assert-True "ReaImGui Python API installed (imgui.py -- the dashboard imports it)" { Test-Path (Join-Path $Fake $ImguiPy) -PathType Leaf }
Assert-True "ReaImGui DLL is a real PE binary, not an error page" {
    $P = Join-Path $Fake $ImguiDll
    if (-not (Test-Path $P)) { return $false }
    $B = [System.IO.File]::ReadAllBytes($P)
    $B.Length -gt 100000 -and $B[0] -eq 0x4D -and $B[1] -eq 0x5A
}
Assert-NotContains "no 'ReaImGui not installed' warning" $Log "ReaImGui not installed"
Assert-Contains "reports reaper.ini not found (fresh REAPER, never launched)" $Log "reaper.ini not found"

# ============================================================================
Test-Scenario "Re-run on the same state (idempotency)"
# ============================================================================
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "second run detects ReaPack already installed (no re-download)" $Log "ReaPack already installed"
Assert-Contains "second run detects ReaImGui already installed" $Log "ReaImGui already installed"
Assert-NotContains "no ReaImGui re-download on re-run" $Log "Installing ReaImGui"
Assert-True "exactly one ReaPack binary present (no duplicate downloads)" { (Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -eq 1 }

# ============================================================================
Test-Scenario "Only the ReaImGui DLL present (e.g. older installer) -- repaired"
# ============================================================================
$Fake = Join-Path $WorkDir "s3_dll_only"
New-Item -ItemType Directory -Path (Join-Path $Fake "UserPlugins") -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $Fake $ImguiDll) -Force | Out-Null
Invoke-Install $Fake "false" | Out-Null
Assert-True "missing imgui.py gets installed" { Test-Path (Join-Path $Fake $ImguiPy) -PathType Leaf }
Assert-True "placeholder DLL replaced with the real one" { (Get-Item (Join-Path $Fake $ImguiDll)).Length -gt 100000 }
Assert-False "no __startup.lua written (direct download, no ReaPack bootstrap)" { Test-Path (Join-Path $Fake "Scripts\__startup.lua") }
Assert-True "ReaPack still installed independently" { (Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -gt 0 }

# ============================================================================
Test-Scenario "Pre-existing __startup.lua with unrelated user content (unchanged)"
# ============================================================================
$Fake = Join-Path $WorkDir "s4_user_startup"
New-Item -ItemType Directory -Path (Join-Path $Fake "Scripts") -Force | Out-Null
Set-Content -Path (Join-Path $Fake "Scripts\__startup.lua") -Value "-- my own startup stuff, unrelated to MIDI-GPT`nreaper.ShowConsoleMsg(`"hello from my own script`n`")"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "user's own startup content survives" (Join-Path $Fake "Scripts\__startup.lua") "hello from my own script"
Invoke-Install $Fake "false" | Out-Null
Assert-Contains "user's content still survives after a second run" (Join-Path $Fake "Scripts\__startup.lua") "hello from my own script"

# ============================================================================
Test-Scenario "REAPER 'running' (non-interactive) -- ReaPack/reaper.ini must be skipped"
# ============================================================================
$Fake = Join-Path $WorkDir "s5_running"
New-Item -ItemType Directory -Path $Fake -Force | Out-Null
Write-Ini (Join-Path $Fake "reaper.ini") "[reaper]`r`nsomeoption=1`r`n"
Invoke-Install $Fake "true" | Out-Null
Assert-True "junction still created (doesn't need REAPER closed)" { Test-Path (Join-Path $Fake "Scripts\MIDI-GPT") }
Assert-False "ReaPack NOT downloaded while REAPER is 'running'" { (Test-Path (Join-Path $Fake "UserPlugins")) -and ((Get-ChildItem -Path (Join-Path $Fake "UserPlugins") -Filter "reaper_reapack*" -ErrorAction SilentlyContinue).Count -gt 0) }
Assert-Contains "explains ReaPack was skipped because REAPER is open" $Log "REAPER is still open"
Assert-True "reaper.ini left untouched (REAPER would overwrite it on quit)" { [System.IO.File]::ReadAllText((Join-Path $Fake "reaper.ini")) -ceq "[reaper]`r`nsomeoption=1`r`n" }

# ============================================================================
Test-Scenario "reaper.ini as REAPER writes it on Windows ([reaper], CRLF)"
# ============================================================================
$Fake = Join-Path $WorkDir "s6_real_ini"
$Ini = Join-Path $Fake "reaper.ini"
$Original = "[reaper]`r`nsomeoption=1`r`notheroption=hello`r`n[audioconfig]`r`nsrate=48000`r`n"
Write-Ini $Ini $Original
Invoke-Install $Fake "false" | Out-Null
Assert-IniWellFormed "after first run" $Ini
Assert-True "unrelated options survive in their sections" { $S = Get-ReaperSection $Ini; $S["someoption"] -eq "1" -and $S["otheroption"] -eq "hello" }
Assert-Contains "other sections survive" $Ini "[audioconfig]`r`nsrate=48000"
Assert-False "no bare LF line endings introduced" { [System.IO.File]::ReadAllText($Ini) -match "[^`r]`n" }
Assert-True "reaper.ini.midigpt-backup holds the original bytes" { [System.IO.File]::ReadAllText("$Ini.midigpt-backup") -ceq $Original }

Invoke-Install $Fake "false" | Out-Null
Assert-IniWellFormed "after second run" $Ini
Assert-GrepCount "exactly one reascript= line after two runs" 1 "reascript=" $Ini
Assert-GrepCount "exactly one pythonlibdll64= line after two runs" 1 "pythonlibdll64=" $Ini

# ============================================================================
Test-Scenario "reaper.ini with uppercase [REAPER] header and LF endings"
# ============================================================================
$Fake = Join-Path $WorkDir "s7_uppercase_lf"
$Ini = Join-Path $Fake "reaper.ini"
Write-Ini $Ini "[REAPER]`nsomeoption=1`n"
Invoke-Install $Fake "false" | Out-Null
Assert-IniWellFormed "uppercase header" $Ini
Assert-False "LF file stays LF (no CRLF mixed in)" { [System.IO.File]::ReadAllText($Ini) -match "`r" }

# ============================================================================
Test-Scenario "reaper.ini with non-ASCII paths (UTF-8) survives byte-for-byte"
# ============================================================================
$Fake = Join-Path $WorkDir "s8_utf8"
$Ini = Join-Path $Fake "reaper.ini"
# Regression guard only: on a Windows-1252 machine (GitHub's runners, this
# test's usual home) even an ANSI read/write round trip happens to be
# byte-lossless, so this can't catch an encoding regression there -- it
# would on a multi-byte ANSI codepage (e.g. Japanese, cp932).
$Accented = "C:\Users\$([char]0xC1)lvaro Jos$([char]0xE9)\Ma$([char]0xF1)ana $([char]0x97F3)$([char]0x697D).rpp"
Write-Ini $Ini "[reaper]`r`nlastproject=$Accented`r`n"
Invoke-Install $Fake "false" | Out-Null
Assert-IniWellFormed "non-ASCII ini" $Ini
Assert-True "non-ASCII path unchanged" { (Get-ReaperSection $Ini)["lastproject"] -ceq $Accented }
Assert-False "no BOM added" { $B = [System.IO.File]::ReadAllBytes($Ini); $B[0] -eq 0xEF -and $B[1] -eq 0xBB }

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
