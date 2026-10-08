# run-all-tests.ps1 —— 一次跑完本工作区的离线测试（全绿才返回 0）
#
#   1) BOM 自检      tools\ensure-ps1-bom.ps1 -CheckOnly            （只查不改：避免动到 Archive 里的只读基线）
#   2) 离线断言      tools\_sm-export-test.js                       （74 项：契约样例 / 编码器 / 时间码 / 边界）
#   3) 发行包自检    source-marker-united-1.1.0\mpv-player\校验.ps1  （16 个文件 SHA256）
#   4) 读取方契约    tools\verify-import.js                         （用 Pr 真实解析段，28 项）
#   5) 许可取证      tools\collect-mpv-provenance.py --quiet         （从分发的 mpv.exe 重新证明是 GPL 构建）
#
# 另有 tools\verify-ntsc.js（29.97fps 时间码漂移回归）**故意不入本清单**：
# 随包带的 verify-data\ntsc_long.*（20260707 实测产物）本身记录的就是一次真实漂移 ——
# 跑它会 FAIL，那正是它在正常工作。要用请换成你自己新跑的数据与对应用例文件。
#
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File run-all-tests.ps1
# 注意：本文件必须保持 UTF-8 **带 BOM**。

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$ps   = 'powershell'
$fail = 0

function Run-Step([string]$name, [scriptblock]$body) {
    Write-Host ''
    Write-Host ('== ' + $name) -ForegroundColor Cyan
    & $body
    if ($LASTEXITCODE -ne 0) { $script:fail++; Write-Host ('   x 失败（退出码 ' + $LASTEXITCODE + '）') -ForegroundColor Red }
    else { Write-Host '   OK 通过' -ForegroundColor Green }
}

Run-Step 'BOM 自检（.ps1 必须带 UTF-8 BOM；只查不改）' {
    $bomOut = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\ensure-ps1-bom.ps1') -CheckOnly 2>&1
    $bomOut | ForEach-Object { Write-Host ('   ' + $_) }
    if (($bomOut -join [Environment]::NewLine) -match '缺 BOM') { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
}
Run-Step '离线断言（74 项）' {
    & node (Join-Path $root 'tools\_sm-export-test.js')
}
Run-Step '发行包自检（16 个文件 SHA256）' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'source-marker-united-1.1.0\mpv-player\校验.ps1')
}
Run-Step '读取方契约（用 Pr 真实解析段）' {
    & node (Join-Path $root 'tools\verify-import.js')
}
Run-Step '许可取证（从分发的 mpv.exe 重新证明是 GPL 构建）' {
    & python (Join-Path $root 'tools\collect-mpv-provenance.py') --quiet
}

Write-Host ''
if ($fail -eq 0) { Write-Host '全部通过' -ForegroundColor Green; exit 0 }
else { Write-Host ($fail.ToString() + ' 个步骤失败') -ForegroundColor Red; exit 1 }