# 打印某一行的颜色游程，用来看清一行里到底有哪些色块
# 用法: python tools\row-runs.py <png> <y> [min_len]
import sys
from PIL import Image
path, y = sys.argv[1], int(sys.argv[2])
minlen = int(sys.argv[3]) if len(sys.argv) > 3 else 4
im = Image.open(path).convert('RGB')
W, H = im.size
px = im.load()
print(f"size={W}x{H} y={y}")
prev, start = None, 0
runs = []
for x in range(W):
    p = px[x, y]
    if p != prev:
        if prev is not None: runs.append((start, x-1, prev))
        prev, start = p, x
runs.append((start, W-1, prev))
for a, b, p in runs:
    if b-a+1 >= minlen:
        print(f"{a:5d}..{b:5d} len={b-a+1:5d} rgb={p}")
