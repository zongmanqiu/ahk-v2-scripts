; ==UserScript==
; @name         防休眠
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.1
; @description  两项托盘勾选阻止系统休眠／屏幕自动关闭，直调内核唤醒 API，退出自动还原
; @author       邱宗满
; @date         2026-11-13
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        托盘菜单「阻止系统休眠」「阻止屏幕关闭」；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 防休眠：与 Caffeine 类工具同一内核原理——直接 SetThreadExecutionState 申请常驻唤醒，
; 不模拟按键、不设定时器轮询。「定时发送不可见按键」那类思路会干扰前台程序，判为伪方案，不采用。
; 本项目独立实现，未复刻任何第三方源码；许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
; 退出（含宿主停止本脚本）显式清回 ES_CONTINUOUS，把电源策略交还系统默认。
; 1.0.1 按 开发指南 §10 核对：本脚本只有托盘菜单、没有原生 GUI 窗口，§10.1 明确
; 不适用，界面零改动；托盘文案「阻止系统休眠」「阻止屏幕关闭」是四字动词短语、
; A_IconTip 用「·」连接状态事实，与 §10.6 一致，故只登记核对结论。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

ES_CONTINUOUS := 0x80000000
ES_SYSTEM_REQUIRED := 0x1
ES_DISPLAY_REQUIRED := 0x2

ITEM_SLEEP := "阻止系统休眠"
ITEM_SCREEN := "阻止屏幕关闭"

gBlockSleep := false
gBlockScreen := false

CalcFlags() {
    global ES_CONTINUOUS, ES_SYSTEM_REQUIRED, ES_DISPLAY_REQUIRED, gBlockSleep, gBlockScreen
    f := ES_CONTINUOUS
    if gBlockSleep
        f |= ES_SYSTEM_REQUIRED
    if gBlockScreen
        f |= ES_DISPLAY_REQUIRED
    return f
}

ApplyVisual() {
    global gBlockSleep, gBlockScreen, ITEM_SLEEP, ITEM_SCREEN
    if gBlockSleep
        A_TrayMenu.Check(ITEM_SLEEP)
    else
        A_TrayMenu.Uncheck(ITEM_SLEEP)
    if gBlockScreen
        A_TrayMenu.Check(ITEM_SCREEN)
    else
        A_TrayMenu.Uncheck(ITEM_SCREEN)
    s := ""
    if gBlockSleep
        s .= "系统"
    if gBlockScreen
        s .= s ? "+屏幕" : "屏幕"
    A_IconTip := s ? "防休眠 · 阻止" s : "防休眠"
}

SetBlock(kind) {
    global gBlockSleep, gBlockScreen, gLastError, ITEM_SLEEP, ITEM_SCREEN
    oldSleep := gBlockSleep
    oldScreen := gBlockScreen
    if kind = "sleep"
        gBlockSleep := !gBlockSleep
    else
        gBlockScreen := !gBlockScreen
    if !DllCall("kernel32\SetThreadExecutionState", "UInt", CalcFlags(), "Ptr") {
        gLastError := DllCall("kernel32\GetLastError", "UInt")
        gBlockSleep := oldSleep
        gBlockScreen := oldScreen
        MsgBox "SetThreadExecutionState 调用失败（错误码 " gLastError "），未启用。", "防休眠", "Iconx"
    }
    ApplyVisual()
}

; ── 无 GUI 自测：--selftest [输出路径] ───────────────────────────────
; 校验四组开关位组合的纯计算，再对真实 API 做「全开 → 清回」往返；只动本线程的执行状态，
; 结束即清回 ES_CONTINUOUS，不写注册表、不碰电源计划。

if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest-result.txt")

RunSelfTest(path) {
    global ES_CONTINUOUS, ES_SYSTEM_REQUIRED, ES_DISPLAY_REQUIRED, gBlockSleep, gBlockScreen
    out := ""
    Emit(s) => out .= s "`n"

    gBlockSleep := false, gBlockScreen := false
    Emit((CalcFlags() = ES_CONTINUOUS ? "PASS " : "FAIL ") "全关＝仅 ES_CONTINUOUS（释放信号）")
    gBlockSleep := true
    Emit((CalcFlags() = (ES_CONTINUOUS | ES_SYSTEM_REQUIRED) ? "PASS " : "FAIL ") "仅阻止休眠档位无杂位")
    gBlockSleep := false, gBlockScreen := true
    Emit((CalcFlags() = (ES_CONTINUOUS | ES_DISPLAY_REQUIRED) ? "PASS " : "FAIL ") "仅阻止息屏档位无杂位")
    gBlockSleep := true
    Emit((CalcFlags() = (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED) ? "PASS " : "FAIL ") "双开三位齐全")

    r1 := DllCall("kernel32\SetThreadExecutionState", "UInt", (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED), "Ptr")
    Emit((r1 ? "PASS " : "FAIL ") "API 双开被受理（返回 0x" Format("{:X}", r1 ? r1 : 0) "）")
    r2 := DllCall("kernel32\SetThreadExecutionState", "UInt", ES_CONTINUOUS, "Ptr")
    Emit((r2 ? "PASS " : "FAIL ") "API 清回被受理（返回 0x" Format("{:X}", r2 ? r2 : 0) "）")
    gBlockSleep := false, gBlockScreen := false

    fails := 0
    for ln in StrSplit(out, "`n")
        if (SubStr(ln, 1, 5) = "FAIL ")
            fails++
    Emit("fails=" . fails)
    ; 自测输出路径可指到任意新目录（相对路径按脚本旁解析）：先补父目录再写，避免 FileAppend 抛错卡对话框。
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

A_TrayMenu.Delete()
A_TrayMenu.Add(ITEM_SLEEP, (*) => SetBlock("sleep"))
A_TrayMenu.Add(ITEM_SCREEN, (*) => SetBlock("screen"))
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := ITEM_SLEEP
A_IconTip := "防休眠"
; 宿主会镜像托盘菜单；独立运行才显示自己的图标。
if !InStr(A_AhkPath, "AHKDeck.exe")
    A_IconHidden := false

; 入口只有托盘菜单，没有热键、没有常驻定时器、没有可见 GUI——往 A_TrayMenu 加项不算常驻理由，
; 必须显式声明常驻，否则脚本加载完最后一行就自行退出（开发指南 §4，夜灯 1.0.1 踩过）。
Persistent(true)

OnScriptExit(*) {
    global ES_CONTINUOUS
    DllCall("kernel32\SetThreadExecutionState", "UInt", ES_CONTINUOUS, "Ptr")
    return 0
}
OnExit(OnScriptExit)
