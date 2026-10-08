# ensure-ps1-bom.ps1 —— 给仓库里所有 .ps1 补 UTF-8 BOM
#
# 为什么需要：Windows PowerShell 5.1 对**无 BOM** 的 .ps1 按 ANSI（中文系统是 CP936）解码，
# 中文串会被拆坏 → 语法错误 → 脚本根本跑不起来。任何编辑器/工具重写文件后都可能把 BOM 丢掉，
# 所以这里做一次全仓库自检并对缺失者补上。
#
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File tools\ensure-ps1-bom.ps1
# 注意：本文件自身也必须带 BOM——首次运行后请确认输出里它自己是 "已有 BOM"。

[CmdletBinding()]
param(
  [string]$Root = '',
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$bom = [byte[]](0xEF, 0xBB, 0xBF)
$files = Get-ChildItem -Path $Root -Recurse -Filter '*.ps1' -File |
  Where-Object { $_.FullName -notmatch '\\verify\\|\\_pkg\\|\\node_modules\\' }

$missing = 0
foreach ($f in $files) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  if ($hasBom) {
    Write-Host ('  已有 BOM  ' + $f.FullName.Replace($Root, '.'))
    continue
  }
  $missing++
  if ($CheckOnly) {
    Write-Host ('  缺 BOM    ' + $f.FullName.Replace($Root, '.')) -ForegroundColor Yellow
    continue
  }
  $out = New-Object byte[] ($bytes.Length + 3)
  [Array]::Copy($bom, 0, $out, 0, 3)
  [Array]::Copy($bytes, 0, $out, 3, $bytes.Length)
  [System.IO.File]::WriteAllBytes($f.FullName, $out)
  Write-Host ('  已补 BOM  ' + $f.FullName.Replace($Root, '.')) -ForegroundColor Green
}

Write-Host ''
if ($missing -eq 0) { Write-Host "全部 $($files.Count) 个 .ps1 都带 BOM" -ForegroundColor Green; exit 0 }
if ($CheckOnly) { Write-Host "有 $missing 个 .ps1 缺 BOM（-CheckOnly 模式，未修改）" -ForegroundColor Yellow; exit 1 }
Write-Host "已为 $missing 个 .ps1 补上 BOM" -ForegroundColor Green
exit 0
