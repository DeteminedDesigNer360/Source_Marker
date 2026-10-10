/* Source Marker — CEP 面板逻辑 */

var cs = new CSInterface();
var US = String.fromCharCode(31);
var STATE = { fps: 25, inSec: 0, outSec: 0, clipName: '', clipPath: '', markers: [] };

/* ------------------------------ 基础桥接 ------------------------------ */

/* 日志分级：info / ok / warn / err。cls 传 'ok'/'warn'/'err'，其余一律当 info。
   老代码里的 log(x) / log(x,'ok') / log(x,'err') 全部照旧可用。
   颜色与左边框用内联样式，不依赖外部样式表。 */
var LOG_COLORS = { info: '#9aa0a6', ok: '#4caf50', warn: '#e0a800', err: '#ef5350' };
function log(msg, cls) {
  var el = document.getElementById('log');
  if (!el) return null;
  var kind = (cls === 'err') ? 'err' : (cls === 'warn' ? 'warn' : (cls === 'ok' ? 'ok' : 'info'));
  var line = document.createElement('div');
  line.className = kind;
  line.style.color = LOG_COLORS[kind];
  line.style.borderLeft = '3px solid ' + LOG_COLORS[kind];
  line.style.paddingLeft = '4px';
  var tag = document.createElement('span');
  tag.textContent = kind.toUpperCase() + ' ';
  tag.style.opacity = '0.6';
  line.appendChild(tag);
  line.appendChild(document.createTextNode(String(msg == null ? '' : msg)));
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
  return line;
}

function q(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'number') return String(v);
  return '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, '\\n') + '"';
}

function callJSX(fn) {
  var args = Array.prototype.slice.call(arguments, 1).map(q).join(',');
  return new Promise(function (resolve) {
    cs.evalScript(fn + '(' + args + ')', function (raw) {
      if (!raw || raw === 'EvalScript error.') {
        resolve({ ok: false, fields: ['EvalScript error (检查 ExtendScript 是否抛异常)'] });
        return;
      }
      var parts = String(raw).split(US);
      resolve({ ok: parts[0] === 'OK', fields: parts.slice(1) });
    });
  });
}

function describe(res) { return res.fields.filter(Boolean).join(' | '); }

/* --------------------- 文件对话框 ---------------------
 * 优先用 CEP 自己的对话框：它挂在**面板窗口**上，归属关系与 ExtendScript 的
 * File.openDialog（由宿主进程弹出）不同，后者在 Pr 主窗口不在最前时会被压在下面。
 * 而 app.bringToFront 在 Pr 24.0 上不存在（自检实测 undefined），没有别的杠杆。
 * CEP 路线一旦返回"不可用"，立即回退到 ExtendScript 对话框，不会让功能失效。
 */
function cepOpenDialog(title, fileTypes, initialPath) {
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.showOpenDialog !== 'function') return null;
    var r = window.cep.fs.showOpenDialog(false, false, title, initialPath || '', fileTypes);
    if (!r || typeof r.err === 'undefined') return null;
    if (r.err !== 0) return null;                       // 出错 → 交回 ExtendScript
    return (r.data && r.data.length) ? r.data[0] : '';  // 选中 / 用户取消
  } catch (e) { return null; }
}

function pickFile(kind) {
  var title = (kind === 'preset') ? '选择 AME 预设 (.epr)' : '选择标记文件';
  var types = (kind === 'preset') ? ['epr'] : ['csv', 'tsv', 'txt', 'json', 'srt'];
  // 标记文件按约定与素材同目录：对话框直接开在那里（CEP 不吃该参数时退回原行为）
  var startDir = (kind === 'marker') ? dirOfPath(STATE.clipPath) : '';
  var hit = cepOpenDialog(title, types, startDir);
  if (hit !== null) {
    log('对话框: CEP' + (hit ? ' → ' + hit : '（已取消）'));
    return Promise.resolve(hit);
  }
  log('对话框: ExtendScript（CEP 不可用，已回退）');
  return callJSX('smPickFile', kind, '').then(function (r) {
    return r.ok ? (r.fields[0] || '') : '';
  });
}
function pickFolder() {
  return callJSX('smPickFolder').then(function (r) {
    return r.ok ? (r.fields[0] || '') : '';
  });
}
function readTextFile(path) {
  return callJSX('smReadTextFile', path).then(function (r) {
    // 正文可能含 US 分隔符之外的任意字符，用 join 还原
    return r.ok ? r.fields.join(String.fromCharCode(31)).replace(/^\uFEFF/, '') : null;
  });
}

/* ------------- 素材目录里的同名标记文件 -------------
 * 约定：mpv 插件把标记导出到**素材同目录**。自 1.2.0-r8 起默认是**无戳**的
 * `<素材名>_markers.csv`（Ctrl+E 覆盖）；Ctrl+Shift+E 另存为迭代时才带 `<时间戳>`。
 * 面板侧自己的导出仍带时间戳（稍后统一）。
 * 面板早就从 smGetState 拿到了素材完整路径（item.getMediaPath），所以不需要新增约定，
 * 把这条路径用起来即可。
 * 目录列举用 CEP 自带的 fs.readdir（面板层），读文件仍走原来的 smReadTextFile（引擎）——
 * 因此这个功能**不需要改宿主引擎**。
 * 文件名里自带时间戳，所以按名字倒序 = 最新在前，不必依赖 stat 的返回结构。
 */
function dirOfPath(p) {
  var m = String(p == null ? '' : p).match(/^(.*)[\\\/][^\\\/]*$/);
  return m ? m[1] : '';
}
function stemOfPath(p) {
  var m = String(p == null ? '' : p).match(/([^\\\/]+)$/);
  return (m ? m[1] : '').replace(/\.[^.]*$/, '');
}
function findMarkerCandidates() {
  if (!STATE.clipPath) return Promise.resolve({ err: '源监视器里没有素材' });
  if (!window.cep || !window.cep.fs || typeof window.cep.fs.readdir !== 'function') {
    return Promise.resolve({ err: '此 Pr 版本不支持读取目录，请用「选择文件…」' });
  }
  var dir = dirOfPath(STATE.clipPath), stem = stemOfPath(STATE.clipPath);
  if (!dir || !stem) return Promise.resolve({ err: '无法从素材路径推出所在目录' });
  var r;
  try { r = window.cep.fs.readdir(dir); }
  catch (e) { return Promise.resolve({ err: '读取目录失败: ' + e.message }); }
  if (!r || r.err !== 0 || !r.data) {
    return Promise.resolve({ err: '读取目录失败（err=' + (r && r.err) + '）: ' + dir });
  }
  var names = (r.data && r.data.length) ? r.data : [];
  /* 候选匹配：<stem>_markers.csv/.json（默认导出，无戳）与 <stem>_markers_<戳>.csv/.json（另存为迭代）。
     注意结尾不再要求下划线 —— 否则 mpv 侧改用"无戳默认名"后会静默找不到。 */
  var base = stem + '_markers';
  var exactCsv = stem + '_markers.csv', exactJson = stem + '_markers.json';
  var hits = names.map(function (n) { return String(n); })
    .filter(function (n) { return n.indexOf(base) === 0 && /\.(csv|json)$/i.test(n); })
    .map(function (n) {
      // readdir 可能只给文件名、也可能给完整路径，两种都兜住
      var full = /^([a-zA-Z]:[\\\/]|[\\\/])/.test(n) ? n : dir + '\\' + n;
      return { name: n.replace(/^.*[\\\/]/, ''), full: full };
    })
    .sort(function (a, b) {
      // 无戳的那份优先（它就是最近一次"覆盖式"导出）；其余按名字倒序（时间戳的词典序 = 时间序）
      var ra = (a.name === exactCsv || a.name === exactJson) ? 0 : 1;
      var rb = (b.name === exactCsv || b.name === exactJson) ? 0 : 1;
      if (ra !== rb) return ra - rb;
      return a.name < b.name ? 1 : (a.name > b.name ? -1 : 0);
    });
  var csv = hits.filter(function (h) { return /\.csv$/i.test(h.name); });
  return Promise.resolve({ dir: dir, stem: stem, total: hits.length, list: csv.length ? csv : hits });
}

/* ------------------------------ 时间解析 ------------------------------ */

function parseTimeToSeconds(str, fps) {
  str = String(str == null ? '' : str).trim();
  if (!str) return NaN;
  if (/^-?\d+(\.\d+)?$/.test(str)) return parseFloat(str);
  var p = str.split(':').map(function (s) { return s.trim(); });
  if (p.length === 4) return (+p[0]) * 3600 + (+p[1]) * 60 + (+p[2]) + parseFloat(p[3]) / fps;   // HH:MM:SS:FF
  if (p.length === 3) return (+p[0]) * 3600 + (+p[1]) * 60 + parseFloat(p[2]);                  // HH:MM:SS(.mmm)
  if (p.length === 2) return (+p[0]) * 60 + parseFloat(p[1]);                                   // MM:SS
  return NaN;
}
/* 先算总帧数再拆位：避免 (sec % 1) * fps 的浮点误差产生非法帧号（如 25fps 下出现 :25） */
function secondsToTimecode(sec, fps) {
  var f = Number(fps) || 25;
  var fpsR = Math.max(1, Math.round(f));
  var total = Math.max(0, Math.round((Number(sec) || 0) * f));
  var ff = total % fpsR;
  var s = Math.floor(total / fpsR);
  var hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  return [hh, mm, ss, ff].map(function (n) { return (n < 10 ? '0' : '') + n; }).join(':');
}

