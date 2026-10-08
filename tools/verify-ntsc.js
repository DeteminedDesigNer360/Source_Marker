/*
 * verify-ntsc.js —— 29.97fps 时间码往返回归
 *
 * 断言分两层，避免把「seek 的帧量化」误当成「格式误差」：
 *   ① 格式保真：Pr 按真实帧率 29.97003 从 CSV 还原出的秒数，
 *      与插件 JSON 里记录的 time（权威值）相差 ≤ 半帧；
 *      旧实现在这里会失败（60s 处偏 1.8 帧、115s 处偏 3.4 帧）。
 *   ② 落点合理：JSON 的 time 与请求的 seek 目标相差 ≤ 1.5 帧
 *      （mpv 的 exact seek 会落在 ≥ 目标的第一帧上，最多差一帧）。
 *
 * 用法： node tools/verify-ntsc.js <ntsc.csv> <ntsc.json> <mode:ms|ff>
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { loadParser } = require('./pr-parser.js');

const CSV = process.argv[2];
const JSON_FILE = process.argv[3];
const MODE = (process.argv[4] || 'ff').toLowerCase();
const FPS = 30000 / 1001;
const REQUESTED = [60.0, 115.0];
const HALF_FRAME = 0.5 / FPS;
const SEEK_TOL = 1.5 / FPS;

if (!CSV || !fs.existsSync(CSV) || !JSON_FILE || !fs.existsSync(JSON_FILE)) {
  console.error('FAIL: 找不到输入文件：' + CSV + ' / ' + JSON_FILE);
  process.exit(2);
}

const pr = loadParser();
const csvText = fs.readFileSync(CSV, 'utf8').replace(/^\uFEFF/, '');
const doc = JSON.parse(fs.readFileSync(JSON_FILE, 'utf8'));
const markers = pr.parseMarkerFile(csvText, FPS);
const author = doc.markers.map(function (m) { return m.time; });

console.log('模式：' + MODE + '   解析帧率：' + FPS.toFixed(5) + '   半帧容差：' + HALF_FRAME.toFixed(6) + 's');
console.log('CSV 时间列：' + JSON.stringify(csvText.split(/\r?\n/).slice(1).filter(Boolean).map(function (l) { return l.split(',')[0]; })));
console.log('JSON 权威 time：' + JSON.stringify(author) + '\n');

let pass = 0;
let fail = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log('  PASS  ' + name + (detail ? '   ' + detail : '')); }
  else { fail++; console.log('  FAIL  ' + name + (detail ? '   ' + detail : '')); }
}

if (MODE === 'ms') {
  const fmt = csvText.split(/\r?\n/).slice(1).filter(Boolean).map(function (l) { return l.split(',')[0]; });
  ok('毫秒模式时间列格式', fmt.every(function (t) { return /^\d\d:\d\d:\d\d\.\d{3}$/.test(t); }), JSON.stringify(fmt));
}

ok('标记条数', markers.length === author.length && author.length === REQUESTED.length,
  'CSV=' + markers.length + ' JSON=' + author.length);

author.forEach(function (t, i) {
  const back = markers[i] ? markers[i].sec : NaN;
  const errFrames = Math.abs(back - t) * FPS;
  ok('格式保真 #' + (i + 1) + '（' + t.toFixed(4) + 's）', isFinite(back) && Math.abs(back - t) <= HALF_FRAME + 1e-9,
    '→ Pr 还原 ' + (isFinite(back) ? back.toFixed(6) : 'NaN') + 's，误差 ' + (isFinite(errFrames) ? errFrames.toFixed(3) : 'NaN') + ' 帧');
});

author.forEach(function (t, i) {
  const d = Math.abs(t - REQUESTED[i]);
  ok('落点合理 #' + (i + 1) + '（请求 ' + REQUESTED[i].toFixed(1) + 's）', d <= SEEK_TOL,
    '实际 ' + t.toFixed(4) + 's，差 ' + (d * FPS).toFixed(3) + ' 帧（seek 会落在 ≥ 目标的第一帧）');
});

console.log('\n结果：' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
