@echo off
rem 把视频/文件夹拖到本文件上 = 用本包里的 mpv 打开（带 Source Markers 插件）
setlocal
set "MPV=%~dp0mpv.exe"
if not exist "%MPV%" (
  echo [错误] 找不到 "%MPV%"
  echo 请确认 mpv.exe 与本文件在同一个文件夹里。
  pause
  exit /b 1
)
if "%~1"=="" (
  echo 用法：把视频文件拖到本文件上；或先双击本文件再在 mpv 里按 O 打开文件。
  start "" "%MPV%"
) else (
  start "" "%MPV%" %*
)
