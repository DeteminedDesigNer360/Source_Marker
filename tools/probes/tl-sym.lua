-- tl-sym.lua —— P2①「进同动瞬间远端瞬移」取证探针
-- 用法：mpv.com --config-dir=portable_config --vo=gpu --geometry=1000x700 \
--        --script-opts=source-markers-tl_dbg=file,tl-sym-scene=1 \
--        --script=..\..\tools\probes\tl-sym.lua 素材.mp4
-- 每个场景跑完自动退出；日志落在 portable_config\source-markers-dbg.log
local opts = require 'mp.options'
local o = { scene = '1' }
opts.read_options(o, 'tl-sym')

-- u 是「概览条归一化位置」0..1（整片），不是区间内比例
local S = {
    ['1'] = { t0 = 0, t1 = 30, tph = 10, kind = 'left',  u0 = 0.002, ua = 0.002, ub = 0.060, n = 50 },
    ['2'] = { t0 = 0, t1 = 30, tph = 15, kind = 'left',  u0 = 0.002, ua = 0.002, ub = 0.060, n = 50 },
    -- 抓右圆向左拖：条上位置按 w=u^p 折算（rw=820、p≈0.5623），u 0.4045→0.3175 对应右端 60→39 s
    ['3'] = { t0 = 0, t1 = 60, tph = 20, kind = 'right', u0 = 0.4045, ua = 0.4045, ub = 0.3175, n = 40 },
}
local sc = S[o.scene]
if not sc then mp.msg.error('tl-sym: unknown scene ' .. tostring(o.scene)) return end

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
            local u = sc.ua + (sc.ub - sc.ua) * (i / sc.n)
            mp.commandv('script-message', 'tl-drag-n', string.format('%.5f', u))
            mp.add_timeout(0.10, nxt)
        end
        mp.add_timeout(0.30, nxt)
    end)
end
mp.register_event('file-loaded', function() mp.add_timeout(1.20, run) end)