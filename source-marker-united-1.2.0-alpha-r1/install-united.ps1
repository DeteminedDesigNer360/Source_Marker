# install-united.ps1 —— 合并包 一键安装 / 卸载
#
# 一般通过同目录的 安装.cmd / 卸载.cmd 调用；也可以直接跑：
#   .\install-united.ps1                  安装（默认装「新手版」Pr 面板）
#   .\install-united.ps1 -Variant full    安装「完整版」Pr 面板
#   .\install-united.ps1 -Uninstall       卸载
#   .\install-united.ps1 -DryRun          只打印将要做什么，不改动任何文件/注册表，也不提权
#   .\install-united.ps1 -PrOnly          只装 Pr 面板，不动「打开方式」
#   .\install-united.ps1 -PlayerOnly      只处理播放器（注册「打开方式」+ 写面板用的路径）
#
# 它做三件事：
#   1) 装 Pr 面板 —— 复用 pr-extension\<变体>\install.ps1，不重复实现任何逻辑
#   2) 把本包的 mpv 注册进「打开方式」—— 调用 mpv.exe --register
#      （mpv 自己写 HKCU\Software\RegisteredApplications\mpv，用户级）
#   3) 把 mpv.exe 的绝对路径写进 CEP 扩展目录的 player-path.txt
#      面板启动时会读它 → 第一次使用也不用再手动选播放器
#
# 为什么显式用 mpv.exe 而不是包里那个 mpv-register.bat：
#   那个 .bat 写的是 "%~dp0/mpv"，cmd 按 PATHEXT 会先命中 mpv.com，
#   于是把**控制台版**注册进「打开方式」（打开视频会弹一个黑窗口）。
#
# 本文件必须保持 UTF-8 带 BOM（与仓库其它 .ps1 同规矩：否则 PS 5.1 按 ANSI 解码中文会语法错误）。

[CmdletBinding()]
param(
    [ValidateSet('novice', 'full')][string]$Variant,
    [switch]$Uninstall,
    [switch]$DryRun,        # 只计划不执行：不改文件、不改注册表、**不提权**
    [switch]$PrOnly,
    [switch]$PlayerOnly,
    [switch]$NoPause,
    [switch]$Pause          # 内部用：提权后的那份结束时停一下，好让用户看到结果
)

$ErrorActionPreference = 'Stop'
$bundleId = 'com.frisk.sourcemarker'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw '无法定位脚本所在目录：请用 powershell -ExecutionPolicy Bypass -File install-united.ps1 运行' }

$prRoot = Join-Path $here 'pr-extension'
$mpvExe = Join-Path $here 'mpv-player\mpv.exe'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 包版本从 Pr 清单里读 —— 单一数据源，不在这里另写一份免得漂移
function Get-PackageVersion {
    try {
        $mf = Join-Path $prRoot '新手版\extension\CSXS\manifest.xml'
        if (-not (Test-Path $mf)) { $mf = Join-Path $prRoot '完整版\extension\CSXS\manifest.xml' }
        if (-not (Test-Path $mf)) { return '?' }
        $t = [System.IO.File]::ReadAllText($mf, [System.Text.Encoding]::UTF8)
        return [string]([xml]$t).ExtensionManifest.ExtensionBundleVersion
    } catch { return '?' }
}

# CEP 会扫描这两个位置，install.ps1 默认装系统级，但用户可能用 -User 装过
$commonExt = Join-Path $env:CommonProgramFiles 'Adobe\CEP\extensions'
$userExt = Join-Path $env:APPDATA 'Adobe\CEP\extensions'
function Get-InstalledTargets {
    $r = @()
    foreach ($root in @($commonExt, $userExt)) {
        $t = Join-Path $root $bundleId
        if (Test-Path $t) { $r += $t }
    }
    return $r
}

