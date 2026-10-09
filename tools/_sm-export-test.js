/* _sm-export-test.js —— Pr 导出编码器的离线校验
 * 放在工作区 tools/ 下（**不进交付包**，避免多出第 17 个差异文件）。
 *
 * 校验方式有一处特别值得说：契约文档《标记文件格式-v1.md》§1.4 与 §2 自带样例，
 * 那就是**冻结契约自己的金标准**。如果我的编码器能把那两段样例一字不差地复现出来，
 * 就说明它不仅"自洽"，而且真的符合契约。
 *
 * 另外把 mpv 侧（source-markers.lua）的算法忠实移植一份，和面板实现逐字节对拍 ——
 * 两侧算法若有任何一处抄错，这里就会炸。
 */
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const ROOT = path.join(__dirname, '..');   // 本文件在 tools/ 下；工作区根是上一级
const MAIN = path.join(ROOT, 'source-marker-united-1.2.0-alpha-r4', 'pr-extension', '完整版', 'extension', 'client', 'main.js');
const src = fs.readFileSync(MAIN, 'utf8');

let pass = 0, fail = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass++; }
  else { fail++; fails.push(name + (extra ? '  → ' + extra : '')); }
}
function eq(name, got, want) {
  ok(name, got === want, '\n      got  = ' + JSON.stringify(got) + '\n      want = ' + JSON.stringify(want));
}

/* ---------- 1. 抽出「导出编码器」段与「面板解析」段 ---------- */
const A = src.indexOf('/* ============================== 导出编码器');
const B = src.indexOf('/* ============================ 导出编码器结束');
if (A < 0 || B < 0) { console.log('FAIL 找不到编码器段'); process.exit(1); }
const encSrc = src.slice(A, B);

// 解析段：与 tools/pr-parser.js 同样切在两条锚点注释之间
const lines = src.split('\n');
const i1 = lines.findIndex(l => l.indexOf('时间解析') >= 0);
const i2 = lines.findIndex(l => l.indexOf('状态刷新') >= 0);
if (i1 < 0 || i2 < 0 || i2 <= i1) { console.log('FAIL 找不到锚点'); process.exit(1); }
const segSrc = lines.slice(i1, i2).join('\n');

const ctx = { console: console };
vm.createContext(ctx);
vm.runInContext(encSrc, ctx, { filename: 'encoder.js' });
vm.runInContext(segSrc, ctx, { filename: 'parser.js' });

const { buildMarkerCsv, buildMarkerJson, msField, tcField, csvField, normColor,
        safeFileName, sortedMarkers } = ctx;
const { parseMarkerFile } = ctx;

ok('编码器段可独立求值（纯函数，无 DOM 依赖）', typeof buildMarkerCsv === 'function');
ok('解析段可独立求值（锚点切法可用）', typeof parseMarkerFile === 'function');

/* ---------- 2. mpv 侧算法的忠实移植（对拍基准） ---------- */
const p2 = n => { n = Math.floor(n); return n < 10 ? '0' + n : String(n); };
const p3 = n => { n = Math.floor(n); return n < 10 ? '00' + n : (n < 100 ? '0' + n : String(n)); };

