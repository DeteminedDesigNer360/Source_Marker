@echo off
rem ============================================================
rem  Source Marker (merged package) -- one-click INSTALL
rem
rem  Deliberately ASCII-only and BOM-less:
rem    * a BOM would break "@echo off"
rem    * non-ASCII bytes in a .cmd get mangled by the ANSI code page
rem  All Chinese output lives in install-united.ps1 instead.
rem ============================================================
setlocal
set "PS1=%~dp0install-united.ps1"
if not exist "%PS1%" (
  echo [ERROR] install-united.ps1 was not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 (
  echo.
  echo [FAILED] exit code %errorlevel%
  pause
)
endlocal