function Write-PlayerPointer([string]$value) {
    $targets = Get-InstalledTargets
    if ($targets.Count -eq 0) {
        # 卸载时第 1 步已经把扩展目录删掉，这里"找不到"是正常的，不必报
        if ($value) {
            Write-Host '  （没找到已安装的 Pr 面板，跳过 player-path.txt）' -ForegroundColor Yellow
            Write-Host '   面板装好后重跑一次本脚本，或直接用 -PlayerOnly。' -ForegroundColor Yellow
        }
        return
    }
    foreach ($t in $targets) {
        $p = Join-Path $t 'player-path.txt'
        if ($value) {
            # 先把原来记的读出来：如果指向别处，**明确说出来** —— 真机上"路径过期"的困惑
            # 多半来自桌面上还留着旧包、而跑的是旧包里的 安装.cmd（谁最后写谁说了算）。
            $old = ''
            if (Test-Path $p) {
                try { $old = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8).Trim() } catch {}
            }
            if ($old -and $old -ne $value) {
                Write-Host "  （原来记的是：$old —— 现在改成下面这个）" -ForegroundColor Yellow
            }
            # 不带 BOM 的 UTF-8：安装路径里可能有中文
            [System.IO.File]::WriteAllText($p, $value, (New-Object System.Text.UTF8Encoding($false)))
            # 写完读回来核对 —— 本项目的纪律：不信"调用了"，只信"读回来的"。
            # 这条能挡住"写了却没落到盘上"这类静默失败。
            $back = ''
            try { $back = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8).Trim() } catch {}
            if ($back -ne $value) {
                throw "player-path.txt 回读校验失败（$p）：期望 $value，读回 $back"
            }
            Write-Host "  播放器路径已写入并回读校验通过 → $p" -ForegroundColor Green
        } elseif (Test-Path $p) {
            Remove-Item $p -Force
            Write-Host "  播放器路径已移除 → $p" -ForegroundColor Green
        }
    }
}

