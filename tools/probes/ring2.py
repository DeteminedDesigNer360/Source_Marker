# -*- coding: utf-8 -*-
import sys, json
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
y = 693
segs=[]; st=None
for x in range(0, 1280):
    v = sum(im.getpixel((x,y)))/3
    if v > 80:
        if st is None: st = x
    else:
        if st is not None: segs.append((st, x-1)); st = None
segs = [s for s in segs if not (s[0] <= 2 or s[1] >= 1277)]
out = {'segs': segs}
if len(segs) >= 4:
    out['l'] = (segs[0][0] + segs[1][1]) / 2.0
    out['r'] = (segs[-2][0] + segs[-1][1]) / 2.0
elif len(segs) == 2:
    out['l'] = float(segs[0][0]); out['r'] = float(segs[1][1])
print(json.dumps(out))
