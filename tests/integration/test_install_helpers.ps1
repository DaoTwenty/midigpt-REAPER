# ============================================================================
# Unit tests for install.ps1's helper functions -- the logic behind the
# failure modes GitHub's windows-latest runners can't reproduce for real
# (they ship with the MSVC runtime preinstalled, so `import torch` never
# fails there), plus reaper.ini editing and the ReaImGui install check.
#
# Loads the functions straight out of install.ps1 via the PowerShell parser
# (without running the installer), so these test the shipped code, not a
# copy. `python` is replaced by a fake function where a test needs to
# control what the interpreter "prints".
#
# Usage:
#   powershell.exe -File .\tests\integration\test_install_helpers.ps1
#   pwsh ./tests/integration/test_install_helpers.ps1
# ============================================================================

$ErrorActionPreference = "Continue"

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

function Assert-Equal {
    param([string]$Desc, $Expected, $Actual)
    $script:Tests++
    if ($Expected -ceq $Actual) { Test-Pass $Desc }
    else {
        $Show = { param($s) "$s" -replace "`r", '\r' -replace "`n", '\n' }
        Test-Fail "$Desc`n        expected: $(& $Show $Expected)`n        actual:   $(& $Show $Actual)"
    }
}

# ── Load install.ps1's functions and the config they read ───────
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallPs1, [ref]$null, [ref]$ParseErrors)
if ($ParseErrors.Count -gt 0) {
    $ParseErrors | ForEach-Object { Write-Host $_.ToString() -ForegroundColor Red }
    Write-Host "install.ps1 has parse errors" -ForegroundColor Red
    exit 1
}
$Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$Ast.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                   "$($_.Left)" -in @('$VcRuntimeMinVersion', '$ReaImGuiVersion', '$ReaImGuiDll') } |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

# Fake `python`: each test sets $script:FakePython to a scriptblock that
# receives the -c code and returns @{ Out = lines; Exit = code }.
function python {
    $Code = $args[$args.Count - 1]
    $R = & $script:FakePython $Code
    $global:LASTEXITCODE = $R.Exit
    $R.Out
}

Write-Host ""
Write-Host "=== install.ps1 helper functions ===" -ForegroundColor White

# ============================================================================
Test-Scenario "Test-TorchDllLoadError"
# ============================================================================
# The exact line from a real Windows 10 VM without the MSVC runtime.
$Real126 = 'OSError: [WinError 126] The specified module could not be found. Error loading "C:\x\.venv\Lib\site-packages\torch\lib\c10.dll" or one of its dependencies.'
Assert-True "WinError 126 (c10.dll) is a DLL load error" { Test-TorchDllLoadError -Detail $Real126 }
Assert-True "WinError 1114 is a DLL load error" { Test-TorchDllLoadError -Detail 'OSError: [WinError 1114] A dynamic link library (DLL) initialization routine failed.' }
Assert-True "'DLL load failed' is a DLL load error" { Test-TorchDllLoadError -Detail 'ImportError: DLL load failed while importing _C: The specified module could not be found.' }
Assert-True "an unrelated ImportError is not" { -not (Test-TorchDllLoadError -Detail "ImportError: cannot import name 'x' from 'numpy'") }

# ============================================================================
Test-Scenario "Get-TorchState"
# ============================================================================
$script:FakePython = { param($c) if ($c -match "find_spec") { @{ Out = @(); Exit = 1 } } }
$S = Get-TorchState
Assert-Equal "torch not installed -> missing" "missing" $S.State

$script:FakePython = { param($c)
    if ($c -match "find_spec") { return @{ Out = @(); Exit = 0 } }
    @{ Out = @("2.14.0+cpu"); Exit = 0 }
}
$S = Get-TorchState
Assert-Equal "torch imports -> ok" "ok" $S.State
Assert-Equal "ok reports the version" "2.14.0+cpu" $S.Detail

# Installed but fails to load: the traceback, then torch's own hint lines
# printed *after* the error line -- the error line must still be picked.
$script:FakePython = { param($c)
    if ($c -match "find_spec") { return @{ Out = @(); Exit = 0 } }
    @{ Exit = 1; Out = @(
        "Traceback (most recent call last):",
        '  File "<string>", line 1, in <module>',
        "    raise err",
        $Real126,
        "Microsoft Visual C++ Redistributable is not installed, this may lead to the DLL load failure.",
        "It can be downloaded at https://aka.ms/vs/17/release/vc_redist.x64.exe") }
}
$S = Get-TorchState
Assert-Equal "installed but fails on import -> broken (not missing)" "broken" $S.State
Assert-Equal "broken reports the OSError line, not torch's trailing hint" $Real126 $S.Detail
Assert-True "...which routes to the Visual C++ Runtime help" { Test-TorchDllLoadError -Detail $S.Detail }

