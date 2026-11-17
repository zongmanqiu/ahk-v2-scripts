; ==UserScript==
; @name         右键菜单整理
; @id           context-menu-tidy
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.0
; @description  列出文件/文件夹/空白处/驱动器等位置的右键菜单项，逐项隐藏或调整位置，只写 HKCU 可随时恢复
; @author       邱宗满
; @date         2026-11-17
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口左侧选位置、右侧选菜单项，底部按钮隐藏/显示/置顶/置底；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 右键菜单整理：一个零提权的右键菜单管理器，只做两件事——隐藏/恢复菜单项、调整菜单项位置。
; 不永久删除、不改命令、不碰文件关联、不提权；这正是被否的 F138「通用菜单编辑器」收窄后的子类。
;
; ★ 核心机制（本机实测 + 源码双重确认，见 info/HISTORY.md）：
;   · 读：HKCR 合并视图枚举每个位置的 shell 子键（verb），拿到系统+软件装进去的全部菜单项。
;   · 隐藏：在 HKCU\Software\Classes\<位置>\shell\<verb> 建「影子键」，写 ProgrammaticAccessOnly=""。
;     HKCR 合并视图里这个值一出现，菜单项即隐藏；HKLM 原键一个字节都不动。实测影子键的值在
;     HKCR 可见、HKLM 原值不受影响、默认值与 command 仍从 HKLM 合并而来（不会把菜单项写坏）。
;   · 恢复：删掉影子键里自己写的 ProgrammaticAccessOnly 与 Position；若仍有系统级隐藏标记
;     （HKLM 的 HideBasedOnVelocityId/LegacyDisable/ProgrammaticAccessOnly/CommandFlags），
;     如实提示需管理员权限，绝不谎称已恢复。
;   · 位置：影子键写 Position=top/bottom，删值即回默认。实测 HKCU 的 Position 在 HKCR 可见。
;   · 改完 SHChangeNotify(SHCNE_ASSOCCHANGED) 即时生效，无需重启 explorer。
;
; 蓝本：ContextMenuManager 的 ShellItem.cs（ItemVisible / ItemPosition 两段约 100 行纯注册表逻辑），
; 本文件是独立 AHK v2 实现，未复制其代码。许可 AGPL-3.0，全文见仓库根 LICENSE。
;
; 坑（源码实证，务必保留）：
;   · 四种隐藏标记是 OR 关系：HideBasedOnVelocityId==0x639bc8 / LegacyDisable /
;     ProgrammaticAccessOnly / CommandFlags%16>=8；判"当前是否隐藏"四种都要看。
;   · CommandFlags 是 EXPCMDFLAGS 功能位掩码，只读不写——本脚本永不写它。
;   · Folder\shell\opennewwindow 写 LegacyDisable 会弄坏 Win+E 和任务栏资源管理器——本脚本
;     根本不写 LegacyDisable，从源头避开。
;   · 隐藏标记写在 HKLM 的项零提权删不掉，只能提示需管理员权限，不能假装成功。
;   · 显示名可能是 "@shell32.dll,-8506" 这类间接串，用 SHLoadIndirectString 解析成人话。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ── 常量 ────────────────────────────────────────────────────────────────
HKEY_CLASSES_ROOT  := 0x80000000
HKEY_CURRENT_USER  := 0x80000001
HKEY_LOCAL_MACHINE := 0x80000002
KEY_READ_64        := 0x20019 | 0x100   ; KEY_READ | KEY_WOW64_64KEY
REG_DWORD          := 4
REG_SZ             := 1
MISSING            := "__ahkdeck_context_tidy_missing__"
HIDE_MARK          := "ProgrammaticAccessOnly"
VEL_HIDE_VALUE     := 6527944           ; 0x639bc8

; 客户区 720×420；左侧导航固定，右侧列表吃余量。
WIN_W := 720, WIN_H := 420
NAV_X := 16, NAV_W := 136, NAV_ITEM_H := 28, NAV_GAP := 4
LIST_X := 168, LIST_Y := 16, LIST_W := 536, HEAD_H := 28, LIST_H := 296
COL_NAME_W := 320, COL_STATE_W := 100
BTN_Y := 352, BTN_H := 30
STATUS_Y := 386, STATUS_H := 30

