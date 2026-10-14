#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成"自带刻度"的标尺素材（给 Pr 源监视器的定量测量用）。

画面里同时给三种参照，任何一帧截图上都能读出"现在是第几帧 / 第几秒"：
  1. 顶部：`MM:SS:FF` 大号数字（人眼读）+ 每秒换一次底色（快速定位）
  2. 中部：横跨整幅的"一秒尺"——每帧一根小刻度、每 5 帧标数字、正中一根粗标（当前帧正好在正中）
  3. 底部：16 格黑白块 = 帧号的二进制（MSB 在左，最左边另有一个白色同步块）——给程序读，不依赖 OCR

用法：python tools\\make-ruler-clip.py [秒数] [fps] [输出mp4]
默认：30 秒 / 30fps / reference\\标尺素材-30s-30fps.mp4
依赖：Pillow；编码用工作区根目录的 ffmpeg.exe（libx264）。
"""
import os
import sys
import colorsys
import subprocess
import shutil

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
FPS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
SEC = int(sys.argv[1]) if len(sys.argv) > 1 else 30
OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join('reference', '标尺素材-%ds-%dfps.mp4' % (SEC, FPS))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = os.path.join(ROOT, 'ffmpeg.exe')


def font(size):
    for name in ('consola.ttf', 'arial.ttf', 'segoeui.ttf'):
        p = os.path.join(os.environ.get('WINDIR', r'C:\Windows'), 'Fonts', name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def main():
    n = SEC * FPS
    tmp = os.path.join(ROOT, '_tmp', 'ruler-frames')      # 中间帧写在工作区内（沙箱允许）；编码完删掉
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    f_big, f_mid, f_small = font(132), font(52), font(26)
    for i in range(n):
        sec, ff = divmod(i, FPS)
        mm, ss = divmod(sec, 60)
        img = Image.new('RGB', (W, H), (30, 30, 34))
        d = ImageDraw.Draw(img)

        # 顶部：每秒一个色相 + MM:SS:FF
        r, g, b = colorsys.hsv_to_rgb(((sec * 11) % 360) / 360.0, 0.55, 0.85)
        d.rectangle([0, 0, W, 168], fill=(int(r * 255), int(g * 255), int(b * 255)))
        tc = '%02d:%02d:%02d' % (mm, ss, ff)
        d.text((W // 2, 84), tc, font=f_big, fill=(16, 16, 16), anchor='mm')

        # 中部：帧号 + 一秒尺（当前帧在正中）
        d.text((W // 2, 300), '%05d' % i, font=f_big, fill=(240, 240, 240), anchor='mm')
        d.text((W // 2, 400), 'frame (of %d)   |   %d fps   |   %d s' % (n, FPS, SEC),
               font=f_small, fill=(150, 150, 160), anchor='mm')
        y0, y1 = 470, 560
        px_per_frame = W / float(FPS)            # 整幅 = 1 秒
        for k in range(FPS + 1):
            x = k * px_per_frame
            long_tick = (k % 5 == 0)
            d.line([x, y1 - (46 if long_tick else 22), x, y1], fill=(220, 220, 220), width=3 if long_tick else 2)
            if long_tick:
                lbl = (i - FPS // 2 + k)
                d.text((x, y0 + 18), '%05d' % lbl, font=f_small, fill=(200, 200, 210), anchor='mm')
        d.line([W // 2, y0, W // 2, y1 + 12], fill=(255, 80, 80), width=5)   # 正中 = 当前帧
        d.text((W // 2, y1 + 40), 'centre tick = current frame', font=f_small,
               fill=(255, 140, 140), anchor='mm')

        # 底部：帧号二进制（16 位，MSB 在左）+ 白色同步块
        bx, by, bs, gap = 120, 640, 56, 8
        d.rectangle([bx - bs - 2 * gap, by - gap, bx - gap, by + bs + gap], fill=(255, 255, 255))
        for bit in range(16):
            on = (i >> (15 - bit)) & 1
            x = bx + bit * (bs + gap)
            d.rectangle([x, by, x + bs, by + bs], fill=(255, 255, 255) if on else (0, 0, 0))
            d.rectangle([x, by, x + bs, by + bs], outline=(90, 90, 90))
        d.text((bx, by + bs + 26), 'binary frame index (bit15 ... bit0) + white sync',
               font=f_small, fill=(140, 140, 150))

        img.save(os.path.join(tmp, 'f%05d.png' % i))

    if not os.path.exists(FFMPEG):
        print('找不到 ffmpeg：' + FFMPEG)
        return 2
    args = [FFMPEG, '-y', '-hide_banner', '-loglevel', 'error',
            '-framerate', str(FPS), '-i', os.path.join(tmp, 'f%05d.png'),
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-g', '15', '-bf', '0',
            '-pix_fmt', 'yuv420p', '-r', str(FPS), OUT]
    print('编码中：' + ' '.join(args[:6]) + ' ...')
    rc = subprocess.call(args)
    shutil.rmtree(tmp, ignore_errors=True)
    print('退出码 %d，产物：%s' % (rc, OUT))
    return rc


if __name__ == '__main__':
    sys.exit(main())
