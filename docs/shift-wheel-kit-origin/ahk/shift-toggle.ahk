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