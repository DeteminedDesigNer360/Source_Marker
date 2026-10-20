# 收尾第 3 步：把工作区镜像进 git 工作树 _branch-work（保留 .git）
# 血的教训（r46 第十四轮）：/XD 必须写【源侧】路径。写过目标路径（$Dst）等于没排除，
# /MIR 会把 _branch-work\.git 当成 EXTRA 文件全删掉（本次丢了 27c49ed / 48935fe 两个提交，
# 靠 C:\Users\Frisk\Documents\GitHub\Source_Marker\.git 的 origin/workspace 才重建回来）。
param([string]$Src = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
$Dst = Join-Path $Src '_branch-work'
$gitDir = Join-Path $Dst '.git'
if (-not (Test-Path $gitDir)) { throw "目标不是 git 工作树（缺少 $gitDir），拒绝 /MIR" }

robocopy $Src $Dst /MIR /XD (Join-Path $Src '_branch-work') (Join-Path $Src '.git') (Join-Path $Src '_tmp') /XF 'ffmpeg.exe' /NFL /NDL /NJH /NJS /NP
$code = $LASTEXITCODE
if (-not (Test-Path $gitDir)) { throw "镜像后 .git 丢失！用 GitHub\Source_Marker 的 .git 重建后再提交" }
if ($code -ge 8) { throw "robocopy 失败（exit=$code）" }
"镜像完成：robocopy exit=$code，.git 完好（$(Get-ChildItem $gitDir -Force | Measure-Object).Count 项）"
