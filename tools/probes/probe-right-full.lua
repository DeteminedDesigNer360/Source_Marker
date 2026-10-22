-- 复现用户轨迹：播放头 10 s，抓右圆，从全片缩到最小再放大回全片
mp.register_event('file-loaded', function()
    mp.set_property_native('pause', true)
    mp.add_timeout(1.2, function()
        mp.commandv('script-message', 'tl-set', '0', '30')
        mp.set_property_number('time-pos', 10)
        mp.add_timeout(0.6, function()
            mp.commandv('script-message', 'tl-grab', 'right', '0.9900')
            local us = {}
            for i = 1, 20 do us[#us + 1] = 0.99 - i * 0.0225 end    -- 缩到 0.54
            for i = 1, 20 do us[#us + 1] = 0.54 + i * 0.0225 end    -- 放回 0.99
            local i = 0
            local function nxt()
                i = i + 1
                local u = us[i]
                if not u then mp.commandv('script-message', 'tl-drop') return end
                mp.commandv('script-message', 'tl-drag-n', string.format('%.4f', math.max(0.001, math.min(1, u))))
                mp.add_timeout(0.16, nxt)
            end
            mp.add_timeout(0.3, nxt)
        end)
    end)
end)
