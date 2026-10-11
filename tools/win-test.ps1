#Requires -Version 5.1
<#
  win-test.ps1 —— 窗口化 mpv 的一键交互测试驱动

  为什么存在：本项目的功能几乎都在 mpv 的 OSD / 按键里，而无头环境里
  IPC keypress 对命名键（ENTER/LEFT/ESC…）常常送不进脚本。可靠的办法是：
  起一个带窗口的 mpv（cmd /c start，非阻塞）→ 用 keybd_event 发【真实按键】
  → 按 Ctrl+S 让 mpv 自己截图（含 OSD，且不会被别的窗口遮挡）
  → 收 --log-file 里的脚本行 → 按 -Expect 断言。把这一整套固化成一条命令。

  典型用法：
    pwsh -File tools\win-test.ps1 -Keys 'F10','m','ENTER','.',']','7','ESC' `
         -ShotAfter 3 -Expect '编辑态按键 → edit-fwd1','编辑态按键 → edit-c7'

  约定：
    · 素材会被复制到 _tmp（侧车/导出都落在那里，绝不动你的原素材）
    · 默认清掉 source-markers-ui.json（干净前提；用 -KeepUiState 保留）
    · 默认最大化窗口（小分辨率素材下 OSD 会挤在一起，见用户反馈）
    · 默认先按一次 F1 关掉"首次使用"自动弹出的帮助（用 -NoCloseHelp 跳过）
    · 断言失败 → 退出码 1（闸门）；成功 → 退出码 0
#>
[CmdletBinding()]
param(
    [string]$Package,
    [string]$Media,
    [string[]]$Keys = @(),
    [int]$WaitMs = 1400,
    [int[]]$ShotAfter = @(),
    [string[]]$Expect = @(),
    [string[]]$NotExpect = @(),
    [switch]$NoCloseHelp,
    [switch]$NoMaximize,
    [switch]$KeepUiState,
    [switch]$KeepTmp,
    [switch]$RetryFailedKeys,
    [int]$StartupSec = 10
)
$ErrorActionPreference = 'Stop'
$NL = [char]10

# powershell -File 传数组参数时会被合成一个字符串（实测 'F10','m' → "F10,m"），
# 所以兼容三种写法：真数组 / 空格分隔的字符串（-Keys）/ 竖线分隔（-Expect）。
if ($Keys.Count -eq 1 -and $Keys[0] -match '\s') { $Keys = @($Keys[0] -split '\s+' | Where-Object { $_ -ne '' }) }
if ($Expect.Count -eq 1 -and $Expect[0] -match '\|') { $Expect = @($Expect[0] -split '\|') }
if ($NotExpect.Count -eq 1 -and $NotExpect[0] -match '\|') { $NotExpect = @($NotExpect[0] -split '\|') }
if ($ShotAfter.Count -eq 1 -and ([string]$ShotAfter[0]) -match ',') {
    $ShotAfter = @(([string]$ShotAfter[0]) -split ',' | ForEach-Object { [int]$_ })
}

function Say([string]$m) { Write-Output ('  ' + $m) }

# ---------- 定位工作区 / 包 / 素材 ----------
$work = Split-Path -Parent $PSScriptRoot
if (-not $Package) {
    $Package = (Get-ChildItem $work -Directory -Filter 'source-marker-united-*' |
                Sort-Object Name | Select-Object -Last 1).FullName
}
$exe = Join-Path $Package 'mpv-player\mpv.exe'
if (-not (Test-Path $exe)) { throw "找不到 mpv：$exe" }
$tmp = Join-Path $work '_tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

if (-not $Media) {
    $Media = (Get-ChildItem (Join-Path $work '参考视频') -File -Filter '*.mp4' |
              Select-Object -First 1).FullName
}
if (-not (Test-Path $Media)) { throw "找不到素材：$Media" }

Say ('包：' + (Split-Path $Package -Leaf))
Say ('素材：' + (Split-Path $Media -Leaf))

# ---------- 干净前提 ----------
if (-not $KeepUiState) {
    Get-ChildItem $Package -Recurse -File -Force -Filter 'source-markers-ui.json' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Say '已清 ui.json（干净前提）' }
}
Get-ChildItem $tmp -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.png', '.log', '.json' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Copy-Item $Media (Join-Path $tmp (Split-Path $Media -Leaf)) -Force
$clip = (Get-ChildItem $tmp -File -Filter '*.mp4' | Select-Object -First 1).FullName
$stem = [System.IO.Path]::GetFileNameWithoutExtension($clip)
$log  = Join-Path $tmp 'mpv.log'
if (Test-Path $log) { Remove-Item $log -Force }

Get-Process -Name mpv,mpv.exe,mpv.com -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 800

# ---------- Win32 按键（P/Invoke；不用 COM 的 WScript.Shell —— 那玩意儿会挂死） ----------
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$cs = @"
using System;
using System.Runtime.InteropServices;
public class WinTestKeys {
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  public static void Down(byte vk, bool ext){ keybd_event(vk, 0, ext ? 1u : 0u, UIntPtr.Zero); }
  public static void Up(byte vk, bool ext){ keybd_event(vk, 0, ext ? 3u : 2u, UIntPtr.Zero); }
}
"@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop } catch { }

function Resolve-Key([string]$token) {
    $mods = New-Object System.Collections.ArrayList
    $k = $token
    while ($true) {
        if ($k -match '^(?i)(Ctrl|Control)\+(.+)$') { [void]$mods.Add([byte]0x11); $k = $Matches[2]; continue }
        if ($k -match '^(?i)Shift\+(.+)$')          { [void]$mods.Add([byte]0x10); $k = $Matches[2]; continue }
        if ($k -match '^(?i)Alt\+(.+)$')            { [void]$mods.Add([byte]0x12); $k = $Matches[2]; continue }
        break
    }
    # 方向键 / DEL / HOME / END / INS / PGUP / PGDN 是"扩展键"，注入时必须带
    # KEYEVENTF_EXTENDEDKEY(0x1)，否则 mpv 收到的不是同一个键 —— 本会话就因为这个
    # 误判过"方向键在 mpv 里被默认绑定占住"（其实是我的注入错了）。
    $named = @{
        'F1'=0x70;'F2'=0x71;'F3'=0x72;'F10'=0x79;'F11'=0x7A;'F12'=0x7B;
        'ENTER'=0x0D;'ESC'=0x1B;'TAB'=0x09;'SPACE'=0x20;'BACKSPACE'=0x08
    }
    $ext = @{ 'LEFT'=0x25;'UP'=0x26;'RIGHT'=0x27;'DOWN'=0x28;'DEL'=0x2E;'HOME'=0x24;'END'=0x23;'INS'=0x2D;'PGUP'=0x21;'PGDN'=0x22 }
    $up = $k.ToUpper()
    if ($named.ContainsKey($up)) { return @{ Mods = $mods; Vk = [byte]$named[$up]; Ext = $false } }
    if ($ext.ContainsKey($up))   { return @{ Mods = $mods; Vk = [byte]$ext[$up];   Ext = $true  } }
    if ($k.Length -eq 1) {
        $c = $k.ToUpper()
        if ($c -match '^[A-Z0-9]$') { return @{ Mods = $mods; Vk = [byte][int][char]$c; Ext = $false } }
        $punct = @{ ','=0xBC; '.'=0xBE; '/'=0xBF; ';'=0xBA; '['=0xDB; ']'=0xDD; '\'=0xDC; '-'=0xBD; '='=0xBB }
        if ($punct.ContainsKey($k)) { return @{ Mods = $mods; Vk = [byte]$punct[$k]; Ext = $false } }
    }
    return $null
}

# ---------- 起 mpv（cmd /c start 非阻塞；Start-Process 起 GUI 会挂） ----------
$argLine = '--force-window=yes --keep-open=yes --pause=yes --msg-level=all=v ' +
           '--screenshot-format=png --screenshot-dir="' + $tmp + '" --log-file="' + $log + '" "' + $clip + '"'
Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "" "' + $exe + '" ' + $argLine) -NoNewWindow
Say ('已发出启动命令（等 ' + $StartupSec + ' 秒）...')
Start-Sleep -Seconds $StartupSec

$proc = Get-Process -Name mpv,mpv.exe,mpv.com -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw 'mpv 没起来（看 _tmp\mpv.log）' }
$h = $proc.MainWindowHandle
Say ('mpv pid=' + $proc.Id + ' hwnd=' + $h)
if ($h -eq 0) { Start-Sleep -Seconds 3; $proc.Refresh(); $h = $proc.MainWindowHandle }

if (-not $NoMaximize) { [WinTestKeys]::ShowWindow($h, 3) | Out-Null; Start-Sleep -Milliseconds 700; Say '窗口已最大化' }
[WinTestKeys]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 800

# 只数"动作行"：日志会因为帮助重绘等无关原因增长，用总行数会误判（本会话踩过）
trap {
    Write-Output ('  ! 出错，正在收场：' + $_.Exception.Message)
    Get-Process -Name mpv,mpv.exe,mpv.com -ErrorAction SilentlyContinue |
        ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
    exit 2
}

function Log-Lines {
    if (-not (Test-Path $log)) { return 0 }
    (Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue |
     Select-String -Pattern '按键 →|已加标记|进入编辑态|已把|已载入|导出 CSV|绑定失败|标记模式绑定|键位覆盖表|键位检查|键位模板' |
     Measure-Object).Count
}
function Script-Lines { if (Test-Path $log) { Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern '\[source_markers\]' | ForEach-Object { $_.Line } } }

function Send-One([string]$token) {
    $spec = Resolve-Key $token
    if (-not $spec) { throw ('不认识这个键：' + $token) }
    [WinTestKeys]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 250
    $ex = [bool]$spec.Ext
    foreach ($m in $spec.Mods) { [WinTestKeys]::Down($m, $false); Start-Sleep -Milliseconds 40 }
    [WinTestKeys]::Down($spec.Vk, $ex); Start-Sleep -Milliseconds 90; [WinTestKeys]::Up($spec.Vk, $ex)
    Start-Sleep -Milliseconds 40
    for ($i = $spec.Mods.Count - 1; $i -ge 0; $i--) { [WinTestKeys]::Up($spec.Mods[$i], $false) }
}

$shots = New-Object System.Collections.ArrayList
function Shoot([string]$label, [string]$how = 'Ctrl+S') {
    $before = @(Get-ChildItem $tmp -File -Filter 'mpv-shot*.png' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
    Send-One $how
    Start-Sleep -Seconds 2
    $new = @(Get-ChildItem $tmp -File -Filter 'mpv-shot*.png' -ErrorAction SilentlyContinue |
             Where-Object { $before -notcontains $_.Name })
    if ($new.Count -eq 0) { Say ('⚠ 截图没产出（' + $label + '）'); return }
    $src = $new | Sort-Object Name | Select-Object -Last 1
    $dst = Join-Path $tmp ('shot-' + $shots.Count.ToString('00') + '-' + $label + '.png')
    Move-Item -LiteralPath $src.FullName -Destination $dst -Force
    [void]$shots.Add($dst)
    Say ('截图：' + (Split-Path $dst -Leaf) + '  (' + (Get-Item $dst).Length + ' B)')
}

# ---------- 关掉"首次使用"自动弹出的帮助 ----------
if (-not $NoCloseHelp) { Send-One 'F1'; Start-Sleep -Seconds 1; Say '已按 F1（关首次帮助）' }

# ---------- 逐个发键 ----------
$idx = 0
foreach ($k in $Keys) {
    $idx++
    $n0 = Log-Lines
    Send-One $k
    Start-Sleep -Milliseconds $WaitMs
    $n1 = Log-Lines
    $note = ''
    if ($n1 -le $n0) {
        $note = '（动作行没增长）'
        if ($RetryFailedKeys) {
            Say ('第 ' + $idx + ' 键 ' + $k + ' 无反应，重试一次')
            Send-One $k; Start-Sleep -Milliseconds $WaitMs
            $n1 = Log-Lines
            $note = '（重试后 ' + ($(if ($n1 -gt $n0) { '有增长' } else { '仍无增长' })) + '）'
        }
    }
    Say ('第 ' + $idx + ' 键 ' + $k.PadRight(8) + ' 日志 ' + $n0 + ' → ' + $n1 + ' ' + $note)
    if ($ShotAfter -contains $idx) { Shoot ('after-' + ($k -replace '[^A-Za-z0-9]', '')) }
}

# ---------- 收尾截图 + 侧车 ----------
Shoot 'final'
$side = Join-Path $tmp ($stem + '.mpv-autosave.json')
Say '--- 侧车 ---'
if (Test-Path -LiteralPath $side) { Say ([System.IO.File]::ReadAllText($side)) } else { Say '(无侧车)' }

# ---------- 收日志 ----------
Say '--- 脚本日志（只列动作行）---'
$acts = Script-Lines | Select-String -Pattern '标记模式按键|编辑态按键|已加标记|进入编辑态|退出|移动|颜色|导出|载入|绑定'
$allScript = Script-Lines          # 断言在【全部】脚本行里找（actions 只是给人看的摘要）
foreach ($a in $acts) { Say ($a.ToString().Trim()) }

# ---------- 断言（闸门） ----------
$fails = New-Object System.Collections.ArrayList
foreach ($pat in $Expect) {
    $hit = $allScript | Select-String -Pattern ([regex]::Escape($pat)) | Select-Object -First 1
    if ($hit) { Say ('✓ 命中：' + $pat) } else { [void]$fails.Add($pat); Say ('✗ 未命中：' + $pat) }
}

# ---------- 反向断言：这些必须【不】出现 ----------
foreach ($pat in $NotExpect) {
    $hit = $allScript | Select-String -Pattern ([regex]::Escape($pat)) | Select-Object -First 1
    if ($hit) { [void]$fails.Add('(不该出现) ' + $pat); Say ('✗ 不该出现却出现：' + $pat) }
    else { Say ('✓ 确认未出现：' + $pat) }
}

# ---------- 清理 ----------
Get-Process -Name mpv,mpv.exe,mpv.com -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 600
Say ('截图共 ' + $shots.Count + ' 张，在 ' + $tmp)
if (-not $KeepTmp) {
    Get-ChildItem $tmp -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.mp4' } | Remove-Item -Force -ErrorAction SilentlyContinue
}
if ($fails.Count -gt 0) {
    Say ('❌ 断言失败 ' + $fails.Count + ' 条')
    exit 1
}
Say '✅ 全部通过'
exit 0