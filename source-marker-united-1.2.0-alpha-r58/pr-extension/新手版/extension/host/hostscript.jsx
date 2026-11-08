/*
 * Source Marker — ExtendScript host script
 *
 * 约定：每个对外函数返回分隔字符串，字段分隔符为 US(\u001F)
 *   "OK<US>f1<US>f2..."
 *   "ERR<US>message"
 * 面板侧用 main.js 里的 split(US) 解析。
 *
 * 所有 Premiere API 调用都包在 try/catch 里，避免一个失败拖垮整个面板。
 */

var US = String.fromCharCode(31);
var MEDIA_ALL = 4;   // 1=video only, 2=audio only, 4=all media types
var ENCODE_ENTIRE = 0, ENCODE_IN_TO_OUT = 1, ENCODE_WORK_AREA = 2;   // 仅作回退值

/*
 * workArea 一律从 app.encoder 取（Adobe 官方 PProPanel 的写法），取不到再回退整数。
 *
 * 更正一条曾经的错误结论：Pr 24.0 自检实测
 *   ENCODE_ENTIRE=number:0  ENCODE_IN_TO_OUT=number:1  ENCODE_WORK_AREA=undefined
 * ——它们本来就是**普通数字**，_wa() 与直接传 0/1 完全等价。
 * 所以「传裸整数导致导出全长」是错判；真正的原因是 encodeProjectItem 不认子剪辑的裁剪，
 * 必须改走 encodeSequence（见 smExportRange 里各策略的实测状态）。
 * 保留 _wa() 只为与官方示例取值方式一致，并兼容 ENCODE_WORK_AREA 缺失。
 */
function _wa(which) {
    try {
        if (which === 'entire' && typeof app.encoder.ENCODE_ENTIRE !== 'undefined') return app.encoder.ENCODE_ENTIRE;
        if (which === 'inout' && typeof app.encoder.ENCODE_IN_TO_OUT !== 'undefined') return app.encoder.ENCODE_IN_TO_OUT;
        if (which === 'work' && typeof app.encoder.ENCODE_WORK_AREA !== 'undefined') return app.encoder.ENCODE_WORK_AREA;
    } catch (e) {}
    return which === 'entire' ? ENCODE_ENTIRE : (which === 'inout' ? ENCODE_IN_TO_OUT : ENCODE_WORK_AREA);
}

function _ok() {
    var p = ['OK'];
    for (var i = 0; i < arguments.length; i++) p.push(String(arguments[i]));
    return p.join(US);
}
function _err(m) { return 'ERR' + US + String(m); }

function _num(v, d) { var n = Number(v); return isNaN(n) ? d : n; }

function _tc(t) {
    try {
        var v = t.timecode;
        return (typeof v === 'undefined' || v === null) ? '' : String(v);
    } catch (e) { return ''; }
}

/*
 * Pr 24.0 实测：Time 对象**没有** timecode 属性（返回 undefined），必须自己格式化。
 * 而且刻意不走 Time 对象：给 Time.seconds 赋值后 .ticks 是否会同步重算并无保证
 * （Bruce Bullis 的官方例子只证明 .seconds 生效）。所以时间码是 (秒数, 帧率) 的纯函数。
 */
function _timecodeAt(item, seconds, sep) {
    var fps = _fps(item);
    var fpsR = Math.max(1, Math.round(fps > 0 ? fps : 25));
    var total = Math.round(_num(seconds, 0) * (fps > 0 ? fps : 25));
    if (total < 0) total = 0;
    var f = total % fpsR;
    var s = Math.floor(total / fpsR);
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return p(Math.floor(s / 3600)) + sep + p(Math.floor((s % 3600) / 60)) + sep + p(s % 60) + sep + p(f);
}

function _srcItem() {
    try { return app.sourceMonitor.getProjectItem(); } catch (e) { return null; }
}

function _fps(item) {
    try {
        var f = item.getFootageInterpretation().frameRate;
        if (f > 0) return f;
    } catch (e) {}
    try {
        var tb = app.project.activeSequence.timebase;   // ticks per frame
        if (tb > 0) return 254016000000 / tb;
    } catch (e) {}
    return 25;
}

/* 用「取一个已有 Time 再改秒数」的方式构造 Time，避免依赖 Time 构造函数 */
function _timeAt(item, seconds) {
    var t = item.getInPoint();
    t.seconds = seconds;
    return t;
}

/*
 * createSubClip —— 真机教训（Pr 24.0），别重蹈覆辙：
 *
 * 只判断"返回了对象"远远不够。用 ticks 字符串调用**会返回一个合法对象**，
 * 但它跨越的是整条素材，于是 encodeProjectItem 出来的仍是完整时长
 * （实测：入点 0s 与 26.72s 两次导出都是 125.675s，文件大小都是 120,407,161B）。
 *
 * 所以这里必须**回读子剪辑自己的入出点**，只有范围对得上才算这个变体可用。
 * 子剪辑入出点有两种可能的参照系，都接受：
 *   A 绝对素材时间：in≈wantIn, out≈wantOut
 *   B 子剪辑自身时间：in≈0,    out≈wantOut-wantIn
 * 范围不对的试探品立即删掉，避免在工程里堆垃圾。
 */
var _subclipVariant = 'none';
var _subclipError = '';
/*
 * workArea 必须在回读之后才能决定，不能事先写死：
 *   回读是「相对自身」(in≈0, out≈跨度) → 子剪辑的媒体已被裁到范围里 → ENCODE_ENTIRE
 *   回读是「绝对素材」(in≈请求in, out≈请求out) → 媒体仍是主素材     → ENCODE_IN_TO_OUT
 * 真机教训：对已被裁过的子剪辑传 ENCODE_IN_TO_OUT，Pr 24.0 会导出**主素材全长**
 * （实测三次导出都是 125.675s，而请求范围只有 50.04s）。
 */
var _subclipWorkArea = 'entire';   // 'entire' | 'inout'

function _workAreaName(kind) {
    var v = _wa(kind);
    // 枚举在 ExtendScript 里是宿主对象，String() 会得到 "[object Object]"，那样日志没意义
    var shown = (typeof v === 'number' || typeof v === 'string') ? String(v) : '(app.encoder 枚举)';
    return kind + '=' + shown;
}

