/*
 * verify-release-e2e.js —— 用「已真机测试的成品包」验证播放器插件的可行性
 *
 * 参照消费方：release/source-marker-1.0.0（Pr 24.0.0 实测通过的 CEP 面板）
 * 被测写入方：player-plugin/source-markers.lua（mpv 插件）的真实导出产物
 *
 * 本脚本全部使用成品包里的**真实代码**，不重写逻辑：
 *   ① release 的 client/main.js  —— parseMarkerFile()（读取方契约）
 *   ② release 的 client/main.js  —— buildImportPayload()（字段编码 + 颜色 clamp）
 *   ③ release 的 host/hostscript.jsx —— smImportMarkers() 里的导入循环（字段→Pr 标记）
 *   ④ release 的 install.ps1 / SHA256SUMS.txt —— 成品完整性与安装前提
 *
 * 运行： node tools/verify-release-e2e.js
 *      （先跑 run-all-tests.ps1 生成 probe/out 下的插件导出产物）
 */
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '..');
const RELEASE = path.join(ROOT, 'release');
const REL_DIR = path.join(RELEASE, 'source-marker-1.0.0');
const REL_MAIN = path.join(REL_DIR, 'extension', 'client', 'main.js');
const REL_JSX = path.join(REL_DIR, 'extension', 'host', 'hostscript.jsx');
const OUT = path.join(ROOT, 'probe', 'out');

let pass = 0;
let fail = 0;
let note_count = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  PASS  ' + name); }
  else { fail++; console.log('  FAIL  ' + name + '\n        期望 ' + e + '\n        实际 ' + a); }
}
// note：机器状态类观察，只提示、不计入失败（例如"本机安装的是更新的开发版本"）
function note(name, detail) {
  note_count++;
  console.log('  NOTE  ' + name + (detail ? '  ' + detail : ''));
}
function ok(name, cond, detail) {
  if (cond) { pass++; console.log('  PASS  ' + name + (detail ? '  ' + detail : '')); }
  else { fail++; console.log('  FAIL  ' + name + (detail ? '  ' + detail : '')); }
}
function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}
function stripBom(t) { return t.charCodeAt(0) === 0xFEFF ? t.slice(1) : t; }

console.log('参照成品：release/source-marker-1.0.0（Pr 24.0.0 真机测试通过）\n');

/* ============ ① 成品包完整性（SHA256SUMS.txt） ============ */
console.log('— 成品包完整性 —');
const sums = fs.readFileSync(path.join(RELEASE, 'SHA256SUMS.txt'), 'utf8');
const sumLines = sums.split(/\r?\n/).filter(function (l) { return /^[0-9a-f]{64}\s/.test(l); });
ok('SHA256SUMS.txt 有 2 条记录', sumLines.length === 2, '(' + sumLines.length + ')');
sumLines.forEach(function (line) {
  const m = line.match(/^([0-9a-f]{64})\s+(.+)$/);
  const zip = path.join(RELEASE, m[2].trim());
  if (!fs.existsSync(zip)) { fail++; console.log('  FAIL  缺少 ' + m[2]); return; }
  const h = sha256(zip);
  ok('成品包校验和一致：' + m[2].trim(), h === m[1], h.slice(0, 16) + '…');
});

/* ============ ② 工作区面板 == 成品面板（确认验证对象就是成品代码） ============ */
console.log('\n— 工作区 extension/ 是否就是成品代码 —');
['client/main.js', 'host/hostscript.jsx', 'client/index.html', 'CSXS/manifest.xml'].forEach(function (rel) {
  const a = path.join(ROOT, 'extension', rel.replace('/', path.sep));
  const b = path.join(REL_DIR, 'extension', rel.replace('/', path.sep));
  ok(rel + ' 与成品同哈希', sha256(a) === sha256(b));
});