; 封闭的七个位置集合，不做开放扩展。
SceneDefs() => [
    { key: "file",    name: "文件",         suffix: "*\shell" },
    { key: "dir",     name: "文件夹",       suffix: "Directory\shell" },
    { key: "bg",      name: "文件夹空白处", suffix: "Directory\Background\shell" },
    { key: "drive",   name: "驱动器",       suffix: "Drive\shell" },
    { key: "folder",  name: "文件夹对象",   suffix: "Folder\shell" },
    { key: "all",     name: "所有对象",     suffix: "AllFilesystemObjects\shell" },
    { key: "desktop", name: "桌面背景",     suffix: "DesktopBackground\shell" }
]

; ── 纯函数（--selftest 可测，不碰注册表）─────────────────────────────────
; 四种隐藏标记是 OR；vals 是 Map(值名 -> 值)，DWORD 用整数、字符串用串。
HiddenByMarks(vals) {
    if (vals.Has("HideBasedOnVelocityId") && vals["HideBasedOnVelocityId"] = VEL_HIDE_VALUE)
        return true
    for n in ["LegacyDisable", "ProgrammaticAccessOnly"]
        if vals.Has(n)
            return true
    if (vals.Has("CommandFlags") && Mod(vals["CommandFlags"], 16) >= 8)
        return true
    return false
}

; 位置值归一：只有 top/bottom 非空算有效，其余（含大写）都归默认。
NormalizePos(v) {
    s := Trim(v)
    if (s = "")
        return "default"
    ; 用 == 区分大小写：AHK 的 = 不区分大小写，会把 "Top" 误当 "top"（自测抓到）。
    return (s == "top" || s == "bottom") ? s : "default"
}

; 显示名：间接串 @dll,-n 交由调用方解析；这里只判断"是不是间接串"。
IsIndirectString(s) => (s != "" && SubStr(s, 1, 1) = "@")

; 本脚本永不对这两个激活关键 verb 做任何写操作。
IsProtectedVerb(v) => (v = "open" || v = "edit")

; 影子键物理路径（只写 HKCU，绝不写 HKCR/HKLM）。
ShadowKey(suffix, verb) => "HKCU\Software\Classes\" suffix "\" verb

