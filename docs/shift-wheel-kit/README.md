# shift-wheel-kit — 滚轮 + Shift 注入工具箱

在 Windows 上给 DSH 会话用的一套「按住 Shift 滚轮横向平移」配方，靶应用为 Adobe Premiere Pro，也适用于任何接受滚轮的窗口。

## 文件

| 文件 | 说明 |
|---|---|
| `run-shift-scroll.ps1` | 一键编排：起 AHK → 注入 F8（按住 Shift）→ 前置目标窗口 → 滚 N 格 → 松开 Shift → 关闭 AHK → 校验 |
| `ahk\shift-toggle.ahk` | AHK v2 脚本，`*F8` 切换全局 Shift 按下/松开，带 ToolTip 与退出清理 |
| `fg-fast.ps1` | 按 pid 反查主窗口并抢前台（SC_RESTORE + AttachThreadInput + SetWindowPos） |
| `DSH-滚轮与Shift注入指南.md` | 完整原理、两条注入通道、九条坑、验证清单、故障排查表 |
| `滚轮注入结论.md` | 早期精简结论（1 格 = 3 行等实测数据） |

## 快速开始

```powershell
# 1. 找到目标进程 id（进程名带空格，用通配）
Get-Process | Where-Object { $_.ProcessName -like '*Premiere*' }   # 受限环境下可能查不到，见下

# 2. 跑一次：向上滚 10 格（Shift 按住 → 横向平移）
.\run-shift-scroll.ps1 -TargetPid 15604 -X 694 -Y 694 -Notches 10

# 3. 只想验证注入链路、不想关 AHK
.\run-shift-scroll.ps1 -TargetPid 15604 -Notches 3 -KeepAhk
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-AhkExe` | 自动探测 | AutoHotkey64.exe 路径 |
| `-AhkScript` | `ahk\shift-toggle.ahk` | 要加载的 AHK 脚本 |
| `-TargetPid` | 0（自动找 Premiere） | 目标进程 id |
| `-X -Y` | 694, 694 | 滚轮落点（屏幕坐标） |
| `-Notches` | 10 | 滚动格数；**插件通道上限 20**，本脚本逐格发送可超过 |
| `-IntervalMs` | 1000 | 每格间隔；低于此值容易被应用吞掉 |
| `-Direction` | up | up / down / left / right |
| `-Restart` | off | 先杀掉已存在的 AHK 再启动（避免双实例抢 F8） |
| `-KeepAhk` | off | 结束时保留 AHK 进程 |

## 重要限制

1. **必须 danger-full-access**。workspace-write 受限令牌下 SendInput 会被 UIPI 静默丢弃（连普通滚轮都不生效），而脚本日志仍可能打 PASS——因为它只校验进程与按键状态。降权环境请改用插件通道 `gui_scroll` + `gui_key`。
2. **滚轮消息只送给前台窗口**，与光标位置无关，所以脚本会先抢前台并校验 `GetForegroundWindow()==hwnd`。
3. **进程发现别只用 `Get-Process`**：受限环境下全枚举可能只返回二十几个进程。本脚本回退到窗口标题反查（`EnumWindows` + `GetWindowText`）。`Get-CimInstance Win32_Process` 在本机会报「无法从客户端中访问 CIM 资源」，勿用。
4. **不要用 Alt 键解锁前台**：`Alt+Shift` 会切输入法，破坏按住中的 Shift。
5. **脚本异常退出可能遗留 AHK**（F8 卡住 → Shift 卡住）。手动清场：
   ```powershell
   Get-Process | Where-Object { $_.ProcessName -like '*utoHotkey*' } | Stop-Process -Force
   ```
   然后确认 `[WheeLShift]::GetAsyncKeyState(0x10)` 为 0，必要时补发一次 VARIANT of Shift keyup。

## 前置条件

- AutoHotkey **v2**（v1 脚本语法不同）
- PowerShell 5.1 或 7（脚本用 C# 内联 P/Invoke，无需额外模块）
- 目标应用窗口不能最小化

## 换成别的应用

改 `-TargetPid` 和 `-X -Y` 即可。判据是「该应用接受 Shift 修饰键 + 滚轮」；不接受 Shift 的应用会退化成普通滚动——先跑 `-Notches 3` 小步验证，别一上来 20 格。

详见 `DSH-滚轮与Shift注入指南.md`。