function _subclipOf(item, name, startTime, endTime, hardBoundaries) {
    var hb = (hardBoundaries === 0 || hardBoundaries === '0') ? 0 : 1;
    var wantIn = _num(startTime.seconds, 0);
    var wantOut = _num(endTime.seconds, 0);
    var span = wantOut - wantIn;
    // 顺序按证据强度排：Adobe 官方 PProPanel 用的就是 Time 对象（new Time(); t.seconds = x），
    // 所以 time-objects 优先；ticks-string 是官方文档写的形式，作次选。
    var variants = [
        ['time-objects', startTime, endTime],
        ['ticks-string', String(startTime.ticks), String(endTime.ticks)],
        ['seconds-number', wantIn, wantOut],
        ['timecode-string', _timecodeAt(item, wantIn, ':'), _timecodeAt(item, wantOut, ':')]
    ];
    var report = [];
    for (var i = 0; i < variants.length; i++) {
        var label = variants[i][0];
        var probe = null;
        try { probe = item.createSubClip(name, variants[i][1], variants[i][2], hb, 1, 1); }
        catch (e) { report.push(label + '=抛错'); continue; }
        if (!probe) { report.push(label + '=返回空'); continue; }

        var gotIn = -1, gotOut = -1;
        try { gotIn = _num(probe.getInPoint().seconds, -1); } catch (e) {}
        try { gotOut = _num(probe.getOutPoint().seconds, -1); } catch (e) {}

        var absOk = Math.abs(gotIn - wantIn) <= 0.5 && Math.abs(gotOut - wantOut) <= 0.5;
        var relOk = Math.abs(gotIn) <= 0.5 && Math.abs(gotOut - span) <= 0.5;
        if (relOk || absOk) {
            _subclipVariant = label;
            // 相对回读 = 媒体已被裁好，编码整个子剪辑即可；绝对回读 = 还得靠入出点
            _subclipWorkArea = relOk ? 'entire' : 'inout';
            _subclipError = '';
            return probe;
        }
        report.push(label + '=范围不符(' + gotIn.toFixed(3) + '~' + gotOut.toFixed(3) + ')');
        _deleteItemVerified(probe, name);   // 不看返回值，删完核实
    }
    _subclipVariant = 'FAILED';
    _subclipError = report.join(' ; ');
    return null;
}

/* 子剪辑名带上范围，避免同一个名字在工程里反复堆积 */
function _rangeName(item, inSec, outSec) {
    return String(item.name) + ' [' + _timecodeAt(item, inSec, '-') + '~' + _timecodeAt(item, outSec, '-') + ']';
}

/* ============================ 状态 ============================ */

function smGetState() {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var inT = item.getInPoint(), outT = item.getOutPoint();
        var markers = 0;
        try { markers = item.getMarkers().numMarkers; } catch (e) {}
        var inSec = _num(inT.seconds, 0), outSec = _num(outT.seconds, 0);
        return _ok(item.name, item.getMediaPath(),
                   inSec.toFixed(3), outSec.toFixed(3),
                   _timecodeAt(item, inSec, ':'), _timecodeAt(item, outSec, ':'),
                   _fps(item).toFixed(4), markers, item.nodeId);
    } catch (e) { return _err('smGetState: ' + e); }
}

/* ============== 读源监视器播放头位置（一键互跳的锚点）==============
 * app.sourceMonitor.getPosition() 不是猜的：smSeekSeconds() 里已经用它做写回校验，
 * 并且在 Pr 24.0 真机上验过（日志 now=125.640 与目标精确吻合）。
 * 它的 .seconds 与 getInPoint().seconds 同源，是【真实秒】——
 * 与 mpv 的 time-pos 同一量纲，所以直接交给 mpv --start 不需要任何换算。
 */
function smGetPlayerPosition() {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var sec = _num(app.sourceMonitor.getPosition().seconds, 0);
        return _ok(sec.toFixed(3), _timecodeAt(item, sec, ':'));
    } catch (e) { return _err('smGetPlayerPosition: ' + e); }
}

/* ====================== 需求②：入出点编辑 ====================== */

function smSetInOut(inSec, outSec) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var a = item.getInPoint(); a.seconds = _num(inSec, 0);
        var b = item.getOutPoint(); b.seconds = _num(outSec, 0);
        var r1 = item.setInPoint(a, MEDIA_ALL);
        var r2 = item.setOutPoint(b, MEDIA_ALL);
        /* 读回校验：API 返回值语义各版本不一，只认读回来的值 */
        var bi = _num(item.getInPoint().seconds, -1);
        var bo = _num(item.getOutPoint().seconds, -1);
        return _ok('ret=' + r1 + '/' + r2,
                   'now=' + bi.toFixed(3) + '/' + bo.toFixed(3),
                   (Math.abs(bi - _num(inSec, 0)) < 0.05 && Math.abs(bo - _num(outSec, 0)) < 0.05)
                       ? 'VERIFIED' : 'MISMATCH-CHECK');
    } catch (e) { return _err('smSetInOut: ' + e); }
}

function smNudge(which, frames) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var fps = _fps(item);
        var isOut = (String(which) === 'out');
        var inSec = _num(item.getInPoint().seconds, 0);
        var outSec = _num(item.getOutPoint().seconds, 0);
        var cur = isOut ? outSec : inSec;
        /* ★ 选帧率：Pr 的入出点**必定落在它自己的帧格上** —— 也就是「起始值 × 真帧率 ≈ 整数」。
           真机实测（r27 日志）两种素材正好相反：
             · 23.976 素材：frameRate=23.976023976，cur=3599.888
                 cur×23.976024 = 86311.0 ✓ 整数     cur×24 = 86397.31 ✗
                 → 必须用**原始 frameRate**；用 round 会漂到别的格上（请求 1 帧却动 2 帧，1 小时附近干脆不动）
             · 30 素材：frameRate=30.00102，cur=2.000
                 cur×30.00102 = 60.002 ✗            cur×30 = 60.0 ✓ 整数
                 → 必须用 **round(frameRate)**
           所以**不能写死哪一个**：用"哪个率能让 cur 落在整数帧上"来判别。
           门槛 0.001 帧：够严到把上面两种情况分开，又容得下浮点噪声。 */
        var cands = [fps, Math.round(fps)];
        var rate = fps;
        for (var ci = 0; ci < cands.length; ci++) {
            var c = cands[ci];
            if (!(c > 0)) continue;
            if (Math.abs(cur * c - Math.round(cur * c)) < 0.001) { rate = c; break; }
        }
        var nextIdeal = (Math.round(cur * rate) + _num(frames, 0)) / rate;
        if (nextIdeal < 0) nextIdeal = 0;
        /* ⚠️ 不许把入点推过出点（反之亦然）—— 那是非法区间。越界就如实回报，
           **绝不把非法值交给 setInPoint / setOutPoint**。 */
        var gap = 1 / rate;
        if (!isOut && nextIdeal > outSec - gap) return _err('入点不能再往后（不能越过出点）');
        if (isOut && nextIdeal < inSec + gap) return _err('出点不能再往前（不能越过入点）');
        /* ★★ 帧边界上的浮点陷阱（r28 真机日志锁定）：
           `nextIdeal` **正好落在帧格边界上**，而 Pr 把 Time 转成 ticks 是**截断**的 ——
           浮点噪声只要让落点掉到边界**下面一丁点**，Pr 就退到**前一帧**：
             起始=1853.310 请求=1853.351（正是 +1 帧）→ 现=1853.310  实际移动 0.00 帧
             起始=1853.643 请求=1853.602（正是 −1 帧）→ 现=1853.560  实际移动 −2.00 帧
           而且**时好时坏** —— 噪声落在边界哪一侧是随机的（差值只有 1 ULP 量级）。
           这一条同时解释了此前所有现象：改成跳 2 帧就"好像好了"（余量盖过 1 ULP）、
           手动设一次能好一阵、失败有连续性（噪声方向固定后一路对或一路错）。
           对策：把落点往**目标帧内部**推一点点（帧长的 1% ≈ 0.4 ms）。
           尺度对比：ticks 分辨率 ≈ 4e-12 秒、浮点噪声 ≈ 1e-13 秒 —— 1% 帧比它们大好几个数量级，
           又比一帧小 100 倍，绝不会误入下一帧。 */
        var eps = 0.01 / rate;
        var next = nextIdeal + eps;
        /* 0.1 帧：刚好能认出"差了整整一帧"。校验比的是**理想落点**（不含 eps）。 */
        var tol = 0.1 / rate;
        var nt = _timeAt(item, next);
        var r = isOut ? item.setOutPoint(nt, MEDIA_ALL) : item.setInPoint(nt, MEDIA_ALL);
        var back = isOut ? _num(item.getOutPoint().seconds, -1) : _num(item.getInPoint().seconds, -1);
        if (Math.abs(back - nextIdeal) <= tol) {
            return _ok(back.toFixed(3), 'r=' + r, 'VERIFIED(率=' + rate + ')');
        }
        /* 退路：改用 ticks（Pr 的原生时间单位）再试一次 —— 某些网格用秒表示不精确。 */
        var tpl = item.getInPoint();
        var tplSec = _num(tpl.seconds, 0), tplTicks = _num(tpl.ticks, 0);
        var tps = (tplSec > 0 && tplTicks > 0) ? (tplTicks / tplSec) : 254016000000;
        var nt2 = _timeAt(item, next);
        try { nt2.ticks = Math.round(next * tps); } catch (e2) {}
        var r2 = isOut ? item.setOutPoint(nt2, MEDIA_ALL) : item.setInPoint(nt2, MEDIA_ALL);
        var back2 = isOut ? _num(item.getOutPoint().seconds, -1) : _num(item.getInPoint().seconds, -1);
        if (Math.abs(back2 - nextIdeal) <= tol) {
            return _ok(back2.toFixed(3), 'r=' + r + '/' + r2,
                       'VERIFIED(ticks:' + Math.round(next * tps) + ' 率=' + rate + ')');
        }
        /* 仍不精确：把**实际移动了几帧**也报出来。
           VFR 素材没有均匀帧格，"移动 1 帧"本身就不是精确概念 —— 让日志能判读，
           而不是简单说一句失败。 */
        return _ok(back2.toFixed(3), 'r=' + r + '/' + r2,
                   'MISMATCH-CHECK 请求=' + nextIdeal.toFixed(3) + ' 现=' + back2.toFixed(3) +
                   ' 起始=' + cur.toFixed(3) + ' 率=' + rate + ' 实际移动=' +
                   ((back2 - cur) * rate).toFixed(2) + ' 帧');
    } catch (e) { return _err('smNudge: ' + e); }
}

