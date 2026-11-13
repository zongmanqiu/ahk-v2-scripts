; ==UserScript==
; @name         双击防抖
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.2.0
; @description  用低级鼠标钩子分别拦截左键、右键、中键间隔过短的连击，各键最小间隔可在托盘设置（0 关闭，10~500 ms）
; @author       邱宗满
; @date         2026-11-13
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        托盘菜单「设置」；配置存于脚本旁同名 .ini
; ==/UserScript==
;
; 许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
; 曾用名「鼠标左键双击最小间隔」（1.0.0 起改现名，行为不变）。
; 低级鼠标钩子（WH_MOUSE_LL）吞掉间隔过短的按下及其抬起，抑制误触连点；带注入标记的事件不拦截。
; 配置存于脚本旁同名 双击防抖.ini；退出卸钩，钩子安装失败弹窗报错并退出，不静默失效。
; 1.1.0 按 开发指南 §10 统一设置框；随系统 Button 一起去掉 Default，回车不再提交，改由点击「保存」。
; 1.2.0 把「只管左键」改成一套通用函数 + 键位/间隔参数表：左/右/中键各自独立计时与拦截，
; 窗口里可分别设定。名字与文件名保持不变，是为了不破坏 .ini 路径、分发清单与宿主镜像菜单；
; 名实不符由描述与界面逐键标注来消除，而不是靠改名。0 表示该键关闭，10~500 ms 为启用范围。
; 旧 ini 的 Settings.Interval 在首次启动时迁移到 Left，右键/中键默认关闭，行为与 1.1.0 一致。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

gIni := A_ScriptDir "\双击防抖.ini"
gKeys := [
    { name: "左键", ini: "Left",   down: 0x0201, up: 0x0202, interval: 50, last: 0, blocked: false },
    { name: "右键", ini: "Right",  down: 0x0204, up: 0x0205, interval: 0,  last: 0, blocked: false },
    { name: "中键", ini: "Middle", down: 0x0207, up: 0x0208, interval: 0,  last: 0, blocked: false }
]
LoadConfig()

; 一套逻辑、三份参数：按下间隔不够就吞掉这次按下，并连带吞掉它对应的抬起，
; 以免系统收到「抬起却没有按下」的孤立事件。三键各自记 last / blocked，互不串味。
MouseProc(nCode, wParam, lParam) {
    global gKeys
    if (nCode >= 0) {
        for k in gKeys {
            if (wParam != k.down && wParam != k.up)
                continue
            if (k.interval <= 0 || (NumGet(lParam, 12, "UInt") & 0x03))
                break
            if (wParam = k.up) {
                if k.blocked {
                    k.blocked := false
                    return 1
                }
                break
            }
            now := A_TickCount
            diff := now - k.last
            if diff < 0
                diff += 4294967296
            if (k.last && diff < k.interval) {
                k.last := now
                k.blocked := true
                return 1
            }
            k.last := now
            break
        }
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

LoadConfig() {
    global gIni, gKeys
    legacy := IniRead(gIni, "Settings", "Interval", "")
    for k in gKeys {
        v := IniRead(gIni, "Settings", k.ini, "")
        if (v = "")
            v := (k.ini = "Left" && legacy != "") ? legacy : (k.ini = "Left" ? "50" : "0")
        k.interval := Integer(v)
    }
    ; 只迁移一次：写齐三个新键后删掉旧键，避免下次启动又把旧值盖回来。
    if (legacy != "") {
        for k in gKeys
            IniWrite k.interval, gIni, "Settings", k.ini
        try IniDelete(gIni, "Settings", "Interval")
    }
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

; 浅色底 + 近黑字之后按钮靠 1px 描边立形；两块都挂 Click，否则点在描边上没反应。
; 不用系统 Button：宿主缺 comctl32 v6 manifest 时系统控件退回经典 3D 凸起。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

; 单行 Edit 对 EM_SETRECT(0xB3) 无效，必须 Multi 系列凑出 ES_MULTILINE 再设 top=2。
SetEditRect(hwnd, left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0)
    NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8)
    NumPut("Int", bottom, rc, 12)
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0xB3, "Ptr", 0, "Ptr", rc, "Ptr")
}

; DWM 属性 35/36/34 只写不读，COLORREF 是 0x00BBGGRR；必须在 Show() 之后调用。
PaintCaption(hwnd) {
    c := Buffer(4, 0)
    NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0)
    NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; 版式照 开发指南 §10：客户区 332×150，行宽 300（332−16×2）。
; 三行字段都是「标签 180 + 8 + 输入框 112 = 300」，输入框右缘 316；
; 操作行两按钮右对齐到同一个 316 —— 输入框与按钮组共用右边界，不再左右错位。
; 去掉了 1.1.0 的底部状态条；窗口高 = 顶 12 + 12 + 28 + 4 + 28 + 4 + 28 + 6 + 28 + 底 12 = 150。
ShowSettings() {
    global gKeys
    g := Gui(, "双击防抖")
    g.BackColor := "F7F9FC"
    g.SetFont("s10", "Microsoft YaHei UI")
    g.OnEvent("Close", (*) => g.Destroy())

    edits := []
    for i, k in gKeys {
        y := 12 + (i - 1) * 32
        g.Add("Text", "x16 y" y " w180 h28 BackgroundF7F9FC c202B3A +0x200"
            , k.name "最小间隔（ms）")
        g.Add("Text", "x204 y" y " w112 h28 BackgroundB7C8E0")
        ed := g.Add("Edit", "x205 y" (y + 1) " w110 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A"
            , k.interval)
        SetEditRect(ed.Hwnd, 8, 2, 104, 26)
        edits.Push(ed)
    }

    FlatButton(g, 192, 110, 58, 28, "取消", "EBF2FB", "B7C8E0", (*) => g.Destroy())
    FlatButton(g, 258, 110, 58, 28, "保存", "EBF2FB", "B7C8E0", (*) => SaveSettings(g, edits))
    g.Show("w332 h150 Center")
    PaintCaption(g.Hwnd)
}

SaveSettings(g, edits) {
    global gKeys, gIni
    vals := []
    for i, ed in edits {
        v := Integer(ed.Value)
        if (v != 0 && (v < 10 || v > 500)) {
            MsgBox "「" gKeys[i].name "」请输入 0 或 10~500 之间的毫秒数。", "设置", "Iconx T1.5"
            return
        }
        vals.Push(v)
    }
    for i, k in gKeys {
        k.interval := vals[i]
        ; 改间隔后清掉旧计时，否则禁用/放宽的键可能残留一次 blocked 抬起。
        k.last := 0, k.blocked := false
        IniWrite k.interval, gIni, "Settings", k.ini
    }
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
