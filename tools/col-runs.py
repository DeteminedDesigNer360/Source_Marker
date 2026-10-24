# 打印某一列的颜色游程（定位按钮的上下边界）
# 用法: python tools\col-runs.py <png> <x> <y0> <y1> [min_len]
import sys
from PIL import Image
path, x = sys.argv[1], int(sys.argv[2])
y0, y1 = int(sys.argv[3]), int(sys.argv[4])
minlen = int(sys.argv[5]) if len(sys.argv) > 5 else 3
im = Image.open(path).convert('RGB')
px = im.load()
prev, start = None, y0
runs = []
for y in range(y0, y1+1):
    p = px[x, y]
    if p != prev:
        if prev is not None: runs.append((start, y-1, prev))
        prev, start = p, y
runs.append((start, y1, prev))
print(f"x={x} y={y0}..{y1}")
for a, b, p in runs:
    if b-a+1 >= minlen:
        print(f"{a:5d}..{b:5d} len={b-a+1:4d} rgb={p}")
