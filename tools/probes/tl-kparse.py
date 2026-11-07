import re, sys
p = sys.argv[1]
rows = []
for line in open(p, encoding='utf-8', errors='replace'):
    if '时间轴：范围' not in line: continue
    m = re.search(r'范围 ([\d.]+)~([\d.]+)', line)
    n = re.search(r'概览x=(\d+),(\d+)', line)
    k = re.search(r'概览k=([\d.]+)', line)
    pw = re.search(r'概览p=([\d.]+)', line)
    if not (m and n and k): continue
    key = (m.group(1), m.group(2))
    if rows and rows[-1][0] == key: continue
    rows.append((key, float(m.group(1)), float(m.group(2)), int(n.group(1)), int(n.group(2)),
                 float(k.group(1)), float(pw.group(1)) if pw else float('nan')))
if not rows: print('没有匹配行'); sys.exit(1)
dur = max(b for _,a,b,_,_,_,_ in rows)
# 轨道端点：取全片档（u 最接近 1 的那行）
full = [r for r in rows if abs(r[2]-dur) < 1e-3 and r[1] < 1e-6]
L0, R0 = (full[0][3], full[0][4]) if full else (min(r[3] for r in rows), max(r[4] for r in rows))
rw = R0 - L0
print('dur=%.3f  轨道环心 %d..%d  rw=%d' % (dur, L0, R0, rw))
print('%-11s %6s %7s %8s %8s %6s %6s  %s' % ('t0~t1','u','w','k日志','k公式','L','R','判'))
bad = 0
for key,a,b,L,R,k,pw in rows:
    u = (b-a)/dur; w = (R-L)/rw
    ki = (1-w)/(1-u) if u < 1-1e-9 else pw
    tag = []
    if u < 1-1e-9:
        d = abs(k-ki)
        if d > 0.02: tag.append('k差%.3f' % d); bad += 1
        else: tag.append('kOK')
    if a < 1e-6:
        if L != L0: tag.append('贴头L=%d≠%d' % (L, L0)); bad += 1
        else: tag.append('贴头L=0')
    if abs(b-dur) < 1e-3:
        if R != R0: tag.append('贴尾R=%d≠%d' % (R, R0)); bad += 1
        else: tag.append('贴尾R=1')
    print('%-11s %6.4f %7.4f %8.4f %8.4f %6d %6d  %s' % ('%.1f~%.1f'%(a,b), u, w, k, ki, L, R, ','.join(tag)))
print('结论:', 'PASS' if bad == 0 else 'FAIL(%d)' % bad)
