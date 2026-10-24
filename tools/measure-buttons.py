# 量按钮（纯黑背景：按钮底亮度 30..70、面板底 ~18、文字 >120）
# 用法: python tools\measure-buttons5.py <png> <x0> <x1> <y0> <y1>
import sys
from PIL import Image
path = sys.argv[1]
X0, X1, Y0, Y1 = (int(v) for v in sys.argv[2:6])
im = Image.open(path).convert('RGB')
px = im.load()
def lum(p): return (p[0]+p[1]+p[2])/3.0
def is_btn(p):
    v = lum(p); return 30 <= v <= 70 and abs(p[0]-p[1]) < 12 and abs(p[1]-p[2]) < 12

blocks, cur = [], None
for y in range(Y0, Y1+1):
    n = sum(1 for x in range(X0, X1+1) if is_btn(px[x, y]))
    if n > 60:
        if cur and y - cur[1] <= 3: cur[1] = y
        else:
            if cur: blocks.append(tuple(cur))
            cur = [y, y]
    elif cur and n == 0:
        pass
if cur: blocks.append(tuple(cur))
blocks = [b for b in blocks if b[1]-b[0] >= 10]
print("blocks:", blocks)
for (ra, rb) in blocks:
    ym = ra + 2
    segs, run = [], None
    for x in range(X0, X1+1):
        if is_btn(px[x, ym]):
            if run is None: run = [x, x]
            else: run[1] = x
        else:
            if run and run[1]-run[0] >= 18: segs.append(tuple(run))
            run = None
    if run and run[1]-run[0] >= 18: segs.append(tuple(run))
    print(f"--- y={ra}..{rb} h={rb-ra+1} edge={ym} n={len(segs)}")
    for i, (a, b) in enumerate(segs):
        tx0 = tx1 = None
        for x in range(a, b+1):
            for y in range(ra, rb+1):
                if lum(px[x, y]) > 120:
                    if tx0 is None: tx0 = x
                    tx1 = x
                    break
        if tx0 is None:
            print(f"{i:3d} {a:5d} {b:5d} w={b-a+1:4d} | (no text)"); continue
        print(f"{i:3d} {a:5d} {b:5d} w={b-a+1:4d} | txt {tx0:5d} {tx1:5d} w={tx1-tx0+1:4d} | L={tx0-a:3d} R={b-tx1:3d} | d={(tx0-a)-(b-tx1):+d}")