# 调 mpv 自带的注册/注销，并把它的输出显出来（失败时能自证）
function Invoke-MpvAssociate([bool]$unregister) {
    if (-not (Test-Path $mpvExe)) { throw "找不到播放器：$mpvExe" }
    $arg = '--register'
    if ($unregister) { $arg = '--unregister' }
    $out = Join-Path $env:TEMP 'sm-mpv-assoc-out.txt'
    $err = Join-Path $env:TEMP 'sm-mpv-assoc-err.txt'
    foreach ($f in @($out, $err)) { if (Test-Path $f) { Remove-Item $f -Force } }
    $p = Start-Process -FilePath $mpvExe -ArgumentList $arg -Wait -PassThru -WindowStyle Hidden `
                       -RedirectStandardOutput $out -RedirectStandardError $err
    foreach ($f in @($out, $err)) {
        if (Test-Path $f) {
            Get-Content $f -Encoding UTF8 | Where-Object { $_ -ne '' } | ForEach-Object {
                Write-Host "    [mpv] $_" -ForegroundColor DarkGray
            }
        }
    }
    return [int]$p.ExitCode
}

# 调 Pr 的安装器。注意：**不能**只写 `& powershell @a` ——
# 那样会把子进程的 stdout 混进本函数的返回值，于是"退出码"变成数组，
# `$code -ne 0` 恒为真 → 明明装成功了却报"有步骤失败"（r5 就是这么错的）。
# 这里用 `2>&1 | Out-Host` 把输出送进主机（不进管道）；stderr 先并进来，
# 免得 PS 5.1 把原生命令的 stderr 包成 NativeCommandError 撞上 $ErrorActionPreference='Stop'。
function Invoke-PrInstaller([string]$variant, [bool]$uninstall, [bool]$dry) {
    $map = @{ novice = '新手版'; full = '完整版' }
    $ps1 = Join-Path $prRoot ($map[$variant] + '\install.ps1')
    if (-not (Test-Path $ps1)) { throw "找不到 Pr 安装脚本：$ps1" }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1)
    if ($uninstall) { $a += '-Uninstall' }
    if ($dry)       { $a += '-DryRun' }
    & powershell @a 2>&1 | Out-Host
    return [int]$LASTEXITCODE
}

Write-Host ''
Write-Host '================ Source Marker 合并包 ================' -ForegroundColor Cyan
Write-Host "  目录  : $here"
Write-Host "  版本  : $(Get-PackageVersion)（面板启动日志里会显示含迭代号的完整标识）"
if ($Uninstall) { Write-Host '  动作  : 卸载' -ForegroundColor Yellow }
else            { Write-Host '  动作  : 安装' -ForegroundColor Yellow }
if ($DryRun)    { Write-Host '  模式  : DryRun —— 不会改动任何文件/注册表，也不会提权' -ForegroundColor Yellow }
Write-Host ''

# ---------- 先问清装哪个变体（提权之前问，免得提权后还要再选一次）----------
if (-not $Uninstall -and -not $PlayerOnly -and -not $Variant) {
    Write-Host '装哪个 Pr 面板？（两个都用同一个扩展 ID，装一个就行）' -ForegroundColor Cyan
    Write-Host '  [1] 新手版 —— 日常使用（推荐）'
    Write-Host '  [2] 完整版 —— 多出自检、导出策略选择、文件名模板'
    $c = Read-Host '请输入 1 或 2（直接回车 = 1）'
    if ($c -eq '2') { $Variant = 'full' } else { $Variant = 'novice' }
}
if (-not $Variant) { $Variant = 'novice' }

# ---------- 提权（DryRun 绝不提权 —— 计划阶段不需要任何权限）----------
if (-not (Test-Admin) -and -not $DryRun) {
    Write-Host '需要管理员权限（要写入 Program Files），正在请求提权…' -ForegroundColor Yellow
    Write-Host '  ⚠ 会弹出 UAC 确认框；不确认就什么都不会发生。' -ForegroundColor Yellow
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"'),
           '-Variant', $Variant, '-Pause')
    if ($Uninstall)  { $a += '-Uninstall' }
    if ($PrOnly)     { $a += '-PrOnly' }
    if ($PlayerOnly) { $a += '-PlayerOnly' }
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $a
    } catch {
        throw "提权被拒绝。请右键本文件 →「以管理员身份运行」。"
    }
    Write-Host '已请求提权。'
    Write-Host '  * 如果出现了新的（管理员）窗口，请在那里看结果。'
    Write-Host '  * 如果没有出现新窗口，说明 UAC 没有放行 —— 请右键本文件 →「以管理员身份运行」。'
    exit 0
}

$failed = @()

# ---------- ① Pr 面板 ----------
if (-not $PlayerOnly) {
    $label = @{ novice = '新手版'; full = '完整版' }[$Variant]
    Write-Host "[1/3] Pr 面板（$label）" -ForegroundColor Cyan
    try {
        $code = Invoke-PrInstaller $Variant $Uninstall.IsPresent $DryRun.IsPresent
        if ($code -ne 0) { $failed += "Pr 面板（退出码 $code）" }
    } catch {
        $failed += "Pr 面板：$($_.Exception.Message)"
    }
    Write-Host ''
}

# ---------- ② 播放器「打开方式」 ----------
if (-not $PrOnly) {
    Write-Host '[2/3] 播放器「打开方式」' -ForegroundColor Cyan
    if ($DryRun) {
        $assocArg = '--register'
        if ($Uninstall) { $assocArg = '--unregister' }
        Write-Host "  [将执行] `"$mpvExe`" $assocArg" -ForegroundColor DarkGray
        Write-Host '  （DryRun：不会真的调用 mpv，也不改注册表）' -ForegroundColor DarkGray
    } else {
        try {
            $code = Invoke-MpvAssociate $Uninstall.IsPresent
            if ($code -eq 0) {
                if ($Uninstall) { Write-Host '  已从「打开方式」移除' -ForegroundColor Green }
                else            { Write-Host '  已加入「打开方式」（右键任意视频 → 打开方式 → mpv）' -ForegroundColor Green }
            } else {
                $failed += "播放器关联（退出码 $code）"
            }
        } catch {
            $failed += "播放器关联：$($_.Exception.Message)"
        }
    }
    Write-Host ''
}

