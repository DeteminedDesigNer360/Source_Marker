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
      Ctrl+e          导出（默认路径出现后可直接回车，或改成别的路径）
      Ctrl+i          导入（CSV / TSV / JSON / SRT）

  关于 name 列：列按格式 v1 保留在表头里，但内容留空。
  Pr 面板的标记名只取「备注/comment 列」，name 列整列忽略，所以本插件不再生成 M01/M02 之类的
  占位名；用户输入一律进 comment。自动保存的 *.marks.json 会带隐藏属性，避免误删误改。

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
    sidecar = true,            -- 与视频同名的 .marks.json 自动保存
    hide_sidecar = true,       -- 把自动保存的 .marks.json 设成隐藏文件（Windows；防误删/误改）
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
    python = 'python',         -- 老版本 mpv 的输入框兜底解释器
    helper = '',               -- 自定义输入框脚本（留空用内置）
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
    local tmp = path .. '.tmp'
    local f, oserr = io.open(tmp, 'wb')
    if not f then
        -- 把系统给的原因一并报出来：只报路径无法区分「没有权限 / 路径过长 / 目录不存在」。
        return false, '无法写入 ' .. tmp .. '（系统错误：' .. tostring(oserr) .. '）'
    end
    f:write(data)
    f:close()
    if file_exists(path) then os.remove(path) end
    local ok, err = os.rename(tmp, path)
    if not ok then return false, tostring(err) end
    return true
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
    return {
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
        S.sidecar = dir .. '\\' .. base_of(path) .. '.marks.json'
        return S.sidecar
    end
    if path and path ~= '' then
        local dir = resolve_dir(o.dir)
        if not dir then
            msg.warn('找不到可写的 sidecar 目录，已跳过 sidecar')
            return nil
        end
        S.sidecar = dir .. '\\' .. safe_filename(base_of(mp.get_property('filename') or 'stream')) .. '.marks.json'
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

local function load_sidecar()
    S.markers = {}
    -- show_list 不在这里重置：它由界面状态文件持久化（见 load_ui_state），
    -- 否则每次换素材都会把「显示列表」的选择抹掉。
    update_overlay()
    if not o.sidecar then return end          -- sidecar=no 时既不写也不读
    local path = sidecar_path()
    if path and file_exists(path) then
        local text = read_file(path)
        local markers, skipped = {}, 0
        if text then markers, skipped = parse_marker_file(text, get_fps()) end
        S.markers = markers
        sort_markers()
        if skipped > 0 then
            msg.warn(string.format('sidecar 里有 %d 条无法解析的标记，已跳过', skipped))
            notify(string.format('sidecar 跳过 %d 条坏标记', skipped))
        end
        log('已载入 %d 个标记：%s', #S.markers, path)
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

local function nearest_index()
    local head = head_time()
    if not head or #S.markers == 0 then return nil end
    local idx, best = nil, nil
    for i, m in ipairs(S.markers) do
        local d = math.abs(m.t - head)
        if not best or d < best then idx, best = i, d end
    end
    return idx
end

-- 用户输入一律作为「正文」写进 comment 列，name 列留空。
-- Pr 面板的标记名只取「备注/comment 列」、name 列整列忽略，所以这里不生成任何占位名。
local function add_marker(comment)
    local t = head_time()
    if not t then
        notify('没有正在播放的文件')
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

local function seek_to(t)
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
end

local function step_marker(delta)
    if #S.markers == 0 then
        notify('还没有标记')
        return
    end
    local head = head_time() or 0
    local target = nil
    if delta > 0 then
        for i, m in ipairs(S.markers) do
            if m.t > head + 0.001 then target = i break end
        end
        if not target then target = #S.markers end
    else
        for i = #S.markers, 1, -1 do
            if S.markers[i].t < head - 0.001 then target = i break end
        end
        if not target then target = 1 end
    end
    goto_marker(target)
end

local function delete_nearest()
    local idx = nearest_index()
    if not idx then
        notify('还没有标记')
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
        notify('还没有标记')
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

local function default_export_path()
    local stamp = os.date('%Y%m%d-%H%M%S')
    local path = mp.get_property('path')
    local dir
    if is_local_file(path) then
        dir = dir_of(path)
    else
        dir = resolve_dir(o.dir)
    end
    if not dir then dir = os.getenv('TEMP') or '.' end
    local base = base_of(mp.get_property('filename') or 'markers')
    return string.format('%s\\%s_markers_%s.csv', dir, safe_filename(base), stamp)
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
    S.last_export = csv_path
    notify(string.format('已导出 %d 个标记 → %s', #S.markers, csv_path))
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
local function key_of(name)
    for _, a in ipairs(ACTIONS) do
        if a.name == name then return a.key end
    end
    return '?'
end

local UI = { help = false, panel = o.panel == true, hover = nil, hint_shown = false, mode = false }
local PANEL_BUTTONS = {}          -- 渲染后填充：{name,label,x,y,w,h,section}
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
    local rows = {}
    for _, a in ipairs(ACTIONS) do
        if not a.compact then rows[#rows + 1] = a end     -- 颜色单独用一行汇总，列出 8 条太占地方
    end
    local box_h = lh * (#rows + 4) + 16
    local lines = {
        rect_line(x - 12, y - 12, box_w, box_h, '&H1C1C1C&', '20'),
        text_line(x, y, size + 2, '&H4DE0FF&', 'Source Markers — 快捷键帮助', true),
    }
    local cy = y + lh
    lines[#lines + 1] = text_line(x, cy, size, '&HB0B0B0&', '鼠标党可以直接按 ' .. key_of('toggle-panel') .. ' 打开按钮面板，全部功能都能点。')
    cy = cy + lh
    for _, a in ipairs(rows) do
        lines[#lines + 1] = text_line(x, cy, size, '&H4DE0FF&', string.format('%-10s', a.key))
        lines[#lines + 1] = text_line(x + math.floor(size * 8.2), cy, size, '&HFFFFFF&', a.help)
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

local function toggle_panel(state)
    UI.panel = (state == nil) and (not UI.panel) or (state == true)
    render_panel()
    if save_ui_state then save_ui_state() end      -- 快捷键 / 按钮 / 脚本消息，任何路径都立即落盘
    if UI.panel then
        notify('按钮面板已打开：所有功能都能点（' .. key_of('toggle-panel') .. ' 关闭，' .. key_of('help') .. ' 帮助）')
    else
        notify('按钮面板已关闭')
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
    { key = 'Del',          name = 'delete-nearest', label = '删除标记' },
}
local overlay_mode = new_overlay()

local function mode_dispatch(name)
    msg.verbose('标记模式按键 → ' .. tostring(name))
    local fn = HANDLERS[name]
    if fn then fn() else msg.warn('标记模式：找不到动作 ' .. tostring(name)) end
end
-- 开=逐个 add_key_binding，关=逐个 remove_key_binding。
-- 选这条而不是 section API，是因为**真机实测**过：add_key_binding 的绑定能盖过 mpv 内置键，
-- 而 section 那套在本机 mpv 上按 m 没有任何反应（同一个键、两种机制，行为不同）。
-- 另外 add_key_binding 的返回值在旧 mpv 上是 nil，所以不能用 返回值:disable() 那套。
local function mode_bindings_apply(on)
    local n = 0
    for _, spec in ipairs(MODE_KEYS) do
        local bname = 'source-markers-mode-' .. spec.name
        if on then
            mp.add_key_binding(spec.key, bname, function() mode_dispatch(spec.name) end)
            n = n + 1
        elseif type(mp.remove_key_binding) == 'function' then
            mp.remove_key_binding(bname)
            n = n + 1
        end
    end
    log('标记模式绑定：%s（处理 %d 个键；remove_key_binding=%s）',
        on and '已启用' or '已关闭', n, tostring(type(mp.remove_key_binding)))
end
local function render_mode_badge()
    local w, h = osd_size()
    if not UI.mode or not w or not h then
        set_overlay(overlay_mode, nil, w, h)
        return
    end
    local size = math.max(14, math.floor(ui_font() * 0.85))
    local text = '标记模式　F10 退出'
    local bw = math.floor(#text * size * 0.95) + 18
    local bh = size + 12
    local x = math.max(SIDE_PADDING, w - bw - 24)
    local y = math.max(SIDE_PADDING, h - bh - 24)
    set_overlay(overlay_mode, {
        rect_line(x, y, bw, bh, '&H000000&', '80'),
        text_line(x + 9, y + 6, size, '&H4DE0FF&', text, true),
    }, w, h)
end

local function set_marker_mode(on, quiet)
    UI.mode = (on == nil) and (not UI.mode) or (on == true)
    mode_bindings_apply(UI.mode)
    render_mode_badge()
    if not quiet then
        if UI.mode then
            notify('标记模式：M 打标记 · Shift+M 下一个 · Ctrl+Shift+M 上一个 · Del 删除 · F10 退出')
        else
            notify('已退出标记模式')
        end
    end
    if save_ui_state then save_ui_state() end
end



-- 面板 / 帮助 / 标记模式徽标的重绘入口：给「改了状态但没经过鼠标事件」的路径用（例如切换颜色）
redraw_ui = function()
    if UI.panel then render_panel() end
    if UI.help then show_help(true) end
    render_mode_badge()
end

-- 悬停高亮：鼠标位置变化时只重绘必要的部分
local hover_pending = false
local function on_mouse_pos(_, pos)
    if not UI.panel or type(pos) ~= 'table' then return end
    local mx, my = tonumber(pos.x) or 0, tonumber(pos.y) or 0
    local hit = nil
    for _, b in ipairs(PANEL_BUTTONS) do
        if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then hit = b.name break end
    end
    if hit ~= UI.hover then
        UI.hover = hit
        if not hover_pending then
            hover_pending = true
            mp.add_timeout(0.05, function()
                hover_pending = false
                render_panel()
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
    help = '在播放头打一个标记（用当前颜色）' }, function() add_marker(nil) end)

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
    help = '编辑离播放头最近的标记的正文' }, function()
    local idx = nearest_index()
    if not idx then notify('还没有标记') return end
    ask_text('编辑正文（会成为 Pr 里的标记名）', S.markers[idx].comment or '', function(text)
        if text == nil then return end
        edit_nearest(text)
    end)
end)
register({ key = 'Ctrl+DEL', name = 'delete-nearest', label = '删除标记',
    help = '删除离播放头最近的标记' }, delete_nearest)
register({ key = 'Ctrl+e', name = 'export-prompt', label = '导出标记',
    help = '导出 CSV/JSON（默认路径直接回车）' }, function()
    ask_text('导出到（回车用默认路径）', default_export_path(), function(text)
        if text == nil then return end
        if trim(text) == '' then text = default_export_path() end
        export_to(text)
    end)
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
register({ key = 'F2', name = 'toggle-panel', label = '按钮面板',
    help = '显示 / 隐藏可点击的按钮面板（鼠标党的入口）' }, function() toggle_panel() end)

register({ key = 'F10', name = 'marker-mode', label = '标记模式',
    help = '开关标记模式：开启后 M 打标记 / Shift+M 下一个 / Ctrl+Shift+M 上一个 / Del 删除（右下角有小标）' }, function()
    set_marker_mode()
end)

for _, a in ipairs(ACTIONS) do
    local fn = HANDLERS[a.name]
    local ok, err = pcall(mp.add_key_binding, a.key, a.name, fn or function() end)
    if not ok then msg.warn(string.format('绑定 %s 失败: %s', tostring(a.key), tostring(err))) end
end

mp.observe_property('mouse-pos', 'native', on_mouse_pos)

-- 窗口大小 / 全屏切换后按钮坐标会失效：尺寸一变就重算并重设鼠标区域
local last_osd = nil
mp.observe_property('osd-dimensions', 'native', function(_, d)
    local w, h = osd_size()
    if last_osd and last_osd[1] == w and last_osd[2] == h then return end
    last_osd = { w, h }
    if UI.panel then render_panel() end
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
    end
end

save_ui_state = function()
    local p = ui_state_path()
    if not p then return end
    -- 三项开关全部落盘：按钮面板 / 帮助浮窗 / 标记列表（外加「首次提示已显示」）
    write_file_atomic(p, json_encode({
        panel = UI.panel, help = UI.help, show_list = S.show_list, hint_shown = UI.hint_shown, mode = UI.mode,
    }))
end

load_ui_state()

----------------------------------------------------------------------
-- ①共享颜色表：只读一次（改颜色表要重启 mpv，与"改配置要重启"一致）
apply_shared_colors()
msg.info('颜色表来源：' .. COLOR_TABLE_STATE)

-- ③标记模式：沿用上次会话的开关（quiet=true，启动时不弹提示；徽标由 time-pos 观察者兜底重绘）
set_marker_mode(UI.mode == true, true)

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
mp.register_script_message('dump', function()
    print(json_encode(export_doc()))
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
        help = UI.help,
        hide_sidecar = o.hide_sidecar,
        input = input and 'mp.input' or 'fallback',
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
    elseif UI.help or UI.panel then
        -- 从上次会话保留的状态：重新渲染一次
        render_panel()
    end
end)

-- 列表 / 面板 / 帮助可见时重绘：按时间节流，避免每帧拼 ASS 字符串。
-- 面板与帮助也必须在这里兜底：它们原先只在 file-loaded 时渲染一次，
-- 而那一刻 OSD/窗口往往尚未就绪 → 覆盖层被丢弃后就再也不出现
--（这正是「列表能记住、F2 面板记不住」的唯一机制差异）。
local last_overlay_at = 0
mp.observe_property('time-pos', 'number', function()
    if not S.show_list and not UI.panel and not UI.help and not UI.mode then return end
    local now = os.clock()
    if now - last_overlay_at < 0.2 then return end
    last_overlay_at = now
    if S.show_list then update_overlay() end
    if (UI.panel or UI.help or UI.mode) and redraw_ui then redraw_ui() end
end)

mp.register_event('shutdown', function()
    save_sidecar()
    save_ui_state()
end)

msg.info(string.format('source-markers 1.2.0-alpha r5 已加载：%d 个快捷键（%s 帮助 / %s 按钮面板）；sidecar=%s（隐藏=%s）；time_format=%s；正文输入=%s',
    #ACTIONS, key_of('help'), key_of('toggle-panel'),
    tostring(o.sidecar), tostring(o.hide_sidecar), tostring(o.time_format),
    input and 'mp.input（播放器内输入框）' or 'python 兜底对话框'))
