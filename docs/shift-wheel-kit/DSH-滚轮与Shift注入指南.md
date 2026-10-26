# DSH 里如何注入滚轮与 Shift（实战结论）

适用：dsh-guikit 0.6.2 + AHK v2.0.31 + PowerShell 7，靶机 Win11。
验证靶：Adobe Premiere Pro（时间线横向平移）、记事本（纵向滚动）。

## 一、速查表

| 需求 | 可行做法 | 结果 |
|---|---|---|
| 普通滚轮 | 插件 `gui_scroll` | ✅ 任何权限下都有效 |
| 滚轮 + 横滚 | `direction:left/right`（HWHEEL） | ✅ 需真实支持横滚的控件 |
| 按住 Shift 再滚 | `gui_key` 注入 F8 → AHK 热键 `Send("{Shift down}")` | ✅ 唯一可靠路径 |
| 按住 Shift 再滚 | 外部 `SendInput`/`keybd_event` 直接按 Shift | ❌ Premiere 不认 |
| 一条命令跑全程 | pwsh 自包含脚本（SendInput） | ⚠️ 仅 danger-full-access 有效 |

## 二、通道 A：插件注入（首选）

```
gui_scroll { x:694, y:694, direction:"up|down|left|right", notches:1 }
gui_key    { keys:"F8" }
```

事实（源码 `dsh-guikit/lib/index.js`:123-130 `ScrollAt`）：
- 1 notch = 1 条 `WM_MOUSEWHEEL`，`delta=-120`(down)/`+120`(up)，格间 `sleep 60`
- 执行序列：`SetCursorPos` → `sleep 140` → 每格 `SendInput`
- schema 在 `lib/index.js:795-811`，**notches 被 clamp 到 1..20**（传 50 也只发 20 条）
- 回执只有 `result:"ok" + delivery{sent:true, verified:false}`，**ok 仅表示事件送到 OS**

## 三、核心难点：插件没有「按住修饰键」能力

`gui_key` 只接受一个 `keys` 参数（`lib/index.js:779-792`），内部 `parseKeySpec`(202-220) + `TapKeys`(138) 是 down+up 一把梭；`gui_click/gui_drag/gui_type` 均无 modifier 参数。因此 Shift 只能从插件外建立。

**不要**用 `SendInput(VK_SHIFT)` / `keybd_event` 直接按：实测全局 `GetAsyncKeyState(0x10)` 已变 True，Premiere 侧依然毫无反应。

**可行做法**——AHK 脚本内的 `Send`：

```autohotkey
#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 2
shiftHeld := false
*F8:: {
    global shiftHeld
    shiftHeld := !shiftHeld
    if (shiftHeld)
        Send("{Shift down}")
    else
        Send("{Shift up}")
    ToolTip(shiftHeld ? "Shift 已按住" : "Shift 已松开")
    SetTimer(() => ToolTip(), -1000)
}
OnExit((*) => (shiftHeld && Send("{Shift up}"), 0))
```

关键事实：**AHK 的键盘钩子会接住其他进程用 `SendInput` 注入的 F8**，所以 `gui_key keys:"F8"` 能程序化翻转 Shift。AHK 热键线程里发出的 `Send("{Shift down}")` 对 Premiere 有效，纯外部注入无效——差异就在这一层。

## 四、完整流程（插件版）

```
1. 启动 AHK 脚本并确认常驻
2. gui_key keys="F8"          # Shift 按住
3. 目标窗口前置（见第五节）
4. gui_scroll × N，notches=1，间隔 1s
5. gui_key keys="F8"          # Shift 松开
6. 校验 GetAsyncKeyState(0x10)==0 且 AHK 进程已退出
```

## 五、前置窗口（必做，滚轮只投给前台）

滚轮消息**只送给当前前台窗口，与光标位置无关**：光标压在探针窗口上、记事本在前台时，滚轮全部滚到记事本。所以注入前必须把目标切到前台。

最小可靠做法（pwsh + P/Invoke）：
1. 最小化则 `SendMessage(hwnd, WM_SYSCOMMAND 0x0112, SC_RESTORE 0xF120, 0)`，等 0.8s
   （`IsIconic=True` 时窗口矩形常在 `-18286,-18286,-18228,-18260` 这种离屏位置）
2. `AttachThreadInput(me, fgThread, true)` → `SetWindowPos TOPMOST` → `NOTOPMOST` → `BringWindowToTop` → `SetForegroundWindow` → 卸 Attach
3. 最多重试 5 次，每次间隔 250ms，最后用 `GetForegroundWindow()==hwnd` 判定

**不要用 Alt 键解锁前台**：`Alt+Shift` 会切输入法，若用户正按住 Shift 就被毁掉。

## 六、通道 B：自包含 pwsh 脚本（需完整权限）