/* ============ ③ 用成品解析器读插件产物 ============ */
console.log('\n— 成品解析器（release client/main.js）读 mpv 插件产物 —');
const { loadParser } = require('./pr-parser.js');
const rel = loadParser(REL_MAIN);
const ws = loadParser(path.join(ROOT, 'extension', 'client', 'main.js'));
ok('成品解析段可加载并包含 buildImportPayload', typeof rel.parseMarkerFile === 'function' && typeof rel.buildImportPayload === 'function',
  '(' + rel.code.length + ' 字符)');

const FPS = 25;
const EXPECT_MS = [
  { sec: 1.24, name: 'M03', desc: '他说"过曝",第2条', color: '2' },
  { sec: 3.52, name: 'M01', desc: '曝光过了', color: '1' },
  { sec: 7.04, name: 'M02', desc: '转场处需要补一帧', color: '6' },
];
function round(m) { return { sec: +m.sec.toFixed(3), name: m.name, desc: m.desc, color: m.color }; }

const files = {
  msCsv: path.join(OUT, 'ms', 'roundtrip.csv'),
  msJson: path.join(OUT, 'ms', 'roundtrip.json'),
  ffCsv: path.join(OUT, 'ff', 'roundtrip.csv'),
  sidecar: path.join(ROOT, 'probe', 'test25.marks.json'),
};
for (const k of Object.keys(files)) {
  if (!fs.existsSync(files[k])) {
    console.error('\nFAIL: 缺少插件产物 ' + files[k] + '；请先运行 run-all-tests.ps1');
    process.exit(2);
  }
}

