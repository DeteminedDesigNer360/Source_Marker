#Requires -Version 5.1
<#
  verify-bar-hit.ps1 —— 第 8 条：控制栏按钮"命中框"的离线验证（无头 mpv，不需要窗口 / 不需要鼠标）

  为什么要它：本机环境**禁止注入鼠标**（SetCursorPos 直接返回 False，SendInput 也无效），
  所以"点得对不对"没法用真鼠标自动化。但命中框本身可以离线验：
    ① 让插件把运行时算出的按钮框打进日志（render_prbar 里的「控制栏按钮框：…」）
    ② 用 script-message hit x y 逐点问插件"这个坐标落在哪个按钮上"
    ③ 断言：每个按钮的中心=它自己；按钮之间的缝和栏外=打空；置灰的按钮=禁
  这能抓住"命中框和图标不重合 / 缩放算错 / 区域重叠"这类问题上机才发现的 bug。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-bar-hit.ps1
    powershell ... -File tools\verify-bar-hit.ps1 -Media 'D:\x.mp4' -KeepTmp

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
$com = Join-Path $Package 'mpv-player\mpv.com'
$lua = Join-Path $Package 'mpv-player\portable_config\scripts\source-markers.lua'
if (-not (Test-Path $com)) { throw "找不到 mpv.com：$com" }
if (-not (Test-Path $lua)) { throw "找不到插件：$lua" }

$tmp = Join-Path $work '_tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not $Media) {
    $Media = (Get-ChildItem (Join-Path $work '参考视频') -File -Filter '*.mp4' |
              Select-Object -First 1).FullName
}
if (-not (Test-Path $Media)) { throw "找不到素材：$Media" }

# mpv 的 ~~home 在 --no-config 下会展开成空 ⇒ 界面状态落到 %TEMP%；开跑前清掉，保证"干净前提"
$uiState = Join-Path $env:TEMP 'source-markers-ui.json'
$cfgDir = Join-Path $tmp 'mpvtest'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

function Invoke-Mpv([string]$probeFile, [string]$logFile) {
    Remove-Item $uiState -ErrorAction SilentlyContinue
    Remove-Item $logFile -ErrorAction SilentlyContinue
    & $com --no-config --config-dir="$cfgDir" --vo=null --ao=null --script="$lua" --script="$probeFile" `
        "--log-file=$logFile" --msg-level=all=v "$Media" 2>&1 | Out-Null
}

Write-Output ('包：' + (Split-Path $Package -Leaf))
Write-Output ('素材：' + (Split-Path $Media -Leaf))

# ── 第一趟：拿运行时的按钮框 ──────────────────────────────────────────
$p1 = Join-Path $tmp 'barhit-1.lua'
Set-Content -LiteralPath $p1 -Encoding ASCII -Value @(
    "mp.add_timeout(0.8, function() mp.commandv('script-binding', 'source_markers/switch-osd') end)",
    "mp.add_timeout(1.2, function() mp.commandv('script-message', 'prbar') end)",
    "mp.add_timeout(1.6, function() mp.commandv('quit') end)"
) -ErrorAction Stop
Invoke-Mpv $p1 (Join-Path $tmp 'barhit-1.log')

$boxLine = (Select-String -LiteralPath (Join-Path $tmp 'barhit-1.log') -Pattern '控制栏按钮框' |
            Select-Object -Last 1).Line
if (-not $boxLine) { throw '没拿到按钮框（看 _tmp\barhit-1.log 里的「控制栏按钮框」）' }
$boxTail = $boxLine.Substring($boxLine.IndexOf('控制栏按钮框：') + 7)
Write-Output ('按钮框：' + $boxTail)

$boxes = @()
foreach ($tok in ($boxTail -split '\s+')) {
    if ($tok -notlike '*=*,*,*,*') { continue }
    $off = $tok.EndsWith(',off')
    $parts = ($tok -replace ',off$', '') -split '='
    $nums = $parts[1] -split ','
    $boxes += [pscustomobject]@{
        Name = $parts[0]; X = [int]$nums[0]; Y = [int]$nums[1]; W = [int]$nums[2]; H = [int]$nums[3]; Off = $off
    }
}
Write-Output ("解析到 $($boxes.Count) 个按钮框")

# ── 生成命中测试点：每个按钮中心 + 两个"必须打空"的点 ────────────────
$pts = @()
foreach ($b in $boxes) {
    $cx = $b.X + [int]($b.W / 2); $cy = $b.Y + [int]($b.H / 2)
    if ($b.Off) { $pts += , @(($b.Name + '(置灰)'), $cx, $cy, '（无）') }
    else        { $pts += , @($b.Name, $cx, $cy, $b.Name) }
}
$a = $boxes[0]
$pts += , @('栏上方 20px', ($a.X + 5), ($a.Y - 20), '（无）')
$pts += , @('两按钮之间的缝', ($a.X + $a.W + 1), ($a.Y + 5), '（无）')

$body = @("mp.add_timeout(0.8, function() mp.commandv('script-binding', 'source_markers/switch-osd') end)")
$t = 1.2
foreach ($p in $pts) {
    $body += ("mp.add_timeout({0}, function() mp.commandv('script-message', 'hit', '{1}', '{2}') end)" -f $t, $p[1], $p[2])
    $t = $t + 0.25
}
$body += ("mp.add_timeout({0}, function() mp.commandv('quit') end)" -f ($t + 0.4))
$p2 = Join-Path $tmp 'barhit-2.lua'
Set-Content -LiteralPath $p2 -Encoding ASCII -Value ($body -join "`n")
Invoke-Mpv $p2 (Join-Path $tmp 'barhit-2.log')

Write-Output '=== 命中测试（期望 → 实际）==='
$fails = 0
foreach ($p in $pts) {
    $pat = '命中测试 ' + $p[1] + ',' + $p[2] + ' → '
    $line = (Select-String -LiteralPath (Join-Path $tmp 'barhit-2.log') -Pattern ([regex]::Escape($pat)) |
             Select-Object -Last 1).Line
    if (-not $line) { Write-Output ('  x ' + $p[0] + '：日志里没有这一条'); $fails++; continue }
    $got = ($line.Substring($line.IndexOf($pat) + $pat.Length)) -replace ' ｜.*$', ''
    $ok = ($got -eq $p[3])
    if (-not $ok) { $fails++ }
    $flag = 'x'; if ($ok) { $flag = 'v' }
    Write-Output ('  ' + $flag + ' ' + $p[0].PadRight(16) + ' 期望[' + $p[3] + '] 实际[' + $got + ']')
}

if (-not $KeepTmp) { Remove-Item (Join-Path $tmp 'barhit-*.lua') -ErrorAction SilentlyContinue }
Write-Output ''
if ($fails -gt 0) { Write-Output ("❌ 命中框断言失败 $fails 条"); exit 1 }
Write-Output ('✅ 命中框全部通过（' + $pts.Count + ' 个测试点）')
exit 0
