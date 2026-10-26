
param(
  [int]$Pid_ = 17052,
  [string]$Prep = "",
  [string]$Mods = "",
  [string]$Action = "wheel",
  [int]$Steps = 3,
  [string]$Dir = "up",
  [int]$X = 640,
  [int]$Y = 693,
  [string]$Tag = "s",
  [int]$DelayMs = 300,
  [string]$OutDir = ""
)
$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Smp {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool at);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  public delegate bool EnumProc(IntPtr h, IntPtr l);

  public static IntPtr FindByPid(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p2; GetWindowThreadProcessId(h, out p2);
      if (p2 == pid && IsWindowVisible(h)) { if (found == IntPtr.Zero) found = h; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static bool Raise(IntPtr h) {
    if (h == IntPtr.Zero) return false;
    if (IsIconic(h)) ShowWindow(h, 9);
    if (GetForegroundWindow() == h) return true;
    uint fgPid; uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint tid = GetCurrentThreadId();
    AttachThreadInput(tid, fgTid, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    AttachThreadInput(tid, fgTid, false);
    System.Threading.Thread.Sleep(150);
    return GetForegroundWindow() == h;
  }

  public static void Key(ushort vk, bool up) {
    INPUT[] a = new INPUT[1]; a[0].type = 1; a[0].u.ki.wVk = vk; a[0].u.ki.dwFlags = up ? 2u : 0u;
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Tap(ushort vk) { Key(vk, false); System.Threading.Thread.Sleep(40); Key(vk, true); }
  public static void Wheel(int delta) {
    INPUT[] a = new INPUT[1]; a[0].type = 0; a[0].u.mi.dwFlags = 0x0800u; a[0].u.mi.mouseData = (uint)delta;
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@

function Shot($path) {
  $bmp = New-Object System.Drawing.Bitmap 1280,800
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0,0,0,0,(New-Object System.Drawing.Size 1280,800))
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

$hwnd = [Smp]::FindByPid([uint32]$Pid_)
if ($hwnd -eq [IntPtr]::Zero) { "ERR no-window pid=$Pid_"; exit 3 }
$fg = [Smp]::Raise($hwnd)
"raise=$fg hwnd=$($hwnd.ToInt64())"

[void][Smp]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 200
foreach ($p in $Prep.Split(",")) {
  if (-not $p) { continue }
  $kv = $p.Split(":")
  if ($kv[0] -eq "eq")   { for ($i=0; $i -lt [int]$kv[1]; $i++) { [Smp]::Tap(0xBB); Start-Sleep -Milliseconds 220 } }
  if ($kv[0] -eq "dash") { for ($i=0; $i -lt [int]$kv[1]; $i++) { [Smp]::Tap(0xBD); Start-Sleep -Milliseconds 220 } }
  if ($kv[0] -eq "key")  { [Smp]::Tap([uint16][Convert]::ToInt32($kv[1],16)); Start-Sleep -Milliseconds 220 }
}
if ($Prep) { Start-Sleep -Milliseconds 400 }

$vks = @()
foreach ($m in $Mods.Split("+")) {
  if ($m -eq "shift") { $vks += 0x10 }
  elseif ($m -eq "ctrl") { $vks += 0x11 }
  elseif ($m -eq "alt") { $vks += 0x12 }
}
foreach ($vk in $vks) { [Smp]::Key([uint16]$vk, $false); Start-Sleep -Milliseconds 90 }

[void][Smp]::Raise($hwnd)
[void][Smp]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 220

$delta = if ($Dir -eq "up") { 120 } else { -120 }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$dir1 = $OutDir
$files = @()
for ($i = 0; $i -le $Steps; $i++) {
  $f = Join-Path $dir1 ("{0}_{1}.png" -f $Tag, $i)
  Shot $f
  $files += $f
  if ($i -lt $Steps) {
    if ($Action -eq "wheel") { [Smp]::Wheel($delta) }
    elseif ($Action -eq "zoom") { [Smp]::Tap(0xBB) }
    elseif ($Action -eq "zoomout") { [Smp]::Tap(0xBD) }
    Start-Sleep -Milliseconds $DelayMs
  }
}
foreach ($vk in $vks) { [Smp]::Key([uint16]$vk, $true) }
Start-Sleep -Milliseconds 180
"steps=$Steps tag=$Tag mods=$Mods fg_end=$([Smp]::GetForegroundWindow().ToInt64())"