param(
  [int]$Handle = 0,
  [string]$Actions = "",
  [int]$W = 1280,
  [int]$H = 800
)
if ($Handle -eq 0) { throw "need -Handle" }
$src = @'
using System;
using System.Runtime.InteropServices;
public class PRC {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint proc);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
}
'@
Add-Type -TypeDefinition $src
Add-Type -AssemblyName System.Drawing

function Raise-Win([IntPtr]$h) {
  if ([PRC]::IsIconic($h)) { [void][PRC]::SendMessage($h, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero); Start-Sleep -Milliseconds 150 }
  [void][PRC]::ShowWindow($h, 3)
  $fg = [PRC]::GetForegroundWindow()
  if ($fg -ne $h) {
    $proc = 0
    $fgT = [PRC]::GetWindowThreadProcessId($fg, [ref]$proc)
    $myT = [PRC]::GetCurrentThreadId()
    [void][PRC]::AttachThreadInput($myT, $fgT, $true)
    [void][PRC]::SetForegroundWindow($h)
    [void][PRC]::AttachThreadInput($myT, $fgT, $false)
    Start-Sleep -Milliseconds 120
  }
  return ([PRC]::GetForegroundWindow() -eq $h)
}

function Shot([string]$path) {
  $bmp = [System.Drawing.Bitmap]::new([int]$W, [int]$H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()
}

$h = [IntPtr]$Handle
$ok = Raise-Win $h
Write-Output ("raise: " + $ok)
$items = $Actions -split ';' | Where-Object { $_ -ne "" }
foreach ($it in $items) {
  $kv = $it -split ':', 2
  $cmd = $kv[0]
  $arg = if ($kv.Count -gt 1) { $kv[1] } else { "" }
  switch ($cmd) {
    "raise"  { $null = Raise-Win $h }
    "click"  {
      $xy = $arg -split ','
      [void][PRC]::SetCursorPos([int]$xy[0], [int]$xy[1])
      Start-Sleep -Milliseconds 40
      [PRC]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 40
      [PRC]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    }
    "down"   {
      $xy = $arg -split ','
      [void][PRC]::SetCursorPos([int]$xy[0], [int]$xy[1])
      Start-Sleep -Milliseconds 30
      [PRC]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    }
    "move"   {
      $xy = $arg -split ','
      [void][PRC]::SetCursorPos([int]$xy[0], [int]$xy[1])
    }
    "up"     { [PRC]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero) }
    "wait"   { Start-Sleep -Milliseconds ([int]$arg) }
    "shot"   { Shot $arg; Write-Output ("shot: " + $arg) }
    "key"    {
      # arg = vk code hex, e.g. key:24 for Home
      [void][PRC]::keybd_event([byte][Convert]::ToInt32($arg,16), 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 30
      [void][PRC]::keybd_event([byte][Convert]::ToInt32($arg,16), 0, 2, [IntPtr]::Zero)
    }
    default  { Write-Output ("skip: " + $cmd) }
  }
}
Write-Output ("fg-end: " + [PRC]::GetForegroundWindow())
