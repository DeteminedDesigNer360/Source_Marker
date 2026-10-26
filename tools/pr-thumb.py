"""Scan Pr timeline thumb (scrollbar) extents from a screenshot."""
import sys
import numpy as np
from PIL import Image

THR = 100
X0, X1 = 5, 1274


def span(im, y, thr=THR, x0=X0, x1=X1):
    row = im[y, x0:x1]
    lum = row[:, 0] * 0.299 + row[:, 1] * 0.587 + row[:, 2] * 0.114
    idx = np.nonzero(lum >= thr)[0]
    if len(idx) == 0:
        return None
    return (int(idx[0]) + x0, int(idx[-1]) + x0)


def best(im, ys=range(686, 699)):
    out = []
    for y in ys:
        s = span(im, y)
        if s:
            out.append((s[1] - s[0], y, s))
    if not out:
        return None
    out.sort(reverse=True)
    return out[0]


def main():
    for p in sys.argv[1:]:
        im = np.asarray(Image.open(p).convert("RGB"), dtype=np.int16)
        b = best(im)
        if b:
            w, y, s = b
            print("%s  y=%d xl=%d xr=%d w=%d" % (p.split("\\")[-1], y, s[0], s[1], w))
        else:
            print("%s  NO-THUMB" % p.split("\\")[-1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
