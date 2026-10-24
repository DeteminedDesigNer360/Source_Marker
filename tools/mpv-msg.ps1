#Requires -Version 5.1
<#
  mpv-msg.ps1 —— 往运行中的 mpv 发 IPC 命令（本项目用来触发脚本的取证钩子）

  为什么存在：探针钩子（panel-pos / panel-grab / tl-set …）都是 mp.register_script_message，
  只能从 IPC 或按键触发。按键注入不可靠（gui_click 会被前台窗口抢），IPC 才是稳定通道。

  用法:
    # 起 mpv 时带 --input-ipc-server=\.\pipe\sm-ipc
    pwsh -File tools\mpv-msg.ps1 -Pipe sm-ipc -Messages "script-message panel-grab on","script-message state"
#>
[CmdletBinding()]
param(
    [string]$Pipe = "sm-ipc",
    [string[]]$Messages = @(),
    [int]$WaitMs = 600,
    [switch]$ReadReply
)
$ErrorActionPreference = "Stop"
# powershell -File 传数组时会被合成一个字符串（win-test.ps1 里同样的坑），所以兼容逗号分隔的写法
if ($Messages.Count -eq 1 -and $Messages[0] -match ',') {
    $Messages = @($Messages[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
$client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
try { $client.Connect(3000) } catch { throw "连不上管道 $Pipe（mpv 是否带 --input-ipc-server=\.\pipe\$Pipe 启动？）" }
$writer = New-Object System.IO.StreamWriter($client)
$writer.AutoFlush = $true
foreach ($m in $Messages) {
    $parts = $m -split " ", 2
    $cmd = @($parts[0])
    if ($parts.Count -gt 1) {
        # 后面的参数按空格再切一次；script-message 的每个参数单独占一项
        foreach ($p in ($parts[1] -split " ")) { if ($p -ne "") { $cmd += $p } }
    }
    $json = @{ command = $cmd } | ConvertTo-Json -Compress -Depth 4
    $writer.WriteLine($json)
    Start-Sleep -Milliseconds 120
}
Start-Sleep -Milliseconds $WaitMs
if ($ReadReply) {
    $reader = New-Object System.IO.StreamReader($client)
    $client.ReadTimeout = 2000
    try { $line = $reader.ReadLine(); if ($line) { $line } } catch { }
}
$writer.Dispose()
$client.Dispose()
Write-Output ("sent " + $Messages.Count + " command(s) to " + $Pipe)