function smClearInOut() {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        item.clearInPoint(MEDIA_ALL);
        item.clearOutPoint(MEDIA_ALL);
        return _ok();
    } catch (e) { return _err('smClearInOut: ' + e); }
}

/* 【已删除】这里原先有「源入出点 ⇄ 序列入出点」两个搬运函数
   （smPushInOutToSequence / smPullInOutFromSequence），按用户决定清理掉了。原因：
   序列入出点是**时间线上的位置**，片段入出点是**素材内部的位置** —— 坐标系不同，
   把数值直接搬过去一般没有意义（只有"序列从 0 开始且片段也从 0 开始"时才碰巧相等）。
   若要恢复这个能力，请**先把语义定清楚**（例如换算成片段内的相对位置），不要照搬旧实现。
   见 改动说明 §15。 */

/* ==================== 需求①：导出入出点范围 ==================== */

/*
 * 三种策略在 Pr 24.0 上的**实测**状态（产物用 MP4 mvhd 量时长，请求范围 50.040s）：
 *
 *   'sequence'  ✅ 可用 —— 子剪辑 → createNewSequenceFromClips → encodeSequence
 *               实测产物 50.069s / 46.0MB（期望 50.040s，误差 0.029s ≈ 不到一帧）
 *   'subclip'   ❌ 无效 —— encodeProjectItem 无论 workArea 传 ENTIRE 还是 IN_TO_OUT，
 *               都导出主素材全长 125.675s（子剪辑本身经回读确认是对的）
 *   'file'      ⚠️ 实验 —— encodeFile 传 Time 对象会抛 "Illegal Parameter type"，
 *               故对入出点做四种形式的梯度重试
 *
 * 三条路线都会在项目里留下东西（子剪辑 / 临时序列），AME 渲染期间不能删除。
 */
function smExportRange(outPath, presetPath, strategy, subclipName) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    if (!presetPath) return _err('preset (.epr) required');
    try {
        var inT = item.getInPoint(), outT = item.getOutPoint();
        var inSec = _num(inT.seconds, 0), outSec = _num(outT.seconds, 0);
        var name = subclipName ? String(subclipName) : _rangeName(item, inSec, outSec);
        var s = String(strategy);

        // --- 策略 'file'：encodeFile 直给入出点。
        //     Pr 24.0 实测：传 Time 对象会抛 "Illegal Parameter type"，所以对入出点的
        //     四种形式做梯度重试，哪种被接受就用哪种。---
        if (s === 'file') {
            var cands = [
                ['time-objects', inT, outT],
                ['ticks-string', String(inT.ticks), String(outT.ticks)],
                ['seconds-number', inSec, outSec],
                ['timecode-string', _timecodeAt(item, inSec, ':'), _timecodeAt(item, outSec, ':')]
            ];
            var ioFails = [];
            for (var ci = 0; ci < cands.length; ci++) {
                try {
                    var jobA = app.encoder.encodeFile(item.getMediaPath(), outPath, presetPath,
                                                      _wa('inout'), 0, cands[ci][1], cands[ci][2]);
                    if (jobA) {
                        return _ok('job=' + jobA, 'mode=file', 'io=' + cands[ci][0],
                                   'workArea=' + _workAreaName('inout'),
                                   'range=' + inSec.toFixed(3) + '~' + outSec.toFixed(3));
                    }
                    ioFails.push(cands[ci][0] + '=返回0');
                } catch (e) { ioFails.push(cands[ci][0] + '=' + e); }
            }
            return _err('encodeFile 四种入出点形式都被拒: ' + ioFails.join(' ; '));
        }

        // --- 策略 2 / 3：都要先做出范围可信的子剪辑 ---
        var sub = _subclipOf(item, name, inT, outT, 1);
        if (!sub) {
            return _err('已中止：无法创建范围可信的子剪辑，拒绝导出整条素材。' +
                        ' 请换用其它策略，或把这行发给开发者：' + _subclipError);
        }
        var subIn = -1, subOut = -1;
        try { subIn = _num(sub.getInPoint().seconds, -1); } catch (e) {}
        try { subOut = _num(sub.getOutPoint().seconds, -1); } catch (e) {}
        var rangeTxt = '子剪辑回读=' + subIn.toFixed(3) + '~' + subOut.toFixed(3);

        // --- 策略 3：临时序列 + encodeSequence（社区最成熟的导出路径）---
        if (s === 'sequence') {
            // 序列名用「SM 时码-时码」，方便事后在项目面板里一眼找到并清理
            var seqName = 'SM ' + _timecodeAt(item, inSec, '.') + '-' + _timecodeAt(item, outSec, '.');
            var seq = app.project.createNewSequenceFromClips(seqName, [sub], app.project.rootItem);
            if (!seq) return _err('createNewSequenceFromClips 返回空');
            // Pr 会忽略传入的名字改用素材名，这里显式再改一次；失败也不影响导出
            try { if (String(seq.name) !== seqName) seq.projectItem.name = seqName; } catch (e) {}
            var jobC = app.encoder.encodeSequence(seq, outPath, presetPath, _wa('entire'), 0, false);
            return jobC ? _ok('job=' + jobC, 'mode=sequence', 'sequence=' + seq.name,
                              'workArea=' + _workAreaName('entire'), 'via=' + _subclipVariant, rangeTxt,
                              '临时序列留在工程里，可用「清理临时序列」删除')
                        : _err('encodeSequence returned 0');
        }

        // --- 策略 2：encodeProjectItem ---
        var jobB = app.encoder.encodeProjectItem(sub, outPath, presetPath, _wa(_subclipWorkArea), 0);
        return jobB ? _ok('job=' + jobB, 'mode=subclip', 'subclip=' + name, 'via=' + _subclipVariant,
                          'workArea=' + _workAreaName(_subclipWorkArea), rangeTxt)
                    : _err('encodeProjectItem returned 0 (workArea=' + _workAreaName(_subclipWorkArea) + ')');
    } catch (e) { return _err('smExportRange: ' + e); }
}

