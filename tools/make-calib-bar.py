# -*- coding: utf-8 -*-
r"""生成校准图：在已知坐标画出"和 Pr 真机同色同形"的概览条 + 两个空心环。

配色/尺寸取自 Pr 2024 真机实测（1280x800）：背景 (35,35,35)、条 (49,49,49)、
环为空心圆、灰度约 128、直径 8~9 px、条端外侧凸出约 4 px。
真值写进同名 .gt.json，事后可用 tools\px-measure.py 打开图自己点环心核对。

用法: python tools\make-calib-bar.py
产物: docs\测量-校准\calib-居中.png / calib-贴边.png / calib-最小.png / *.gt.json
"""
import json
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'docs', '测量-校准')

W, H = 1280, 800
Y = 400
X0, X1 = 20, 1260
BAR_H = 8
CR = 4.5
BG = (35, 35, 35)
BAR = (49, 49, 49)
RING = (128, 128, 128)

CASES = {
    'calib-居中': dict(dur=300.0, t0=30.0, t1=90.0),
    'calib-贴边': dict(dur=300.0, t0=0.0, t1=150.0),
    'calib-最小': dict(dur=300.0, t0=150.0, t1=153.0),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    rw = X1 - X0
    for name, c in CASES.items():
        im = Image.new('RGB', (W, H), BG)
        d = ImageDraw.Draw(im)
        d.rectangle([X0, Y - BAR_H // 2, X1, Y + BAR_H // 2], fill=BAR)
        lc = X0 + rw * (c['t0'] / c['dur'])
        rc = X0 + rw * (c['t1'] / c['dur'])
        for cx in (lc, rc):
            d.ellipse([cx - CR, Y - CR, cx + CR, Y + CR], outline=RING, width=1)
        png = os.path.join(OUT, name + '.png')
        im.save(png)
        gt = dict(x0=X0, x1=X1, y=Y, l=round(lc, 3), r=round(rc, 3), cr=CR, **c)
        with open(os.path.join(OUT, name + '.gt.json'), 'w', encoding='utf-8') as f:
            json.dump(gt, f, ensure_ascii=False, indent=1)
        print('%-10s t0=%.2f t1=%.2f -> l=%.2f r=%.2f' % (name, c['t0'], c['t1'], lc, rc))
    print('out:', OUT)


if __name__ == '__main__':
    main()
