# 校验.ps1 —— 核对本包文件是否与 SHA256SUMS.txt 一致
# 用法：右键「使用 PowerShell 运行」，或在终端里执行
#       powershell -NoProfile -ExecutionPolicy Bypass -File .\校验.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sums = Join-Path $here 'SHA256SUMS.txt'
if (-not (Test-Path $sums)) { Write-Host '找不到 SHA256SUMS.txt' -ForegroundColor Red; exit 1 }

$bad = 0
$n = 0
Get-Content $sums -Encoding UTF8 | ForEach-Object {
  $line = $_.Trim()
  if ($line -eq '' -or $line.StartsWith('#')) { return }
  $m = [regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
  if (-not $m.Success) { return }
  $want = $m.Groups[1].Value.ToLower()
  $rel = $m.Groups[2].Value.Trim()
  $path = Join-Path $here $rel
  $n++
  if (-not (Test-Path $path)) {
    Write-Host ("  缺失  {0}" -f $rel) -ForegroundColor Red
    $script:bad++
    return
  }
  $got = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()
  if ($got -eq $want) {
    Write-Host ("  OK    {0}" -f $rel) -ForegroundColor Green
  } else {
    Write-Host ("  不一致 {0}" -f $rel) -ForegroundColor Red
    Write-Host ("         期望 {0}" -f $want)
    Write-Host ("         实际 {0}" -f $got)
    $script:bad++
  }
}

Write-Host ''
if ($bad -gt 0) { Write-Host ("校验失败：{0}/{1} 个文件有问题" -f $bad, $n) -ForegroundColor Red; exit 1 }
Write-Host ("校验通过：{0} 个文件全部一致" -f $n) -ForegroundColor Green
exit 0