# ---------- ③ 面板用的播放器路径 ----------
if (-not $PrOnly) {
    Write-Host '[3/3] 面板内的播放器路径' -ForegroundColor Cyan
    if ($DryRun) {
        # 预测要准：安装时第 1 步会先把面板装好，所以目标就是系统级安装位置；
        # 卸载时第 1 步会把扩展目录整个删掉，这一步实际无事可做。
        if ($Uninstall) {
            Write-Host '  [DryRun] 第 1 步会删掉扩展目录，player-path.txt 随之消失 —— 这一步实际无事可做' -ForegroundColor DarkGray
        } elseif (-not $PlayerOnly) {
            $pp = Join-Path (Join-Path $commonExt $bundleId) 'player-path.txt'
            Write-Host "  [将写入] $pp  ←  $mpvExe" -ForegroundColor DarkGray
            Write-Host '  （第 1 步刚装好面板，所以这一步会真的写入）' -ForegroundColor DarkGray
        } else {
            $targets = Get-InstalledTargets
            if ($targets.Count -eq 0) {
                Write-Host '  [DryRun] 没找到已安装的 Pr 面板 —— 实际执行时这一步会被跳过' -ForegroundColor DarkGray
                Write-Host '   （面板装好后重跑，或去掉 -PlayerOnly 连面板一起装）' -ForegroundColor DarkGray
            } else {
                foreach ($t in $targets) {
                    Write-Host "  [将写入] $(Join-Path $t 'player-path.txt')  ←  $mpvExe" -ForegroundColor DarkGray
                }
            }
        }
    } else {
        try {
            if ($Uninstall) { Write-PlayerPointer '' }
            else            { Write-PlayerPointer $mpvExe }
        } catch {
            $failed += "player-path.txt：$($_.Exception.Message)"
        }
    }
    Write-Host ''
}

# ---------- 汇总 ----------
Write-Host '================ 结果 ================' -ForegroundColor Cyan
if ($DryRun) {
    Write-Host ' DryRun 结束：以上只是计划，没有改动任何东西。' -ForegroundColor Yellow
    Write-Host ' 确认无误后，去掉 -DryRun 再跑一次即可真正执行。'
} elseif ($failed.Count -eq 0) {
    Write-Host ' 全部完成' -ForegroundColor Green
    if (-not $Uninstall) {
        Write-Host ''
        Write-Host '下一步：'
        Write-Host '  1) 完全退出 Premiere Pro（任务管理器确认没有残留进程）再重新打开'
        Write-Host '  2) 顶部菜单 窗口 > 扩展 > Source Marker'
        Write-Host '  3) 想看片打标记：右键视频 → 打开方式 → mpv，或双击本包 mpv-player\mpv.exe'
    }
} else {
    Write-Host ' 有步骤失败：' -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "   - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '播放器是绿色便携的，没注册成功不影响使用 —— 双击 mpv-player\mpv.exe 照旧能看。'
}
if (-not $DryRun) {
    if (-not $Uninstall) {
        Write-Host ''
        Write-Host '卸载：双击本包根目录的 卸载.cmd'
    } else {
        Write-Host ''
        Write-Host '注意：播放器本体（mpv-player 文件夹）是绿色便携的，本脚本不会删除它 ——'
        Write-Host '      不要了整个文件夹删掉即可。'
    }
}
Write-Host ''

if ($Pause -and -not $NoPause) { Read-Host '按 Enter 关闭窗口' | Out-Null }
