# Source Marker — Premiere Pro 源监视器增强扩展

面向「源监视器（Source Monitor）」的剪辑与交付增强面板。
调研结论见 [`research/00-survey-source-monitor-extension.md`](research/00-survey-source-monitor-extension.md)。

## 为什么是自研

- 现有扩展（Excalibur / ExportFoundry / MultiRender / Quick Export Pro / Jumper / premiere-pro-mcp…）**没有任何一个以源监视器为中心**：Excalibur 全站 162 篇文档 0 次提及 Source Monitor；导出类工具全部以序列或项目面板选中项为单位。
- 全部需求所需的 API 在 **CEP / ExtendScript** 里都存在：入出点写入有 Adobe 工程师本人的可用代码背书，
  播放头定位有 Adobe 官方示例 PProPanel 的 QE 写法可循。

## 功能

| # | 功能 | 实现 |
|---|---|---|
| ① | 一键导出源监视器入出点范围 | `encoder.encodeFile(..., inPoint, outPoint)` 或 `createSubClip + encodeProjectItem`；入队后 `encoder.startBatch()` 直接开始渲染 |
| ② | 入出点精确输入 / 微调 / 与序列互拷 / 清除 | `projectItem.getInPoint/setInPoint(t, 4)` |
| ③ | 插入 / 覆盖到序列指定轨道 | `sequence.insertClip()`、`track.overwriteClip()` |
| ④ | 外部文件（CSV/TSV/JSON/SRT）→ 源监视器剪辑标记 | `projectItem.getMarkers().createMarker(sec)` |
| ⑤ | 把播放头跳到 In / Out / 任意标记（点列表项） | `qe.source.player.scrubTo()`，写法取自 Adobe 官方 PProPanel 示例 |

轨道号与 Pr 界面一致：面板里的 **V1 / A1 就是第一条视频/音频轨**（宿主 API 是 0-based，面板负责换算）。

**导出一键化**：
- 输出目录和 `.epr` 预设**只需选一次**（存在 `localStorage`），之后每次导出直接按文件名模板生成路径；
- 扩展名由 `sequence.getExportFileExtension(preset)` 反查，不用手填（无活动序列时回退 mp4，
  也可在模板末尾直接写 `.mov` 覆盖）；
- 文件名模板支持 `{clip}` `{in}` `{out}` `{date}`，非法字符自动替换；
- 导出前**前置检查**（预设可读？输出目录可写？）——把失败原因说清楚，而不是丢一个 `job=0`；
- 入队后可自动调 `encoder.startBatch()` **让 AME 立即开始渲染**，不用切过去手动点「开始队列」。

### ⚠️ 导出排查全过程（4 次真机往返，含 2 次错误结论）

**现象**：入点 `10s` 的导出产物是 **125.675s**（完整素材），而请求范围只有 50.04s。
时长是把产物 MP4 的 `mvhd` 解析出来量的——**这是唯一算数的证据**。

**结论：`encodeProjectItem` 在 Pr 24.0 上不认子剪辑的裁剪，必须走 `encodeSequence`。**

正确做法：子剪辑 → `createNewSequenceFromClips` → `encodeSequence(seq, …, ENCODE_ENTIRE, …)`。
实测产物 **50.069s / 46.0MB**（期望 50.040s，误差 0.029s ≈ 不到一帧），文件大小从 114.8MB 降到 46.0MB。

#### 排查中犯过的两个错误（留档以免重蹈）

**错误结论 1：以为是 `createSubClip` 坏了。** 错。
自检回读显示：请求跨度 2.000s → 回读 `0.000~2.000`，**跨度完全正确**。
子剪辑的入出点本来就是"相对自身"的，我按绝对值比对才误判成失败。

**错误结论 2：以为是 `workArea` 传了裸整数。** 也错。
自检实测：`ENCODE_ENTIRE=number:0`、`ENCODE_IN_TO_OUT=number:1`、
`ENCODE_WORK_AREA=undefined` —— **它们本来就是普通数字**，`_wa()` 与直接传 `0/1` 完全等价。
换 `encodeSequence` 之后「同时」改了这两处，所以一度把功劳记在了枚举上。

> 教训：一次改两处，就无法归因。真正的定位靠的是**把中间状态读回来**
> （子剪辑范围、常量的类型），而不是靠"改完好了"。

#### 仍然成立的坑

**`createSubClip` 的入出点是相对自身的**：请求 `22.510~24.510` 回读成 `0.000~2.000`。
代码同时接受两种参照系，并据此决定 workArea：