/* ------------------------------ 设置持久化 ------------------------------ */
/* 目录和预设只选一次：避免每次导出都弹保存对话框，否则「一键导出」不成立 */

var SETTINGS_KEY = 'sourceMarker.settings.v1';
var SET = readSettings();

function readSettings() {
  var def = { presetPath: '', outDir: '', outName: '{clip}_in{in}', strategy: 'sequence', runBatch: true, mpvPath: '', autoRefresh: true, srcMs: 2000, mkMs: 5000, autoMk: true, followNudge: true };
  try {
    var raw = window.localStorage.getItem(SETTINGS_KEY);
    if (raw) {
      var o = JSON.parse(raw);
      for (var k in def) { if (o && o[k] != null) def[k] = o[k]; }
    }
  } catch (e) {}
  return def;
}
function saveSettings() {
  try {
    SET.presetPath = document.getElementById('presetPath').value.trim();
    SET.outDir = document.getElementById('outDir').value.trim();
    SET.outName = document.getElementById('outName').value.trim() || '{clip}_in{in}';
    SET.strategy = document.getElementById('strategy').value;
    SET.runBatch = document.getElementById('runBatch').checked;
    SET.autoRefresh = document.getElementById('autoRefresh').checked;
    SET.srcMs = parseInt(document.getElementById('srcMs').value, 10) || 2000;
    SET.mkMs = parseInt(document.getElementById('mkMs').value, 10) || 5000;
    SET.autoMk = document.getElementById('autoMk').checked;
    SET.followNudge = document.getElementById('followNudge').checked; SET.iterStamp = document.getElementById('iterStamp').checked;
    window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(SET));
  } catch (e) { log('设置保存失败: ' + e.message, 'err'); }
}
function applySettings() {
  document.getElementById('presetPath').value = SET.presetPath;
  document.getElementById('outDir').value = SET.outDir;
  document.getElementById('outName').value = SET.outName;
  document.getElementById('strategy').value = SET.strategy;
  document.getElementById('runBatch').checked = SET.runBatch !== false;
  document.getElementById('autoRefresh').checked = SET.autoRefresh !== false;
  document.getElementById('srcMs').value = SET.srcMs || 2000;
  document.getElementById('mkMs').value = SET.mkMs || 5000;
  document.getElementById('autoMk').checked = SET.autoMk !== false;
  document.getElementById('followNudge').checked = SET.followNudge !== false; document.getElementById('iterStamp').checked = SET.iterStamp === true;
}

/* ------------------------------ 输出路径拼装 ------------------------------ */

function safeName(s) {
  return String(s).replace(/[\\\/:*?"<>|]+/g, '_').replace(/\s+/g, ' ').trim() || 'clip';
}

/* 素材名通常自带扩展名（25帧...修复2.0.mp4），直接塞进 {clip} 会变成
   "名字.mp4_in00-00-10-00.mp4"。默认去掉尾部媒体扩展名。 */
var MEDIA_EXT = /\.(mp4|m4v|mov|mxf|avi|mkv|webm|flv|wmv|mpg|mpeg|mts|m2ts|r3d|braw|crm|ari|dng|m4a|wav|mp3|aif|aiff|aac|flac|png|jpe?g|tiff?|dpx|exr|psd|gif)$/i;
function stripMediaExt(s) {
  return String(s == null ? '' : s).replace(MEDIA_EXT, '');
}
function pad2(n) { return (n < 10 ? '0' : '') + n; }

function buildOutputPath(dir, ext) {
  var tpl = document.getElementById('outName').value.trim() || '{clip}_in{in}';
  var d = new Date();
  var name = tpl
    .replace(/\{clip\}/g, stripMediaExt(STATE.clipName) || 'clip')
    .replace(/\{in\}/g, secondsToTimecode(STATE.inSec, STATE.fps).replace(/[:;]/g, '-'))
    .replace(/\{out\}/g, secondsToTimecode(STATE.outSec, STATE.fps).replace(/[:;]/g, '-'))
    .replace(/\{date\}/g, '' + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
                          '-' + pad2(d.getHours()) + pad2(d.getMinutes()));
  var sep = dir.indexOf('\\') >= 0 ? '\\' : '/';
  var base = dir.replace(/[\\\/]+$/, '');
  // 模板里已自带扩展名就以它为准（用于没有活动序列、查不到预设扩展名时的手动覆盖）
  var m = name.match(/\.([A-Za-z0-9]{2,5})$/);
  if (m) return base + sep + safeName(name.slice(0, -m[0].length)) + m[0];
  return base + sep + safeName(name) + '.' + ext;
}

/* ------------------------------ 结构化文件解析 ------------------------------ */

function detectDelimiter(head) {
  if (head.indexOf('\t') >= 0) return '\t';
  var sc = (head.match(/;/g) || []).length, cc = (head.match(/,/g) || []).length;
  return sc > cc ? ';' : ',';
}

function parseCSV(text) {
  var firstLine = text.split(/\r?\n/)[0] || '';
  var delim = detectDelimiter(firstLine);
  var rows = [], row = [], cur = '', inQ = false;
  for (var i = 0; i < text.length; i++) {
    var c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { cur += '"'; i++; } else inQ = false; }
      else cur += c;
    } else if (c === '"') inQ = true;
    else if (c === delim) { row.push(cur); cur = ''; }
    else if (c === '\n') { row.push(cur); rows.push(row); row = []; cur = ''; }
    else if (c !== '\r') cur += c;
  }
  if (cur !== '' || row.length) { row.push(cur); rows.push(row); }
  return rows.filter(function (r) { return r.some(function (x) { return String(x).trim() !== ''; }); });
}

var KEY_TIME = /^(time|tc|timecode|start|in|timestamp|时间|时间码|时间戳|起始)$/i;
var KEY_NAME = /^(name|title|label|名称|标题|标签)$/i;
var KEY_DESC = /^(comment|comments|desc|description|content|text|note|notes|内容|备注|描述|正文|说明)$/i;
var KEY_COLOR = /^(color|colour|颜色)$/i;

function mapColumns(header) {
  var m = { time: 0, name: -1, desc: -1, color: -1 };
  header.forEach(function (h, i) {
    h = String(h).trim();
    if (KEY_TIME.test(h)) m.time = i;
    else if (KEY_NAME.test(h)) m.name = i;
    else if (KEY_DESC.test(h)) m.desc = i;
    else if (KEY_COLOR.test(h)) m.color = i;
  });
  return m;
}

function rowsToMarkers(rows, fps) {
  if (!rows.length) return [];
  var header = rows[0].map(function (s) { return String(s).trim(); });
  // 首格若能解析成时间 → 这是数据行；否则再看是否命中列名关键词
  var hasHeader = isNaN(parseTimeToSeconds(header[0], fps)) &&
                  header.some(function (h) { return KEY_TIME.test(h) || KEY_NAME.test(h) || KEY_DESC.test(h); });
  var map = hasHeader ? mapColumns(header) : { time: 0, name: 1, desc: 2, color: 3 };
  var body = hasHeader ? rows.slice(1) : rows;
  var out = [];
  body.forEach(function (r) {
    var sec = parseTimeToSeconds(r[map.time], fps);
    if (isNaN(sec)) return;
    out.push({
      sec: sec,
      name: map.name >= 0 ? String(r[map.name] || '').trim() : '',
      desc: map.desc >= 0 ? String(r[map.desc] || '').trim() : '',
      color: map.color >= 0 ? String(r[map.color] || '').trim() : ''
    });
  });
  return out;
}

function parseSRT(text) {
  var out = [];
  text.split(/\r?\n\r?\n/).forEach(function (block) {
    var lines = block.split(/\r?\n/).filter(function (l) { return l.trim() !== ''; });
    if (lines.length < 2) return;
    var tl = lines.find(function (l) { return l.indexOf('-->') >= 0; });
    if (!tl) return;
    var start = tl.split('-->')[0].trim().replace(',', '.');
    var p = start.split(':');
    var sec = p.length === 3 ? (+p[0]) * 3600 + (+p[1]) * 60 + parseFloat(p[2]) : NaN;
    if (isNaN(sec)) return;
    var textLines = lines.slice(lines.indexOf(tl) + 1);
    out.push({ sec: sec, name: '', desc: textLines.join(' ').trim(), color: '' });
  });
  return out;
}

function parseJSONMarkers(text, fps) {
  var data = JSON.parse(text);
  if (!Array.isArray(data)) data = data.markers || data.data || [];
  return data.map(function (o) {
    var t = o.time != null ? o.time : (o.tc != null ? o.tc : (o.start != null ? o.start : o.startTime));
    return {
      sec: parseTimeToSeconds(t, fps),
      name: String(o.name || o.title || o.label || ''),
      desc: String(o.comment || o.comments || o.desc || o.description || o.text || o.note || ''),
      color: String(o.color || o.colour || '')
    };
  }).filter(function (m) { return !isNaN(m.sec); });
}