; ── Win32 注册表读取（内核无 RegEnumKey，用 API 枚举）────────────────────
RegGet(root, path, name, default := MISSING) {
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0,
            "UInt", KEY_READ_64, "Ptr*", &h, "Int") != 0
        return default
    try {
        typ := 0, sz := 0
        if DllCall("advapi32\RegQueryValueExW", "Ptr", h, "Str", name, "Ptr", 0,
                "Ptr*", &typ, "Ptr", 0, "Ptr*", &sz, "Int") != 0
            return default
        if (sz = 0)
            return ""
        buf := Buffer(sz, 0)
        if DllCall("advapi32\RegQueryValueExW", "Ptr", h, "Str", name, "Ptr", 0,
                "Ptr*", &typ, "Ptr", buf, "Ptr*", &sz, "Int") != 0
            return default
        if (typ = REG_DWORD)
            return NumGet(buf, 0, "UInt")
        return StrGet(buf, sz // 2, "UTF-16")
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
}

EnumSubkeys(root, path) {
    arr := []
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0,
            "UInt", KEY_READ_64, "Ptr*", &h, "Int") != 0
        return arr
    try {
        i := 0
        loop {
            buf := Buffer(512, 0), cch := 256
            r := DllCall("advapi32\RegEnumKeyExW", "Ptr", h, "UInt", i, "Ptr", buf,
                "UInt*", &cch, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Int")
            if (r != 0)
                break
            arr.Push(StrGet(buf, cch, "UTF-16"))
            i++
        }
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
    return arr
}

; 收集某 verb 的四种标记，交给纯函数 HiddenByMarks 判定。
VerbMarks(root, path, verb) {
    vals := Map()
    base := path "\" verb
    for n in ["HideBasedOnVelocityId", "LegacyDisable", "ProgrammaticAccessOnly", "CommandFlags"] {
        v := RegGet(root, base, n, MISSING)
        if (v != MISSING)
            vals[n] := v
    }
    return vals
}

; 显示名：MUIVerb 优先，其次默认值；@dll,-n 用 SHLoadIndirectString 解析成人话。
VerbLabel(root, path, verb) {
    base := path "\" verb
    raw := RegGet(root, base, "MUIVerb", MISSING)
    if (raw = MISSING || raw = "")
        raw := RegGet(root, base, "", verb)
    if (raw = MISSING || raw = "")
        return verb
    if IsIndirectString(raw) {
        out := Buffer(1024, 0)
        if DllCall("shlwapi\SHLoadIndirectString", "Str", raw, "Ptr", out,
                "UInt", 512, "Ptr", 0, "Int") = 0 {
            s := StrGet(out, "UTF-16")
            if (s != "")
                return s
        }
        return verb   ; 解析不出来就回退 verb 名，不把 @shell32.dll,-8506 甩给用户
    }
    return raw
}

NotifyAssocChanged() =>
    DllCall("shell32\SHChangeNotify", "Int", 0x08000000, "UInt", 0, "Ptr", 0, "Ptr", 0)

; ── 全局状态 ────────────────────────────────────────────────────────────
global gGui := 0, gList := 0, gStatus := 0, gNavBtns := []
global gItems := [], gScene := 1

; ── 数据层 ──────────────────────────────────────────────────────────────
MakeItems(scene) {
    global HKEY_CLASSES_ROOT, HKEY_CURRENT_USER
    items := []
    suffix := scene.suffix
    for verb in EnumSubkeys(HKEY_CLASSES_ROOT, suffix) {
        ; 合并视图判"当前是否隐藏"；本机影子键只认 ProgrammaticAccessOnly 是自己写的。
        effHidden := HiddenByMarks(VerbMarks(HKEY_CLASSES_ROOT, suffix, verb))
        ownVals := VerbMarks(HKEY_CURRENT_USER, "Software\Classes\" suffix, verb)
        ours := ownVals.Has(HIDE_MARK)
        state := effHidden ? (ours ? "hidden" : "syshidden") : "show"
        pos := NormalizePos(RegGet(HKEY_CLASSES_ROOT, suffix "\" verb, "Position", ""))
        items.Push({ verb: verb, label: VerbLabel(HKEY_CLASSES_ROOT, suffix, verb)
                   , state: state, pos: pos })
    }
    return items
}

RefreshItems() {
    global gList, gStatus, gItems, gScene
    scene := SceneDefs()[gScene]
    gItems := MakeItems(scene)
    gList.Delete()
    nHide := 0, nSys := 0
    for it in gItems {
        st := it.state = "show" ? "显示" : it.state = "hidden" ? "已隐藏" : "系统隐藏"
        ps := it.pos = "top" ? "置顶" : it.pos = "bottom" ? "置底" : "默认"
        gList.Add("", it.label, st, ps)
        if (it.state = "hidden")
            nHide++
        if (it.state = "syshidden")
            nSys++
    }
    gStatus.Value := scene.name " · 共 " gItems.Length " 项 · 已隐藏 " nHide " · 系统隐藏 " nSys
}

SelectedItem() {
    global gList, gItems
    r := gList.GetNext(0, "F")
    if !r
        r := gList.GetNext(0)
    return r ? gItems[r] : 0
}

; ── 写操作（只写 HKCU 影子键）───────────────────────────────────────────
SetHide(on) {
    global gStatus, gScene
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if IsProtectedVerb(it.verb) {
        gStatus.Value := "「" it.verb "」是打开动词，本脚本不改动它"
        return
    }
    key := ShadowKey(SceneDefs()[gScene].suffix, it.verb)
    if on {
        try {
            RegWrite "", "REG_SZ", key, HIDE_MARK
            gStatus.Value := "已隐藏「" it.label "」· 右键菜单刷新后生效"
        } catch as e
            gStatus.Value := "隐藏失败 · " e.Message
    } else {
        try RegDelete key, HIDE_MARK
        gStatus.Value := "已移除本脚本加的隐藏标记 · " (it.state = "syshidden"
            ? "该项仍有系统级隐藏标记，需管理员权限才能恢复" : "菜单项恢复显示")
    }
    NotifyAssocChanged()
    RefreshItems()
}

SetPos(pos) {
    global gStatus, gScene
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if IsProtectedVerb(it.verb) {
        gStatus.Value := "「" it.verb "」是打开动词，本脚本不改动它"
        return
    }
    key := ShadowKey(SceneDefs()[gScene].suffix, it.verb)
    try {
        if (pos = "default")
            RegDelete key, "Position"
        else
            RegWrite pos, "REG_SZ", key, "Position"
        gStatus.Value := "「" it.label "」位置已设为" (pos = "top" ? "置顶" : pos = "bottom" ? "置底" : "默认")
    } catch as e
        gStatus.Value := "调整位置失败 · " e.Message
    NotifyAssocChanged()
    RefreshItems()
}

; ── UI ──────────────────────────────────────────────────────────────────
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

FlatButton(g, x, y, w, h, text, cb, fill := "EBF2FB", edge := "B7C8E0") {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

NavClick(i, *) {
    global gNavBtns, gScene
    gScene := i
    for j, b in gNavBtns
        b.Opt("Background" (j = i ? "EBF2FB" : "F7F9FC"))
    RefreshItems()
}

BuildGui() {
    global gGui, gList, gStatus, gNavBtns
    gGui := Gui("", "右键菜单整理")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())

    ; 左侧位置导航：选中项整块 EBF2FB，未选中与底色同色（照硬件信息范本）。
    gNavBtns := []
    y := NAV_Y := 16
    for i, sc in SceneDefs() {
        b := gGui.Add("Text", "x" NAV_X " y" y " w" NAV_W " h" NAV_ITEM_H
            " Background" (i = 1 ? "EBF2FB" : "F7F9FC") " c202B3A +0x200 Center", sc.name)
        b.OnEvent("Click", NavClick.Bind(i))
        gNavBtns.Push(b)
        y += NAV_ITEM_H + NAV_GAP
    }

    ; 列表区：白底块 + 四边各 1px 线（§10.4）。列头自绘，ListView 去原生列头。
    ; ★ 装饰色块全部 +0x100（WS_EX_TRANSPARENT）：否则它们会像真实点击一样挡住
    ;   底下 ListView 的鼠标消息（MCP 实测点击落点全是 Static、列表一行都选不中）。
    gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_Y + 1) " w" (LIST_W - 2)
        " h" (HEAD_H + LIST_H - 1) " BackgroundFFFFFF +0x100")
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w" LIST_W " h1 BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" LIST_X " y" (LIST_Y + HEAD_H + LIST_H) " w" LIST_W " h1 BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" (LIST_X + LIST_W - 1) " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_Y + 1) " w" (LIST_W - 2) " h" HEAD_H " BackgroundDCE8F7 +0x100")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x" (LIST_X + 7) " y" (LIST_Y + 1) " w" (COL_NAME_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "菜单项")
    gGui.Add("Text", "x" (LIST_X + 7 + COL_NAME_W) " y" (LIST_Y + 1) " w" (COL_STATE_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "状态")
    gGui.Add("Text", "x" (LIST_X + 13 + COL_NAME_W + COL_STATE_W) " y" (LIST_Y + 1)
        " w" (LIST_W - COL_NAME_W - COL_STATE_W - 16) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "位置")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    gList := gGui.Add("ListView", "x" (LIST_X + 1) " y" (LIST_Y + HEAD_H + 1)
        " w" (LIST_W - 2) " h" (LIST_H - 1) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["菜单项", "状态", "位置"])
    gList.ModifyCol(1, COL_NAME_W), gList.ModifyCol(2, COL_STATE_W)
    gList.ModifyCol(3, LIST_W - COL_NAME_W - COL_STATE_W - 6)
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)

    ; 操作按钮：隐藏/显示/置顶/置底/恢复位置/刷新。
    FlatButton(gGui, 168, BTN_Y, 64, BTN_H, "隐藏", () => SetHide(true))
    FlatButton(gGui, 240, BTN_Y, 64, BTN_H, "显示", () => SetHide(false))
    FlatButton(gGui, 328, BTN_Y, 64, BTN_H, "置顶", () => SetPos("top"))
    FlatButton(gGui, 400, BTN_Y, 64, BTN_H, "置底", () => SetPos("bottom"))
    FlatButton(gGui, 488, BTN_Y, 88, BTN_H, "恢复位置", () => SetPos("default"))
    FlatButton(gGui, 596, BTN_Y, 64, BTN_H, "刷新", (*) => RefreshItems())

    gGui.Add("Text", "x0 y" STATUS_Y " w" WIN_W " h" STATUS_H " BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y" STATUS_Y " w" (WIN_W - 24) " h" STATUS_H
        " BackgroundDCE8F7 c202B3A +0x200", "就绪")

    gGui.Show("w" WIN_W " h" WIN_H " Center")
    PaintCaption()
    RefreshItems()
}

; ── 无 GUI 分支 ─────────────────────────────────────────────────────────
if (A_Args.Length && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\右键菜单整理\selftest-result.txt")

; --probe <位置suffix> <verb> <动作>：实机回归直接驱动同一套写函数，验证注册表效果。
; 宿主 MCP 的 send_input 命中不到被装饰色块包住的 ListView（K19），故写操作走此分支测，
; GUI 层单独测几何与列表内容。动作：hide / show / top / bottom / default。
if (A_Args.Length >= 4 && A_Args[1] = "--probe") {
    ProbeWrite(A_Args[2], A_Args[3], A_Args[4])
    ExitApp(0)
}

ProbeWrite(suffix, verb, action) {
    key := ShadowKey(suffix, verb)
    switch action {
        case "hide":    RegWrite "", "REG_SZ", key, HIDE_MARK
        case "show":    try RegDelete key, HIDE_MARK
        case "top":     RegWrite "top", "REG_SZ", key, "Position"
        case "bottom":  RegWrite "bottom", "REG_SZ", key, "Position"
        case "default": try RegDelete key, "Position"
        default: throw ValueError("未知 probe 动作: " action)
    }
    NotifyAssocChanged()
}

RunSelfTest(path) {
    out := "", fails := 0
    ; 嵌套函数里写外层局部变量：用 ByRef 传，避免 global 绑定问题（本内核实测 global fails 未赋值）。
    Chk(cond, name, &out, &fails) {
        out .= (cond ? "PASS " : "FAIL ") name "`n"
        if !cond
            fails++
    }
    defs := SceneDefs()
    Chk(defs.Length = 7, "七个固定位置", &out, &fails)
    keys := Map()
    for d in defs
        keys[d.key] := 1
    Chk(keys.Count = 7 && keys.Has("file") && keys.Has("bg") && keys.Has("desktop"), "位置 key 唯一且齐全", &out, &fails)
    Chk(defs[1].suffix = "*\shell" && defs[3].suffix = "Directory\Background\shell", "位置根路径正确", &out, &fails)

    m1 := Map("ProgrammaticAccessOnly", "")
    m2 := Map("HideBasedOnVelocityId", VEL_HIDE_VALUE)
    m3 := Map("LegacyDisable", "")
    m4 := Map("CommandFlags", 8)
    m5 := Map("CommandFlags", 7)
    Chk(HiddenByMarks(m1) && HiddenByMarks(m2) && HiddenByMarks(m3) && HiddenByMarks(m4), "四种隐藏标记都认", &out, &fails)
    Chk(!HiddenByMarks(m5) && !HiddenByMarks(Map()), "CommandFlags 低4位<8 与空标记算显示", &out, &fails)
    Chk(NormalizePos("top") = "top" && NormalizePos("bottom") = "bottom", "位置值归一 top/bottom", &out, &fails)
    Chk(NormalizePos("Top") = "default" && NormalizePos("") = "default", "非小写/空值归默认", &out, &fails)
    Chk(IsIndirectString("@shell32.dll,-8506") && !IsIndirectString("在此处打开"), "间接串识别", &out, &fails)
    Chk(IsProtectedVerb("open") && IsProtectedVerb("edit") && !IsProtectedVerb("cmd"), "保护 open/edit 动词", &out, &fails)
    Chk(ShadowKey("*\shell", "cmd") = "HKCU\Software\Classes\*\shell\cmd", "影子键只落在 HKCU", &out, &fails)
    Chk(InStr(ShadowKey("*\shell", "cmd"), "HKLM") = 0 && InStr(ShadowKey("*\shell", "cmd"), "HKCR") = 0
        , "影子键绝不指向 HKLM/HKCR", &out, &fails)

    out .= "fails=" fails "`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

BuildGui()
