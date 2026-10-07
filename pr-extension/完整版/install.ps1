# install.ps1 —— 把 Source Marker CEP 扩展装进 Premiere Pro
#
# 用法：
#   .\install.ps1                装到系统级目录（需要管理员，脚本会自动请求提权）
#   .\install.ps1 -User          装到当前用户目录（不需要管理员）
#   .\install.ps1 -DryRun        只打印将要做什么，不改动任何文件/注册表
#   .\install.ps1 -Uninstall     卸载（两个位置都清理）
#
# 为什么默认系统级：
#   本机实测（Pr 24.0.0）：用户级目录 %APPDATA%\Adobe\CEP\extensions 从未被创建过，
#   而系统级目录里的扩展能被正常识别。两个位置 CEP 都会扫描，但用户级要求该目录
#   在 Premiere 启动前就已存在——首次安装时最容易踩这个坑。
#
# 注册表：只写 HKCU（本机可用配置实测为 HKCU\Software\Adobe\CSXS.11\PlayerDebugMode=1），
#   系统级扩展同样读 HKCU，因此不需要 HKLM、也不需要为注册表提权。
#
# 本文件必须保持 UTF-8 **带 BOM**（否则 Windows PowerShell 5.1 按 ANSI 解码中文会语法错误）。

[CmdletBinding()]
param(
    [switch]$User,
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$bundleId = 'com.frisk.sourcemarker'

# ---------- 定位脚本与源目录 ----------
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { throw '无法定位脚本所在目录：请用  powershell -ExecutionPolicy Bypass -File install.ps1  运行' }
$source = Join-Path $here 'extension'

$commonRoot = Join-Path $env:CommonProgramFiles 'Adobe\CEP\extensions'
$userRoot   = Join-Path $env:APPDATA 'Adobe\CEP\extensions'
$sysTarget  = Join-Path $commonRoot $bundleId
$userTarget = Join-Path $userRoot $bundleId

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Plan([string]$action, [string]$path) {
    Write-Host ("  [{0}] {1}" -f $action, $path)
}

# ============================== 卸载 ==============================
if ($Uninstall) {
    Write-Host '卸载 Source Marker' -ForegroundColor Cyan
    $removed = 0
    foreach ($t in @($sysTarget, $userTarget)) {
        if (-not (Test-Path $t)) { Write-Host "  跳过（不存在）：$t"; continue }
        if ($DryRun) { Write-Host "  [将删除] $t"; continue }
        try {
            Remove-Item $t -Recurse -Force
            Write-Host "  已删除：$t" -ForegroundColor Green
            $removed++
        } catch {
            Write-Warning "  删除失败（需要管理员？）：$t`n    $($_.Exception.Message)"
        }
    }
    Write-Host ''
    Write-Host '注册表 PlayerDebugMode 未改动（其它扩展可能依赖它）。如需还原，请手动删除：'
    Write-Host '  HKCU\Software\Adobe\CSXS.9~13 下的 PlayerDebugMode'
    Write-Host ''
    Write-Host '完全退出并重启 Premiere Pro 后生效。'
    exit 0
}

# ============================== 校验源 ==============================
$srcManifest = Join-Path $source 'CSXS\manifest.xml'
if (-not (Test-Path $srcManifest)) {
    throw "找不到扩展源：$srcManifest`n请确认 install.ps1 与 extension\ 目录在同一层。"
}

# 目标位置
$target      = if ($User) { $userTarget } else { $sysTarget }
$targetRoot  = if ($User) { $userRoot }   else { $commonRoot }
$otherTarget = if ($User) { $sysTarget }  else { $userTarget }
$needsAdmin  = -not $User

Write-Host '安装 Source Marker' -ForegroundColor Cyan
Write-Host "  源目录   : $source"
Write-Host "  目标     : $target"
Write-Host "  安装范围 : $(if ($User) { '当前用户' } else { '所有用户（系统级）' })"
if ($DryRun) { Write-Host '  模式     : DryRun（不会改动任何东西）' -ForegroundColor Yellow }
Write-Host ''

# ============================== 提权 ==============================
if ($needsAdmin -and -not $DryRun -and -not (Test-Admin)) {
    Write-Host "写入 $commonRoot 需要管理员权限，正在请求提权…" -ForegroundColor Yellow
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $scriptPath + '"'))
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $args
    } catch {
        throw "提权被取消。可改用：  .\install.ps1 -User   （装到当前用户目录，不需要管理员）"
    }
    Write-Host '已在新窗口中继续，请在该窗口查看结果。'
    exit 0
}

