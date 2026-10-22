local function msg(...) mp.commandv('script-message', ...) end
mp.add_timeout(0.5, function() msg('tl-set', '0', '5') end)
mp.add_timeout(0.9, function() msg('tl-goto', '1.0') end)
mp.add_timeout(1.3, function() msg('tl-grab', 'right') end)
mp.add_timeout(1.7, function() msg('tl-drag', '1050') end)
mp.add_timeout(2.2, function() msg('tl-drag', '1200') end)
mp.add_timeout(2.7, function() msg('tl-drag', '1400') end)
mp.add_timeout(3.2, function() msg('tl-drag', '1600') end)
mp.add_timeout(3.8, function() mp.commandv('quit') end)
