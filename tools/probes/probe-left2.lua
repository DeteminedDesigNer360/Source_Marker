-- 真实轨迹：鼠标跟着左环走（0 → 0.485 → 0 → 继续往左）
mp.register_event('file-loaded', function()
    mp.set_property_native('pause', true)
    mp.add_timeout(1.2, function()
        mp.commandv('script-message', 'tl-set', '0', '29')
        mp.set_property_number('time-pos', 10)
        mp.add_timeout(0.6, function()
            mp.commandv('script-message', 'tl-grab', 'left', '0.005')
            local us = {}
            for i = 1, 10 do us[#us + 1] = 0.005 + i * 0.048 end   -- 0.053 … 0.485
            for i = 1, 10 do us[#us + 1] = 0.485 - i * 0.048 end   -- 0.437 … 0.005
            for i = 1, 6 do us[#us + 1] = 0.001 end
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