# ============================== 安装 ==============================
if ($DryRun) {
    Show-Plan '将创建' $targetRoot
    Show-Plan '将清空并重建' $target
    Show-Plan '将复制' "$source\* -> $target"
} else {
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force
        Write-Host '  已清理旧版本（避免残留过期文件）'
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    # 复制"内容"而不是目录本身，避免 PowerShell 的 目标\源目录名\ 嵌套陷阱
    Copy-Item (Join-Path $source '*') $target -Recurse -Force
    Write-Host '  文件已复制' -ForegroundColor Green
}

# ============================== 注册表（HKCU，9~13 全覆盖） ==============================
$regVersions = 9, 10, 11, 12, 13
if ($DryRun) {
    foreach ($v in $regVersions) { Show-Plan '将设置 PlayerDebugMode=1' "HKCU:\Software\Adobe\CSXS.$v" }
} else {
    foreach ($v in $regVersions) {
        $key = "HKCU:\Software\Adobe\CSXS.$v"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'PlayerDebugMode' -Value '1' -PropertyType String -Force | Out-Null
    }
    Write-Host '  已开启 PlayerDebugMode（HKCU\Software\Adobe\CSXS.9 ~ CSXS.13）' -ForegroundColor Green
}

# ============================== 安装后校验 ==============================
if (-not $DryRun) {
    Write-Host ''
    Write-Host '校验：' -ForegroundColor Cyan
    $ok = $true

    $dstManifest = Join-Path $target 'CSXS\manifest.xml'
    if (Test-Path $dstManifest) {
        Write-Host '  [OK] manifest.xml 就位（没有嵌套成 目标\extension\）' -ForegroundColor Green
    } else {
        Write-Host "  [失败] 找不到 $dstManifest" -ForegroundColor Red
        $ok = $false
    }

    foreach ($f in @('client\index.html', 'client\main.js', 'client\CSInterface.js', 'host\hostscript.jsx')) {
        if (Test-Path (Join-Path $target $f)) { Write-Host "  [OK] $f" -ForegroundColor Green }
        else { Write-Host "  [失败] 缺少 $f" -ForegroundColor Red; $ok = $false }
    }

    # 逐文件比对，确认装的就是仓库当前版本
    $diff = @()
    # -Force 才会把隐藏文件（.debug）计入比对
    foreach ($f in (Get-ChildItem $source -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($source.Length).TrimStart('\')
        $dst = Join-Path $target $rel
        if (-not (Test-Path $dst)) { $diff += "缺失 $rel"; continue }
        if ((Get-FileHash $f.FullName -Algorithm MD5).Hash -ne (Get-FileHash $dst -Algorithm MD5).Hash) { $diff += "内容不一致 $rel" }
    }
    if ($diff.Count -eq 0) { Write-Host '  [OK] 与仓库版本逐文件一致' -ForegroundColor Green }
    else { foreach ($d in $diff) { Write-Host "  [失败] $d" -ForegroundColor Red }; $ok = $false }

    if (Test-Path $otherTarget) {
        Write-Host ''
        Write-Host "  注意：另一个位置也装了一份：$otherTarget" -ForegroundColor Yellow
        Write-Host '        两份同时存在可能加载到旧的那份，建议卸载其一（.\install.ps1 -Uninstall 会两个都清）。'
    }

    Write-Host ''
    if ($ok) { Write-Host '安装完成。' -ForegroundColor Green } else { Write-Host '安装未通过校验。' -ForegroundColor Red }
}

Write-Host ''
Write-Host '下一步：完全退出并重启 Premiere Pro → 菜单 窗口 > 扩展 > Source Marker'
Write-Host '（若菜单里没有：确认 Pr 已完全退出，且注册表 HKCU\Software\Adobe\CSXS.11\PlayerDebugMode = 1）'
