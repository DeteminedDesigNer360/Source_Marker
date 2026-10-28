# tl-parse.py —— 解析 tl-linear.lua / tl-drag.lua 的 mpv 日志，列出概览条环心与幂律误差
#
# 用法：python tools\probes\tl-parse.py _tmp\tl.log [duration]
#   duration 省略时取日志里出现过的最大的 t1（tl-linear 的第 1 档就是全片，所以对得上）
#
# 期望模型（r50 定稿，见 docs\设计-第9条-时间轴与面板.md §十五）：
#   c = (t0+t1)/2/dur                中心线性  -> 环心
#   w = u^p        u = (t1-t0)/dur   宽度幂律
#   p = ln(W_min/rw) / ln(minspan/dur)    （日志里的「概览p」「环心距min」直接给值，不再自己推）
#   贴片头钉 (0,w)、贴片尾钉 (1-w,1)，再夹到 [0,1]，最后不足 W_min 时以中心撑开
import re, io, sys
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

path = sys.argv[1] if len(sys.argv) > 1 else "_tmp/tl.log"
dur_arg = float(sys.argv[2]) if len(sys.argv) > 2 else None

case, last, rows = None, None, []
for line in io.open(path, encoding="utf-8", errors="replace"):
    m = re.search(r"(?:CASE|STEP) (\d+) (.*)", line)
    if m:
        if case is not None and last:
            rows.append((case, last))
        case, last = m.group(1) + " " + m.group(2).strip(), None
        continue
    m = re.search(r"时间轴：范围 ([-\d.]+)~([-\d.]+).*?画布 x (\d+)\.\.(\d+).*?概览x=(-?\d+),(-?\d+).*?概览k=([-\d.]+) 概览p=([-\d.]+) 环心距min=(\d+)", line)
    if m and case is not None:
        last = tuple([float(m.group(1)), float(m.group(2)), int(m.group(3)), int(m.group(4)),
                      int(m.group(5)), int(m.group(6)), float(m.group(7)), float(m.group(8)), float(m.group(9))])
if case is not None and last:
    rows.append((case, last))

if not rows:
    print("日志里没有「时间轴：范围 …」行 —— 检查 --msg-level=all=v 和 ui.json 里 tl 是否为 true")
    raise SystemExit(1)

dur = dur_arg if dur_arg else max(r[1][1] for r in rows)
print(f"duration = {dur:.3f}s\n")
print(f"{'case / step':<30}{'t0':>9}{'t1':>9} |{'rw':>4}{'p':>7} |{'L':>6}{'R':>6} |{'expL':>8}{'expR':>8} |{'dL':>6}{'dR':>6} | k")
worst = 0.0
for name, v in rows:
    t0, t1, X0, X1, L, R, k, pw, ovmin = v
    rw = X1 - X0
    u = (t1 - t0) / dur
    w = u ** pw if u > 0 else 0.0
    c = (t0 + t1) / 2 / dur
    eps = dur * 1e-4
    if t0 <= eps and t1 >= dur - eps:
        l0, r0 = 0.0, 1.0
    elif t0 <= eps:
        l0, r0 = 0.0, w
    elif t1 >= dur - eps:
        l0, r0 = 1 - w, 1.0
    else:
        l0, r0 = c - w / 2, c + w / 2
    if l0 < 0:
        r0, l0 = r0 - l0, 0.0
    if r0 > 1:
        l0, r0 = l0 - (r0 - 1), 1.0
    l0 = max(0.0, l0); r0 = min(1.0, r0)
    eL, eR = X0 + l0 * rw, X0 + r0 * rw
    if eR - eL < ovmin:
        mid = (eL + eR) / 2
        eL, eR = mid - ovmin / 2, mid + ovmin / 2
        if eL < X0: eL, eR = X0, X0 + ovmin
        if eR > X0 + rw: eL, eR = X0 + rw - ovmin, X0 + rw
    if abs(k - 1.0) < 1e-3:
        worst = max(worst, abs(L - eL), abs(R - eR))
    print(f"{name:<30}{t0:>9.3f}{t1:>9.3f} |{rw:>4}{pw:>7.3f} |{L:>6}{R:>6} |{eL:>8.1f}{eR:>8.1f} |{L-eL:>6.1f}{R-eR:>6.1f} | {k:.3f}")
print()
print(f"常规区间最大偏差 = {worst:.1f} px")
print("判读：")
print("  · 概览k 必须 1.000（中心线性，无横向放大）")
print("  · 概览p 应 <1（长素材，条更宽）或 >1（短素材，条更窄）；恒为 1.000 说明 rw 没取到，退化成了线性")
print("  · dL/dR 在常规区间应 ≤1 px；最窄档被最小环心距撑开，离开期望值是正常的")
print("  · 抓右环拖动时，同一组的 L 必须完全相同（左环像素钉死）")