/* ============ 导出前置检查 + 启动渲染队列 ============ */

/* 把"导出失败"从黑盒变成明确原因：预设读不读得到、输出目录写不写得进去 */
function smPreflight(outPath, presetPath) {
    var notes = [];
    var okAll = true;

    try {
        var pf = new File(String(presetPath));
        if (!pf.exists) { notes.push('预设文件不存在'); okAll = false; }
        else if (!pf.open('r')) { notes.push('预设无法读取'); okAll = false; }
        else { var len = pf.length; pf.close(); notes.push('预设 OK (' + len + 'B)'); }
    } catch (e) { notes.push('预设检查异常: ' + e); okAll = false; }

    try {
        var outFile = new File(String(outPath));
        var dir = outFile.parent;
        if (!dir || !dir.exists) { notes.push('输出目录不存在'); okAll = false; }
        else {
            var probe = new File(dir.fsName + '/__sm_write_probe.tmp');
            if (probe.open('w')) {
                probe.write('x');
                probe.close();
                try { probe.remove(); } catch (e) {}
                notes.push('输出目录可写');
            } else { notes.push('输出目录不可写'); okAll = false; }
        }
    } catch (e) { notes.push('输出目录检查异常: ' + e); okAll = false; }

    return okAll ? _ok(notes.join(' | ')) : _err(notes.join(' | '));
}

/* 没有这一步，「一键导出」只是入队，用户还得切到 AME 手动点开始 */
function smStartBatch() {
    try { return _ok('ret=' + app.encoder.startBatch()); }
    catch (e) { return _err('smStartBatch: ' + e); }
}

/* 收集名字里含 fragment 的项目项（递归走项目树，深度封顶 8 层） */
function _findItemsNamedLike(fragment, node, depth, out) {
    if (depth > 8) return out;
    var kids = null;
    try { kids = node.children; } catch (e) { return out; }
    if (!kids) return out;
    var n = 0;
    try { n = kids.numItems; } catch (e) { return out; }
    for (var i = 0; i < n; i++) {
        var it = null;
        try { it = kids[i]; } catch (e) { continue; }
        if (!it) continue;
        try { if (String(it.name).indexOf(fragment) >= 0) out.push(it); } catch (e) {}
        try { _findItemsNamedLike(fragment, it, depth + 1, out); } catch (e) {}
    }
    return out;
}

/*
 * 删除一个项目项，并且**核实它真的没了**。
 *
 * 实测（Pr 24.0）：projectItem.deleteBin() 对子剪辑/序列都是
 * "返回 true，但项目树里一个都没少"——文档却写"成功返回 0"。
 * 所以这里一律以「重新枚举」为准，并准备第二条路：先移进临时 bin，再删 bin
 * （deleteBin() 的文档用途本来就是删 bin）。
 */
function _deleteItemVerified(item, fragment) {
    var before = _findItemsNamedLike(fragment, app.project.rootItem, 0, []).length;
    var notes = [];
    try { notes.push('deleteBin=' + item.deleteBin()); }
    catch (e) { notes.push('deleteBin抛错:' + e); }
    var after1 = _findItemsNamedLike(fragment, app.project.rootItem, 0, []).length;
    if (after1 < before) return { ok: true, via: 'deleteBin', notes: notes.join(' ') };

    try {
        var bin = app.project.rootItem.createBin('__sm_trash__');
        if (bin) {
            try { notes.push('moveBin=' + item.moveBin(bin)); } catch (e) { notes.push('moveBin抛错:' + e); }
            try { notes.push('bin.deleteBin=' + bin.deleteBin()); } catch (e) { notes.push('bin删除抛错:' + e); }
        } else { notes.push('createBin 返回空'); }
    } catch (e) { notes.push('bin路线抛错:' + e); }

    var after2 = _findItemsNamedLike(fragment, app.project.rootItem, 0, []).length;
    return { ok: after2 < before, via: 'bin', notes: notes.join(' ') + ' 残留=' + after2 };
}

function _countSequencesNamedLike(fragment) {
    var n = 0;
    try {
        var seqs = app.project.sequences;
        for (var i = 0; i < seqs.numSequences; i++) {
            try { if (String(seqs[i].name).indexOf(fragment) === 0) n++; } catch (e) {}
        }
    } catch (e) { return -1; }
    return n;
}

/*
 * 一键清理：export 留下的 "SM " 临时序列 + 自检留下的 "__sm_selftest__" 项目项。
 *
 * 两个刻意的设计：
 *  1) 为什么不能自动删 —— AME 渲染期间必须能读到该序列，而 ExtendScript 没有渲染完成回调；
 *  2) **不看 deleteBin() 的返回值，只信"重新枚举后的实际残留"**。
 *     真机实测：对序列调 deleteBin() 返回的是 true（文档却写"成功返回 0"），
 *     所以按返回值判断会把成功当失败、也会把失败当成功。
 */
function smCleanupTempSequences() {
    try {
        var active = '';
        try { active = String(app.project.activeSequence.name); } catch (e) {}

        // ---------- 1) SM 临时序列 ----------
        var seqTargets = [];
        try {
            var seqs = app.project.sequences;
            for (var i = 0; i < seqs.numSequences; i++) {
                var s = seqs[i];
                if (s && String(s.name).indexOf('SM ') === 0 && String(s.name) !== active) seqTargets.push(s);
            }
        } catch (e) {}
        var skippedActive = _countSequencesNamedLike('SM ') - seqTargets.length;

        var seqNotes = [];
        for (var j = 0; j < seqTargets.length; j++) {
            var nm = String(seqTargets[j].name);
            // 正确 API 是 Project.deleteSequence()，**不是** seq.projectItem.deleteBin()
            // —— 实测后者返回 true 却一个都没删掉。
            try {
                var r = app.project.deleteSequence(seqTargets[j]);
                seqNotes.push(nm + ' deleteSequence=' + r);
            } catch (e) { seqNotes.push(nm + ' 抛错:' + e); }
        }
        var seqLeft = _countSequencesNamedLike('SM ');

        // ---------- 2) 自检残留 ----------
        var leftovers = _findItemsNamedLike('__sm_selftest__', app.project.rootItem, 0, []);
        var itemNotes = [];
        for (var k = 0; k < leftovers.length; k++) {
            var inm = '';
            try { inm = String(leftovers[k].name); } catch (e) {}
            var del = _deleteItemVerified(leftovers[k], '__sm_selftest__');
            itemNotes.push(inm + ' via=' + del.via + ' ' + del.notes);
        }
        var itemsLeft = _findItemsNamedLike('__sm_selftest__', app.project.rootItem, 0, []).length;

        return _ok('序列: 候选=' + (seqTargets.length + Math.max(0, skippedActive)),
                   '仍残留=' + (seqLeft < 0 ? '?' : seqLeft),
                   '测试项: 候选=' + leftovers.length, '仍残留=' + itemsLeft,
                   skippedActive > 0 ? '跳过活动序列 ' + skippedActive + ' 个' : '',
                   seqNotes.length ? '序列调用: ' + seqNotes.join(' ; ') : '',
                   itemNotes.length ? '项目项调用: ' + itemNotes.join(' ; ') : '');
    } catch (e) { return _err('smCleanupTempSequences: ' + e); }
}