function parseMarkerFile(text, fps) {
  var t = text.trim();
  if (t.charAt(0) === '[' || t.charAt(0) === '{') {
    try { return parseJSONMarkers(t, fps); } catch (e) { log('JSON 解析失败: ' + e.message, 'err'); return []; }
  }
  if (/^\d+\s*\r?\n\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->/.test(t)) return parseSRT(t);
  return rowsToMarkers(parseCSV(t), fps);
}

/* 把标记数组编成宿主 payload。
   协议用 \n 当记录分隔符、US(\x1f) 当字段分隔符，所以字段里的 CR/LF/US 必须先折叠成空格，
   否则含换行的备注会被 JSX 侧拆成两行（备注截断、颜色丢失）。
   颜色按标记交换格式 v1 §4 clamp 到 0..7。 */
function buildImportPayload(markers) {
  return markers.map(function (m) {
    function flat(s) {
      return String(s == null ? '' : s).replace(/[\r\n\u001f]+/g, ' ');
    }
    var color = Math.floor(Number(m.color));
    if (isNaN(color) || color < 0 || color > 7) color = 0;
    return [Number(m.sec).toFixed(3), flat(m.name), flat(m.desc), flat(color)].join(US);
  }).join('\n');
}

/* ------------------------------ 状态刷新 ------------------------------ */

/* ------------------------------ 自动刷新 ------------------------------
   Pr 的 ExtendScript 侧没有「源监视器变了」「标记变了」的回调，也没有事件通道，只能轮询。
   分两路，间隔都能在面板上填（选择会记住）：
     · 源状态：smGetState，很轻，默认 2 秒
     · 标记列表：smListMarkers，重一些，默认 5 秒
   纪律（都是为稳定性与开销）：
     1) 上一次没回来就不发下一次（请求不叠加）
     2) 源状态没变就不动界面；**标记内容没变就不重绘列表**
        （否则每轮重绘会把滚动位置和选中项冲掉）
     3) 正在输入的时间码框不覆盖（否则轮询会把用户打的字擦掉）
     4) 某次源状态查询卡住超 10 秒就警告一次并放行，避免轮询永久停摆
   「自动刷新」勾选框可随时关掉。 */
var AUTO = {
  srcTimer: null, srcBusy: false, srcSince: 0, srcWarned: false,
  mkTimer: null, mkBusy: false,
  sig: '',                 // 标记列表的内容签名：没变就不重绘
  count: -1, clip: null
};

function setFieldIfIdle(id, value) {
  var el = document.getElementById(id);
  if (!el) return;
  if (document.activeElement === el) return;   // 正在输入：别擦掉用户打的字
  el.value = value;
}

function autoOn() {
  var box = document.getElementById('autoRefresh');
  return !!(box && box.checked);
}

/* 面板上填的间隔：非法/过小一律夹到安全范围，免得填 0 把 Pr 轮询死 */
function intervalFrom(id, dflt) {
  var v = parseInt(document.getElementById(id).value, 10);
  if (isNaN(v)) v = dflt;
  if (v < 300) v = 300;
  if (v > 60000) v = 60000;
  return v;
}

function autoSrcTick() {
  if (!autoOn()) return;
  if (AUTO.srcBusy) {
    if (!AUTO.srcWarned && (Date.now() - AUTO.srcSince) > 10000) {
      AUTO.srcWarned = true;
      log('自动刷新：上一次状态查询超过 10 秒未返回，已放行继续（手动刷新不受影响）', 'err');
      AUTO.srcBusy = false;
    }
    return;
  }
  AUTO.srcBusy = true;
  AUTO.srcSince = Date.now();
  refresh().then(function () {
    AUTO.srcBusy = false;
    AUTO.srcWarned = false;
    /* 这里**不再**顺手刷标记列表：标记列表有自己的开关（autoMk）与节拍。
       r21 真机反馈：取消「自动刷新」后换素材时标记栏也不刷新了 —— 两路必须互不依赖。 */
  }, function () { AUTO.srcBusy = false; });
}

/* 标记列表这一路：按**内容签名**判断，覆盖"改颜色 / 改 comment / 在时间轴上拖动标记"
   这些**不改变标记条数**的编辑（r7 只按条数判断，所以那几种情况一直刷不出来）。
   它有**自己的开关** autoMk —— 源状态那一路关掉，这里照样刷。 */
function autoOnMk() {
  var box = document.getElementById('autoMk');
  return !!(box && box.checked);
}

function autoMkTick() {
  if (!autoOnMk() || AUTO.mkBusy) return;
  AUTO.mkBusy = true;
  /* 直接 loadMarkers()：引擎读的是"当前源素材"的标记，所以换素材会自动跟上，
     不依赖源状态那一路。内容签名没变时 renderMarkers 不重绘（滚动与选中都保住）。 */
  loadMarkers().then(function () { AUTO.mkBusy = false; },
                     function () { AUTO.mkBusy = false; });
}

function restartAuto() {
  if (AUTO.srcTimer) { clearInterval(AUTO.srcTimer); AUTO.srcTimer = null; }
  if (AUTO.mkTimer)  { clearInterval(AUTO.mkTimer);  AUTO.mkTimer = null; }
  var a = intervalFrom('srcMs', 2000), b = intervalFrom('mkMs', 5000);
  document.getElementById('srcMs').value = a;
  document.getElementById('mkMs').value = b;
  AUTO.srcTimer = setInterval(autoSrcTick, a);
  AUTO.mkTimer = setInterval(autoMkTick, b);
  return { src: a, mk: b };
}

function refresh() {
  return callJSX('smGetState').then(function (res) {
    if (!res.ok) {
      document.getElementById('clipName').textContent = '（源监视器为空）';
      document.getElementById('clipPath').textContent = '';
      document.getElementById('tcLine').textContent = '入点 — / 出点 —';
      STATE.markers = [];
      return;
    }
    var f = res.fields;
    STATE.fps = parseFloat(f[6]) || 25;
    STATE.inSec = parseFloat(f[2]);
    STATE.outSec = parseFloat(f[3]);
    STATE.clipName = f[0];
    STATE.clipPath = f[1];
    STATE.markerCount = Number(f[7]) || 0;   // 标记数变了就自动刷新列表
    document.getElementById('clipName').textContent = f[0];
    document.getElementById('clipPath').textContent = f[1];
    document.getElementById('tcLine').textContent =
      'in ' + secondsToTimecode(STATE.inSec, STATE.fps) + ' / out ' + secondsToTimecode(STATE.outSec, STATE.fps) +
      '  (' + STATE.fps.toFixed(2) + 'fps, ' + f[7] + ' markers)';
  });
}

/* ------------------------------ 事件绑定 ------------------------------ */

function on(id, fn) { document.getElementById(id).addEventListener('click', fn); }

on('btnRefresh', function () { refresh(); });
on('autoRefresh', function () {
  saveSettings();
  log('源状态自动刷新：' + (document.getElementById('autoRefresh').checked ? '开' : '关') +
      '（每 ' + (parseInt(document.getElementById('srcMs').value, 10) || 2000) + ' ms）');
});
on('autoMk', function () {
  saveSettings();
  log('标记列表自动刷新：' + (document.getElementById('autoMk').checked ? '开' : '关') +
      '（每 ' + (parseInt(document.getElementById('mkMs').value, 10) || 5000) + ' ms）');
});
on('followNudge', function () {
  saveSettings();
  log('微调后跟随播放头：' + (document.getElementById('followNudge').checked ? '开' : '关'));
});

/* 「播放源 / 暂停源」：app.sourceMonitor.play 是**唯一**可用的源监视器控制入口。
   真机实测：play(1) 真的播源；play(0) 功能上停住，但 Pr 的传送按钮会显示成"暂停"
   （"以 0 速播放"的 UI 表现）。它**不会**改变活动监视器，所以按空格仍按 Pr 自己的规矩走。
   好处是：**即使活动监视器是节目，也能从面板直接播源**，不必再去点 Pr 的监视器。
   在 Pr 里自己按了空格/停之后，本按钮文案可能暂时滞后 —— 再按一次即可对齐。 */
var PLAYING = false;
on('btnPlaySource', function () {
  var btn = document.getElementById('btnPlaySource');
  var next = PLAYING ? 0 : 1;
  callJSX('smPlaySource', next).then(function (r) {
    log((r.ok ? '' : '播放源失败：') + describe(r), r.ok ? 'ok' : 'err');
    if (r.ok) {
      PLAYING = (next === 1);
      btn.textContent = PLAYING ? '暂停源' : '播放源';
    }
  });
});
on('btnClearLog', function () {
  document.getElementById('log').innerHTML = '';
  log('日志已清空');
});
['srcMs', 'mkMs'].forEach(function (id) {
  document.getElementById(id).addEventListener('change', function () {
    var r = restartAuto();
    saveSettings();
    log('自动刷新间隔已改：源状态 ' + r.src + ' ms，标记列表 ' + r.mk + ' ms');
  });
});

/* Delete 删除标记：**两段式**，防手滑。
   第一次按 → 该行变红，日志提示"再按一次"；3 秒内再按同一个键才真的删。
   不用 window.confirm —— CEP（CEF）里 confirm/prompt 常被禁用，属于不可验证的坑。 */
