# tl-parse.py —— 解析 tl-linear.lua / tl-drag.lua 的 mpv 日志，列出概览条环心与线性误差
#
# 用法：python tools\probes\tl-parse.py _tmp\tl.log [duration]
#   duration 省略时取日志里出现过的最大的 t1（tl-linear 的第 1 档就是全片，所以对得上）
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
    m = re.search(r"时间轴：范围 ([-\d.]+)~([-\d.]+).*?画布 x (\d+)\.\.(\d+).*?概览x=(-?\d+),(-?\d+).*?概览k=([-\d.]+)", line)
    if m and case is not None:
        last = (float(m.group(1)), float(m.group(2)), int(m.group(3)), int(m.group(4)),
                int(m.group(5)), int(m.group(6)), float(m.group(7)))
if case is not None and last:
    rows.append((case, last))

dur = dur_arg if dur_arg else (max(r[1][1] for r in rows) if rows else 1.0)
print(f"duration = {dur:.3f}s\n")
print(f"{'case / step':<32}{'t0':>10}{'t1':>10} |{'x0':>5}{'rw':>5} |{'L':>6}{'R':>6} |{'expL':>8}{'expR':>8} |{'dL':>7}{'dR':>7} | k")
worst = 0.0
for name, v in rows:
    t0, t1, X0, X1, L, R, k = v
    rw = X1 - X0
    eL = X0 + rw * t0 / dur
    eR = X0 + rw * t1 / dur
    if k > 0.999:
        worst = max(worst, abs(L - eL), abs(R - eR))
    print(f"{name:<32}{t0:>10.3f}{t1:>10.3f} |{X0:>5}{rw:>5} |{L:>6}{R:>6} |{eL:>8.1f}{eR:>8.1f} |{L-eL:>7.1f}{R-eR:>7.1f} | {k:.3f}")
print()
print("判读：")
print("  · 概览k 必须 1.000 —— 不是 1 说明装的是旧版（幂律还在）")
print("  · dL/dR 在常规区间应 ≈ 0；最窄档被最小环心距撑开，离开期望值是正常的")
print("  · 抓右环拖动时，同一组的 L 必须完全相同（左环像素钉死）")
