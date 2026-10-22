-- 贴近真机：鼠标跟着右环从 0.96 走到 0.513（缩到最小），再往回走到条尾
mp.register_event('file-loaded', function()
    mp.set_property_native('pause', true)
    mp.add_timeout(1.2, function()
        mp.commandv('script-message', 'tl-set', '0', '29')
        mp.set_property_number('time-pos', 12)
        mp.add_timeout(0.6, function()
            mp.commandv('script-message', 'tl-grab', 'right', '0.9621')
            local us = {}
            for i = 1, 10 do us[#us + 1] = 0.9621 - i * 0.045 end
            for i = 1, 12 do us[#us + 1] = 0.5121 + i * 0.041 end
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