document.addEventListener('keydown', function (ev) {
  if (ev.key !== 'Delete' && ev.key !== 'Del') return;
  var ae = document.activeElement;
  if (ae && (ae.tagName === 'INPUT' || ae.tagName === 'SELECT' || ae.tagName === 'TEXTAREA')) return;
  if (SELECTED < 0 || SELECTED >= MARKERS.length) return;
  ev.preventDefault();
  var m = MARKERS[SELECTED];
  if (ARMED_SEC != null && Math.abs(ARMED_SEC - m.sec) < 0.0005 && (Date.now() - ARMED_AT) < 3000) {
    callJSX('smDeleteMarker', SELECTED, m.sec).then(function (r) {
      log((r.ok ? '已删除标记：' : '删除失败：') + describe(r), r.ok ? 'ok' : 'err');
      ARMED_SEC = null;
      SELECTED_SEC = null;
      loadMarkers(true);                    // 强制回读，确认标记真的从项目项上没了
    });
    return;
  }
  ARMED_SEC = m.sec;
  ARMED_AT = Date.now();
  applySelection();
  log('再按一次 Delete 就会删除「' + markerRowText(m) + '」（3 秒内有效）', 'warn');
});

/* 编辑条的按钮与键盘 —— 只绑一次，不是每条标记都绑 */
on('mkEditOk', function () { finishEdit(true); });
document.getElementById('mkEditCancel').addEventListener('mousedown', function (ev) {
  ev.preventDefault();                 // 抢在 blur 之前，否则"失焦提交"会先跑
  finishEdit(false);
});
document.getElementById('mkEditText').addEventListener('keydown', function (ev) {
  if (ev.key === 'Enter') { ev.preventDefault(); finishEdit(true); }
  else if (ev.key === 'Escape') { ev.preventDefault(); finishEdit(false); }
});
document.getElementById('mkEditText').addEventListener('blur', function () { finishEdit(true); });

on('btnApply', function () {
  var i = parseTimeToSeconds(document.getElementById('InTc').value, STATE.fps);
  var o = parseTimeToSeconds(document.getElementById('OutTc').value, STATE.fps);
  if (isNaN(i) || isNaN(o)) { log('入点/出点时间格式无法解析', 'err'); return; }
  callJSX('smSetInOut', i, o).then(function (r) {
    log((r.ok ? '入点和出点已设置: ' : '失败: ') + describe(r), r.ok ? 'ok' : 'err');
    refresh();
  });
});

/* 微调之后让播放头跟过去。**必须节流** —— r21 真机踩过：
   连按 In＋/Out＋ 十来次后 Pr 会卡死（按钮与播放头全部没反应）。
   原因：跟随跳转走的是 QE 的 scrubTo，短时间内被反复调用把源监视器 wedged 住；
   `＋` 要向前解码、比 `−` 重，所以只有 `＋` 先崩。
   对策两条：① 防抖 + 同一时刻只允许一个在飞（排队合并成最后一次）
            ② 给个开关，用户可以整体关掉跟随。 */
var FOLLOW = { timer: null, busy: false, pending: null, ms: 400 };

function followSeek(sec) {
  FOLLOW.pending = sec;
  if (FOLLOW.timer) { clearTimeout(FOLLOW.timer); FOLLOW.timer = null; }
  FOLLOW.timer = setTimeout(function () {
    FOLLOW.timer = null;
    if (FOLLOW.busy) return;                       // 上一次还没回来：跳过这一拍，等它回来后再补
    var t = FOLLOW.pending;
    FOLLOW.pending = null;
    if (t == null) return;
    FOLLOW.busy = true;
    callJSX('smSeekSeconds', t).then(function (r) {
      FOLLOW.busy = false;
      if (!r.ok) log('播放头跟随失败（不影响微调本身）：' + describe(r), 'warn');
      else if (FOLLOW.pending != null) followSeek(FOLLOW.pending);
    }, function () { FOLLOW.busy = false; });
  }, FOLLOW.ms);
}

/* 连按 ± 时**绝不能让请求叠加**：callJSX 是异步的，快速连点会把 Pr 的脚本队列堆起来，
   真机表现正是"按几下之后整个卡死、按钮和播放头全没反应"（r21 反馈）。
   纪律与自动刷新那两路同一套：**同一时刻只允许一个在飞**，期间按的累加成净值，回来后再发一次。 */
var NUDGE = { busy: false, since: 0, warned: false, inFrames: 0, outFrames: 0 };

function nudge(which, sign) {
  var n = Number(document.getElementById('nudge').value) || 1;
  if (String(which) === 'out') NUDGE.outFrames += sign * n;
  else NUDGE.inFrames += sign * n;
  nudgePump();
}

function nudgePump() {
  if (NUDGE.busy) {
    /* 看门狗：卡住时**绝不能**默默不说话 —— 否则"守卫"会把一次真卡死
       变成"按钮永远没反应"，比卡住更难查。与自动刷新同一套纪律。 */
    if (!NUDGE.warned && (Date.now() - NUDGE.since) > 10000) {
      NUDGE.warned = true;
      log('微调：上一次调用超过 10 秒没返回 —— Pr 可能已经卡住（你按的会排队，不会丢）', 'err');
      NUDGE.busy = false;
    }
    return;                                     // 有在飞的：先攒着
  }
  var which = null, frames = 0;
  if (NUDGE.inFrames !== 0) { which = 'in'; frames = NUDGE.inFrames; NUDGE.inFrames = 0; }
  else if (NUDGE.outFrames !== 0) { which = 'out'; frames = NUDGE.outFrames; NUDGE.outFrames = 0; }
  if (!which) return;
  NUDGE.busy = true;
  NUDGE.since = Date.now();
  NUDGE.warned = false;
  callJSX('smNudge', which, frames).then(function (r) {
    NUDGE.busy = false;
    if (!r.ok) log('微调失败（' + which + ' ' + frames + ' 帧）: ' + describe(r), 'warn');
    else {
      var d = describe(r);
      /* 引擎的 ok=true 只代表"调用没报错"，**不代表值真的动对了** ——
         判定写在字段里（VERIFIED / MISMATCH-CHECK）。所以按判定上色，
         否则 MISMATCH 会被刷成绿色的 OK，又是一次"制造虚假把握"。 */
      log('微调 ' + (which === 'out' ? '出点' : '入点') + ' ' + (frames > 0 ? '+' : '') + frames +
          ' 帧 → ' + d, (d.indexOf('VERIFIED') >= 0) ? 'ok' : 'warn');
      refresh();
      var sec = parseFloat(r.fields[0]);
      if (!isNaN(sec) && document.getElementById('followNudge').checked) followSeek(sec);
    }
    nudgePump();                                // 期间又按过 → 接着发
  }, function () { NUDGE.busy = false; });
}
on('inMinus', function () { nudge('in', -1); });
on('inPlus', function () { nudge('in', 1); });
on('outMinus', function () { nudge('out', -1); });
on('outPlus', function () { nudge('out', 1); });

/* 【已删除】「← 序列入出点」「源入出点 →」两个按钮与其宿主函数一并清理：
   序列入出点是**时间线上的位置**、片段入出点是**素材内部的位置**，坐标系不同，
   直接搬运数值一般没有意义。原因与"要恢复请先定清语义"见 改动说明 §15。 */
on('btnClear', function () {
  callJSX('smClearInOut').then(function (r) {
    log((r.ok ? '已清除源入点和出点' : '失败: ' + describe(r)), r.ok ? 'ok' : 'err');
    refresh();
  });
});
on('btnProbeQE', function () {
  callJSX('smProbeQE').then(function (r) { log('QE 探测: ' + describe(r), r.ok ? 'ok' : 'err'); });
});

on('btnSelfTest', function () {
  log('开始自检（会临时创建一个子剪辑再删除，仅影响项目面板）…');
  callJSX('smSelfTest').then(function (r) {
    var report = r.ok ? r.fields.join(US) : describe(r);
    report.split('\n').forEach(function (l) { log(l, r.ok ? '' : 'err'); });
  });
});

/* --------------------- 标记列表 + 点击跳转 --------------------- */

var RS = String.fromCharCode(30), GS = String.fromCharCode(29);
var MARKERS = [];
var FILE_MARKERS = [];

/* 标记颜色：参考色值取自格式文档 §4（只用于界面展示，不参与交换）。
   索引读不到（-1）时返回空串，回到默认文字色。 */
var MARKER_COLORS = ['#718637', '#D22C36', '#AF8BB1', '#E96F24', '#D0A12B', '#FFFFFF', '#428DFC', '#19F4D6'];
/* ①共享颜色表（1.2.0「交织」）：上面这份是**回退**，启动时会尝试从扩展目录读
   marker-colors.json（安装器从包内 mpv-player\portable_config\ 拷进来）。
   只有整表合法（8 条、索引 0..7、hex 合法）才采用，否则保留回退并在日志里说明原因。 */
