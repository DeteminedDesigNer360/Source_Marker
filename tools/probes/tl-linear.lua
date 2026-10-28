-- tl-linear.lua —— 概览条线性度回归探针（P1/P4/P7）
--
-- 用法（在 mpv-player 目录下，或把 --config-dir 指到 portable_config）：
--   mpv.com --config-dir=portable_config --log-file=_tmp\tl.log --msg-level=all=v --           --script=tools\probes\tl-linear.lua 你的素材.mp4
--
-- 它会按媒体时长的比例依次设 7 个区间，每档 0.6 s，打完自己退出。
-- 判定：日志里每行「时间轴：范围 a~b … 画布 x X0..X1 … 概览x=L,R 概览k=K」
--   · 期望 L = X0 + (X1-X0)*a/dur，R = X0 + (X1-X0)*b/dur
--   · 常规区间应逐像素命中；最窄档会被"最小环心距"撑开（L/R 离开期望值是正常的）
--   · 概览k 必须是 1.0000（幂律已删；不是 1 说明装的是旧版）
--   解析脚本：tools\probes\tl-parse.py <log>
local dur = mp.get_property_number('duration')
local function run()
  dur = dur or mp.get_property_number('duration')
  if not dur or dur <= 0 then mp.msg.error('拿不到 duration，先给一个真视频文件') mp.commandv('quit') return end
  local frames = { {0, 1.0}, {0, 0.5}, {0.25, 0.75}, {0.5, 0.75}, {0.497, 0.503}, {0, 0.004}, {0.996, 1.0} }
  local i = 0
  local function step()
    i = i + 1
    local f = frames[i]
    if not f then mp.commandv('quit') return end
    local a, b = f[1] * dur, f[2] * dur
    if b - a < 1e-6 then b = a + 1e-6 end
    mp.msg.info(string.format('CASE %d %.4f %.4f', i, a, b))
    mp.commandv('script-message', 'tl', tostring(a), tostring(b))
    mp.add_timeout(0.6, step)
  end
  mp.add_timeout(1.5, step)
end
run()
