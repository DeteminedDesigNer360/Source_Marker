#!/usr/bin/env python3
"""Scan Premiere's timeline overview-bar rings (the two hollow circles under the ruler).

Usage:  pr-ring-scan.py [--y A:B] <png> [png ...]
Output: <name>  y=<row>  L=<left ring centre>  R=<right ring centre>  W=<width>  n=<ring count>

--y defaults to 684:704 (maximised 1280x800 layout). Pass e.g. --y 640:680
after resizing the Pr window, because the timeline moves up/down with it.

Why the strict filters: an earlier version compared every bright run and
silently paired the 1-px window border at x=1 with the one at x=1278, which
produced plausible-but-wrong widths. Rings are 1-px hollow circles with a
2..9 px gap between their two walls.
"""
import os
import sys

import numpy as np
from PIL import Image

EDGE = 5
MAX_WALL = 8
GAP_LO, GAP_HI = 2, 9
DEFAULT_Y = (684, 704)


def parse_args(argv):
    y0, y1 = DEFAULT_Y
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--y":
            i += 1
            v = argv[i]
            if ":" in v:
                p, q = v.split(":", 1)
                y0, y1 = int(p), int(q)
            else:
                y0 = int(v)
                y1 = y0 + 1
        else:
            files.append(a)
        i += 1
    return y0, y1, files


def rings(path, y0, y1):
    im = np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)
    h = im.shape[0]
    y0 = max(2, y0)
    y1 = min(h - 2, y1)
    votes = {}
    for y in range(y0, y1):
        lum = im[y].mean(axis=1)
        on = lum > 100
        segs, start = [], None
        for x, v in enumerate(on):
            if v and start is None:
                start = x
            elif not v and start is not None:
                segs.append((start, x - 1))
                start = None
        if start is not None:
            segs.append((start, len(on) - 1))
        segs = [g for g in segs if g[0] >= EDGE and g[1] <= len(on) - 1 - EDGE
                and (g[1] - g[0]) <= MAX_WALL]
        pairs, i = [], 0
        while i + 1 < len(segs):
            a, b = segs[i], segs[i + 1]
            if GAP_LO <= b[0] - a[1] <= GAP_HI:
                pairs.append((a[0] + a[1] + b[0] + b[1]) / 4.0)
                i += 2
            else:
                i += 1
        if len(pairs) >= 2:
            key = (round(pairs[0]), round(pairs[-1]))
            votes.setdefault(key, []).append((y, pairs[0], pairs[-1]))
    if not votes:
        return None
    key, rows = max(votes.items(), key=lambda kv: len(kv[1]))
    y, l, r = rows[len(rows) // 2]
    return (y, l, r, len(rows))


def main():
    y0, y1, files = parse_args(sys.argv[1:])
    prev = None
    for f in files:
        name = os.path.basename(f)
        if not os.path.exists(f):
            print("%-18s MISSING" % name)
            continue
        r = rings(f, y0, y1)
        if r is None:
            print("%-18s NO-RINGS" % name)
            continue
        y, l, rr, n = r
        w = rr - l
        ratio = "ratio=%.4f" % (w / prev) if prev else ""
        prev = w
        print("%-18s y=%d L=%.1f R=%.1f W=%.1f n=%d %s" % (name, y, l, rr, w, n, ratio))


if __name__ == "__main__":
    main()
