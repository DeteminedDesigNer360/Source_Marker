# refresh-hashes.ps1 —— 一键刷新发行包内的 SHA256SUMS.txt
#
# 什么时候用：改了 mpv-player 下任何会随包分发的文件之后（例如 source-markers.lua），
# SHA256SUMS.txt 里那一行的哈希就过期了，mpv-player\校验.ps1 会报「N/16 个文件有问题」。
# 本脚本按 SHA256SUMS.txt **已有条目**逐个重算并写回 —— 只刷新、不增删条目。
#
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File tools\refresh-hashes.ps1
#        （不带参数时自动在工作集里找 source-marker-united-*）
# 注意：本文件必须保持 UTF-8 **带 BOM**。

[CmdletBinding()]
param([string]$Package = '')

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot

if (-not $Package) {
    $cand = Get-ChildItem $workspace -Directory -Filter 'source-marker-united-*' |
            Sort-Object Name -Descending | Select-Object -First 1
    if (-not $cand) { throw ('在工作集里没找到 source-marker-united-* 目录：' + $workspace) }
    $Package = $cand.FullName
}
$mpvDir  = Join-Path $Package 'mpv-player'
$sumFile = Join-Path $mpvDir 'SHA256SUMS.txt'
if (-not (Test-Path $sumFile)) { throw ('找不到：' + $sumFile) }

Write-Host ('发行包：' + $Package) -ForegroundColor Cyan
$lines = Get-Content $sumFile -Encoding UTF8
$out = New-Object System.Collections.Generic.List[string]
$changed = 0
$bad = 0

foreach ($line in $lines) {
    if ($line -match '^([0-9a-fA-F]{64})(\s+)(.+?)\s*$') {
        $oldHash = $Matches[1]; $sep = $Matches[2]; $rel = $Matches[3]
        $full = Join-Path $mpvDir ($rel -replace '/', '\')
        if (-not (Test-Path $full)) {
            Write-Host ('  x 文件不存在：' + $rel) -ForegroundColor Red
            $bad++; $out.Add($line); continue
        }
        $newHash = (Get-FileHash $full -Algorithm SHA256).Hash
        if ($newHash -ne $oldHash) {
            Write-Host ('  > ' + $rel) -ForegroundColor Yellow
            Write-Host ('      ' + $oldHash)
            Write-Host ('   ->  ' + $newHash)
            $changed++; $out.Add($newHash + $sep + $rel)
        } else { $out.Add($line) }
    } else { $out.Add($line) }
}

if ($changed -gt 0) {
    [System.IO.File]::WriteAllText($sumFile, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('已刷新 ' + $changed + ' 个条目的哈希') -ForegroundColor Green
} else { Write-Host '所有条目的哈希都是最新的，无需改动' -ForegroundColor Green }
if ($bad -gt 0) { Write-Host ($bad.ToString() + ' 个条目指向的文件不存在，请检查') -ForegroundColor Red }

Write-Host ''
Write-Host '=== 跑一次包自检确认 ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mpvDir '校验.ps1')
exit $LASTEXITCODE