请求 `22.510~24.510` 会回读成 `0.000~2.000`。这是正确的（跨度对得上），
但如果按"绝对值"去比对就会误判成失败。代码同时接受两种参照系，
并且**根据是哪种参照系决定 workArea**：

| 回读形态 | 含义 | workArea |
|---|---|---|
| `0 ~ 跨度` | 子剪辑媒体已被裁到范围 | `ENCODE_ENTIRE` |
| `请求in ~ 请求out` | 媒体仍是主素材 | `ENCODE_IN_TO_OUT` |

参数形式优先用 **Time 对象**（`new Time(); t.seconds = x`）——这是 Adobe 官方示例的写法；
官方文档写的 ticks 字符串作次选。范围不符的试探品立即删除，不在工程里堆垃圾。

**验证必须量产物，不能看返回值。** 上面两个错误结论之所以能存活，就是因为
「函数返回了对象、AME 返回了 job id、文件确实产出了」全都看起来正常，只有时长是错的。
导出成功时日志会回报 `workArea=…`、`子剪辑回读=…`、`sequence=…`，可以肉眼核对。

### 三种导出策略（下拉可选，默认「临时序列」）

| 策略 | 做法 | Pr 24.0 实测状态 |
|---|---|---|
| `sequence`（默认） | 子剪辑 → `createNewSequenceFromClips` → `encodeSequence(seq, …, ENCODE_ENTIRE, …)` | ✅ **可用**，实测 50.069s（期望 50.040s） |
| `subclip` | 子剪辑 → `encodeProjectItem` | ❌ 无效，导出主素材全长 125.675s |
| `file` | `encodeFile(mediaPath, …, inPoint, outPoint)` | ⚠️ 实验：传 Time 对象抛 `Illegal Parameter type`，已加四种入出点形式的梯度重试 |

三者都不依赖序列本身的入出点，不会污染你的时间线。

**`sequence` 策略会在工程里留下东西**：一个子剪辑和一个名为 `SM 00.00.10.00-00.01.00.01`
的临时序列。用 `SM ` 前缀就是为了能一眼认出并批量清理。

面板上有 **「清理「SM …」序列」** 按钮，一键删除所有 `SM ` 开头的序列（会跳过当前活动序列并说明原因，
绝不碰其它序列）。**为什么不能导出后自动删**：AME 渲染期间必须能读到该序列，
而 ExtendScript 没有渲染完成回调——删早了渲染就失败。所以只能手动触发，
建议等 AME 队列跑完再点。

## 配套：播放器端标记插件（mpv）

在播放器里边看边打标记，再导入到 Pr —— 见 [`player-plugin/README.md`](player-plugin/README.md)。

- 宿主选型结论：**mpv**（唯一有用户级插件 API 的候选；PotPlayer 闭源无插件接口，
  MPC-BE/MPC-HC 无插件 SDK 只能做外部伴随程序）。完整取证见
  [`research/01-playback-marker-plugin-selection.md`](research/01-playback-marker-plugin-selection.md)。
- 已装在本机：`D:\Tools\mpv`（官方 mpv 0.41.0 便携版）+ `portable_config\scripts\source-markers.lua`；
  用 `Ctrl+m` 在播放头打标记、`Alt+m` 写描述、`Ctrl+1..8` 换颜色、`Ctrl+l` 看列表、`Ctrl+e` 导出。
- 导出的 CSV 就是本扩展能直接导入的格式（`time,name,comment,color`，颜色为 Pr 标记色索引）。
- 全部离线测试：`powershell -NoProfile -ExecutionPolicy Bypass -File run-all-tests.ps1`
  （读取方契约 28 项 + 写入方一致性 ms/ff 各 24 项 + 健壮性 15 项 + 29.97fps 漂移回归 11 项）。

## 安装（Windows）

**双击 `install.cmd`** 即可（推荐）——它会绕过执行策略并在结束时暂停，错误不会被窗口一闪吞掉。

或在 PowerShell 里：

```powershell
.\install.ps1              # 系统级安装（默认，自动请求提权）
.\install.ps1 -User        # 只给当前用户装（不需要管理员）
.\install.ps1 -DryRun      # 只打印将要做什么，不改动任何东西
.\install.ps1 -Uninstall   # 卸载（两个位置都清）
```

安装位置：

