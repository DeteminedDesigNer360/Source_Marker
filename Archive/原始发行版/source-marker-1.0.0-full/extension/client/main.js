/* Source Marker — CEP 面板逻辑 */

var cs = new CSInterface();
var US = String.fromCharCode(31);
var STATE = { fps: 25, inSec: 0, outSec: 0, clipName: '', markers: [] };

/* ------------------------------ 基础桥接 ------------------------------ */

function log(msg, cls) {
  var el = document.getElementById('log');
  var line = document.createElement('div');
  if (cls) line.className = cls;
  line.textContent = msg;
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
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
function cepOpenDialog(title, fileTypes) {
  try {
    if (!window.cep || !window.cep.fs || typeof window.cep.fs.showOpenDialog !== 'function') return null;
    var r = window.cep.fs.showOpenDialog(false, false, title, '', fileTypes);
    if (!r || typeof r.err === 'undefined') return null;
    if (r.err !== 0) return null;                       // 出错 → 交回 ExtendScript
    return (r.data && r.data.length) ? r.data[0] : '';  // 选中 / 用户取消
  } catch (e) { return null; }
}

function pickFile(kind) {
  var title = (kind === 'preset') ? '选择 AME 预设 (.epr)' : '选择标记文件';
  var types = (kind === 'preset') ? ['epr'] : ['csv', 'tsv', 'txt', 'json', 'srt'];
  var hit = cepOpenDialog(title, types);
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
  var def = { presetPath: '', outDir: '', outName: '{clip}_in{in}', strategy: 'sequence', runBatch: true };
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
    window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(SET));
  } catch (e) { log('设置保存失败: ' + e.message, 'err'); }
}
function applySettings() {
  document.getElementById('presetPath').value = SET.presetPath;
  document.getElementById('outDir').value = SET.outDir;
  document.getElementById('outName').value = SET.outName;
  document.getElementById('strategy').value = SET.strategy;
  document.getElementById('runBatch').checked = SET.runBatch !== false;
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
var KEY_DESC = /^(comment|comments|desc|description|content|text|note|notes|内容|备注|描述|说明)$/i;
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

function refresh() {
  return callJSX('smGetState').then(function (res) {
    if (!res.ok) {
      document.getElementById('clipName').textContent = '（源监视器为空）';
      document.getElementById('clipPath').textContent = '';
      document.getElementById('tcLine').textContent = 'in — / out —';
      STATE.markers = [];
      return;
    }
    var f = res.fields;
    STATE.fps = parseFloat(f[6]) || 25;
    STATE.inSec = parseFloat(f[2]);
    STATE.outSec = parseFloat(f[3]);
    STATE.clipName = f[0];
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

on('btnApply', function () {
  var i = parseTimeToSeconds(document.getElementById('InTc').value, STATE.fps);
  var o = parseTimeToSeconds(document.getElementById('OutTc').value, STATE.fps);
  if (isNaN(i) || isNaN(o)) { log('入/出点时间格式无法解析', 'err'); return; }
  callJSX('smSetInOut', i, o).then(function (r) {
    log((r.ok ? '入出点已设置: ' : '失败: ') + describe(r), r.ok ? 'ok' : 'err');
    refresh();
  });
});

function nudge(which, sign) {
  var n = Number(document.getElementById('nudge').value) || 1;
  callJSX('smNudge', which, sign * n).then(function (r) {
    if (!r.ok) log('微调失败: ' + describe(r), 'err');
    refresh();
  });
}
on('inMinus', function () { nudge('in', -1); });
on('inPlus', function () { nudge('in', 1); });
on('outMinus', function () { nudge('out', -1); });
on('outPlus', function () { nudge('out', 1); });

on('btnPull', function () {
  callJSX('smPullInOutFromSequence').then(function (r) {
    log((r.ok ? '已从序列拉取入出点' : '失败: ' + describe(r)), r.ok ? 'ok' : 'err');
    refresh();
  });
});
on('btnPush', function () {
  callJSX('smPushInOutToSequence').then(function (r) {
    log((r.ok ? '已推送到序列入出点' : '失败: ' + describe(r)), r.ok ? 'ok' : 'err');
  });
});
on('btnClear', function () {
  callJSX('smClearInOut').then(function (r) {
    log((r.ok ? '入出点已清除' : '失败: ' + describe(r)), r.ok ? 'ok' : 'err');
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

function loadMarkers() {
  return callJSX('smListMarkers').then(function (r) {
    MARKERS = [];
    if (r.ok && r.fields[1]) {
      r.fields[1].split(GS).forEach(function (rec) {
        if (!rec) return;
        var f = rec.split(RS);
        var sec = parseFloat(f[0]);
        if (!isNaN(sec)) MARKERS.push({ sec: sec, name: f[1] || '', desc: f[2] || '' });
      });
    }
    renderMarkers();
    return MARKERS.length;
  });
}

function renderMarkers() {
  var box = document.getElementById('markerList');
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
    row.textContent = secondsToTimecode(m.sec, STATE.fps) + '  ' + (m.name || '') +
                      (m.desc ? '  — ' + m.desc : '');
    row.title = '点击：把源监视器播放头跳到该标记';
    row.addEventListener('click', function () { seekTo(m.sec); });
    box.appendChild(row);
  });
}

function seekTo(sec) {
  callJSX('smSeekSeconds', sec).then(function (r) {
    log(r.ok ? '已跳到 ' + secondsToTimecode(sec, STATE.fps) + '  ' + describe(r)
             : '跳转失败: ' + describe(r), r.ok ? 'ok' : 'err');
  });
}

on('btnListMarkers', function () {
  loadMarkers().then(function (n) { log('标记列表已刷新：' + n + ' 条'); });
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
log('Source Marker 已加载。');
refresh().then(loadMarkers);
