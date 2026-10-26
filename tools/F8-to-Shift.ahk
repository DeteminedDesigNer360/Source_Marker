; ⚠ 本机实测（2026-10-25）：AHK 运行期间 Pr 收不到鼠标点击（gui_click 全失效），杀掉 AHK 立即恢复。用完立即杀。
; ⚠ 启动前先停干净旧实例：#SingleInstance Force 按脚本路径判重，同名不同路径会并存，F8 被两个实例同时翻转。
#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 2

shiftHeld := false

*F8:: {
    global shiftHeld
    shiftHeld := !shiftHeld
    if (shiftHeld) {
        Send("{Shift down}")
        ToolTip("Shift 已按住")
    } else {
        Send("{Shift up}")
        ToolTip("Shift 已松开")
    }
    SetTimer(() => ToolTip(), -1000)
}

OnExit((*) => (shiftHeld && Send("{Shift up}"), 0))