/* ================= 需求③：插入 / 覆盖到指定轨道 ================= */

function smSendToSequence(mode, vIdx, aIdx, hardBoundaries) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    var seq = app.project.activeSequence;
    if (!seq) return _err('no active sequence');
    try {
        var inT = item.getInPoint(), outT = item.getOutPoint();
        var sub = _subclipOf(item, _rangeName(item, _num(inT.seconds, 0), _num(outT.seconds, 0)),
                             inT, outT, hardBoundaries);
        if (!sub) return _err('已中止：子剪辑范围不可信。' + _subclipError);
        var at = seq.getPlayerPosition();
        if (String(mode) === 'overwrite') {
            seq.videoTracks[Number(vIdx)].overwriteClip(sub, at);
            if (Number(aIdx) >= 0) seq.audioTracks[Number(aIdx)].overwriteClip(sub, at);
        } else {
            seq.insertClip(sub, at, Number(vIdx), Number(aIdx));
        }
        return _ok('mode=' + mode, 'v=' + vIdx, 'a=' + aIdx);
    } catch (e) { return _err('smSendToSequence: ' + e); }
}

/* ============= 需求④：外部文件 → 源监视器剪辑标记 ============= */

/*
 * payload：每行一条，字段用 US 分隔 -> "seconds<US>name<US>comment<US>colorIndex"
 * 面板负责把 CSV/JSON/SRT 解析成这个格式（时间戳换算需要 fps，面板从 smGetState 拿）。
 */
function smImportMarkers(payload, clearFirst) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var col = item.getMarkers();
        if (Number(clearFirst)) {
            var existing = [];
            for (var k = 0; k < col.numMarkers; k++) existing.push(col[k]);
            for (var d = 0; d < existing.length; d++) {
                try { col.deleteMarker(existing[d]); } catch (e) {}
            }
        }
        var lines = String(payload).split('\n');
        var added = 0, failed = 0, notes = [];
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (!line) continue;
            var f = line.split(US);
            var sec = Number(f[0]);
            if (isNaN(sec)) { failed++; continue; }
            try {
                var m = col.createMarker(sec);
                if (!m) { failed++; if (notes.length < 3) notes.push('null@' + sec); continue; }
                // 命名映射：标记名只取「内容/备注」列（payload 第 3 段）。
                // 第 2 段（name 列）一律忽略——它只是写入方留下的空列，既不参与命名也不进注释。
                var rawNote = String(f[2] || '').replace(/^\s+|\s+$/g, '');
                m.name = rawNote;
                m.comments = '';
                try { m.setTypeAsComment(); } catch (e) {}
                if (f[3]) { try { m.setColorByIndex(Number(f[3])); } catch (e) {} }
                added++;
            } catch (e) {
                failed++;
                if (notes.length < 3) notes.push('@' + sec + ':' + e);
            }
        }
        /* 重新取一次集合并读回总数，确认标记是真的落到了项目项上 */
        var now = -1;
        try { now = item.getMarkers().numMarkers; } catch (e) {}
        return _ok('added=' + added, 'failed=' + failed, 'now=' + now, notes.join(' | '));
    } catch (e) { return _err('smImportMarkers: ' + e); }
}

/* 返回结构化标记：fields[0]='count=N'，fields[1]=各标记用 GS(0x1D) 分隔、字段用 RS(0x1E) 分隔，
   字段序：秒|名|注释|颜色（颜色读不到时为 -1）。
   注释**不折叠换行**：契约 §6.5 要求「文件层不丢字符」，Pr 导出时要原样写进文件；
   界面显示若需折叠，由面板自己做（面板的 markerRowText 已折叠）。 */
var RS = String.fromCharCode(30), GS = String.fromCharCode(29);

/* 读标记颜色索引（0..7）。getColorByIndex() 不是猜的：完整版自检在 Pr 24.0 真机上验过
   ——写 setColorByIndex(3) 能读回 3。读不到返回 -1，面板按「无颜色」处理。 */
function _markerColor(m) {
    try {
        var n = Number(m.getColorByIndex());
        if (!isNaN(n) && n >= 0 && n <= 7) return String(Math.floor(n));
    } catch (e) {}
    return '-1';
}

function smListMarkers() {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var col = item.getMarkers(), out = [];
        for (var i = 0; i < col.numMarkers; i++) {
            var m = col[i];
            out.push(_num(m.start.seconds, 0).toFixed(3) + RS +
                     String(m.name || '') + RS +
                     String(m.comments || '') + RS +
                     _markerColor(m));
        }
        return _ok('count=' + col.numMarkers, out.join(GS));
    } catch (e) { return _err('smListMarkers: ' + e); }
}

/* 按面板给的下标 + 期望时间定位一条标记。**绝不盲操作**：
   先看 col[i] 的时间对不对得上（容差约 2 帧），对不上就在整列里找时间最接近的；
   最近的那个也差超过 2 秒，就认定"已经不是同一条了"，直接放弃 —— 宁可什么都不做。 */
function _markerAt(item, index, expectedSec) {
    var col = item.getMarkers();
    var want = _num(expectedSec, -1);
    var tol = 0.08;
    var i = Math.floor(_num(index, -1));
    if (i >= 0 && i < col.numMarkers) {
        var t0 = _num(col[i].start.seconds, -99);
        if (want < 0 || Math.abs(t0 - want) <= tol) return { col: col, m: col[i], idx: i };
    }
    if (want < 0) return null;
    var best = -1, bestD = 1e9;
    for (var k = 0; k < col.numMarkers; k++) {
        var tk = _num(col[k].start.seconds, -99);
        var d = Math.abs(tk - want);
        if (d < bestD) { bestD = d; best = k; }
    }
    if (best < 0 || bestD > 2.0) return null;
    return { col: col, m: col[best], idx: best };
}

/* 改标记正文。**写到 m.name**（不是 comments）—— 契约里"文件的 comment 列"在 Pr 侧
   就存在 name 属性上，界面显示的也是它；导入方向的 smImportMarkers 同理。
   name 属性可写已由完整版自检真机验证过（写 'sm_probe' 能读回）。 */
