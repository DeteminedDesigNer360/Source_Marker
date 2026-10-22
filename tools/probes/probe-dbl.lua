mp.register_event('file-loaded', function()
  local T = 0.9
  local function at(d, fn) T = T + d; mp.add_timeout(T, fn) end
  mp.add_timeout(0.9, function() mp.commandv('script-message', 'tl-set', '0', '0.05') end)
  T = 1.5
  at(0.0, function() mp.commandv('script-message', 'tl-hit', '300', '600') end)
  at(0.2, function() mp.commandv('script-message', 'tl-hit', '300', '600') end)
  at(0.8, function() mp.commandv('script-message', 'tl-hit', '300', '629') end)
  at(0.2, function() mp.commandv('script-message', 'tl-hit', '300', '629') end)
  mp.add_timeout(T + 0.8, function() mp.commandv('quit') end)
end)
