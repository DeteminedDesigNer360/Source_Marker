/*
 * verify-import.js —— 用 Pr 扩展「真实的解析函数」校验标记文件（读取方契约）
 *
 * 做法：从包内 pr-extension/完整版/extension/client/main.js 里切出解析段（时间解析 → 状态刷新 之间的代码），
 * 在 vm 沙箱里求值，直接调用生产代码的 parseMarkerFile() / buildImportPayload()。
 * 不依赖 Premiere、不依赖浏览器。
 *
 * 运行： node tools/verify-import.js
 */
'use strict';

const path = require('path');
const { loadParser } = require('./pr-parser.js');

const MAIN_JS = path.join(__dirname, '..', 'source-marker-united-1.2.0-alpha-r4', 'pr-extension', '完整版', 'extension', 'client', 'main.js');
const parser = loadParser(MAIN_JS);
const parseMarkerFile = parser.parseMarkerFile;
const secondsToTimecode = parser.secondsToTimecode;
console.log('已加载 Pr 侧真实解析器：main.js#parser（' + parser.code.length + ' 字符）\n');

let pass = 0, fail = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  PASS  ' + name); }
  else { fail++; console.log('  FAIL  ' + name + '\n        期望 ' + e + '\n        实际 ' + a); }
}
function round(m) {
  return { sec: +m.sec.toFixed(3), name: m.name, desc: m.desc, color: m.color };
}

const FPS = 25;

/* ---------- 用例 1：插件导出 CSV（HH:MM:SS:FF，25fps @ 3.52s / 7.04s） ---------- */
const tc1 = secondsToTimecode(3.52, FPS);   // 期望 00:00:03:13
const tc2 = secondsToTimecode(7.04, FPS);   // 期望 00:00:07:01
check('时间码换算 3.52s@25fps', tc1, '00:00:03:13');
check('时间码换算 7.04s@25fps', tc2, '00:00:07:01');

const csvFF =
  'time,name,comment,color\n' +
  tc1 + ',开场,注意这里曝光过,1\n' +
  tc2 + ',转场,需要补一帧,6\n';
check('CSV + HH:MM:SS:FF 解析',
  parseMarkerFile(csvFF, FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '注意这里曝光过', color: '1' },
   { sec: 7.04, name: '转场', desc: '需要补一帧', color: '6' }]);

/* ---------- 用例 2：秒 + 毫秒（不依赖帧率，最稳） ---------- */
const csvMs = 'time,name,comment,color\n00:00:03.520,开场,曝光过,1\n7.040,转场,补一帧,6\n';
check('CSV + HH:MM:SS.mmm / 纯秒',
  parseMarkerFile(csvMs, FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' },
   { sec: 7.04, name: '转场', desc: '补一帧', color: '6' }]);

