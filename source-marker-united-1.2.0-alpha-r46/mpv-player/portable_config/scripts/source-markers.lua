--[[
  source-markers.lua —— mpv 播放头标记插件（与 Premiere「Source Marker」面板互通）

  做标记：在播放头位置记录 时间戳 / 颜色 / 正文，可列表查看、跳转、导入导出。
  导出文件直接喂给 Pr 的 CEP 面板「导入标记」（CSV/JSON/SRT，颜色为 Pr 标记色索引）。

  安装（便携 mpv）：把本文件放到
      <mpv>\portable_config\scripts\source-markers.lua
  或启动时：  mpv --script=source-markers.lua

  默认键位（都不与 mpv 默认键冲突；随时按 F1 看帮助）：
      F1              帮助浮窗（列出全部快捷键）
      F2              可点击的按钮面板（鼠标党入口，可一直留着）
      Ctrl+m          在播放头打标记（用当前颜色）
      Alt+m           打标记并输入正文（正文就是 Pr 里看到的标记名）
      Ctrl+1 .. 8     设定当前颜色（对应 Pr 标记色 0..7：绿/红/紫/橙/黄/白/蓝/青）
      Ctrl+l          显示 / 隐藏标记列表
      Alt+n / Alt+p   跳到下一个 / 上一个标记
      Alt+g           按序号跳转
      Alt+e           编辑离播放头最近的标记的正文（只改正文）
      Ctrl+DEL        删除离播放头最近的标记
      Ctrl+e          直接导出标记（覆盖同名文件，不弹框）
    Ctrl+Shift+e    直接导出标记并带时间戳（另存为迭代，不覆盖）
    Ctrl+Alt+e    导出标记到指定路径（弹输入框）
      Ctrl+i          导入（CSV / TSV / JSON / SRT）

  关于 name 列：列按格式 v1 保留在表头里，但内容留空。
  Pr 面板的标记名只取「备注/comment 列」，name 列整列忽略，所以本插件不再生成 M01/M02 之类的
  占位名；用户输入一律进 comment。自动保存的 *.mpv-autosave.json 会带隐藏属性，避免误删误改。

  可在 mpv.conf 里改路径与行为，例如：
      script-opts=source-markers-sidecar=yes
      script-opts=source-markers-time_format=ms       # ms（默认）| ff | sec | auto
      script-opts=source-markers-default_color=0      # 0..7（0 = 绿，与 Pr 的默认标记色一致）
      script-opts=source-markers-dir=~~home/markers   # sidecar=no / 流输入时的目录
      script-opts=source-markers-csv_bom=no           # 导出 CSV 不带 BOM
]]

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local opts = require 'mp.options'

-- Lua 5.1 / 5.2 兼容
local unpack = table.unpack or unpack

-- 播放器内输入框：mpv ≥0.38 提供 mp.input 模块，但它是 require 进来的，不挂在 mp 表上
-- （实测 0.36 与 0.41：mp.input == nil，require 'mp.input' 才拿得到）
local input = nil
do
    local ok, mod = pcall(require, 'mp.input')
    if ok and type(mod) == 'table' and type(mod.get) == 'function' then input = mod end
end

local o = {
    sidecar = true,            -- 与视频同名的 .mpv-autosave.json 自动保存
    hide_sidecar = true,       -- 把自动保存的 .mpv-autosave.json 设成隐藏文件（Windows；防误删/误改）
    dir = '~~home/markers',    -- sidecar=false 时的存放目录
    default_color = 0,         -- 默认当前颜色（0 = 绿；与 Pr 的默认标记色一致）
    time_format = 'ms',        -- ms（规范默认）| ff | sec | auto
    csv_bom = true,            -- 导出 CSV 是否带 UTF-8 BOM（Excel 友好）
    import_mode = 'replace',   -- replace | append
    overlay = true,            -- 打标记时是否顺带显示列表
    overlay_x = 40,
    overlay_y = 50,
    overlay_size = 22,
    overlay_limit = 18,
    panel = false,             -- 首次启动是否显示按钮面板；之后以 F2 的选择为准（存在界面状态文件里）
    panel_anchor = 'bottom-left', -- bottom-left | top-left | top-right | bottom-right
    panel_x = 40,              -- 面板左右留白
    panel_bottom = 0,          -- 距底部像素；0 = 自动（抬到 mpv 进度条上方）
    hint = true,               -- 首次打开素材时提示「F1 帮助 / F2 按钮面板」
    hr_seek = true,            -- 跳转是否帧精确（false 时按关键帧跳）
    nearest_window = 1.0,      -- 「最近标记」的判定半径（秒）；超出就提示附近没有（见 4(b) 修复）
    export_stamp = false,      -- 默认导出是否带时间戳（false = 覆盖同名文件；Ctrl+Shift+E 始终带戳）
    hide_export_json = true,   -- 把导出的同名 .json 设成隐藏（减少目录里的视觉重复）
    python = 'python',         -- 老版本 mpv 的输入框兜底解释器
    helper = '',               -- 自定义输入框脚本（留空用内置）
    bar_scale = 1.0,           -- 第 8 条：Pr 风格控制栏的额外缩放（1.0 = 只随窗口自适应）
    bar_tooltip = false,       -- 第 8 条：鼠标悬停时在按钮上方显示按钮名（默认关）
    tl = true,                 -- 第 9 条：Pr 风格下是否显示那条可缩放时间轴（默认开）
    tl_scale = 2.0,            -- 第 9 条：时间轴自己的缩放因子（Pr 里时间轴高度 ≈ 控制栏的 2~3 倍）
    tl_min_frames = 15,        -- 第 9 条：时间轴最小跨度（帧）——滚轮最多放大到这么多帧
tl_min_px = 40,            -- 第 9 条：概览条两圆最小间距（像素，Pr 实测约 40）——长片上按它抬高最小跨度
    tl_zoom_steps = '1.003,1.001,1.01',  -- 第 9 条：滚轮缩放步长（普通,Ctrl细,Shift粗）——用户实测手感值
    tl_zoom_anchor = 'snap',   -- 第 9 条：缩放锚点 snap = 缩放后播放头落在区间正中（Pr NS1 实测定论，默认）| head = 死钉播放头 | center = 钉区间中心 | pr = 每档拉向中心
    tl_zoom_pull = 0.585,      -- 第 9 条：pr 的拉力 —— Pr 实测"每 ×2 一步把离中心的偏移乘 2/3"，即 pull = -log2(2/3)
    tl_key_step = 2.0,         -- 第 9 条：Alt+= / Alt+- 的步长（Pr 的 = 实测就是 ×2）
    tl_labels = true,          -- 第 9 条：刻度上是否显示时间戳（Pr 没有；默认开）
    tl_ov_map = 'bar',         -- 第 9 条：概览条映射 linear | sqrt | pow | bar（bar = Pr 实测形态，默认）
    tl_ov_pow = 1.30,          -- 第 9 条：亮段宽 = u^pow —— 三轮实测 1.29~1.31，取 1.30
    tl_ov_k = 1.19,            -- 第 9 条：bar 模式中心斜率（u=1/2 处）—— NS4 两轮拟合，深层按 u^0.68 衰减
    tl_ov_pin = 'px',          -- 第 9 条：拖圆缩放的钉住口径 px = 另一端像素不动、该端时间微调（Pr 实测：左端漂 12~16 帧，默认）| time = 另一端时间不动
    tl_hit_px = 13,            -- 第 9 条：概览条两个圆的命中半径（px）；圆直径约 12，放大到 1.1 倍 = 13
    tl_ov_edge = 'pin',        -- 第 9 条：概览条贴片头/片尾时的映射 pin = 那一端钉死在 0/1（默认，跨过贴边瞬间会跳 6~21 px）| pr = 连续口径（不跳，但贴边那端会漂几 px）
    tl_play_follow = 'pr',     -- 第 9 条：播放跟随 off | pr（播放中不动、暂停追平居中，默认）| page（播到区间尾翻页）| center（始终居中）
tl_grab_feel = 'mouse',    -- 第 9 条：拖圆缩放手感 mouse（抓哪端动哪端、另一端钉死，默认）| pr（两阶段：缩=远端动、放=被抓端动；跨度缩到 2×(播放头−近端) 以下会改成以播放头对称 ⇒ 钉住端漂移，用户上机否决）
}
opts.read_options(o, 'source-markers')

-- Pr 标记色（索引与名称/近似色值一一对应；色值仅用于 OSD 显示）
-- Pr 标记色 0..7（索引语义由契约 §4 冻结：绿红紫橙黄白蓝青）。
-- 色值优先从**共享表** portable_config/marker-colors.json 读取（1.2.0「交织」①），
-- 下面这份内置表是**回退**：共享表缺失/不完整时仍能正常工作。
-- 这份回退必须与共享表一致 —— tools/_sm-export-test.js 里有守卫会盯着。
local COLORS = {
    [0] = { name = '绿', rgb = { 0x71, 0x86, 0x37 } },
    [1] = { name = '红', rgb = { 0xD2, 0x2C, 0x36 } },
    [2] = { name = '紫', rgb = { 0xAF, 0x8B, 0xB1 } },
    [3] = { name = '橙', rgb = { 0xE9, 0x6F, 0x24 } },
    [4] = { name = '黄', rgb = { 0xD0, 0xA1, 0x2B } },
    [5] = { name = '白', rgb = { 0xFF, 0xFF, 0xFF } },
    [6] = { name = '蓝', rgb = { 0x42, 0x8D, 0xFC } },
    [7] = { name = '青', rgb = { 0x19, 0xF4, 0xD6 } },
}
local function ass_color(i)
    local c = COLORS[i] or COLORS[1]
    local r, g, b = c.rgb[1], c.rgb[2], c.rgb[3]
    return string.format('&H%02X%02X%02X&', b, g, r)
end
local function color_name(i)
    local c = COLORS[i]
    if not c then return '?' end
    return c.name
end

local S = {
    markers = {},       -- { t=秒, name=, comment=, color= }
    color = tonumber(o.default_color) or 0,
    show_list = false,
    overlay = nil,
    sidecar = nil,      -- 当前视频对应的 sidecar 路径
    last_export = nil,
}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function log(fmt, ...)
    msg.info(string.format(fmt, ...))
end

local function notify(text)
    mp.osd_message(text, 2)
end

local function expand(path)
    return mp.command_native({ 'expand-path', path })
end

local function file_exists(path)
    if not path or path == '' then return false end
    local f = io.open(path, 'rb')
    if f then f:close() return true end
    return false
end

local function is_local_file(path)
    if not path or path == '' then return false end
    if path:match('^%a[%w+%.%-]*://') then return false end
    return true
end

local function dir_of(path)
    return path:match('^(.*)[/\\][^/\\]*$')
end

local function base_of(path)
    local name = path:match('([^/\\]+)$') or path
    return (name:gsub('%.[^%.]*$', ''))
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    if data and data:sub(1, 3) == '\239\187\191' then data = data:sub(4) end  -- 去 BOM
    return data
end

local function write_file_atomic(path, data)
    -- 「写 .tmp → 删原文件 → 改名」这三步在 Windows 上都可能被**瞬时占用**打断
    -- （杀软扫描刚写出的文件、别的进程短暂打开等），系统给的就是 EACCES / "Permission denied"。
    -- 真机上表现为"导出失败 + 视频旁 sidecar 同时写不进去"（两处都走这个函数），
    -- 历史记录见「改动说明」§6。所以这里做三件事：
    --   ① 最多 4 轮重试（失败时短暂等待，只等到真的失败才有开销）；
    --   ② 仍然不行就**退化为直接覆盖写目标**（牺牲原子性，先保证能用）；
    --   ③ 报错**点名是哪一步**失败（写临时文件 / 删原文件 / 改名 / 直接写），
    --      这样下次复发时光看 OSD 就知道卡在哪一步。
    local last = nil
    for attempt = 1, 4 do
        local tmp = path .. '.tmp'
        local f, oserr = io.open(tmp, 'wb')
        if not f then
            last = string.format('第①步写临时文件失败：%s（系统错误：%s）', tmp, tostring(oserr))
        else
            f:write(data)
            f:close()
            local removed, rerr = true, nil
            if file_exists(path) then
                local rok
                rok, rerr = os.remove(path)
                if not rok then removed = false; last = string.format('第②步删除原文件失败：%s（%s）', path, tostring(rerr)) end
            end
            if removed then
                local ok, err = os.rename(tmp, path)
                if ok then
                    if attempt > 1 then msg.verbose(string.format('写文件重试成功（第 %d 轮）：%s', attempt, path)) end
                    return true
                end
                last = string.format('第③步改名失败：%s → %s（%s）', tmp, path, tostring(err))
                os.remove(tmp)
            end
        end
        if attempt < 4 then
            local t0 = os.clock()
            while os.clock() - t0 < 0.12 do end      -- 只在失败路径上等一下（总开销 < 0.4s）
        end
    end
    local f2, oserr2 = io.open(path, 'wb')
    if f2 then
        f2:write(data)
        f2:close()
        msg.warn(string.format('原子写入失败，已退化为直接覆盖写：%s（%s）', path, tostring(last)))
        return true, '（已退化为直接写入）'
    end
    return false, string.format('%s ／ 直接覆盖写也失败：%s', tostring(last), tostring(oserr2))
end

----------------------------------------------------------------------
-- 帧率与时间码
----------------------------------------------------------------------

local function get_fps()
    local f = mp.get_property_number('container-fps')
    if not f or f <= 0 then f = mp.get_property_number('estimated-vf-fps') end
    if not f or f <= 0 then f = mp.get_property_number('video-params/fps') end
    if not f or f <= 0 then return nil end
    return f
end

-- 是否可变帧率（容器帧率与实测帧率明显不一致）
local function is_vfr()
    local a = mp.get_property_number('container-fps')
    local b = mp.get_property_number('estimated-vf-fps')
    if a and b and a > 0 and b > 0 and math.abs(a - b) > 0.05 then return true end
    return false
end

-- 时间码。必须与 Pr 侧 parseTimeToSeconds 严格互逆：
--   Pr 用  sec = HH*3600 + MM*60 + SS + FF / realFps
-- 所以这里按「整秒 + 真实帧率的帧号」拆，而不是把总帧数按四舍五入后的整数帧率取模
-- （后者在 29.97/23.976 上会线性漂移：300s 处偏 ~9 帧、600s 处偏 ~18 帧）。
-- 注意：不要改回「先算总帧数再拆位」——那是 Pr 侧 secondsToTimecode 的算法。
local function to_timecode(sec, fps)
    local f = tonumber(fps) or 25
    if f <= 0 then f = 25 end
    sec = tonumber(sec) or 0
    if sec < 0 then sec = 0 end                              -- 规范 §3：写入方禁止产出负数
    local maxff = math.ceil(f - 1e-9)                        -- 合法帧号上界（不含）；整数帧率时等于名义帧率
    if maxff < 1 then maxff = 1 end
    local whole = math.floor(sec)
    local ff = math.floor((sec - whole) * f + 0.5)
    if ff >= maxff then                                      -- 边界进位（如 25fps 的 3.999s）
        ff = 0
        whole = whole + 1
    end
    if ff < 0 then ff = 0 end
    return string.format('%02d:%02d:%02d:%02d',
        math.floor(whole / 3600), math.floor((whole % 3600) / 60), whole % 60, ff)
end

-- 帧率是否整数（29.97/23.976 这类非整数帧率下不建议写时间码）
local function fps_is_integer(fps)
    if not fps or fps <= 0 then return false end
    return math.abs(fps - math.floor(fps + 0.5)) < 0.001
end

local function to_hms_ms(sec)
    sec = math.max(0, tonumber(sec) or 0)
    local total = math.floor(sec * 1000 + 0.5)
    local ms = total % 1000
    local s = math.floor(total / 1000)
    return string.format('%02d:%02d:%02d.%03d',
        math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60, ms)
end