function smSetMarkerText(index, expectedSec, text) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var hit = _markerAt(item, index, expectedSec);
        if (!hit) return _err('找不到匹配的标记（下标与时间都对不上，可能已被改动）');
        var t = String(text == null ? '' : text).replace(/[\r\n]+/g, ' ');   // 单行输入，不引入换行
        hit.m.name = t;
        hit.m.comments = '';
        return _ok('idx=' + hit.idx + ' sec=' + _num(hit.m.start.seconds, 0).toFixed(3) +
                   ' 读回=' + String(hit.m.name || ''));
    } catch (e) { return _err('smSetMarkerText: ' + e); }
}

/* 删标记。deleteMarker 可用同样由自检真机验证过。定位失败一律不删。 */
function smDeleteMarker(index, expectedSec) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var hit = _markerAt(item, index, expectedSec);
        if (!hit) return _err('找不到匹配的标记（下标与时间都对不上，已取消删除）');
        var at = _num(hit.m.start.seconds, 0).toFixed(3);
        hit.col.deleteMarker(hit.m);
        return _ok('已删除 idx=' + hit.idx + ' sec=' + at +
                   ' 剩余=' + item.getMarkers().numMarkers);
    } catch (e) { return _err('smDeleteMarker: ' + e); }
}

/* 播放 / 停止源监视器。`app.sourceMonitor.play(speed)` 是 Pr 里**唯一**可用的
   源监视器控制入口（active / open / setActive / openInSourceMonitor / bringToFront
   真机自检全是 undefined）。
   真机实测语义（Pr 24.0.0，用户观察）：
     · play(1) —— 真的开始播放源；
     · play(0) —— 功能上停住，但 Pr 的传送按钮会显示成「暂停」方块（"以 0 速播放"的 UI 表现），
       看着像还在播，其实不动；
     · **两种都不会改变"哪个监视器是活动监视器"** —— 所以按空格仍然按 Pr 自己的规矩走。
       因此面板**不**再在点标记时偷偷调它（那会平白留下"暂停"状态这个副作用）。
   面板的「播放源 / 暂停源」按钮显式用它，好让你在面板里干活时不必去点 Pr 的监视器。 */
function smPlaySource(speed) {
    try {
        if (typeof app.sourceMonitor.play !== 'function') return _err('此版本没有 sourceMonitor.play');
        var s = _num(speed, 1);
        s = (s >= 0.5) ? 1 : 0;
        app.sourceMonitor.play(s);
        var p = app.sourceMonitor.getPosition();
        return _ok((s === 0 ? '已停止源监视器' : '源监视器开始播放') +
                   '（位置=' + _num(p && p.seconds, 0).toFixed(3) + '）');
    } catch (e) { return _err('smPlaySource: ' + e); }
}

/* 原生文本输入框。CEP 面板里中文输入法的候选浮窗位置不可靠（CEF 老毛病），
   而 ExtendScript 的 prompt() 是**原生模态对话框**，输入法在那里是正常的。
   返回 _err('cancelled') 表示用户取消；返回"没有 prompt"表示此版本不支持，
   面板据此退回自己的编辑条。文本里的分隔符一律折叠成空格，免得破坏回传协议。 */
function smPromptText(title, dflt) {
    try {
        if (typeof prompt !== 'function') return _err('此版本没有 ExtendScript prompt()');
        var v = prompt(String(title || '输入'), String(dflt == null ? '' : dflt));
        // 注意：ExtendScript 的 prompt() 取消时返回 null，但**常常变成字符串 "null"**（老毛病）。
        // 两种都必须当取消 —— 否则点 Cancel 会把标记正文写成字面量 null（真机已踩）。
        if (v === null || v === undefined) return _err('cancelled');
        var s = String(v);
        if (s === 'null' || s === 'undefined') return _err('cancelled');
        return _ok(s.replace(/[\r\n\x1f\x1d\x1e]+/g, ' '));
    } catch (e) { return _err('smPromptText: ' + e); }
}

/* ============ 诊断：官方 API 无法定位播放头，探测 QE ============ */

function smProbeQE() {
    try {
        if (typeof app.enableQE !== 'function') return _err('app.enableQE unavailable');
        app.enableQE();
        if (typeof qe === 'undefined' || !qe) return _err('qe undefined');
        if (!qe.source) return _err('qe.source 不存在');
        if (!qe.source.player) return _err('qe.source.player 不存在');
        var p = qe.source.player;
        var need = ['startScrubbing', 'scrubTo', 'endScrubbing', 'step', 'play'];
        var got = [];
        for (var i = 0; i < need.length; i++) {
            var t = '?';
            try { t = typeof p[need[i]]; } catch (e) { t = 'ERR'; }
            got.push(need[i] + '=' + t);
        }
        return _ok(got.join(' '));
    } catch (e) { return _err('smProbeQE: ' + e); }
}

/* ====== 需求②补充：定位源监视器播放头 ======
 * 官方 API 无此能力（Adobe 的 Bruce Bullis 2020/2023 两次确认）。
 * 但 Adobe 官方 PProPanel 示例自己给出了 QE 写法：
 *   app.enableQE(); qe.source.player.startScrubbing();
 *   qe.source.player.scrubTo('00;00;00;11'); qe.source.player.endScrubbing();
 * timecode 字符串的分隔符（':' 或 ';' 丢帧）由宿主 Time 对象自己产出，避免手工格式化出错。
 */

function _qeSourcePlayer() {
    if (typeof app.enableQE !== 'function') return null;
    app.enableQE();
    if (typeof qe === 'undefined' || !qe) return null;
    if (!qe.source || !qe.source.player) return null;
    return qe.source.player;
}

/*
 * 分隔符：非丢帧工程用 ':'，丢帧工程用 ';'。Pr 没给我们现成的格式信息
 * （Time.timecode 不可用，Sequence 也没有 timeDisplayFormat），所以两种都试，
 * 并且**以读回的实际位置为准**判断是否真的跳过去了，而不是只看有没有抛异常。
 */
function smSeekSeconds(sec) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    var player = _qeSourcePlayer();
    if (!player) return _err('QE source player 不可用（官方 API 无法定位播放头）');
    var target = _num(sec, 0);
    var tried = [];
    var seps = [':', ';'];
    for (var i = 0; i < seps.length; i++) {
        var tc = _timecodeAt(item, target, seps[i]);
        try {
            player.startScrubbing();
            player.scrubTo(tc);
            player.endScrubbing();
        } catch (e) {
            tried.push(seps[i] + ' 抛错: ' + e);
            try { player.endScrubbing(); } catch (e2) {}
            continue;
        }
        var now = -1;
        try { now = _num(app.sourceMonitor.getPosition().seconds, -1); } catch (e) {}
        if (now >= 0 && Math.abs(now - target) <= 1.0) {
            return _ok('tc=' + tc, 'now=' + now.toFixed(3), 'sep=' + seps[i]);
        }
        tried.push(seps[i] + ' 未生效(now=' + (now < 0 ? '?' : now.toFixed(3)) + ')');
    }
    return _err('scrubTo 两种分隔符都未生效: ' + tried.join(' | '));
}

function smSeekToMarker(index) {
    var item = _srcItem();
    if (!item) return _err('source monitor empty');
    try {
        var col = item.getMarkers();
        var i = Number(index);
        if (isNaN(i) || i < 0 || i >= col.numMarkers) return _err('marker index out of range: ' + index);
        return smSeekSeconds(_num(col[i].start.seconds, 0));
    } catch (e) { return _err('smSeekToMarker: ' + e); }
}

