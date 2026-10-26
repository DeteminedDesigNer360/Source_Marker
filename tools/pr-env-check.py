# -*- coding: utf-8 -*-
"""测量环境门禁：必须在 1280x800 @ 100%（dpi 1）下测量。

任何测量脚本第一步都要调用本文件；不符就 exit 2，调用方必须停止。
用法: python tools\pr-env-check.py [--quiet]
"""
import ctypes
import sys

EXP_W, EXP_H, EXP_DPI = 1280, 800, 96

u32 = ctypes.windll.user32
try:
    u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))   # PER_MONITOR_AWARE_V2
except Exception:
    pass
w, h = u32.GetSystemMetrics(0), u32.GetSystemMetrics(1)
try:
    dpi = int(u32.GetDpiForSystem())
except Exception:
    dpi = 96

ok = (w, h, dpi) == (EXP_W, EXP_H, EXP_DPI)
if '--quiet' not in sys.argv or not ok:
    print('env: %dx%d dpi=%d (%.2fx)   expect %dx%d dpi=%d' % (w, h, dpi, dpi / 96.0, EXP_W, EXP_H, EXP_DPI))
if ok:
    print('env: PASS')
    sys.exit(0)
print('env: FAIL -- set display to %dx%d @100%% before measuring. STOPPED.' % (EXP_W, EXP_H))
sys.exit(2)
