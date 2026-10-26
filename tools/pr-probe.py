#!/usr/bin/env python3
"""Probe Premiere's timeline: raise / click / key / screenshot / scan the overview slider."""
import argparse
import ctypes
import os
import time
from ctypes import wintypes as wt

import numpy as np
from PIL import Image, ImageGrab

u32 = ctypes.windll.user32

SW_MAXIMIZE = 3
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
KEYEVENTF_KEYUP = 0x0002


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("ki", KEYBDINPUT)]

    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _U)]


def find_window(pid):
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, l):
        p = wt.DWORD()
        u32.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and not found and u32.IsWindowVisible(h):
            found.append(h)
        return True

    u32.EnumWindows(cb, 0)
    return found[0] if found else 0


def win_rect(h):
    r = wt.RECT()
    u32.GetWindowRect(h, ctypes.byref(r))
    return r.left, r.top, r.right, r.bottom


def raise_window(h, maximize=True):
    if not h:
        return False
    if maximize:
        u32.ShowWindow(h, SW_MAXIMIZE)
    u32.SetForegroundWindow(h)
    time.sleep(0.35)
    return u32.GetForegroundWindow() == h


def click(x, y, pause=0.12):
    u32.SetCursorPos(x, y)
    time.sleep(0.05)
    u32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    time.sleep(0.03)
    u32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(pause)


KEYEVENTF_EXTENDEDKEY = 0x0001


def key_down(vk, ext=False):
    i = INPUT(type=1)
    i.ki.wVk = vk
    i.ki.dwFlags = KEYEVENTF_EXTENDEDKEY if ext else 0
    u32.SendInput(1, ctypes.byref(i), ctypes.sizeof(INPUT))


def key_up(vk, ext=False):
    i = INPUT(type=1)
    i.ki.wVk = vk
    i.ki.dwFlags = KEYEVENTF_KEYUP | (KEYEVENTF_EXTENDEDKEY if ext else 0)
    u32.SendInput(1, ctypes.byref(i), ctypes.sizeof(INPUT))


def tap(vk, gap=0.04, ext=False):
    key_down(vk, ext)
    time.sleep(0.02)
    key_up(vk, ext)
    time.sleep(gap)


def combo(mod, vk, gap=0.08):
    key_down(mod)
    time.sleep(0.05)
    tap(vk)
    key_up(mod)
    time.sleep(gap)


KEYEVENTF_UNICODE = 0x0004


def key_uni(ch, up=False):
    i = INPUT(type=1)
    i.ki.wVk = 0
    i.ki.wScan = ord(ch)
    i.ki.dwFlags = KEYEVENTF_UNICODE | (KEYEVENTF_KEYUP if up else 0)
    u32.SendInput(1, ctypes.byref(i), ctypes.sizeof(INPUT))


def type_str(s, gap=0.09):
    for ch in s:
        key_uni(ch)
        time.sleep(0.015)
        key_uni(ch, up=True)
        time.sleep(gap)


FRAME_BOX = (28, 655)
ENTER = 0x0D


def goto(frame, box=FRAME_BOX, wait=0.75):
    click(box[0], box[1], 0.25)
    combo(0x11, 0x41)
    type_str(str(frame))
    time.sleep(0.10)
    tap(ENTER, wait)


def grab():
    return np.asarray(ImageGrab.grab(bbox=(0, 0, 1280, 800)).convert("RGB"), dtype=np.int16)