# ============================================================================
Test-Scenario "Get-VcRuntimeArch"
# ============================================================================
$script:FakePython = { param($c) @{ Out = @("AMD64"); Exit = 0 } }
Assert-Equal "x64 Python -> x64 runtime" "x64" (Get-VcRuntimeArch -Py "python")
$script:FakePython = { param($c) @{ Out = @("ARM64"); Exit = 0 } }
Assert-Equal "ARM64 Python -> arm64 runtime" "arm64" (Get-VcRuntimeArch -Py "python")

# ============================================================================
Test-Scenario "Set-ReaperIniKey"
# ============================================================================
function Set-Both { param($Content)
    $C = Set-ReaperIniKey -Key "reascript" -Value "1" -Content $Content
    Set-ReaperIniKey -Key "pythonlibdll64" -Value "C:\Py\python312.dll" -Content $C
}

# What REAPER itself writes on Windows: lowercase header, CRLF.
Assert-Equal "real-world ini (lowercase [reaper], CRLF): keys go inside the existing section" `
    "[reaper]`r`npythonlibdll64=C:\Py\python312.dll`r`nreascript=1`r`nfoo=1`r`n[other]`r`nx=2`r`n" `
    (Set-Both "[reaper]`r`nfoo=1`r`n[other]`r`nx=2`r`n")

Assert-Equal "existing keys are updated in place, CRLF kept" `
    "[reaper]`r`nreascript=1`r`npythonlibdll64=C:\Py\python312.dll`r`nfoo=1`r`n" `
    (Set-Both "[reaper]`r`nreascript=0`r`npythonlibdll64=C:\old.dll`r`nfoo=1`r`n")

Assert-Equal "uppercase [REAPER] + LF file: same section, LF kept" `
    "[REAPER]`npythonlibdll64=C:\Py\python312.dll`nreascript=1`nfoo=1`n" `
    (Set-Both "[REAPER]`nfoo=1`n")

Assert-Equal "no [reaper] section yet: one is appended (CRLF)" `
    "[other]`r`nx=2`r`n`r`n[reaper]`r`npythonlibdll64=C:\Py\python312.dll`r`nreascript=1`r`n" `
    (Set-Both "[other]`r`nx=2`r`n")

Assert-Equal "empty file: [reaper] section created" `
    "[reaper]`r`npythonlibdll64=C:\Py\python312.dll`r`nreascript=1`r`n" `
    (Set-Both "")

Assert-Equal "running twice is idempotent" (Set-Both "[reaper]`r`nfoo=1`r`n") (Set-Both (Set-Both "[reaper]`r`nfoo=1`r`n"))

$Accented = "[reaper]`r`nlastproject=C:\Users\Jos$([char]0xE9)\Ma$([char]0xF1)ana.rpp`r`n"
Assert-True "non-ASCII lines are preserved" { (Set-Both $Accented).Contains("Jos$([char]0xE9)\Ma$([char]0xF1)ana.rpp") }

# ============================================================================
Test-Scenario "Get-ReaImGuiChecksums (codeberg publishes none today -- fake its API)"
# ============================================================================
function Invoke-RestMethod { & $script:FakeApi }
$script:FakeApi = { [pscustomobject]@{ assets = @(
    [pscustomobject]@{ name = "reaper_imgui-x64.dll"; sha256 = "ABC123" },
    [pscustomobject]@{ name = "imgui.py"; digest = "sha256:def456" },
    [pscustomobject]@{ name = "gfx2imgui.lua" }) } }
$Sums = Get-ReaImGuiChecksums
Assert-Equal "a 'sha256' field is used (lowercased)" "abc123" $Sums["reaper_imgui-x64.dll"]
Assert-Equal "a GitHub-style 'digest' field is used" "def456" $Sums["imgui.py"]
Assert-True "an asset with no checksum gets none (-> installed unverified)" { -not $Sums.ContainsKey("gfx2imgui.lua") }
$script:FakeApi = { throw "network down" }
Assert-True "API unreachable -> no checksums, no error" { (Get-ReaImGuiChecksums).Count -eq 0 }
Remove-Item Function:\Invoke-RestMethod

# ============================================================================
Test-Scenario "Test-ReaImGuiInstalled"
# ============================================================================
$Fake = Join-Path ([System.IO.Path]::GetTempPath()) "midigpt-helpers-test-$([System.Guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $Fake -Force | Out-Null
    Assert-True "nothing installed -> not installed" { -not (Test-ReaImGuiInstalled -ReaperDir $Fake) }

    New-Item -ItemType Directory -Path (Join-Path $Fake "UserPlugins") -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $Fake "UserPlugins\$ReaImGuiDll") -Force | Out-Null
    Assert-True "DLL but no imgui.py -> not installed (dashboard's import would fail)" { -not (Test-ReaImGuiInstalled -ReaperDir $Fake) }

    New-Item -ItemType Directory -Path (Join-Path $Fake "Scripts\ReaTeam Extensions\API") -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $Fake "Scripts\ReaTeam Extensions\API\imgui.py") -Force | Out-Null
    Assert-True "DLL + imgui.py -> installed (Lua shims are optional)" { Test-ReaImGuiInstalled -ReaperDir $Fake }
} finally {
    Remove-Item -Path $Fake -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
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
