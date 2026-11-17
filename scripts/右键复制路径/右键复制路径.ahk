; ==UserScript==
; @name         右键复制路径
; @id           copy-full-path
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.0
; @description  给文件/文件夹空白处/文件夹/驱动器的右键菜单加「复制完整路径」，只写 HKCU，随时可撤销
; @author       邱宗满
; @date         2026-11-17
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口勾选场景后「应用」；--copy-path 为菜单静默调用；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 右键复制路径：单点用途——只往右键菜单加一个固定动作「复制完整路径」，不动默认关联。
; 形态：配置窗口（勾选四个场景 → 应用/撤销）+ 静默分支（菜单点击时把 %1 写进剪贴板）。
; 只写 HKCU\Software\Classes\<场景>\shell\AHKDeckCopyFullPath，零提权；verb 固定 ASCII，
; 不碰 open/edit 激活动词，不写 CommandFlags；改完 SHChangeNotify(0x08000000) 即时生效。
; 反例（本脚本不做）：按软件改 UserChoice、按后缀名开放增删、自定义任意命令——那是 F138 被否的菜单管理器。
; 纯 AHK v2 原创实现，未复用第三方源码；许可 AGPL-3.0，全文见仓库根目录 LICENSE。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ── 纯函数（自检可测）────────────────────────────────────────────────────
CopyVerb() => "AHKDeckCopyFullPath"

; 四个固定场景 → HKCU\Software\Classes 下的相对根。封闭集合，不可扩展成通用编辑器。
SceneRoots() => Map(
    "file",  "*\shell",
    "bg",    "Directory\Background\shell",
    "dir",   "Directory\shell",
    "drive", "Drive\shell"
)

; 菜单项命令行：当前解释器 + 本脚本 + 静默动作 + 选中项占位符 %1。
; 自引用脚本——移动/改名脚本后须重开本窗口点「应用」刷新，否则菜单断链（info/README 已写明）。
; ★ 两种解释器形态（实机验证）：
;   · 宿主内核 AHKDeck.exe —— 只认 --run <脚本> [参数...]，直接跟脚本路径只会打印 usage（假成功）；
;   · 独立 AutoHotkey64.exe —— 直接跟脚本路径即可，加 --run 反而被当脚本名。
; 用解释器文件名分流，不用进程名猜；每个路径都带引号，含空格不散。
BuildCommand(exe, script) {
    q := Chr(34)
    exeName := RegExReplace(exe, "^.*\\")
    runArg := (exeName = "AHKDeck.exe") ? "--run " : ""
    return q exe q " " runArg q script q " --copy-path " q "%1" q
}

; ── 静默分支：被资源管理器菜单调用，写剪贴板后立即退出，不建窗口 ────────
if (A_Args.Length && A_Args[1] = "--copy-path") {
    if (A_Args.Length >= 2)
        A_Clipboard := A_Args[2]
    ExitApp(0)
}

