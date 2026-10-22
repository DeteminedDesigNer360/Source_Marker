-- 播放头偏离中心（12/30）时同动放大，看右端是否在 29.x 锁死
mp.register_event('file-loaded', function()
    mp.set_property_native('pause', true)
    mp.add_timeout(1.2, function()
        mp.commandv('script-message', 'tl-set', '0', '29')
        mp.set_property_number('time-pos', 12)
        mp.add_timeout(0.6, function()
            mp.commandv('script-message', 'tl-grab', 'right', '0.9621')
            local us = {}
            for i = 1, 20 do us[#us + 1] = 0.9621 - i * 0.047 end
            for i = 1, 22 do us[#us + 1] = 0.0221 + i * 0.047 end
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
