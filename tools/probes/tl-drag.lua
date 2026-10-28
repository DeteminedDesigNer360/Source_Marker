-- tl-drag.lua —— 拖圆"另一端像素钉死"回归探针（P4）
--
-- 用法同 tl-linear.lua：
--   mpv.com --config-dir=portable_config --log-file=_tmp\drag.log --msg-level=all=v --           --script=tools\probes\tl-drag.lua 你的素材.mp4
--
-- 两组：
--   A 常规档（25%~75%）抓右环往右拖 —— 左环心必须**一像素不动**
--   B 最窄档（99.4%~99.9%）抓右环 —— 跨度触底后允许整体平移，此时左环会跟着走，属正常
-- 解析：tools\probes\tl-parse.py _tmp\drag.log <duration>
local dur = mp.get_property_number('duration') or 300
local function pct(p) return tostring(p / 100 * dur) end
local script = {
  {'tl', pct(25), pct(75)},
  {'tl-dbg-mark', 'A-normal-grab-right'},
  {'tl-grab', 'right'},
  {'tl-drag-n', '0.80'},
  {'tl-drag-n', '0.85'},
  {'tl', pct(99.4), pct(99.9)},
  {'tl-dbg-mark', 'B-narrow-grab-right'},
  {'tl-grab', 'right'},
  {'tl-drag-n', '0.997'},
  {'tl-drag-n', '0.999'},
}
local i = 0
local function step()
  i = i + 1
  local c = script[i]
  if not c then mp.commandv('quit') return end
  mp.msg.info('STEP ' .. i .. ' ' .. table.concat(c, ' '))
  local args = {'script-message'}
  for k = 1, #c do args[#args + 1] = c[k] end
  mp.commandv(table.unpack and table.unpack(args) or unpack(args))
  mp.add_timeout(0.45, step)
end
mp.add_timeout(2.0, step)
