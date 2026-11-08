-- tl-cgroup.lua —— C 组（最小档与拖圆）判据取证探针
-- 用法（在 mpv-player 目录下，素材用 ASCII 路径）：
--   .\mpv.exe --vo=null --no-audio --script-opts=source-markers-tl_dbg=file,tl-cgroup-scene=N \
--     --script=<本文件绝对路径> ..\reference\ref-CFR-23976-60min.mp4
-- 60 min 素材 = 3610.023 s；--vo=null 下 OSD 1280x720 ⇒ x0=112 rw=1055 p=0.5040 最窄环心距 22 px
-- abs=true 的场景用 tl-drag（绝对像素），可以拖出条外 —— 真机就是这样，tl-drag-n 会钳在 0..1
local opts = require 'mp.options'
local o = { scene = '1' }
opts.read_options(o, 'tl-cgroup')

local S = {
    ['1'] = { t0 = 1000, t1 = 1001.6683, ph = 3000, kind = 'right', u0 = 0.27109, du = 0.007583, n = 24 },
    ['2'] = { t0 = 1000, t1 = 1001.6683, ph = 3000, kind = 'left',  u0 = 0.29194, du = -0.007583, n = 24 },
    ['3'] = { t0 = 3590, t1 = 3591.6683, ph = 3000, kind = 'right', u0 = 0.99502, du = 0.0012, n = 24 },
    ['4'] = { t0 = 20, t1 = 21.6683, ph = 3000, kind = 'left',  u0 = 0.00521, du = -0.0012, n = 24 },
    ['5'] = { t0 = 1000, t1 = 1001.6683, ph = 1000.8342, kind = 'right', u0 = 0.27109, du = 0.007583, n = 24 },
    ['6'] = { t0 = 1000, t1 = 1610, ph = 3000, kind = 'right', u0 = 0.60550, du = 0.005, n = 12 },
    ['7'] = { t0 = 1000, t1 = 1610, ph = 3000, kind = 'left',  u0 = 0.19723, du = -0.005, n = 12 },
    ['8'] = { t0 = 1000, t1 = 1001.6683, ph = 3000, kind = 'right', u0 = 0.27109, du = 0.012, n = 60 },
    -- 撞片尾后继续把鼠标拖出条外（真机行为）：tl-drag 绝对像素，x0=112 rw=1055
    ['3b'] = { t0 = 3590, t1 = 3591.6683, ph = 3000, kind = 'right', u0 = 0.99502, abs = true, xa = 1162, dx = 8, n = 24 },
    -- 撞片头后继续拖出条外
    ['4b'] = { t0 = 20, t1 = 21.6683, ph = 3000, kind = 'left',  u0 = 0.00521, abs = true, xa = 117, dx = -8, n = 24 },
    -- 从最窄档一路放大到全片，并把鼠标拖出条外 111 px（C 组 :564 的「拖到顶」）
    ['9'] = { t0 = 1000, t1 = 1001.6683, ph = 3000, kind = 'right', u0 = 0.27109, abs = true, xa = 398, dx = 8, n = 110 },
    -- 用户报的疑似遗留 bug：30 s 素材、可见范围 0~10（贴片头）、播放头 20 s，抓右环放大到撞片尾
    ['10'] = { t0 = 0, t1 = 10, ph = 20, kind = 'right', u0 = 0.28645, abs = true, xa = 414, dx = 10, n = 80 },
    -- 30 s 素材扫多种初始可见范围（播放头 20 s），找用户报的「撞片尾瞬间左环瞬移」
    ['11'] = { t0 = 15, t1 = 25, ph = 20, kind = 'right', u0 = 0.82161, abs = true, xa = 979, dx = 10, n = 60 },
    ['12'] = { t0 = 17, t1 = 21, ph = 20, kind = 'right', u0 = 0.68879, abs = true, xa = 839, dx = 10, n = 60 },
    ['13'] = { t0 = 5, t1 = 6.6683, ph = 20, kind = 'right', u0 = 0.20755, abs = true, xa = 331, dx = 10, n = 90 },
    ['14'] = { t0 = 25, t1 = 30, ph = 20, kind = 'right', u0 = 1.0, abs = true, xa = 1167, dx = 10, n = 40 },
}
local sc = S[o.scene]
if not sc then mp.msg.error('tl-cgroup: unknown scene ' .. tostring(o.scene)) return end

local function run()
    mp.set_property_native('pause', true)
    mp.commandv('script-message', 'tl-dbg', 'file')
    mp.commandv('script-message', 'tl-set', tostring(sc.t0), tostring(sc.t1))
    mp.set_property_number('time-pos', sc.ph)
    mp.add_timeout(0.90, function()
        mp.commandv('script-message', 'tl-dbg-mark',
            string.format('SCENE %s t0=%.4f t1=%.4f ph=%.4f kind=%s', o.scene, sc.t0, sc.t1, sc.ph, sc.kind))
        mp.commandv('script-message', 'tl-grab', sc.kind, string.format('%.5f', sc.u0))
        local i = 0
        local u = sc.u0
        local x = sc.xa
        local function nxt()
            i = i + 1
            if i > sc.n then
                mp.commandv('script-message', 'tl-dbg-mark', 'SCENE END')
                mp.commandv('script-message', 'tl-drop')
                mp.add_timeout(0.40, function() mp.commandv('quit') end)
                return
            end
            if sc.abs then
                x = x + sc.dx
                mp.commandv('script-message', 'tl-drag', string.format('%.1f', x))
            else
                u = u + sc.du
                mp.commandv('script-message', 'tl-drag-n', string.format('%.5f', math.max(0, math.min(1, u))))
            end
            mp.add_timeout(0.12, nxt)
        end
        mp.add_timeout(0.35, nxt)
    end)
end
mp.register_event('file-loaded', function() mp.add_timeout(1.20, run) end)