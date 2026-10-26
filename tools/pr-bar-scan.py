# -*- coding: utf-8 -*-
r"""pr-bar-scan.py —— 从截图里读出 Pr 概览条：条两端 x0/x1 与两环中心 l/r。

原理：概览条永远代表整个素材，所以环的像素位置直接就是时间比例：
    w = (r-l)/rw,  xc = ((l+r)/2 - x0)/rw,  t = x/rw*dur

用法:
    python tools\pr-bar-scan.py <png> [--y N] [--dur S] [--xr a:b] [--cr 4.5] [--json out]

形态判定（Pr 的环是空心圆，单行上是"两段窄壁"）:
    overlap  最右-最左 的亮像素总跨度 <= 2*cr+16  -> 两环挤在一起/单块
             l = 最左 + cr, r = 最右 - cr
    rings    否则按"相邻两段间距 <= 2*cr+1"配对成环，环心 = 两壁中点
    x0/x1    取最长连续段（允许 6px 空隙）作条；若环心离条端 <= cr+2，认为环心就是条端
"""
import json
import sys
from PIL import Image


def lum(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def segments(px, W, y, xa, xb, thr, gap=2):
    segs = []
    cur = None
    for x in range(xa, xb):
        if lum(px[x, y]) >= thr:
            if cur is not None and x - cur[1] <= gap:
                cur[1] = x
            else:
                if cur:
                    segs.append(cur)
                cur = [x, x]
    if cur:
        segs.append(cur)
    return segs


def arg(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def main():
    if len(sys.argv) < 2:
        print('usage: pr-bar-scan.py <png> [--y N] [--dur S] [--xr a:b] [--cr 4.5] [--json out]')
        return 2
    path = sys.argv[1]
    im = Image.open(path).convert('RGB')
    W, H = im.size
    px = im.load()
    xr = arg('--xr', '0:%d' % W).split(':')
    xa, xb = int(xr[0]), int(xr[1])
    bright = float(arg('--bright', 105))
    bar = float(arg('--bar', 42))
    cr = float(arg('--cr', 4.5))
    dur = float(arg('--dur', 0) or 0)

    if arg('--y') is not None:
        y = int(arg('--y'))
    else:
        best = None
        for yy in range(0, H):
            row = [x for x in range(xa, xb, 2) if lum(px[x, yy]) >= bar]
            if row and (best is None or (row[-1] - row[0]) > best[0]):
                best = (row[-1] - row[0], yy)
        y = best[1] if best else H // 2

    barsegs = segments(px, W, y, xa, xb, bar, 6)
    if not barsegs:
        print('FAIL: y=%d 没有条' % y)
        return 2
    main_seg = max(barsegs, key=lambda s: s[1] - s[0])
    edge_l, edge_r = main_seg[0], main_seg[1]

    segs = segments(px, W, y, xa, xb, bright, 2)
    if not segs:
        print('FAIL: y=%d 没有亮块' % y)
        return 2
    span = segs[-1][1] - segs[0][0]
    if span <= 2 * cr + 16:
        mode = 'overlap'
        l = segs[0][0] + cr
        r = segs[-1][1] - cr
    else:
        mode = 'rings'
        i = 0
        found = []
        while i < len(segs):
            a, b = segs[i]
            if i + 1 < len(segs) and (segs[i + 1][0] - b) <= 2 * cr + 1:
                found.append((a + segs[i + 1][1]) / 2.0)
                i += 2
            else:
                found.append((a + b) / 2.0)
                i += 1
        l, r = found[0], found[-1]

    x0 = l if (l - edge_l) <= cr + 2 else edge_l
    x1 = r if (edge_r - r) <= cr + 2 else edge_r
    rw = float(x1 - x0)
    res = dict(y=y, x0=x0, x1=x1, rw=rw, l=l, r=r,
               w=(r - l) / rw if rw else 0.0,
               xc=(((l + r) / 2.0) - x0) / rw if rw else 0.0,
               nseg=len(segs), mode=mode)
    if dur > 0:
        res['dur'] = dur
        res['t0'] = (l - x0) / rw * dur if rw else 0.0
        res['t1'] = (r - x0) / rw * dur if rw else 0.0
        res['u'] = (res['t1'] - res['t0']) / dur
        res['c'] = (res['t0'] + res['t1']) / 2.0 / dur
    order = ['y', 'x0', 'x1', 'rw', 'l', 'r', 'w', 'xc', 't0', 't1', 'u', 'c', 'nseg', 'mode']
    parts = []
    for k in order:
        if k not in res:
            continue
        parts.append('%s=%d' % (k, res[k]) if isinstance(res[k], int) else
                     ('%s=%s' % (k, res[k]) if isinstance(res[k], str) else '%s=%.3f' % (k, res[k])))
    print(' '.join(parts))
    out = arg('--json')
    if out:
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(res, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
