local function msg(...) mp.commandv('script-message', ...) end
mp.add_timeout(0.5, function() msg('tl-set', '25', '30') end)
mp.add_timeout(0.9, function() msg('tl-goto', '29.0') end)
mp.add_timeout(1.3, function() msg('tl-grab', 'left') end)
mp.add_timeout(1.7, function() msg('tl-drag', '40') end)
mp.add_timeout(2.2, function() msg('tl-drag', '0') end)
mp.add_timeout(2.7, function() msg('tl-drag', '-80') end)
mp.add_timeout(3.4, function() mp.commandv('quit') end)