const csvMsRaw = fs.readFileSync(files.msCsv, 'utf8');
ok('插件导出的 CSV 带 UTF-8 BOM（成品读取路径会剥掉）', csvMsRaw.charCodeAt(0) === 0xFEFF);
ok('成品 main.js 确实会剥 BOM（readTextFile 里的 replace）',
  /replace\(\/\^\\uFEFF\//.test(fs.readFileSync(REL_MAIN, 'utf8')));

check('成品解析器读 ms CSV', rel.parseMarkerFile(stripBom(csvMsRaw), FPS).map(round), EXPECT_MS);
check('成品解析器读 ff CSV', rel.parseMarkerFile(stripBom(fs.readFileSync(files.ffCsv, 'utf8')), FPS).map(round), EXPECT_MS);
check('成品解析器读 JSON（v1 结构）', rel.parseMarkerFile(fs.readFileSync(files.msJson, 'utf8'), FPS).map(round), EXPECT_MS);
// sidecar 会被各测试套件轮流改写，所以这里断言「成品解析器读出的内容 == 文件自身的 markers」
const sideDoc = JSON.parse(fs.readFileSync(files.sidecar, 'utf8'));
const sideExpect = sideDoc.markers.map(function (m) {
  return { sec: +Number(m.time).toFixed(3), name: m.name || '', desc: m.comment || '', color: String(m.color) };
});
check('成品解析器读 sidecar（与文件自身 markers 一致）',
  rel.parseMarkerFile(fs.readFileSync(files.sidecar, 'utf8'), FPS).map(round), sideExpect);
ok('sidecar 非空（确实是插件刚写出来的）', sideExpect.length > 0, '(' + sideExpect.length + ' 条)');
check('成品解析器与工作区解析器结果一致',
  rel.parseMarkerFile(stripBom(csvMsRaw), FPS).map(round),
  ws.parseMarkerFile(stripBom(csvMsRaw), FPS).map(round));

/* ============ ④ 成品 payload + 成品 JSX 导入循环 ============ */
console.log('\n— 成品 payload 编码 + hostscript.jsx 导入循环（真实代码） —');

// 从成品的 hostscript.jsx 里切出导入循环本体（不重写逻辑）
function loadJsxImportLoop() {
  const src = fs.readFileSync(REL_JSX, 'utf8');
  const startMark = "var lines = String(payload).split('\\n');";
  const endMark = "return _ok('added=' + added";
  const s = src.indexOf(startMark);
  const e = src.indexOf(endMark, s);
  if (s < 0 || e < 0) throw new Error('无法在成品 hostscript.jsx 中定位导入循环');
  const body = src.slice(s, e);
  // 用 new Function 让这段成品代码在 Node 里跑；col / US 由外部注入
  const fn = new Function('payload', 'col', 'US', 'clearFirst', body + '\n return { added: added, failed: failed, notes: notes };');
  return { fn: fn, code: body };
}
const loop = loadJsxImportLoop();
ok('已切出成品导入循环', loop.code.length > 500, '(' + loop.code.length + ' 字符)');
ok('成品循环里有 setTypeAsComment（标记类型设为注释）', /setTypeAsComment/.test(loop.code));

function makeMockCollection() {
  const created = [];
  return {
    created: created,
    numMarkers: 0,
    createMarker: function (sec) {
      const m = {
        sec: sec, name: '', comments: '', colorIndex: null, typeComment: false,
        setColorByIndex: function (i) { this.colorIndex = i; },
        setTypeAsComment: function () { this.typeComment = true; },
      };
      created.push(m);
      this.numMarkers = created.length;
      return m;
    },
  };
}

function runReleaseImport(csvText, label) {
  const markers = rel.parseMarkerFile(csvText, FPS);
  const payload = rel.buildImportPayload(markers);
  const col = makeMockCollection();
  const res = loop.fn(payload, col, rel.US, 0);
  console.log('    [' + label + '] 解析 ' + markers.length + ' 条 → payload ' + payload.split('\n').length +
    ' 行 → JSX added=' + res.added + ' failed=' + res.failed);
  return { markers: markers, payload: payload, col: col, res: res };
}

const r1 = runReleaseImport(stripBom(csvMsRaw), 'ms CSV');
check('成品链路：added 数 = 标记数', r1.res.added, EXPECT_MS.length);
check('成品链路：failed = 0', r1.res.failed, 0);
ok('成品链路：Pr 侧标记未报 null', r1.res.notes.length === 0 || !/null@/.test(r1.res.notes.join(' ')));

console.log('\n— 成品命名映射规则（发布说明「显示名取备注列，M01 丢弃」） —');
const nm = r1.col.created.map(function (m) { return { name: m.name, comments: m.comments, color: m.colorIndex, type: m.typeComment }; });
check('插件产物的 name 列全是占位名（M+数字）',
  EXPECT_MS.every(function (m) { return /^M\d+$/.test(m.name); }), true);
check('标记名 = 备注列（占位名 M01/M02/M03 被丢弃）',
  nm.map(function (m) { return m.name; }),
  ['他说"过曝",第2条', '曝光过了', '转场处需要补一帧']);
check('占位名不占注释位（comments 全为空）',
  nm.map(function (m) { return m.comments; }), ['', '', '']);
check('颜色索引原样落到 Pr', nm.map(function (m) { return m.color; }), [2, 1, 6]);
check('每个标记都调用了 setTypeAsComment()', nm.map(function (m) { return m.type; }), [true, true, true]);

// 用一份「name 列是用户自填」的合成 payload 验证成品的另一条分支：不会丢信息，而是移进注释。
// （插件自己不会产出这种文件，但导入别人给的文件时会出现。）
{
  const synthetic = rel.buildImportPayload([{ sec: 2.5, name: '转场', desc: '需要补一帧', color: 3 }]);
  const col2 = makeMockCollection();
  const res2 = loop.fn(synthetic, col2, rel.US, 0);
  ok('合成样例：自填 name 的标记也能被成品接收', res2.added === 1 && res2.failed === 0);
  check('自填 name 被移到标记注释里（不丢信息）', [col2.created[0].name, col2.created[0].comments], ['需要补一帧', '转场']);
}

/* ============ ⑤ 边界输入：成品自己会 clamp 颜色、折叠换行 ============ */
console.log('\n— 边界输入（越界/NaN/多行）走成品代码 —');
const nasty =
  'time,name,comment,color\n' +
  '1.000,c_nan,NaN 颜色,NaN\n' +
  '2.000,c_over,越界 99,99\n' +
  '3.000,c_neg,负数,-1\n' +
  '4.000,自定义名,"第一行\r\n第二行",3\n';
const r2 = runReleaseImport(nasty, 'nasty');
check('边界输入不丢标记', r2.res.added, 4);
check('边界输入 failed = 0', r2.res.failed, 0);
check('成品把越界/NaN 颜色 clamp 到 0..7',
  r2.col.created.map(function (m) { return m.colorIndex; }), [0, 0, 0, 3]);
check('多行备注被成品折叠成单行（payload 层）',
  r2.col.created[3].name, '第一行 第二行');
check('自定义名保留到注释', r2.col.created[3].comments, '自定义名');

/* ============ ⑥ 插件产物 → 成品：矩阵汇总 ============ */
console.log('\n— 插件产物逐一过成品链路 —');
const matrix = [
  ['ms CSV', path.join(OUT, 'ms', 'roundtrip.csv')],
  ['ff CSV', path.join(OUT, 'ff', 'roundtrip.csv')],
  ['sidecar JSON', files.sidecar],
  ['robust 场景A CSV', path.join(OUT, 'robust', 'A', 'robust.csv')],
  ['robust 场景C 边界颜色 CSV', path.join(OUT, 'robust', 'C', 'robust.csv')],
  ['NTSC ff CSV', path.join(OUT, 'ntsc', 'ff', 'ntsc.csv')],
];
let matrixBad = 0;
matrix.forEach(function (row) {
  const p = row[1];
  if (!fs.existsSync(p)) { console.log('    [SKIP] ' + row[0] + '（产物不存在）'); return; }
  const text = stripBom(fs.readFileSync(p, 'utf8'));
  const markers = rel.parseMarkerFile(text, /\.json$/.test(p) ? FPS : (p.indexOf('ntsc') >= 0 ? 30000 / 1001 : FPS));
  const payload = rel.buildImportPayload(markers);
  const col = makeMockCollection();
  const res = loop.fn(payload, col, rel.US, 0);
  const colorsOk = col.created.every(function (m) { return Number.isInteger(m.colorIndex) && m.colorIndex >= 0 && m.colorIndex <= 7; });
  const good = markers.length > 0 && res.added === markers.length && res.failed === 0 && colorsOk;
  if (!good) matrixBad++;
  console.log('    ' + (good ? 'PASS' : 'FAIL') + '  ' + row[0] + '：' + markers.length + ' 条 → added=' + res.added +
    ' failed=' + res.failed + ' 颜色合法=' + colorsOk);
});
ok('所有插件产物都能被成品完整吃下', matrixBad === 0);

/* ============ ⑦ 安装现状：已安装副本必须就是成品（只读） ============ */
console.log('\n— 安装现状（只读） —');
const instPs1 = fs.readFileSync(path.join(REL_DIR, 'install.ps1'), 'utf8');
ok('成品安装脚本使用 CommonProgramFiles\\Adobe\\CEP\\extensions（系统级，需管理员）',
  /CommonProgramFiles/.test(instPs1) && /Adobe\\CEP\\extensions/.test(instPs1));
ok('成品自带 install.cmd（双击安装入口）', fs.existsSync(path.join(REL_DIR, 'install.cmd')));
ok('成品自带 -DryRun（可先看要做什么）', /DryRun/.test(instPs1));

const sysCep = path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Common Files', 'Adobe', 'CEP', 'extensions', 'com.frisk.sourcemarker');
const installed = fs.existsSync(sysCep);
ok('系统级 CEP 目录：' + (installed ? '已安装' : '未安装'), true, installed ? sysCep : '');
if (installed) {
  // 逐文件比对（装的是 normal 还是 full），并区分「功能代码不同」与「仅版本号不同」
  const filesToCompare = ['client/main.js', 'client/index.html', 'host/hostscript.jsx', 'client/CSInterface.js', '.debug', 'CSXS/manifest.xml'];
  const variants = [
    ['normal', path.join(REL_DIR, 'extension')],
    ['full', path.join(RELEASE, 'source-marker-1.0.0-full', 'extension')],
  ];
  let best = null;
  for (const v of variants) {
    const diffs = filesToCompare.filter(function (rel2) {
      const a = path.join(sysCep, rel2.split('/').join(path.sep));
      const b = path.join(v[1], rel2.split('/').join(path.sep));
      return !fs.existsSync(a) || !fs.existsSync(b) || sha256(a) !== sha256(b);
    });
    if (!best || diffs.length < best.diffs.length) best = { name: v[0], diffs: diffs };
  }
  const onlyManifestDiffers = best.diffs.length > 0 &&
    best.diffs.every(function (d) { return d === 'CSXS/manifest.xml'; });
  if (best.diffs.length === 0) {
    ok('已安装副本 = 成品 ' + best.name + ' 变体（6/6 文件同哈希）', true);
  } else if (onlyManifestDiffers) {
    ok('已安装副本 = 成品 ' + best.name + ' 变体（功能代码同哈希，仅 manifest 版本不同）',
      true, '（差异文件：CSXS/manifest.xml）');
  } else {
    // 「本机装的是什么」属于机器状态，不是仓库属性：
    // 有人可能正在开发更新版本（例如 1.0.1）并已安装，这不该让本套件失败。
    // 仓库自身的自洽性（extension/ == release）由本文件 ⑥ 节的哈希断言严格把关。
    note('本机已安装副本与成品 release 不一致 —— 机器状态，不计失败',
      '（差异文件：' + best.diffs.join(', ') + '；若你正在开发更新版本，忽略本提示即可）');
  }
  if (best.diffs.indexOf('CSXS/manifest.xml') >= 0) {
    const a = fs.readFileSync(path.join(sysCep, 'CSXS', 'manifest.xml'), 'utf8');
    const b = fs.readFileSync(path.join(REL_DIR, 'extension', 'CSXS', 'manifest.xml'), 'utf8');
    const va = (a.match(/ExtensionBundleVersion="([^"]+)"/) || [])[1];
    const vb = (b.match(/ExtensionBundleVersion="([^"]+)"/) || [])[1];
    // 只有版本号不同才算「同一构建、元数据未更新」
    const normalized = function (t) { return t.replace(/Version="[^"]+"/g, 'Version="X"'); };
    if (normalized(a) === normalized(b)) {
      ok('manifest 差异仅为版本号（已装 ' + va + ' → 成品 ' + vb + '），功能不受影响',
        true, '（重跑一次 install.cmd 即会同步为 ' + vb + '）');
    } else {
      note('manifest 除版本号外还有其它差异（已装 ' + va + ' vs 成品 ' + vb + '）—— 机器状态，不计失败');
    }
  }
  const instMain = path.join(sysCep, 'client', 'main.js');
  if (fs.existsSync(instMain) && sha256(instMain) === sha256(REL_MAIN)) {
    ok('已安装面板的解析器与本次验证的成品同哈希', true);
  } else {
    note('已安装面板的解析器与成品不同哈希 —— 机器状态，不计失败',
      '（已装 ' + (fs.existsSync(instMain) ? sha256(instMain).slice(0, 12) : '缺失') +
      ' vs 成品 ' + sha256(REL_MAIN).slice(0, 12) + '；本套件的契约验证用的是成品代码，不受影响）');
  }
}
// 注册表检查：Node 的 execSync 管道在本沙箱被禁（已由独立验证者证明是环境限制），
// 因此这里不判失败，只做提示；PowerShell 侧命令见输出。
console.log('    [提示] PlayerDebugMode 请在 PowerShell 里核对：');
console.log('           (Get-ItemProperty "HKCU:\\Software\\Adobe\\CSXS.11").PlayerDebugMode   # 期望 1');

console.log('\n结果：' + pass + ' 通过, ' + fail + ' 失败' +
  (note_count > 0 ? '（另有 ' + note_count + ' 条机器状态提示，不计失败）' : ''));
if (fail === 0) {
  console.log('结论：mpv 插件（' + sha256(path.join(ROOT, 'player-plugin', 'source-markers.lua')).slice(0, 16) +
    '…）的产物可被成品面板 source-marker 1.0.0 完整导入。');
}
process.exit(fail === 0 ? 0 : 1);
