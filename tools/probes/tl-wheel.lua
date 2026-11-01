-- tl-wheel.lua —— P3「刻度带滚轮语义」取证探针
-- 用法（在 mpv-player 目录下，不要传 --config-dir）：
--   .\mpv.com --vo=null --ao=null --geometry=1000x700 --msg-level=all=v \
--     --script=..\..\tools\probes\tl-wheel.lua ..\..\reference\标尺素材-5min-30fps.mp4
-- 每步先把播放头放回 100 s，再发一次 tl-wheel-at，输出前后 time-pos 与折算帧数。
-- 几何坐标来自 render_timeline 的 verbose 日志（1000x700 窗口）：
--   tc=554,18 标签行=575 基线=617 概览=621 画布 x=112..1167
--   ⇒ axis 取 y=590（552..619 内且不被 con 抢）、con 取 y=625（>619）
local SEQ = {
    { n = 'axis naked up',    x = 600, y = 590, dir = 1,  mod = '' }, 
    { n = 'axis naked down',  x = 600, y = 590, dir = -1, mod = '' }, 
    { n = 'axis ctrl up',     x = 600, y = 590, dir = 1,  mod = 'ctrl' }, 
    { n = 'axis ctrl down',   x = 600, y = 590, dir = -1, mod = 'ctrl' }, 
    { n = 'axis shift up',    x = 600, y = 590, dir = 1,  mod = 'shift' }, 
    { n = 'axis shift down',  x = 600, y = 590, dir = -1, mod = 'shift' }, 
    { n = 'con naked up',     x = 600, y = 625, dir = 1,  mod = '' }, 
    { n = 'con ctrl up',      x = 600, y = 625, dir = 1,  mod = 'ctrl' }, 
    { n = 'con shift up',     x = 600, y = 625, dir = 1,  mod = 'shift' }, 
}
local i = 0
local function step()
    i = i + 1
    local sc = SEQ[i]
    if not sc then
        mp.msg.warn('WHEELRES END')
        mp.add_timeout(0.4, function() mp.commandv('quit') end)
        return
    end
    mp.set_property_number('time-pos', 100)
    mp.add_timeout(0.25, function()
        local before = mp.get_property_number('time-pos') or -1
        mp.commandv('script-message', 'tl-wheel-at', tostring(sc.x), tostring(sc.y), tostring(sc.dir), sc.mod)
        mp.add_timeout(0.30, function()
            local after = mp.get_property_number('time-pos') or -1
            local fps = mp.get_property_number('estimated-vf-fps') or 30
            mp.msg.warn(string.format('WHEELRES %-16s before=%.4f after=%.4f frames=%+.1f', sc.n, before, after, (after - before) * fps))
            mp.add_timeout(0.20, step)
        end)
    end)
end
local function run()
    mp.set_property_native('pause', true)
    mp.commandv('script-message', 'tl-set', '100', '200')
    mp.add_timeout(0.60, function() mp.msg.warn('WHEELRES BEGIN'); step() end)
end
mp.register_event('file-loaded', function() mp.add_timeout(1.20, run) end)
