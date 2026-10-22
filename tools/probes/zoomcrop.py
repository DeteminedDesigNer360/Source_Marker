import sys
from PIL import Image
src, out, x, y, w, h, z = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:8])
im = Image.open(src).convert('RGB')
box = im.crop((x, y, x + w, y + h))
box = box.resize((w * z, h * z), Image.NEAREST)
box.save(out)
print('ok', box.size)