/* ============ 文件对话框与读取（走 ExtendScript，兼容性最好） ============ */

/*
 * Pr 主窗口置前：ExtendScript 的文件对话框由宿主进程弹出，Pr 不在前台时可能被压在下面。
 * app.bringToFront 未见于官方文档，属于尽力而为；自检会报告它是否存在。
 */
function _focusHost() {
    try {
        if (typeof app.bringToFront === 'function') { app.bringToFront(); return true; }
    } catch (e) {}
    return false;
}

function smPickFile(kind, prompt) {
    try {
        _focusHost();
        var f = (String(kind) === 'preset')
            ? File.openDialog(prompt || '选择 AME 预设 (.epr)', '*.epr')
            : File.openDialog(prompt || '选择标记文件', '*.csv;*.tsv;*.txt;*.json;*.srt');
        return _ok(f ? f.fsName : '');
    } catch (e) { return _err('smPickFile: ' + e); }
}

function smPickFolder() {
    try {
        _focusHost();
        var f = Folder.selectDialog('选择输出目录');
        return _ok(f ? f.fsName : '');
    } catch (e) { return _err('smPickFolder: ' + e); }
}

/* 用当前序列反查预设对应的扩展名；返回值可能带点，面板侧统一去掉 */
function smExportFileExtension(presetPath) {
    try {
        var seq = app.project.activeSequence;
        if (!seq) return _ok('');
        var ext = seq.getExportFileExtension(String(presetPath));
        return _ok(ext ? String(ext) : '');
    } catch (e) { return _ok(''); }   // 拿不到不算错误，面板回退到 mp4
}

function smReadTextFile(path) {
    try {
        var f = new File(String(path));
        if (!f.exists) return _err('file not found: ' + path);
        if (f.length > 1048576) return _err('file too large (>1MB): ' + f.length + ' bytes');
        f.encoding = 'UTF-8';
        if (!f.open('r')) return _err('open failed: ' + path);
        var s = f.read();
        f.close();
        return _ok(s);
    } catch (e) { return _err('smReadTextFile: ' + e); }
}

function smProjectDir() {
    try {
        var p = app.project.path;
        return _ok(p ? String(p).replace(/[^\\\/]+$/, '') : '');
    } catch (e) { return _err('smProjectDir: ' + e); }
}

/* ============== 真机自检：一次点击验完所有依赖 API ============== */

function _try(label, fn, R) {
    try { R.push(label + ' :: ' + fn()); }
    catch (e) { R.push(label + ' :: THREW ' + e); }
}

