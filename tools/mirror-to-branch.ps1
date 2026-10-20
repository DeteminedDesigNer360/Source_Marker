# 收尾第 3 步：把工作区镜像进 git 工作树 _branch-work（保留 .git）
# 血的教训（r46 第十四轮，实测两次）：/MIR 即使写了 /XD 也会把目标侧的 .git 当 EXTRA 删掉
# （.git 在目标根，源侧同名的 .git 被 /XD 跳过 ⇒ 删除阶段认为"源里没有"）。
# 所以这里用 /E（只增改不删除）+ 先备份 .git + 跑后校验 + 失败自动回滚。
param([string]$Src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
$Dst = Join-Path $Src '_branch-work'
$gitDir = Join-Path $Dst '.git'
$backup = Join-Path $Src '_tmp\git-backup'
if (-not (Test-Path (Join-Path $gitDir 'HEAD'))) { throw "目标不是 git 工作树（$gitDir 缺 HEAD），拒绝执行" }

New-Item -ItemType Directory -Force -Path $backup | Out-Null
robocopy $gitDir $backup /E /NFL /NDL /NJH /NJS /NP | Out-Null
if (-not (Test-Path (Join-Path $backup 'HEAD'))) { throw "备份 .git 失败，拒绝镜像" }

robocopy $Src $Dst /E /XD (Join-Path $Src '_branch-work') (Join-Path $Src '.git') (Join-Path $Src '_tmp') /XF 'ffmpeg.exe' /NFL /NDL /NJH /NJS /NP | Out-Null
$code = $LASTEXITCODE
if (-not (Test-Path (Join-Path $gitDir 'HEAD'))) {
    robocopy $backup $gitDir /E /NFL /NDL /NJH /NJS /NP | Out-Null
    throw "镜像后 .git 丢失，已从 $backup 回滚；请检查 robocopy 参数"
}
if ($code -ge 8) { throw "robocopy 失败（exit=$code）" }
"镜像完成：robocopy exit=$code，.git 完好"