var COLOR_TABLE_STATE = '内置回退表';
function loadSharedColors() {
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.readFile !== 'function') {
      COLOR_TABLE_STATE = '内置回退表（CEP 不支持读文件）'; return;
    }
    var dir = (typeof SystemPath !== 'undefined' && cs && typeof cs.getSystemPath === 'function')
      ? cs.getSystemPath(SystemPath.EXTENSION) : '';
    if (!dir) { COLOR_TABLE_STATE = '内置回退表（取不到扩展目录）'; return; }
    var p = dir + '/marker-colors.json';
    var r = window.cep.fs.readFile(p, window.cep.fs.UTF8);
    if (!r || r.err !== 0 || !r.data) { COLOR_TABLE_STATE = '内置回退表（共享表读不出，err=' + (r ? r.err : 'null') + '）'; return; }
    var d = JSON.parse(r.data);
    var list = d && d.colors;
    if (!list || list.length !== 8) { COLOR_TABLE_STATE = '内置回退表（共享表不是 8 条）'; return; }
    var fresh = [];
    for (var i = 0; i < list.length; i++) {
      var n = Number(list[i].index), h = String(list[i].hex || '');
      if (!(n >= 0 && n <= 7) || !/^[0-9A-Fa-f]{6}$/.test(h)) { COLOR_TABLE_STATE = '内置回退表（有条目不合法）'; return; }
      fresh[n] = '#' + h.toUpperCase();
    }
    for (var k = 0; k < 8; k++) { if (!fresh[k]) { COLOR_TABLE_STATE = '内置回退表（共享表缺索引 ' + k + '）'; return; } }
    MARKER_COLORS = fresh;
    COLOR_TABLE_STATE = '共享表 ' + p;
  } catch (e) { COLOR_TABLE_STATE = '内置回退表（' + e.message + '）'; }
}
function markerColorCss(idx) {
  var n = Number(idx);
  if (isNaN(n) || n < 0 || n > 7) return '';
  return MARKER_COLORS[Math.floor(n)];
}
function decorateRow(row, colorIdx) {
  var c = markerColorCss(colorIdx);
  if (c) { row.style.color = c; row.style.borderLeft = '3px solid ' + c; row.style.paddingLeft = '5px'; }
}
/* 正文取值规则（显示与导出**必须**共用这一个函数，否则两边会各说各话）：
   优先用显式算好的 text（源标记 = name||comments，文件侧 = comment 列）；
   兜底也必须是 **name 在前** —— Pr 的标记文本在 name 属性里（见 loadMarkers 的说明）。 */
function markerBody(m) {
  return (m.text != null) ? m.text : (m.name || m.desc || '');
}
function markerRowText(m) {
  // 显示时把换行折叠成空格（引擎原样回传，好让导出不丢字符；见契约 §6.5）
  return secondsToTimecode(m.sec, STATE.fps) + '  ' + String(markerBody(m)).replace(/[\r\n]+/g, ' ');
}

/* 导出用的一行：把「可显示正文」映射到编码器的 desc 字段。
   这里**不能**写成 m.desc —— Pr 的标记文本在 name 属性里。 */
function toExportRow(m) {
  return { sec: m.sec, desc: markerBody(m), color: m.color };
}

function loadMarkers(force) {
  return callJSX('smListMarkers').then(function (r) {
    var next = [];
    if (r.ok && r.fields[1]) {
      r.fields[1].split(GS).forEach(function (rec) {
        if (!rec) return;
        var f = rec.split(RS);
        var sec = parseFloat(f[0]);
        if (!isNaN(sec)) {
          next.push({ sec: sec, name: f[1] || '', desc: f[2] || '',
                      // 可显示/可导出的正文。**别只读 comments**：引擎的 smImportMarkers 是把
                      // 文件的 comment 列写进 Pr 的 name 属性、同时把 comments 置空的，
                      // 所以正文在 name 里（Pr 界面显示的也是它）。两个都兜住，name 优先。
                      text: (f[1] || f[2] || ''),
                      color: (f[3] === undefined ? -1 : parseInt(f[3], 10)) });
        }
      });
    }
    MARKERS = next;
    // 内容签名：时间/正文/颜色都算进去。只按条数判断会漏掉"改内容"和"拖时间轴"（r7 的毛病）。
    var sig = MARKERS.map(function (m) { return m.sec + '|' + m.text + '|' + m.color; }).join('\n');
    if (force || sig !== AUTO.sig) { AUTO.sig = sig; renderMarkers(); }
    return MARKERS.length;
  });
}

/* --------------------- 标记的选中 / 编辑 / 删除 ---------------------
   选中按**时间**记（不是下标）—— 自动刷新会重绘列表，按下标记会错位。
   编辑与删除都带上"期望时间"交给引擎二次校验，对不上就不动手。 */
var SELECTED_SEC = null, SELECTED = -1, ARMED_SEC = null, ARMED_AT = 0;
var SEL_BG = '#33507a', ARMED_BG = '#7a2f2f';

function applySelection() {
  var box = document.getElementById('markerList');
  var rows = box.getElementsByClassName('mk');
  for (var k = 0; k < rows.length; k++) { rows[k].style.background = ''; }
  SELECTED = -1;
  if (SELECTED_SEC == null) return;
  for (var j = 0; j < MARKERS.length && j < rows.length; j++) {
    if (Math.abs(MARKERS[j].sec - SELECTED_SEC) < 0.0005) {
      SELECTED = j;
      var armed = (ARMED_SEC != null) && Math.abs(ARMED_SEC - MARKERS[j].sec) < 0.0005 &&
                  (Date.now() - ARMED_AT) < 3000;
      rows[j].style.background = armed ? ARMED_BG : SEL_BG;
      return;
    }
  }
}

/* 双击改正文。**优先走原生对话框**（引擎的 ExtendScript prompt()）：
   CEP 面板里中文输入法的候选浮窗位置不可靠（CEF 老毛病，把输入框移出滚动容器也没解决），
   而原生模态对话框里输入法是正常的。引擎若回"没有 prompt"，再退回面板内编辑条。 */
var EDIT = null;

function applyMarkerText(idx, sec, v) {
  callJSX('smSetMarkerText', idx, sec, v).then(function (r) {
    log((r.ok ? '已改标记正文：' : '改正文失败：') + describe(r), r.ok ? 'ok' : 'err');
    loadMarkers(true);                                            // 强制回读，确认真的落到项目项上
  });
}

function startEditMarker(m, idx) {
  var cur = markerBody(m);
  var label = '修改标记正文（' + secondsToTimecode(m.sec, STATE.fps) + '）';
  callJSX('smPromptText', label, cur).then(function (r) {
    if (r.ok) {
      var v = r.fields[0];
      if (v === cur) { log('正文未改动'); return; }
      applyMarkerText(idx, m.sec, v);
      return;
    }
    var why = String((r.fields && r.fields[0]) || '');
    if (why.indexOf('cancelled') >= 0) { log('已取消编辑'); return; }
    log('原生输入框不可用（' + why + '），改用面板内编辑条（中文候选窗可能摆不正）', 'warn');
    showEditStrip(m, idx);
  });
}

/* 面板内编辑条：仅在原生 prompt 不可用时作为退路 */
function showEditStrip(m, idx) {
  EDIT = { idx: idx, sec: m.sec, text: markerBody(m) };
  document.getElementById('mkEditLabel').textContent = secondsToTimecode(m.sec, STATE.fps);
  var inp = document.getElementById('mkEditText');
  inp.value = EDIT.text;
  document.getElementById('mkEditRow').style.display = '';
  inp.focus();
  inp.select();
}

/* Enter 提交 / Esc 取消 / 失焦提交。
   取消按钮用 mousedown 而不是 click —— 要抢在 blur 的"失焦提交"之前跑。 */
function finishEdit(commit) {
  if (!EDIT) return;
  var e = EDIT;
  EDIT = null;
  document.getElementById('mkEditRow').style.display = 'none';
  var v = document.getElementById('mkEditText').value;
  if (!commit || v === e.text) { renderMarkers(); return; }      // 取消或没改 → 重绘还原
  applyMarkerText(e.idx, e.sec, v);
}

function renderMarkers() {
  var box = document.getElementById('markerList');
  var cap = document.getElementById('srcCount');
  if (cap) cap.textContent = MARKERS.length ? '（' + MARKERS.length + ' 条）' : '';
  box.innerHTML = '';
  if (!MARKERS.length) {
    var e = document.createElement('div');
    e.className = 'hint';
    e.textContent = '（无标记）';
    box.appendChild(e);
    return;
  }
  MARKERS.forEach(function (m, i) {
    var row = document.createElement('div');
    row.className = 'mk';
    decorateRow(row, m.color);
    row.textContent = markerRowText(m);
    row.title = markerRowText(m) + '\n单击：选中并跳到该标记\n双击：改正文\n选中后按 Delete：删除（按两次确认）';
    row.addEventListener('click', function () {
      SELECTED_SEC = m.sec;
      ARMED_SEC = null;
      applySelection();
      seekTo(m.sec);
      // 这里**不再**偷偷碰 app.sourceMonitor.play：真机实测它既不改变活动监视器，
      // 又会把源监视器的传送按钮留在"暂停"外观上（纯粹是副作用）。见改动说明 §14.6。
    });
    row.addEventListener('dblclick', function () { startEditMarker(m, i); });
    box.appendChild(row);
  });
  applySelection();   // 重绘后把选中状态恢复回来（选中是按时间记的）
}

/* --------------------- 右栏：文件里的标记（对照用） ---------------------
   选完文件立刻解析并渲染 —— 点「导入」之前就能和左栏对照。
   解析用面板自己的 parseMarkerFile()，不经过引擎。 */