function smSelfTest() {
    var R = [];
    R.push('=== Source Marker 自检 ' + (new Date()).toString() + ' ===');
    _try('app.version', function () { return app.version; }, R);
    _try('project', function () { return app.project ? (app.project.name || '(未命名)') : 'none'; }, R);

    var item = _srcItem();
    if (!item) {
        R.push('sourceMonitor.getProjectItem :: null   <-- 请先在源监视器打开一个片段再自检');
    } else {
        _try('sourceItem.name', function () { return item.name; }, R);
        _try('sourceItem.mediaPath', function () { return item.getMediaPath(); }, R);
        _try('getInPoint', function () {
            var t = item.getInPoint();
            return _num(t.seconds, 0) + 's / ' + t.ticks + ' ticks / Time.timecode=' +
                   (typeof t.timecode === 'undefined' ? 'undefined(改用自算)' : t.timecode) +
                   ' / 自算=' + _timecodeAt(item, _num(t.seconds, 0), ':');
        }, R);
        _try('getOutPoint', function () {
            var t = item.getOutPoint();
            return _num(t.seconds, 0) + 's / ' + t.ticks + ' ticks / Time.timecode=' +
                   (typeof t.timecode === 'undefined' ? 'undefined(改用自算)' : t.timecode) +
                   ' / 自算=' + _timecodeAt(item, _num(t.seconds, 0), ':');
        }, R);
        _try('帧率解析（时间码全靠它）', function () {
            var f = 'THREW';
            try { f = item.getFootageInterpretation().frameRate; } catch (e) { f = 'THREW ' + e; }
            return 'footageInterpretation.frameRate=' + f + ' -> _fps=' + _fps(item);
        }, R);
        _try('setInPoint 写回', function () {
            var t = item.getInPoint();
            var before = _num(t.seconds, 0);
            var ret = item.setInPoint(t, MEDIA_ALL);
            var after = _num(item.getInPoint().seconds, -1);
            return 'ret=' + ret + ' before=' + before + ' after=' + after +
                   (Math.abs(after - before) < 0.05 ? '  OK' : '  MISMATCH');
        }, R);
        _try('getMarkers', function () { return item.getMarkers().numMarkers + ' 个标记'; }, R);
        _try('标记写入回读（需求④核心）', function () {
            var col = item.getMarkers();
            var before = col.numMarkers;
            var probe = 3.0;
            var m = col.createMarker(probe);
            if (!m) return 'createMarker 返回 null';
            var landed = _num(m.start.seconds, -1);
            m.name = 'sm_probe';
            m.comments = 'source-marker self-test';
            var bn = m.name, bc = m.comments;
            var after = before;
            try { col.deleteMarker(m); after = item.getMarkers().numMarkers; } catch (e) {}
            return '请求=' + probe + 's 落点=' + landed + 's ' +
                   (Math.abs(landed - probe) < 0.05 ? 'OK' : '[MISMATCH 可能按 ticks 解释]') +
                   ' / name=' + bn + ' / comment=' + bc + ' / 数量 ' + before + '->' + after;
        }, R);
        /* 导出功能要写标记文件，而格式 v1 的 color 是必填列 —— 所以必须能"读"标记颜色。
           Marker 的写是 setColorByIndex()，但读有没有公开 API 查不到（Adobe 论坛里
           有人专门发帖问 Getting Marker Color via Script），只能真机探。
           做法是受控回读：自建一个标记、写死颜色 3、再试几种读法，最后自删。
           回报里带"可枚举方法"，万一候选名都不对我还能从方法表里找线索。 */
        _try('标记颜色读取（自建自删；决定导出能否带颜色）', function () {
            var col = item.getMarkers();
            var m = col.createMarker(5.0);
            if (!m) return 'createMarker 返回 null，无法探测';
            var wrote = '?';
            try { m.setColorByIndex(3); wrote = '已写 setColorByIndex(3)'; } catch (e) { wrote = '写入 THREW ' + e; }
            var cands = ['getColorByIndex', 'getColorIndex', 'getColor', 'colorIndex', 'color'];
            var out = [];
            for (var i = 0; i < cands.length; i++) {
                var k = cands[i], t = 'undefined', v = '-';
                try {
                    t = typeof m[k];
                    if (t === 'function') v = String(m[k]());
                    else if (t !== 'undefined') v = String(m[k]);
                } catch (e) { v = 'THREW ' + e; }
                out.push(k + ':' + t + '=' + v);
            }
            var names = [];
            try { for (var p in m) { if (typeof m[p] === 'function') names.push(p); } } catch (e) {}
            var left = -1;
            try { col.deleteMarker(m); left = item.getMarkers().numMarkers; } catch (e) {}
            return wrote + ' → ' + out.join('  ') +
                   ' ／ 可枚举方法=[' + (names.length ? names.join(',') : '宿主对象不可枚举') + ']' +
                   ' ／ 清理后标记数=' + left;
        }, R);
        /* 用户现象：点面板标记跳转后，Pr 的活动监视器仍留在「节目」，
           于是按空格播的是序列而不是源。ExtendScript 有没有"让源监视器成为活动监视器"
           的 API 查不到（Adobe 论坛有人专门问能不能设面板焦点），按本项目老办法压成一次点击。
           此处**只读**：只报 typeof，绝不调用可能产生副作用的方法（play 会真的开始播放）。 */
        _try('活动监视器 / 播放源 相关 API（决定"点标记后空格能否播源"）', function () {
            var out = [];
            var pairs = [
                ['app.sourceMonitor.play', app.sourceMonitor, 'play'],
                ['app.sourceMonitor.setPosition', app.sourceMonitor, 'setPosition'],
                ['app.sourceMonitor.open', app.sourceMonitor, 'open'],
                ['app.sourceMonitor.activate', app.sourceMonitor, 'activate'],
                ['app.sourceMonitor.setActive', app.sourceMonitor, 'setActive'],
                ['app.openInSourceMonitor', app, 'openInSourceMonitor'],
                ['app.openSourceMonitor', app, 'openSourceMonitor'],
                ['app.bringToFront', app, 'bringToFront']
            ];
            for (var i = 0; i < pairs.length; i++) {
                var t = '?';
                try { t = typeof pairs[i][1][pairs[i][2]]; } catch (e1) { t = 'THREW'; }
                out.push(pairs[i][0] + '=' + t);
            }
            try {
                out.push('qe.sourceMonitor.player.play=' + typeof qe.sourceMonitor.player.play);
                out.push('qe.sourceMonitor.setActive=' + typeof qe.sourceMonitor.setActive);
                out.push('qe.sourceMonitor.open=' + typeof qe.sourceMonitor.open);
            } catch (e2) { out.push('qe 访问失败: ' + e2); }
            return out.join('  ');
        }, R);
        _try('createSubClip 范围回读（决定导出 in/out 是否真的生效）', function () {
            var inSec = _num(item.getInPoint().seconds, 0);
            var outSec = _num(item.getOutPoint().seconds, 0);
            if (outSec - inSec < 4) { _subclipError = '素材不足 4s'; return '素材太短，跳过'; }
            // 取一段明确的内部区间：如果子剪辑实际跨越整条素材，这里立刻能被看出来
            var startSec = inSec + (outSec - inSec) * 0.25;
            var endSec = startSec + 2;
            var sub = _subclipOf(item, '__sm_selftest__', _timeAt(item, startSec), _timeAt(item, endSec), 1);
            if (!sub) return '四种变体都拿不到正确范围 :: ' + _subclipError;
            var gi = '?', go = '?';
            try { gi = _num(sub.getInPoint().seconds, -1).toFixed(3); } catch (e) {}
            try { go = _num(sub.getOutPoint().seconds, -1).toFixed(3); } catch (e) {}
            // deleteBin() 的返回值不可信（真机上对序列返回 true，而文档写"成功返回 0"），
            // 所以一律以「重新枚举后的实际残留」为准。
            var leftBefore = _findItemsNamedLike('__sm_selftest__', app.project.rootItem, 0, []).length;
            var del = _deleteItemVerified(sub, '__sm_selftest__');
            var leftAfter = _findItemsNamedLike('__sm_selftest__', app.project.rootItem, 0, []).length;
            var delRet = del.via + '(' + del.notes + ')';
            return '请求 ' + startSec.toFixed(3) + '~' + endSec.toFixed(3) +
                   ' / 变体=' + _subclipVariant + ' / 回读=' + gi + '~' + go +
                   ' / workArea=' + _workAreaName(_subclipWorkArea) +
                   ' / 本次测试项删除=' + (del.ok ? 'OK(via ' + del.via + ')' : '失败') +
                   ' / 项目树残留 ' + leftBefore + '→' + leftAfter +
                   (leftAfter === 0 ? '（已清空）'
                                    : '（含历史残留，点「清理临时对象」可清）');
        }, R);
    }

    _try('app.encoder', function () {
        return 'encodeFile=' + typeof app.encoder.encodeFile +
               ' encodeProjectItem=' + typeof app.encoder.encodeProjectItem +
               ' encodeSequence=' + typeof app.encoder.encodeSequence;
    }, R);
    _try('app.encoder workArea 常量（之前误用裸整数，是导出全长的元凶）', function () {
        var d = function (v) {
            return (typeof v === 'number' || typeof v === 'string') ? typeof v + ':' + v : typeof v;
        };
        return 'ENCODE_ENTIRE=' + d(app.encoder.ENCODE_ENTIRE) +
               ' ENCODE_IN_TO_OUT=' + d(app.encoder.ENCODE_IN_TO_OUT) +
               ' ENCODE_WORK_AREA=' + d(app.encoder.ENCODE_WORK_AREA) +
               ' -> _wa(inout)=' + d(_wa('inout'));
    }, R);
    _try('createNewSequenceFromClips（序列策略依赖）', function () {
        return typeof app.project.createNewSequenceFromClips;
    }, R);
    _try('activeSequence', function () {
        var s = app.project.activeSequence;
        return s ? (s.name + '  V轨=' + s.videoTracks.numTracks + ' A轨=' + s.audioTracks.numTracks) : 'none';
    }, R);
    _try('sequence.insertClip / Track.overwriteClip', function () {
        var s = app.project.activeSequence;
        if (!s) return 'n/a';
        return typeof s.insertClip + ' / ' + typeof s.videoTracks[0].overwriteClip;
    }, R);
    _try('sourceMonitor 可枚举方法', function () {
        var n = [];
        for (var k in app.sourceMonitor) {
            try { if (typeof app.sourceMonitor[k] === 'function') n.push(k); } catch (e) {}
        }
        return n.length ? n.join(', ') : '(宿主对象不可枚举，属正常)';
    }, R);
    _try('QE 源监视器 player（决定「跳到标记」能否用）', function () {
        if (typeof app.enableQE !== 'function') return 'app.enableQE 不可用';
        app.enableQE();
        if (typeof qe === 'undefined' || !qe) return 'qe 未定义';
        if (!qe.source) return 'qe.source 不存在';
        var p = qe.source.player;
        if (!p) return 'qe.source.player 不存在 <-- 跳到功能不可用';
        var need = ['startScrubbing', 'scrubTo', 'endScrubbing', 'step', 'play'];
        var got = [];
        for (var i = 0; i < need.length; i++) {
            var t = '?';
            try { t = typeof p[need[i]]; } catch (e) { t = 'ERR'; }
            got.push(need[i] + '=' + t);
        }
        return got.join(' ');
    }, R);
    _try('File API', function () { return typeof File.openDialog + ' / ' + typeof File.saveDialog; }, R);
    _try('app.bringToFront（文件对话框置前，尽力而为）', function () {
        return typeof app.bringToFront;
    }, R);
    _try('项目树里 __sm_selftest__ 残留（清理按钮的输入）', function () {
        return _findItemsNamedLike('__sm_selftest__', app.project.rootItem, 0, []).length + ' 个';
    }, R);
    R.push('=== 自检结束，请把以上内容整段复制回传 ===');
    return _ok(R.join('\n'));
}
