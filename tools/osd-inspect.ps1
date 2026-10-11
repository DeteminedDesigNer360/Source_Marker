#Requires -Version 5.1
<#
  osd-inspect.ps1 —— 把 OSD 截图裁出来放大（必要时做像素级对比）

  为什么存在：mpv 的 OSD 文字在 2560 宽的窗口里很小，直接看图读不清；
  而 read_image 会缩图。裁出感兴趣的条带再放大，就能一眼看清文字/布局/是否越界。

  用法：
    pwsh -File tools\osd-inspect.ps1 -Image _tmp\shot-01-after-ENTER.png
    pwsh -File tools\osd-inspect.ps1 -Image a.png -Diff b.png          # 像素级回归对比
    pwsh -File tools\osd-inspect.ps1 -Image a.png -Region bottom -Zoom 3

  Region: bottom（默认，OSD 常在底部）| top | full | 或 "x,y,w,h"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Image,
    [string]$Diff,
    [string]$Region = 'bottom',
    [double]$Zoom = 2.0,
    [int]$MaxWidth = 1500,
    [string]$Out,
    [string]$Python
)
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $PSScriptRoot

function Find-Python {
    if ($Python -and (Test-Path $Python)) { return $Python }
    $cand = @(
        (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'),
        'python.exe', 'python3.exe'
    )
    foreach ($c in $cand) {
        try { $v = & $c -c "import PIL,sys;print(sys.version.split()[0])" 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { return $c } } catch {}
    }
    return $null
}
$py = Find-Python
if (-not $py) { throw '找不到带 Pillow 的 Python（可用 -Python 指定）' }

if (-not [System.IO.Path]::IsPathRooted($Image)) { $Image = Join-Path $work $Image }
if (-not (Test-Path $Image)) { throw "找不到图片：$Image" }
if (-not $Out) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Image)
    $Out = Join-Path ([System.IO.Path]::GetDirectoryName($Image)) ($base + '-inspect.png')
}

$script = @"
import sys
from PIL import Image, ImageChops
src = sys.argv[1]; out = sys.argv[2]; region = sys.argv[3]; zoom = float(sys.argv[4]); diff = sys.argv[6] if len(sys.argv) > 6 else ''
im = Image.open(src).convert('RGB')
W, H = im.size
if region == 'full':
    box = (0, 0, W, H)
elif region == 'top':
    box = (0, 0, W, max(1, int(H * 0.28)))
elif region == 'bottom':
    box = (0, int(H * 0.62), W, H)
elif region == 'bottomright':
    box = (int(W * 0.5), int(H * 0.62), W, H)
elif region == 'bottomleft':
    box = (0, int(H * 0.62), int(W * 0.5), H)
elif region == 'topleft':
    box = (0, 0, int(W * 0.5), int(H * 0.38))
elif region == 'center':
    box = (int(W * 0.2), int(H * 0.3), int(W * 0.8), int(H * 0.7))
else:
    parts = [int(x) for x in region.split(',')]
    box = (parts[0], parts[1], parts[0] + parts[2], parts[1] + parts[3])
crop = im.crop(box)
if zoom != 1.0:
    crop = crop.resize((int(crop.width * zoom), int(crop.height * zoom)), Image.LANCZOS)
maxw = int(sys.argv[5]) if len(sys.argv) > 5 else 1500
if maxw > 0 and crop.width > maxw:
    k = maxw / float(crop.width)
    crop = crop.resize((maxw, max(1, int(crop.height * k))), Image.LANCZOS)
    print('fit to %d px wide (so read_image keeps it sharp)' % maxw)
crop.save(out)
print('IMAGE %dx%d -> crop %s -> %dx%d (zoom %.1f)' % (W, H, str(box), crop.width, crop.height, zoom))
if diff:
    other = Image.open(diff).convert('RGB')
    if other.size != im.size:
        print('DIFF size mismatch: %s vs %s' % (str(im.size), str(other.size)))
    else:
        ch = ImageChops.difference(im, other)
        bbox = ch.getbbox()
        hist = ch.convert('L').histogram()
        total = im.size[0] * im.size[1]
        changed = sum(hist[8:])
        print('DIFF bbox=%s changed_px=%d (%.3f%%)' % (str(bbox), changed, 100.0 * changed / total))
"@
$tmpPy = Join-Path $env:TEMP ('osd-inspect-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.py')
[System.IO.File]::WriteAllText($tmpPy, $script, (New-Object System.Text.UTF8Encoding($false)))
$args = @($tmpPy, $Image, $Out, $Region, $Zoom, $MaxWidth)
if ($Diff) { if (-not [System.IO.Path]::IsPathRooted($Diff)) { $Diff = Join-Path $work $Diff }; $args += $Diff }
& $py @args
Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
Write-Output ('OUT ' + $Out)