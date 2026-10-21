param([int]$Handle = 0, [int]$IntervalMs = 200)
if ($Handle -eq 0) { throw "need -Handle" }
$src = @'
using System;
using System.Runtime.InteropServices;
public class KP { 
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint proc);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@
Add-Type -TypeDefinition $src
$h = [IntPtr]$Handle
while ($true) {
  try {
    if ([KP]::IsIconic($h)) { [void][KP]::ShowWindow($h, 9) }
    $fg = [KP]::GetForegroundWindow()
    if ($fg -ne $h) {
      $proc = 0
      $fgT = [KP]::GetWindowThreadProcessId($fg, [ref]$proc)
      $myT = [KP]::GetCurrentThreadId()
      [void][KP]::AttachThreadInput($myT, $fgT, $true)
      [void][KP]::BringWindowToTop($h)
      [void][KP]::SetForegroundWindow($h)
      [void][KP]::AttachThreadInput($myT, $fgT, $false)
    }
  } catch { }
  Start-Sleep -Milliseconds $IntervalMs
}
