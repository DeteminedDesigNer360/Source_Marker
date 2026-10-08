# run-all-tests.ps1 —— 一次跑完本工作区的离线测试
#
#   1) BOM 自检        tools\ensure-ps1-bom.ps1    （.ps1 必须带 UTF-8 BOM；缺了就补）
#   2) 离线断言        tools\_sm-export-test.js    （74 项：契约样例 / 编码器 / 时间码 / 边界）
#   3) 发行包自检      source-marker-united-1.1.0\mpv-player\校验.ps1  （16 个文件 SHA256）
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
    if ($LASTEXITCODE -ne 0) { $script:fail++; Write-Host ('   ✗ 失败（退出码 ' + $LASTEXITCODE + '）') -ForegroundColor Red }
    else { Write-Host '   ✓ 通过' -ForegroundColor Green }
}

Run-Step 'BOM 自检（.ps1 必须带 UTF-8 BOM）' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\ensure-ps1-bom.ps1')
}
Run-Step '离线断言（74 项）' {
    & node (Join-Path $root 'tools\_sm-export-test.js')
}
Run-Step '发行包自检（16 个文件 SHA256）' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'source-marker-united-1.1.0\mpv-player\校验.ps1')
}

Write-Host ''
if ($fail -eq 0) { Write-Host '全部通过 ✓' -ForegroundColor Green; exit 0 }
else { Write-Host ($fail.ToString() + ' 个步骤失败 ✗') -ForegroundColor Red; exit 1 }