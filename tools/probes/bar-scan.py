# -*- coding: utf-8 -*-
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p).convert('RGB')
# 找缩放条那一行：y 680..710，输出每行的亮段（亮度 > 60 的连续段）
for y in range(686, 700):
    row = [im.getpixel((x, y)) for x in range(0, 1280)]
    segs = []
    start = None
    for x, c in enumerate(row):
        v = (c[0] + c[1] + c[2]) / 3
        if v > 55:
            if start is None: start = x
        else:
            if start is not None and x - start >= 2:
                segs.append((start, x - 1))
            start = None
    if start is not None: segs.append((start, 1279))
    print(y, segs[:12])