function renderFileMarkers() {
  var box = document.getElementById('fileMarkerList');
  if (!box) return;
  var cap = document.getElementById('fileCount');
  if (cap) cap.textContent = FILE_MARKERS.length ? '（' + FILE_MARKERS.length + ' 条）' : '';
  box.innerHTML = '';
  if (!FILE_MARKERS.length) {
    var e = document.createElement('div');
    e.className = 'hint';
    e.textContent = markerFilePath ? '（这个文件里没解析出标记）' : '（选择文件后显示）';
    box.appendChild(e);
    return;
  }
  FILE_MARKERS.forEach(function (m) {
    var row = document.createElement('div');
    row.className = 'mk';
    decorateRow(row, m.color);
    row.textContent = markerRowText(m);
    row.title = markerRowText(m) + '\n（文件里的这一条，导入后会成为源监视器的标记）';
    box.appendChild(row);
  });
}

/* 选完文件立即预览：读文件走引擎的 smReadTextFile，解析用面板自己的 parseMarkerFile */
function previewFileMarkers() {
  if (!markerFilePath) { FILE_MARKERS = []; renderFileMarkers(); return; }
  readTextFile(markerFilePath).then(function (text) {
    if (text == null) { FILE_MARKERS = []; log('读取文件失败，无法预览', 'err'); renderFileMarkers(); return; }
    // 文件里的正文取 comment 列（契约 §1.2：name 列读取方整列忽略）
    FILE_MARKERS = parseMarkerFile(text, STATE.fps).map(function (m) { m.text = m.desc || ''; return m; });
    renderFileMarkers();
    log('文件里解析出 ' + FILE_MARKERS.length + ' 条标记（右栏）；确认后点「导入」',
        FILE_MARKERS.length ? 'ok' : 'err');
  });
}

/* ============================== 导出编码器 ==============================
   纯函数：不碰 DOM、不碰引擎，可以整段抽出来离线测试。
   契约：《标记文件格式-v1.md》§1 CSV / §2 JSON / §3 时间 / §4 颜色。
   逐字对齐 mpv 侧写入方（source-markers.lua 的 build_csv / export_doc / to_hms_ms / to_timecode），
   这样同一批标记在两侧产出的 CSV 才能逐字节一致。 */
var EXPORT_TIME_FORMAT = 'ms';   // 规范默认。ff 需两侧帧率一致，本项目只在 JSON 的 tc 里用

function mPad2(n) { n = Math.floor(n); return n < 10 ? '0' + n : String(n); }
function mPad3(n) { n = Math.floor(n); return n < 10 ? '00' + n : (n < 100 ? '0' + n : String(n)); }

/* §3 毫秒字段（规范默认）。对齐 Lua 的 to_hms_ms：先一次性取整到整毫秒再拆位，
   保证「毫秒 → 秒」零误差，不被浮点漂移改写。 */
function msField(sec) {
  var s = Number(sec); if (!isFinite(s) || s < 0) s = 0;
  var total = Math.floor(s * 1000 + 0.5);
  var t = Math.floor(total / 1000);
  return mPad2(Math.floor(t / 3600)) + ':' + mPad2(Math.floor((t % 3600) / 60)) + ':' +
         mPad2(t % 60) + '.' + mPad3(total % 1000);
}

/* §3 时间码字段。必须用「整秒 + 真实帧率帧号 + 上界进位」，
   禁止"总帧数取模"（29.97/23.976 会线性漂移，已被 run-ntsc-test.ps1 钉死）。
   对齐 Lua 的 to_timecode：maxff = ceil(fps - 1e-9)，ff >= maxff 就进位。 */
function tcField(sec, fps) {
  var f = Number(fps); if (!isFinite(f) || f <= 0) f = 25;
  var s = Number(sec); if (!isFinite(s) || s < 0) s = 0;
  var maxff = Math.ceil(f - 1e-9); if (maxff < 1) maxff = 1;
  var whole = Math.floor(s);
  var ff = Math.floor((s - whole) * f + 0.5);
  if (ff >= maxff) { ff = 0; whole += 1; }
  if (ff < 0) ff = 0;
  return mPad2(Math.floor(whole / 3600)) + ':' + mPad2(Math.floor((whole % 3600) / 60)) + ':' +
         mPad2(whole % 60) + ':' + mPad2(ff);
}

/* §1.1 RFC4180：含 " , CR LF 时整字段加引号，内部 " 写成 ""（对齐 Lua 的 csv_field） */
function csvField(v) {
  var s = (v == null ? '' : String(v));
  return /["\r\n,]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

/* §4 写入方只输出 0..7 的整数；缺省/越界/非数字一律 0。
   注意：引擎读不到颜色时给的是 -1，这里会落到 0（契约允许的"缺省绿"）。 */
function normColor(v) {
  if (v == null || String(v).replace(/\s/g, '') === '') return 0;
  var n = Number(v);
  if (!isFinite(n)) return 0;
  n = Math.floor(n);
  return (n >= 0 && n <= 7) ? n : 0;
}

function sortedMarkers(markers) {
  return markers.slice().sort(function (a, b) { return Number(a.sec) - Number(b.sec); });  // §1.3 升序
}

/* §1 CSV 正文（不含 BOM；BOM 由写入方拼，见 exportMarkers） */
function buildMarkerCsv(markers) {
  var lines = ['time,name,comment,color'];
  sortedMarkers(markers).forEach(function (m) {
    lines.push(csvField(msField(m.sec)) + ',' +
               csvField('') + ',' +                    // name 列：保留但恒为空（§1.2）
               csvField(m.desc || '') + ',' +
               String(normColor(m.color)));
  });
  return lines.join('\r\n') + '\r\n';                  // 行尾 CRLF，末尾也给一个（对齐 Lua）
}

/* §2 JSON 文档（不带 BOM）。键序与 mpv 侧 export_doc() 一致，便于人工对照。 */
function buildMarkerJson(markers, fps, srcFile) {
  var f = Number(fps); if (!isFinite(f) || f <= 0) f = 25;
  var arr = sortedMarkers(markers).map(function (m) {
    var s = Number(m.sec); if (!isFinite(s) || s < 0) s = 0;
    return {
      time: Math.round(s * 1000) / 1000,               // §2 权威值，3 位小数
      tc: tcField(s, f),
      name: '',
      comment: m.desc || '',
      color: normColor(m.color)
    };
  });
  return JSON.stringify({
    format: 'source-markers',
    version: 1,
    created: isoUtcNow(),
    source: { file: srcFile || '', fps: f, durationSec: null, timeFormat: EXPORT_TIME_FORMAT },
    markers: arr
  }, null, 2);
}

/* 对齐 Lua 的 os.date('!%Y-%m-%dT%H:%M:%SZ')：UTC、秒精度、带 Z */
function isoUtcNow() { return new Date().toISOString().replace(/\.\d+Z$/, 'Z'); }

/* 对齐 Lua 的 safe_filename()：非法字符换 _、去首尾空白、去结尾点、保留名加 _、限 120 字符 */
var WIN_RESERVED = { CON:1, PRN:1, AUX:1, NUL:1, COM1:1, COM2:1, COM3:1, COM4:1, COM5:1,
                     COM6:1, COM7:1, COM8:1, COM9:1, LPT1:1, LPT2:1, LPT3:1, LPT4:1,
                     LPT5:1, LPT6:1, LPT7:1, LPT8:1, LPT9:1 };
function safeFileName(name) {
  var n = String(name == null ? 'stream' : name)
            .replace(/[\\/:*?"<>|]/g, '_').replace(/^\s+|\s+$/g, '').replace(/\.+$/, '');
  if (!n) n = 'stream';
  var stem = (n.match(/^[^.]+/) || [n])[0];
  if (WIN_RESERVED[stem.toUpperCase()]) n = n + '_';
  return n.length > 120 ? n.substring(0, 120) : n;
}
/* ============================ 导出编码器结束 ============================ */

/* ------------------------------ 导出当前源的标记 ------------------------------
   Pr 侧从此也是「写入方」，必须满足契约 §6 的写入方保证：
   CSV 带 BOM / CRLF / 四列 / name 写空 / 毫秒 / 升序；JSON 不带 BOM；空列表不产出文件。
   落盘约定与 mpv 侧一致：<素材名>_markers_<YYYYMMDD-HHMMSS>.csv 放在素材同目录，
   并**同时**写出同名 .json —— 这样「自动找标记」和 mpv 都能直接找到它。 */
function exportStamp() {
  var d = new Date();
  return String(d.getFullYear()) + mPad2(d.getMonth() + 1) + mPad2(d.getDate()) + '-' +
         mPad2(d.getHours()) + mPad2(d.getMinutes()) + mPad2(d.getSeconds());
}

/* 导出目标：**素材同目录**（与 mpv 侧约定一致，也让「自动找标记」直接找得到）。
   素材目录写不进去时（只读共享、权限）才退回面板里的「输出目录」。
   真机实测：Pr 的 CEP **没有** window.cep.fs.showSaveDialog（日志原文：
   「此 CEP 版本没有 showSaveDialog」），所以不做存盘对话框 —— 直接、明确。 */
function exportTargets() {
  // 与 mpv 侧看齐：默认【无戳覆盖】同名文件；勾上「另存为迭代」才带时间戳（6plus）
  var iterEl = document.getElementById('iterStamp');
  var useStamp = !!(iterEl && iterEl.checked);
  var name = safeFileName(stemOfPath(STATE.clipPath) || 'markers') + '_markers' + (useStamp ? '_' + exportStamp() : '');
  var list = [];
  var d1 = dirOfPath(STATE.clipPath);
  if (d1) list.push({ dir: d1, tag: '素材同目录' });
  var d2 = String(SET.outDir || '').replace(/[\\\/]+$/, '');
  if (d2 && d2.toLowerCase() !== String(d1).toLowerCase()) list.push({ dir: d2, tag: '面板设置的输出目录' });
  return { name: name, list: list };
}

function cepDeleteQuiet(path) {
  try {
    if (window.cep && window.cep.fs && typeof window.cep.fs.deleteFile === 'function') {
      window.cep.fs.deleteFile(path);
    }
    return true;
  } catch (e) { return false; }
}
function cepWriteFile(path, data) {
  /* 先删掉同名旧文件再写：真机踩到过 —— 目标 json 若是 mpv 侧留下的【隐藏】文件，
     CEP 的 writeFile 会直接失败（日志原文：同名 JSON 写入失败: writeFile err=6）。
     删除对隐藏文件是有效的，所以「先删后写」比直接覆盖稳。 */
  cepDeleteQuiet(path);
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.writeFile !== 'function') return 'CEP 不支持写文件';
    var enc = window.cep.fs.UTF8;
    var r = (typeof enc === 'undefined') ? window.cep.fs.writeFile(path, data)
                                         : window.cep.fs.writeFile(path, data, enc);
    if (!r || r.err !== 0) return 'writeFile err=' + (r && r.err);
    return '';
  } catch (e) { return 'writeFile 异常: ' + e.message; }
}

/* 写完立刻回读校验（本项目的一贯做法：不信"调用了"，只信"读回来的"）。
   顺带把 BOM / CRLF / 表头这些**字节层**规定也验掉 —— 恰恰是本地完全无法验证的部分。 */
function verifyExport(path, expectCount, isJson) {
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.readFile !== 'function') {
      return '（本机不支持回读，请手工确认）';
    }
    var r = window.cep.fs.readFile(path, window.cep.fs.UTF8);
    if (!r || r.err !== 0 || typeof r.data !== 'string') return '回读失败 err=' + (r && r.err);
    var txt = r.data, hasBom = txt.charCodeAt(0) === 0xFEFF;
    if (isJson && hasBom) return '⚠ JSON 不该带 BOM（契约 §2）';
    if (!isJson && !hasBom) return '⚠ CSV 缺 BOM（Excel 打开中文会乱码，契约 §1.1）';
    var body = hasBom ? txt.substring(1) : txt;
    if (!isJson) {
      if (body.indexOf('time,name,comment,color\r\n') !== 0) return '⚠ 表头或换行不符（应为四列表头 + CRLF）';
      if (body.replace(/\r\n/g, '').indexOf('\n') !== -1) return '⚠ 换行不是 CRLF';
    }
    var n = parseMarkerFile(body, STATE.fps).length;
    if (n !== expectCount) return '⚠ 回读只解析出 ' + n + ' 条（应为 ' + expectCount + '）';
    return 'OK';
  } catch (e) { return '回读异常: ' + e.message; }
}

