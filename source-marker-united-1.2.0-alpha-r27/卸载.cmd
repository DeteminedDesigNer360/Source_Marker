@echo off
rem ============================================================
rem  Source Marker (merged package) -- one-click UNINSTALL
rem
rem  ASCII-only and BOM-less on purpose (same reason as the
rem  installer wrapper: a BOM breaks "@echo off", and non-ASCII
rem  bytes in a .cmd get mangled by the ANSI code page).
rem ============================================================
setlocal
set "PS1=%~dp0install-united.ps1"
if not exist "%PS1%" (
  echo [ERROR] install-united.ps1 was not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall
if errorlevel 1 (
  echo.
  echo [FAILED] exit code %errorlevel%
  pause
)
endlocal
