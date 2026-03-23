@echo off
REM ============================================================================
REM MIDI-GPT for REAPER — Windows Installer (double-click to run)
REM
REM This .bat file opens a terminal and runs the PowerShell installer.
REM ============================================================================

echo.
echo   ╔══════════════════════════════════════════════════╗
echo   ║         MIDI-GPT for REAPER — Installer         ║
echo   ║                                                  ║
echo   ║  This will install MIDI-GPT and all its         ║
echo   ║  dependencies. It takes about 5-10 minutes      ║
echo   ║  and may require an internet connection.         ║
echo   ╚══════════════════════════════════════════════════╝
echo.

REM Set flag so install.ps1 shows "Press Enter to close" at the end
set MIDIGPT_INTERACTIVE=1

REM Run the PowerShell installer (bypass execution policy for this script only)
powershell.exe -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*

if errorlevel 1 (
    echo.
    echo Installation encountered an error. Check the output above.
    echo.
    pause
)