-- 与 Pr 侧 parseTimeToSeconds 同规则：秒 / MM:SS / HH:MM:SS(.mmm) / HH:MM:SS:FF
local function parse_time(str, fps)
    str = trim(str)
    if str == '' then return nil end
    if str:match('^%-?%d+%.?%d*$') then return tonumber(str) end
    local p = {}
    for piece in str:gmatch('[^:]+') do p[#p + 1] = trim(piece) end
    local n = #p
    if n == 4 then
        local a, b, c, d = tonumber(p[1]), tonumber(p[2]), tonumber(p[3]), tonumber(p[4])
        if not (a and b and c and d) then return nil end
        return a * 3600 + b * 60 + c + d / (tonumber(fps) or 25)
    elseif n == 3 then
        local a, b, c = tonumber(p[1]), tonumber(p[2]), tonumber(p[3])
        if not (a and b and c) then return nil end
        return a * 3600 + b * 60 + c
    elseif n == 2 then
        local a, b = tonumber(p[1]), tonumber(p[2])
        if not (a and b) then return nil end
        return a * 60 + b
    end
    return nil
end

-- 导出用的时间字段
local function time_field(sec)
    local mode = o.time_format
    local fps = get_fps()
    if mode == 'ff' then return to_timecode(sec, fps or 25) end
    if mode == 'sec' then return string.format('%.3f', sec) end
    if mode == 'auto' then
        -- 只有「整数帧率且不是 VFR」才写时间码，否则写毫秒（毫秒与帧率无关，绝不会错位）
        if fps and fps_is_integer(fps) and not is_vfr() then return to_timecode(sec, fps) end
        return to_hms_ms(sec)
    end
    return to_hms_ms(sec)   -- 默认 ms
end

----------------------------------------------------------------------
-- JSON（优先用 mpv 自带；老版本用内置兜底实现）
----------------------------------------------------------------------

local function json_escape(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', string.byte(c)) end)
    return '"' .. s .. '"'
end

local function fallback_json_encode(v)
    local t = type(v)
    if v == nil then return 'null' end
    if t == 'boolean' then return v and 'true' or 'false' end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
        return string.format('%.6f', v)
    end
    if t == 'string' then return json_escape(v) end
    if t == 'table' then
        local is_array = true
        local n = 0
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= 'number' then is_array = false break end
        end
        if is_array and n == #v then
            local out = {}
            for i = 1, #v do out[i] = fallback_json_encode(v[i]) end
            return '[' .. table.concat(out, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = json_escape(tostring(k)) .. ':' .. fallback_json_encode(v[k])
        end
        return '{' .. table.concat(out, ',') .. '}'
    end
    return 'null'
end

local function json_encode(v)
    if utils.format_json then
        local ok, res = pcall(utils.format_json, v)
        if ok and type(res) == 'string' then return res end
    end
    return fallback_json_encode(v)
end

local function utf8_encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function fallback_json_decode(text)
    local pos = 1
    local function skip()
        while true do
            local c = text:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then pos = pos + 1 else break end
        end
    end
    local parse_value
    local function parse_string()
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = text:sub(pos, pos)
            if c == '"' then pos = pos + 1 return table.concat(out) end
            if c == '\\' then
                local e = text:sub(pos + 1, pos + 1)
                if e == 'n' then out[#out + 1] = '\n' pos = pos + 2
                elseif e == 't' then out[#out + 1] = '\t' pos = pos + 2
                elseif e == 'r' then out[#out + 1] = '\r' pos = pos + 2
                elseif e == 'b' then out[#out + 1] = '\b' pos = pos + 2
                elseif e == 'f' then out[#out + 1] = '\f' pos = pos + 2
                elseif e == 'u' then
                    local hex = text:sub(pos + 2, pos + 5)
                    local cp = tonumber(hex, 16) or 63
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF then
                        local hex2 = text:sub(pos, pos + 1)
                        if hex2 == '\\u' then
                            local lo = tonumber(text:sub(pos + 2, pos + 5), 16) or 0
                            if lo >= 0xDC00 and lo <= 0xDFFF then
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                                pos = pos + 6
                            end
                        end
                    end
                    out[#out + 1] = utf8_encode(cp)
                else out[#out + 1] = e pos = pos + 2 end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error('字符串未闭合')
    end
    parse_value = function()
        skip()
        local c = text:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skip()
            if text:sub(pos, pos) == '}' then pos = pos + 1 return obj end
            while true do
                skip()
                local key = parse_string()
                skip()
                if text:sub(pos, pos) ~= ':' then error('缺少冒号') end
                pos = pos + 1
                obj[key] = parse_value()
                skip()
                local d = text:sub(pos, pos)
                if d == ',' then pos = pos + 1
                elseif d == '}' then pos = pos + 1 break
                else error('对象语法错误') end
            end
            return obj
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skip()
            if text:sub(pos, pos) == ']' then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = parse_value()
                skip()
                local d = text:sub(pos, pos)
                if d == ',' then pos = pos + 1
                elseif d == ']' then pos = pos + 1 break
                else error('数组语法错误') end
            end
            return arr
        elseif c == '"' then
            return parse_string()
        elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
        else
            local num = text:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
            if not num or num == '' then error('无法解析的值 @' .. pos) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local ok, res = pcall(parse_value)
    if not ok then return nil, res end
    return res
end

local function json_decode(text)
    if utils.parse_json then
        local ok, res = pcall(utils.parse_json, text)
        if ok and res ~= nil then return res end
    end
    return fallback_json_decode(text)
end

----------------------------------------------------------------------
-- 标记文件解析（与 Pr 侧 extension/client/main.js 同规则）
----------------------------------------------------------------------

local KEY_TIME = '^(time|tc|timecode|start|in|timestamp|时间|时间码|时间戳|起始)$'
local KEY_NAME = '^(name|title|label|名称|标题|标签)$'
local KEY_DESC = '^(comment|comments|desc|description|content|text|note|notes|内容|备注|描述|正文|说明)$'
local KEY_COLOR = '^(color|colour|颜色)$'

local function detect_delimiter(head)
    if head:find('\t', 1, true) then return '\t' end
    local sc = select(2, head:gsub(';', ''))
    local cc = select(2, head:gsub(',', ''))
    if sc > cc then return ';' end
    return ','
end

local function parse_csv(text)
    local first = text:match('^[^\r\n]*') or ''
    local delim = detect_delimiter(first)
    local rows, row, cur, in_q, i = {}, {}, {}, false, 1
    local n = #text
    while i <= n do
        local c = text:sub(i, i)
        if in_q then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then cur[#cur + 1] = '"' i = i + 1
                else in_q = false end
            else cur[#cur + 1] = c end
        elseif c == '"' then in_q = true
        elseif c == delim then row[#row + 1] = table.concat(cur) cur = {}
        elseif c == '\n' then
            row[#row + 1] = table.concat(cur) cur = {}
            rows[#rows + 1] = row row = {}
        elseif c ~= '\r' then cur[#cur + 1] = c end
        i = i + 1
    end
    if #cur > 0 or #row > 0 then
        row[#row + 1] = table.concat(cur)
        rows[#rows + 1] = row
    end
    local out = {}
    for _, r in ipairs(rows) do
        local has = false
        for _, v in ipairs(r) do if trim(v) ~= '' then has = true break end end
        if has then out[#out + 1] = r end
    end
    return out
end

local function map_columns(header)
    local m = { time = 1, name = -1, desc = -1, color = -1 }
    for i, h in ipairs(header) do
        h = trim(h)
        if h:match(KEY_TIME) then m.time = i
        elseif h:match(KEY_NAME) then m.name = i
        elseif h:match(KEY_DESC) then m.desc = i
        elseif h:match(KEY_COLOR) then m.color = i end
    end
    return m
end

-- 颜色索引规范化：规范 §4 要求写入方只产出 0..7 的整数。
-- 注意 NaN：LuaJIT 的 tonumber('NaN') 得到 NaN，而 NaN 与任何数比较都为 false，
-- 所以必须用「肯定式」判断（n == n 且落在区间内），否则 nan 会一路写进 CSV/JSON。
local function normalize_color(v)
    if v == nil or trim(v) == '' then return 0 end          -- 缺列/空值：静默按 0
    local n = tonumber(v)
    if not n or n ~= n then                                  -- 非数字 / NaN
        msg.warn(string.format('颜色值 %q 不是数字，已按 0 处理', tostring(v)))
        return 0
    end
    n = math.floor(n)
    if not (n >= 0 and n <= 7) then
        msg.warn(string.format('颜色索引 %s 超出 0..7，已按 0 处理', tostring(v)))
        return 0
    end
    return n
end

-- 条目级跳过计数（规范 §6 读取方保证 1：跳过的条目必须告警，不能静默）
local skip_count = 0

local function rows_to_markers(rows, fps)
    if #rows == 0 then return {} end
    local header = rows[1]
    local looks_header = parse_time(header[1], fps) == nil
    local hit = false
    for _, h in ipairs(header) do
        h = trim(h)
        if h:match(KEY_TIME) or h:match(KEY_NAME) or h:match(KEY_DESC) then hit = true break end
    end
    local has_header = looks_header and hit
    local map = has_header and map_columns(header) or { time = 1, name = 2, desc = 3, color = 4 }
    local body = rows
    if has_header then
        body = {}
        for i = 2, #rows do body[#body + 1] = rows[i] end
    end
    local out = {}
    for _, r in ipairs(body) do
        local sec = parse_time(r[map.time], fps)
        if sec then
            out[#out + 1] = {
                t = sec,
                name = map.name > 0 and trim(r[map.name]) or '',
                comment = map.desc > 0 and trim(r[map.desc]) or '',
                color = normalize_color(map.color > 0 and trim(r[map.color]) or nil),
            }
        else
            skip_count = skip_count + 1
        end
    end
    return out
end

local function parse_srt(text)
    local out = {}
    local block = {}
    local function flush()
        if #block == 0 then return end
        local tline, tindex = nil, nil
        for i, line in ipairs(block) do
            if line:find('-->', 1, true) then tline, tindex = line, i break end
        end
        if tline then
            local start = trim(tline:match('^(.-)%-%->') or ''):gsub(',', '.')
            local p = {}
            for piece in start:gmatch('[^:]+') do p[#p + 1] = tonumber(trim(piece)) end
            if #p == 3 and p[1] and p[2] and p[3] then
                local lines = {}
                for i = tindex + 1, #block do
                    if trim(block[i]) ~= '' then lines[#lines + 1] = trim(block[i]) end
                end
                out[#out + 1] = {
                    t = p[1] * 3600 + p[2] * 60 + p[3],
                    name = '',
                    comment = table.concat(lines, ' '),
                    color = 0,
                }
            end
        end
        block = {}
    end
    for line in (text:gsub('\r\n', '\n') .. '\n\n'):gmatch('([^\n]*)\n') do
        if trim(line) == '' then flush() else block[#block + 1] = line end
    end
    return out
end

local function parse_json_markers(text, fps)
    local data = json_decode(text)
    if type(data) ~= 'table' then return {} end
    -- 规范 §6：读到形状不对的 JSON 只能「这一份没解析出东西」，绝不能让异常冲出去
    -- （mpv 对未捕获的脚本错误是直接销毁脚本客户端：键位注销、消息全失效）
    if type(data.markers) == 'table' then data = data.markers
    elseif type(data.data) == 'table' then data = data.data
    elseif data.markers ~= nil or data.data ~= nil then
        msg.warn('JSON 里的 markers/data 不是数组，已忽略')
        return {}
    end
    if type(data) ~= 'table' then return {} end
    -- 裸对象（非数组）也容忍：当作单条标记
    if data.time ~= nil or data.t ~= nil or data.tc ~= nil then data = { data } end
    local out = {}
    for _, item in ipairs(data) do
        if type(item) == 'table' then
            local t = item.time
            if t == nil then t = item.tc end
            if t == nil then t = item.start end
            if t == nil then t = item.startTime end      -- 与 Pr 面板的兼容链保持一致
            if t == nil then t = item.t end
            local sec = parse_time(t, fps)
            if sec then
                out[#out + 1] = {
                    t = sec,
                    name = trim(item.name or item.title or item.label or ''),
                    comment = trim(item.comment or item.comments or item.desc or item.description
                        or item.text or item.note or ''),
                    color = normalize_color(item.color or item.colour),
                }
            else
                skip_count = skip_count + 1
            end
        else
            skip_count = skip_count + 1
        end
    end
    return out
end

-- 统一入口：JSON / SRT / CSV(TSV)。
-- 最外层再包一层 pcall：任何解析异常都退化成「0 条标记 + 告警」，不影响插件继续工作。
-- 返回 markers, skipped（skipped = 被跳过的坏条目数）
local function parse_marker_file(text, fps)
    skip_count = 0
    local ok, result = pcall(function()
        text = trim(text)
        if text == '' then return {} end
        local first = text:sub(1, 1)
        if first == '[' or first == '{' then
            return parse_json_markers(text, fps)
        end
        if text:match('^%d+%s*\r?\n%s*%d%d?:%d%d:%d%d[,%.]%d+%s*%-%->') then
            return parse_srt(text)
        end
        return rows_to_markers(parse_csv(text), fps)
    end)
    if not ok then
        msg.warn('标记文件解析失败，已忽略：' .. tostring(result))
        return {}, skip_count
    end
    return result or {}, skip_count
end

----------------------------------------------------------------------
-- 状态存取
----------------------------------------------------------------------

-- ①共享颜色表：读 portable_config/marker-colors.json 覆盖内置表。
-- 只在**整表完整**（8 条、索引 0..7、hex 合法）时才采用，否则保留内置回退 ——
-- 宁可用旧色，也不能因为一个坏文件让插件半死不活。
local COLOR_TABLE_STATE = '内置回退表'
local function hex_to_rgb(h)
    if type(h) ~= 'string' then return nil end
    h = h:gsub('^#', '')
    if #h ~= 6 or h:match('^%x%x%x%x%x%x$') == nil then return nil end
    return { tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16) }
end
local function apply_shared_colors()
    local path = expand('~~home/marker-colors.json')
    if not path or not file_exists(path) then
        COLOR_TABLE_STATE = '内置回退表（共享表不存在）'
        return
    end
    local text = read_file(path)
    if not text then COLOR_TABLE_STATE = '内置回退表（共享表读不出）' return end
    local ok, d = pcall(json_decode, text)
    if not ok or type(d) ~= 'table' or type(d.colors) ~= 'table' then
        COLOR_TABLE_STATE = '内置回退表（共享表解析失败）'
        return
    end
    local fresh = {}
    for _, c in ipairs(d.colors) do
        local i = tonumber(c.index)
        local rgb = hex_to_rgb(c.hex)
        if not i or i < 0 or i > 7 or type(c.name) ~= 'string' or c.name == '' or not rgb then
            COLOR_TABLE_STATE = '内置回退表（共享表有条目不合法）'
            return
        end
        fresh[i] = { name = c.name, rgb = rgb }
    end
    for i = 0, 7 do
        if not fresh[i] then COLOR_TABLE_STATE = '内置回退表（共享表缺索引 ' .. i .. '）' return end
    end
    COLORS = fresh
    COLOR_TABLE_STATE = '共享表 ' .. path
end

local function sort_markers()
    table.sort(S.markers, function(a, b) return a.t < b.t end)
end

local function ensure_dir(dir)
    if not dir or dir == '' then return end
    local info = utils.file_info and utils.file_info(dir) or nil
    if info and info.is_dir then return end
    local ok, _, code = os.execute('mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul')
    -- Lua 5.1 返回数字（0 = 成功），5.2+ 返回 true/nil
    local failed = (ok == false) or (type(ok) == 'number' and ok ~= 0)
    if failed and code ~= nil then
        msg.warn(string.format('建目录可能失败（code=%s）：%s', tostring(code), dir))
    end
end

-- 绝对路径判定：mpv 的 expand-path 在 config-dir 不可用时会把 ~~home/xxx 变成相对路径，
-- 那样插件就会在「进程当前目录」里造目录（--no-config 场景实测过）。
local function is_absolute(path)
    if not path or path == '' then return false end
    if path:match('^%a:[/\\]') then return true end        -- C:\ 或 C:/
    if path:match('^[/\\][/\\]') then return true end       -- UNC \\server\share
    if path:match('^/') then return true end                -- POSIX
    return false
end

-- 目录候选：展开后必须是绝对路径，否则依次退回 TEMP / 当前目录
local function resolve_dir(spec)
    local cand = {}
    if spec and spec ~= '' then cand[#cand + 1] = expand(spec) end
    cand[#cand + 1] = expand('~~home/markers')
    local tmp = os.getenv('TEMP') or os.getenv('TMP')
    if tmp and tmp ~= '' then cand[#cand + 1] = tmp .. '\\source-markers' end
    for _, c in ipairs(cand) do
        if is_absolute(c) then return c end
    end
    return nil
end

-- Windows 文件名净化（流输入的 filename 可能含 : 等非法字符，也可能是 CON/NUL 这类保留设备名）
local RESERVED = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
    COM6 = true, COM7 = true, COM8 = true, COM9 = true,
    LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
    LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}
local function safe_filename(name)
    name = tostring(name or 'stream')
    name = name:gsub('[\\/:*?"<>|]', '_')
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    name = name:gsub('%.+$', '')                      -- Windows 不允许以点结尾
    if name == '' then name = 'stream' end
    local stem = name:match('^([^%.]+)') or name
    if RESERVED[stem:upper()] then name = name .. '_' end
    if #name > 120 then name = name:sub(1, 120) end    -- 给目录与后缀留余量
    return name
end

-- 统一的标记文档结构（规范 v1 §2）：键名与 Pr 面板认的 JSON 一致，
-- 因此导出文件与 sidecar 都可以直接拿去 Pr 里导入。
-- ── 出入点（第 7 条）状态与读数 ────────────────────────────────────────
-- 一律用【帧号】存：r31 的教训是"毫秒值落在帧间会造成差一帧"，出入点必须帧对齐。
-- ⚠ 这三样必须定义在 export_doc **之前**：Lua 的 local 只在其声明之后可见，
--   放到文件后段会让 export_doc 里的引用变成全局 nil（r16 那次前向引用同款坑）。
local IN_FRAME, OUT_FRAME = nil, nil
local function frame_seconds(f)
    local fps = get_fps() or 25
    return f / fps
end
local function inout_summary()
    if not IN_FRAME and not OUT_FRAME then return '未设出入点' end
    local fps = get_fps() or 25
    local a = IN_FRAME and to_timecode(frame_seconds(IN_FRAME), fps) or '—'
    local b = OUT_FRAME and to_timecode(frame_seconds(OUT_FRAME), fps) or '—'
    local extra = ''
    if IN_FRAME and OUT_FRAME and OUT_FRAME > IN_FRAME then
        extra = string.format('（%d 帧 / %.2fs）', OUT_FRAME - IN_FRAME, (OUT_FRAME - IN_FRAME) / fps)
    end
    return string.format('入 %s → 出 %s%s', a, b, extra)
end

local function export_doc()
    local fps = get_fps()
    local markers = {}
    for _, m in ipairs(S.markers) do
        -- name 列保留但恒为空：Pr 面板只认 comment 列，name 列一律忽略。
        -- 这里刻意不沿用 m.name —— 旧 sidecar / 外部文件里带进来的 M01 不会再被写回去。
        markers[#markers + 1] = {
            time = tonumber(string.format('%.3f', m.t)),
            tc = to_timecode(m.t, fps or 25),
            name = '',
            comment = m.comment or '',
            color = normalize_color(m.color),
        }
    end
    local doc = {
        format = 'source-markers',
        version = 1,
        created = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        source = {
            file = mp.get_property('path') or '',
            fps = fps,
            durationSec = mp.get_property_number('duration'),
            timeFormat = o.time_format,
        },
        markers = markers,
    }
    -- 第 7 条：出入点写成【可选顶层字段 inout】（契约 §7：新增可选字段 = 仍是 v1；
    -- 契约要求读取方忽略未知字段 ⇒ 老读取方不受影响）。
    -- 只在设过至少一个端点时才写；未设的端点直接省略（Lua 的 nil 不入表）——
    -- 读取方对"字段缺失 / 端点缺失 / 端点为 null"都应视为未设。
    if IN_FRAME or OUT_FRAME then
        local io_doc = {}
        if IN_FRAME then io_doc['in'] = tonumber(string.format('%.3f', frame_seconds(IN_FRAME))) end
        if OUT_FRAME then io_doc.out = tonumber(string.format('%.3f', frame_seconds(OUT_FRAME))) end
        doc.inout = io_doc
    end
    return doc
end

-- 把文件设为隐藏（Windows）：防止新手误删/误改自动保存的 sidecar。
-- 非 Windows 或 attrib 不可用时静默跳过；os.execute 的返回值在 Lua 5.1/5.2 里不一致，
-- 所以这里只在真的看到失败码时记一条 debug 日志。
local function hide_file(path)
    if not o.hide_sidecar or not path or path == '' then return end
    if package.config:sub(1, 1) ~= '\\' then return end      -- 仅 Windows
    local ok = os.execute('attrib +h "' .. path .. '" 2>nul')
    if ok == false then msg.warn('设置隐藏属性失败: ' .. tostring(path)) end
end

local function sidecar_path()
    S.sidecar = nil
    local path = mp.get_property('path')
    if is_local_file(path) then
        local dir = dir_of(path) or '.'
        S.sidecar = dir .. '\\' .. base_of(path) .. '.mpv-autosave.json'
        return S.sidecar
    end
    if path and path ~= '' then
        local dir = resolve_dir(o.dir)
        if not dir then
            msg.warn('找不到可写的 sidecar 目录，已跳过 sidecar')
            return nil
        end
        S.sidecar = dir .. '\\' .. safe_filename(base_of(mp.get_property('filename') or 'stream')) .. '.mpv-autosave.json'
        return S.sidecar
    end
    return nil
end

local function save_sidecar()
    if not o.sidecar then return end
    local path = sidecar_path()
    if not path then return end
    ensure_dir(dir_of(path))
    local ok, err = write_file_atomic(path, json_encode(export_doc()))
    if not ok then
        msg.warn('sidecar 保存失败: ' .. tostring(err))
    else
        hide_file(path)      -- 设成隐藏，防新手误删/误改
    end
end

-- 面板/mpv 导出出来的标记文件（<素材名>_markers.json）。
-- 只认 sidecar 的话，Pr 面板导出之后 mpv 打开同一个素材是看不到的（用户实测反馈）。
local function exported_json_path()
    local p = mp.get_property('path')
    if not is_local_file(p) then return nil end
    return (dir_of(p) or '.') .. '\\' .. base_of(p) .. '_markers.json'
end
local function file_mtime(path)
    local info = utils.file_info and utils.file_info(path) or nil
    return info and info.mtime or nil
end

-- 选要载入的那个文件：sidecar 优先；若导出的标记文件存在且【比 sidecar 新】，则以它为准
-- （谁后写谁算数 —— 这样"Pr 导出 → mpv 打开"就能看到 Pr 的版本）。
-- 旧版 sidecar 名字（按使用顺序：r10 的方括号名 → 更早的 .marks.json）。
-- 只用来兜底读一次：读到了就照常用，下次保存会写到新名字下（用户不会因为改名丢标记）。
local LEGACY_SIDECAR_SUFFIXES = { '.marks[mpv-autosave].json', '.marks.json' }
local function legacy_sidecar_path()
    local p = mp.get_property('path')
    if not is_local_file(p) then return nil end
    local stem = (dir_of(p) or '.') .. '\\' .. base_of(p)
    for _, suf in ipairs(LEGACY_SIDECAR_SUFFIXES) do
        if file_exists(stem .. suf) then return stem .. suf end
    end
    return nil
end

local function pick_marker_file()
    local side, exp = sidecar_path(), exported_json_path()
    local has_side = side and file_exists(side)
    local has_exp = exp and file_exists(exp)
    if has_side and has_exp then
        local ms, me = file_mtime(side), file_mtime(exp)
        if ms and me and me > ms then return exp, 'export' end
        return side, 'sidecar'
    end
    if has_side then return side, 'sidecar' end
    if has_exp then return exp, 'export' end
    local leg = legacy_sidecar_path()
    if leg and file_exists(leg) then return leg, 'legacy' end
    return nil, nil
end

local function load_sidecar()
    S.markers = {}
    -- show_list 不在这里重置：它由界面状态文件持久化（见 load_ui_state），
    -- 否则每次换素材都会把「显示列表」的选择抹掉。
    update_overlay()
    if not o.sidecar then return end          -- sidecar=no 时既不写也不读
    local path, tag = pick_marker_file()
    if path then
        local text = read_file(path)
        local markers, skipped = {}, 0
        if text then markers, skipped = parse_marker_file(text, get_fps()) end
        S.markers = markers
        sort_markers()
        if skipped > 0 then
            msg.warn(string.format('标记文件里有 %d 条无法解析的标记，已跳过', skipped))
            notify(string.format('跳过 %d 条坏标记', skipped))
        end
        local tag_text = (tag == 'export') and '（来自导出文件）'
            or ((tag == 'legacy') and '（旧版 sidecar，之后会写到新名字）' or '')
        log('已载入 %d 个标记：%s%s', #S.markers, path, tag_text)
        if tag ~= 'sidecar' then
            -- 来源不是新名 sidecar（旧名 sidecar 或导出文件）→ 顺手把当前内容落到新名。
            -- 这样下次打开就直接用新名；旧文件/导出文件都原样留着，不删。
            save_sidecar()
            log('已把当前标记落到新名字：%s（来源：%s）', sidecar_path() or '?', path)
        end
        if #S.markers > 0 then
            notify(string.format('已载入 %d 个标记', #S.markers))
        end
    end
    update_overlay()
end

----------------------------------------------------------------------
-- OSD 覆盖层（标记列表）
----------------------------------------------------------------------

local function ass_escape(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}')
    s = s:gsub('[\r\n]+', ' ')
    return s
end

function update_overlay()
    if not o.overlay then return end
    if not S.overlay then
        if mp.create_osd_overlay then
            S.overlay = mp.create_osd_overlay('ass-events')
        else
            S.overlay = {
                data = '', res_x = 0, res_y = 0,
                update = function(self) mp.set_osd_ass(self.res_x, self.res_y, self.data) end,
                remove = function() mp.set_osd_ass(0, 0, '') end,
            }
        end
    end
    if not S.show_list or #S.markers == 0 then
        S.overlay.data = ''
        S.overlay:update()
        return
    end

    -- 坐标系：ass-events 的 res_x/res_y 就是 PlayRes，取当前 OSD 尺寸才能让 \pos 落在可见区域内
    local w, h = 0, 0
    if mp.get_osd_size then
        local ow, oh = mp.get_osd_size()
        w, h = tonumber(ow) or 0, tonumber(oh) or 0
    end
    if w <= 0 then w = 1280 end
    if h <= 0 then h = 720 end
    S.overlay.res_x = w
    S.overlay.res_y = h

    local size = tonumber(o.overlay_size) or 22
    local x = tonumber(o.overlay_x) or 40
    local y0 = tonumber(o.overlay_y) or 50
    local line_h = math.floor(size * 1.35)
    local fps = get_fps() or 25
    local limit = math.min(#S.markers, math.max(1, tonumber(o.overlay_limit) or 18))
    -- 小窗口时自动缩小行距，尽量都塞得下
    if y0 + limit * line_h > h then
        local avail = math.max(1, h - y0 - line_h)
        line_h = math.max(math.floor(size * 0.9), math.floor(avail / limit))
    end

    local head = mp.get_property_number('time-pos') or 0
    local lines = {}
    for i = 1, limit do
        local m = S.markers[i]
        local desc = m.comment
        -- 播放头正落在某个标记附近时给它加个标记符号
        local flag = (math.abs(m.t - head) <= (1 / fps) * 0.51) and '  <' or ''
        lines[#lines + 1] = string.format(
            '{\\an7\\pos(%d,%d)\\fs%d\\bord2\\shad0\\1c%s}%d  %s  %s%s',
            x, y0 + (i - 1) * line_h, size, ass_color(m.color),
            i, to_timecode(m.t, fps), ass_escape(desc), flag)
    end
    if #S.markers > limit then
        lines[#lines + 1] = string.format('{\\an7\\pos(%d,%d)\\fs%d\\1c&HFFFFFF&}... 共 %d 个标记（Ctrl+e 导出）',
            x, y0 + limit * line_h, size, #S.markers)
    end
    -- ass-events：每行会被当成一个 Dialogue 事件的 Text，不能带 [Script Info]/[Events] 头
    S.overlay.data = table.concat(lines, '\n')
    S.overlay:update()
end

-- 前向声明：下面这两件事定义在文件后段（Lua 的 local 必须先声明后使用）
local save_ui_state = nil        -- 界面状态持久化（定义在文件末尾附近）
local redraw_ui      = nil        -- 面板 / 帮助浮窗重绘（定义在按钮面板那一段之后）

local function toggle_list()
    S.show_list = not S.show_list
    update_overlay()
    if save_ui_state then save_ui_state() end
    notify(S.show_list and (string.format('标记列表：%d 条', #S.markers)) or '已隐藏标记列表')
end

----------------------------------------------------------------------
-- 标记操作
----------------------------------------------------------------------

local function head_time()
    return mp.get_property_number('time-pos')
end

-- 找离播放头最近的标记，但【只认 window 秒以内的】。
-- 4(b) 修复：原先不限定范围 → 会一路搜到全局最近的标记，把很远的标记删掉/改掉（用户实测踩到）。
-- 默认 1 秒（可用 script-opts=source-markers-nearest_window=秒 改）。
local NEAREST_WINDOW = tonumber(o.nearest_window) or 1.0
local function nearest_index(window)
    local head = head_time()
    if not head or #S.markers == 0 then return nil end
    window = window or NEAREST_WINDOW
    local idx, best = nil, nil
    for i, m in ipairs(S.markers) do
        local d = math.abs(m.t - head)
        if d <= window and (not best or d < best) then idx, best = i, d end
    end
    return idx
end

-- 同一帧不重复打标记：Pr 一个帧位只有一条标记。
-- 用"帧号"而不是秒来比较，避免浮点误差；帧号取离它最近的整帧。
local function frame_of(t, fps)
    if not t then return nil end
    fps = fps or get_fps() or 25
    if fps <= 0 then return nil end
    return math.floor(t * fps + 0.5)
end


local function set_in_point()
    local t = head_time()
    if not t then notify('没有正在播放的文件') return end
    IN_FRAME = frame_of(t)
    local cleared = ''
    if OUT_FRAME and OUT_FRAME <= IN_FRAME then OUT_FRAME = nil; cleared = '（原出点已清）' end
    notify('设入点：' .. inout_summary() .. cleared)
    log('设置入点：帧 %d t=%.3f%s', IN_FRAME, frame_seconds(IN_FRAME), cleared)
    -- 出入点变了必须**立刻重绘**：暂停时 time-pos 不再变化，否则控制栏的"转到入/出点"
    -- 要等到下一次播放（按 Space）才会由 time-pos 兜底重绘（用户实测反馈）
    if redraw_ui then redraw_ui() end
end
local function set_out_point()
    local t = head_time()
    if not t then notify('没有正在播放的文件') return end
    OUT_FRAME = frame_of(t)
    local cleared = ''
    if IN_FRAME and OUT_FRAME <= IN_FRAME then IN_FRAME = nil; cleared = '（原入点已清）' end
    notify('设出点：' .. inout_summary() .. cleared)
    log('设置出点：帧 %d t=%.3f%s', OUT_FRAME, frame_seconds(OUT_FRAME), cleared)
    if redraw_ui then redraw_ui() end
end
-- 区间武装：Enter 从入点播放时置位；到出点自动解除（解除后 Space 可自由续播）。
-- 「区间不消失」= 出入点本身一直保留；武装只是一个一次性的播放约束。
local RANGE_ARMED = false

local function clear_inout()
    IN_FRAME, OUT_FRAME = nil, nil
    notify('已清除出入点')
    log('已清除出入点')
    if redraw_ui then redraw_ui() end
end

local function marker_at_same_frame(t)
    local f = frame_of(t)
    if f == nil then return nil end
    for i, m in ipairs(S.markers) do
        if frame_of(m.t) == f then return i end
    end
    return nil
end

-- 用户输入一律作为「正文」写进 comment 列，name 列留空。
-- Pr 面板的标记名只取「备注/comment 列」、name 列整列忽略，所以这里不生成任何占位名。
local function add_marker(comment)
    local t = head_time()
    if not t then
        notify('没有正在播放的文件')
        return
    end
    local dup = marker_at_same_frame(t)
    if dup then
        local text = comment and trim(comment) or ''
        if text ~= '' then
            S.markers[dup].comment = text
            save_sidecar()
            if S.show_list then update_overlay() end
            notify(string.format('此处已有标记，已更新正文：%s', text))
            log('同帧更新正文: t=%.3f comment=%s', S.markers[dup].t, text)
        else
            notify(string.format('此处已有标记（%s，同一帧不重复打）',
                to_timecode(S.markers[dup].t, get_fps() or 25)))
            log('同帧重复被忽略: t=%.3f', t)
        end
        return
    end
    local m = {
        t = t,
        name = '',                                -- name 列留空（Pr 只认 comment 列）
        comment = comment and trim(comment) or '',
        color = tonumber(S.color) or 0,
    }
    S.markers[#S.markers + 1] = m
    sort_markers()
    save_sidecar()
    if S.show_list then update_overlay() end
    notify(string.format('标记 %s  %s  %s', to_timecode(m.t, get_fps() or 25),
        color_name(m.color), m.comment))
    log('已加标记: t=%.3f color=%d name=%s comment=%s', m.t, m.color, m.name, m.comment)
end

local function set_color(idx)
    idx = tonumber(idx)
    if not idx or not COLORS[idx] then
        notify('颜色索引必须是 0..7')
        return
    end
    S.color = idx
    if redraw_ui then redraw_ui() end          -- 立刻重绘面板/帮助，不必等鼠标移出面板
    notify(string.format('当前颜色：%d %s', idx, color_name(idx)))
end

-- 「跳不动」的根因（真机取证，见改动说明）：
--   面板导出的标记时间是毫秒值，常常落在两帧之间（例：1.mp4 的 0.633 秒，30.000473fps，
--   0.633×30.000473 = 18.99 帧）。帧精确 seek 会落到"第一个 pts >= 目标"的帧 ⇒ 落在【后一帧】
--   ⇒ 播放头比标记晚一帧 ⇒ 反方向的 step_marker 会把同一个标记再选中一次，表现为"那个方向跳不动"。
-- 所以跳转前先把目标回退半帧：这样"第一个 pts >= 目标-半帧"必定就是标记所在的那一帧。
local function seek_to(t)
    local fps = get_fps()
    if fps and fps > 0 and t and t > 0 then
        t = math.max(0, t - 0.5 / fps)
    end
    if o.hr_seek then
        -- 尊重用户的 mpv.conf：用户显式写了 hr-seek=no 就不要覆盖
        if mp.get_property('hr-seek') ~= 'no' then mp.set_property('hr-seek', 'yes') end
        mp.commandv('seek', tostring(t), 'absolute+exact')
    else
        -- 显式要求关键帧跳：mpv 的 absolute 默认就是精确的，必须加 keyframes 才退化
        mp.commandv('seek', tostring(t), 'absolute+keyframes')
    end
end

local function goto_marker(idx)
    idx = tonumber(idx)
    if not idx or not S.markers[idx] then
        notify('没有这个序号的标记')
        return
    end
    seek_to(S.markers[idx].t)
    notify(string.format('跳到 %d/%d  %s', idx, #S.markers, to_timecode(S.markers[idx].t, get_fps() or 25)))
    -- 同一件事也写进日志：跳转类问题的排查必须能看出"目标序号有没有前进"
    --（只发 notify 的话，日志里只剩"按键被路由了"，等于没证据 —— 本会话为此多绕了两轮）。
    log('跳到 %d/%d：t=%.3f（跳前播放头=%.3f）', idx, #S.markers, S.markers[idx].t, head_time() or -1)
end

local function step_marker(delta)
    if #S.markers == 0 then
        notify(string.format('附近 %g 秒内没有标记（当前共 %d 条）', NEAREST_WINDOW, #S.markers))
        return
    end
    local head = head_time() or 0
    -- 用【帧号】而不是秒来比较：跳转落点与标记时间本身就差着不到一帧（面板导出的毫秒值
    -- 多半落在帧间），用秒比会把"同一条标记"判成"还在前面/后面" ⇒ 那个方向永远跳不动。
    local hf = frame_of(head)
    local target = nil
    if delta > 0 then
        for i, m in ipairs(S.markers) do
            if not hf or (frame_of(m.t) or -1) > hf then target = i break end
        end
        if not target then target = #S.markers end
        log('next 计算：播放头=%.3f（帧 %s）→ 目标序号=%d（共 %d 条）', head, tostring(hf), target, #S.markers)
    else
        for i = #S.markers, 1, -1 do
            if not hf or (frame_of(S.markers[i].t) or -1) < hf then target = i break end
        end
        if not target then target = 1 end
        log('prev 计算：播放头=%.3f（帧 %s）→ 目标序号=%d（共 %d 条）', head, tostring(hf), target, #S.markers)
    end
    goto_marker(target)
end

-- ── 第 7 条 步骤 3：区间播放（向 Pr 源监视器看齐）──────────────────────
--   Enter  → 播放头吸到入点并开始播，同时【武装】区间
--   到出点 → 自动暂停（再补一次精确 seek 保证停在出点上）+ 自动解除武装
--   解除后 → Space 正常续播且不再被区间拦住；出入点保留，再按 Enter 重新武装
-- 这里单开一个 time-pos 观察者（mpv 允许同属性多个观察者），不动原来那个兜底重绘。
local function range_tick()
    if not RANGE_ARMED then return end
    if not IN_FRAME or not OUT_FRAME then return end
    local fps = get_fps() or 25
    local outsec = frame_seconds(OUT_FRAME)
    local t = head_time()
    if not t or t < outsec then return end
    mp.set_property('pause', 'yes')
    seek_to(outsec)
    RANGE_ARMED = false
    notify('已到出点，暂停（区间保留：Space 继续 / Enter 重新开始）')
    log('到达出点，已暂停：t=%.3f 出点=%.3f（区间已解除）', t, outsec)
    if render_mode_badge then render_mode_badge() end
end
mp.observe_property('time-pos', 'number', function() range_tick() end)

local function play_from_in()
    if not IN_FRAME then
        notify('还没有入点：Shift+I 设入点 / Shift+O 设出点')
        log('从入点播放：还没有入点')
        return
    end
    local fps = get_fps() or 25
    local insec = frame_seconds(IN_FRAME)
    seek_to(insec)
    mp.set_property('pause', 'no')
    RANGE_ARMED = true
    local tail = OUT_FRAME and (' → ' .. to_timecode(frame_seconds(OUT_FRAME), fps))
                          or '（未设出点，不受限）'
    notify('从入点播放 ' .. to_timecode(insec, fps) .. tail)
    log('从入点播放：入点帧 %d t=%.3f ｜ 出点%s', IN_FRAME, insec,
        OUT_FRAME and ('帧 ' .. OUT_FRAME .. string.format(' t=%.3f', frame_seconds(OUT_FRAME))) or '未设（不受限）')
    if render_mode_badge then render_mode_badge() end
end

local function delete_nearest()
    local idx = nearest_index()
    if not idx then
        notify(string.format('附近 %g 秒内没有标记（当前共 %d 条）', NEAREST_WINDOW, #S.markers))
        return
    end
    local m = table.remove(S.markers, idx)
    save_sidecar()
    update_overlay()
    notify(string.format('已删除 %s', to_timecode(m.t, get_fps() or 25)))
    log('已删除标记: t=%.3f', m.t)
end

local function clear_markers()
    local n = #S.markers
    S.markers = {}
    save_sidecar()
    update_overlay()
    notify(string.format('已清空 %d 个标记', n))
end

local function edit_nearest(text)
    local idx = nearest_index()
    if not idx then
        notify(string.format('附近 %g 秒内没有标记（当前共 %d 条）', NEAREST_WINDOW, #S.markers))
        return
    end
    local m = S.markers[idx]
    m.comment = trim(text or '')          -- 只改正文；name 列留空
    save_sidecar()
    update_overlay()
    notify(string.format('已更新 %s：%s', to_timecode(m.t, get_fps() or 25), m.comment))
end

----------------------------------------------------------------------
-- 输入框：mpv 内置（≥0.38）；老版本用内置 Python 兜底
----------------------------------------------------------------------

local PY_FALLBACK = [[
import sys
sys.stdout.reconfigure(encoding="utf-8")
import tkinter as tk
prompt = sys.argv[1] if len(sys.argv) > 1 else ""
default = sys.argv[2] if len(sys.argv) > 2 else ""
root = tk.Tk()
root.title("Source Markers")
root.attributes("-topmost", True)
root.resizable(False, False)
tk.Label(root, text=prompt, anchor="w", justify="left", wraplength=520).pack(fill="x", padx=14, pady=(14, 4))
var = tk.StringVar(value=default)
entry = tk.Entry(root, textvariable=var, width=64)
entry.pack(padx=14, pady=4)
entry.focus_set()
entry.select_range(0, "end")
result = {"text": None}
def ok(*_):
    result["text"] = var.get()
    root.destroy()
def cancel(*_):
    root.destroy()
bar = tk.Frame(root)
bar.pack(pady=(4, 14))
tk.Button(bar, text="确定", width=10, command=ok).pack(side="left", padx=6)
tk.Button(bar, text="取消", width=10, command=cancel).pack(side="left", padx=6)
root.bind("<Return>", ok)
root.bind("<Escape>", cancel)
root.mainloop()
sys.stdout.write(result["text"] if result["text"] is not None else "")
]]

local function helper_path()
    if o.helper and o.helper ~= '' and file_exists(o.helper) then return o.helper end
    local dir = mp.get_script_directory and mp.get_script_directory() or nil
    if dir then
        local p = dir .. '\\ask_text.py'
        if file_exists(p) then return p end
    end
    -- 兜底脚本落点：TEMP（os.getenv 最可靠）。注意 mpv 的 ~~temp 不带斜杠时不会被展开，
    -- 而带斜杠在本机又解析为空串，所以这里不用它。
    local tmpdir = os.getenv('TEMP') or os.getenv('TMP')
    if not tmpdir or tmpdir == '' then
        msg.warn('取不到 TEMP 目录，无法写出兜底输入框脚本')
        return nil
    end
    local tmp = tmpdir .. '\\source_markers_ask_text.py'
    if read_file(tmp) ~= PY_FALLBACK then
        local ok, err = write_file_atomic(tmp, PY_FALLBACK)
        if not ok then
            msg.warn('写不出兜底输入框脚本：' .. tostring(err))
            return nil
        end
    end
    return tmp
end

-- 返回 true 表示已接管（回调可能异步触发）；false 表示无法弹出输入框
local function ask_text(prompt, default, callback)
    -- mpv 的 mp.input 会先 submit 再 closed（或只 closed），这里做一次性保护
    local answered = false
    local function deliver(text)
        if answered then return end
        answered = true
        callback(text)
    end
    if input then
        input.get({
            prompt = prompt,
            default_text = default or '',
            submit = function(text) deliver(text) end,
            closed = function() deliver(nil) end,
        })
        return true
    end
    local helper = helper_path()
    if not helper then
        notify('无法弹出输入框：' .. (o.python or 'python') .. ' 或 TEMP 不可用（可先用 Ctrl+m 打标记，再手工编辑 sidecar/CSV）')
        return false
    end
    local args = { o.python or 'python', helper, prompt or '', default or '' }
    mp.command_native_async({
        name = 'subprocess',
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        if answered then return end
        if success and res and res.stdout and trim(res.stdout) ~= '' then
            deliver(trim(res.stdout))
        else
            local err = res and res.stderr or ''
            msg.warn('输入框兜底失败: ' .. tostring(err))
            notify('无法弹出输入框（可改用 script-message 或 Ctrl+e 指定路径）')
            deliver(nil)
        end
    end)
    return true
end

----------------------------------------------------------------------
-- 导入 / 导出
----------------------------------------------------------------------

local function csv_field(s)
    s = tostring(s or '')
    if s:find('["\r\n,]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function build_csv()
    local lines = { 'time,name,comment,color' }
    for _, m in ipairs(S.markers) do
        lines[#lines + 1] = table.concat({
            time_field(m.t), '', csv_field(m.comment), tostring(normalize_color(m.color)),
        }, ',')
    end
    local body = table.concat(lines, '\r\n') .. '\r\n'
    -- 规范 v1 §1.1：写入方默认带 UTF-8 BOM（Excel 打开中文不乱码）；Pr 面板读取时会剥掉
    if o.csv_bom then body = '\239\187\191' .. body end
    return body
end

-- 默认导出名：<素材名>_markers.csv（**不带时间戳** → 每次导出覆盖，好找、不堆积）。
-- 需要"另存为迭代"时：Ctrl+Shift+E（始终带戳），或把 export_stamp 设成 yes（默认也带戳）。
local function default_export_path(stamp)
    if stamp == nil then stamp = (o.export_stamp == true) end
    local path = mp.get_property('path')
    local dir
    if is_local_file(path) then
        dir = dir_of(path)
    else
        dir = resolve_dir(o.dir)
    end
    if not dir then dir = os.getenv('TEMP') or '.' end
    local base = safe_filename(base_of(mp.get_property('filename') or 'markers'))
    if stamp then
        return string.format('%s\\%s_markers_%s.csv', dir, base, os.date('%Y%m%d-%H%M%S'))
    end
    return string.format('%s\\%s_markers.csv', dir, base)
end

local function export_to(path)
    if not path or trim(path) == '' then
        notify('导出已取消')
        return
    end
    path = trim(path)
    if not path:match('%.csv$') and not path:match('%.json$') then path = path .. '.csv' end
    if #S.markers == 0 then
        notify('还没有标记可导出')
        return
    end
    local csv_path = path:gsub('%.json$', '.csv')
    local json_path = path:gsub('%.csv$', '.json')
    ensure_dir(dir_of(csv_path))
    local ok1, err1 = write_file_atomic(csv_path, build_csv())
    if not ok1 then
        notify('导出失败：' .. tostring(err1))
        msg.error(string.format('导出失败: %s', tostring(err1)))
        return
    end
    local ok2 = write_file_atomic(json_path, json_encode(export_doc()))
    if ok2 and o.hide_export_json then hide_file(json_path) end   -- 默认隐藏，减少目录里的视觉重复
    S.last_export = csv_path
    notify(string.format('已导出 %d 个标记 → %s%s', #S.markers, csv_path,
        o.hide_export_json and '（同名 .json 已设为隐藏）' or ''))
    log('导出 CSV: %s (JSON: %s, ok=%s)', csv_path, json_path, tostring(ok2))
end

local function import_from(path)
    if not path or trim(path) == '' then
        notify('导入已取消')
        return
    end
    path = trim(path)
    local text = read_file(path)
    if not text then
        notify('读不到文件：' .. path)
        return
    end
    local markers, skipped = parse_marker_file(text, get_fps())
    if skipped > 0 then
        msg.warn(string.format('%s 里有 %d 条无法解析的标记，已跳过', path, skipped))
        notify(string.format('跳过 %d 条坏标记', skipped))
    end
    if #markers == 0 then
        notify('没有解析出标记，检查时间列/格式')
        return
    end
    if o.import_mode == 'append' then
        for _, m in ipairs(markers) do S.markers[#S.markers + 1] = m end
    else
        S.markers = markers
    end
    sort_markers()
    save_sidecar()
    if S.show_list then update_overlay() end
    notify(string.format('已导入 %d 个标记（%s）', #markers, o.import_mode == 'append' and '追加' or '替换'))
    log('已导入 %d 个标记自 %s', #markers, path)
end

----------------------------------------------------------------------
-- 界面：帮助浮窗 + 可点击的按钮面板
--
-- 一张动作表同时驱动三样东西：①快捷键注册 ②帮助浮窗内容 ③按钮面板，
-- 所以帮助里写的键位永远等于真正注册的键位，不会再出现"文档和实现对不上"。
----------------------------------------------------------------------

local SCRIPT_NAME = (mp.get_script_name and mp.get_script_name()) or 'source-markers'
local BIND_PREFIX = SCRIPT_NAME .. '/'

-- 动作表与处理函数表：先声明，后填充（帮助/面板/快捷键都读同一份）
local ACTIONS, HANDLERS = {}, {}

-- 第 9 条 r46：时间轴自己的三个键位（默认值；keys.conf 可改）。
-- 单独一张表，**不能进 ACTIONS** —— ACTIONS 同时驱动按钮面板与帮助，塞进去控制栏会多出按钮。
local TL_KEYS = {
    { name = 'tl-zoom-in',  key = 'Alt+=', label = '时间轴放大' },
    { name = 'tl-zoom-out', key = 'Alt+-', label = '时间轴缩小' },
    { name = 'tl-reset',    key = 'Alt+0', label = '时间轴回到整片' },
}

-- ── 第 5 条：键位覆盖表 ────────────────────────────────────────────────
-- 文件：portable_config/script-opts/source-markers-keys.conf
--   一行一条  动作名 = 按键      # 没写的用默认；写 none 表示禁用该键
-- 首次运行会自动生成一份"全注释的默认值清单"当模板。
local KEY_OVERRIDE = {}                     -- 动作名 -> 按键；false=禁用
local KEY_CHECK = { errors = {}, warns = {}, infos = {} }
local KEY_CONF_REL = 'script-opts/source-markers-keys.conf'

-- 注意：--no-config 等情况下 mp.get_property('config') 可能是垃圾值（实测返回 "no"），
-- 直接拼路径会把模板写到相对目录去 —— 所以写文件前必须校验路径。
-- 本脚本自己的目录：Lua 标准库最靠得住（debug.getinfo 的 source 就是 <config>/scripts/xxx.lua）。
-- 实测：mp.get_script_directory 与 mp.get_property('config') 在本机 mpv 上都拿不到值，
-- 所以三个来源依次尝试，并把结果全部打进日志（省得以后再猜）。
local function script_dir_guess()
    -- 直接在函数里取 level 1：包一层闭包会得到 "[C]"（本会话踩过）
    local src = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    if type(info) == 'table' and info.source then src = tostring(info.source) end
    local sd = (mp.get_script_directory and mp.get_script_directory()) or ''
    local cd1 = mp.get_property('config-dir') or ''
    local cd2 = mp.get_property('options/config-dir') or ''
    if not KEY_DIR_CACHE then
        msg.verbose('键位目录探测：source=%s | get_script_directory=%s | config-dir=%s | options/config-dir=%s', src, sd, cd1, cd2)
    end
    local from_src = src:gsub('^@', ''):match('^(.*)[\\/][^\\/]*$') or ''
    local cand = {}
    if from_src ~= '' then cand[#cand + 1] = from_src end
    if sd ~= '' then cand[#cand + 1] = sd end
    for _, c in ipairs(cand) do
        local up = c:gsub('[\\/]scripts[\\/]?$', '')
        if up ~= c and up ~= '' then return up end          -- <config>/scripts → <config>
    end
    for _, c in ipairs({ cd1, cd2 }) do
        if c ~= '' and (c:match('^%a:[\\/]') or c:match('^[\\/]')) then
            local up = c:gsub('[\\/]scripts[\\/]?$', '')
            return up
        end
    end
    return nil
end

local function key_conf_dir()
    -- 注意：不要用 file_exists 去验目录 —— 它内部是 io.open，在 Windows 上对目录会失败。
    -- 从脚本路径推出的上一级本身就是真实目录。
    local d = script_dir_guess()
    if d then return d end
    return nil
end
local function key_conf_read_path()
    if mp.find_config_file then
        local p = mp.find_config_file(KEY_CONF_REL)
        if p then return p end
    end
    local base = key_conf_dir()
    if base and file_exists(base .. '/' .. KEY_CONF_REL) then return base .. '/' .. KEY_CONF_REL end
    return nil
end
local function key_conf_write_path()
    local base = key_conf_dir()
    if not base then return nil end
    return base .. '/' .. KEY_CONF_REL
end

local function load_key_overrides()
    KEY_OVERRIDE = {}
    local path = key_conf_read_path()
    if not path then log('键位覆盖表：未找到（用默认键位）'); return end
    local text = read_file(path)
    if not text then log('键位覆盖表：读不出来，用默认键位', path); return end
    local n, bad = 0, 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local stripped = line:gsub('#.*$', '')
        local s = trim(stripped)
        if s ~= '' then
            local name, key = s:match('^([%w%-%._]+)%s*=%s*(.-)%s*$')
            if name then
                if key == '' or key:lower() == 'none' or key == '-' then
                    KEY_OVERRIDE[name] = false
                else
                    KEY_OVERRIDE[name] = key
                end
                n = n + 1
            else
                bad = bad + 1
                msg.warn('键位表这行看不懂（已忽略）：' .. line)
            end
        end
    end
    log('键位覆盖表：%s（%d 条生效，%d 行看不懂）', path, n, bad)
end

-- 取生效键位：nil=用默认；false → 返回 nil 表示禁用
local function eff_key(name, default)
    local v = KEY_OVERRIDE[name]
    if v == nil then return default end
    if v == false then return nil end
    return v
end

local function key_of(name)
    for _, a in ipairs(ACTIONS) do
        if a.name == name then return a.key end
    end
    return '?'
end

load_key_overrides()   -- 第 5 条：先读键位覆盖表，后面注册绑定时会用它
-- 第 8 条：OSD 样式。style = 'panel'（旧按钮面板）| 'prbar'（Pr 风格控制栏）。
-- panel / bar 是两个样式各自的「是否显示」；互斥由 ui_set_shown() 统一保证。
local UI = { help = false, panel = o.panel == true, hover = nil, hint_shown = false, mode = false,
             style = 'panel', bar = false }
local PANEL_BUTTONS = {}          -- 渲染后填充：{name,label,x,y,w,h,section}
local PRBAR_BUTTONS = {}          -- 第 8 条：控制栏按钮的命中框（渲染后填充）
local SIDE_PADDING = 40

local function new_overlay()
    if mp.create_osd_overlay then return mp.create_osd_overlay('ass-events') end
    return {
        data = '', res_x = 0, res_y = 0,
        update = function(self) mp.set_osd_ass(self.res_x, self.res_y, self.data) end,
    }
end
local overlay_help = new_overlay()
local overlay_panel = new_overlay()
local overlay_bar = new_overlay()          -- 第 8 条：Pr 风格控制栏
local overlay_tl = new_overlay()           -- 第 9 条：可缩放时间轴

local function osd_size()
    local w, h = 1280, 720
    if mp.get_osd_size then
        local ow, oh = mp.get_osd_size()
        w = tonumber(ow) or w
        h = tonumber(oh) or h
    end
    if w <= 0 then w = 1280 end
    if h <= 0 then h = 720 end
    return w, h
end

local function ui_font()
    local _, h = osd_size()
    return math.max(14, math.min(26, math.floor(h * 0.026 + 0.5)))
end

local function set_overlay(ov, lines, w, h)
    ov.res_x = w
    ov.res_y = h
    ov.data = lines and table.concat(lines, '\n') or ''
    ov:update()
end

-- ASS 画一个填充矩形（按钮底）
local function rect_line(x, y, w, h, rgb, alpha)
    local c = rgb or '&H2A2A2A&'
    return string.format(
        '{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c%s\\alpha&H%s&}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}',
        x, y, c, alpha or '30', w, w, h, h)
end

local function text_line(x, y, size, color, s, bold, outline_color, outline_size)
    return string.format('{\\an7\\pos(%d,%d)\\fs%d\\bord%d\\shad0\\1c%s\\3c%s%s}%s',
        x, y, size, outline_size or 2, color or '&HFFFFFF&', outline_color or '&H000000&',
        bold and '\\b1' or '', ass_escape(s))
end

-- 色块上的文字：按亮度选黑/白，并用反色描边，保证任何颜色上都看得清
local function swatch_colors(idx)
    local c = COLORS[idx] or COLORS[1]
    local r, g, b = c.rgb[1] / 255, c.rgb[2] / 255, c.rgb[3] / 255
    local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if lum > 0.6 then return '&H000000&', '&HFFFFFF&' end   -- 浅色块：黑字白边
    return '&HFFFFFF&', '&H000000&'                          -- 深色块：白字黑边
end

-- 中文/多字节字符按 2 个宽度估算（LuaJIT 没有 utf8 库，所以按字节判断 UTF-8 长度）
local function visual_width(s)
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 then
            n = n + 1
            i = i + 1
        else
            local len = 2
            if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 end
            n = n + 2
            i = i + len
        end
    end
    return n
end

-- 文本折行：先按显式 "\n" 切成段落，再按视觉宽度折（视觉宽度用上面的 visual_width 口径）。
-- 4(c) 修复：帮助里有些说明比面板框还宽（F10 那条最明显），原先一行画出去会被裁掉/溢出。
local function wrap_visual(s, max_units)
    local out = {}
    if max_units and max_units > 0 then
        for para in (s .. '\n'):gmatch('([^\n]*)\n') do
            local cur, curw, i = '', 0, 1
            while i <= #para do
                local b = para:byte(i)
                local len, w = 1, 1
                if b >= 0xF0 then len, w = 4, 2
                elseif b >= 0xE0 then len, w = 3, 2
                elseif b >= 0xC0 then len, w = 2, 2 end
                local ch = para:sub(i, i + len - 1)
                if curw + w > max_units and cur ~= '' then
                    out[#out + 1] = cur
                    cur, curw = ch, w
                else
                    cur = cur .. ch
                    curw = curw + w
                end
                i = i + len
            end
            if cur ~= '' then out[#out + 1] = cur end
        end
    else
        out[1] = s
    end
    if #out == 0 then out[1] = '' end
    return out
end
local function show_help(state)
    UI.help = (state == nil) and (not UI.help) or (state == true)
    if not UI.help then
        local w, h = osd_size()
        set_overlay(overlay_help, nil, w, h)
        return
    end
    local w, h = osd_size()
    local size = ui_font()
    local lh = math.floor(size * 1.5)
    local x = math.max(SIDE_PADDING, math.floor(w * 0.16))
    local y = math.max(SIDE_PADDING, math.floor(h * 0.08))
    local box_w = math.min(w - 2 * x, math.floor(size * 34))
    local col_x = x + math.floor(size * 8.2)
    -- 文本列能用的"视觉宽度单位"（1 单位≈size/2 像素；中文字算 2 单位）
    local text_units = math.max(8, math.floor(2 * (x - 12 + box_w - col_x) / size))
    local rows = {}
    for _, a in ipairs(ACTIONS) do
        if not a.compact then rows[#rows + 1] = a end     -- 颜色单独用一行汇总，列出 8 条太占地方
    end
    -- 第 9 条 r46：时间轴三个键也进帮助（不进 ACTIONS —— ACTIONS 同时驱动按钮面板，塞进去会多出按钮）
    for _, s in ipairs(TL_KEYS) do
        rows[#rows + 1] = { key = eff_key(s.name, s.key) or '（已禁用）', help = '时间轴：' .. s.label }
    end
    local wrapped, row_lines = {}, 0
    for ri, a in ipairs(rows) do
        wrapped[ri] = wrap_visual(a.help, text_units)
        row_lines = row_lines + #wrapped[ri]
    end
    -- 顶部两条静态说明也必须折行 —— 否则会顶出框宽被裁掉（用户上机实测反馈：这两行超出边界）
    local hints = {
        '鼠标党按 ' .. key_of('toggle-panel') .. ' 开 / 关 OSD，' .. key_of('switch-osd')
            .. ' 换样式（Pr 风格 = 控制栏 + 时间轴；老样式 = 按钮面板 + mpv 自带播放条）；两种都能点。',
        'Pr 风格控制栏按钮（左→右）：上一个标记 · 打标记 · 下一个标记 · 标记入点 · 标记出点 · 转到入点 · 后退一帧 · 播放/暂停 · 向前一帧 · 转到出点 · 截取当前帧',
        '时间轴：滚轮以播放头为轴缩放（Ctrl 更细、Shift 更粗），Alt+滚轮左右平移，Alt+0 回到整片。',
    }
    local hint_lines = {}
    for _, s in ipairs(hints) do
        for _, part in ipairs(wrap_visual(s, text_units)) do hint_lines[#hint_lines + 1] = part end
    end
    local conflict_note = (#KEY_CHECK.errors > 0 or #KEY_CHECK.warns > 0)
    local box_h = lh * (row_lines + #hint_lines + 3 + (conflict_note and 1 or 0)) + 16
    msg.verbose(string.format('帮助折行：文本列 %d 单位，共 %d 行（原先 %d 行）', text_units, row_lines, #rows))
    local lines = {
        rect_line(x - 12, y - 12, box_w, box_h, '&H1C1C1C&', '20'),
        text_line(x, y, size + 2, '&H4DE0FF&', 'Source Markers — 快捷键帮助', true),
    }
    local cy = y + lh
    for _, part in ipairs(hint_lines) do
        lines[#lines + 1] = text_line(x, cy, size, '&HB0B0B0&', part)
        cy = cy + lh
    end
    for ri, a in ipairs(rows) do
        lines[#lines + 1] = text_line(x, cy, size, '&H4DE0FF&', string.format('%-10s', a.key))
        local parts = wrapped[ri] or { a.help }
        for pi, part in ipairs(parts) do
            lines[#lines + 1] = text_line(col_x, cy, size, '&HFFFFFF&', part)
            msg.verbose(string.format('帮助行 %s[%d/%d] 宽=%d：%s', a.key, pi, #parts, visual_width(part), part))
            if pi < #parts then cy = cy + lh end
        end
        cy = cy + lh
    end
    if conflict_note then
        lines[#lines + 1] = text_line(x, cy, size, '&HFF9090&',
            string.format('⚠ 键位：%d 处错误 / %d 处警告 —— script-message keys 看详情', #KEY_CHECK.errors, #KEY_CHECK.warns))
        cy = cy + lh
    end
    lines[#lines + 1] = text_line(x, cy, size, '&H4DE0FF&', string.format('%-10s', 'Ctrl+1..8'))
    lines[#lines + 1] = text_line(x + math.floor(size * 8.2), cy, size, '&HFFFFFF&',
        string.format('选择颜色 —— 当前是 %d（%s）', S.color, color_name(S.color)))
    cy = cy + lh
    lines[#lines + 1] = text_line(x, cy + 6, size, '&HB0B0B0&',
        '颜色索引：0 绿  1 红  2 紫  3 橙  4 黄  5 白  6 蓝  7 青（与 Premiere 标记色一致）')
    set_overlay(overlay_help, lines, w, h)
end

----------------------------------------------------------------------
-- 按钮面板（鼠标可点的 OSD 浮窗）
----------------------------------------------------------------------

local function panel_sections_off()
    for _, b in ipairs(PANEL_BUTTONS) do
        if b.section then
            mp.commandv('disable-section', b.section)
            mp.set_mouse_area(0, 0, 0, 0, b.section)
        end
    end
end

local function render_panel()
    local w, h = osd_size()
    if not UI.panel then
        panel_sections_off()
        PANEL_BUTTONS = {}
        set_overlay(overlay_panel, nil, w, h)
        return
    end

    local size = ui_font()
    local pad = math.max(6, math.floor(size * 0.4))
    local bh = size + 2 * pad                       -- 按钮高
    local gap = math.max(4, math.floor(size * 0.35))
    local x0 = math.max(SIDE_PADDING, tonumber(o.panel_x) or 40)
    -- 排列：标题行（含 帮助/关闭）→ 颜色行 → 两行功能按钮。
    -- 颜色行放在最上面：即使窗口很矮、面板贴近底部，颜色也最不容易被进度条挡住。
    local row_main, row_extra, color_row, row_title = {}, {}, {}, {}
    for _, a in ipairs(ACTIONS) do
        if a.color then color_row[#color_row + 1] = a
        elseif a.name == 'help' or a.name == 'toggle-panel' then row_title[#row_title + 1] = a
        elseif #row_main < 5 then row_main[#row_main + 1] = a
        else row_extra[#row_extra + 1] = a end
    end

    local title = string.format('Source Markers ｜ 颜色 %d %s ｜ %d 个标记',
        S.color, color_name(S.color), #S.markers)
    local title_w = math.floor(visual_width(title) * size * 0.56) + 3 * pad
    local color_w = #color_row * math.floor(size * 2.9) + (#color_row - 1) * gap
    local function row_w(list)
        local total = 0
        for _, a in ipairs(list) do
            total = total + math.floor(size * (visual_width(a.label) * 0.58 + 2.6)) + 2 * pad + gap
        end
        return total > 0 and total - gap or 0
    end
    local panel_w = math.max(title_w + row_w(row_title), color_w, row_w(row_main), row_w(row_extra)) + 2 * pad

    -- 竖向位置：默认自动抬到 mpv 进度条（OSC）上方
    local rows_n = 4
    local total_h = bh * rows_n + gap * (rows_n + 1) + 8
    local bottom_opt = tonumber(o.panel_bottom) or 0
    local margin = (bottom_opt > 0) and bottom_opt or math.max(90, math.floor(h * 0.20))
    local anchor = tostring(o.panel_anchor or 'bottom-left')
    local top, left
    if anchor == 'top-left' or anchor == 'top-right' then
        top = math.max(SIDE_PADDING, math.floor(h * 0.06))
        left = (anchor == 'top-right') and math.max(SIDE_PADDING, w - x0 - panel_w) or x0
    else
        top = h - margin - total_h
        left = (anchor == 'bottom-right') and math.max(SIDE_PADDING, w - x0 - panel_w) or x0
    end
    if top < SIDE_PADDING then top = SIDE_PADDING end
    if left + panel_w > w - 10 then left = math.max(10, w - panel_w - 10) end

    local lines = { rect_line(left - 12, top - 10, panel_w + 24, total_h + 16, '&H141414&', '25') }
    local buttons = {}
    local function place(list, y, start_x)
        local x = start_x or left
        for _, a in ipairs(list) do
            local bw = math.floor(size * (visual_width(a.label) * 0.58 + 2.6)) + 2 * pad
            local hovered = (UI.hover == a.name)
            buttons[#buttons + 1] = { name = a.name, label = a.label, x = x, y = y, w = bw, h = bh }
            local bg = a.color and ass_color(a.color) or (hovered and '&H3C6E9E&' or '&H333333&')
            lines[#lines + 1] = rect_line(x, y, bw, bh, bg, hovered and '10' or '35')
            local fg, oc = '&HFFFFFF&', '&H000000&'
            if a.color then fg, oc = swatch_colors(a.color) end
            lines[#lines + 1] = text_line(x + pad, y + pad, size, fg, a.label, hovered, oc)
            x = x + bw + gap
        end
        return y + bh + gap
    end

    local y = top + 4
    lines[#lines + 1] = text_line(left + pad, y + pad, size, '&H4DE0FF&', title, true)
    place(row_title, y, left + pad + title_w)          -- 标题行右侧：帮助 / 关闭
    y = y + bh + gap

    -- 颜色行：8 个色块（数字即 Pr 的颜色索引）；选中项用白色外圈 + 加粗标出
    local cx = left
    for _, a in ipairs(color_row) do
        local bw = math.floor(size * 2.9)
        local chosen = (a.color == S.color)
        buttons[#buttons + 1] = { name = a.name, label = a.label, x = cx, y = y, w = bw, h = bh }
        if chosen then
            lines[#lines + 1] = rect_line(cx - 3, y - 3, bw + 6, bh + 6, '&HFFFFFF&', '0')
        end
        lines[#lines + 1] = rect_line(cx, y, bw, bh, ass_color(a.color), chosen and '0' or '40')
        local fg, oc = swatch_colors(a.color)
        lines[#lines + 1] = text_line(cx + pad, y + pad, size, fg,
            string.format('%d %s', a.color, a.label), chosen, oc)
        cx = cx + bw + gap
    end
    y = y + bh + gap

    y = place(row_main, y)
    y = place(row_extra, y)

    set_overlay(overlay_panel, lines, w, h)

    -- 注册鼠标区域：每个按钮一个 input section（set_mouse_area 是按 section 生效的）
    PANEL_BUTTONS = buttons
    for _, b in ipairs(buttons) do
        b.section = 'sm_panel_' .. b.name:gsub('[^%w]', '_')
        mp.commandv('define-section', b.section,
            'mbtn_left script-binding ' .. BIND_PREFIX .. b.name, 'force')
        mp.commandv('enable-section', b.section)
        mp.set_mouse_area(b.x, b.y, b.x + b.w, b.y + b.h, b.section)
    end
end

----------------------------------------------------------------------
-- 第 8 条：Pr 源监视器风格控制栏（与 F2 按钮面板互斥；F3 切换样式）
----------------------------------------------------------------------
-- 圆用正 16 边形近似（图标只有 20 单位见方，肉眼与真圆无异）
-- 前后标记：上半箭头、下半盾（**上下叠** —— 与「转到入/出点」那种"括号+箭头"并排的样式区分开，
-- 否则一眼分不清谁是谁；盾沿用「打标记」那个五边形，视觉语言统一）
local SHIELD_SMALL = { 5, 10, 15, 10, 15, 15, 10, 19.5, 5, 15 }

local function circle_pts(cx, cy, r, reverse)
    local pts, n = {}, 16
    for i = 0, n - 1 do
        local k = reverse and (n - i) or i
        local a = 2 * math.pi * k / n
        pts[#pts + 1] = cx + r * math.cos(a)
        pts[#pts + 1] = cy + r * math.sin(a)
    end
    return pts
end

-- 图标全部是【矢量多边形】（ASS \p1 绘图指令），不依赖字体：换字体/换系统都不会变形。
-- 坐标一律在 20×20 的方格里，渲染时按 icon/20 缩放。
local ICONS = {
    -- 打标记：Pr 的"盾牌"（五边形、底下带尖）
    marker = { { 2, 0, 18, 0, 18, 11, 10, 20, 2, 11 } },
    -- 标记入点 '{'：上下钩朝右、中刺朝左
    brace_in = {
        { 8, 0, 16, 0, 16, 3, 8, 3 }, { 8, 0, 13, 0, 13, 20, 8, 20 },
        { 8, 17, 16, 17, 16, 20, 8, 20 }, { 3, 8.5, 8, 8.5, 8, 11.5, 3, 11.5 },
    },
    -- 标记出点 '}'：上下钩朝左、中刺朝右
    brace_out = {
        { 4, 0, 12, 0, 12, 3, 4, 3 }, { 7, 0, 12, 0, 12, 20, 7, 20 },
        { 4, 17, 12, 17, 12, 20, 4, 20 }, { 12, 8.5, 17, 8.5, 17, 11.5, 12, 11.5 },
    },
    -- 转到入点：'{' + 左向实心箭头
    goto_in = {
        { 2, 0, 5, 0, 5, 20, 2, 20 }, { 2, 0, 8, 0, 8, 2.5, 2, 2.5 },
        { 2, 17.5, 8, 17.5, 8, 20, 2, 20 }, { 14, 2, 6, 10, 14, 18 },
        { 13, 7.5, 20, 7.5, 20, 12.5, 13, 12.5 },
    },
    -- 转到出点：右向实心箭头 + '}'
    goto_out = {
        { 0, 7.5, 7, 7.5, 7, 12.5, 0, 12.5 }, { 6, 2, 14, 10, 6, 18 },
        { 15, 0, 18, 0, 18, 20, 15, 20 }, { 12, 0, 18, 0, 18, 2.5, 12, 2.5 },
        { 12, 17.5, 18, 17.5, 18, 20, 12, 20 },
    },
    -- 后退一帧：左三角 + 竖条（三角的尖必须在左边 —— 第一版把尖画在右边了）
    back1 = { { 11, 2, 0, 10, 11, 18 }, { 14, 2, 18, 2, 18, 18, 14, 18 } },
    -- 向前一帧：竖条 + 右三角
    fwd1 = { { 2, 2, 6, 2, 6, 18, 2, 18 }, { 9, 2, 20, 10, 9, 18 } },
    -- 播放 / 暂停
    play = { { 3, 1, 18, 10, 3, 19 } },
    pause = { { 4, 2, 8, 2, 8, 18, 4, 18 }, { 12, 2, 16, 2, 16, 18, 12, 18 } },
    -- 截取当前帧：相机（机身 + 顶部取景凸起 + 镜头"挖洞"）。
    -- 这三条必须是**同一个 \p1 里的多条子路径**：机身在先、镜头圈反向走后（nonzero 填充规则）
    -- 才能把机身挖出一个圆孔；分成两次绘制的话，孔里露出的是同色的机身 ⇒ 镜头根本看不见（踩过）。
    camera = {
        {
            { 1, 5.5, 19, 5.5, 19, 18, 1, 18 },                        -- 机身
            { 6.5, 2.5, 13.5, 2.5, 13.5, 5.5, 6.5, 5.5 },              -- 顶部取景凸起
            circle_pts(10, 11.75, 3.6, true),                           -- 镜头（反向 ⇒ 挖孔）
        },
    },
    -- 上一个 / 下一个标记：左（右）向块箭头 + 下方小盾
    marker_prev = {
        { 14, 3, 6, 3, 6, 1, 0, 6, 6, 11, 6, 9, 14, 9 },               -- 左向箭头
        SHIELD_SMALL,
    },
    marker_next = {
        { 6, 3, 14, 3, 14, 1, 20, 6, 14, 11, 14, 9, 6, 9 },            -- 右向箭头
        SHIELD_SMALL,
    },
}

-- 左→右：与 Pr 源监视器底部栏一致（Pr 里"插入/覆盖/切换代理"在 mpv 无意义，不画也不留位）
local PRBAR_BTN = {
    -- 打标记两侧各放一个"跳标记"（Pr 的按钮栏里没有，是给鼠标党的补充；三件事聚在最左端）
    { name = 'prev-marker', icon = 'marker_prev', label = '上一个标记' },
    { name = 'add',         icon = 'marker',      label = '打标记' },
    { name = 'next-marker', icon = 'marker_next', label = '下一个标记' },
    { name = 'in-set',      icon = 'brace_in',    label = '标记入点' },
    { name = 'out-set',  icon = 'brace_out', label = '标记出点' },
    { name = 'goto-in',  icon = 'goto_in',   label = '转到入点', need = 'in' },
    { name = 'back1',    icon = 'back1',     label = '后退一帧' },
    { name = 'play',     icon = 'play',      label = '播放 / 暂停' },
    { name = 'fwd1',     icon = 'fwd1',      label = '向前一帧' },
    { name = 'goto-out', icon = 'goto_out',  label = '转到出点', need = 'out' },
    { name = 'shot',     icon = 'camera',    label = '截取当前帧' },
}

-- ASS 填充多边形：pts 可以是 {x1,y1, x2,y2, ...}（单条闭合多边形），
-- 也可以是 {{...},{...}}（多条子路径：内圈反向走，靠 nonzero 填充规则挖空 —— 镜头环这类"带孔"图标用）
local function poly_line(x, y, s, color, alpha, pts)
    local function path_of(list)
        local t = {}
        for i = 1, #list, 2 do
            t[#t + 1] = string.format('%.1f %.1f', list[i] * s, (list[i + 1] or 0) * s)
        end
        t[#t + 1] = string.format('%.1f %.1f', list[1] * s, list[2] * s)     -- 闭合路径
        return 'm ' .. table.concat(t, ' l ')
    end
    local parts = {}
    if type(pts[1]) == 'table' then
        for _, sub in ipairs(pts) do parts[#parts + 1] = path_of(sub) end
    else
        parts[#parts + 1] = path_of(pts)
    end
    return string.format('{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c%s\\alpha&H%s&}%s{\\p0}',
        x, y, color or '&HA8A8A8&', alpha or '00', table.concat(parts, ' '))
end

-- ASS 圆角矩形：四角用三次贝塞尔（k=0.5523 是标准圆近似系数）
local function round_rect_line(x, y, w, h, r, rgb, alpha)
    if r > w / 2 then r = math.floor(w / 2) end
    if r > h / 2 then r = math.floor(h / 2) end
    local k = r * 0.5523
    local p = string.format(
        'm %.1f 0 l %.1f 0 b %.1f 0 %.1f %.1f %.1f %.1f l %.1f %.1f'
        .. ' b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f'
        .. ' b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f 0 %.1f 0',
        r, w - r,
        w - r + k, w, r - k, w, r,
        w, h - r,
        w, h - r + k, w - r + k, h, w - r, h,
        r, h,
        r - k, h, 0, h - r + k, 0, h - r,
        0, r,
        0, r - k, r - k, r)
    return string.format('{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c%s\\alpha&H%s&}%s{\\p0}',
        x, y, rgb or '&H2B2B2B&', alpha or '28', p)
end

local function prbar_metrics()
    local w, h = osd_size()
    local scale = math.max(0.8, math.min(1.5, h / 1080)) * (tonumber(o.bar_scale) or 1.0)
    local icon = math.max(10, math.floor(22 * scale + 0.5))
    local pad = math.max(4, math.floor(9 * scale + 0.5))
    local gap = math.max(2, math.floor(4 * scale + 0.5))
    local bpad = math.max(4, math.floor(7 * scale + 0.5))
    local cell = icon + 2 * pad
    local bar_w = #PRBAR_BTN * cell + (#PRBAR_BTN - 1) * gap + 2 * bpad
    local bar_h = cell + 2 * bpad
    local x = math.max(8, math.floor((w - bar_w) / 2))
    local y = math.max(8, h - bar_h - math.floor(24 * scale + 0.5))
    return { w = w, h = h, scale = scale, icon = icon, pad = pad, cell = cell, gap = gap,
             bpad = bpad, bar_w = bar_w, bar_h = bar_h, x = x, y = y }
end

-- 控制栏按钮的鼠标区域：重绘时先全部关掉，再按需打开（置灰的按钮不注册）
local BAR_SECTIONS = {}
local PRBAR_BOX_SIG = nil          -- 命中框的指纹：只在变化时打日志（给自动化测试算坐标用）
local function bar_sections_off()
    for _, sec in pairs(BAR_SECTIONS) do
        mp.commandv('disable-section', sec)
        mp.set_mouse_area(0, 0, 0, 0, sec)
    end
end

local function render_prbar()
    local m = prbar_metrics()
    bar_sections_off()
    if not (UI.bar and UI.style == 'prbar') then
        PRBAR_BUTTONS = {}
        set_overlay(overlay_bar, nil, m.w, m.h)
        return
    end
    local paused = mp.get_property_native('pause') and true or false
    local lines = { round_rect_line(m.x, m.y, m.bar_w, m.bar_h,
        math.floor(m.cell * 0.28), '&H2B2B2B&', '28') }
    local buttons = {}
    for i, b in ipairs(PRBAR_BTN) do
        local bx = m.x + m.bpad + (i - 1) * (m.cell + m.gap)
        local by = m.y + m.bpad
        local hovered = (UI.hover == ('bar:' .. b.name))
        local disabled = (b.need == 'in' and not IN_FRAME) or (b.need == 'out' and not OUT_FRAME)
        if hovered and not disabled then
            lines[#lines + 1] = round_rect_line(bx, by, m.cell, m.cell,
                math.floor(m.cell * 0.22), '&H3C6E9E&', '40')
        end
        local fg = disabled and '&H5A5A5A&' or (hovered and '&HFFFFFF&' or '&HA8A8A8&')
        local key = b.icon
        if b.name == 'play' and not paused then key = 'pause' end   -- 正在播放 → 显示"暂停"图标
        for _, poly in ipairs(ICONS[key] or {}) do
            lines[#lines + 1] = poly_line(bx + m.pad, by + m.pad, m.icon / 20, fg, '00', poly)
        end
        buttons[#buttons + 1] = { name = 'bar:' .. b.name, act = b.name, label = b.label,
                                  x = bx, y = by, w = m.cell, h = m.cell, disabled = disabled }
    end
    -- 悬停提示（默认关：o.bar_tooltip=false）：在按钮上方画一个自适应宽度的小框。
    -- 贴左/贴右的按钮要把框往里挪，否则会顶出屏幕。
    if o.bar_tooltip and UI.hover then
        for _, b in ipairs(buttons) do
            if b.name == UI.hover then
                local tsize = math.max(13, math.floor(m.cell * 0.5))
                local tw = math.floor(visual_width(b.label) * tsize * 0.58) + 14
                local th = tsize + 10
                local tx = math.floor(b.x + b.w / 2 - tw / 2)
                if tx < 6 then tx = 6 end
                if tx + tw > m.w - 6 then tx = m.w - 6 - tw end
                local ty = m.y - th - 6
                if ty < 6 then ty = m.y + m.bar_h + 6 end       -- 栏贴着屏幕顶时改画到下方
                lines[#lines + 1] = round_rect_line(tx, ty, tw, th, 4, '&H141414&', '12')
                lines[#lines + 1] = text_line(tx + 7, ty + 5, tsize, '&HFFFFFF&', b.label)
                break
            end
        end
    end
    set_overlay(overlay_bar, lines, m.w, m.h)
    PRBAR_BUTTONS = buttons

    -- 注册鼠标区域：与旧面板同一套机制（每个按钮一个 section，mbtn_left → script-binding）。
    -- 置灰的按钮**不注册**（点了不该有反应）；section 名字记住，下次重绘好统一关掉。
    for _, b in ipairs(buttons) do
        if not b.disabled then
            local id = 'bar-' .. b.act
            b.section = 'sm_' .. id:gsub('%-', '_')
            BAR_SECTIONS[b.act] = b.section
            mp.commandv('define-section', b.section,
                'mbtn_left script-binding ' .. BIND_PREFIX .. id, 'force')
            mp.commandv('enable-section', b.section)
            mp.set_mouse_area(b.x, b.y, b.x + b.w, b.y + b.h, b.section)
        end
    end

    -- 命中框只在"变了"时打进日志（窗口缩放 / 换样式 / 出入点被设或清）：自动化测试靠它算点击坐标
    local sig = {}
    for _, b in ipairs(buttons) do
        sig[#sig + 1] = string.format('%s=%d,%d,%d,%d%s', b.act, b.x, b.y, b.w, b.h,
            b.disabled and ',off' or '')
    end
    local s = table.concat(sig, ' ')
    if s ~= PRBAR_BOX_SIG then
        PRBAR_BOX_SIG = s
        msg.verbose(string.format('控制栏按钮框：osd=%dx%d %s', m.w, m.h, s))
    end
end

----------------------------------------------------------------------
-- 第 9 条：可缩放时间轴（Pr 源监视器风格）—— r45 静态版
----------------------------------------------------------------------
-- 状态：nil = 整片；r46 的缩放/平移只改这两个值（渲染永远从它们出发）
-- cur_file / saved 用来"只记住同一个文件的范围"（换文件不继承别人的窗口）
local TL = { t0 = nil, t1 = nil, cur_file = nil, saved = nil }

-- 当前文件的"键"（只用文件名：同一文件在不同入口写法可能不同，basename 更稳）
TL.file_key = function()
    local p = mp.get_property('path') or ''
    return (p:match('[^\\/]*$') or p)
end

local function tl_span()
    local dur = mp.get_property_number('duration')
    if not dur or dur <= 0 then return nil end
    -- 第 9 条 r46：换文件时只把"这个文件上次的范围"接回来；别的文件的范围不继承
    local path = TL.file_key()
    if path ~= TL.cur_file then
        TL.cur_file = path
        local saved = TL.saved
        TL.saved = nil
        if saved and saved.file == path then
            TL.t0, TL.t1 = saved.t0, saved.t1
        else
            TL.t0, TL.t1 = nil, nil
        end
    end
    local t0 = TL.t0 or 0
    local t1 = TL.t1 or dur
    if t0 < 0 then t0 = 0 end
    if t1 > dur then t1 = dur end
    if t1 - t0 < 1e-6 then t0, t1 = 0, dur end
    return t0, t1, dur
end

local function tl_metrics()
    local w, h = osd_size()
    local bm = prbar_metrics()                    -- 与控制栏同一套缩放；位置贴着控制栏正上方
    local s = bm.scale * (tonumber(o.tl_scale) or 1.0)   -- 时间轴自己的缩放因子（与控制栏解耦，用户可自己找比例）
    -- 比例尺要大一些（原来 62% 显得比下面控制栏"内容多、格子挤"）
    local width = math.min(math.floor(w * 0.84), w - 60)
    if width < 280 then width = math.max(200, w - 40) end
    -- 每行高度只在这里算一次；render_timeline 按同一套数字排位置，总高也由它们累加，
    -- 这样"最底下那条横线"永远真的落在它该在的地方（刻度基线 / 概览条在最底部）
    local pad     = math.max(5, math.floor(6 * s + 0.5))
    local tc_sz   = math.max(10, math.floor(11 * s + 0.5))
    local ov_h    = math.max(6, math.floor(7 * s + 0.5))
    local lab_sz  = math.max(9, tc_sz - 2)
    local mh      = math.max(5, math.floor(7 * s + 0.5))
    local tick_h  = math.max(3, math.floor(5 * s + 0.5))
    local tick_h2 = math.max(6, math.floor(8 * s + 0.5))
    local gap     = math.max(1, math.floor(2 * s + 0.5))
    local height  = pad + tc_sz + gap + lab_sz + gap + mh + tick_h2 + gap + ov_h + pad
    local x = math.max(8, math.floor((w - width) / 2))
    local y = math.max(8, bm.y - height - math.floor(6 * s + 0.5))
    return { w = w, h = h, scale = s, x = x, y = y, width = width, height = height,
             pad = pad, tc_sz = tc_sz, ov_h = ov_h, lab_sz = lab_sz, mh = mh,
             tick_h = tick_h, tick_h2 = tick_h2, gap = gap,
             mw = math.max(5, math.floor(6 * s + 0.5)),                     -- 播放头头型宽
             mw_mk = math.max(4, math.floor(5 * s + 0.5)) }                 -- 标记头型宽（Pr 里标记比播放头瘦一点）
end

local function render_timeline()
    local m = tl_metrics()
    local t0, t1, dur = tl_span()
    if not (UI.bar and UI.style == 'prbar' and o.tl) or not t0 then
        set_overlay(overlay_tl, nil, m.w, m.h)
        if TL.place then TL.place(nil) end          -- 隐藏时把可点区域一并清掉
        return
    end
    local s = m.scale
    local fps = get_fps() or 25
    local pad = m.pad
    local x0 = m.x + pad
    local x1 = m.x + m.width - pad
    local rw = x1 - x0
    local span = t1 - t0
    local lines = { round_rect_line(m.x, m.y, m.width, m.height, math.floor(8 * s + 0.5), '&H1E1E1E&', '18') }

    -- 行位置全部由 tl_metrics 的同一套高度推出来（那里算总高，这里排位置，不许各写一份）
    -- 从上往下：两端时间码 → 刻度标签 → 标记头型 → 刻度尺（基线）→ 概览 ⚪==⚪（Pr 的位置：块的最底部）
    local tc_sz, ov_h, lab_sz = m.tc_sz, m.ov_h, m.lab_sz
    local mh, tick_h, tick_h2, gap = m.mh, m.tick_h, m.tick_h2, m.gap
    local mw, mw_mk = m.mw, m.mw_mk
    local cy = m.y + pad
    local row_tc = cy
    cy = cy + tc_sz + gap
    local row_lab = cy
    cy = cy + lab_sz + gap
    local row_mk = cy
    local rl_y = row_mk + mh + tick_h2 - 1     -- 刻度基线：竖条、头型尖端、刻度都落在它上面
    local row_ov = rl_y + 1 + gap              -- 概览条在基线**下面**（Pr 是这么放的）
    local ph = mh + tick_h2                    -- 播放头头型高度：顶到标记那一行，尖端正好落在基线上

    -- Pr 的"盾形"头型（上宽下窄、尖端在底部中间）；(x,y) = 左上角
    local function shield_pts(h, wd)
        local yv = math.floor(0.62 * h * 20 / wd + 0.5)
        local yt = math.floor(h * 20 / wd + 0.5)
        return { 0, 0, 20, 0, 20, yv, 10, yt, 0, yv }
    end

    local function t2x(t)
        local x = x0 + (t - t0) / span * rw
        if x < x0 then x = x0 end
        if x > x1 then x = x1 end
        return x
    end
    local function ov2x(t) return x0 + t / dur * rw end

    -- ① 两端时间码 = 可见范围的起点 / 终点
    local ltxt = to_timecode(t0, fps)
    local rtxt = to_timecode(t1, fps)
    local wl = math.floor(visual_width(ltxt) * tc_sz * 0.55)
    local wr = math.floor(visual_width(rtxt) * tc_sz * 0.55)
    lines[#lines + 1] = text_line(x0, row_tc, tc_sz, '&HB8C4D0&', ltxt)
    lines[#lines + 1] = text_line(x1 - wr, row_tc, tc_sz, '&HB8C4D0&', rtxt)

    -- ② 概览 ⚪==⚪（在刻度基线**下面**）：深色轨道 = 整片可滑动范围，亮段 = 当前可见范围，两端各一个圆
    --    tl_ov_map=sqrt 用 Pr 那种压缩映射（亮段比真实比例长 = 极小区间也抓得住，代价是"看到的长度"不真实）
    local ov_mid = row_ov + math.floor(ov_h / 2)
    local ov_track_h = math.max(3, math.floor(4 * s + 0.5))
    lines[#lines + 1] = rect_line(x0, ov_mid - math.floor(ov_track_h / 2), rw, ov_track_h, '&H141414&', '00')
    local function ov_frac(f)
        f = math.max(0, math.min(1, f))
        local mode = o.tl_ov_map or 'linear'
        if mode == 'sqrt' then return math.sqrt(f) end
        if mode == 'pow' then return f ^ (tonumber(o.tl_ov_pow) or 1.29) end   -- Pr 实测：亮段宽 ∝ 区间^1.29
        return f
    end
    local wx0, wx1
    if (o.tl_ov_map or 'linear') == 'bar' and TL.bar_geom then
        local bl, br = TL.bar_geom(t0, t1, dur)     -- Pr 实测形态：宽度只看区间大小，中心线性放大
        wx0, wx1 = x0 + bl * rw, x0 + br * rw
    else
        wx0 = x0 + ov_frac(t0 / dur) * rw
        wx1 = x0 + ov_frac(t1 / dur) * rw
    end
    local cr = math.max(3, math.floor(3.6 * s + 0.5))
    local grk = (TL.grab and TL.grab.kind) or ''      -- 抓取中：对应抓手画亮（r46）
    lines[#lines + 1] = rect_line(math.floor(wx0), ov_mid - 1, math.max(1, math.floor(wx1 - wx0)), 2,
        (grk == 'mid') and '&HFFFFFF&' or '&HD0D0D0&', '0')
    for i, xc in ipairs({ wx0, wx1 }) do
        local hot = (grk == ((i == 1) and 'left' or 'right'))
        local cx = math.floor(xc)
        local r = hot and (cr + 2) or cr
        lines[#lines + 1] = poly_line(cx - r - 1, ov_mid - r - 1, (r + 1) / 10, '&H101010&', '40',
            circle_pts(10, 10, 10))
        lines[#lines + 1] = poly_line(cx - r, ov_mid - r, r / 10, hot and '&HFFFFFF&' or '&HE8E8E8&', '00',
            circle_pts(10, 10, 10))
    end

    -- ⑥a 播放头竖条：**先画**，下面的刻度会盖在它上面（Pr 的行为：刻度在播放头上层）
    --     放大到"一帧 ≥6px"以后，播放头**吸到帧头**（与 ⑥ 的"当前显示帧"扁条同一个条件）——
    --     到这个倍率，播放头只该落在帧头/刻度上，不该落在帧中间（用户反馈）。
    local t = head_time()
    local PL = '&HFFA64D&'
    local frame_px = (1 / fps) / span * rw          -- 一格帧有多宽
    local fi, pl_t, cx_pl                           -- fi = 当前显示帧号（只在吸帧时算）；pl_t = 实际用来画播放头的时间
    if t and frame_px >= 6 then
        fi = math.floor(t * fps + 1e-6)
        pl_t = fi / fps
    end
    if t and t >= t0 and t <= t1 then
        local xpl = math.max(x0, math.min(x1, t2x(pl_t or t)))
        cx_pl = math.floor(xpl) + 0.5               -- 1px 竖线画在 [cx,cx+1)，中心是 cx+0.5
        lines[#lines + 1] = rect_line(math.floor(cx_pl), row_lab, 1, rl_y - row_lab + 1, PL, '30')
    end

    -- ③ 刻度尺：步长只走"典型值"（半固定 —— 缩放时换档，格子形态不变）
    --   1s 以上：时钟值（1/2/5/10/15/30 秒 → 分 → 1 小时封顶），每条大刻度**恒定 5 段**（4 条小刻度）
    --   1s 以下：回到帧，大刻度 = fps 的整数因子且 ≥2 帧，小刻度份数取能整除的 {5,4,3,2}
    lines[#lines + 1] = rect_line(x0, rl_y, rw, 1, '&H5A5A5A&', '0')
    local fps_i = math.max(1, math.floor(fps + 0.5))
    local function minor_parts(frames)
        for _, k in ipairs({ 5, 4, 3, 2 }) do
            if frames % k == 0 and frames / k >= 1 then return k end
        end
        return 0
    end
    local ladder = {}                       -- {步长(秒), 小刻度份数}，**按步长从小到大**排（选档依赖这个顺序）
    for f = 2, fps_i do
        if fps_i % f == 0 then ladder[#ladder + 1] = { f / fps, minor_parts(f) } end
    end
    for _, v in ipairs({ 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600 }) do
        ladder[#ladder + 1] = { v, 5 }
    end
    -- 一屏大刻度控制在 4~8 条：**从大往小**找第一个"间距 ≤ 上限"的档（上限同时保证标签放得下、不糊在一起）
    local sample_w = math.floor(visual_width('00:00') * lab_sz * 0.55)
    local hi_px = math.max(sample_w + math.floor(10 * s + 0.5), math.floor(rw / 4 + 0.5))
    local step, parts = ladder[1][1], ladder[1][2]      -- 兜底 = 最细的一档（放到一帧一格时不会再粗）
    for k = #ladder, 1, -1 do
        local e = ladder[k]
        if e[1] / span * rw <= hi_px + 0.5 then step, parts = e[1], e[2]; break end
    end
    -- 标签：1s 以上 MM:SS / H:MM:SS；1s 以下 SS:FF（可见范围跨分钟时 MM:SS:FF，跟 Pr 的帧号习惯一致）
    -- 1s 以下按**步长序号**算"名义帧"：fps 常带尾巴（这份素材是 30.0005），用 t*fps 会把 6.000s
    -- 那一格标成上一帧（05:28 而不是 06:00）。
    local cross_min = math.floor(t0 / 60) ~= math.floor(t1 / 60)
    local function tl_label(idx, tt, st)
        if st < 1 then
            local fi = math.floor(idx * step * fps + 0.5)
            local sec, ff = math.floor(fi / fps_i), fi % fps_i
            -- 帧档的标签带一个 f（11:23f）——一眼看出这是"秒:帧"而不是"分:秒"
            if cross_min then return string.format('%02d:%02d:%02df', math.floor(sec / 60), sec % 60, ff) end
            return string.format('%02d:%02df', sec % 60, ff)
        end
        local sec = math.floor(tt + 1e-6)
        local hh = math.floor(sec / 3600)
        local mm = math.floor(sec % 3600 / 60)
        if hh > 0 then return string.format('%d:%02d:%02d', hh, mm, sec % 60) end
        return string.format('%02d:%02d', mm, sec % 60)
    end
    -- 起点对齐到步长整数倍；减 0.01 步是给 fps 尾巴（29.97/30.0005）留的浮点余量 ——
    -- 否则 6.000s 这种"正好在格子上"的点会被算成 90.0014 步、ceiling 成下一格，整条刻度相位偏一帧。
    local t_cur = math.ceil(t0 / step - 0.01) * step
    local i_cur = math.floor(t_cur / step + 0.5)          -- 步长序号（= t_cur / step 的整数倍）
    local lab_w = math.floor(visual_width(tl_label(i_cur, t_cur, step)) * lab_sz * 0.55)
    local prev_lab = -9999
    local first_lab = ''                                  -- 第一个真画出去的标签（只进日志，用来核对步长/格式）
    while t_cur <= t1 + 1e-9 do
        -- 大刻度永远落在步长的整数倍上（5s 档就是 5s/10s/15s…，不随可见区间漂移）
        local x = math.floor(t2x(t_cur))
        lines[#lines + 1] = rect_line(x, rl_y - tick_h2, 1, tick_h2, '&H6E6E6E&', '0')
        if o.tl_labels then
            -- 标签独占一行；最右端会被夹回框内，压到前一个就干脆不画（宁可少一个数字，不要糊成一片）
            local txt = tl_label(i_cur, t_cur, step)
            local lx = math.min(x + 3, x1 - lab_w)
            if lx >= x0 and lx >= prev_lab + lab_w + math.floor(6 * s + 0.5) then
                prev_lab = lx
                if first_lab == '' then first_lab = txt end
                lines[#lines + 1] = text_line(lx, row_lab, lab_sz, '&H7A8A9A&', txt)
            end
        end
        if parts and parts >= 2 then
            for k = 1, parts - 1 do
                local tx = math.floor(t2x(t_cur + step * k / parts))
                if tx > x0 and tx < x1 then
                    lines[#lines + 1] = rect_line(tx, rl_y - tick_h, 1, tick_h, '&H5A5A5A&', '0')
                end
            end
        end
        t_cur = t_cur + step
        i_cur = i_cur + 1
    end

    -- ④ 标记（彩色盾形头，比播放头**瘦**一点 —— Pr 里两者接近，标记窄一些；同一像素只画一个）
    local last_x = -999
    for _, mk in ipairs(S.markers) do
        if mk.t >= t0 and mk.t <= t1 then
            local x = t2x(mk.t)
            if x - last_x >= 2 then
                last_x = x
                local c = ass_color(mk.color or 0)
                -- 中心线取 +0.5：1px 的竖线画在 [cx,cx+1)，中心是 cx+0.5，头型按同一条中心对称
                local cx = math.floor(x) + 0.5
                lines[#lines + 1] = poly_line(cx - mw_mk / 2, rl_y - tick_h2 - mh, mw_mk / 20, c, '00',
                    shield_pts(mh, mw_mk))
                lines[#lines + 1] = rect_line(math.floor(cx), rl_y - tick_h2, 1, tick_h2, c, '70')
            end
        end
    end

    -- ⑤ 出入点：区间淡色带 + 两个方括号（区间武装中用另一种色）
    local xi_x, xo_x
    if IN_FRAME or OUT_FRAME then
        local xi = IN_FRAME and t2x(frame_seconds(IN_FRAME)) or nil
        local xo = OUT_FRAME and t2x(frame_seconds(OUT_FRAME)) or nil
        xi_x, xo_x = xi, xo
        local band = RANGE_ARMED and '&H2A6E2A&' or '&H6E4A2A&'
        -- 括号与淡色带从刻度标签那一行一直画到基线（Pr 的出入点括号也是整条高度）
        local bh = rl_y - row_lab + 1
        if xi and xo and xo > xi then
            lines[#lines + 1] = rect_line(math.floor(xi), row_lab, math.max(1, math.floor(xo - xi)), bh, band, '70')
        end
        local bw = math.max(2, math.floor(2 * s + 0.5))
        local arm = math.max(4, math.floor(5 * s + 0.5))
        for _, spec in ipairs({ { xi, 1 }, { xo, -1 } }) do
            local x = spec[1]
            if x then
                local ax = math.floor(x - (spec[2] < 0 and arm or 0))
                lines[#lines + 1] = rect_line(math.floor(x), row_lab, bw, bh, '&HFFFFFF&', '10')
                lines[#lines + 1] = rect_line(ax, row_lab, arm, bw, '&HFFFFFF&', '10')
                lines[#lines + 1] = rect_line(ax, rl_y - bw, arm, bw, '&HFFFFFF&', '10')
            end
        end
    end

    -- ⑥ 播放头头型：Pr 的"盾形"（尖端落在基线上）；放大到一帧 ≥6px 时，把"当前显示帧"那一格
    --    画成蓝色扁条 —— Pr 用它提示"监视器上现在显示的是哪一帧"（扁条在哪边就说明头偏在哪边）。
    --    在范围外 = 对应边缘画方向小箭头（用户定的）。
    if t then
        if t >= t0 and t <= t1 then
            if fi then                                     -- 一帧 ≥6px：画出"当前显示帧"那一格
                local bh = math.max(2, math.floor(tick_h2 / 2))
                lines[#lines + 1] = rect_line(math.floor(t2x(fi / fps)), rl_y - bh,
                    math.max(2, math.floor(frame_px)), bh + 1, PL, '00')
            end
            lines[#lines + 1] = poly_line(cx_pl - mw / 2, rl_y - ph, mw / 20, PL, '00', shield_pts(ph, mw))
        elseif t < t0 then
            lines[#lines + 1] = poly_line(x0 + 2, rl_y - ph, ph / 20, PL, '20',
                { 20, 0, 0, 10, 20, 20 })
        else
            lines[#lines + 1] = poly_line(x1 - ph - 2, rl_y - ph, ph / 20, PL, '20',
                { 0, 0, 20, 10, 0, 20 })
        end
    end

    set_overlay(overlay_tl, lines, m.w, m.h)
    -- r46：把这一帧的几何交给鼠标交互（一个 section 覆盖整块，按 y 落在哪一行分派）
    if TL.place then
        TL.place({
            x0 = x0, x1 = x1, rw = rw, t0 = t0, t1 = t1, span = span, dur = dur, fps = fps,
            y_tc = row_tc, h_tc = tc_sz, y_lab = row_lab, rl_y = rl_y,
            y_ov = row_ov, h_ov = ov_h, w_l = wl, w_r = wr, wx0 = wx0, wx1 = wx1,
        })
    end
    -- 中间量打进日志（位置类问题只能靠它精确定位，别靠肉眼数像素）
    msg.verbose(string.format('时间轴：范围 %.3f~%.3f ｜ 画布 x %d..%d ｜ 行数 %d ｜ 大刻度 %.4fs×%d段 ｜ 标签%s 首标=%s ｜ 入=%s 出=%s ｜ 播放头=%s ｜ 几何 tc=%d,%d 标签行=%d 基线=%d 概览=%d 概览x=%d,%d 码宽=%d/%d 概览k=%.4f',
        t0, t1, x0, x1, #lines,
        step, parts or 0, o.tl_labels and 'on' or 'off', first_lab ~= '' and first_lab or '（无）',
        xi_x and string.format('%.0f', xi_x) or '无', xo_x and string.format('%.0f', xo_x) or '无',
        t and string.format('%.3f 吸帧=%s 帧宽=%.1fpx 头x=%.0f', t, fi and tostring(fi) or '关',
            frame_px, cx_pl or -1) or '无',
        row_tc, tc_sz, row_lab, rl_y, row_ov, wx0, wx1, wl, wr,
        (o.tl_ov_map == 'bar' and TL.bar_k) and TL.bar_k(math.max(0, math.min(1, span / math.max(1e-6, dur)))) or 1))
end

----------------------------------------------------------------------
-- 第 9 条 r46：时间轴的缩放 / 平移（滚轮 + 键盘 + 脚本绑定）
----------------------------------------------------------------------
-- 约定（与用户对齐）：
--   · 滚轮以【播放头】为轴缩放；播放头不在可见范围内时以最近的那条边为轴（那条边不动）
--   · 单滚 = 中步长；Ctrl+滚轮 = 细；Shift+滚轮 = 粗
--   · Alt+滚轮 = 左右平移，Shift+Alt+滚轮 = 粗平移；Ctrl+Alt+滚轮 不占用（留给用户/mpv）
--   · 键盘默认 Alt+= / Alt+- / Alt+0（keys.conf 可改）
--   · 最小跨度 = tl_min_frames 帧（默认 15 帧：Pr 实测也是十几帧，一帧一格不是给人用的）
--   · 范围跨重启记住 —— 但只记"同一个文件"的（ui.json 里 tl_file / tl_t0 / tl_t1）
local function tl_init()      -- 整块塞进一个函数：Lua 5.1 主块最多 200 个 local，这个文件已经很挤
-- 步长（用户实测反馈：原来 ×1.5/×1.12/×2.5 整体偏粗，Ctrl 的手感已经像 Pr 的 Shift ⇒ 全部调细）；
-- 可用 tl_zoom_steps = '普通,细,粗' 自己调（重启生效）
local TL_STEP = { plain = 1.10, ctrl = 1.03, shift = 1.35, key = 2.0 }
local TL_PAN  = { plain = 0.10, shift = 0.25 }
do
    local a, b, c = tostring(o.tl_zoom_steps or ''):match('([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)')
    if tonumber(a) and tonumber(b) and tonumber(c) then
        TL_STEP.plain, TL_STEP.ctrl, TL_STEP.shift = tonumber(a), tonumber(b), tonumber(c)
    end
    TL_STEP.key = tonumber(o.tl_key_step) or 2.0
end

local function tl_min_span()
    local fr = tonumber(o.tl_min_frames) or 15
    if fr < 1 then fr = 1 end
    local s = fr / (get_fps() or 25)
    -- Pr 的概览条两圆最小间距约 40 px；长片上"15 帧"会窄到抓不住（亮段宽 w = u^pow）
    local g, dur = TL.geo, mp.get_property_number('duration')
    if (o.tl_ov_map or 'linear') == 'bar' and g and g.rw and g.rw > 0 and dur and dur > 0 then
        local pow = tonumber(o.tl_ov_pow) or 1.30
        local u = (tonumber(o.tl_min_px) or 40) / g.rw
        if u > 0 and u < 1 then s = math.max(s, dur * u ^ (1 / pow)) end
    end
    return s
end

-- 夹取：最小跨度 + 不出片头/片尾（full=true 表示等于整片，此时 TL 里存 nil）
local function tl_clamp_range(t0n, t1n, dur)
    local minspan = tl_min_span()
    if minspan > dur then minspan = dur end
    local span = t1n - t0n
    if span < minspan then                       -- 太小 ⇒ 中心不动，放大到最小跨度
        local c = (t0n + t1n) / 2
        t0n, t1n = c - minspan / 2, c + minspan / 2
        span = minspan
    end
    if span >= dur - 1e-9 then return 0, dur, true end
    if t0n < 0 then t0n, t1n = 0, span end
    if t1n > dur then t1n, t0n = dur, dur - span end
    return t0n, t1n, false
end

-- 统一入口：夹取 → 落盘 → 重绘 → 记日志（why 会打进日志，自动化测试靠它认路）
local function tl_set_range(t0n, t1n, why, save)
    local dur = mp.get_property_number('duration')
    if not dur or dur <= 0 then return end
    local t0c, t1c, full = tl_clamp_range(t0n, t1n, dur)
    TL.t0 = full and nil or t0c
    TL.t1 = full and nil or t1c
    if save ~= false and save_ui_state then save_ui_state() end
    log('时间轴%s：范围 %.3f ~ %.3f（跨度 %.3f / 整片 %.3f）',
        why and ('·' .. why) or '设置', t0c, t1c, t1c - t0c, dur)
    render_timeline()
end

local function tl_zoom(factor, why)
    if TL.grab then TL.drop('缩放') end
    local t0c, t1c = tl_span()
    local dur = mp.get_property_number('duration')
    if not t0c or not dur then return end
    local span = t1c - t0c
    local minspan = tl_min_span()
    -- 已经顶在最小跨度上再放大 = 什么都不做。否则会出现"跨度缩不动、整段却在漂"的不对称
    -- （用户实测：在 00:00 按 = 到最小再按 - 时区间整体向右漂，根因之一就在这里）。
    if factor > 1 and span <= minspan + 1e-9 then
        msg.verbose(string.format('时间轴·已在最小跨度 %.3f s，再放大无效', span))
        return
    end
    local anchor = mp.get_property_number('time-pos')
    if not anchor then anchor = (t0c + t1c) / 2 end
    if anchor < t0c then anchor = t0c end              -- 播放头在范围外 ⇒ 以最近的边为轴
    if anchor > t1c then anchor = t1c end
    local p = (anchor - t0c) / span
    -- 锚点模式：head = 死钉播放头；center = 钉区间中心；
    --           pr   = 每档把播放头往中心拉（上一轮按 T3 拟合：偏移 ×2/3）；
    --           snap = 缩放后播放头**直接落在区间正中**（NS1 实测：Pr 从整片缩一档时 p 由 0.3333 → 0.5000）
    local anchor_mode = o.tl_zoom_anchor or 'head'
    if anchor_mode == 'center' then
        anchor = (t0c + t1c) / 2
        p = 0.5
    elseif anchor_mode == 'snap' then
        p = 0.5
    elseif anchor_mode == 'pr' then
        local pull = tonumber(o.tl_zoom_pull) or 0.585
        if pull > 0 then
            p = 0.5 + (p - 0.5) * (1 / factor) ^ pull
            msg.verbose(string.format('时间轴·缩放锚点 p → %.3f（pr，拉力 %s）', p, tostring(pull)))
        end
    end
    -- 播放头不许被甩到区间外：一旦跑出去，下一轮"以最近的边为轴"会把区间一点点推走（越漂越远）。夹回 [0,1]。
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    local newspan = span / factor
    if newspan < minspan then newspan = minspan end
    if newspan > dur then newspan = dur end
    local n0 = anchor - p * newspan
    tl_set_range(n0, n0 + newspan, string.format('%s ×%.3f', why or '缩放', factor))
end

local function tl_pan(frac, why)
    if TL.grab then TL.drop('平移') end
    local t0c, t1c = tl_span()
    local dur = mp.get_property_number('duration')
    if not t0c or not dur then return end
    local span = t1c - t0c
    if span >= dur - 1e-9 then
        notify('时间轴已经是整片（缩放之后才能平移）')
        return
    end
    local n0 = t0c + span * frac
    tl_set_range(n0, n0 + span, string.format('%s %+.0f%%', why or '平移', frac * 100))
end

local function tl_reset(why)
    local dur = mp.get_property_number('duration')
    if not dur or dur <= 0 then return end
    tl_set_range(0, dur, why or '整片')
end

-- 动作名 → 行为：既给键位表用，也直接作为"脚本绑定"暴露（input.conf / script-binding 都能调）
local TL_ACTIONS = {
    ['tl-zoom-in']   = function() tl_zoom(TL_STEP.key or 2.0, '键位') end,
    ['tl-zoom-out']  = function() tl_zoom(1 / (TL_STEP.key or 2.0), '键位') end,
    ['tl-pan-left']  = function() tl_pan(-TL_PAN.plain, '左移') end,
    ['tl-pan-right'] = function() tl_pan(TL_PAN.plain, '右移') end,
    ['tl-reset']     = function() tl_reset('整片') end,
}
for name, fn in pairs(TL_ACTIONS) do mp.add_key_binding(nil, name, fn) end

-- 键位表里的三个默认键（绑定名带键名 keytag —— 同一个名字重复 add_key_binding 会静默替换，这是老坑）
for _, spec in ipairs(TL_KEYS) do
    local k = eff_key(spec.name, spec.key)
    if k then
        local tag = tostring(k):gsub('[^%w]', '')
        local ok, err = pcall(mp.add_key_binding, k, spec.name .. '-' .. tag, TL_ACTIONS[spec.name])
        if not ok then log('时间轴键位绑定失败：key=%s name=%s err=%s', k, spec.name, tostring(err)) end
    end
end

-- 滚轮（r46 第七轮）：Pr 是**分区**的 —— 时间轴上滚轮 = 播放头 ±1 帧，只有落在控制条
-- （圆圈横条 + 滑轨那一整条）里滚轮才缩放。指针在时间轴外（画面区/按钮栏）时滚轮不做事。
-- 这里不用 input section 分派（不同后端对 wheel 的 area 分派不一致），改成全局收 wheel 后按
-- mouse-pos 的 y 判区域：既可日志取证，也不会因为 area 不生效而让滚轮整个失效。
local TL_WHEEL_POS = nil          -- 取证钩子 tl-wheel-at 用：临时指定坐标
local function tl_bind_wheel(key, fn)
    local ok, err = pcall(mp.add_key_binding, key, 'tl-wheel-' .. tostring(key):gsub('[^%w]', ''), fn)
    if not ok then log('滚轮绑定失败 %s：%s', key, tostring(err)) end
end
local function tl_wheel_region(x, y)
    local g = TL.geo
    if not g or not x or not y then return nil end
    if x < g.x0 - 2 or x > g.x1 + 2 then return nil end
    if y >= g.y_ov - 2 and y <= g.y_ov + g.h_ov + 2 then return 'con' end     -- 控制条：缩放
    if y >= g.y_tc - 2 and y <= g.rl_y + 2 then return 'axis' end            -- 刻度/标记/时间码：单帧
    return nil
end
-- 滚动跟随（NS6 11A 定论）：播放头还在区间内 → 区间不动；一旦越出区间边界，就把区间**平移**（跨度不变），
-- 让播放头回到区间内并尽量居中；贴到片头/片尾时夹边界，播放头因此无法居中（与 Pr 实测一致）。
local function tl_follow_playhead(why)
    local t0c, t1c, dur = tl_span()
    local t = mp.get_property_number('time-pos')
    if not t0c or not t1c or not t or not dur then return end
    local span = t1c - t0c
    if span >= dur - 1e-9 then return end            -- 整片：无可跟随
    if t >= t0c - 1e-9 and t <= t1c + 1e-9 then return end
    local n0 = t - span / 2
    n0 = math.max(0, math.min(n0, dur - span))
    if math.abs(n0 - t0c) < 1e-6 then return end     -- 贴边夹住后与现状相同：不重复记日志/落盘
    tl_set_range(n0, n0 + span, (why or '跟随') .. '·播放头出区间')
end

-- 播放跟随（r46 第九轮）：Pr 实测 —— 播放时区间**不动**（允许播放头跑出区间），暂停时才把区间平移、
-- 让播放头尽量居中（贴片头/片尾夹边界时只能偏侧，与越界重排同源）。另给两个用户提的模式：
--   page   = 播到区间尾就把区间头挪到旧区间尾（翻页），播放头持续播放，永不跑出区间
--   center = 始终让播放头居中（到两端做不到就放跑）
local TL_FOLLOW_T = 0
local function tl_play_follow_check(why, playing)
    local mode = tostring(o.tl_play_follow or 'pr')
    if mode == 'off' then return end
    local t0c, t1c, dur = tl_span()
    local t = mp.get_property_number('time-pos')
    if not t0c or not t1c or not t or not dur then return end
    local span = t1c - t0c
    if span >= dur - 1e-9 then return end                 -- 整片：无可跟随
    if playing == nil then playing = mp.get_property_native('pause') == false end
    if mode == 'pr' then
        if playing then return end                        -- 播放中一动不动（与 Pr 一致）
        tl_follow_playhead(why or '暂停')
        return
    end
    if mode == 'page' then
        if t > t1c - 1e-9 then
            local n0 = math.min(t1c, dur - span)          -- 区间头 = 旧区间尾；贴片尾时夹回
            if math.abs(n0 - t0c) > 1e-6 then tl_set_range(n0, n0 + span, '播放跟随(page)·翻页', false) end
        elseif t < t0c + 1e-9 then
            local n0 = math.max(0, t0c - span)
            if math.abs(n0 - t0c) > 1e-6 then tl_set_range(n0, n0 + span, '播放跟随(page)·回翻', false) end
        end
        return
    end
    local c = (t0c + t1c) / 2
    if math.abs(t - c) <= span * 0.15 then return end      -- center：15% 死区，免得每帧都挪
    local n0 = math.max(0, math.min(t - span / 2, dur - span))
    if math.abs(n0 - t0c) < 1e-6 then return end            -- 贴边时无法居中：不重复动作
    tl_set_range(n0, n0 + span, '播放跟随(center)·居中', false)
end
local function tl_follow_tick(why)
    local now = mp.get_time()
    if now - TL_FOLLOW_T < 0.15 then return end            -- 节流：time-pos 变化很密
    TL_FOLLOW_T = now
    tl_play_follow_check(why, true)
end
mp.observe_property('time-pos', 'number', function() tl_follow_tick('播放') end)
mp.observe_property('pause', 'native', function(_, p)
    if p then tl_play_follow_check('暂停', false) end
end)
local function tl_wheel_frame(dir)
    local before = mp.get_property_number('time-pos') or 0
    local fps = mp.get_property_number('estimated-vf-fps') or 30
    local tf = math.floor(before * fps + 0.5) + (dir > 0 and 1 or -1)
    if tf < 0 then tf = 0 end
    mp.set_property_number('time-pos', tf / fps)
    log('时间轴·滚轮刻度区 → %s：自 %.3f 到帧 %d（%.3f）',
        dir > 0 and '前进一帧' or '后退一帧', before, tf, tf / fps)
    tl_follow_playhead('滚轮')
end
local function tl_wheel(dir)          -- dir > 0 = 滚轮向上
    local pos = TL_WHEEL_POS or mp.get_property_native('mouse-pos') or {}
    local reg = tl_wheel_region(pos.x, pos.y)
    if reg == 'axis' then
        -- 用户 2026-10-20 实测：时间轴上滚轮**向上 = 后退一帧**（与 Pr 一致），所以这里取反
        tl_wheel_frame(-dir)
    elseif reg == 'con' then
        tl_zoom(dir > 0 and TL_STEP.plain or 1 / TL_STEP.plain, dir > 0 and '滚轮上' or '滚轮下')
    else
        msg.verbose(string.format('时间轴·滚轮（区域外 x=%s y=%s）忽略', tostring(pos.x), tostring(pos.y)))
    end
end
tl_bind_wheel('wheel_up',   function() tl_wheel(1) end)
tl_bind_wheel('wheel_down', function() tl_wheel(-1) end)
tl_bind_wheel('Ctrl+wheel_up',   function() tl_zoom(TL_STEP.ctrl, 'Ctrl+滚轮上') end)
tl_bind_wheel('Ctrl+wheel_down', function() tl_zoom(1 / TL_STEP.ctrl, 'Ctrl+滚轮下') end)
tl_bind_wheel('Shift+wheel_up',   function() tl_zoom(TL_STEP.shift, 'Shift+滚轮上') end)
tl_bind_wheel('Shift+wheel_down', function() tl_zoom(1 / TL_STEP.shift, 'Shift+滚轮下') end)
tl_bind_wheel('Alt+wheel_up',   function() tl_pan(-TL_PAN.plain, 'Alt+滚轮上') end)
tl_bind_wheel('Alt+wheel_down', function() tl_pan(TL_PAN.plain, 'Alt+滚轮下') end)
tl_bind_wheel('Shift+Alt+wheel_up',   function() tl_pan(-TL_PAN.shift, 'Shift+Alt+滚轮上') end)
tl_bind_wheel('Shift+Alt+wheel_down', function() tl_pan(TL_PAN.shift, 'Shift+Alt+滚轮下') end)

----------------------------------------------------------------------
-- r46 step2：鼠标交互 —— 刻度带单击跳转、双击回整片、点两端时间码输入跳转
----------------------------------------------------------------------
-- mpv 没有"鼠标松开"事件，拖动类交互统一走"点一下抓起 → 移动 → 再点一下放下"。
-- 命中判定用 render_timeline 每帧存下来的几何（TL.geo）：一个 section 覆盖整块时间轴，
-- 由点击的 y 落在哪一行决定行为（时间码行 / 刻度带 / 概览条）。
TL.geo = nil
local TL_SEC = 'sm_tl_click'                              -- 时间轴本体（点击分派：时间码/刻度带/概览条）
local TL_ANY = 'sm_tl_grab_any'                           -- 抓手期间：整窗口"点哪儿都放下"
local TL_KEYSEC = 'sm_tl_grab_keys'                       -- 抓手期间：常用键"一按就放下"
local TL_LAST = { t = -10, x = -1e9 }

-- ③ 概览条三个抓取区：左圆改起点、右圆改终点、中间整体平移（一律**在概览条的尺度上跟鼠标 1:1**）。
--    mpv 没有"鼠标松开"事件 ⇒ 「点一下抓起 → 移动鼠标改范围 → 再点一下放下」。
--    用户 2026-10-13 实测反馈后修的三处：
--      · 中间平移改成跟"抓起那一刻的鼠标位置"比位移（原来拿 t0 当基准 ⇒ 手一抖整条就跳出去）
--      · 左右圆改成用概览条映射反算时间（原来用刻度尺尺度 ⇒ 一点就缩到最小、两个圆贴一起）
--      · 抓取期间**任何点击或按键**都能打断（原来只能再点圆，两圆贴一起后点不到 ⇒ 卡死）
TL.grab = nil

-- 概览条 x → 时间（与画的时候同一套映射，反过来；tl_ov_map=sqrt 也一致）
local function tl_ov_time(g, mx)
    local f = (mx - g.x0) / math.max(1, g.rw)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    if (o.tl_ov_map or 'linear') == 'sqrt' then
        f = f * f
    else
        local mode = o.tl_ov_map or 'linear'
        if mode == 'pow' then f = f ^ (1 / (tonumber(o.tl_ov_pow) or 1.29)) end
    end
    return f * g.dur
end

-- 概览条 'bar' 映射（Pr NS3/NS3b 实测定论）：
--   u = (t1-t0)/dur, c = (t0+t1)/(2*dur)
--   宽 w = u^pow（只由区间大小决定）；中心 xc = 0.5 + (c-0.5)*k（线性、斜率 k>1）
--   left = xc - w/2, right = xc + w/2，再夹到 [0,1]（贴边时 Pr 也是夹住不是压缩）
--   实测：u=1/2 时宽占比 0.4057、k=1.1886；五个位置预测误差 < 1.6 px
-- k 不是常数：NS4 A/B 两轮实测 u=1/2→1.19、1/4→1.1186、1/8→1.074、1/16→1.046，
-- 即 k(u) = 1 + (k05-1)*(u/0.5)^0.68 —— 缩得越深越接近线性（否则深层偏移 100+ px）
TL.bar_k = function(u)
    local k5 = tonumber(o.tl_ov_k) or 1.19
    if not u or u >= 0.5 then return k5 end
    return 1 + (k5 - 1) * math.min(1, u / 0.5) ^ 0.68
end

TL.bar_geom = function(t0, t1, dur)
    if not dur or dur <= 0 then return 0, 1 end
    local u = math.max(0, math.min(1, (t1 - t0) / dur))
    local c = math.max(0, math.min(1, (t0 + t1) / (2 * dur)))
    local w = u ^ (tonumber(o.tl_ov_pow) or 1.29)
    -- 贴边必须**钉住**：区间碰到片头/片尾时，那一端就固定在 0/1，宽度照旧由 u 决定。
    -- 否则中心公式（xc 带 k>1 的放大）会让"本该不动的另一端"跟着漂 —— 用户实测：
    -- 播放头 0 时拖右圆从最小到最大，左端在 16s 起右移、23s 到顶、30s 回到原位（复现：138→147→138）。
    local eps = dur * 1e-4
    local at_head = (t0 <= eps)
    local at_tail = (t1 >= dur - eps)
    local l, r
    if tostring(o.tl_ov_edge or 'pin') == 'pr' then
        -- 连续口径：贴边也用中心公式（靠下面的平移 clamp 收进 0~1），贴边瞬间不会阶跃，
        -- 代价是贴边那一端不再像素级钉死（30 s 片上约 6~21 px 的漂移）
        local xc = 0.5 + (c - 0.5) * TL.bar_k(u)
        l, r = xc - w / 2, xc + w / 2
    elseif at_head and at_tail then
        l, r = 0, 1
    elseif at_head then
        l, r = 0, w
    elseif at_tail then
        l, r = 1 - w, 1
    else
        local xc = 0.5 + (c - 0.5) * TL.bar_k(u)
        l, r = xc - w / 2, xc + w / 2
    end
    if l < 0 then r, l = r - l, 0 end
    if r > 1 then l, r = l - (r - 1), 1 end
    if l < 0 then l = 0 end
    if r > 1 then r = 1 end
    return l, r
end

-- 'bar' 模式的反解：一端时间固定，二分求另一端，使那一端的归一化位置等于 target
-- （t0 增大 ⇒ 左端右移；t1 增大 ⇒ 右端右移，两边都单调，可以直接二分）
TL.bar_solve = function(dur, fixed, target, side)
    local lo, hi
    if side == 'left' then lo, hi = 0, fixed else lo, hi = fixed, dur end
    if hi <= lo then return fixed end
    for _ = 1, 42 do
        local mid = (lo + hi) / 2
        local cur
        if side == 'left' then
            cur = TL.bar_geom(mid, fixed, dur)
        else
            local _, rr = TL.bar_geom(fixed, mid, dur)
            cur = rr
        end
        if cur < target then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end

-- 'bar' 模式的反解（第二段）：以播放头为轴两圆对称，反解"跨度"使指定一端正好落在 target 上
-- （跨度变大 ⇒ 两端一起往两边铺，目标端的归一化位置单调递增，仍可二分）
TL.bar_solve_center = function(dur, tph, target, side)
    local lo = tl_min_span()
    local hi = math.min(2 * tph, 2 * (dur - tph))
    if hi <= lo then return nil end
    local function pos(sp)
        local l, r = TL.bar_geom(tph - sp / 2, tph + sp / 2, dur)
        return side == 'left' and l or r
    end
    -- 端点位置随跨度的单调方向取决于抓哪一端：抓右端（r）跨度越大越靠右；
    -- 抓左端（l）跨度越大越靠左 ⇒ 二分方向必须反着走。
    -- （r46 第十八轮修：原来一律按"越大越靠右"处理，抓左端时永远返回最小跨度，
    --   表现就是左圆一进同动立刻缩到最小区间。）
    local inc = (side ~= 'left')
    local q0, q1 = pos(lo), pos(hi)
    if inc then
        if q0 >= target then return lo end
        if q1 <= target then return hi end
    else
        if q0 <= target then return lo end
        if q1 >= target then return hi end
    end
    for _ = 1, 42 do
        local mid = (lo + hi) / 2
        local q = pos(mid)
        if inc then
            if q < target then lo = mid else hi = mid end
        else
            if q > target then lo = mid else hi = mid end
        end
    end
    return (lo + hi) / 2
end

-- 'bar' 模式的反解（像素钉死，Pr 上机实测定论：拖右圆时左端像素不动、左端时间微调 12~16 帧）
-- anchor = 抓起时"另一端"的归一化位置（抓右端 ⇒ anchor 是左端 l0）；target = 被拖端的目标位置
-- w = b-a 定 u，u 定 span；xc = (a+b)/2 定 c，再由 c 定时中 ⇒ 两端时间。
TL.bar_solve_px = function(dur, anchor, target, side, minw)
    if not dur or dur <= 0 or not anchor then return nil end
    local pow = tonumber(o.tl_ov_pow) or 1.29
    local a, b
    if side == 'right' then a, b = anchor, target else a, b = target, anchor end
    if minw and b - a < minw then          -- 跨度触底：宽度锁在最小跨度上，钉住端仍然不动
        if side == 'right' then b = a + minw else a = b - minw end
    end
    local w = b - a
    if w <= 1e-6 then return nil end
    local u = w ^ (1 / pow)
    if u > 1 then return nil end
    local c = 0.5 + ((a + b) / 2 - 0.5) / TL.bar_k(u)
    local span = u * dur
    local mid = c * dur
    return mid - span / 2, mid + span / 2
end

-- Pr 式时间码输入：纯数字时**从右往左**两位一组读 = [时][分][秒][帧]，帧数超过 fps 自动进位
-- 2200 → 22 秒 0 帧；120000 → 12 分 0 秒 0 帧；2245 @30fps → 23 秒 15 帧
-- 带分隔符的（00:00:22:00 / 22.5 / 1:02:03）仍走导入侧那套 parse_time，两边规则不互相污染。
TL.parse_tc = function(str, fps)
    local s = tostring(str or ''):gsub('%s', '')
    if s == '' then return nil end
    if s:match('^%d+$') then
        local fi = tonumber(fps) or 25
        if fi < 1 then fi = 1 end
        local n = #s
        local function part(from, len)                  -- 从右往左第 from 位起，取 len 位
            local a = n - from - len + 1
            if a < 1 then return 0 end
            return tonumber(s:sub(a, a + len - 1)) or 0
        end
        local fr = part(0, 2)
        local ss = part(2, 2)
        local mm = part(4, 2)
        local hh = part(6, n)
        return hh * 3600 + mm * 60 + ss + fr / fi       -- fr/fi 自动进位（45 帧 @30 = 1.5 秒）
    end
    return parse_time(s, fps)
end

local function tl_grab_sections(on)
    local w, h = osd_size()
    if on then
        mp.commandv('disable-section', TL_SEC)          -- 抓取期间点哪儿都是"放下"，不再走点击分派
        mp.set_mouse_area(0, 0, w, h, TL_ANY)           -- 整个窗口都算"放下"（点别处也能退出）
        mp.commandv('enable-section', TL_ANY)
        mp.commandv('enable-section', TL_KEYSEC)
    else
        mp.set_mouse_area(0, 0, 0, 0, TL_ANY)
        mp.commandv('disable-section', TL_ANY)
        mp.commandv('disable-section', TL_KEYSEC)
        mp.commandv('enable-section', TL_SEC)
    end
end

TL.drop = function(why)                                  -- 放下：保留当前范围，只结束抓取
    if not TL.grab then return end
    TL.grab = nil
    tl_grab_sections(false)
    msg.verbose('时间轴·放下（' .. tostring(why or '点击') .. '）')
    render_timeline()
end

TL.abort = function(why)                                 -- 放弃：回到抓起前的范围
    if not TL.grab then return end
    local gr = TL.grab
    TL.grab = nil
    tl_grab_sections(false)
    tl_set_range(gr.t0, gr.t1, '放弃抓取（' .. tostring(why or 'ESC') .. '）')
end

local function tl_grab_start(g, mx)
    local kind = 'mid'
    -- 圆直径约 12 px，命中半径放大到 1.1 倍（tl_hit_px），圆看着抓不住的问题就解决了
    local hitr = tonumber(o.tl_hit_px) or 13
    -- 圆贴到画布边缘时，外侧那一半在窗口外根本点不到（命中框看着变小）；把内侧补一倍，
    -- 让贴边圆的可点宽度和中间的圆一样。取更近的那个目标，否则两端各补一倍会互相抢。
    local hrl = ((g.wx0 - g.x0) < hitr) and hitr * 2 or hitr
    local hrr = (((g.x0 + g.rw) - g.wx1) < hitr) and hitr * 2 or hitr
    local dl = math.abs(mx - g.wx0)
    local dr = math.abs(mx - g.wx1)
    if dl <= hrl and dl <= dr then kind = 'left'
    elseif dr <= hrr then kind = 'right' end
    local gl0, gr0
    if (o.tl_ov_map or 'linear') == 'bar' and TL.bar_geom then gl0, gr0 = TL.bar_geom(g.t0, g.t1, g.dur) end
    -- 播放头位置只取抓起那一刻的快照：播放中拖动时 time-pos 一直在变，按实时值算 p0 会让
    -- “播放头在正中就对称缩放”的门槛忽过忽不过
    local tph0 = tonumber(mp.get_property_number('time-pos'))
    local p00 = (tph0 and tph0 > g.t0 + 1e-9 and tph0 < g.t1 - 1e-9) and (tph0 - g.t0) / (g.t1 - g.t0) or nil
    TL.grab = { kind = kind, t0 = g.t0, t1 = g.t1, base = tl_ov_time(g, mx), mx0 = mx, l0 = gl0, r0 = gr0, tph = tph0, p0 = p00 }
    tl_grab_sections(true)
    msg.verbose(string.format('时间轴·抓起 %s（%.3f ~ %.3f，鼠标处 %.3f）：移动鼠标改范围，点任意处/按任意键放下，ESC 放弃',
        kind == 'left' and '左端' or (kind == 'right' and '右端' or '整段'), g.t0, g.t1, TL.grab.base))
    render_timeline()
end

local function tl_grab_move(g, mx)
    local gr = TL.grab
    if not gr then return end
    local minspan = tl_min_span()
    local n0, n1 = gr.t0, gr.t1
    if (o.tl_ov_map or 'linear') == 'bar' and TL.bar_geom and TL.bar_solve then
        -- 'bar' 模式：抓手的 x 不是"时间尺度"，必须按映射反解（否则画的和点的错位）
        local target = math.max(0, math.min(1, (mx - g.x0) / math.max(1, g.rw)))
        local feel = tostring(o.tl_grab_feel or 'pr')
        local tph = gr.tph or tonumber(mp.get_property_number('time-pos'))
        local inr = (tph and tph > gr.t0 + 1e-9 and tph < gr.t1 - 1e-9) and true or false
        local span0 = gr.t1 - gr.t0
        local p0 = gr.p0 or (inr and (tph - gr.t0) / span0 or nil)   -- 抓起时（tl_place 的 pr 两阶段用它）
        -- 两阶段判据用**当前区间**算（播放头取抓起时快照 TL.grab.tph，免得播放中漂移）：
        -- 拖动时区间一直在变，p 会连续地从 0 漂到 0.5，到中点附近就切进“两圆对称”，离开就退回单动。
        -- 进用 0.02、出用 0.05（迟滞），状态记在 gr.sym —— 这样“拖到一半进入同动”和“退出同动”都成立。
        local span_cur = math.max(1e-9, g.t1 - g.t0)
        local pn = (tph and tph > g.t0 + 1e-9 and tph < g.t1 - 1e-9) and (tph - g.t0) / span_cur or nil
        local EPS = 0.02
        -- 按"新跨度 sp 该摆在哪里"落位（越界/最小跨度交给 tl_clamp_range）：
        --   · 播放头在正中 → 两圆对称于播放头（缩、放都对称）
        --   · 播放头在区间外 → 被抓那端动
        --   · 其它位置：缩 → 远端动、近端钉住；放 → 被抓那端动、另一端钉住
        --   · 收缩越过中点 → 以播放头为轴（切换点连续）
        local function tl_place(sp, grab)
            local s2 = math.max(minspan, sp)
            local a, b
            if p0 == nil then
                if grab == 'left' then a, b = gr.t1 - s2, gr.t1 else a, b = gr.t0, gr.t0 + s2 end
            elseif math.abs(p0 - 0.5) <= EPS then
                a, b = tph - s2 / 2, tph + s2 / 2
            elseif s2 < span0 - 1e-9 then
                if p0 < 0.5 then a, b = gr.t0, gr.t0 + s2 else a, b = gr.t1 - s2, gr.t1 end
            else
                if grab == 'left' then a, b = gr.t1 - s2, gr.t1 else a, b = gr.t0, gr.t0 + s2 end
            end
            if a < 0 then b, a = b - a, 0 end
            if b > g.dur then a, b = a - (b - g.dur), g.dur end
            if a < 0 then a = 0 end
            if b > g.dur then b = g.dur end
            if p0 and math.abs(p0 - 0.5) > EPS and b - a > 1e-6 then
                local crossed
                if p0 < 0.5 then crossed = (tph - a) > 0.5 * (b - a) else crossed = (b - tph) > 0.5 * (b - a) end
                if crossed then
                    local s3 = math.max(minspan, math.min(b - a, 2 * tph, 2 * (g.dur - tph)))
                    a, b = tph - s3 / 2, tph + s3 / 2
                    if a < 0 then b, a = b - a, 0 end
                    if b > g.dur then a, b = a - (b - g.dur), g.dur end
                end
            end
            return a, b
        end
        -- 播放头落在区间正中（|p0-0.5|<=EPS）：两圆以播放头为轴对称缩放（Pr 两阶段的第一段，
        -- mouse 手感也要保留；不这样做时抓右圆只会缩右边，播放头会被挤到边上）
        local sym
        local lim = gr.sym and 0.05 or EPS
        -- Pr 口径：播放头在区间内时，“缩小”只允许让播放头朝中点移动。
        -- p<0.5 时右移左圆、p>0.5 时左移右圆都会让播放头远离中点 —— Pr 不允许这种操作，
        -- 而是让“抓的那个圆不动、把另一个圆移过来”，也就是先把播放头拉到 p=0.5 再两圆同动。
        local illegal = false
        if inr and pn and (gr.kind == 'left' or gr.kind == 'right') and TL.bar_geom then
            -- bar_geom 返回的是归一化端点（0..1），鼠标要换算成归一化再比，否则恒判"在缩小"
            local glc, grc = TL.bar_geom(g.t0, g.t1, g.dur)
            local mxn = (mx - g.x0) / math.max(1, g.rw)
            local shrinking = (gr.kind == 'left') and (mxn > glc) or (gr.kind == 'right' and mxn < grc)
            if shrinking and ((pn < 0.5 and gr.kind == 'left') or (pn > 0.5 and gr.kind == 'right')) then
                illegal = true
            end
        end
        -- 抓中段（mid）永远是整体平移：播放头在区间正中时也让 mid 进对称的话，横轴就拖不动了
        if gr.kind ~= 'mid' and pn and math.abs(pn - 0.5) <= lim and TL.bar_solve_center then
            local hi = math.min(2 * tph, 2 * (g.dur - tph))
            if gr.sym_ready == nil then
                -- 进入同动的**第一帧**：跨度保持不变，只把中点点到播放头上（跳幅 = |区间中点−播放头|，模式切换的固有最小值）；
                -- 同时记下"鼠标位置 − 被抓端位置"的偏移 gr.sym_off，后面每帧都用它换算 ——
                -- 否则切模式那一下会按鼠标绝对位置重排区间（实测跳 0.3~0.9 s）
                -- pn 落进窗口时，跨度理论上已经 <= hi（pn=0.5 ⇔ span=2(tph-t0) <= hi），
                -- 但帧步进可能跨过 0.5，于是 span 略大于 hi —— 这时用 hi 居中（跳幅 <= 0.02*span）。
                -- 以前这里要求 sp_cur < hi 才进，跨过 0.5 的那一帧就把 sym_ready 设成 false，
                -- 之后再也不重试 ⇒ 用户看到“有概率不进入双动”（0~15@4 抓右圆几乎必现）。
                local sp_cur = math.min(g.t1 - g.t0, hi)
                if sp_cur >= minspan - 1e-9 then
                    local gl2, gr2 = TL.bar_geom(tph - sp_cur / 2, tph + sp_cur / 2, g.dur)
                    gr.sym_off = target - ((gr.kind == 'left') and gl2 or gr2)
                    gr.sym_ready = true
                    sym = sp_cur
                else
                    -- 保留 nil 让它下一帧继续重试；这里不能动 l0/r0，否则单动拖动会把锚点带着走
                    gr.sym_ready, gr.sym_off = nil, nil
                end
            elseif gr.sym_ready then
                local sp = TL.bar_solve_center(g.dur, tph, target - gr.sym_off, gr.kind)
                -- 对称解已经贴到片头/片尾（sp 触界）就退回单动：否则用户会被“两边一起卡住”锁死
                if sp and sp < hi - 1e-6 and (tph - sp / 2) >= -1e-9 and (tph + sp / 2) <= g.dur + 1e-9 then
                    sym = sp
                elseif TL.bar_geom then
                    -- 对称已经贴到片头/片尾：退回单动，并把锚点换成**当前**像素，别跳回抓起时的位置
                    gr.l0, gr.r0 = TL.bar_geom(g.t0, g.t1, g.dur)
                    gr.sym_ready, gr.sym_off = nil, nil
                end
            end
        else
            gr.sym_ready, gr.sym_off = nil, nil
        end
        gr.sym = (sym ~= nil)
        -- tl_ov_pin='px'：抓哪端，另一端就钉在抓起那一刻的像素上（Pr 实测口径），时间随之微调
        local pinpx = TL.bar_solve_px and feel ~= 'pr' and tostring(o.tl_ov_pin or 'px') == 'px' and gr.l0 and gr.r0
        -- Pr 口径：缩小只允许让播放头朝中点靠近。若抓的这一端会让播放头远离中点（上面判的 illegal），
        -- 就换成“抓另一端、鼠标位置镜像到区间另一侧”：被抓的那端钉住，另一端跟手移过来，
        -- 播放头随之逼近中点；到 p=0.5 后由上面的对称分支接管（两圆同时动）。
        local kind_eff, target_eff = gr.kind, target
        if illegal and gr.l0 and gr.r0 then
            kind_eff = (gr.kind == 'left') and 'right' or 'left'
            -- gr.l0/gr.r0 是归一化端点（0..1）；鼠标位置镜像到区间另一侧 = l0 + r0 - 鼠标归一化位置
            target_eff = math.max(0, math.min(1, gr.l0 + gr.r0 - (mx - g.x0) / math.max(1, g.rw)))
        end
        local pa, pb
        if pinpx and (kind_eff == 'left' or kind_eff == 'right') then
            local wmin = (minspan / g.dur) ^ (tonumber(o.tl_ov_pow) or 1.29)
            local anchor = kind_eff == 'right' and gr.l0 or gr.r0
            pa, pb = TL.bar_solve_px(g.dur, anchor, target_eff, kind_eff, wmin)
            if pa and not (pb - pa >= minspan - 1e-9 and pa >= -1e-9 and pb <= g.dur + 1e-9) then
                -- 时间越界：先看是**哪一端**出头，再按那一侧的贴边公式重解
                --   左端出头 ⇒ t0=0，宽度 = 右端的归一化位置（抓右端时右端跟手，否则用抓起时的锚 r0）
                --   右端出头 ⇒ t1=dur，宽度 = 1 - 左端的归一化位置（抓左端时左端跟手，否则用锚 l0）
                local pow = tonumber(o.tl_ov_pow) or 1.29
                local w
                if pa < -1e-9 then
                    w = (kind_eff == 'right') and target_eff or anchor
                    if w and w > 0 and w <= 1 then
                        local span = math.max(minspan, math.min(g.dur, (w ^ (1 / pow)) * g.dur))
                        pa, pb = 0, span
                    else pa = nil end
                elseif pb > g.dur + 1e-9 then
                    local lpos = (kind_eff == 'left') and target_eff or anchor
                    w = 1 - lpos
                    if w and w > 0 and w <= 1 then
                        local span = math.max(minspan, math.min(g.dur, (w ^ (1 / pow)) * g.dur))
                        pa, pb = g.dur - span, g.dur
                    else pa = nil end
                else
                    pa = nil
                end
            end
        end
        if sym then
            n0, n1 = tph - sym / 2, tph + sym / 2
        elseif pa then
            n0, n1 = math.max(0, pa), math.min(g.dur, pb)
        elseif gr.kind == 'left' then
            local e = TL.bar_solve(g.dur, gr.t1, target, 'left')
            if inr and feel == 'pr' then
                n0, n1 = tl_place(span0 - (e - gr.t0), 'left')
            else
                n0 = math.max(0, math.min(e, gr.t1 - minspan))
                n1 = gr.t1
                if inr and n0 > tph then n0 = math.max(0, math.min(tph, n1 - minspan)) end   -- 别让播放头掉出区间
            end
        elseif gr.kind == 'right' then
            local e = TL.bar_solve(g.dur, gr.t0, target, 'right')
            if inr and feel == 'pr' then
                n0, n1 = tl_place(span0 - (gr.t1 - e), 'right')
            else
                n1 = math.min(g.dur, math.max(e, gr.t0 + minspan))
                n0 = gr.t0
                if inr and n1 < tph then n1 = math.min(g.dur, math.max(tph, gr.t0 + minspan)) end
            end
        else
            local k = TL.bar_k(math.max(0, math.min(1, (gr.t1 - gr.t0) / math.max(1e-6, g.dur))))
            local x0m = ((gr.mx0 or mx) - g.x0) / math.max(1, g.rw)
            local half = (gr.t1 - gr.t0) / 2
            local mid = (((gr.t0 + gr.t1) / 2) / g.dur + (target - x0m) / k) * g.dur
            n0, n1 = mid - half, mid + half
            if n0 < 0 then n1, n0 = n1 - n0, 0 end
            if n1 > g.dur then n0, n1 = n0 - (n1 - g.dur), g.dur end
        end
    else
        local at = tl_ov_time(g, mx)
        if gr.kind == 'left' then
            n0 = math.max(0, math.min(at, gr.t1 - minspan))        -- 左圆跟鼠标，右端不动
            n1 = gr.t1
        elseif gr.kind == 'right' then
            n1 = math.min(g.dur, math.max(at, gr.t0 + minspan))    -- 右圆跟鼠标，左端不动
            n0 = gr.t0
        else
            local d = at - gr.base                                 -- 整段平移：相对抓起那一刻的位移
            n0, n1 = gr.t0 + d, gr.t1 + d
            if n0 < 0 then n1, n0 = n1 - n0, 0 end
            if n1 > g.dur then n0, n1 = n0 - (n1 - g.dur), g.dur end
        end
    end
    local c0, c1 = TL.t0 or 0, TL.t1 or g.dur                  -- 没变就别重绘（鼠标一动会来很多次）
    if math.abs(c0 - n0) < 1e-6 and math.abs(c1 - n1) < 1e-6 then return end
    tl_set_range(n0, n1, gr.kind == 'left' and '抓取左端' or (gr.kind == 'right' and '抓取右端' or '抓取平移'))
end

mp.observe_property('mouse-pos', 'native', function(_, p)
    if TL.grab and p and p.x and TL.geo then tl_grab_move(TL.geo, p.x) end
end)
mp.add_key_binding('ESC', 'tl-grab-cancel', function()
    if TL.grab then
        TL.abort('ESC')
    else
        mp.commandv('set', 'fullscreen', 'no')      -- ESC 在 mpv 里的默认行为，别被我们吃掉
    end
end)
mp.add_key_binding(nil, 'tl-drop', function() TL.drop('点击/按键') end)
-- 取证钩子：本机不能注入鼠标。tl-grab 指定抓哪端，tl-drag-n 按"概览条归一化位置 0..1"喂坐标
-- （归一化 ⇒ 探针不依赖窗口尺寸，--vo=null 无头也能跑）
mp.register_script_message('tl-grab', function(kind)
    local g = TL.geo
    if not g then return end
    local gl0, gr0
    if (o.tl_ov_map or 'linear') == 'bar' and TL.bar_geom then gl0, gr0 = TL.bar_geom(g.t0, g.t1, g.dur) end
    local tph0 = tonumber(mp.get_property_number('time-pos'))
    local p00 = (tph0 and tph0 > g.t0 + 1e-9 and tph0 < g.t1 - 1e-9) and (tph0 - g.t0) / (g.t1 - g.t0) or nil
    TL.grab = { kind = kind, t0 = g.t0, t1 = g.t1, base = tl_ov_time(g, g.x0 + g.rw / 2), mx0 = g.x0 + g.rw / 2, l0 = gl0, r0 = gr0, tph = tph0, p0 = p00 }
    tl_grab_sections(true)
    msg.verbose('时间轴·抓起（取证）' .. tostring(kind))
end)
mp.register_script_message('tl-drag-n', function(u)
    local g = TL.geo
    if TL.grab and g then tl_grab_move(g, g.x0 + math.max(0, math.min(1, tonumber(u) or 0.5)) * g.rw) end
end)
mp.register_script_message('tl-drag', function(x)
    if TL.grab and TL.geo then tl_grab_move(TL.geo, tonumber(x)) end
end)

local function tl_click(fx, fy, forced_dbl)
    local g = TL.geo
    if not g then return end
    if TL.grab then                     -- 抓手进行中点时间轴 = 放下（真机路径已被整窗区域接管，这里是兜底 + 测试钩子）
        TL.drop('点击')
        return
    end
    local mx, my = fx, fy
    if not mx then
        local p = mp.get_property_native('mouse-pos')
        if not (p and p.x) then return end
        mx, my = p.x, p.y
    end
    local now = mp.get_time()
    local dbl = forced_dbl or ((now - TL_LAST.t < 0.40) and math.abs(mx - TL_LAST.x) <= 14)
    TL_LAST.t, TL_LAST.x = (dbl and -10 or now), mx     -- 真双击事件来了就把计时器清零，别触发两次

    local function seek_frame(tt, why)
        local fr = math.floor(tt * g.fps + 1e-6)         -- 与"吸帧"同一口径：跳到帧起点
        if fr < 0 then fr = 0 end
        local st = fr / g.fps
        if st > g.dur then st = g.dur end
        mp.set_property_number('time-pos', st)
        local tc0 = os.clock()
        render_timeline()                        -- 立刻重绘，不等 time-pos 观察者（否则最坏多等一个节流周期）
        msg.verbose(string.format('时间轴·%s → %.3f（帧 %d）｜重绘 %.1f ms', why, st, fr, (os.clock() - tc0) * 1000))
    end

    -- ① 两端时间码那一行：点左框改起点、点右框改终点（Pr 是点它自己输入跳转）
    if my >= g.y_tc - 2 and my <= g.y_tc + g.h_tc + 2 then
        local side
        if mx <= g.x0 + g.w_l + 4 then side = 'left'
        elseif mx >= g.x1 - g.w_r - 4 then side = 'right' end
        if side then
            local def = to_timecode(side == 'left' and g.t0 or g.t1, g.fps)
            msg.verbose(string.format('时间轴·打开时间码输入框（%s端 %s）',
                side == 'left' and '左' or '右', def))
            ask_text('跳到时间码（Pr 式：2200 = 22s0f；也认 00:00:22:00 / 22.5）', def, function(str)
                if not str then return end                     -- ESC 关掉输入框 = 不改
                local v = TL.parse_tc(str, g.fps)
                if v == nil then notify('时间码看不懂：' .. str) return end
                seek_frame(v, '输入' .. (side == 'left' and '左' or '右') .. '端时间码')
            end)
        end
        return
    end

    -- ② 刻度带：单击跳到该处（吸到帧头），双击回整片
    if my >= g.y_lab - 2 and my <= g.rl_y + 1 then
        if dbl then tl_reset('双击刻度带') return end
        seek_frame(g.t0 + (mx - g.x0) / math.max(1, g.rw) * g.span, '点击刻度带')
        return
    end

    -- ③ 概览条（基线下方）：抓起 / 放下
    if my > g.rl_y + 1 then
        if TL.grab then
            msg.verbose('时间轴·放下（' .. TL.grab.kind .. '）')
            TL.grab = nil
            render_timeline()
        else
            tl_grab_start(g, mx)
        end
        return
    end
end

-- mbtn_left_dbl 也绑进我们这块区域：mpv 默认"双击 = 切全屏"，不挡掉的话双击回整片会顺带切全屏（用户实测）
mp.commandv('define-section', TL_SEC,
    'mbtn_left script-binding ' .. BIND_PREFIX .. 'tl-click\n' ..
    'mbtn_left_dbl script-binding ' .. BIND_PREFIX .. 'tl-dbl', 'force')
-- 抓手期间的两个"逃生门"（只在抓取中 enable）
mp.commandv('define-section', TL_ANY, 'mbtn_left script-binding ' .. BIND_PREFIX .. 'tl-drop', 'force')
mp.commandv('define-section', TL_KEYSEC,
    'SPACE script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'ENTER script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'LEFT script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'RIGHT script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'UP script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'DOWN script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'PGUP script-binding ' .. BIND_PREFIX .. 'tl-drop\n' ..
    'PGDWN script-binding ' .. BIND_PREFIX .. 'tl-drop', 'force')
mp.add_key_binding(nil, 'tl-click', tl_click)
-- 双击：mpv 默认"双击 = 切全屏"。上次试的"用脚本绑定盖住它"你复验仍然切全屏（脚本 section 盖不住
-- mbtn_left_dbl 的默认绑定）⇒ 改成直接改 default section 那条：双击不再切全屏，**全屏改按 F11**（mpv 自带的 `f` 也还在）。
-- "双击回整片"由 tl-click 里的计时判定负责（两次单击 ≤0.40s），不依赖 mbtn_left_dbl。
mp.commandv('keybind', 'MBTN_LEFT_DBL', 'ignore')
mp.add_key_binding('F11', 'tl-fullscreen', function() mp.commandv('cycle', 'fullscreen') end)
mp.add_key_binding('MBTN_LEFT_DBL', 'tl-dbl', function()      -- 兜底：万一哪台机器还能收到，只负责结束抓取
    if TL.grab then TL.drop('双击') end
end)
-- 自动化取证钩子：tl-hit 用给定坐标走一遍点击（本机不能注入鼠标）；tl-goto 直接按时间码跳
mp.register_script_message('tl-hit', function(x, y)
    tl_click(tonumber(x), tonumber(y))
end)
mp.register_script_message('tl-goto', function(str)
    local g = TL.geo
    if not g then return end
    local v = TL.parse_tc(str, g.fps)
    if v == nil then msg.verbose('时间轴·时间码看不懂：' .. tostring(str)) return end
    local fr = math.floor(v * g.fps + 1e-6)
    mp.set_property_number('time-pos', fr / g.fps)
    msg.verbose(string.format('时间轴·输入 %s → %.3f（帧 %d）', str, fr / g.fps, fr))
end)

-- 自动化取证：tl-wheel-at x y dir —— 用给定坐标走一遍滚轮（本机不能注入鼠标）
mp.register_script_message('tl-wheel-at', function(x, y, dir)
    TL_WHEEL_POS = { x = tonumber(x), y = tonumber(y) }
    local ok, err = pcall(tl_wheel, tonumber(dir) or 1)
    TL_WHEEL_POS = nil
    if not ok then log('时间轴·滚轮取证失败：%s', tostring(err)) end
end)

-- 调参钩子（运行时立即生效，不用重启；想长期保留就写进 source-markers.conf）：
--   tl-steps 1.003,1.001,1.01 ｜ tl-anchor pr|head [拉力] ｜ tl-ov linear|sqrt
mp.register_script_message('tl-steps', function(str)
    local a, b, c = tostring(str or ''):match('([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)')
    if a and b and c then
        TL_STEP.plain, TL_STEP.ctrl, TL_STEP.shift = tonumber(a), tonumber(b), tonumber(c)
        log('时间轴·滚轮步长 → %s / %s / %s', tostring(TL_STEP.plain), tostring(TL_STEP.ctrl),
            tostring(TL_STEP.shift))
    end
end)
mp.register_script_message('tl-anchor', function(mode, pull)
    local m = tostring(mode)
    o.tl_zoom_anchor = (m == 'center' or m == 'pr' or m == 'snap') and m or 'head'
    if tonumber(pull) then o.tl_zoom_pull = tonumber(pull) end
    log('时间轴·缩放锚点 → %s（拉力 %s）', tostring(o.tl_zoom_anchor), tostring(o.tl_zoom_pull))
end)
mp.register_script_message('tl-ov', function(mode, p)
    local m = tostring(mode)
    if m == 'linear' or m == 'sqrt' or m == 'pow' or m == 'bar' then o.tl_ov_map = m end
    if tonumber(p) then o.tl_ov_pow = tonumber(p) end
    log('时间轴·概览映射 → %s（pow 指数 %s）', tostring(o.tl_ov_map), tostring(o.tl_ov_pow))
    render_timeline()
end)
-- 自动化取证：tl-follow off|pr|page|center [时间] [1=当作播放中] —— 切模式 → 跳时间 → 走一遍跟随判定
mp.register_script_message('tl-follow', function(mode, t, playing)
    local m = tostring(mode or '')
    if m == 'off' or m == 'pr' or m == 'page' or m == 'center' then o.tl_play_follow = m end
    if tonumber(t) then mp.set_property_number('time-pos', tonumber(t)) end
    log('时间轴·跟随模式 → %s（样本 %s，播放中=%s）', tostring(o.tl_play_follow), tostring(t), tostring(playing))
    tl_play_follow_check('取证', playing == '1')
end)

-- 每次重绘摆好可点区域；时间轴隐藏时清空（与 bar_sections_off 同一套做法）
TL.place = function(g)
    TL.geo = g
    if g then
        mp.set_mouse_area(g.x0 - 2, g.y_tc - 2, g.x1 + 4, g.y_ov + g.h_ov + 2, TL_SEC)
        mp.commandv('enable-section', TL_SEC)
    else
        mp.set_mouse_area(0, 0, 0, 0, TL_SEC)
        mp.commandv('disable-section', TL_SEC)
    end
end

-- 对外接口：第 9 条 r46 的点击/拖动（下一小步）与自动化测试都从这里调用
TL.zoom, TL.pan, TL.reset = tl_zoom, tl_pan, tl_reset
TL.set_range, TL.min_span, TL.clamp_range = tl_set_range, tl_min_span, tl_clamp_range
TL.follow = tl_play_follow_check
TL.ACTIONS = TL_ACTIONS
TL.STEP = TL_STEP
end
tl_init()

-- 第 9 条：内置 OSC 跟随样式 —— 老样式（按钮面板）要 mpv 自带的底部播放条；
-- Pr 风格（控制栏 + 时间轴）用我们自己的，就把内置 OSC 关掉。
-- 实测：`set osc no/yes` 能在运行时卸载/加载 @osc.lua（日志有 Unloading/Loading script @osc.lua），
-- 所以不用重启 mpv。老面板本来就带 osc_safe_margin（当年为躲 OSC 做的避让）⇒ 正好回到它的设计环境。
local function apply_osc_for_style()
    local want = (UI.style == 'prbar') and 'no' or 'yes'
    if mp.get_property('osc') ~= want then
        mp.set_property('osc', want)
        log('内置 OSC → %s（当前样式 %s）', want, UI.style)
    end
end

-- 两种样式各自"是否显示"；打开一个就关掉另一个（互斥只在这一处定义）
local function ui_style_shown(style)
    return (style == 'prbar') and UI.bar or UI.panel
end
local function ui_set_shown(style, on)
    if style == 'prbar' then
        UI.bar = on and true or false
        if UI.bar then UI.panel = false end
    else
        UI.panel = on and true or false
        if UI.panel then UI.bar = false end
    end
end

local function toggle_panel(state)
    local style = (UI.style == 'prbar') and 'prbar' or 'panel'
    local on = (state == nil) and (not ui_style_shown(style)) or (state == true)
    ui_set_shown(style, on)
    render_panel()
    render_prbar()
    render_timeline()
    if save_ui_state then save_ui_state() end      -- 快捷键 / 按钮 / 脚本消息，任何路径都立即落盘
    if on then
        if style == 'prbar' then
            notify('Pr 风格控制栏已打开（' .. key_of('switch-osd') .. ' 换回按钮面板，'
                .. key_of('toggle-panel') .. ' 关闭）')
        else
            notify('按钮面板已打开：所有功能都能点（' .. key_of('toggle-panel') .. ' 关闭，'
                .. key_of('help') .. ' 帮助）')
        end
    else
        notify((style == 'prbar' and '控制栏' or '按钮面板') .. '已关闭')
    end
end

-- 第 8 条：F3 —— 在两种 OSD 样式之间切换（切完立即显示）
local function switch_osd_style()
    UI.style = (UI.style == 'prbar') and 'panel' or 'prbar'
    ui_set_shown(UI.style, true)
    apply_osc_for_style()          -- 换样式 = 连内置播放条一起换（老样式要 OSC，Pr 风格不要）
    render_panel()
    render_prbar()
    render_timeline()
    -- 状态机必须把"切到哪"打进日志（否则"没反应"和"切错了"分不清）
    log('OSD 样式切换 → %s（panel=%s bar=%s）', UI.style, tostring(UI.panel), tostring(UI.bar))
    if save_ui_state then save_ui_state() end
    if UI.style == 'prbar' then
        notify('OSD 样式：Pr 风格控制栏（' .. key_of('toggle-panel') .. ' 显示/隐藏，'
            .. key_of('switch-osd') .. ' 换回按钮面板）')
    else
        notify('OSD 样式：按钮面板（' .. key_of('toggle-panel') .. ' 显示/隐藏，'
            .. key_of('switch-osd') .. ' 换成 Pr 风格控制栏）')
    end
end

local function toggle_help(state)
    show_help(state)
    if save_ui_state then save_ui_state() end
    if UI.help then notify('帮助已显示（' .. key_of('help') .. ' 关闭；' .. key_of('toggle-panel') .. ' 打开按钮面板）') end
end

-- ============================== 标记模式（1.2.0「交织」③） ==============================
-- F10 开关；开启后接管四个裸键，向 Pr 源监视器看齐：
--   M            在当前播放头打标记   （Pr：添加标记）
--   Shift+M      跳到下一个标记
--   Ctrl+Shift+M 跳到上一个标记
--   Del          删除播放头处的标记
-- 为什么做成"模式"：mpv 里裸字母都被它自己占了（m=静音 等），而真机实测 ——
-- mp.add_key_binding 的绑定【能盖过 mpv 内置绑定】，但【用户自己的 input.conf 优先级更高】。
-- 所以既有快捷键（Ctrl+m 等）与 F2 按钮面板一律保留：模式被占也还有保底路径。
local MODE_KEYS = {
    { key = 'm',            name = 'add',            label = '打标记' },
    { key = 'Shift+m',      name = 'next',           label = '下一个标记' },
    { key = 'Ctrl+Shift+m', name = 'prev',           label = '上一个标记' },
    -- 向 Pr 源监视器看齐：Enter = 从入点播放（原本占这个键的「改正文」已移到 Shift+Enter）
    { key = 'ENTER',       name = 'play-in',         label = '从入点播放' },
    { key = 'Shift+i',     name = 'in-set',          label = '设入点' },
    { key = 'Shift+o',     name = 'out-set',         label = '设出点' },
    -- 清除出入点：Ctrl+Shift+X 与 Pr 一致；另给 Shift+DEL 作别名
    -- （字母键的 Shift 会被 mpv 折叠进大写，注入/键盘的边界情况多，双保险）
    { key = 'Ctrl+Shift+x', name = 'inout-clear',    label = '清除出入点' },
    { key = 'Shift+DEL',    name = 'inout-clear',    label = '清除出入点（同上）' },
}

local EDIT_KEYS = {
    { key = 'LEFT',        name = 'edit-back1',      label = '-1 帧' },
    { key = 'RIGHT',       name = 'edit-fwd1',       label = '+1 帧' },
    { key = 'SHIFT+LEFT',  name = 'edit-back10',     label = '-10 帧' },
    { key = 'SHIFT+RIGHT', name = 'edit-fwd10',      label = '+10 帧' },
    -- 备选：与 mpv 自带的逐帧键习惯一致（字符键的送达比方向键更可靠）
    { key = ',',         name = 'edit-back1',      label = '-1 帧' },
    { key = '.',         name = 'edit-fwd1',       label = '+1 帧' },
    { key = '[',         name = 'edit-back10',     label = '-10 帧' },
    { key = ']',         name = 'edit-fwd10',      label = '+10 帧' },
    -- 颜色索引跟格式契约一致：0..7（0=绿 1=红 2=紫 3=橙 4=黄 5=白 6=蓝 7=青）
    { key = '0', name = 'edit-c0' }, { key = '1', name = 'edit-c1' },
    { key = '2', name = 'edit-c2' }, { key = '3', name = 'edit-c3' },
    { key = '4', name = 'edit-c4' }, { key = '5', name = 'edit-c5' },
    { key = '6', name = 'edit-c6' }, { key = '7', name = 'edit-c7' },
    { key = 't',     name = 'edit-text-t',     label = '改正文' },
    { key = 'SHIFT+ENTER', name = 'edit-text-enter', label = '改正文' },
    { key = 'DEL',   name = 'del-current',     label = '删除（模式=最近 / 编辑=这条）' },
    { key = 'ESC',   name = 'edit-exit',       label = '完成' },
}
local overlay_mode = new_overlay()

-- 注册时【一次性】把模式键与编辑键都绑上，运行时按状态路由。
-- 不在这里来回增删绑定：从某个键自己的回调里 remove 掉它自己，会让后续 add 的绑定整体失效
-- （真机现象：进编辑态后 16 个新绑定一个都不响应；对照：同一段代码在模式里工作正常）。
local EDIT_ACTION, MODE_ACTION = {}, {}
for _, spec in ipairs(EDIT_KEYS) do EDIT_ACTION[spec.name] = true end
for _, spec in ipairs(MODE_KEYS) do MODE_ACTION[spec.name] = true end
-- Enter 一个键两种行为：不在编辑态=进编辑态；已在编辑态=改正文（所以它两边都要可用）
MODE_ACTION['edit-text-enter'] = true
MODE_ACTION['play-in'] = true            -- Enter：模式态=从入点播放（编辑态里 Enter 交给 mpv 输入框提交）
MODE_ACTION['in-set'] = true
MODE_ACTION['out-set'] = true
MODE_ACTION['inout-clear'] = true
MODE_ACTION['del-current'] = true        -- 模式态=删最近的标记；编辑态=删这一条

-- 模式态下的方向键：按【mpv 默认】前后跳（用户真机明确要求）。
-- 为什么需要显式做：模式开启时插件把编辑键也绑上了（LEFT → edit-back1，prio 38），
-- 已经盖过 mpv 默认的 seek，但模式态的路由只认 MODE_ACTION ⇒ 不显式处理就是"什么都没发生"。
-- 编辑态（Shift+Enter）里这四个动作仍是"挪标记"，两者按状态分流。
local MODE_ARROW_SEEK = {
    ['edit-back1']  = { '-5', 'relative' },        -- 对应 mpv 默认 LEFT
    ['edit-fwd1']   = { '5',  'relative' },        -- 对应 mpv 默认 RIGHT
    ['edit-back10'] = { '-1', 'relative+exact' },  -- 对应 mpv 默认 SHIFT+LEFT
    ['edit-fwd10']  = { '1',  'relative+exact' },  -- 对应 mpv 默认 SHIFT+RIGHT
}

local function mode_dispatch(name)
    local fn = HANDLERS[name]
    if not fn then msg.warn('标记模式：找不到动作 ' .. tostring(name)); return end
    local editing = UI.edit ~= nil

    if editing then
        if EDIT_ACTION[name] then
            msg.verbose('编辑态按键 → ' .. tostring(name))
            fn()
        else
            msg.verbose('编辑态按键 → 忽略（模式键 ' .. tostring(name) .. '）')
        end
        return
    end
    local sk = MODE_ARROW_SEEK[name]
    if sk then
        msg.verbose('标记模式按键 → ' .. tostring(name) .. '（按 mpv 默认前后跳）')
        mp.commandv('seek', sk[1], sk[2])
        log('模式态方向键 → seek %s %s（与 mpv 默认一致）', sk[1], sk[2])
        return
    end
    if MODE_ACTION[name] then
        msg.verbose('标记模式按键 → ' .. tostring(name))
        fn()
    end
end
-- 开=逐个 add_key_binding，关=逐个 remove_key_binding。
-- 选这条而不是 section API，是因为**真机实测**过：add_key_binding 的绑定能盖过 mpv 内置键，
-- 而 section 那套在本机 mpv 上按 m 没有任何反应（同一个键、两种机制，行为不同）。
-- 另外 add_key_binding 的返回值在旧 mpv 上是 nil，所以不能用 返回值:disable() 那套。
local function mode_bindings_apply(on)
    local n = 0
    local all = {}
    for _, spec in ipairs(MODE_KEYS) do all[#all + 1] = spec end
    for _, spec in ipairs(EDIT_KEYS) do all[#all + 1] = spec end
    for _, spec in ipairs(all) do
        -- 绑定名必须【每个键唯一】：同一个动作可以有多个键（例如 edit-back1 = LEFT 和 ,），
        -- 若只用 spec.name 做绑定名，后注册的会【静默替换】前一个 —— 真机后果是
        -- 编辑态里方向键被 , . [ ] 顶掉、从来没生效过（本会话查 Shift 键问题时才发现）。
        local keytag = tostring(spec.key):gsub('[^%w]', '')
        local bname = 'source-markers-mode-' .. spec.name .. '-' .. keytag
        spec.default_key = spec.default_key or spec.key
        local ekey = eff_key(spec.name, spec.default_key)   -- 第 5 条：覆盖表可以改键或禁用
        if on and ekey then
            -- 每个键单独 pcall：某个键名若不被 mpv 接受，不至于拖垮整批；失败会写进日志（便于诊断）
            local ok, err = pcall(mp.add_key_binding, ekey, bname,
                                  function() mode_dispatch(spec.name) end)
            if ok then n = n + 1
            else log('绑定失败：key=%s name=%s err=%s', tostring(spec.key), bname, tostring(err)) end

        elseif type(mp.remove_key_binding) == 'function' then
            pcall(mp.remove_key_binding, bname)
            n = n + 1
        end
    end
    log('标记模式绑定：%s（处理 %d 个键；remove_key_binding=%s）',
        on and '已启用' or '已关闭', n, tostring(type(mp.remove_key_binding)))
end
local function edit_tc(t)
    if not t then return "--:--:--:--" end
    local fps = get_fps() or 25
    local whole = math.floor(t)
    local fr = math.floor((t - whole) * fps + 0.5)
    if fr >= math.max(1, math.floor(fps)) then fr = 0 whole = whole + 1 end
    return string.format('%s:%02d', os.date('!%H:%M:%S', whole), fr)
end
local function render_mode_badge()
    local w, h = osd_size()
    if (not UI.mode and not UI.edit) or not w or not h then
        set_overlay(overlay_mode, nil, w, h)
        return
    end
    local size = math.max(14, math.floor(ui_font() * 0.85))
    local rows = { '标记模式　F10 退出' }
    -- 出入点常驻显示（区间"保留"必须看得见；武装中额外标出）
    if IN_FRAME or OUT_FRAME then
        rows[#rows + 1] = inout_summary() .. (RANGE_ARMED and '　▶ 区间播放中' or '')
    end
    local accent = '&H4DE0FF&'
    if UI.edit then
        local m = UI.edit
        local body = (m.comment and m.comment ~= '') and m.comment or '（空）'
        rows = {
            string.format('编辑标记 %s · 颜色 %s · 正文「%s」', edit_tc(m.t), color_name(m.color or 0), body),
            '移动：, / . ±1帧 · [ / ] ±10帧 · 颜色：0-7 改【这条】(0=绿 … 7=青) · T/Shift+Enter 改正文 · DEL 删除 · ESC 完成',
        }
        accent = '&H7CFF7C&'
    end
    local unit_budget = math.max(16, math.floor((w - 90) / size))
    local rows2 = {}
    for _, r in ipairs(rows) do
        for _, part in ipairs(wrap_visual(r, unit_budget)) do rows2[#rows2 + 1] = part end
    end
    local maxb = 0
    for _, r in ipairs(rows2) do maxb = math.max(maxb, #r) end
    local lh = math.floor(size * 1.25)
    local bw = math.min(w - 40, math.floor(maxb * size * 0.72) + 20)
    local bh = lh * #rows2 + 12
    local x = math.max(SIDE_PADDING, w - bw - 24)
    -- 第 8 条：控制栏占着底部中间 —— 徽标与它水平重叠时抬到栏上方，别叠在一起
    local lift = 0
    if UI.bar and UI.style == 'prbar' then
        local m = prbar_metrics()
        if x < m.x + m.bar_w then lift = m.bar_h + 10 end
    end
    local y = math.max(SIDE_PADDING, h - bh - 24 - lift)
    local lines = { rect_line(x, y, bw, bh, '&H000000&', '80') }
    for i, r in ipairs(rows2) do
        lines[#lines + 1] = text_line(x + 9, y + 6 + (i - 1) * lh, size, accent, r, true)
    end
    set_overlay(overlay_mode, lines, w, h)
end

-- ── 编辑态（B）：在标记模式里按 Enter，编辑播放头处那条标记 ─────────────
-- 进态时把播放头吸到那条标记上（对应 Pr 里「双击标记跳过去」）；每次改动立即落盘。
-- 语义区分：编辑态里的 1-8 改【这一条】的颜色；Ctrl+1..8 改的是「下一条新标记用什么色」。

local function edit_bindings_apply(on)
    local n = 0
    for _, spec in ipairs(EDIT_KEYS) do
        local bname = 'source-markers-edit-' .. spec.name
        if on then
            mp.add_key_binding(spec.key, bname, function() mode_dispatch(spec.name) end)
            n = n + 1
        elseif type(mp.remove_key_binding) == 'function' then
            mp.remove_key_binding(bname)
            n = n + 1
        end
    end
    log('编辑态绑定：%s（处理 %d 个键）', on and '已启用' or '已关闭', n)
end

local function edit_follow()
    local m = UI.edit
    if m then mp.commandv('seek', string.format('%.3f', m.t), 'absolute+exact') end
end


local function edit_exit(quiet)
    if not UI.edit then return end
    UI.edit = nil                        -- 键位不动，回到模式路由
    render_mode_badge()
    if not quiet then notify(UI.mode and '已退出编辑态（仍在标记模式）' or '已退出编辑态') end
end

local function edit_enter()
    if not UI.mode then notify('先按 F10 进标记模式，再用 Enter 编辑'); return end
    if UI.edit then notify('已经在编辑态：Esc 完成'); return end
    local idx = nearest_index()
    if not idx then
        notify(string.format('附近 %g 秒内没有标记（想新建按 M）', NEAREST_WINDOW))
        return
    end
    local m = S.markers[idx]
    UI.edit = m                          -- 键位不动：路由会切到编辑态
    edit_follow()
    render_mode_badge()
    log('进入编辑态：t=%.3f color=%s comment=%s', m.t, tostring(m.color), tostring(m.comment))
    notify(string.format('编辑标记 %s · 0-7 改这条的颜色 · T/Shift+Enter 改正文 · ESC 完成', edit_tc(m.t)))
end

-- 打开"指定那一条"的编辑态（edit_enter 找的是播放头附近那条；这里要精确到某一帧的那条）
local function edit_enter_marker(m)
    UI.edit = m
    edit_follow()
    render_mode_badge()
    log('进入编辑态（同帧已有标记）：t=%.3f color=%s comment=%s', m.t, tostring(m.color), tostring(m.comment))
    notify(string.format('这一帧已有标记 → 直接编辑它 %s · 0-7 改色 · T/Shift+Enter 改正文 · ,/. 挪帧 · ESC 完成',
        edit_tc(m.t)))
end

local function edit_move(frames)
    local m = UI.edit
    if not m then return end
    local fps = get_fps() or 25
    local nt = m.t + frames / fps
    if nt < 0 then nt = 0 end
    local other = marker_at_same_frame(nt)
    if other and S.markers[other] ~= m then
        notify('那一帧已经有标记了（同一帧只能有一条）—— 没动')
        return
    end
    m.t = nt
    m.tc = edit_tc(nt)
    sort_markers()
    save_sidecar()
    edit_follow()
    render_mode_badge()
    -- msg.* 不做 printf（实测会把 %+d 原样打出来）→ 用 log() 助手（内部 string.format）
    log('编辑态：移动 %+d 帧 → t=%.3f（%s）', frames, nt, m.tc)
    notify(string.format('标记 → %s', m.tc))
end

local function edit_set_color(i)
    local m = UI.edit
    if not m then return end
    m.color = i
    save_sidecar()
    render_mode_badge()
    notify(string.format('这条标记的颜色 → %s', color_name(i)))
end

local function edit_text()
    local m = UI.edit
    if not m then return end
    ask_text('这条标记的正文', m.comment or '', function(text)
        if text == nil then return end
        if UI.edit ~= m then return end
        m.comment = trim(text)
        save_sidecar()
        render_mode_badge()
        notify('正文已改：' .. ((m.comment ~= '') and m.comment or '（空）'))
    end)
end

local function edit_delete()
    local m = UI.edit
    if not m then return end
    for i, x in ipairs(S.markers) do
        if x == m then table.remove(S.markers, i) break end
    end
    UI.edit = nil
    save_sidecar()
    render_mode_badge()
    notify('已删除这条标记')
end

local function color_handler(i) return function() edit_set_color(i) end end
HANDLERS['edit-exit']       = function() edit_exit(false) end
HANDLERS['edit-back1']      = function() edit_move(-1) end
HANDLERS['edit-fwd1']       = function() edit_move(1) end
HANDLERS['edit-back10']     = function() edit_move(-10) end
HANDLERS['edit-fwd10']      = function() edit_move(10) end
for i = 0, 7 do HANDLERS['edit-c' .. i] = color_handler(i) end
-- 【步骤 1 占位】Enter = 从入点播放：真正的区间播放与出入点在步骤 2/3 接入；
-- 先只提示，用来验证键位本身（Enter 已从「改正文」腾出来交给播放）。
HANDLERS['in-set']      = set_in_point
HANDLERS['out-set']     = set_out_point
HANDLERS['inout-clear'] = clear_inout
HANDLERS['play-in'] = play_from_in
HANDLERS['edit-text-t']     = edit_text
-- Enter：不在编辑态就进编辑态，已在编辑态就改正文（只绑一个键，避免后注册覆盖前注册）
HANDLERS['edit-text-enter'] = function()
    if UI.edit then edit_text() else edit_enter() end
end
-- DEL 只绑一次（绑两次会被后注册的覆盖，ENTER 就是这么坏掉的）：
-- 不在编辑态时等价于原来的"删最近的标记"，在编辑态时删当前这条。
HANDLERS['del-current'] = function()
    if UI.edit then edit_delete() else delete_nearest() end
end

-- ── 第 8 条 步骤 3：控制栏按钮的鼠标点击 ──────────────────────────────
-- 与旧面板同一套机制（每个按钮一个 section、里面 mbtn_left 指向一个 script-binding）。
-- 这里每个按钮注册一个**无键绑定**：mp.add_key_binding 的 key 传 nil ⇒ 只能被
-- script-binding 触发，**不占任何键**，也不出现在帮助 / 面板 / 键位表里。
local function bar_run(name)
    local fn = HANDLERS[name]
    if not fn then msg.warn('控制栏：找不到动作 ' .. tostring(name)); return end
    log('控制栏点击 → %s', tostring(name))
    fn()
end

-- 「转到入/出点」「前后一帧」「播放/暂停」在标记模式里才有键位，而控制栏是常显的 ⇒ 补等价动作
HANDLERS['goto-in'] = function()
    if not IN_FRAME then notify('还没有入点（Shift+I 设入点）'); return end
    seek_to(frame_seconds(IN_FRAME))
    log('控制栏：转到入点 帧 %d t=%.3f', IN_FRAME, frame_seconds(IN_FRAME))
end
HANDLERS['goto-out'] = function()
    if not OUT_FRAME then notify('还没有出点（Shift+O 设出点）'); return end
    seek_to(frame_seconds(OUT_FRAME))
    log('控制栏：转到出点 帧 %d t=%.3f', OUT_FRAME, frame_seconds(OUT_FRAME))
end
HANDLERS['back1'] = function() mp.commandv('frame-back-step') end
HANDLERS['fwd1']  = function() mp.commandv('frame-step') end
HANDLERS['play']  = function() mp.commandv('cycle', 'pause') end

-- 第 8 条 步骤 4：截取当前帧（Pr 的相机按钮）—— 存到素材同目录的 `截图\` 下，**不带 OSD**
local function shot_timecode(t)
    local ms = math.floor((t - math.floor(t)) * 1000 + 0.5)
    local sec = math.floor(t)
    return string.format('%02d.%02d.%02d.%03d', math.floor(sec / 3600),
        math.floor(sec % 3600 / 60), sec % 60, ms)
end

local function shot_frame()
    local t = head_time()
    if not t then notify('还没有打开文件'); return end
    local path = mp.get_property('path')
    if not is_local_file(path) then notify('截取当前帧：只支持本地文件'); return end
    local dir = dir_of(path)
    if not dir then notify('截取当前帧：拿不到素材目录'); return end
    local outdir = dir .. '\\截图'
    ensure_dir(outdir)
    local stem = string.format('%s-%s', base_of(path), shot_timecode(t))
    local target = outdir .. '\\' .. stem .. '.png'
    local n = 1
    while file_exists(target) and n < 999 do
        n = n + 1
        target = string.format('%s\\%s-%d.png', outdir, stem, n)
    end
    -- 'video' = 只要画面：**不带字幕 / 不带 OSD**
    -- （不给 flags 时 mpv 默认按 subtitles 处理，会把 OSD 一起烤进图里）
    mp.commandv('screenshot-to-file', target, 'video')
    log('截取当前帧：t=%.3f → %s', t, target)
    -- 截图是异步的：等文件真落盘再报路径（否则又成了"发出去就算成功"）
    mp.add_timeout(0.7, function()
        if file_exists(target) then
            notify('已截取当前帧：' .. target)
            log('截取当前帧完成：%s', target)
        else
            notify('截取当前帧失败（没找到产物）：' .. target)
            msg.warn('截取当前帧失败：' .. target)
        end
    end)
end
HANDLERS['shot'] = shot_frame
-- 控制栏最左那对"跳标记"：复用既有的 step_marker（与 Alt+n/Alt+p、Shift+M/Ctrl+Shift+M 同一套逻辑）
HANDLERS['prev-marker'] = function() step_marker(-1) end
HANDLERS['next-marker'] = function() step_marker(1) end

for _, spec in ipairs(PRBAR_BTN) do
    local ok, err = pcall(mp.add_key_binding, nil, 'bar-' .. spec.name,
        function() bar_run(spec.name) end)
    if not ok then
        msg.warn(string.format('控制栏按钮绑定失败（bar-%s）：%s', spec.name, tostring(err)))
    end
end

local function set_marker_mode(on, quiet)
    UI.mode = (on == nil) and (not UI.mode) or (on == true)
    if not UI.mode and UI.edit then edit_exit(true) end      -- 关模式就别留着编辑态
    mode_bindings_apply(UI.mode)
    render_mode_badge()
    if not quiet then
        if UI.mode then
            notify('标记模式：M 打标记 · Shift+M 下一个 · Ctrl+Shift+M 上一个 · Del 删除 · Enter 从入点播放 · Shift+I/O 设出入点 · Shift+DEL 清除 · F10 退出')
        else
            notify('已退出标记模式')
        end
    end
    if save_ui_state then save_ui_state() end
end

-- 与 Pr 一致：在**已有标记**的位置按「打标记」→ 不打新的，而是**打开这一条的编辑**
-- （Pr 里按 M 落在已有标记上就是弹它的编辑框）。键位 M / Ctrl+m / 面板按钮 / 控制栏第一个按钮
-- 全都走 HANDLERS['add']，所以只改注册处那一行即可覆盖四条路径。
local function add_or_edit()
    local t = head_time()
    local idx = t and marker_at_same_frame(t) or nil
    if not idx then
        add_marker(nil)
        return
    end
    local m = S.markers[idx]
    if UI.edit == m then
        notify('已经在编辑这一条：ESC 完成')
        return
    end
    if not UI.mode then
        set_marker_mode(true, true)      -- 编辑态要靠标记模式的键位接管（quiet：下面统一提示）
    end
    edit_enter_marker(m)
end



-- 面板 / 帮助 / 标记模式徽标的重绘入口：给「改了状态但没经过鼠标事件」的路径用（例如切换颜色）
redraw_ui = function()
    if UI.panel then render_panel() end
    if UI.bar then render_prbar() end
    render_timeline()
    if UI.help then show_help(true) end
    render_mode_badge()
end

-- 悬停高亮：鼠标位置变化时只重绘必要的部分
local hover_pending = false
local MOUSE_LOG_AT, MOUSE_LAST = 0, { -1, -1 }
local function on_mouse_pos(_, pos)
    if (not UI.panel and not UI.bar) or type(pos) ~= 'table' then return end
    local mx, my = tonumber(pos.x) or 0, tonumber(pos.y) or 0
    local hit = nil
    local lists = UI.bar and PRBAR_BUTTONS or PANEL_BUTTONS
    for _, b in ipairs(lists) do
        if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then hit = b.name break end
    end
    -- 诊断：鼠标位置只要动了就记一行（0.25s 节流）—— 鼠标类问题只能靠这条中间量
    local now = os.clock()
    if now - MOUSE_LOG_AT > 0.25
        and (math.abs(mx - MOUSE_LAST[1]) > 2 or math.abs(my - MOUSE_LAST[2]) > 2) then
        MOUSE_LOG_AT = now
        MOUSE_LAST = { mx, my }
        msg.verbose(string.format('鼠标 %d,%d → 悬停 %s', mx, my, hit and tostring(hit) or '（空白）'))
    end
    if hit ~= UI.hover then
        UI.hover = hit
        if not hover_pending then
            hover_pending = true
            mp.add_timeout(0.05, function()
                hover_pending = false
                if UI.bar then render_prbar() else render_panel() end
            end)
        end
    end
end

----------------------------------------------------------------------
-- 动作表 → 快捷键 + 帮助 + 面板（三者同源）
----------------------------------------------------------------------

local function register(action, handler)
    ACTIONS[#ACTIONS + 1] = action
    HANDLERS[action.name] = handler
end

register({ key = 'Ctrl+m', name = 'add', label = '打标记',
    help = '在播放头打一个标记（用当前颜色）；同一帧不会重复打 —— 这一帧已有标记时，直接打开它的编辑（与 Pr 一致）' },
    function() add_or_edit() end)

register({ key = 'Alt+m', name = 'add-prompt', label = '打标记 + 正文',
    help = '打标记并输入正文 —— 正文会成为 Pr 里的标记名' }, function()
    ask_text('标记正文（会成为 Pr 里的标记名）', '', function(text)
        if text == nil then return end
        add_marker(text)
    end)
end)

for i = 0, 7 do
    register({ key = 'Ctrl+' .. tostring(i + 1), name = 'color-' .. tostring(i),
        label = color_name(i), color = i, compact = true,
        help = string.format('把当前颜色设为 %d（%s）', i, color_name(i)) },
        function() set_color(i) end)
end

register({ key = 'Ctrl+l', name = 'toggle-list', label = '标记列表',
    help = '显示 / 隐藏标记列表' }, toggle_list)
register({ key = 'Alt+n', name = 'next', label = '下一个标记',
    help = '跳到下一个标记（帧精确）' }, function() step_marker(1) end)
register({ key = 'Alt+p', name = 'prev', label = '上一个标记',
    help = '跳到上一个标记' }, function() step_marker(-1) end)
register({ key = 'Alt+g', name = 'goto-prompt', label = '按序跳转',
    help = '按序号跳到某个标记' }, function()
    if #S.markers == 0 then notify('还没有标记') return end
    if input and input.select then
        local items = {}
        for i, m in ipairs(S.markers) do
            items[#items + 1] = string.format('%d  %s  %s', i, to_timecode(m.t, get_fps() or 25),
                m.comment)
        end
        input.select({ prompt = '跳到哪个标记？', items = items, submit = function(id)
            if id then goto_marker(id) end
        end })
    else
        ask_text('跳到第几个标记？（1-' .. tostring(#S.markers) .. '）', '', function(text)
            if text then goto_marker(tonumber(trim(text))) end
        end)
    end
end)
register({ key = 'Alt+e', name = 'edit-nearest', label = '改正文',
    help = '编辑离播放头最近的标记的正文（默认 ±1 秒内）' }, function()
    local idx = nearest_index()
    if not idx then notify(string.format('附近 %g 秒内没有标记（当前共 %d 条）', NEAREST_WINDOW, #S.markers)) return end
    ask_text('编辑正文（会成为 Pr 里的标记名）', S.markers[idx].comment or '', function(text)
        if text == nil then return end
        edit_nearest(text)
    end)
end)
register({ key = 'Ctrl+DEL', name = 'delete-nearest', label = '删除标记',
    help = '删除离播放头最近的标记（默认 ±1 秒内）' }, delete_nearest)
-- 导出两种：默认覆盖同名文件（好找、不堆积）；Ctrl+Shift+E 带时间戳另存（保留每一次的版本）
local function export_prompt(stamped)
    ask_text('导出到（回车用默认路径）', default_export_path(stamped), function(text)
        if text == nil then return end
        if trim(text) == '' then text = default_export_path(stamped) end
        export_to(text)
    end)
end
-- 导出免回车：默认路径已经高度可预期，所以 Ctrl+E / Ctrl+Shift+E 直接落盘，不再弹框。
-- 需要自己选路径时才用 Ctrl+Alt+E（保留原来的输入框）。
register({ key = 'Ctrl+e', name = 'export-prompt', label = '导出标记',
    help = '直接导出（覆盖同名文件，不再弹框）' }, function()
    export_to(default_export_path(false))
end)
register({ key = 'Ctrl+Shift+e', name = 'export-stamped', label = '导出标记（另存为迭代）',
    help = '直接导出并带时间戳（不覆盖，保留每一次的版本）' }, function()
    export_to(default_export_path(true))
end)
register({ key = 'Ctrl+Alt+e', name = 'export-as', label = '导出标记（指定路径）',
    help = '弹出输入框，自己指定导出到哪个文件' }, function()
    export_prompt(false)
end)
register({ key = 'Ctrl+i', name = 'import-prompt', label = '导入标记',
    help = '从文件导入标记（CSV / TSV / JSON / SRT）' }, function()
    ask_text('从哪个文件导入？（CSV/TSV/JSON/SRT）', S.last_export or S.sidecar or '', function(text)
        if text == nil then return end
        import_from(text)
    end)
end)
register({ key = 'F1', name = 'help', label = '帮助',
    help = '显示 / 隐藏这份帮助' }, function() toggle_help() end)
register({ key = 'F2', name = 'toggle-panel', label = 'OSD 显示/隐藏',
    help = '显示 / 隐藏当前 OSD（按钮面板 或 Pr 风格控制栏；用 F3 换样式）' }, function() toggle_panel() end)

register({ key = 'F3', name = 'switch-osd', label = '切换 OSD 样式',
    help = '在「按钮面板」和「Pr 风格控制栏」之间切换（切完立即显示）' }, function() switch_osd_style() end)

register({ key = 'F10', name = 'marker-mode', label = '标记模式',
    help = '开关标记模式：开启后 M 打标记 / Shift+M 下一个 /\nCtrl+Shift+M 上一个 / Del 删除 / Enter 从入点播放（右下角有小标）' }, function()
    set_marker_mode()
end)

for _, a in ipairs(ACTIONS) do
    local fn = HANDLERS[a.name]
    a.default_key = a.default_key or a.key
    -- a.key 是【给人看的显示串】，绝不留 nil：禁用时显示"（已禁用）"，绑定另用 a.bind_key。
    -- 之前直接把 nil 写进 a.key，任何 string.format('%s', a.key) 都会抛异常，
    -- 于是面板/帮助渲染连带死掉（用户实测：help=none 之后 F2、F10 都没反应）。
    local bind_key = eff_key(a.name, a.default_key)
    a.bind_key = bind_key
    a.key = bind_key or '（已禁用）'
    local ok, err = true, nil
    -- 第 9 条 r46：抓手进行中，任何插件动作键也顺手把抓手放下（"任何按键都能中断"，且不丢这个键原本的功能）
    if bind_key then
        local f0 = fn or function() end
        ok, err = pcall(mp.add_key_binding, bind_key, a.name, function()
            if TL.drop then TL.drop('按键') end
            f0()
        end)
    end
    if not ok then msg.warn(string.format('绑定 %s 失败: %s', tostring(a.key), tostring(err))) end
end

mp.observe_property('mouse-pos', 'native', on_mouse_pos)

-- 第 8 条：暂停 / 播放切换时立刻重绘 —— 暂停后 time-pos 不再变化，
-- 否则控制栏的 ▶ / ⏸ 要等下一次事件（例如按 Space 恢复）才跟着变（用户实测反馈）
mp.observe_property('pause', 'native', function()
    if redraw_ui then redraw_ui() end
end)

-- 窗口大小 / 全屏切换后按钮坐标会失效：尺寸一变就重算并重设鼠标区域
local last_osd = nil
mp.observe_property('osd-dimensions', 'native', function(_, d)
    local w, h = osd_size()
    if last_osd and last_osd[1] == w and last_osd[2] == h then return end
    last_osd = { w, h }
    if UI.panel then render_panel() end
    if UI.bar then render_prbar() end
    render_timeline()
    if UI.help then show_help(true) end
end)

----------------------------------------------------------------------
-- 界面状态持久化（记住"是否保留浮窗"，新手不用每次重开）
----------------------------------------------------------------------

local function ui_state_path()
    local p = expand('~~home/source-markers-ui.json')
    if is_absolute(p) then return p end
    local tmp = os.getenv('TEMP') or os.getenv('TMP')
    if tmp and tmp ~= '' then return tmp .. '\\source-markers-ui.json' end
    return nil
end

local function load_ui_state()
    local p = ui_state_path()
    if not p or not file_exists(p) then return end
    local d = json_decode(read_file(p) or '')
    if type(d) == 'table' then
        if d.hint_shown ~= nil then UI.hint_shown = d.hint_shown == true end
        if d.help ~= nil then UI.help = d.help == true end
        if d.show_list ~= nil then S.show_list = d.show_list == true end
        if d.mode ~= nil then UI.mode = d.mode == true end
        -- 上次会话的选择优先；配置里的 panel=yes/no 只在"还没有界面状态文件"时当默认值。
        -- （原来写成"配置写了 panel=yes 就以配置为准"，结果 F2 关掉面板后下次启动又会被强开 ✗）
        if d.panel ~= nil then UI.panel = d.panel == true end
        -- 第 8 条：样式 + 控制栏是否显示。旧文件没有这两个键 ⇒ 样式仍是按钮面板、
        -- 控制栏不显示，行为与升级前完全一致（用户实测过的路径不变）
        if d.style == 'prbar' or d.style == 'panel' then UI.style = d.style end
        if d.bar ~= nil then UI.bar = d.bar == true end
        if UI.bar then UI.panel = false end          -- 互斥：文件里两个都开时以控制栏为准
        -- 第 9 条 r46：时间轴的可见范围跨重启记住（只对"同一个文件"生效，换文件不继承）
        if d.tl_file and tonumber(d.tl_t0) and tonumber(d.tl_t1) then
            TL.saved = { file = tostring(d.tl_file), t0 = tonumber(d.tl_t0), t1 = tonumber(d.tl_t1) }
        end
    end
end

save_ui_state = function()
    local p = ui_state_path()
    if not p then return end
    -- 三项开关全部落盘：按钮面板 / 帮助浮窗 / 标记列表（外加「首次提示已显示」）
    write_file_atomic(p, json_encode({
        panel = UI.panel, help = UI.help, show_list = S.show_list, hint_shown = UI.hint_shown, mode = UI.mode,
        style = UI.style, bar = UI.bar,
        tl_file = TL.cur_file, tl_t0 = TL.t0, tl_t1 = TL.t1,   -- 第 9 条 r46：时间轴可见范围
    }))
end

load_ui_state()

-- 第 9 条：启动时也按保存的样式校准内置 OSC
-- （老的 ui.json 没有 style 字段 ⇒ 默认 panel ⇒ 这里把 OSC 打开，与升级前的观感一致）
apply_osc_for_style()

----------------------------------------------------------------------
-- ①共享颜色表：只读一次（改颜色表要重启 mpv，与"改配置要重启"一致）
apply_shared_colors()
msg.info('颜色表来源：' .. COLOR_TABLE_STATE)

-- ③标记模式：沿用上次会话的开关（quiet=true，启动时不弹提示；徽标由 time-pos 观察者兜底重绘）
set_marker_mode(UI.mode == true, true)
msg.info('标记模式：' .. key_of('marker-mode') .. ' 开关（M 打标记 / Shift+M 下一个 / Ctrl+Shift+M 上一个 / Del 删除 / Enter 从入点播放）'
    .. '；注意：用户自定义 input.conf 的优先级更高，会盖掉这些裸键')

-- 脚本消息（外部工具 / 自动化测试用；与按钮、快捷键走同一批处理函数）
----------------------------------------------------------------------

local function as_bool(v)
    if v == nil or v == '' then return nil end
    if v == true or v == 'on' or v == '1' or v == 'true' or v == 'yes' then return true end
    if v == false or v == 'off' or v == '0' or v == 'false' or v == 'no' then return false end
    return nil
end

mp.register_script_message('add', function(comment) add_marker(comment) end)
mp.register_script_message('add-prompt', function()
    local fn = HANDLERS['add-prompt']
    if fn then fn() end
end)
mp.register_script_message('set-color', function(idx) set_color(idx) end)
mp.register_script_message('color', function(idx) set_color(idx) end)
mp.register_script_message('list', function(state)
    local b = as_bool(state)
    S.show_list = (b == nil) and true or b
    update_overlay()
end)
mp.register_script_message('toggle-list', toggle_list)
mp.register_script_message('next', function() step_marker(1) end)
mp.register_script_message('prev', function() step_marker(-1) end)
mp.register_script_message('goto', function(idx) goto_marker(idx) end)
mp.register_script_message('delete', delete_nearest)
mp.register_script_message('clear', clear_markers)
mp.register_script_message('edit', function(text) edit_nearest(text) end)
mp.register_script_message('export', function(path) export_to(path or S.last_export or default_export_path()) end)
mp.register_script_message('import', function(path) import_from(path) end)
mp.register_script_message('help', function(state)
    local b = as_bool(state)
    toggle_help(b)
end)
mp.register_script_message('panel', function(state)
    local b = as_bool(state)
    toggle_panel(b)
    save_ui_state()
end)
-- 模拟"点某个按钮"（与鼠标点击走同一条路径，便于自动化测试）
mp.register_script_message('click', function(name)
    local fn = HANDLERS[tostring(name or '')]
    if fn then fn() else notify('未知按钮：' .. tostring(name)) end
end)
mp.register_script_message('ui-state', function(path)
    local btns = {}
    local minx, miny, maxx, maxy = nil, nil, nil, nil
    for _, b in ipairs(PANEL_BUTTONS) do
        btns[#btns + 1] = { name = b.name, label = b.label, x = b.x, y = b.y, w = b.w, h = b.h }
        minx = math.min(minx or b.x, b.x)
        miny = math.min(miny or b.y, b.y)
        maxx = math.max(maxx or (b.x + b.w), b.x + b.w)
        maxy = math.max(maxy or (b.y + b.h), b.y + b.h)
    end
    local keys = {}
    for _, a in ipairs(ACTIONS) do
        keys[#keys + 1] = { key = a.key, name = a.name, label = a.label, help = a.help }
    end
    for _, s in ipairs(TL_KEYS) do                     -- 第 9 条 r46：时间轴三个键也报给外部工具
        keys[#keys + 1] = { key = eff_key(s.name, s.key), name = s.name, label = s.label,
                            help = '时间轴：' .. s.label }
    end
    local swatch_fg, swatch_oc = {}, {}
    for i = 0, 7 do
        local fg, oc = swatch_colors(i)
        swatch_fg[tostring(i)] = fg
        swatch_oc[tostring(i)] = oc
    end
    local function lines_of(ov)
        if not ov or ov.data == '' then return 0 end
        local n = 0
        for _ in ov.data:gmatch('\n') do n = n + 1 end
        return n + 1
    end
    local w, h = osd_size()
    local bottom_opt = tonumber(o.panel_bottom) or 0
    local payload = json_encode({
        help = UI.help, panel = UI.panel, hover = UI.hover,
        help_lines = lines_of(overlay_help), panel_lines = lines_of(overlay_panel),
        count = #S.markers, color = S.color, list = S.show_list,
        sidecar = S.sidecar, buttons = btns, keys = keys,
        state_file = ui_state_path(),
        osd = { w = w, h = h },
        panel_rect = (minx and { x = minx, y = miny, w = maxx - minx, h = maxy - miny }) or nil,
        panel_anchor = tostring(o.panel_anchor or 'bottom-left'),
        osc_safe_margin = (bottom_opt > 0) and bottom_opt or math.max(90, math.floor(h * 0.20)),
        swatch_fg = swatch_fg, swatch_outline = swatch_oc,
    })
    print(payload)
    -- 给了路径就同时落盘：外部工具（以及自动化测试）可以据此拿到按钮坐标与渲染出的 ASS
    if path and path ~= '' then
        local ok, err = write_file_atomic(path, json_encode({
            osd = { w = w, h = h },
            ui = json_decode(payload) or {},
            ass = { panel = overlay_panel.data or '', help = overlay_help.data or '' },
        }))
        if not ok then msg.warn('写 ui-state 失败: ' .. tostring(err)) end
    end
end)
-- ── 第 5 条：键位模板 + 冲突检查 + 查询接口 ────────────────────────────
local function key_all_known()
    local known = {}
    for _, a in ipairs(ACTIONS) do known[a.name] = true end
    for _, s in ipairs(MODE_KEYS) do known[s.name] = true end
    for _, s in ipairs(EDIT_KEYS) do known[s.name] = true end
    for _, s in ipairs(TL_KEYS) do known[s.name] = true end        -- 第 9 条 r46：时间轴三个键
    return known
end

local function write_key_template()
    local path = key_conf_write_path()
    if not path then log('键位模板：跳过（找不到可写的配置目录）') return end
    if file_exists(path) then return end                 -- 只在缺失时生成，绝不覆盖用户改过的
    ensure_dir(dir_of(path))
    local L = {}
    L[#L+1] = '# Source Markers 键位覆盖表（改完重启 mpv 生效）'
    L[#L+1] = '# 语法： <动作名> = <按键>      没写的动作用默认；写 none 表示禁用这个键'
    L[#L+1] = '# 按键写法与 mpv 一致：字母/数字原样；命名键用大写（ENTER / LEFT / DEL / ESC / F10 ...）；'
    L[#L+1] = '#                       组合键写 Ctrl+e / Shift+m / Ctrl+Shift+m / Alt+m'
    L[#L+1] = '# 也可以完全不用这个文件，改用 mpv 的 input.conf（优先级最高，会盖过本插件）：'
    L[#L+1] = '#     <你的键>  script-binding ' .. BIND_PREFIX .. '<动作名>'
    L[#L+1] = ''
    L[#L+1] = '# —— 全局快捷键 ——'
    for _, a in ipairs(ACTIONS) do
        L[#L+1] = string.format('# %-24s = %s', a.name, a.default_key or a.key or '')
    end
    L[#L+1] = ''
    L[#L+1] = '# —— 标记模式内（先按 F10 打开）——'
    for _, s in ipairs(MODE_KEYS) do
        L[#L+1] = string.format('# %-24s = %s', s.name, s.default_key or s.key)
    end
    L[#L+1] = ''
    L[#L+1] = '# —— 时间轴（Pr 风格控制栏）——'
    for _, s in ipairs(TL_KEYS) do
        L[#L+1] = string.format('# %-24s = %s', s.name, s.key)
    end
    L[#L+1] = ''
    L[#L+1] = '# —— 编辑态内（标记模式里按 ENTER 进入）——'
    for _, s in ipairs(EDIT_KEYS) do
        L[#L+1] = string.format('# %-24s = %s', s.name, s.default_key or s.key)
    end
    local ok = write_file_atomic(path, table.concat(L, '\r\n') .. '\r\n')
    log('键位模板：%s（%s）', path, ok and '已生成' or '写入失败')
end

-- 收集"当前生效"的键位：动作名 -> 键（禁用则不出现）
local function key_effective_map()
    local eff, bykey = {}, {}
    local function add(name, key)
        if not key or eff[name] then return end
        eff[name] = key
        local k = key:upper()
        bykey[k] = bykey[k] or {}
        bykey[k][#bykey[k] + 1] = name
    end
    for _, a in ipairs(ACTIONS) do add(a.name, a.key) end
    for _, s in ipairs(MODE_KEYS) do add(s.name, eff_key(s.name, s.default_key or s.key)) end
    for _, s in ipairs(EDIT_KEYS) do add(s.name, eff_key(s.name, s.default_key or s.key)) end
    for _, s in ipairs(TL_KEYS) do add(s.name, eff_key(s.name, s.key)) end      -- 第 9 条 r46
    return eff, bykey
end

local function check_key_conflicts()
    local errors, warns, infos = {}, {}, {}
    local known = key_all_known()
    for name in pairs(KEY_OVERRIDE) do
        if not known[name] then
            warns[#warns + 1] = string.format('键位表里的动作名 %s 不存在（这条没生效，检查拼写）', name)
        end
    end
    local eff, bykey = key_effective_map()
    for k, names in pairs(bykey) do
        if #names > 1 then
            errors[#errors + 1] = string.format('插件内部同一个键 %s 绑了多个动作：%s', k, table.concat(names, ' / '))
        end
    end
    local mine = 'input_' .. SCRIPT_NAME
    local user_set = {}
    for name, v in pairs(KEY_OVERRIDE) do
        if v ~= false and type(v) == 'string' then user_set[v:upper()] = name end
    end
    local ok, binds = pcall(mp.get_property_native, 'input-bindings')
    if ok and type(binds) == 'table' then
        local seen = {}
        for _, b in ipairs(binds) do
            local k = tostring(b.key or ''):upper()
            if k ~= '' and bykey[k] and tostring(b.section) ~= mine then
                local tag = k .. '|' .. tostring(b.section) .. '|' .. tostring(b.cmd)
                if not seen[tag] then
                    seen[tag] = true
                    local line = string.format('%s ← %s：%s', k,
                        (tostring(b.section) == 'default') and 'mpv 默认' or ('脚本 ' .. tostring(b.section)),
                        tostring(b.cmd))
                    local uname = user_set[k]
                    if uname then
                        -- 用户亲自把某个动作改到了这个键：无论对方是谁都要提醒（它会盖掉对方）
                        warns[#warns + 1] = line ..
                            string.format('  ← 你把「%s」改到了 %s，它会盖掉上面这个功能', uname, k)
                    elseif tostring(b.section) == 'default' and b.is_weak == false then
                        warns[#warns + 1] = line .. '  ← 你自己的 input.conf 优先级更高，这个键会被它盖掉'
                    elseif tostring(b.section) == 'default' then
                        infos[#infos + 1] = line .. '（本插件会盖过它）'
                    else
                        infos[#infos + 1] = line .. '（与它重叠，按各自优先级取一个）'
                    end
                end
            end
        end
    end
    KEY_CHECK = { errors = errors, warns = warns, infos = infos }
    log('键位检查：错误 %d / 警告 %d / 提示 %d', #errors, #warns, #infos)
    for _, s in ipairs(errors) do msg.warn('键位冲突（错误）：' .. s) end
    for _, s in ipairs(warns) do msg.warn('键位冲突（警告）：' .. s) end
    for _, s in ipairs(infos) do msg.verbose('键位提示：' .. s) end
    if #errors > 0 then
        notify(string.format('键位有 %d 处冲突（按 F1 看帮助 / 查日志）', #errors))
    elseif #warns > 0 then
        notify(string.format('键位有 %d 处警告，详见日志（script-message keys 可查）', #warns))
    end
end

mp.register_script_message('keys', function()
    local eff = {}
    for name, key in pairs(key_effective_map()) do eff[name] = key end
    for _, a in ipairs(ACTIONS) do if not a.key then eff[a.name] = '（已禁用）' end end
    print(json_encode({
        conf = key_conf_read_path() or '',
        effective = eff,
        errors = KEY_CHECK.errors, warns = KEY_CHECK.warns, infos = KEY_CHECK.infos,
    }))
end)
mp.register_script_message('keys-reload', function()
    KEY_OVERRIDE = {}
    load_key_overrides()
    check_key_conflicts()
    notify('键位表已重新读取（新键位要重启 mpv 才生效）')
end)

mp.register_script_message('dump', function()
    print(json_encode(export_doc()))
end)
-- 第 8 条：自动化测试钩子 —— 把控制栏的当前状态与 ASS 载荷打进日志（[v] 级），
-- 用来断言"置灰 / 高亮 / 图标朝向"这类只能看渲染结果的东西
mp.register_script_message('prbar', function()
    msg.verbose(string.format('控制栏载荷：style=%s bar=%s panel=%s in=%s out=%s',
        tostring(UI.style), tostring(UI.bar), tostring(UI.panel),
        tostring(IN_FRAME), tostring(OUT_FRAME)))
    -- 按钮命中框（自动化测试要靠它算出"点哪里"；off = 置灰、不响应点击）
    local boxes = {}
    for _, b in ipairs(PRBAR_BUTTONS) do
        boxes[#boxes + 1] = string.format('%s=%d,%d,%d,%d%s', b.act, b.x, b.y, b.w, b.h,
            b.disabled and ',off' or '')
    end
    msg.verbose('控制栏按钮：' .. table.concat(boxes, ' '))
    msg.verbose('控制栏 ASS: ' .. tostring((overlay_bar and overlay_bar.data) or ''))
end)
-- 第 8 条：命中测试钩子 —— 给一个坐标，回报它落在哪个按钮上（供自动化断言命中框的位置/不重叠）。
-- 环境不允许注入鼠标时（本机 DSH 沙箱里 SetCursorPos 直接返回 false），这是唯一能验命中框的办法。
mp.register_script_message('hit', function(x, y)
    local mx, my = tonumber(x) or -1, tonumber(y) or -1
    local hit, marks = '（无）', {}
    for _, b in ipairs(PRBAR_BUTTONS) do
        local inside = (mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h)
        if b.disabled then
            -- 几何上落在框里，但**点了不会有反应**（没注册鼠标区域）⇒ 报告为禁
            marks[#marks + 1] = string.format('%s=%s', b.act, inside and '禁' or '-')
        else
            marks[#marks + 1] = string.format('%s=%s', b.act, inside and 'HIT' or '-')
            if inside and hit == '（无）' then hit = b.act end
        end
    end
    msg.verbose(string.format('命中测试 %d,%d → %s ｜ %s', mx, my, hit, table.concat(marks, ' ')))
end)
-- 第 8 条：悬停"取证钩子" —— 直接指定悬停哪个按钮（自动化测试用；
-- 本机不能注入鼠标，所以"悬停提示"只能靠它验）。传空/不存在的名字 = 清空悬停。
mp.register_script_message('hover', function(name)
    local want = tostring(name or '')
    UI.hover = (want ~= '' and want ~= 'none') and want or nil
    msg.verbose(string.format('悬停设为 %s', UI.hover and tostring(UI.hover) or '（无）'))
    render_panel()
    render_prbar()
end)
-- 第 9 条：时间轴"取证钩子" —— 直接设定可见范围（自动化测试用；不给参数 = 回到整片）。
-- r46 的缩放/平移走的是同一套状态，所以它同时也是那两个功能的测试入口。
mp.register_script_message('tl', function(a, b)
    local t0, t1 = tonumber(a), tonumber(b)
    if t0 and t1 and t1 > t0 then
        TL.t0, TL.t1 = t0, t1
        log('时间轴范围设为 %.3f ~ %.3f', t0, t1)
    else
        TL.t0, TL.t1 = nil, nil
        log('时间轴范围回到整片')
    end
    render_timeline()
end)
mp.register_script_message('state', function()
    print(json_encode({
        sidecar_enabled = o.sidecar,
        sidecar = S.sidecar,
        count = #S.markers,
        color = S.color,
        fps = get_fps(),
        time_format = o.time_format,
        panel = UI.panel,
        osd_style = UI.style,
        osd_bar = UI.bar,
        osc = mp.get_property('osc'),
        help = UI.help,
        hide_sidecar = o.hide_sidecar,
        input = input and 'mp.input' or 'fallback',
        tl_t0 = TL.t0, tl_t1 = TL.t1, tl_file = TL.cur_file,
        tl_min_frames = tonumber(o.tl_min_frames) or 15,
        tl_zoom_anchor = o.tl_zoom_anchor, tl_zoom_pull = o.tl_zoom_pull,
        tl_ov_map = o.tl_ov_map, tl_ov_pow = o.tl_ov_pow, tl_ov_k = o.tl_ov_k, tl_ov_pin = o.tl_ov_pin, tl_ov_edge = o.tl_ov_edge, tl_hit_px = o.tl_hit_px,
        tl_play_follow = o.tl_play_follow,
        tl_zoom_steps = TL.STEP and string.format('%s,%s,%s', tostring(TL.STEP.plain),
            tostring(TL.STEP.ctrl), tostring(TL.STEP.shift)) or nil,
    }))
end)

----------------------------------------------------------------------
-- 事件
----------------------------------------------------------------------

-- hr_seek=yes 时确保 mpv 打开精确 seek；用户若在 mpv.conf 里显式写了 hr-seek=no，尊重用户设置
if o.hr_seek and mp.get_property('hr-seek') ~= 'no' then mp.set_property('hr-seek', 'yes') end

mp.register_event('file-loaded', function()
    load_sidecar()
    -- 首次使用引导：自动把帮助浮窗打开一次，并提示鼠标党可以开按钮面板
    if o.hint and not UI.hint_shown then
        UI.hint_shown = true
        save_ui_state()
        toggle_help(true)
        notify(string.format('新手提示：%s 看快捷键，%s 打开可点击的按钮面板；正文就是 Pr 里的标记名',
            key_of('help'), key_of('toggle-panel')))
        log('新手提示：%s 帮助 / %s 按钮面板（本次是首次使用，之后不再自动弹出）',
            key_of('help'), key_of('toggle-panel'))
    elseif UI.help or UI.panel or UI.bar then
        -- 从上次会话保留的状态：重新渲染一次
        render_panel()
        render_prbar()
        render_timeline()
    end
end)

-- 列表 / 面板 / 帮助可见时重绘：按时间节流，避免每帧拼 ASS 字符串。
-- 面板与帮助也必须在这里兜底：它们原先只在 file-loaded 时渲染一次，
-- 而那一刻 OSD/窗口往往尚未就绪 → 覆盖层被丢弃后就再也不出现
--（这正是「列表能记住、F2 面板记不住」的唯一机制差异）。
local last_overlay_at = 0
mp.observe_property('time-pos', 'number', function()
    if not S.show_list and not UI.panel and not UI.bar and not UI.help and not UI.mode and not UI.edit then return end
    local now = os.clock()
    if now - last_overlay_at < 0.2 then return end
    last_overlay_at = now
    if S.show_list then update_overlay() end
    if (UI.panel or UI.bar or UI.help or UI.mode or UI.edit) and redraw_ui then redraw_ui() end
end)

-- 第 9 条：时间轴**自己的**观察者，节流 0.1s（10 Hz）—— 播放头要"看起来在走"，
-- 控制栏仍用上面的 0.2s。载荷只有几十行，10 Hz 没压力。
local last_tl_at = 0
mp.observe_property('time-pos', 'number', function()
    if not (UI.bar and UI.style == 'prbar' and o.tl) then return end
    local now = os.clock()
    if now - last_tl_at < 0.05 then return end      -- 20 Hz：播放头走起来更顺（原 10 Hz 看着像卡）
    last_tl_at = now
    render_timeline()
end)

mp.register_event('shutdown', function()
    save_sidecar()
    save_ui_state()
end)

write_key_template()
check_key_conflicts()
msg.info(string.format('source-markers 1.2.0-alpha r46 已加载：%d 个快捷键（%s 帮助 / %s 按钮面板）；sidecar=%s（隐藏=%s）；time_format=%s；正文输入=%s',
    #ACTIONS, key_of('help'), key_of('toggle-panel'),
    tostring(o.sidecar), tostring(o.hide_sidecar), tostring(o.time_format),
    input and 'mp.input（播放器内输入框）' or 'python 兜底对话框'))