; ── --selftest：无 GUI 分支，断言纯函数与避坑约束 ───────────────────────
if (A_Args.Length && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\右键复制路径\selftest-result.txt")

RunSelfTest(path) {
    out := "", fails := 0
    Chk(cond, name) {
        global fails
        out .= (cond ? "PASS " : "FAIL ") name "`n"
        if !cond
            fails++
    }
    roots := SceneRoots()
    cmd := BuildCommand("C:\AHK\AutoHotkey64.exe", "C:\my dir\右键复制路径.ahk")
    Chk(CopyVerb() = "AHKDeckCopyFullPath", "verb 名固定且为 ASCII")
    Chk(roots.Count = 4 && roots.Has("file") && roots.Has("bg") && roots.Has("dir") && roots.Has("drive"), "四个固定场景齐")
    Chk(roots["bg"] = "Directory\Background\shell", "空白处场景根正确")
    Chk(InStr(cmd, "--copy-path") > 0 && InStr(cmd, "%1") > 0, "命令行含静默动作与占位符")
    q := Chr(34)
    Chk(InStr(cmd, q "C:\my dir\右键复制路径.ahk" q) > 0, "带空格的脚本路径被引号包裹")
    Chk(InStr(cmd, "--run") = 0, "独立解释器形态不加 --run")
    Chk(InStr(BuildCommand("C:\AHKDeck.exe", "C:\s.ahk"), "--run") > 0, "宿主内核形态加 --run")
    Chk(!InStr(cmd, "CommandFlags") && !InStr(cmd, "open") && !InStr(cmd, "edit"), "不碰 CommandFlags/open/edit")
    out .= "fails=" fails "`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

; ── 全局变量 ────────────────────────────────────────────────────────────
global gGui := 0, gStatus := 0
global gChkFile := 0, gChkBg := 0, gChkDir := 0, gChkDrive := 0
global gBtnApply := 0, gBtnRevoke := 0

; 系统 CheckBox 在宿主里是经典黑勾方框，样式位去不掉，改成三层 Text 色块自绘。
; 类声明必须写在 BuildGui() 调用之前（K18），否则加载时弹「This line will never execute」。
class FlatCheck {
    __New(g, x, y, w, h, text, checked := false) {
        this.Value := checked ? 1 : 0
        this.cb := 0
        boxY := y + (h - 16) // 2
        this.frame := g.Add("Text", "x" x " y" boxY " w16 h16 BackgroundB7C8E0")
        this.fill := g.Add("Text", "x" (x + 1) " y" (boxY + 1) " w14 h14 +0x200 Center", "")
        this.fill.SetFont("s11 Bold", "Microsoft YaHei UI")
        this.label := g.Add("Text", "x" (x + 22) " y" y " w" (w - 22) " h" h
            " BackgroundF7F9FC c202B3A +0x200", text)
        this.Paint()
        for c in [this.frame, this.fill, this.label]
            c.OnEvent("Click", (*) => this.Toggle())
    }
    Paint() {
        if (this.Value) {
            this.fill.Opt("BackgroundEBF2FB c202B3A")
            this.fill.Value := "✓"
        } else {
            this.fill.Opt("BackgroundFFFFFF c202B3A")
            this.fill.Value := ""
        }
    }
    Toggle() {
        this.Value := !this.Value
        this.Paint()
        ; 存的是函数对象，必须显式 .Call()：this.cb() 会被当成方法并多传 this（K32）。
        if (this.cb)
            this.cb.Call()
    }
    OnEvent(name, cb) {
        if (name = "Click")
            this.cb := cb
    }
}

; DWM 属性 35/36/34 只写不读，验证只能看像素；COLORREF 是 0x00BBGGRR。
PaintCaption() {
    global gGui
    c := Buffer(4, 0), NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0), NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; 1px 描边按钮：两层都挂 Click，否则点在 1px 边上没反应（K26）。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

; 读某场景是否已装（只读 HKCU，双 hive 里另一个 hive 的项不由本脚本写，故不认）。
IsSceneOn(root) {
    SetRegView 64
    base := "HKCU\Software\Classes\" root "\" CopyVerb()
    try return RegRead(base "\command") != "" ? 1 : 0
    return 0
}

Apply() {
    global gStatus, gChkFile, gChkBg, gChkDir, gChkDrive
    SetRegView 64
    cmd := BuildCommand(A_AhkPath, A_ScriptFullPath)
    roots := SceneRoots()
    picked := Map("file", gChkFile.Value, "bg", gChkBg.Value
        , "dir", gChkDir.Value, "drive", gChkDrive.Value)
    n := 0
    for key, root in roots {
        base := "HKCU\Software\Classes\" root "\" CopyVerb()
        if (picked[key]) {
            try {
                ; ★ 本内核 RegWrite 签名 = (Value, ValueType, KeyName, ValueName)，
                ;   不是现代 AHK v2 的 (ValueType, KeyName, ValueName, Value）——lookup_help 实证。
                RegWrite "复制完整路径", "REG_SZ", base, "MUIVerb"
                RegWrite cmd, "REG_SZ", base "\command"
                n++
            } catch as e {
                gStatus.Value := "写入失败 · " key " · " e.Message
                return
            }
        } else {
            ; RegDelete 删「值」、RegDeleteKey 删「键」——删菜单项必须删键（含子键先、父键后）。
            try RegDeleteKey base "\command"
            try RegDeleteKey base
        }
    }
    ; 改注册表后广播一次关联变更，绝大多数场景免重启 explorer 即时生效。
    DllCall("shell32\SHChangeNotify", "Int", 0x08000000, "UInt", 0, "Ptr", 0, "Ptr", 0)
    gStatus.Value := n ? "已启用 " n " 个场景 · 右键即见「复制完整路径」" : "已清空 · 右键菜单无本脚本项"
}

Revoke() {
    global gStatus
    SetRegView 64
    roots := SceneRoots()
    for key, root in roots {
        base := "HKCU\Software\Classes\" root "\" CopyVerb()
        try RegDeleteKey base "\command"
        try RegDeleteKey base
    }
    DllCall("shell32\SHChangeNotify", "Int", 0x08000000, "UInt", 0, "Ptr", 0, "Ptr", 0)
    gStatus.Value := "已撤销全部 · 右键菜单恢复原状"
}

; 版式照 UI规范 §10.2/§10.3：客户区 420×228，内容行 x16 w388；同排同高，
; 文字控件固定 h +0x200 垂直居中；状态条铺满窗口底，caption 由 DWM 染成同一个 #DCE8F7。
BuildGui() {
    global gGui, gStatus, gChkFile, gChkBg, gChkDir, gChkDrive

    gGui := Gui("", "右键复制路径")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())

    ; 说明行（事实句，不写指令句）
    gGui.Add("Text", "x16 y12 w388 h24 BackgroundF7F9FC c202B3A +0x200", "勾选要启用的右键场景")

    ; 四个场景勾选：y42/72/102/132，同 h26，ROW_GAP 4
    gChkFile  := FlatCheck(gGui, 16, 42, 388, 26, "文件")
    gChkBg    := FlatCheck(gGui, 16, 72, 388, 26, "文件夹空白处")
    gChkDir   := FlatCheck(gGui, 16, 102, 388, 26, "文件夹")
    gChkDrive := FlatCheck(gGui, 16, 132, 388, 26, "驱动器")

    ; 反映当前注册表状态（重开窗口即见已装场景）
    gChkFile.Value  := IsSceneOn(SceneRoots()["file"])
    gChkBg.Value    := IsSceneOn(SceneRoots()["bg"])
    gChkDir.Value   := IsSceneOn(SceneRoots()["dir"])
    gChkDrive.Value := IsSceneOn(SceneRoots()["drive"])
    for c in [gChkFile, gChkBg, gChkDir, gChkDrive]
        c.Paint()

    ; 操作行：两按钮右对齐，余量留在左侧（K25：按钮宽=文字宽+32）
    FlatButton(gGui, 248, 164, 58, 28, "应用", "EBF2FB", "B7C8E0", Apply)
    FlatButton(gGui, 314, 164, 58, 28, "撤销", "EBF2FB", "B7C8E0", Revoke)

    ; 状态条
    gGui.Add("Text", "x0 y198 w420 h30 BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y198 w396 h30 BackgroundDCE8F7 c202B3A +0x200", "就绪")

    gGui.Show("w420 h228 Center")
    PaintCaption()
}

BuildGui()