| 范围 | 路径 |
|---|---|
| 系统级（默认） | `C:\Program Files\Common Files\Adobe\CEP\extensions\com.frisk.sourcemarker` |
| 用户级（`-User`） | `%APPDATA%\Adobe\CEP\extensions\com.frisk.sourcemarker` |

**为什么默认系统级**：本机实测（Pr 24.0.0）用户级目录从未被创建过，而系统级目录里的扩展能被正常识别。
两个位置 CEP 都会扫描，但用户级要求该目录在 Premiere 启动前就已存在——首次安装时最容易踩这个坑。

注册表只写 **HKCU**（`HKCU\Software\Adobe\CSXS.9 ~ CSXS.13` 的 `PlayerDebugMode` = 字符串 `1`）。
本机可用配置实测为 `CSXS.11 = 1`，系统级扩展同样读 HKCU，**不需要 HKLM、也不需要为注册表提权**。

装完**完全退出**并重启 Premiere Pro → `窗口 > 扩展 > Source Marker`。

安装脚本自带校验：比对已装副本与仓库版本逐文件 MD5，并检查没有嵌套成 `目标\extension\`。
没通过会明确报出来。

### ⚠️ 每次改完扩展都要重装

CEP 加载的是**安装目录里的那份**，不是仓库里的。改完代码忘记重装，跑的还是旧版本
（本机就发生过：已装副本缺 `buildImportPayload` / `smPreflight` / `smStartBatch`，却完全没有提示）。
`install.ps1` 的逐文件 MD5 校验就是为了把这件事暴露出来。

### ⚠️ 改 `install.ps1` 后必须确认它带 UTF-8 BOM

Windows PowerShell 5.1 对**无 BOM** 的 `.ps1` 按 ANSI（中文系统是 CP936）解码，中文串会被拆坏成
语法错误，**整份脚本跑不起来**，而报错本身也是乱码、看不出原因。这个坑本项目踩过一次。
仓库里 `tools/ensure-ps1-bom.ps1` 可做全仓自检与补写，`run-all-tests.ps1` 第一步就会跑它。
`.cmd` 文件则相反，**不能**带 BOM。

## 标记文件格式

**格式已冻结为 v1，规范见 [`docs/marker-format.md`](docs/marker-format.md)**（含 JSON Schema
[`docs/marker-format.schema.json`](docs/marker-format.schema.json)）。要点：

- **CSV（规范、Pr 面板直接导入）**：UTF-8（写入方带 BOM，读取方必须容忍）+ CRLF，表头固定四列
  `time,name,comment,color`；时间默认写**毫秒** `HH:MM:SS.mmm`（与帧率无关，跨机器不会偏移），
  需要 `HH:MM:SS:FF` 时可显式开启；`color` 是 Pr 标记色索引 `0..7`。
- **JSON（无损）**：`{format, version, created, source:{file,fps,durationSec}, markers:[{time,tc,name,comment,color}]}`；
  `time`（秒）是权威值，`tc` 只是展示用；读取方忽略未知字段。

导入侧（本扩展）按下列规则解析，四种都支持：

- **CSV / TSV**：首行若为表头则按名字映射列（`time/tc/timecode/start/时间码`、`name/title/名称`、`comment/desc/content/内容/备注`、`color/颜色`）；无表头则按 `时间, 名称, 内容, 颜色` 顺序取列。
- **JSON**：`[{time, name, comment, color}, ...]`，或 `{markers:[...]}` / `{data:[...]}`。
- **SRT**：取每条字幕的起始时间，字幕文本作为标记注释。

时间格式：`HH:MM:SS:FF`（帧）、`HH:MM:SS.mmm`、`MM:SS`、纯秒数。
`HH:MM:SS:FF` 的帧率取自当前源片段（`footageInterpretation.frameRate`）。

### 标记命名规则（按实际使用反馈定）

播放器自动生成的名字（`M01`、`M02`…）没有信息量，所以导入时**不是照搬**：

| 文件里的字段 | 落到 Pr 标记的 |
|---|---|
| `comment` / `内容`（非空） | **标记名**（列表和 OSD 上看到的就是它） |
| `name` 且形如 `M01` | **丢弃** |
| `name` 且是用户自己填的 | 移到标记的**注释**里保留（不丢信息） |
| `comment` 为空 | 用 `name` 当标记名 |

实测：`{"name":"M01","comment":"Test"}` → 标记名 `Test`；
`{"name":"开场","comment":"注意曝光"}` → 标记名 `注意曝光`，注释 `开场`。

## 首次使用：先跑一次自检

1. 在源监视器里打开任意一个片段；
2. 点面板里的 **「自检」**；
3. 点 **「复制全部」**，把日志整段回传。

自检会逐项探测本机环境并把结果打出来，覆盖：

- `app.version` / 项目 / 源片段名称与媒体路径
- `getInPoint` / `getOutPoint` 的 seconds、ticks、timecode 三种表示
- **`setInPoint` 写回校验**（写入后读回比对，输出 `OK` 或 `MISMATCH`）
- **`createSubClip` 两种参数变体**（ticks 字符串 / Time 对象）哪个生效
- `app.encoder` 三个方法是否存在
- 序列、`insertClip`、`Track.overwriteClip` 是否可用
- **`qe.source.player` 的 5 个方法**（`startScrubbing` / `scrubTo` / `endScrubbing` / `step` / `play`）是否存在——决定「跳到」能否用

自检会临时建一个名为 `__sm_selftest__` 的子剪辑然后删除，不影响你的工程内容。

`createSubClip` 在正式导出/发送时也会**自动按这个顺序试两种变体**，所以即使某个 Pr 版本只认其中一种，功能也不会断。

## 已知限制（重要）

1. **移动播放头走的是 QE（非公开 API）**。官方 API 确实不支持——Bruce Bullis 2020/2023 两次确认。
   但 Adobe **自己的官方示例 PProPanel** 里就用 `qe.source.player.startScrubbing()/scrubTo()/endScrubbing()`
   实现源监视器定位，本扩展直接沿用该写法。风险：QE 不受官方兼容性承诺保护，
   所以自检里专门探测 `qe.source.player` 的 5 个方法是否存在，不存在时「跳到」会明确报错而不是静默失败。
   注意：**写入入出点不受此限制**，`projectItem.setInPoint()` 是官方支持的。
2. **导出依赖 Adobe Media Encoder**，且必须提供磁盘上的 `.epr` 预设文件。
3. `subclip` 导出策略会在项目里留下一个子剪辑——AME 渲染期间不能删除它。
4. 标记同时会出现在项目面板的该素材上（这就是「剪辑标记」的存储方式，源监视器显示的就是它）。

## 目录

```
extension/
  CSXS/manifest.xml        CEP 清单（PPRO 13.0+ / CSXS 7.0+）
  client/index.html        面板 UI
  client/main.js           面板逻辑：桥接、时间码、CSV/JSON/SRT 解析、设置持久化、路径模板
  client/CSInterface.js    Adobe 官方 CEP 接口库
  host/hostscript.jsx      ExtendScript 宿主，17 个函数（ES3 安全）
  .debug                   远程调试端口配置