/* ---------- 用例 3：中文表头 ---------- */
const csvCn = '时间码,名称,备注,颜色\n00:00:03:13,开场,曝光过,1\n';
check('CSV + 中文表头',
  parseMarkerFile(csvCn, FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' }]);

/* ---------- 用例 4：无表头（时间,名称,内容,颜色） ---------- */
check('CSV 无表头',
  parseMarkerFile('3.52,开场,曝光过,1\n', FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' }]);

/* ---------- 用例 5：JSON ---------- */
check('JSON {markers:[...]}',
  parseMarkerFile('{"markers":[{"time":3.52,"name":"开场","comment":"曝光过","color":4}]}', FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '4' }]);

/* ---------- 用例 6：描述里带逗号 / 引号（导出必须转义） ---------- */
check('CSV 引号转义（描述含逗号与引号）',
  parseMarkerFile('time,name,comment,color\n3.520,"开场, 第2条","他说""过曝""",2\n', FPS).map(round),
  [{ sec: 3.52, name: '开场, 第2条', desc: '他说"过曝"', color: '2' }]);

/* ---------- 用例 7：8 个颜色索引全部原样透传 ---------- */
const rows = [];
for (let i = 0; i < 8; i++) rows.push((i + 1) + '.000,c' + i + ',d' + i + ',' + i);
const parsedColors = parseMarkerFile('time,name,comment,color\n' + rows.join('\n') + '\n', FPS)
  .map(function (m) { return m.color; });
check('颜色索引 0..7 原样透传', parsedColors, ['0', '1', '2', '3', '4', '5', '6', '7']);

/* ---------- 用例 8：大时间戳 ---------- */
check('大时间戳（1 小时以上）',
  parseMarkerFile('time,name,comment,color\n01:02:03.500,长片,尾段,3\n', FPS).map(round),
  [{ sec: 3723.5, name: '长片', desc: '尾段', color: '3' }]);

/* ---------- 用例 9：UTF-8 BOM（规范 §1.1：读取方必须容忍） ---------- */
check('带 BOM 的 CSV 仍能解析',
  parseMarkerFile('\uFEFFtime,name,comment,color\n3.520,开场,曝光过,1\n', FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' }]);

/* ---------- 用例 10：未知扩展列必须被忽略（规范 §1.2） ---------- */
check('多一个未知列 color_name 不影响',
  parseMarkerFile('time,name,comment,color,color_name\n3.520,开场,曝光过,1,红\n', FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' }]);

/* ---------- 用例 11：引号字段内允许换行（RFC4180） ---------- */
check('备注含换行（引号包裹）',
  parseMarkerFile('time,name,comment,color\n3.520,多行,"第一行\r\n第二行",2\n', FPS).map(round),
  [{ sec: 3.52, name: '多行', desc: '第一行\r\n第二行', color: '2' }]);

/* ---------- 用例 12：规范 v1 的 JSON 包裹（format/version/source） ---------- */
check('JSON v1 结构（含 source 元数据）',
  parseMarkerFile(JSON.stringify({
    format: 'source-markers', version: 1, created: '2026-10-06T00:00:00Z',
    source: { file: 'D:\\a.mp4', fps: 25, durationSec: 10, timeFormat: 'ms' },
    markers: [{ time: 3.52, tc: '00:00:03:13', name: '开场', comment: '曝光过', color: 1 }],
  }), FPS).map(round),
  [{ sec: 3.52, name: '开场', desc: '曝光过', color: '1' }]);

/* ---------- 用例 13：形状不对的 JSON 不能炸（规范 §6） ---------- */
[
  ['{"markers":123}', 'markers 是数字'],
  ['{"markers":"abc"}', 'markers 是字符串'],
  ['{"data":true}', 'data 是布尔'],
  ['{"markers":[]}', '空数组'],
  ['{"version":1}', '只有 version'],
  ['{"markers":[{"time":null}]}', '时间缺失'],
].forEach(function (c) {
  let threw = false;
  let got = null;
  try { got = parseMarkerFile(c[0], FPS); } catch (e) { threw = true; }
  check('坏 JSON 不抛异常且解析为 0 条（' + c[1] + '）', [threw, got && got.length], [false, 0]);
});

/* ---------- 用例 14：越界颜色在解析层原样透传（clamp 由 payload/插件负责） ---------- */
check('颜色 99 原样透传（由消费方 clamp）',
  parseMarkerFile('time,name,comment,color\n3.520,越界,测试,99\n', FPS).map(function (m) { return m.color; }),
  ['99']);

/* ---------- 用例 15：进入 Pr 宿主的 payload（main.js 的真实实现） ---------- */
if (parser.buildImportPayload) {
  const US = parser.US;
  const nasty = [
    { sec: 1, name: 'a,b', desc: '带"引号"和,逗号', color: '99' },
    { sec: 2, name: 'multi', desc: '第一行\r\n第二行', color: '1' },
    { sec: 3, name: 'multi-lf', desc: '上行\n下行', color: '2' },
    { sec: 4, name: 'pipe|name', desc: 'a|b|c', color: '3' },
    { sec: 5, name: '超长', desc: new Array(5001).join('x'), color: '4' },
    { sec: 6, name: '', desc: '只有备注', color: '' },
    { sec: 7, name: 'tab', desc: '前\t后', color: '7' },
    { sec: 8, name: 'us', desc: '含\u001f分隔符', color: '-1' },
    { sec: 9, name: 'cr', desc: '前\r后', color: 'abc' },
  ];
  const payloadRows = parser.buildImportPayload(nasty).split('\n');
  const fields = payloadRows.map(function (r) { return r.split(US); });

  check('payload 行数 == 标记数（换行不再把一条拆成两行）', payloadRows.length, nasty.length);
  check('每行都是 4 个字段', fields.map(function (f) { return f.length; }),
    [4, 4, 4, 4, 4, 4, 4, 4, 4]);
  check('秒数原样保留（3 位小数）', fields.map(function (f) { return f[0]; }),
    ['1.000', '2.000', '3.000', '4.000', '5.000', '6.000', '7.000', '8.000', '9.000']);
  check('CR/LF/US 折叠成空格', [fields[1][2], fields[2][2], fields[7][2]],
    ['第一行 第二行', '上行 下行', '含 分隔符']);
  check('TAB 不受影响（不是分隔符）', fields[6][2], '前\t后');
  check('超长字段完整', fields[4][2].length, 5000);
  check('颜色 clamp 到 0..7', fields.map(function (f) { return f[3]; }),
    ['0', '1', '2', '3', '4', '0', '7', '0', '0']);
} else {
  fail++;
  console.log('  FAIL  main.js 里找不到 buildImportPayload（F4 修复缺失？）');
}

console.log('\n结果：' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
