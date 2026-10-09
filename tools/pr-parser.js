/*
 * pr-parser.js —— 从 Pr 扩展的 extension/client/main.js 里加载「真实的」标记解析函数
 *
 * 目的：任何"我方产物能否被 Pr 面板读懂"的结论，都必须由生产代码自己来证明，
 * 而不是由测试脚本重新实现一遍解析逻辑。
 *
 * 用法：
 *   const { loadParser } = require('./pr-parser.js');
 *   const pr = loadParser();               // { parseMarkerFile, secondsToTimecode, parseTimeToSeconds }
 *   const markers = pr.parseMarkerFile(text, 25);
 */
'use strict';

const fs = require('fs');
const vm = require('vm');
const path = require('path');

const START = '/* ------------------------------ 时间解析';
const END = '/* ------------------------------ 状态刷新';

function loadParser(mainJsPath) {
  const file = mainJsPath || path.join(__dirname, '..', 'source-marker-united-1.2.0-alpha-r4', 'pr-extension', '完整版', 'extension', 'client', 'main.js');
  const src = fs.readFileSync(file, 'utf8');
  const startAt = src.indexOf(START);
  const endAt = src.indexOf(END);
  if (startAt < 0 || endAt <= startAt) {
    throw new Error('无法在 ' + file + ' 中定位解析段（源码结构变了？）');
  }
  const parserCode = src.slice(startAt, endAt);
  // US 是 main.js 顶部的字段分隔符常量（在解析段之外），沙箱里补一个同样的值
  const sandbox = { log: function () {}, console: console, US: '\u001f' };
  vm.createContext(sandbox);
  vm.runInContext(parserCode, sandbox, { filename: 'main.js#parser' });
  const want = ['parseMarkerFile', 'secondsToTimecode', 'parseTimeToSeconds'];
  for (const name of want) {
    if (typeof sandbox[name] !== 'function') {
      throw new Error('解析段里没有导出 ' + name);
    }
  }
  return {
    code: parserCode,
    parseMarkerFile: sandbox.parseMarkerFile,
    secondsToTimecode: sandbox.secondsToTimecode,
    parseTimeToSeconds: sandbox.parseTimeToSeconds,
    // 宿主 payload 构造器（同一段代码里，返回的是 US 分隔的行）
    buildImportPayload: typeof sandbox.buildImportPayload === 'function' ? sandbox.buildImportPayload : null,
    US: '\u001f',
  };
}

module.exports = { loadParser };