install.ps1                安装 / 卸载（CEP 面板；文件须保持 UTF-8 BOM）
run-all-tests.ps1          一把跑完全部离线测试
docs/
  marker-format.md         标记交换格式 v1 规范（播放器侧与面板侧的共同契约）
  marker-format.schema.json 该格式 JSON 载体的 JSON Schema
player-plugin/             播放器端标记插件（mpv + Lua，单文件）
  source-markers.lua       插件本体
  install.ps1              安装到 mpv（便携目录或 %APPDATA%\mpv）
  input.conf.example       改键位样板
  open-with-mpv.cmd        拖拽文件即可用 mpv 打开
  test/driver.lua          端到端测试驱动器（ms/ff 两种模式）
  test/driver-ntsc.lua     29.97fps 漂移回归驱动器
  test/driver-robust.lua   坏 JSON / 坏 sidecar 健壮性驱动器
  test/run-test.ps1        写入方一致性测试
  test/run-ntsc-test.ps1   帧率漂移回归
  test/run-robust-test.ps1 健壮性回归
  docs/osd-list.png        标记列表实拍
tools/
  pr-parser.js             加载 Pr 扩展「真实的」标记解析函数（供测试复用）
  verify-import.js         读取方契约测试（21 项）
  verify-plugin.js         插件产物一致性测试（ms/ff 各 24 项）
  verify-ntsc.js           29.97fps 时间码往返回归
  ensure-ps1-bom.ps1       给所有 .ps1 补 UTF-8 BOM（PS 5.1 中文脚本必需）
  fetch-mpv.py             下载官方 mpv 便携版
