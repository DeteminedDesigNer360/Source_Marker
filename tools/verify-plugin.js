/*
 * verify-plugin.js —— 校验「播放器插件」的产物是否符合标记交换格式 v1，并能原样进入 Pr
 *
 * 用法： node tools/verify-plugin.js [输出目录] [ms|ff]
 *   ms（默认）→ 期望 CSV 时间列是毫秒（规范默认）
 *   ff         → 期望 CSV 时间列是 HH:MM:SS:FF（整数帧率下可逆）
 *
 * 校验方式：用 Pr 扩展真实的解析器（tools/pr-parser.js）读这些文件，
 * 并断言时间戳（帧精确）、颜色索引、名称/备注、BOM、转义、幂等。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { loadParser } = require('./pr-parser.js');

const OUT = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(__dirname, '..', 'probe', 'out');
const MODE = (process.argv[3] || 'ms').toLowerCase();
const SIDECAR = process.argv[4]
  ? path.resolve(process.argv[4])
  : path.join(__dirname, '..', 'probe', 'test25.marks.json');
const FPS = 25;

let pass = 0;
let fail = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  PASS  ' + name); }
  else { fail++; console.log('  FAIL  ' + name + '\n        期望 ' + e + '\n        实际 ' + a); }
}
function round(m) {
  return { sec: +m.sec.toFixed(3), name: m.name, desc: m.desc, color: m.color };
}
function stripBom(text) {
  return text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

console.log('输出目录：' + OUT + '   时间格式模式：' + MODE);
if (!fs.existsSync(OUT)) {
  console.error('FAIL: 输出目录不存在，先跑 test/run-test.ps1');
  process.exit(2);
}

const pr = loadParser();
console.log('已加载 Pr 侧真实解析器（main.js#parser，' + pr.code.length + ' 字符）\n');

/* ---------- 期望的 3 个标记（由 driver.lua 的动作序列决定） ----------
   name 列的约定：插件只写占位名（M+数字），用户输入一律进 comment ——
   Pr 面板会丢弃 M+数字 形式的名称，并把 comment 当作标记名。 */
const EXPECT = [
  { sec: 1.24, name: 'M03', desc: '他说"过曝",第2条', color: '2' },  // 期望帧 31
  { sec: 3.52, name: 'M01', desc: '曝光过了', color: '1' },          // 期望帧 88
  { sec: 7.04, name: 'M02', desc: '转场处需要补一帧', color: '6' },   // 期望帧 176
];
const EXPECT_TC = ['00:00:01:06', '00:00:03:13', '00:00:07:01'];
const EXPECT_MS = ['00:00:01.240', '00:00:03.520', '00:00:07.040'];
const EXPECT_TIME_COL = MODE === 'ff' ? EXPECT_TC : EXPECT_MS;

const csvPath = path.join(OUT, 'roundtrip.csv');
const csvRaw = fs.readFileSync(csvPath, 'utf8');

console.log('— CSV 字节层（规范 v1 §1.1） —');
check('带 UTF-8 BOM', csvRaw.charCodeAt(0) === 0xFEFF, true);
check('BOM 之后就是表头', stripBom(csvRaw).split(/\r?\n/)[0], 'time,name,comment,color');
check('使用 CRLF 换行', /\r\n/.test(csvRaw), true);
check('描述里的引号被转义为双写', /""/.test(csvRaw), true);
check('含逗号的字段被引号包裹', /"他说""过曝"",第2条"/.test(csvRaw), true);
check(MODE + ' 模式下时间列即预期格式',
  stripBom(csvRaw).split(/\r?\n/).slice(1).filter(Boolean).map(function (l) { return l.split(',')[0]; }),
  EXPECT_TIME_COL);

console.log('\n— Pr 解析器读 roundtrip.csv —');
const fromCsv = pr.parseMarkerFile(stripBom(csvRaw), FPS).map(round);
check('解析出 3 条标记', fromCsv.length, 3);
check('标记内容与帧精确时间', fromCsv, EXPECT);

console.log('\n— 时间码换算（Pr 侧实现） —');
check('1.24s@25fps -> 00:00:01:06', pr.secondsToTimecode(1.24, FPS), '00:00:01:06');
check('3.52s@25fps -> 00:00:03:13', pr.secondsToTimecode(3.52, FPS), '00:00:03:13');
check('7.04s@25fps -> 00:00:07:01', pr.secondsToTimecode(7.04, FPS), '00:00:07:01');

console.log('\n— Pr 解析器读 roundtrip.json（规范 v1 §2） —');
const jsonPath = path.join(OUT, 'roundtrip.json');
const jsonText = fs.readFileSync(jsonPath, 'utf8');
const jsonRaw = JSON.parse(jsonText);
check('JSON 不带 BOM', jsonText.charCodeAt(0) === 0xFEFF, false);
check('format = source-markers', jsonRaw.format, 'source-markers');
check('version = 1', jsonRaw.version, 1);
check('有 created 时间戳', typeof jsonRaw.created === 'string' && jsonRaw.created.length > 10, true);
check('source.fps 记录了帧率', jsonRaw.source && jsonRaw.source.fps > 0, true);
check('source 记录了源文件', !!(jsonRaw.source && jsonRaw.source.file), true);
check('markers 与 CSV 一致', pr.parseMarkerFile(jsonText, FPS).map(round), EXPECT);
check('JSON 里同时带 time 与 tc', [jsonRaw.markers[0].time, jsonRaw.markers[0].tc], [1.24, EXPECT_TC[0]]);

console.log('\n— 往返一致性（导出 -> 清空 -> 导入 -> 再导出） —');
const reimportRaw = fs.readFileSync(path.join(OUT, 'reimport.csv'), 'utf8');
check('重新导入后再导出仍为同一批标记', pr.parseMarkerFile(stripBom(reimportRaw), FPS).map(round), EXPECT);
check('两次导出逐字节一致（幂等）', reimportRaw === csvRaw, true);

console.log('\n— sidecar 自动保存（规范 v1 §2） —');
if (fs.existsSync(SIDECAR)) {
  const sideText = fs.readFileSync(SIDECAR, 'utf8');
  const side = JSON.parse(sideText);
  check('sidecar 与视频同名并保存了 3 条', side.markers.length, 3);
  check('sidecar 也是 v1 结构', [side.format, side.version], ['source-markers', 1]);
  check('sidecar 也能被 Pr 解析器读懂', pr.parseMarkerFile(sideText, FPS).map(round), EXPECT);
} else {
  fail++;
  console.log('  FAIL  找不到 sidecar：' + SIDECAR);
}

console.log('\n结果：' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
