# -*- coding: utf-8 -*-
"""分析 source-markers 的拖圆取证日志（tl_dbg=file 产生，每帧一行 tlgrab）。

用法：
  python tools/analyze-dbg.py <日志路径> [--thresh 0.25] [--context 3] [--csv out.csv]

输出：分段概览、区间跳变清单（带前后文逐字段对照）、状态组合统计。
"""
import io
import re
import sys
import argparse

FIELDS = ('k', 'ke', 'tr', 'sym', 'sr', 'blk', 'inr', 'pn', 'mx', 'tg', 'te',
          'l0', 'r0', 'mxo', 'soff', 'pa', 'pb')


def parse_line(line):
    i = line.find('tlgrab k=')
    if i < 0:
        return None
    s = line[i:]
    kv = dict(re.findall(r'(\w+)=([^ ]+)', s))
    if ' n=' not in s:
        return None
    a, b = s.split(' n=')[-1].split(',')[:2]
    try:
        kv['n0'] = float(a)
        kv['n1'] = float(b)
    except ValueError:
        return None
    if 'mark' in line:
        kv['mark'] = line.split('tlgrab ---- ')[-1].split(' ----')[0]
    return kv


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def load(path):
    rows = []
    with io.open(path, encoding='utf-8', errors='replace') as f:
        for n, line in enumerate(f, 1):
            if 'tlgrab ---- ' in line:
                rows.append({'mark': line.split('tlgrab ---- ')[-1].split(' ----')[0], 'line': n})
                continue
            kv = parse_line(line)
            if kv is not None:
                kv['line'] = n
                rows.append(kv)
    return rows


def segments(rows):
    """按「重新抓起 / 换端点 / 鼠标大跳」切段，便于把一次拖动看成一个片段。"""
    segs = []
    cur = None
    prev = None
    for r in rows:
        if 'mark' in r:
            cur = None
            prev = None
            continue
        if prev is None:
            cur = {'rows': [r], 'start': r['line'], 'end': r['line']}
            segs.append(cur)
            prev = r
            continue
        newgrab = (r.get('k') != prev.get('k') or r.get('l0') != prev.get('l0')
                   or r.get('r0') != prev.get('r0'))
        m0, m1 = num(r.get('mx')), num(prev.get('mx'))
        jump = m0 is not None and m1 is not None and abs(m0 - m1) > 40
        if newgrab or jump:
            cur = {'rows': [r], 'start': r['line'], 'end': r['line']}
            segs.append(cur)
        else:
            cur['rows'].append(r)
            cur['end'] = r['line']
        prev = r
    return segs


def fmt(r):
    keys = ['k', 'ke', 'tr', 'sym', 'sr', 'blk', 'pn', 'tg', 'te', 'l0', 'r0', 'mxo', 'soff', 'pa', 'pb']
    head = ' '.join('%s=%s' % (k, r.get(k, '-')) for k in keys)
    return 'n=%.3f,%.3f %s' % (r['n0'], r['n1'], head)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--thresh', type=float, default=0.25, help='判为跳变的区间变化阈值（秒）')
    ap.add_argument('--context', type=int, default=2)
    ap.add_argument('--csv')
    args = ap.parse_args()

    rows = load(args.log)
    if not rows:
        print('没有解析到 tlgrab 行（是不是 tl_dbg 没开成 file？）')
        return 1
    frames = [r for r in rows if 'mark' not in r]
    segs = segments(rows)
    print('总行数 %d，帧数 %d，分段 %d（阈值 %.2f s）' % (len(rows), len(frames), len(segs), args.thresh))
    print()
    print('== 分段概览 ==')
    for i, s in enumerate(segs, 1):
        a, b = s['rows'][0], s['rows'][-1]
        mins = min(r['n1'] - r['n0'] for r in s['rows'])
        print('#%-2d 行 %d..%d  帧 %-3d  k=%-5s ke=%-5s tr=%-5s  区间 %.3f~%.3f -> %.3f~%.3f  最小跨度 %.3f'
              % (i, s['start'], s['end'], len(s['rows']), a.get('k'), a.get('ke'), a.get('tr'),
                 a['n0'], a['n1'], b['n0'], b['n1'], mins))
    print()
    print('== 跳变（自适应：|Δn| 超过 8 倍邻域中位数且 > %.2f s）==' % args.thresh)
    hits = 0
    n = len(frames)
    deltas = []
    for i in range(n):
        if i == 0:
            deltas.append(0.0)
        else:
            deltas.append(max(abs(frames[i]['n0'] - frames[i - 1]['n0']),
                              abs(frames[i]['n1'] - frames[i - 1]['n1'])))
    def med_window(i, w=10):
        vals = [deltas[j] for j in range(max(1, i - w), min(n, i + w + 1)) if j != i and deltas[j] > 0]
        if not vals:
            return 0.0
        vals.sort()
        return vals[len(vals) // 2]
    for i in range(1, n):
        base = med_window(i)
        lim = max(args.thresh, 8 * base)
        if deltas[i] <= lim:
            continue
        p, r = frames[i - 1], frames[i]
        hits += 1
        print('--- #%d 行 %d -> %d  Δ=(%+.3f, %+.3f)  邻域中位 %.3f ---'
              % (hits, p['line'], r['line'], r['n0'] - p['n0'], r['n1'] - p['n1'], base))
        lo = max(0, i - args.context - 1)
        hi = min(n, i + args.context + 1)
        for j in range(lo, hi):
            rj = frames[j]
            mark = '  <<<' if j == i else ('  >>>' if j == i - 1 else '')
            prevs = frames[j - 1] if j > 0 else None
            dd = '' if prevs is None else '  d=(%+.3f,%+.3f)' % (rj['n0'] - prevs['n0'], rj['n1'] - prevs['n1'])
            print('  行 %-5d %s%s%s' % (rj['line'], fmt(rj), dd, mark))
        print()
    if not hits:
        print('（没有超过阈值的跳变）')
    print()
    print('== 状态组合计数 ==')
    combo = {}
    for r in frames:
        key = 'k=%s ke=%s tr=%s sym=%s sr=%s blk=%s' % (r.get('k'), r.get('ke'), r.get('tr'), r.get('sym'), r.get('sr'), r.get('blk'))
        combo[key] = combo.get(key, 0) + 1
    for k, v in sorted(combo.items(), key=lambda x: -x[1]):
        print('  %-70s %d' % (k, v))

    if args.csv:
        keys = ['line', 'k', 'ke', 'tr', 'sym', 'sr', 'blk', 'inr', 'pn', 'mx', 'tg', 'te',
                'l0', 'r0', 'mxo', 'soff', 'pa', 'pb', 'n0', 'n1']
        with io.open(args.csv, 'w', encoding='utf-8', newline='') as f:
            f.write(','.join(keys) + '\n')
            for r in frames:
                f.write(','.join(str(r.get(k, '')) for k in keys) + '\n')
        print('\n已导出 %s' % args.csv)
    return 0


if __name__ == '__main__':
    sys.exit(main())