def span(img, y, thr, x0=5, x1=1275):
    lum = img.mean(axis=2)
    row = lum[y, x0:x1]
    idx = np.where(row >= thr)[0]
    if idx.size == 0:
        return -1, -1
    return int(idx[0]) + x0, int(idx[-1]) + x0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["probe", "bar", "rows", "key", "walk", "goto"])
    ap.add_argument("--pid", type=int, default=8236)
    ap.add_argument("--x", type=int, default=1250)
    ap.add_argument("--y", type=int, default=683)
    ap.add_argument("--tag", default="c1")
    ap.add_argument("--png", default="")
    ap.add_argument("--bary", type=int, default=692)
    ap.add_argument("--thr", type=int, default=100)
    ap.add_argument("--y0", type=int, default=660)
    ap.add_argument("--y1", type=int, default=780)
    ap.add_argument("--vk", default="BB")
    ap.add_argument("--times", type=int, default=1)
    ap.add_argument("--gap", type=float, default=0.35)
    ap.add_argument("--dirvk", default="27")
    ap.add_argument("--no-max", action="store_true")
    ap.add_argument("--dir", default=r"C:\Users\Frisk\Documents\Source_Marker_United\tools")
    a = ap.parse_args()

    if a.action == "bar":
        im = np.asarray(Image.open(a.png).convert("RGB"), dtype=np.int16)
        print("xl=%d xr=%d" % span(im, a.bary, a.thr))
        return 0

    if a.action == "rows":
        im = np.asarray(Image.open(a.png).convert("RGB"), dtype=np.int16)
        for y in range(a.y0, a.y1, 2):
            xl, xr = span(im, y, a.thr)
            if xl >= 0:
                print("y=%d xl=%d xr=%d" % (y, xl, xr))
        return 0

    h = find_window(a.pid)
    if not h:
        print("ERR no-window pid=%d" % a.pid)
        return 1
    ok = raise_window(h, maximize=not a.no_max)
    r = win_rect(h)

    if a.action == "key":
        click(a.x, a.y)
        time.sleep(0.45)
        vk = int(a.vk, 16)
        for _ in range(a.times):
            tap(vk, a.gap)
        time.sleep(0.4)
        im = grab()
        p = os.path.join(a.dir, "%s_key.png" % a.tag)
        Image.fromarray(im.astype("uint8")).save(p)
        print("rect=%s fg=%s span=%s png=%s" % (r, ok, span(im, a.bary, a.thr, max(5, r[0]), min(1275, r[2])), p))
        return 0

    if a.action == "goto":
        l0 = max(5, r[0])
        l1 = min(1275, r[2])
        before = span(grab(), a.bary, a.thr, l0, l1)
        goto(a.times)
        im = grab()
        after = span(im, a.bary, a.thr, l0, l1)
        crop = Image.fromarray(im.astype("uint8")).crop((300, 380, 980, 470))
        crop = crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS)
        p = os.path.join(a.dir, "%s_goto%d_frame.png" % (a.tag, a.times))
        crop.save(p)
        ip = os.path.join(a.dir, "%s_goto%d.png" % (a.tag, a.times))
        Image.fromarray(im.astype("uint8")).save(ip)
        print("before xl=%d xr=%d" % before)
        print("after  xl=%d xr=%d w=%d" % (after[0], after[1], after[1] - after[0]))
        print("png=%s" % p)
        return 0

    if a.action == "walk":
        click(a.x, a.y)
        time.sleep(0.5)
        l0 = max(5, r[0])
        l1 = min(1275, r[2])
        xl0, xr0 = span(grab(), a.bary, a.thr, l0, l1)
        print("rect=%s base xl=%d xr=%d w=%d" % (r, xl0, xr0, xr0 - xl0))
        dvk = int(a.dirvk, 16)
        ext = dvk in (0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E)
        key_down(0x10)
        hit = -1
        for i in range(a.times):
            tap(dvk, 0.22, ext)
            im = grab()
            xl, xr = span(im, a.bary, a.thr, l0, l1)
            moved = xl != xl0
            print("step %d xl=%d xr=%d moved=%s" % (i + 1, xl, xr, moved))
            if moved:
                hit = i + 1
                p = os.path.join(a.dir, "%s_walk%d.png" % (a.tag, hit))
                Image.fromarray(im.astype("uint8")).save(p)
                print("png=%s" % p)
                break
        key_up(0x10)
        print("hit=%d" % hit)
        return 0

    im1 = grab()
    p1 = os.path.join(a.dir, "%s_before.png" % a.tag)
    Image.fromarray(im1.astype("uint8")).save(p1)
    b1 = span(im1, a.bary, a.thr, max(5, r[0]), min(1275, r[2]))
    click(a.x, a.y)
    time.sleep(0.7)
    im2 = grab()
    p2 = os.path.join(a.dir, "%s_after.png" % a.tag)
    Image.fromarray(im2.astype("uint8")).save(p2)
    b2 = span(im2, a.bary, a.thr, max(5, r[0]), min(1275, r[2]))
    print("rect=%s fg=%s" % (r, ok))
    print("before xl=%d xr=%d" % b1)
    print("after  xl=%d xr=%d" % b2)
    print("moved=%s" % (b1[0] != b2[0]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
