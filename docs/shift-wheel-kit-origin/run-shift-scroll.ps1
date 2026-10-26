param(
    [string]$AhkExe    = '',
    [string]$AhkScript = '',
    [int]$TargetPid    = 0,
    [int]$X = 694,
    [int]$Y = 694,
    [int]$Notches = 10,
    [int]$IntervalMs = 1000,
    [ValidateSet('up','down','left','right')][string]$Direction = 'up',
    [switch]$Restart,
    [switch]$KeepAhk
)

$ErrorActionPreference = 'Stop'
$script:sw = [System.Diagnostics.Stopwatch]::StartNew()

# 解析 AutoHotkey 路径：默认探测常见安装位置，找不到再从 PATH 取
if (-not $AhkExe) {
    $cands = @(
        'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
        'C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe',
        'C:\Program Files\AutoHotkey\AutoHotkey64.exe',
        'C:\Program Files\AutoHotkey\AutoHotkey.exe'
    )
    $AhkExe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $AhkExe) {
        $cmd = Get-Command 'AutoHotkey64.exe','AutoHotkey.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $AhkExe = $cmd.Source }
    }
    if (-not $AhkExe) { throw 'AutoHotkey v2 not found; pass -AhkExe <path>' }
}

# 解析 AHK 脚本：默认用本文件夹 ahk\ 目录下的脚本
if (-not $AhkScript) {
    $packed = Join-Path $PSScriptRoot 'ahk\shift-toggle.ahk'
    if (Test-Path $packed) { $AhkScript = $packed }
    else {
        $any = Get-ChildItem (Join-Path $PSScriptRoot 'ahk') -Filter '*.ahk' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($any) { $AhkScript = $any.FullName } else { throw 'no .ahk script found; pass -AhkScript <path>' }
    }
}

function Step([string]$msg) {
    Write-Host ('{0,7:N2}s {1}' -f ($script:sw.ElapsedMilliseconds / 1000), $msg)
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WheeLShift {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool at);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);

  public static void Key(ushort vk, bool up) {
    INPUT[] a = new INPUT[1];
    a[0].type = 1;
    a[0].u.ki.wVk = vk;
    a[0].u.ki.dwFlags = up ? 2u : 0u;
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Wheel(bool horizontal, int delta) {
    INPUT[] a = new INPUT[1];
    a[0].type = 0;
    a[0].u.mi.dwFlags = horizontal ? 0x1000u : 0x0800u;
    a[0].u.mi.mouseData = unchecked((uint)delta);
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static IntPtr MainWindow(int pid) {
    IntPtr best = IntPtr.Zero;
    int bestArea = 0;
    EnumProc cb = (h, l) => {
      uint p;
      GetWindowThreadProcessId(h, out p);
      if (p != (uint)pid) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r;
      GetWindowRect(h, out r);
      int area = (r.R - r.L) * (r.B - r.T);
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return best;
  }
}
'@

function Get-AhkProcs {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*utoHotkey*' })
}

function Stop-Ahk {
    $procs = Get-AhkProcs
    if ($procs.Count -eq 0) { Step 'AHK: none running'; return }
    $ids = ($procs | ForEach-Object { $_.Id }) -join ','
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
    Step ('AHK: stopped ' + $ids)
}

function Start-Ahk {
    $before = @()
    foreach ($p in (Get-AhkProcs)) { $before += $p.Id }
    $argLine = '"' + $AhkScript + '"'
    Start-Process -FilePath $AhkExe -ArgumentList $argLine
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        foreach ($p in (Get-AhkProcs)) {
            if ($before -notcontains $p.Id) { Step ('AHK: started pid=' + $p.Id); return $p.Id }
        }
    }
    throw 'AHK script did not start within 8s'
}

function Resolve-TargetPid([int]$wanted) {
    if ($wanted -ne 0) { return $wanted }
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*Premiere*' } | Select-Object -First 1
    if (-not $p) { throw 'no Premiere process found' }
    return $p.Id
}

function Focus-Target([int]$prPid) {
    $h = [WheeLShift]::MainWindow($prPid)
    if ($h -eq [IntPtr]::Zero) { throw ('no visible window for pid ' + $prPid) }
    if ([WheeLShift]::IsIconic($h)) {
        [void][WheeLShift]::SendMessage($h, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 900
    }
    for ($i = 0; $i -lt 5; $i++) {
        if ([WheeLShift]::GetForegroundWindow() -eq $h) { break }
        $fp = 0
        $ft = [WheeLShift]::GetWindowThreadProcessId([WheeLShift]::GetForegroundWindow(), [ref]$fp)
        $me = [WheeLShift]::GetCurrentThreadId()
        [void][WheeLShift]::AttachThreadInput($me, $ft, $true)
        [void][WheeLShift]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003)
        [void][WheeLShift]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0003)
        [void][WheeLShift]::BringWindowToTop($h)
        [void][WheeLShift]::SetForegroundWindow($h)
        [void][WheeLShift]::AttachThreadInput($me, $ft, $false)
        Start-Sleep -Milliseconds 250
    }
    $ok = ([WheeLShift]::GetForegroundWindow() -eq $h)
    $r = New-Object WheeLShift+RECT
    [void][WheeLShift]::GetWindowRect($h, [ref]$r)
    Step ('foreground hwnd=' + $h.ToInt64() + ' isFg=' + $ok + ' rect=' + $r.L + ',' + $r.T + ',' + $r.R + ',' + $r.B)
    return $ok
}

function ToggleShiftF8([string]$why) {
    [WheeLShift]::Key(0x77, $false)
    Start-Sleep -Milliseconds 60
    [WheeLShift]::Key(0x77, $true)
    Step ('F8 injected (' + $why + ')')
}

if ($Restart) { Stop-Ahk }
$running = Get-AhkProcs
if ($running.Count -eq 0) { $null = Start-Ahk } else { Step ('AHK: reuse pid=' + $running[0].Id) }

$pr = Resolve-TargetPid $TargetPid
Step ('target pid=' + $pr)

ToggleShiftF8 'hold'
Start-Sleep -Milliseconds 700

$fgOk = Focus-Target $pr
if (-not $fgOk) { throw 'target not foreground, aborting' }

$delta = 120
$horiz = $false
switch ($Direction) {
    'up'    { $delta = 120;  $horiz = $false }
    'down'  { $delta = -120; $horiz = $false }
    'left'  { $delta = -120; $horiz = $true }
    'right' { $delta = 120;  $horiz = $true }
}
[void][WheeLShift]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 140
for ($i = 1; $i -le $Notches; $i++) {
    [WheeLShift]::Wheel($horiz, $delta)
    Step ('notch ' + $i + '/' + $Notches)
    if ($i -lt $Notches) { Start-Sleep -Milliseconds $IntervalMs }
}

Start-Sleep -Milliseconds 400
ToggleShiftF8 'release'
Start-Sleep -Milliseconds 400

if (-not $KeepAhk) { Stop-Ahk }

$expectLeft = if ($KeepAhk) { 1 } else { 0 }
$left = (Get-AhkProcs).Count
$sh = [WheeLShift]::GetAsyncKeyState(0x10)
$verdict = 'FAIL'
if ($left -eq $expectLeft -and $sh -eq 0) { $verdict = 'PASS' }
Step ('verify ahk_procs=' + $left + '/expect ' + $expectLeft + ' VK_SHIFT=' + $sh + ' result=' + $verdict)
