-- 让时间轴落到最小跨度后停住，供截图量像素
local function arm()
    mp.add_timeout(1.5, function()
        mp.commandv('script-message', 'tl-set', '0', '0.05')
        mp.add_timeout(0.6, function()
            local t0, t1 = 0, 0
            if TL and TL.geo then
                local g = TL.geo
                t0, t1 = g.t0 or 0, g.t1 or 0
            end
            mp.msg.info(string.format('probe-min 区间 %.4f~%.4f', t0, t1))
        end)
    end)
end
mp.register_event('file-loaded', arm)
