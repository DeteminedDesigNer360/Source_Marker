-- tl-kassert.lua —— 中心压缩系数 k = (1-w)/(1-u) 的回归探针（r54 / B1）
--
-- 用法（必须在 mpv-player 目录下跑，不要传 --config-dir）：
--   .\mpv.com --vo=null --ao=null --log-file=..\_tmp\k.log --msg-level=all=v --script=..\tools\probes\tl-kassert.lua ..\reference\标尺素材-5min-30fps.mp4
--
-- 每档用 script-message tl a b 设区间，日志会打出：
--   概览x=L,R 概览k=K 概览p=P 环心距min=M
-- 判据（解析脚本 tools\probes\tl-kparse.py）：
--   w = (R-L)/rw，u = (b-a)/dur，k 应为 (1-w)/(1-u)；贴片头时 L 应为 0，贴片尾时 R 应为 rw。
local dur = mp.get_property_number('duration')
local frames = {
  {0.00, 1.00, 'FULL'},
  {0.00, 0.50, 'HEAD50'},
  {0.25, 0.75, 'MID'},
  {0.00, 0.30, 'HEAD30'},
  {0.70, 1.00, 'TAIL30'},
  {0.40, 0.50, 'SMALL45'},
  {0.50, 0.60, 'SMALL55'},
  {0.00, 0.05, 'HEAD5'},
  {0.95, 1.00, 'TAIL5'},
}
local i = 0
local function step()
  i = i + 1
  local f = frames[i]
  if not f then mp.commandv('quit') return end
  local a, b = f[1] * dur, f[2] * dur
  if b - a < 1e-6 then b = a + 1e-6 end
  mp.msg.info(string.format('CASE %d %s %.4f %.4f', i, f[3], a, b))
  mp.commandv('script-message', 'tl', tostring(a), tostring(b))
  mp.add_timeout(0.7, step)
end
local function wait_dur()
  dur = mp.get_property_number('duration')
  if not dur or dur <= 0 then mp.add_timeout(0.25, wait_dur) return end
  mp.msg.info(string.format('DUR %.4f', dur))
  mp.add_timeout(0.8, step)
end
wait_dur()
