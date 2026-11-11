; ==UserScript==
; @name         双击防抖
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.0
; @description  用低级鼠标钩子拦截间隔过短的左键双击，间隔可在托盘设置（10~500 ms）
; @author       邱宗满
; @date         2026-11-11
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        托盘菜单「设置」；配置存于脚本旁同名 .ini
; ==/UserScript==
;
; 许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
; 曾用名「鼠标左键双击最小间隔」（1.0.0 起改现名，行为不变）。
; 低级鼠标钩子（WH_MOUSE_LL）吞掉间隔过短的左键双击，抑制误触连点；带注入标记的事件不拦截。
; 配置存于脚本旁同名 双击防抖.ini；退出卸钩，钩子安装失败弹窗报错并退出，不静默失效。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

gIni := A_ScriptDir "\双击防抖.ini"
gInterval := Integer(IniRead(gIni, "Settings", "Interval", 50))
gLast := 0
gBlocked := false

MouseProc(nCode, wParam, lParam) {
    global gInterval, gLast, gBlocked
    if nCode >= 0 && (wParam = 0x0201 || wParam = 0x0202) {
        if wParam = 0x0202 {
            if gBlocked {
                gBlocked := false
                return 1
            }
        } else if !(NumGet(lParam, 12, "UInt") & 0x03) {
            now := A_TickCount
            diff := now - gLast
            if diff < 0
                diff += 4294967296
            if gLast && diff < gInterval {
                gLast := now
                gBlocked := true
                return 1
            }
            gLast := now
        }
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

gCb := CallbackCreate(MouseProc, "F", 3)
gHook := DllCall("SetWindowsHookEx", "Int", 14, "Ptr", gCb, "Ptr", 0, "UInt", 0, "Ptr")
if !gHook {
    MsgBox "鼠标钩子安装失败，错误码 " A_LastError, "双击防抖", "Iconx"
    ExitApp
}
OnExit OnScriptExit

OnScriptExit(*) {
    DllCall("UnhookWindowsHookEx", "Ptr", gHook)
    return 0
}
SetTimer KeepAlive, 5000

KeepAlive() {
}

ShowSettings() {
    global gInterval, gIni
    g := Gui(, "双击防抖")
    g.SetFont("s10", "Microsoft YaHei UI")
    g.MarginX := 14, g.MarginY := 14
    g.OnEvent("Close", (*) => g.Destroy())
    g.Add("Text",, "连击最小间隔（ms）：")
    ed := g.Add("Edit", "w120", gInterval)
    g.Add("Button", "xm y+14 w90 Default", "保存").OnEvent("Click", (*) => SaveSettings(g, ed))
    g.Add("Button", "x+12 w90", "取消").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}

SaveSettings(g, ed) {
    global gInterval, gIni
    v := Integer(ed.Value)
    if v < 10 || v > 500 {
        MsgBox "请输入 10~500 之间的毫秒数。", "设置", "Iconx T1.5"
        return
    }
    gInterval := v
    IniWrite v, gIni, "Settings", "Interval"
    g.Destroy()
}

A_TrayMenu.Delete()
A_TrayMenu.Add("设置", (*) => ShowSettings())
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "设置"
A_IconTip := "双击防抖"
; 宿主会镜像托盘菜单；独立运行才显示自己的图标。
if !InStr(A_AhkPath, "AHKDeck.exe")
    A_IconHidden := false
