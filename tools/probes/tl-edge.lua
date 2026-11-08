-- tl-edge.lua —— r58「撞片头/片尾后宽度冻结」取证探针
-- 用法（在 mpv-player 目录下）：.\mpv.exe --vo=null --no-audio
--   --script-opts=source-markers-tl_dbg=file,tl-edge-scene=1
--   --script=..\tools\probes\tl-edge.lua ..\reference\标尺素材-5min-30fps.mp4
-- u 是「概览条归一化位置」0..1（整片），不是区间内比例
local opts = require 'mp.options'
local o = { scene = '1' }
opts.read_options(o, 'tl-edge')

local S = {
    -- 5 min = 300 s。区间 30~60 s（跨度 30），播放头 45 s（p0 = 0.5），抓左环向左放大到撞片头
    -- 播放头 45 s 落在区间正中 ⇒ 进同动，左端一路外扩到撞片头
    ['1'] = { t0 = 30, t1 = 60, tph = 45, kind = 'left',  u0 = 0.283, ua = 0.283, ub = -0.060, n = 80 },
    -- 对照：同级起手，抓右环向右放大到撞片尾
    -- 播放头贴近片尾（255 s，2*(300-255)=90 < 2*255）⇒ 对称上限由片尾决定，撞的是片尾而不是片头
    ['2'] = { t0 = 240, t1 = 270, tph = 255, kind = 'right', u0 = 0.9800, ua = 0.9800, ub = 3.000, n = 80 },
    -- 撞片头后反向缩小：验证冻结能自动解除（前一半放大撞边、后一半原地回拖）
    ['3'] = { t0 = 30, t1 = 60, tph = 45, kind = 'left', u0 = 0.283, ua = 0.283, ub = -0.060, n = 90, back = true },
}
local sc = S[o.scene]
if not sc then mp.msg.error('tl-edge: unknown scene ' .. tostring(o.scene)) return end

local function run()
    mp.set_property_native('pause', true)
    mp.commandv('script-message', 'tl-dbg', 'file')
    mp.commandv('script-message', 'tl-set', tostring(sc.t0), tostring(sc.t1))
    mp.set_property_number('time-pos', sc.tph)
    mp.add_timeout(0.70, function()
        mp.commandv('script-message', 'tl-dbg-mark', string.format('SCENE %s t0=%s t1=%s tph=%s kind=%s', o.scene, sc.t0, sc.t1, sc.tph, sc.kind))
        mp.commandv('script-message', 'tl-grab', sc.kind, string.format('%.4f', sc.u0))
        local i = 0
        local function nxt()
            i = i + 1
            if i > sc.n then
                mp.commandv('script-message', 'tl-dbg-mark', 'SCENE END')
                mp.commandv('script-message', 'tl-drop')
                mp.add_timeout(0.50, function() mp.commandv('quit') end)
                return
            end
            local u
            if sc.back then
                local half = sc.n / 2
                if i <= half then u = sc.ua + (sc.ub - sc.ua) * (i / half)
                else u = sc.ub + (sc.ua - sc.ub) * ((i - half) / (sc.n - half)) end
            else
                u = sc.ua + (sc.ub - sc.ua) * (i / sc.n)
            end
            mp.commandv('script-message', 'tl-drag-n', string.format('%.5f', u))
            mp.add_timeout(0.10, nxt)
        end
        mp.add_timeout(0.30, nxt)
    end)
end
mp.register_event('file-loaded', function() mp.add_timeout(1.20, run) end)
