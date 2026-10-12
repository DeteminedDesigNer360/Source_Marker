"""shot-diff.py -- compare two PNGs and assert they DIFFER.

Purpose: prove the "capture current frame" output has no OSD.
  camera shot (screenshot-to-file ... video)  vs  reference (screenshot-to-file ... window, WITH OSD)
  They must differ: the reference proves the OSD really was on screen, and the camera shot lacks it.

Usage:  python shot-diff.py <cam.png> <ref.png>
Exit:   0 = differ (as expected); 1 = identical (reference useless -> no OSD was on screen); 2 = usage/IO error

NOTE: output is ASCII only -- the Windows console codepage (GBK here) cannot print arrows/checkmarks.
"""
import sys

try:
    from PIL import Image, ImageChops
except Exception as e:                                    # noqa: BLE001
    print('Pillow required: %s' % e)
    sys.exit(2)


def main(argv):
    if len(argv) < 3:
        print('usage: python shot-diff.py <cam.png> <ref.png>')
        return 2
    try:
        a = Image.open(argv[1]).convert('RGB')
        b = Image.open(argv[2]).convert('RGB')
    except Exception as e:                                # noqa: BLE001
        print('cannot open image: %s' % e)
        return 2
    print('cam %dx%d | ref %dx%d' % (a.size[0], a.size[1], b.size[0], b.size[1]))
    if a.size != b.size:
        print('sizes differ -> the camera shot is not the OSD one (as expected)')
        return 0
    diff = ImageChops.difference(a, b)
    bbox = diff.getbbox()
    if bbox is None:
        print('FAIL: the two images are identical -> the reference had no OSD either, test useless')
        return 1
    print('OK: images differ (bbox %s) -> OSD was on screen, camera shot has no OSD' % (bbox,))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
