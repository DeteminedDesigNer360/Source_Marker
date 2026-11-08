@echo off
rem ============================================================
rem  Source Marker installer wrapper
rem  Double-click this file, or run:  install.cmd -User
rem
rem  Why this exists: double-clicking a .ps1 opens Notepad (not
rem  the script), and "Run with PowerShell" closes the window
rem  instantly on error. This wrapper bypasses the execution
rem  policy and pauses so failures stay visible.
rem ============================================================
setlocal
set "SCRIPT=%~dp0install.ps1"

if not exist "%SCRIPT%" (
  echo [ERROR] install.ps1 not found next to this file:
  echo         %SCRIPT%
  echo.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (echo Done. Exit code 0) else (echo [ERROR] Exit code %RC%)
echo.
pause
exit /b %RC%
