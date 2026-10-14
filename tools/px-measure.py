#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""px-measure.py —— 像素级读点工具（给 Pr / mpv 界面的定量测量用）

用法：
    python tools\\px-measure.py                 # 空窗口，用 V 抓剪贴板 / O 打开文件
    python tools\\px-measure.py 图片.png        # 直接打开

操作：
    左键          打一个点（编号 + 十字线，相邻点自动连线）
    右键          撤销最后一个点
    C             清空所有点
    V             从剪贴板抓图（先 Win+Shift+S 截图，再进来按 V）
    O             打开图片文件
    滚轮          以光标为中心缩放（1x~16x；8x 以上显示像素网格）
    中键拖动      平移
    方向键        平移
    R             复位（整幅适应窗口）
    G             切换像素网格
    S             点表存成 <图片名>.points.csv，并在终端打印
    D             打印最后两个点的 Δx / Δy / 距离
    Esc / Q       退出

读数说明：状态栏坐标一律是**原图像素**（和截图里的像素一一对应）；Δ 是相对"上一个点"的位移。
"""
import os
import sys

try:
    import tkinter as tk
    from tkinter import filedialog
    from PIL import Image, ImageTk, ImageGrab
except Exception as exc:                                    # pragma: no cover
    print('需要 tkinter / Pillow：%s' % exc)
    sys.exit(2)

ZOOM_MIN, ZOOM_MAX = 0.2, 16.0
COL_PT = '#ff2d55'
COL_LINE = '#ffd400'
COL_GRID = '#3a3a46'


def img_to_view(ix, iy, scale, ox, oy):
    return ix * scale + ox, iy * scale + oy


def view_to_img(vx, vy, scale, ox, oy):
    return (vx - ox) / scale, (vy - oy) / scale


class App(object):
    def __init__(self, root, path=None):
        self.root = root
        root.title('px-measure —— 像素级读点工具')
        root.geometry('1400x900')
        self.canvas = tk.Canvas(root, bg='#101014', highlightthickness=0)
        self.canvas.pack(fill='both', expand=True)
        self.status = tk.Label(root, anchor='w', font=('Consolas', 12), bg='#1c1c22', fg='#e8e8ee')
        self.status.pack(fill='x')
        self.help = tk.Label(root, anchor='w', font=('Consolas', 10), bg='#1c1c22', fg='#9aa0aa',
                             text='左键打点 / 右键撤销 / C 清空 / V 剪贴板 / O 打开 / 滚轮缩放 / 中键平移 / R 复位 / G 网格 / S 存表 / D Δ / Esc 退出')
        self.help.pack(fill='x')

        self.img = None
        self.scale = 1.0
        self.ox = self.oy = 0.0
        self.points = []
        self.show_grid = True
        self._photo = None
        self._drag = None
        self._cursor = (0, 0)

        self.canvas.bind('<Button-1>', self.on_click)
        self.canvas.bind('<Button-3>', self.on_undo)
        self.canvas.bind('<Button-2>', self.on_drag_start)
        self.canvas.bind('<B2-Motion>', self.on_drag_move)
        self.canvas.bind('<ButtonRelease-2>', self.on_drag_end)
        self.canvas.bind('<Motion>', self.on_motion)
        self.canvas.bind('<MouseWheel>', self.on_wheel)
        self.canvas.bind('<Configure>', lambda e: self.redraw())
        root.bind('<Key>', self.on_key)

        if path:
            self.load(path)

    # ---------- 载入 / 视图 ----------
    def load(self, path):
        try:
            self.img = Image.open(path).convert('RGB')
        except Exception as exc:
            self.set_status('打开失败：%s' % exc)
            return
        self.points = []
        self.fit()
        self.set_status('已载入 %s  %dx%d' % (os.path.basename(path), self.img.width, self.img.height))

    def load_clipboard(self):
        try:
            data = ImageGrab.grabclipboard()
        except Exception as exc:
            self.set_status('剪贴板取图失败：%s' % exc)
            return
        if data is None:
            self.set_status('剪贴板里没有图片（先 Win+Shift+S 截个图）')
            return
        if isinstance(data, list):
            self.set_status('剪贴板里是文件列表，按 O 打开')
            return
        self.img = data.convert('RGB')
        self.points = []
        self.fit()
        self.set_status('已从剪贴板载入 %dx%d' % (self.img.width, self.img.height))

    def fit(self):
        if not self.img:
            return
        cw = max(1, self.canvas.winfo_width())
        ch = max(1, self.canvas.winfo_height())
        z = min(cw / float(self.img.width), ch / float(self.img.height))
        self.scale = max(ZOOM_MIN, min(ZOOM_MAX, z))
        self.ox = (cw - self.img.width * self.scale) / 2.0
        self.oy = (ch - self.img.height * self.scale) / 2.0
        self.redraw()

    def redraw(self):
        self.canvas.delete('all')
        if not self.img:
            return
        cw = max(1, self.canvas.winfo_width())
        ch = max(1, self.canvas.winfo_height())
        x0 = max(0, int(-self.ox / self.scale))
        y0 = max(0, int(-self.oy / self.scale))
        x1 = min(self.img.width, int((cw - self.ox) / self.scale) + 1)
        y1 = min(self.img.height, int((ch - self.oy) / self.scale) + 1)
        if x1 <= x0 or y1 <= y0:
            return
        crop = self.img.crop((x0, y0, x1, y1))
        tw = max(1, int(round(crop.width * self.scale)))
        th = max(1, int(round(crop.height * self.scale)))
        resample = Image.NEAREST if self.scale >= 1.0 else Image.BILINEAR
        self._photo = ImageTk.PhotoImage(crop.resize((tw, th), resample))
        px, py = img_to_view(x0, y0, self.scale, self.ox, self.oy)
        self.canvas.create_image(px, py, image=self._photo, anchor='nw')

        if self.show_grid and self.scale >= 8:
            for ix in range(x0, x1 + 1):
                vx, _ = img_to_view(ix, 0, self.scale, self.ox, self.oy)
                self.canvas.create_line(vx, py, vx, py + th, fill=COL_GRID)
            for iy in range(y0, y1 + 1):
                _, vy = img_to_view(0, iy, self.scale, self.ox, self.oy)
                self.canvas.create_line(px, vy, px + tw, vy, fill=COL_GRID)

        prev = None
        for i, (ix, iy) in enumerate(self.points, start=1):
            vx, vy = img_to_view(ix + 0.5, iy + 0.5, self.scale, self.ox, self.oy)
            if prev:
                self.canvas.create_line(prev[0], prev[1], vx, vy, fill=COL_LINE, width=2)
            self.canvas.create_line(vx - 12, vy, vx + 12, vy, fill=COL_PT, width=2)
            self.canvas.create_line(vx, vy - 12, vx, vy + 12, fill=COL_PT, width=2)
            self.canvas.create_text(vx + 14, vy - 14, text=str(i), fill=COL_PT, anchor='sw',
                                    font=('Consolas', 13, 'bold'))
            prev = (vx, vy)

    def set_status(self, text):
        self.status.config(text=text)

    # ---------- 事件 ----------
    def on_motion(self, ev):
        if not self.img:
            return
        ix, iy = view_to_img(ev.x, ev.y, self.scale, self.ox, self.oy)
        self._cursor = (int(ix), int(iy))
        rgb = ''
        if 0 <= int(ix) < self.img.width and 0 <= int(iy) < self.img.height:
            rgb = '  RGB=%s' % (self.img.getpixel((int(ix), int(iy))),)
        delta = ''
        if self.points:
            p = self.points[-1]
            delta = '  从#%d: Δx=%+d Δy=%+d' % (len(self.points), int(ix) - p[0], int(iy) - p[1])
        self.set_status('x=%d y=%d%s  缩放 %.2fx  %s%s' % (int(ix), int(iy), rgb, self.scale,
                                                           '点数 %d' % len(self.points), delta))

    def on_click(self, ev):
        if not self.img:
            return
        ix, iy = view_to_img(ev.x, ev.y, self.scale, self.ox, self.oy)
        self.points.append((int(round(ix)), int(round(iy))))
        self.redraw()
        self.print_last_pair()

    def on_undo(self, ev=None):
        if self.points:
            self.points.pop()
            self.redraw()
            self.set_status('撤销一个点，剩 %d 个' % len(self.points))

    def on_drag_start(self, ev):
        self._drag = (ev.x, ev.y, self.ox, self.oy)

    def on_drag_move(self, ev):
        if not self._drag:
            return
        sx, sy, ox, oy = self._drag
        self.ox = ox + (ev.x - sx)
        self.oy = oy + (ev.y - sy)
        self.redraw()

    def on_drag_end(self, ev):
        self._drag = None

    def on_wheel(self, ev):
        if not self.img:
            return
        factor = 1.25 if ev.delta > 0 else 1 / 1.25
        ns = max(ZOOM_MIN, min(ZOOM_MAX, self.scale * factor))
        ix, iy = view_to_img(ev.x, ev.y, self.scale, self.ox, self.oy)
        self.scale = ns
        self.ox = ev.x - ix * ns
        self.oy = ev.y - iy * ns
        self.redraw()

    def on_key(self, ev):
        k = (ev.keysym or '').lower()
        if k in ('escape', 'q'):
            self.root.destroy()
        elif k == 'v':
            self.load_clipboard()
        elif k == 'o':
            p = filedialog.askopenfilename(filetypes=[('图片', '*.png *.jpg *.jpeg *.bmp *.webp'), ('全部', '*.*')])
            if p:
                self.load(p)
        elif k == 'c':
            self.points = []
            self.redraw()
            self.set_status('已清空')
        elif k == 'r':
            self.fit()
        elif k == 'g':
            self.show_grid = not self.show_grid
            self.redraw()
        elif k == 's':
            self.save_points()
        elif k == 'd':
            self.print_last_pair(verbose=True)
        elif k in ('left', 'right', 'up', 'down'):
            step = 40
            if k == 'left':
                self.ox += step
            elif k == 'right':
                self.ox -= step
            elif k == 'up':
                self.oy += step
            else:
                self.oy -= step
            self.redraw()

    # ---------- 输出 ----------
    def print_last_pair(self, verbose=False):
        if len(self.points) < 2:
            return
        (x1, y1), (x2, y2) = self.points[-2], self.points[-1]
        dx, dy = x2 - x1, y2 - y1
        dist = (dx * dx + dy * dy) ** 0.5
        self.set_status('#%d(%d,%d) → #%d(%d,%d)   Δx=%+d  Δy=%+d  距离=%.1f px' % (
            len(self.points) - 1, x1, y1, len(self.points), x2, y2, dx, dy, dist))
        if verbose:
            print('Δx=%+d Δy=%+d 距离=%.1f px' % (dx, dy, dist))

    def save_points(self):
        if not self.points:
            self.set_status('还没有点')
            return
        out = 'px-points.csv'
        try:
            with open(out, 'w', encoding='utf-8') as fh:
                fh.write('index,x,y,dx_from_prev,dy_from_prev\n')
                px = py = None
                for i, (x, y) in enumerate(self.points, start=1):
                    dx = '' if px is None else (x - px)
                    dy = '' if py is None else (y - py)
                    fh.write('%d,%d,%d,%s,%s\n' % (i, x, y, dx, dy))
                    px, py = x, y
        except Exception as exc:
            self.set_status('写表失败：%s' % exc)
            return
        print('--- 点表（原图像素）---')
        px = py = None
        for i, (x, y) in enumerate(self.points, start=1):
            if px is None:
                print('#%d  x=%d  y=%d' % (i, x, y))
            else:
                print('#%d  x=%d  y=%d   Δx=%+d  Δy=%+d' % (i, x, y, x - px, y - py))
            px, py = x, y
        self.set_status('已写出 %s（%d 个点），终端里也打印了一份' % (os.path.abspath(out), len(self.points)))


def selftest():
    """不开窗口，只验坐标换算与文件读写（在沙箱里也能跑）。"""
    assert img_to_view(10, 20, 2.0, 5, 7) == (25, 47)
    assert view_to_img(25, 47, 2.0, 5, 7) == (10, 20)
    assert view_to_img(img_to_view(3, 4, 0.5, 11, 13)[0], img_to_view(3, 4, 0.5, 11, 13)[1], 0.5, 11, 13) == (3, 4)
    img = Image.new('RGB', (40, 30), (7, 8, 9))
    assert img.getpixel((0, 0)) == (7, 8, 9)
    print('selftest OK（坐标换算 / PIL / 图片读写都正常）')


def main():
    if '--selftest' in sys.argv:
        selftest()
        return 0
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    root = tk.Tk()
    app = App(root, args[0] if args else None)
    if not args:
        app.set_status('按 V 抓剪贴板截图，或 O 打开图片文件')
    root.mainloop()
    return 0


if __name__ == '__main__':
    sys.exit(main())
