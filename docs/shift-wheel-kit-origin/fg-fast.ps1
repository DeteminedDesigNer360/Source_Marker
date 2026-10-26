param([int]$TargetPid)
$src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Fx {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool at);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
Add-Type -TypeDefinition $src
$best = [IntPtr]::Zero
$bestArea = 0
$cb = [Fx+EnumProc]{
  param($h, $l)
  $p = 0
  [void][Fx]::GetWindowThreadProcessId($h, [ref]$p)
  if ($p -ne $TargetPid) { return $true }
  if (-not [Fx]::IsWindowVisible($h)) { return $true }
  $r = New-Object Fx+RECT
  [void][Fx]::GetWindowRect($h, [ref]$r)
  $area = ($r.R - $r.L) * ($r.B - $r.T)
  if ($area -gt $script:bestArea) { $script:bestArea = $area; $script:best = $h }
  return $true
}
[void][Fx]::EnumWindows($cb, [IntPtr]::Zero)
if ($best -eq [IntPtr]::Zero) { "NO WINDOW for pid $TargetPid"; exit 1 }
$t = New-Object System.Text.StringBuilder 256
[void][Fx]::GetWindowText($best, $t, 256)
if ([Fx]::IsIconic($best)) { [void][Fx]::SendMessage($best, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero); Start-Sleep -Milliseconds 900 }
for ($i = 1; $i -le 5; $i++) {
  if ([Fx]::GetForegroundWindow() -eq $best) { break }
  $fgPid = 0
  $fgThread = [Fx]::GetWindowThreadProcessId([Fx]::GetForegroundWindow(), [ref]$fgPid)
  $me = [Fx]::GetCurrentThreadId()
  [void][Fx]::AttachThreadInput($me, $fgThread, $true)
  [void][Fx]::SetWindowPos($best, [IntPtr](-1), 0, 0, 0, 0, 0x0003)
  [void][Fx]::SetWindowPos($best, [IntPtr](-2), 0, 0, 0, 0, 0x0003)
  [void][Fx]::BringWindowToTop($best)
  [void][Fx]::SetForegroundWindow($best)
  [void][Fx]::AttachThreadInput($me, $fgThread, $false)
  Start-Sleep -Milliseconds 300
}
$r2 = New-Object Fx+RECT
[void][Fx]::GetWindowRect($best, [ref]$r2)
"hwnd=$($best.ToInt64()) isFg=$([Fx]::GetForegroundWindow() -eq $best) rect=$($r2.L),$($r2.T),$($r2.R),$($r2.B) title='$($t.ToString())'"
