#Requires -Version 5.1
<#
  verify-shot.ps1 —— 第 8 条 步骤 4：验证控制栏的「截取当前帧」（相机按钮）

  验三件事：
    ① 触发 bar-shot 后，PNG 真的落到 **素材同目录的 截图\ 下**（文件名带时间码）
    ② 这张图**不含 OSD**：同一时刻再取一张"带 OSD"的参考图（screenshot-to-file … window），
       两张必须**不同** —— 参考图里有 OSD 说明当时 OSD 确实在屏幕上，而相机图里没有它
    ③ 尺寸合理（相机图来自视频帧）

  前置：需要 Pillow（系统 python 即可）；需要能起窗口化的 mpv（本机可以）。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-shot.ps1
    powershell ... -File tools\verify-shot.ps1 -Media 'D:\x.mp4' -KeepTmp

  退出码：0 = 全过；1 = 有失败。本文件必须 UTF-8 带 BOM。
#>
[CmdletBinding()]
param(
    [string]$Package,
    [string]$Media,
    [switch]$KeepTmp
)
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $PSScriptRoot
Set-Location $work

if (-not $Package) {
    $Package = (Get-ChildItem $work -Directory -Filter 'source-marker-united-*' |
                Sort-Object Name | Select-Object -Last 1).FullName
}
$exe = Join-Path $Package 'mpv-player\mpv.exe'
if (-not (Test-Path $exe)) { throw "找不到 mpv.exe：$exe" }
$tmp = Join-Path $work '_tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not $Media) {
    $Media = (Get-ChildItem (Join-Path $work '参考视频') -File -Filter '*.mp4' | Select-Object -First 1).FullName
}
if (-not (Test-Path $Media)) { throw "找不到素材：$Media" }

# 用 _tmp 里的副本跑，绝不动用户素材（截图会写到"素材同目录"，所以必须是副本）
$clip = Join-Path $tmp 'shot-media.mp4'
Copy-Item $Media $clip -Force
$shotDir = Join-Path $tmp '截图'
Remove-Item $shotDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $tmp 'shot-ref-osd.png') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $tmp 'shot-probe.lua') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $tmp 'shot-verify.log') -Force -ErrorAction SilentlyContinue
# 干净前提：窗口化运行时 portable_config 就是 ~~home，界面状态就在包里
Remove-Item (Join-Path $Package 'mpv-player\portable_config\source-markers-ui.json') -Force -ErrorAction SilentlyContinue

$ref = ($tmp + '\shot-ref-osd.png') -replace '\\', '/'
$probe = Join-Path $tmp 'shot-probe.lua'
Set-Content -LiteralPath $probe -Encoding ASCII -Value (@(
    "mp.add_timeout(1.0, function() mp.commandv('script-binding', 'source_markers/switch-osd') end)",
    "mp.add_timeout(1.6, function() mp.commandv('set', 'time-pos', '2.0') end)",
    "mp.add_timeout(1.8, function() mp.commandv('set', 'pause', 'yes') end)",
    "mp.add_timeout(2.2, function() mp.commandv('script-binding', 'source_markers/bar-shot') end)",
    "mp.add_timeout(3.0, function() mp.commandv('screenshot-to-file', '$ref', 'window') end)",
    "mp.add_timeout(4.0, function() mp.commandv('quit') end)"
) -join "`n")

$log = Join-Path $tmp 'shot-verify.log'
# 注意：**不要**再 --script=<插件>：portable_config 已经会自动加载它，
# 再传一次会加载出第二个实例（source_markers2），两个实例会互相抢 OSD。
$argLine = '--force-window=yes --keep-open=yes --pause=yes --msg-level=all=v --log-file="' + $log + '" ' +
           '--script="' + $probe + '" "' + $clip + '"'
Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "" "' + $exe + '" ' + $argLine) -NoNewWindow
Write-Output ('包：' + (Split-Path $Package -Leaf))
Write-Output ('素材副本：' + (Split-Path $clip -Leaf) + '（截图会落在同目录的 截图\ 下）')
Start-Sleep -Seconds 10
Get-Process -Name mpv,mpv.exe,mpv.com -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 500

$fails = 0
$logTxt = if (Test-Path $log) { Get-Content $log -Raw -Encoding UTF8 } else { '' }
$shot = Get-ChildItem $shotDir -File -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $shot) {
    Write-Output '❌ 没找到截图产物（看 _tmp\shot-verify.log 里的「截取当前帧」）'
    exit 1
}
Write-Output ('产物：' + $shot.Name + '  (' + $shot.Length + ' B)')
if ($logTxt -match '截取当前帧完成') { Write-Output '✓ 日志确认落盘（截取当前帧完成）' }
else { Write-Output '❌ 日志里没有「截取当前帧完成」'; $fails++ }
if ($shot.Name -match '-\d\d\.\d\d\.\d\d\.\d\d\d(\.png|-2\.png)$') { Write-Output '✓ 文件名带时间码' }
else { Write-Output ('❌ 文件名不像 <素材名>-HH.MM.SS.mmm.png：' + $shot.Name); $fails++ }

if (-not (Test-Path (Join-Path $tmp 'shot-ref-osd.png'))) {
    Write-Output '❌ 没有参考图（带 OSD 的那张），无法证明"图里真没有 OSD"'
    exit 1
}
$rc = & python (Join-Path $PSScriptRoot 'shot-diff.py') $shot.FullName (Join-Path $tmp 'shot-ref-osd.png') 2>&1
$rc | ForEach-Object { Write-Output ('  ' + $_) }
if ($LASTEXITCODE -ne 0) { $fails++ }

if (-not $KeepTmp) { Remove-Item (Join-Path $tmp 'shot-ref-osd.png') -Force -ErrorAction SilentlyContinue }
Write-Output ''
if ($fails -gt 0) { Write-Output ("❌ 截取当前帧验证失败 $fails 条"); exit 1 }
Write-Output '✅ 截取当前帧验证通过（图里没有 OSD）'
exit 0
