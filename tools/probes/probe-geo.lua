mp.register_event('file-loaded', function()
    mp.set_property_native('pause', true)
    mp.add_timeout(1.5, function()
        mp.commandv('script-message', 'tl-set', '0', '29')
        mp.set_property_number('time-pos', 14.5)
        mp.add_timeout(0.8, function()
            local g = TL and TL.geo
            if g then
                mp.msg.warn(string.format('GEO t0=%.3f t1=%.3f dur=%.3f rw=%.1f cr=%s wx0=%.1f wx1=%.1f',
                    g.t0, g.t1, g.dur, g.rw, tostring(g.cr), g.wx0, g.wx1))
            else
                mp.msg.warn('GEO nil')
            end
            mp.add_timeout(0.5, function() mp.commandv('quit') end)
        end)
    end)
end)
