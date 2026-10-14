#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 Pr 控制条的实测数据回归成模型（数据来源：测量方案-Pr控制条.md）。

用法：
    python tools\\fit-pr-model.py                # 用 2026-10-14 那组实测数据
    python tools\\fit-pr-model.py W=2506 1=2506 2=1028 4=420 8=171 16=68

T2：亮段宽 S 对区间比例 u（u = 可见区间 / 整片）。若 S = W·u^p，则每按一次 `=`（u 减半）亮段比例 ×2^-p。
T3：把播放头在轨道里的相对位置 p 换算出来，看每一步之后"离中心的偏移"乘了多少（→ 拉力 k）。
"""
import math
import sys


def fit_power(W, data):
    print('T2 幂律拟合（S = W · u^p）')
    print('  u        亮段宽    比例     本次/上次     p = -log2(比例)/log2(u)')
    prev = None
    ps = []
    for n in sorted(data):
        u = 1.0 / n
        r = data[n] / W
        ratio = '' if prev is None else '%.4f' % (r / prev)
        p = '' if n == 1 else '%.4f' % (-math.log2(r) / math.log2(n))
        if n != 1:
            ps.append(-math.log2(r) / math.log2(n))
        print('  1/%-6d %-9.1f %-8.4f %-12s %s' % (n, data[n], r, ratio, p))
        prev = r
    if not ps:
        return None
    pbar = sum(ps) / len(ps)
    print('  => p 的 %d 个估计：%s   平均 p = %.4f' % (len(ps), ['%.4f' % x for x in ps], pbar))
    print('  => 每按一次 "="（区间减半）亮段比例应乘 2^-p = %.4f' % (2 ** -pbar))
    print('  => 用 p=%.4f 反算：%s' % (pbar, ['%.1f' % (W * (1.0 / n) ** pbar) for n in sorted(data) if n != 1]))
    print('  => 实测            ：%s' % [data[n] for n in sorted(data) if n != 1])
    return pbar


def fit_pull(xL, xR, samples):
    print()
    print('T3 拉力拟合（p\' = 0.5 + (p-0.5)·k）')
    W = xR - xL
    ks = []
    for name, x, x2 in samples:
        p = (x - xL) / W
        p2 = (x2 - xL) / W
        k = (p2 - 0.5) / (p - 0.5)
        ks.append(k)
        print('  %-8s p=%.4f → p\'=%.4f   离中心偏移 ×k = %.4f   （2/3=0.6667，1/2=0.5）' % (name, p, p2, k))
    kbar = sum(ks) / len(ks)
    print('  => 平均 k = %.4f   （2/3 = 0.6667）' % kbar)
    print('  => 换成我代码里的 tl_zoom_pull（p\' = 0.5+(p-0.5)·(1/倍率)^pull，倍率=2）：pull = -log2(k) = %.4f'
          % (-math.log2(kbar)))
    return kbar


def main():
    args = sys.argv[1:]
    if args:
        W = 2506.0
        data = {}
        for a in args:
            k, v = a.split('=')
            if k.upper() == 'W':
                W = float(v)
            else:
                data[int(k)] = float(v)
    else:
        W = 2506.0
        data = {1: 2506.0, 2: 1028.0, 4: 420.0, 8: 171.0, 16: 68.0}
    fit_power(W, data)
    fit_pull(24.0, 2525.0, [('左1/4', 334.5, 646.0), ('右1/4', 2214.0, 1902.5)])
    return 0


if __name__ == '__main__':
    sys.exit(main())