function lua_to_hms_ms(sec) {                       // source-markers.lua:219
  sec = Math.max(0, Number(sec) || 0);
  const total = Math.floor(sec * 1000 + 0.5);
  const ms = total % 1000, s = Math.floor(total / 1000);
  return p2(Math.floor(s / 3600)) + ':' + p2(Math.floor((s % 3600) / 60)) + ':' + p2(s % 60) + '.' + p3(ms);
}
function lua_to_timecode(sec, f) {                  // source-markers.lua:199
  if (sec < 0) sec = 0;
  let maxff = Math.ceil(f - 1e-9); if (maxff < 1) maxff = 1;
  let whole = Math.floor(sec);
  let ff = Math.floor((sec - whole) * f + 0.5);
  if (ff >= maxff) { ff = 0; whole += 1; }
  if (ff < 0) ff = 0;
  return p2(Math.floor(whole / 3600)) + ':' + p2(Math.floor((whole % 3600) / 60)) + ':' + p2(whole % 60) + ':' + p2(ff);
}
const lua_csv_field = s => { s = String(s == null ? '' : s); return /["\r\n,]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
function lua_norm_color(v) {                        // source-markers.lua:504
  if (v == null || String(v).trim() === '') return 0;
  const n = Number(v);
  if (!isFinite(n)) return 0;
  const f = Math.floor(n);
  return (f >= 0 && f <= 7) ? f : 0;
}
function lua_build_csv(markers) {                   // source-markers.lua:1139
  const out = ['time,name,comment,color'];
  for (const m of markers) {
    out.push([lua_to_hms_ms(m.sec), '', lua_csv_field(m.desc), String(lua_norm_color(m.color))].join(','));
  }
  return out.join('\r\n') + '\r\n';
}

/* ---------- 3. 金标准：契约文档自带的样例 ---------- */
const DOC_CSV =
  'time,name,comment,color\r\n' +
  '00:00:01.240,,"他说""过曝"",第2条",2\r\n' +
  '00:00:03.520,,曝光过了，需要重新调色,1\r\n' +
  '00:00:05.120,,背景音有杂音,4\r\n' +
  '00:00:07.040,,需要补一帧,6\r\n';
const DOC_MARKERS = [
  { sec: 1.240, desc: '他说"过曝",第2条', color: 2 },
  { sec: 3.520, desc: '曝光过了，需要重新调色', color: 1 },
  { sec: 5.120, desc: '背景音有杂音', color: 4 },
  { sec: 7.040, desc: '需要补一帧', color: 6 }
];
eq('金标准：复现契约 §1.4 的 CSV 样例（逐字节）', buildMarkerCsv(DOC_MARKERS), DOC_CSV);
eq('金标准：mpv 移植版也复现同一段（说明移植没错）', lua_build_csv(DOC_MARKERS), DOC_CSV);

// 契约 §2 的 JSON 样例给出两个 tc 金值：1.240s@25fps = 00:00:01:06，3.520s@25fps = 00:00:03:13
eq('金标准：tc 1.240s@25fps', tcField(1.240, 25), '00:00:01:06');
eq('金标准：tc 3.520s@25fps', tcField(3.520, 25), '00:00:03:13');
eq('金标准：ms 1.240s', msField(1.240), '00:00:01.240');

/* ---------- 4. 与 mpv 移植版对拍（含边界） ---------- */
const cases = [];
for (const fps of [25, 24, 30, 23.976, 29.97, 59.94]) {
  for (const t of [0, 0.001, 0.04, 1.24, 3.51999, 3.999, 4.0, 59.999, 300, 600, 3599.999, 3600, 36000.5]) {
    cases.push([t, fps]);
  }
}
let tcDiff = 0, msDiff = 0;
for (const [t, fps] of cases) {
  if (tcField(t, fps) !== lua_to_timecode(t, fps)) tcDiff++;
  if (msField(t) !== lua_to_hms_ms(t)) msDiff++;
}
eq('对拍：tcField 与 Lua to_timecode 全部一致（' + cases.length + ' 组）', tcDiff, 0);
eq('对拍：msField 与 Lua to_hms_ms 全部一致（' + cases.length + ' 组）', msDiff, 0);

// 契约 §3 的硬约束：FF 必须 < ⌈fps⌉（进位必须发生）
let badFf = 0;
for (const [t, fps] of cases) {
  const ff = Number(tcField(t, fps).split(':')[3]);
  if (ff >= Math.ceil(fps - 1e-9)) badFf++;
}
eq('契约 §3：所有 tc 的 FF 都 < ⌈fps⌉（进位正确）', badFf, 0);
eq('边界：25fps 的 3.999s 必须进位成 00:00:04:00', tcField(3.999, 25), '00:00:04:00');
eq('边界：29.97fps 的 600s 用毫秒不漂移', msField(600), '00:10:00.000');
eq('边界：负数按 0 处理（契约 §3 禁止负数产出）', msField(-5), '00:00:00.000');
eq('边界：负数时间码按 0', tcField(-5, 25), '00:00:00:00');
eq('边界：超过 1 小时', msField(3661.5), '01:01:01.500');

/* ---------- 5. 转义 / 颜色 / 排序 ---------- */
eq('转义：含引号', csvField('a"b'), '"a""b"');
eq('转义：含逗号', csvField('a,b'), '"a,b"');
eq('转义：含换行', csvField('a\nb'), '"a\nb"');
eq('转义：普通文本不加引号', csvField('普通'), '普通');
eq('转义：空字段保持空', csvField(''), '');
eq('颜色：越界 9 → 0', normColor(9), 0);
eq('颜色：-1（引擎读不到） → 0', normColor(-1), 0);
eq('颜色：非数字 → 0', normColor('abc'), 0);
eq('颜色：2.9 向下取整 → 2', normColor(2.9), 2);
eq('颜色：null → 0', normColor(null), 0);

const unsorted = [{ sec: 5, desc: 'c', color: 0 }, { sec: 1, desc: 'a', color: 0 }, { sec: 3, desc: 'b', color: 0 }];
const sortedCsv = buildMarkerCsv(unsorted);
ok('排序：输入乱序也要按 time 升序输出（契约 §1.3）',
   sortedCsv.indexOf('00:00:01.000') < sortedCsv.indexOf('00:00:03.000') &&
   sortedCsv.indexOf('00:00:03.000') < sortedCsv.indexOf('00:00:05.000'));

const multi = buildMarkerCsv([{ sec: 1, desc: '第一行\n第二行', color: 3 }]);
ok('换行：注释里的换行必须**原样保留**在文件层（契约 §6.5「文件层不丢字符」）',
   multi.indexOf('"第一行\n第二行"') > 0);
// 注意：不能笼统地断言"没有裸 LF" —— 引号内的换行本来就必须保留。
// 正确的断言是：**引号之外**的行尾只能是 CRLF。
const multiUnquoted = multi.replace(/"(?:[^"]|"")*"/g, '""');
ok('换行：引号外的行尾必须是 CRLF（引号内的换行不算违规）',
   !/[^\r]\n/.test(multiUnquoted) && multi.indexOf('\r\n') > 0);

/* ---------- 6. JSON ---------- */
const doc = JSON.parse(buildMarkerJson(DOC_MARKERS, 25, 'D:\\rushes\\A001.mp4'));
eq('JSON：format', doc.format, 'source-markers');
eq('JSON：version', doc.version, 1);
eq('JSON：顶层键序与 mpv 侧 export_doc 一致',
   JSON.stringify(Object.keys(doc)), JSON.stringify(['format', 'version', 'created', 'source', 'markers']));
eq('JSON：marker 键序', JSON.stringify(Object.keys(doc.markers[0])),
   JSON.stringify(['time', 'tc', 'name', 'comment', 'color']));
eq('JSON：time 是数字且 3 位小数', doc.markers[0].time, 1.24);
eq('JSON：name 恒为空（§2）', doc.markers[0].name, '');
eq('JSON：tc 金值', doc.markers[0].tc, '00:00:01:06');
eq('JSON：color 保留', doc.markers[0].color, 2);
eq('JSON：source.timeFormat', doc.source.timeFormat, 'ms');
eq('JSON：source.fps', doc.source.fps, 25);
ok('JSON：created 是 UTC 带 Z 且秒精度（对齐 Lua os.date!）',
   /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(doc.created), doc.created);
ok('JSON：不含 BOM（契约 §2）', buildMarkerJson([], 25, '').charCodeAt(0) !== 0xFEFF);

/* ---------- 7. 往返：自己产的 CSV 必须能被面板自己的解析器读回 ---------- */
const roundTrip = parseMarkerFile(DOC_CSV, 25);
eq('往返：解析回读条数', roundTrip.length, 4);
eq('往返：第 1 条时间', roundTrip[0].sec, 1.24);
eq('往返：第 1 条注释（含引号与逗号）', roundTrip[0].desc, '他说"过曝",第2条');
eq('往返：第 1 条颜色', String(roundTrip[0].color), '2');
eq('往返：第 4 条时间', roundTrip[3].sec, 7.04);
const reExport = buildMarkerCsv(roundTrip.map(m => ({ sec: m.sec, desc: m.desc, color: m.color })));
eq('往返：导出→解析→再导出 逐字节一致（契约 §6.1 幂等）', reExport, DOC_CSV);

/* ---------- 8. 文件名 ---------- */
eq('文件名：非法字符替换', safeFileName('a/b:c*d?e"f<g>h|i'), 'a_b_c_d_e_f_g_h_i');
eq('文件名：结尾点去掉', safeFileName('name...'), 'name');
eq('文件名：保留名加下划线', safeFileName('CON'), 'CON_');
eq('文件名：空 → stream', safeFileName(''), 'stream');
eq('文件名：限长 120', safeFileName('x'.repeat(200)).length, 120);

/* ---------- 9. 契约 §6.4：空列表不产出文件（由 exportMarkers 把关，这里验编码器本身仍安全） ---------- */
eq('空列表：CSV 只有表头 + CRLF', buildMarkerCsv([]), 'time,name,comment,color\r\n');

/* ---------- 10. 回归：真机 bug「导出丢 Comment」 ----------
   症状：导出的 CSV 里 time 与 color 都在，comment 却是空的。
   根因：引擎的 smImportMarkers 把文件的 comment 列写进 Pr 的 **name 属性**（同时 comments 置空），
        而 r9 的导出只读了 comments → 恒空。
   这里把面板的 toExportRow() 也抽出来，把「正文优先取 name」这个约定钉死在测试里。 */
const iTo = src.indexOf('function markerBody');
if (iTo < 0) { console.log('FAIL 找不到 markerBody'); process.exit(1); }
const iToEnd = src.indexOf('\n}', src.indexOf('function toExportRow'));
vm.runInContext(src.slice(iTo, iToEnd + 2), ctx, { filename: 'markerBody+toExportRow.js' });
const { toExportRow, markerBody } = ctx;
ok('抽出了 markerBody + toExportRow', typeof toExportRow === 'function' && typeof markerBody === 'function');

// 引擎真实回传的形状：正文在 name，comments 为空
const engRows = [
  { sec: 1.24, name: '过曝了', desc: '', color: 2 },
  { sec: 3.52, name: '', desc: '来自注释属性', color: 1 },
  { sec: 5.0, name: '两边都有', desc: 'name 优先', color: 3 }
];
eq('回归 bug#1：正文在 name 属性时也能导出（r9 就是在这里丢的）', toExportRow(engRows[0]).desc, '过曝了');
eq('回归 bug#1：只有 comments 时也能导出（向后兼容）', toExportRow(engRows[1]).desc, '来自注释属性');
eq('回归 bug#1：两者都有时 name 优先', toExportRow(engRows[2]).desc, '两边都有');
eq('回归 bug#1：正文必须完整出现在导出的 CSV 里',
   buildMarkerCsv(engRows.map(toExportRow)),
   'time,name,comment,color\r\n' +
   '00:00:01.240,,过曝了,2\r\n' +
   '00:00:03.520,,来自注释属性,1\r\n' +
   '00:00:05.000,,两边都有,3\r\n');
// 反向确认：如果谁又改回只读 desc，这条会立刻炸
eq('回归 bug#1：只读 desc 的老写法会丢正文（证明本测试确实能抓到）',
   buildMarkerCsv(engRows.map(m => ({ sec: m.sec, desc: m.desc, color: m.color }))).indexOf('过曝了'), -1);

/* ---------- 11. 回归：「改正文 / 删标记」的定位逻辑（引擎的 _markerAt）----------
   这是"绝不盲操作"的核心：下标对不上就按时间找最近的，离所有标记都太远就拒绝。
   注意它是**只读**的 —— 定位过程本身绝不能动任何标记。 */
const engPath = path.join(ROOT, 'source-marker-united-1.2.0-alpha-r4', 'pr-extension', '完整版', 'extension', 'host', 'hostscript.jsx');
const eng = fs.readFileSync(engPath, 'utf8');
function fnSrc(name) {
  const i = eng.indexOf('function ' + name);
  if (i < 0) throw new Error('找不到 ' + name);
  const j = eng.indexOf('\n}', i);
  return eng.slice(i, j + 2);
}
const ctx2 = { console: console };
vm.createContext(ctx2);
vm.runInContext(fnSrc('_num') + '\n' + fnSrc('_markerAt'), ctx2, { filename: 'markerAt.js' });
const { _markerAt } = ctx2;
ok('抽出了引擎的 _num + _markerAt', typeof _markerAt === 'function');

function fakeItem(times) {
  const col = times.map(t => ({ start: { seconds: t } }));
  col.numMarkers = times.length;
  col.deleteMarker = function (m) {
    const k = col.indexOf(m);
    if (k >= 0) { col.splice(k, 1); col.numMarkers = col.length; }
  };
  return { getMarkers: function () { return col; } };
}
const itm = fakeItem([1.0, 5.0, 9.0]);
eq('_markerAt：下标与时间都对 → 命中同一条', _markerAt(itm, 1, 5.0).idx, 1);
eq('_markerAt：下标指错了但时间在 → 按时间找最近', _markerAt(itm, 0, 9.0).idx, 2);
eq('_markerAt：下标越界但时间在 → 仍能找到', _markerAt(itm, 99, 1.0).idx, 0);
eq('_markerAt：时间在容差内（≈2 帧）→ 视为同一条', _markerAt(itm, 1, 5.05).idx, 1);
eq('_markerAt：离所有标记都超过 2 秒 → 拒绝（返回 null）', _markerAt(itm, 0, 20.0), null);
eq('_markerAt：空标记集合 → 拒绝', _markerAt(fakeItem([]), 0, 1.0), null);

let deletedByLookup = 0;
const itm2 = fakeItem([1, 5, 9]);
itm2.getMarkers().deleteMarker = function () { deletedByLookup++; };
_markerAt(itm2, 1, 5.0);
eq('_markerAt 是只读的：定位过程绝不删任何标记', deletedByLookup, 0);

/* ---------- 12. 回归：原生输入框的文本消毒（smPromptText）----------
   面板↔宿主用 US(0x1f)/GS(0x1d)/RS(0x1e) 当分隔符，用户输入的正文里若带这些字符
   会把回传协议撑破（多出一段被当成字段）。引擎必须把它们和换行一起折叠成空格。 */
const ctx3 = { console: console };
vm.createContext(ctx3);
vm.runInContext(
  'var LAST=null;' +
  'function _ok(v){LAST=v;return {ok:true,fields:[v]};}' +
  'function _err(m){LAST=m;return {ok:false,fields:[m]};}\n' + fnSrc('smPromptText'), ctx3);
const sp = ctx3.smPromptText;
ok('抽出了引擎的 smPromptText', typeof sp === 'function');

ctx3.prompt = function () { return '正常中文 与 ascii'; };
sp('t', '');
eq('smPromptText：正常文本原样返回', ctx3.LAST, '正常中文 与 ascii');

ctx3.prompt = function () { return 'a\x1fb\x1dc\x1ed\ne\rf'; };
sp('t', '');
eq('smPromptText：分隔符与换行一律折叠成空格（否则回传协议会被撑破）', ctx3.LAST, 'a b c d e f');

ctx3.prompt = function () { return null; };
eq('smPromptText：用户取消 → 报 cancelled', sp('t', '').fields[0], 'cancelled');

// 真机踩过的坑：prompt() 取消时返回的 null 会变成字符串 "null"，把正文写成字面量 null
ctx3.prompt = function () { return 'null'; };
eq('回归：prompt 取消返回字符串 "null" 也当取消（否则正文会被写成 null）',
   sp('t', '').fields[0], 'cancelled');
ctx3.prompt = function () { return 'undefined'; };
eq('回归：字符串 "undefined" 同样当取消', sp('t', '').fields[0], 'cancelled');
ctx3.prompt = function () { return ''; };
eq('smPromptText：清空正文是合法输入（返回空串，不是取消）', sp('t', '').fields[0], '');

delete ctx3.prompt;
ok('smPromptText：此版本没有原生 prompt → 明确报不可用（面板据此退回编辑条）',
   sp('t', '').fields[0].indexOf('没有') >= 0);

/* ---------- 契约守卫：两侧解析器的中文表头别名表必须完整 ----------
 * 回归来源：统一用词时做过一次整批替换（「描述」→「正文」），
 * 误伤了 Lua 里契约规定的别名表 —— 用「描述」作表头的 CSV 会读不出来，
 * 而当时 74 项全绿也没拦住它（因为本文件从不读 Lua 源文件，只手工移植算法）。
 * 这里直接读三个源文件的别名正则来兜。 */
const PKG = path.resolve(path.dirname(MAIN), '..', '..', '..', '..');
const ALIAS_WORDS = ['内容', '备注', '描述', '说明'];   // 契约《标记文件格式-v1.md》规定的中文表头
const luaDoc = fs.readFileSync(path.join(PKG, 'mpv-player', 'portable_config', 'scripts', 'source-markers.lua'), 'utf8');
const luaAlias = (luaDoc.match(/KEY_DESC = '\^\(([^)]+)\)/) || [])[1] || '';
ok('契约别名：能解析到 Lua 侧 KEY_DESC', luaAlias.length > 0, luaAlias);
ALIAS_WORDS.forEach(w => ok('契约别名：Lua 侧必须接受表头「' + w + '」', luaAlias.indexOf(w) >= 0, luaAlias));
ok('契约别名：Lua 侧额外接受「正文」', luaAlias.indexOf('正文') >= 0, luaAlias);
['新手版', '完整版'].forEach(v => {
  const t = fs.readFileSync(path.join(PKG, 'pr-extension', v, 'extension', 'client', 'main.js'), 'utf8');
  const a = (t.match(/KEY_DESC = \/\^\(([^)]+)\)/) || [])[1] || '';
  ok('契约别名：能解析到' + v + '侧 KEY_DESC', a.length > 0, a);
  ALIAS_WORDS.forEach(w => ok('契约别名：' + v + '侧必须接受表头「' + w + '」', a.indexOf(w) >= 0, a));
});

/* ---------- 汇总 ---------- */
console.log('通过 ' + pass + ' 项，失败 ' + fail + ' 项');
if (fail) { console.log('\n失败明细:'); fails.forEach(f => console.log('  ✗ ' + f)); process.exit(1); }
console.log('OK 全部通过');