function exportMarkers() {
  if (!STATE.clipPath) { log('源监视器里没有素材，无法导出', 'err'); return; }
  loadMarkers().then(function (n) {
    if (!n) { log('还没有标记可导出（契约 §6：空列表不产出文件）', 'err'); return; }
    var t = exportTargets();
    if (!t.list.length) { log('推不出导出目录 —— 请在设置里填「输出目录」', 'err'); return; }
    var rows = MARKERS.map(toExportRow);                                // 正文取自 markerBody
    var csvBody = '\uFEFF' + buildMarkerCsv(rows);                      // §1.1 BOM
    var jsonBody = buildMarkerJson(rows, STATE.fps, STATE.clipPath);    // §2 不带 BOM
    var csvPath = '', lastErr = '';
    for (var i = 0; i < t.list.length; i++) {
      var base = t.list[i].dir + '\\' + t.name;
      csvPath = base + '.csv';
      lastErr = cepWriteFile(csvPath, csvBody);
      if (lastErr) { log('写入失败（' + t.list[i].tag + '）：' + lastErr, 'err'); continue; }
      log('已导出 ' + n + ' 条 → ' + t.list[i].tag + '：' + csvPath, 'ok');
      var e2 = cepWriteFile(base + '.json', jsonBody);
      log(e2 ? ('同名 JSON 写入失败: ' + e2) : ('已写入同名 JSON：' + base + '.json'), e2 ? 'err' : 'ok');
      var v1 = verifyExport(csvPath, n, false);
      log('回读校验 CSV → ' + v1, v1 === 'OK' ? 'ok' : 'err');
      if (!e2) {
        var v2 = verifyExport(base + '.json', n, true);
        log('回读校验 JSON → ' + v2, v2 === 'OK' ? 'ok' : 'err');
      }
      return;
    }
    log('两个位置都写不进去：' + lastErr, 'err');
  });
}
on('btnExportMarkers', exportMarkers);
on('iterStamp', function () {
  saveSettings();
  log('导出命名：' + (document.getElementById('iterStamp').checked ? '另存为迭代（带时间戳）' : '覆盖同名文件（默认）'));
});

function seekTo(sec) {
  callJSX('smSeekSeconds', sec).then(function (r) {
    log(r.ok ? '已跳到 ' + secondsToTimecode(sec, STATE.fps) + '  ' + describe(r)
             : '跳转失败: ' + describe(r), r.ok ? 'ok' : 'err');
  });
}

on('btnListMarkers', function () {
  loadMarkers(true).then(function (n) { log('标记列表已刷新：' + n + ' 条'); });
});
on('btnSeekIn', function () { seekTo(STATE.inSec); });
on('btnSeekOut', function () { seekTo(STATE.outSec); });

on('btnCopyLog', function () {
  var el = document.getElementById('log');
  var ta = document.createElement('textarea');
  ta.value = el.innerText || el.textContent || '';
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  var ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
  document.getElementById('copyHint').textContent = ok ? '已复制到剪贴板' : '复制失败，请手动选中日志';
});

on('btnPickOutDir', function () {
  pickFolder().then(function (p) {
    if (!p) return;
    document.getElementById('outDir').value = p;
    saveSettings();
  });
});
on('btnPickPreset', function () {
  pickFile('preset').then(function (p) {
    if (!p) return;
    document.getElementById('presetPath').value = p;
    saveSettings();
  });
});

on('btnExport', function () {
  var preset = document.getElementById('presetPath').value.trim();
  var dir = document.getElementById('outDir').value.trim();
  if (!preset) { log('请先指定 .epr 预设（选一次就会记住）', 'err'); return; }
  if (!dir) { log('请先指定输出目录（选一次就会记住）', 'err'); return; }
  saveSettings();
  var strategy = document.getElementById('strategy').value;
  callJSX('smExportFileExtension', preset).then(function (er) {
    var ext = (er.ok && er.fields[0]) ? String(er.fields[0]).replace(/^\./, '') : '';
    if (!ext) log('提示：无活动序列，无法从预设反查扩展名，暂按 mp4 处理（可在文件名末尾直接写 .mov 等覆盖）');
    var out = buildOutputPath(dir, ext || 'mp4');
    callJSX('smPreflight', out, preset).then(function (pf) {
      if (!pf.ok) { log('导出前检查未通过：' + describe(pf), 'err'); return; }
      log('检查通过：' + describe(pf));
      log('输出 → ' + out);
      callJSX('smExportRange', out, preset, strategy, '').then(function (r) {
        log((r.ok ? '导出已入队: ' : '失败: ') + describe(r), r.ok ? 'ok' : 'err');
        if (r.ok && document.getElementById('runBatch').checked) {
          callJSX('smStartBatch').then(function (b) {
            log((b.ok ? '已请求 AME 开始渲染：' : '启动渲染失败：') + describe(b), b.ok ? 'ok' : 'err');
          });
        }
      });
    });
  });
});

on('btnSend', function () {
  var mode = document.getElementById('sendMode').value;
  // 界面上是 1-based（与 Pr 的 V1/A1 一致），宿主 API 是 0-based，这里换算
  var vUi = parseInt(document.getElementById('vIdx').value, 10);
  var aUi = parseInt(document.getElementById('aIdx').value, 10);
  var v = (isNaN(vUi) ? 1 : vUi) - 1;
  var a = (isNaN(aUi) ? 1 : aUi) - 1;
  if (v < 0) { log('V 轨号最小为 1', 'err'); return; }
  callJSX('smSendToSequence', mode, v, a, 1).then(function (r) {
    log((r.ok ? '已发送到序列（V' + (v + 1) + '/A' + (a + 1) + '）: ' : '失败: ') + describe(r),
        r.ok ? 'ok' : 'err');
    refresh();
  });
});

on('btnCleanup', function () {
  callJSX('smCleanupTempSequences').then(function (r) {
    log((r.ok ? '清理临时序列: ' : '清理失败: ') + describe(r), r.ok ? 'ok' : 'err');
  });
});

var markerFilePath = '';
on('btnPickMarkers', function () {
  pickFile('marker').then(function (p) {
    if (!p) return;
    markerFilePath = p;
    document.getElementById('markerFile').textContent = p;
    previewFileMarkers();          // 选完就渲染右栏，点「导入」之前先对照
  });
});

