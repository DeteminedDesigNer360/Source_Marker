#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 NS1 实测数据换算成区间/p/跨度，并给出三种缩放锚点模型在"新时间戳"上的复算预测。

数据来源：测量工作表-NS1NS4.md 第 3 节（用户 2026-10-15 填）。
Pr 素材：900 帧 / 30fps / 30s；轨道两端 xL=24, xR=2525（沿用 K1，本表 S0 已自检吻合）。
"""
import sys

FPS = 30.0
D_FRAMES = 900.0          # Pr 标尺素材总帧数
D_SEC = D_FRAMES / FPS    # 30.0 s
XL, XR = 24.0, 2525.0
W = XR - XL

# name, 按过几次=, P(帧), x_P, x_P2, cL, cR
ROWS = [
    ("S0", 0, 300.0, 857.5, 885.5, 36.0, 2524.5),
    ("S1", 1, 300.0, 1274.5, 1330.5, 282.5, 1292.5),
    ("S2", 2, 300.0, 1274.5, 1386.5, 615.5, 1018.0),
    ("S3", 3, 300.0, 1274.5, 1496.5, 759.0, 912.0),
    ("S4", 4, 300.0, 1274.5, 1718.5, 821.5, 872.0),
]


def line(ch="-", n=78):
    print(ch * n)


def table_a():
    print("表 A：NS1 每一级的 pxF / 跨度 / 播放头相对位置 p / 区间")
    line()
    print("%-3s %-4s %8s %8s %10s %10s %7s   %-22s" %
          ("状态", "=次数", "pxF", "pxF比", "跨度(帧)", "跨度(s)", "p", "区间 [起, 止] (s)"))
    line()
    base = None
    for name, n, P, xp, xp2, cL, cR in ROWS:
        pxf = (xp2 - xp) / 10.0
        if base is None:
            base = pxf
        ratio = pxf / base
        span_f = D_FRAMES / (2 ** n)          # 由 pxF 精确翻倍 => 跨度精确减半
        span_s = span_f / FPS
        p = (xp - XL) / W
        start = P - p * span_f
        end = start + span_f
        print("%-3s %-6d %8.2f %8.3f %10.1f %10.3f %7.4f   [%7.3f, %7.3f]" %
              (name, n, pxf, ratio, span_f, span_s, p, start / FPS, end / FPS))
    line()
    print("pxF 用原始测量值反算的跨度（检查 0.7%% 的像素量化误差）：")
    for name, n, P, xp, xp2, cL, cR in ROWS:
        pxf = (xp2 - xp) / 10.0
        print("   %s: 轨道宽 %.0fpx / pxF %.2f = %.1f 帧 = %.2f s（理论 %.1f 帧）"
              % (name, W, pxf, W / pxf, W / pxf / FPS, D_FRAMES / (2 ** n)))
    line()


def table_b():
    print("表 B：播放头相对位置 p —— 实测 vs 三种模型预测（S0 -> S1）")
    line()
    p0 = (857.5 - XL) / W
    models = [
        ("head  (死钉播放头, p 不变)", p0),
        ("pull k=2/3 (上一轮拟合)", 0.5 + (p0 - 0.5) * (2.0 / 3.0)),
        ("center(以区间中心为轴)", 2 * p0 - 0.5),
        ("居中   (缩放后播放头到正中)", 0.5),
    ]
    print("S0 实测 p = %.4f；S1 实测 p = %.4f" % (p0, (1274.5 - XL) / W))
    line()
    for name, pred in models:
        print("   %-28s 预测 p(S1) = %.4f   偏差 %.4f" % (name, pred, abs(pred - 0.5)))
    line()


def predict(P_frame, pitch=0.0):
    """给定 Pr 侧播放头帧号，算三种模型下一次 '=' 之后的区间（秒）。"""
    span0 = D_FRAMES
    span1 = span0 / 2.0
    p0 = P_frame / span0
    out = {}
    out["head"] = (p0, span1)
    out["pull"] = (0.5 + (p0 - 0.5) * (2.0 / 3.0), span1)
    out["居中"] = (0.5, span1)
    res = {}
    for k, (p1, sp) in out.items():
        st = P_frame - p1 * sp
        en = st + sp
        # 夹到 [0, 900]
        if st < 0:
            en -= st
            st = 0.0
        if en > D_FRAMES:
            st -= (en - D_FRAMES)
            en = D_FRAMES
        res[k] = (p1, st, en)
    return res


def table_c(P_frame):
    print("表 C：复算点 —— Pr 侧播放头放在 %s（%.0f 帧），连按两次 '=' 的预期"
          % (fmt_tc(P_frame), P_frame))
    for step in (1, 2):
        span = D_FRAMES / (2 ** step)
        print("  第 %d 次 '=' 之后（跨度 %.1f 帧 = %.3f s）" % (step, span, span / FPS))
        line()
        print("  模型        p      预期区间(帧)          预期区间(时间码)      x_P 应落在")
        line()
        for k in ("head", "pull", "居中"):
            p1 = {"head": P_frame / D_FRAMES,
                  "pull": 0.5 + (P_frame / D_FRAMES - 0.5) * (2.0 / 3.0) ** step,
                  "居中": 0.5}[k]
            st = P_frame - p1 * span
            en = st + span
            if st < 0:
                en -= st
                st = 0.0
            if en > D_FRAMES:
                st -= (en - D_FRAMES)
                en = D_FRAMES
            xp = XL + ((P_frame - st) / (en - st)) * W
            print("  %-10s %7.4f   [%7.1f, %7.1f]     %s ~ %s      x_P=%.0f" %
                  (k, p1, st, en, fmt_tc(st), fmt_tc(en), xp))
        line()
    print("换算关系：每按一次 '='，跨度 %.0f 帧 -> %.0f 帧（%.1f s -> %.1f s）"
          % (D_FRAMES, D_FRAMES / 2, D_SEC, D_SEC / 2))
    line()


def fmt_tc(frame):
    frame = max(0.0, min(D_FRAMES, frame))
    s = int(frame // FPS)
    f = int(round(frame - s * FPS))
    if f >= int(FPS):
        s += 1
        f = 0
    return "%02d:%02d:%02d" % (s // 60, s % 60, f)


def table_d(mpv_dur, playhead_sec):
    """在 mpv 侧（21.223s 素材）复算，供上机对照。"""
    p0 = playhead_sec / mpv_dur
    span1 = mpv_dur / 2.0
    print("表 D：mpv 侧复算（素材 %.3f s，播放头 %.3f s，p=%.4f）" % (mpv_dur, playhead_sec, p0))
    line()
    print("模型        p(S1)    预期区间(s)            跨度(s)")
    line()
    for name, p1 in (("head", p0), ("pull", 0.5 + (p0 - 0.5) * (2.0 / 3.0)), ("居中", 0.5)):
        st = playhead_sec - p1 * span1
        en = st + span1
        if st < 0:
            en -= st
            st = 0.0
        if en > mpv_dur:
            st -= (en - mpv_dur)
            en = mpv_dur
        print("%-10s %7.4f   %8.3f ~ %8.3f      %.3f" % (name, p1, st, en, en - st))
    line()


def main():
    table_a()
    table_b()
    # 复算点：12 s 17 f = 377 帧（p0 = 0.4189，居中后不撞两端）
    table_c(377.0)
    # mpv 侧等价位置：同样的 p0
    mpv_dur = 21.223
    playhead = (377.0 / D_FRAMES) * mpv_dur
    table_d(mpv_dur, playhead)
    return 0


if __name__ == "__main__":
    sys.exit(main())
