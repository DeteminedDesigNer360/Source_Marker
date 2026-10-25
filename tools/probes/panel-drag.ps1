param(
    [string]$Pkg = 'C:\Users\Frisk\Documents\Source_Marker_United\source-marker-united-1.2.0-alpha-r46',
    [string]$Media = 'C:\Users\Frisk\Documents\Source_Marker_United\reference\标尺素材-30s-30fps.mp4',
    [string]$Geom = '1280x720+40+60',
    [string]$Keys = '',
    [switch]$DragStop,
    [int]$HoldMs = 1500
)
# r48 探针：面板拖动 / 位置记忆的真机验证（键盘与鼠标都走真实注入，读脚本自己的日志）
$ErrorActionPreference = 'Stop'
$cs = @"
using System;
using System.Runtime.InteropServices;
public class PanelKeys {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
  public static int[] ClientOrigin(IntPtr hWnd) { POINT p; p.X = 0; p.Y = 0; ClientToScreen(hWnd, ref p); return new int[] { p.X, p.Y }; }
}
"@
Add-Type -TypeDefinition $cs

$tmp = Join-Path $Pkg '..\_tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$log = Join-Path $tmp 'panel-drag.log'
if (Test-Path $log) { Remove-Item $log -Force }
Get-Process mpv -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 600

$exe = Join-Path $Pkg 'mpv-player\mpv.exe'
$argLine = '--force-window=yes --geometry=' + $Geom + ' --keep-open=yes --pause=yes --msg-level=all=v --log-file="' + $log + '" "' + $Media + '"'
Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "" "' + $exe + '" ' + $argLine) -NoNewWindow
Start-Sleep -Seconds 8
$proc = Get-Process mpv -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw 'mpv 没起来' }
[PanelKeys]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 900
$org = [PanelKeys]::ClientOrigin($proc.MainWindowHandle)
Write-Output ('client origin: ' + $org[0] + ',' + $org[1])

function Move-To([int]$ox, [int]$oy) {
    [PanelKeys]::SetCursorPos($org[0] + $ox, $org[1] + $oy) | Out-Null
}
function Tap-Key([string]$spec) {
    $parts = $spec.Split('+')
    $mods = @()
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $p = $parts[$i]
        if ($p -eq 'Alt') { $mods += 0x12 } elseif ($p -eq 'Ctrl') { $mods += 0x11 } elseif ($p -eq 'Shift') { $mods += 0x10 }
    }
    $name = $parts[$parts.Count - 1]
    if ($name -match '^F(\d+)$') { $vk = 0x6F + [int]$Matches[1] } else { $vk = [int][char]$name.ToUpper() }
    foreach ($m in $mods) { [PanelKeys]::keybd_event($m, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
    [PanelKeys]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 70
    [PanelKeys]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
    foreach ($m in $mods) { [PanelKeys]::keybd_event($m, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 30 }
    Start-Sleep -Milliseconds 250
}

if ($DragStop) {
    Move-To 200 100
    Start-Sleep -Milliseconds 400
    Tap-Key 'Alt+F3'
    Start-Sleep -Milliseconds 500
    Move-To 300 200
    Start-Sleep -Milliseconds 300
    Move-To 400 240
    Start-Sleep -Milliseconds 300
}
if ($Keys) {
    foreach ($k in $Keys.Split(',')) { if ($k.Trim()) { Write-Output ('key: ' + $k.Trim()); Tap-Key $k.Trim() } }
}
if ($HoldMs -gt 0) { Start-Sleep -Milliseconds $HoldMs }

Get-Process mpv -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
Get-Content $log -Encoding UTF8 | Select-String '面板拖动|面板跟随|面板几何|拒绝' | ForEach-Object { $_.Line }
