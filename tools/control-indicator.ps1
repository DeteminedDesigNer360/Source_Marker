# control-indicator.ps1 —— 屏幕左上角的「AI 正在操控鼠标/键盘」指示条
#
# 为什么要它：我用 gui_click / gui_drag / gui_type 直接操作真实鼠标键盘，你很可能正在
# 用同一台机器做别的事。这个条子在任何操控开始前亮起、结束后消失，好让你知道现在别动手。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\control-indicator.ps1 -Text "DSH 正在拖动 Pr 的缩放条" -Seconds 30
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\control-indicator.ps1 -Stop
#
# 设计约束（很关键）：
#   · 绝不抢焦点 —— 窗口设 WS_EX_NOACTIVATE，否则会把 Pr/mpv 弄成失焦，而我又正要往那里点，结果点空。
#   · 固定贴在左上角、无边框、半透明、不进任务栏，不挡标题栏和右键菜单。
#   · 只有一份：新实例会先把旧的停掉（PID 记在 _tmp\control-indicator.pid）。
# 注意：本文件必须保持 UTF-8 **带 BOM**。

[CmdletBinding()]
param(
    [string]$Text = 'DSH 正在操控鼠标/键盘',
    [int]$Seconds = 20,
    [switch]$Stop,
    [int]$X = 12,
    [int]$Y = 44
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $workspace '_tmp\control-indicator.pid'

function Stop-Indicator {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' or Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*control-indicator.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Stop) { Stop-Indicator; return }

Stop-Indicator

if (-not ('DshControlW32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DshControlW32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$WS_EX_NOACTIVATE = 0x08000000
$WS_EX_TOOLWINDOW = 0x00000080
$GWL_EXSTYLE = -20

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH control indicator'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point($X, $Y)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::Black
$form.Opacity = 0.93

$label = New-Object System.Windows.Forms.Label
$label.Text = [char]0x25C9 + '  ' + $Text
$label.AutoSize = $true
$label.Padding = New-Object System.Windows.Forms.Padding(10, 5, 12, 5)
$label.BackColor = [System.Drawing.Color]::FromArgb(230, 20, 20, 20)
$label.ForeColor = [System.Drawing.Color]::FromArgb(255, 210, 60)
$label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($label)
$form.Size = $label.PreferredSize

# 句柄一建好就把 NOACTIVATE 装上，这样 Show 不会抢焦点
$null = $form.Handle
$ex = [DshControlW32]::GetWindowLong($form.Handle, $GWL_EXSTYLE)
$null = [DshControlW32]::SetWindowLong($form.Handle, $GWL_EXSTYLE, ($ex -bor $WS_EX_NOACTIVATE -bor $WS_EX_TOOLWINDOW))

$form.Add_Shown({
    $form.Size = $label.PreferredSize
    Set-Content -Path $pidFile -Value $PID -Encoding ASCII
    if ($Seconds -gt 0) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [Math]::Max(200, $Seconds * 1000)
        $timer.Add_Tick({ $timer.Stop(); $form.Close() })
        $timer.Start()
        $script:keepTimer = $timer
    }
})
$form.Add_FormClosed({ Remove-Item $pidFile -Force -ErrorAction SilentlyContinue })

[System.Windows.Forms.Application]::Run($form)