research/                  调研证据与结论
verify/                    独立对抗式验证的脚本与报告（REPORT.md）
```

## 实机验证结果（Premiere Pro 24.0.0 / Windows）

**五项需求全部在真机上跑通**，每条都有实测证据而不是"应该可以"：

| 能力 | 实测证据 |
|---|---|
| ① 一键导出源监视器入出点范围 | 请求 `10.000~60.040`（跨度 50.040s）→ 产物 **50.069s**，文件 114.8MB → 46.0MB（用 MP4 `mvhd` 量的时长，误差 0.029s ≈ 不到一帧） |
| ② 入出点精确编辑 | `setInPoint` 写回 `after=10.48` 与请求一致 |
| ② 跳到 In / Out / 标记 | QE `scrubTo` 实测 `tc=00:02:05:16 \| now=125.640`，精确吻合 |
| ③ 插入 / 覆盖到指定轨道 | 真机确认轨道对应正确（`mode=insert/overwrite \| v=1 \| a=1`） |
| ④ 外部文件 → 源监视器标记 | 导入 mpv 导出的 CSV：`added=2 \| failed=0 \| now=2`，命名规则符合预期 |
| 临时对象清理 | `序列: 仍残留=0 \| 测试项: 仍残留=0`（删完重新枚举核实，不是看返回值） |
| 文件对话框 | `对话框: CEP → …csv`（CEP 对话框正常出现在最前） |

另有两条用真实数值验算过：`createMarker(3.0)` 落点精确为 `3s`（**确认按「秒」而非 ticks 解释**，
猜错的话标记会全部堆到 0 秒且不报错）；时间码 `10.48s → 00:00:10:12`、`42.76s → 00:00:42:19`。

### 被真机推翻的 5 个假设（本项目最有价值的部分）

这 5 条**没有一条能从文档里读出来**，也无法在没装 Premiere 的机器上发现：

| # | 文档 / 推断 | 真机实测 |
|---|---|---|
| 1 | `Time.timecode` 可直接生成时间码 | **该属性不存在**（`undefined`）→ 改为自算，且刻意绕开 `ticks` |
| 2 | `setInPoint()` 可用返回值判断成败 | 返回 `null` 但写入成功 → 改为读回校验 |
| 3 | `encodeProjectItem` 能按子剪辑的范围导出 | 无论 `workArea` 传什么都是**主素材全长** → 必须走 `encodeSequence` |
| 4 | `ProjectItem.deleteBin()` 能删除对象 | 对序列和项目项**都返回 `true` 却什么都不删** → 序列改用 `Project.deleteSequence()`，项目项走「移进临时 bin 再删 bin」 |
| 5 | `app.bringToFront()` 能把对话框置前 | **该方法不存在**（`undefined`）→ 改用 CEP 自己的对话框 |

**共同规律：ExtendScript 的返回值普遍不可信**（`null`、`true`、文档承诺的 `0` 三者都对不上）。
所以凡是"某个 API 帮我做成了某事"的地方，最终都改成**做完之后把状态读回来核实**——
导出的时长要去量产物文件，删除要重新枚举项目树，写入要读回比对。

## 离线自动验证

无 Premiere 环境下能自动验的都验了：

- 面板 JS 与宿主 JSX 语法检查通过；宿主脚本确认 ES3 安全（无 `map/filter/JSON/let/const`）
- 面板引用的 39 个 DOM id 与 17 个宿主函数**静态交叉引用一致**
- **宿主逻辑单元测试**：用 mock Premiere 环境跑真实代码路径——时间码换算（喂入自检实测的
  125.64s / 31914570240000 ticks）、`smGetState` 字段布局、`smSeekSeconds` 正常/回退/假成功三种分支、
  `smImportMarkers` 导入与清空、`smSelfTest` 全项无异常
- **16 万组帧号合法性属性测试**（8 种帧率 × 2 万组）
- 标记解析器 10 个用例全通过（CSV 带/无表头、分号分隔、中文表头、引号内逗号、纯秒数、`MM:SS`、JSON 两种包裹、SRT）
- **时间码属性测试**：8 种帧率 × 5000 组随机秒数，帧号恒合法（此测试抓到并修掉了一个浮点边界 bug——
  原实现会产出 `00:00:01:25` 这种 25fps 下不存在的帧号）
- **输出路径拼装**：Windows/POSIX 分隔符、尾部斜杠、`{clip}{in}{out}{date}` 变量、非法字符替换
- **设置持久化**：写入→读回→回填界面 全链路
- 标记列表 RS/GS 结构化解析与渲染

仍需真机验证的项，全部收敛到「自检」按钮里。