见工作区 `run-shift-scroll.ps1`（参数：`-TargetPid -X -Y -Notches -IntervalMs -Direction -Restart -KeepAhk`）。要点：

```csharp
// INPUT 结构 x64 = 40 字节：type(4)+pad(4)+union(32)
[StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] MOUSEINPUT mi; [FieldOffset(0)] KEYBDINPUT ki; }
SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
// 滚轮   : type=0, mi.dwFlags=0x0800(WHEEL) / 0x1000(HWHEEL), mi.mouseData=±120
// 按键   : type=1, ki.wVk=0x77(F8), ki.dwFlags=0x0002(KEYUP)
```

## 七、限制与坑（按踩坑顺序）

1. **降权沙箱下自包含注入静默失效**。`workspace-write` 下 pwsh 跑受限令牌：`Get-Process` 全枚举只剩 23 个进程，注入 F8/滚轮后目标窗口毫无反应（日志仍会打 PASS，因为它只校验进程与按键状态）。同样脚本在 `danger-full-access` 下 PASS。→ 要自包含脚本就必须完整权限；降权环境请走插件通道。
2. **进程发现不要只靠 `Get-Process | Where-Object`**。受限环境下会漏判（`*Premiere*` 匹配 0）。改用窗口标题反查：`EnumWindows` + `GetWindowText` 含关键字 → `GetWindowThreadProcessId` 得 pid。`Get-Process -Id <已知pid>` 在受限下仍可读。
3. **`Get-CimInstance Win32_Process` 不可靠**：本机会报 `无法从客户端中访问 CIM 资源`，返回空集导致把「进程存在」误判成「不存在」。
4. **hwnd 会失效**：应用重启后旧句柄 `IsWindow=False`、rect 全 0。用 pid 反查，别缓存 hwnd。
5. **进程名带空格**：`Get-Process Premiere*` 匹配不到，实际名是 `Adobe Premiere Pro`；用通配 `*Premiere*` 才命中。
6. **notches 上限 20**；且**上一动作未停稳就滚会被吞**（`ctrl+home` 后 500ms 立刻滚完全没动，等 1.5s 再滚就精确）。实测逐格起点间隔 ≈1.85s（1s 等待 + 0.85s 工具往返）。
7. **AHK ToolTip 抓不到**：`tooltips_class32` 自绘、`GetWindowText` 返回空，`SetTimer -1000` 又只显示 1 秒，不能作验证手段。判据只有 `GetAsyncKeyState` 与画面。
8. **`gui_key` 对 Win11 记事本无效**（Shift 按住时发 `a` 既无 A 也无 a）；纯文本输入请用 `gui_type`（Unicode 注入，可靠）。
9. **Shift 卡死风险**：脚本必须写 `OnExit` 释放；每轮结束复核 `GetAsyncKeyState(0x10)==0`、`0xA0`、`0xA1`。

## 八、AHK 生命周期管理

```powershell
# 启动 + 检测（差集法，183ms 内命中）
$before = @(Get-Process | ? ProcessName -like '*utoHotkey*' | % Id)
Start-Process 'C:Program FilesAutoHotkey2AutoHotkey64.exe' -ArgumentList '"脚本.ahk"'
# 轮询 Get-Process，取 $before 里没有的新 pid（最长 8s）

# 关闭
Get-Process | ? ProcessName -like '*utoHotkey*' | Stop-Process -Force
```

- `Start-Process` 启动的 AHK **不会被后台 job 回收**，可长期常驻
- `#SingleInstance Force` 按脚本路径判重，同名不同路径的脚本可并存 → 测试前先停干净，否则 F8 被两个实例同时翻转
- 脚本异常退出会遗留 AHK，用 `trap { Stop-Ahk; break }` 兜底

## 九、验证清单

1. `isFg=True` 且 rect 正常（非负离屏值）
2. 10 格滚动期间前台未变
3. 结束后 `GetAsyncKeyState(0x10/0xA0/0xA1)==0`
4. AHK 进程数 = 0（设置成收尾关闭时）
5. 画面确实是横向平移而非纵向滚动（前四条全过也可能画面不对）

## 十、故障排查

| 现象 | 排查 |
|---|---|
| 切到目标后什么都没发生 | 是否在 workspace-write 沙箱下跑自包含脚本 → 换 danger-full-access 或走插件通道 |
| 按 F8 无任何反应、无悬浮框 | AHK 进程是否真的存在（用 `Get-Process`，别用 CIM）；是否被两个实例抢 |
| 滚轮没动 | 目标是否在前台；notches 是否超 20；上一动作是否未停稳 |
| 动了但方向不对 | 是纵向滚动 → Shift 没按住，检查 F8 是否命中热键 |
| 悬挂 Shift | `GetAsyncKeyState(0x10)` 非 0 → 手动 `keybd_event(0x10,...,KEYUP)` 清场 |