/* 自动在素材目录里找同名标记文件；找不到就明确报错 —— 手动按钮照常可用（保险绳） */
on('btnAutoMarkers', function () {
  findMarkerCandidates().then(function (res) {
    if (res.err) { log(res.err, 'err'); return; }
    if (!res.total) {
      log('素材目录里没有 ' + res.stem + '_markers_*.csv（' + res.dir + '），请用「选择文件…」', 'err');
      return;
    }
    markerFilePath = res.list[0].full;
    document.getElementById('markerFile').textContent = res.list[0].name;
    log('找到 ' + res.total + ' 个同名标记文件，取最新：' + res.list[0].name, 'ok');
    for (var i = 1; i < res.list.length && i < 5; i++) log('　其它候选：' + res.list[i].name);
    previewFileMarkers();
  });
});

/* 用 mpv 打开源监视器里的素材。
   CEP 的 process API，不需要 --enable-nodejs、也不改清单；播放器路径只问一次并记住。
   任何一步失败都打印手动路径 —— 不能变成一个按了没反应的死按钮。 */
function rawText(v) {
  try { return (typeof v === 'object' && v !== null) ? JSON.stringify(v) : String(v); }
  catch (e) { return String(v); }
}
/* 安装器（包根 安装.cmd）会把播放器路径写进扩展目录下的 player-path.txt。
   这里读它当默认值 —— 第一次使用就不用手动选播放器了。
   刻意**不写进 SET**：安装器换了路径能立刻生效，也不会留下过期值；读不到就返回 ''，手动选照旧。 */
function readInstalledPlayerPath() {
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.readFile !== 'function') return '';
    var m = String(window.location.href || '').match(/^file:\/\/\/(.*?)\/(?:client|host)\//i);
    if (!m) return '';
    var dir = decodeURIComponent(m[1]).replace(/\//g, '\\');
    var r = window.cep.fs.readFile(dir + '\\player-path.txt');
    if (!r || r.err !== 0 || r.data == null) return '';
    var s = String(r.data).replace(/^\uFEFF/, '').trim();
    return /\.exe$/i.test(s) ? s : '';   // 读到的形状不对就当没有，回退到手动选
  } catch (e) { return ''; }
}
function playerPathInUse() { return SET.mpvPath || readInstalledPlayerPath(); }

function launchPlayerAt(sec, exe) {
  if (!window.cep || !window.cep.process || typeof window.cep.process.createProcess !== 'function') {
    log('此 Pr 版本不支持直接启动外部程序。手动：右键素材 → 在资源管理器中显示 → 打开方式 → mpv', 'err');
    return;
  }
  /* 后两个参数是刻意加的：CEP 起子进程时子进程会继承面板的 stdio 句柄，
     若那些句柄是没人读的管道，mpv 写日志写满缓冲就会卡在主线程上 ——
     表现正是「窗口能最小化/最大化，但关不掉、内部也没反应」。
     所以让 mpv 别去碰继承来的 stdio：不读终端、不往 stderr 写日志。
     插件自己的 OSD 提示走另一条路，不受影响。 */
  /* --start 直接收【真实秒】：Pr 的 getPosition().seconds 与 mpv 的 time-pos 同一量纲，
     不需要任何换算（由参考视频实测确认，见 参考视频/README.md 第七节）。
     mpv 会落在「PTS ≥ 该秒的第一个帧」上，即最多晚一帧（23.976 下约 42 ms）。
     --pause=yes：跳过去之后**先停住**，按空格才放 —— 便于核对落点。
     实测（包内 mpv 0.41）：--pause=yes 与 --start 不冲突，位置精确且不漂移。 */
  var raw;
  try {
    raw = window.cep.process.createProcess(exe, '--no-terminal', '--msg-level=all=no',
                                           '--pause=yes', '--start=' + sec, STATE.clipPath);
  } catch (e) { log('启动播放器失败: ' + e.message, 'err'); return; }
  /* ⚠️ 必须检查 err —— r21 真机踩过：createProcess 返回 {"data":-1,"err":3}（其实没起来），
     旧代码不看 err 照样打「OK 已请求启动播放器」，害人以为已经启动了。 */
  if (raw && typeof raw === 'object' && raw.err === 0) {
    log('已启动播放器：' + exe + '　从 ' + sec + ' s 起播（暂停）　素材：' + STATE.clipPath, 'ok');
    return;
  }
  log('直接启动没成功（' + rawText(raw) + '）：' + exe, 'warn');
  log('改用系统 shell 再试一次…');
  var raw2;
  try {
    raw2 = window.cep.process.createProcess('cmd.exe', '/c', 'start', '', exe,
                                            '--no-terminal', '--msg-level=all=no',
                                            '--pause=yes', '--start=' + sec, STATE.clipPath);
  } catch (e2) { log('shell 方式异常: ' + e2.message, 'err'); return; }
  if (raw2 && typeof raw2 === 'object' && raw2.err === 0) {
    log('已通过系统 shell 启动播放器：' + exe, 'ok');
  } else {
    log('两种方式都没起来（' + rawText(raw2) + '）。手动：右键素材 → 在资源管理器中显示 → 打开方式 → mpv', 'err');
  }
}
/* player-path.txt 里的路径会过期（包被移动 / 改名 / 删掉）。启动前先验一次真实性：
   用 CEP 的 readdir（真机验证过的 API）看那个目录里到底有没有这个文件。
   验不了（API 缺失）就返回 true，交给 createProcess 自己报错。 */
function playerExeExists(p) {
  try {
    if (!p) return false;
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.readdir !== 'function') return true;
    var m = String(p).match(/^(.*)[\\\/]([^\\\/]+)$/);
    if (!m) return false;
    var r = window.cep.fs.readdir(m[1]);
    if (!r || r.err !== 0 || !r.data) return false;
    var want = m[2].toLowerCase();
    for (var i = 0; i < r.data.length; i++) {
      if (String(r.data[i]).replace(/^.*[\\\/]/, '').toLowerCase() === want) return true;
    }
    return false;
  } catch (e) { return true; }
}

on('btnOpenInPlayer', function () {
  if (!STATE.clipPath) { log('源监视器里没有素材', 'err'); return; }
  var exe = playerPathInUse();
  var fromInstaller = !!(exe && !SET.mpvPath);
  if (exe && !playerExeExists(exe)) {
    /* r22 真机就是这样：player-path.txt 里还指着**改名前的旧包**（…-1.0.1-alpha），
       于是 createProcess 返回 err=3、什么也没起来。先验一次，直接给人话提示。 */
    log('记录里的播放器路径已失效（文件不在）：' + exe, 'err');
    log(fromInstaller
        ? '多半是包被移动 / 改名 / 删掉了 —— 重跑一次包根的 安装.cmd 就能修正，或下面手动选一次。'
        : '这个路径是你手动选过的、已失效 —— 重新选一次。', 'warn');
    exe = '';
    SET.mpvPath = '';          // 清掉过期值，免得每次都撞一遍
    saveSettings();
  }
  if (exe && fromInstaller) log('播放器路径来自安装信息（player-path.txt）：' + exe);
  if (!exe) {
    var hit = cepOpenDialog('选择 mpv.exe（本包 mpv-player 文件夹里）', ['exe']);
    if (hit === null) { log('此 Pr 版本不支持 CEP 对话框，无法选择播放器。手动：右键素材 → 在资源管理器中显示 → 打开方式 → mpv', 'err'); return; }
    if (!hit) { log('未选择播放器（手动：右键素材 → 打开方式 → mpv）'); return; }
    SET.mpvPath = hit;
    saveSettings();
    log('已记住播放器路径：' + hit);
    exe = hit;
  }
  // 锚点 = 源监视器当前播放头。读不到就退回从 0 起播（不阻断，照旧能看片）
  callJSX('smGetPlayerPosition').then(function (r) {
    var sec = 0;
    if (r.ok && !isNaN(parseFloat(r.fields[0]))) {
      sec = parseFloat(r.fields[0]);
      log('播放头：' + r.fields[1] + '（' + sec.toFixed(3) + ' s 真实秒）→ 交给播放器');
    } else {
      log('读不到播放头位置（' + describe(r) + '），播放器从 0 起播', 'err');
    }
    launchPlayerAt(sec, exe);
  });
});

on('btnImport', function () {
  if (!markerFilePath) { log('请先选择标记文件', 'err'); return; }
  readTextFile(markerFilePath).then(function (text) {
    if (text == null) { log('读取文件失败', 'err'); return; }
    var markers = parseMarkerFile(text, STATE.fps);
    if (!markers.length) { log('未解析出任何标记（检查时间列/格式）', 'err'); return; }
    var payload = buildImportPayload(markers);
    var clear = document.getElementById('clearFirst').checked ? 1 : 0;
    callJSX('smImportMarkers', payload, clear).then(function (r) {
      log('导入 ' + markers.length + ' 条 → ' + describe(r), r.ok ? 'ok' : 'err');
      refresh();
      loadMarkers();   // 导入后立刻回读，确认标记真的落到项目项上
    });
  });
});

/* ------------------------------ 启动 ------------------------------ */

applySettings();
loadSharedColors();
log('颜色表来源：' + COLOR_TABLE_STATE);
log('Source Marker 1.2.0-alpha r8 已加载。');
refresh().then(loadMarkers).then(function () {
  restartAuto();
});
