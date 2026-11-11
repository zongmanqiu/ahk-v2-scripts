; ==UserScript==
; @name         打开方式清理
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.2.0
; @description  扫描 Windows「打开方式」相关的 13 处注册表位置，列出并清理失效残留
; @author       邱宗满
; @date         2026-11-11
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        托盘菜单「打开方式清理」；--report / --selftest 为无 GUI 分支
; ==/UserScript==
;
; 许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
; 功能复刻自 OpenWithCleaner（C# / WinForms，同一作者），注册表扫描口径一致，界面用纯 AHK v2 重写。
; 不含原项目的关于页、打赏二维码、多语言与自动更新（自动更新会覆盖宿主目录，不能照搬）。
; 与原项目的差异：复制路径改为工具条按钮与双击行；新增「删除失效项」；
; 扫描结果按注册表位置去重（原项目把 HKCU 的扩展名重复计入两次）。
; 恢复功能与原项目一样有损：备份只记程序路径，恢复一律写回 REG_SZ，不还原原始值类型与 MRUList 顺序。
; 无 GUI 分支：--report [路径] 只读扫描读数；--selftest [路径] 合成键自测（只动自建键，结束即清理）。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

class RK {
    static FileExts    := "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts"
    static Classes     := "Software\Classes"
    static Apps        := "Software\Classes\Applications"
    static Mui1        := "Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    static Mui2        := "Software\Microsoft\Windows\Shell\MuiCache"
    static Recent      := "Software\Microsoft\Windows\CurrentVersion\Search\RecentApps"
    static Repo        := "Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages"
    static Contract    := "Extensions\ContractId\Windows.Launch\PackageId"
    static LmClasses   := "SOFTWARE\Classes"
    static LmClasses32 := "SOFTWARE\Wow6432Node\Classes"
    static LmApps      := "SOFTWARE\Classes\Applications"
    static LmApps32    := "SOFTWARE\Wow6432Node\Classes\Applications"
    static AppPaths    := "SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"
    static AppPaths32  := "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\App Paths"
    static Clients     := "SOFTWARE\Clients\StartMenuInternet"
    static Clients32   := "SOFTWARE\Wow6432Node\Clients\StartMenuInternet"
}

class L {
    static Status := Map("Exists", "有效", "Missing", "未找到", "Unknown", "未知")
    static Source := Map(
        "MRU List", "最近使用列表",
        "ProgId", "关联标识",
        "Application", "程序注册",
        "Global MRU List", "全局最近使用",
        "Global ProgId", "全局关联标识",
        "System MRU List", "系统关联",
        "App Path", "程序路径",
        "Recent App", "最近使用",
        "Store App", "商店应用",
        "ProgId Registration", "关联标识注册")
}

S := {
    all: [], view: [], seen: Map(), dupes: 0,
    mui: Map(), exe: Map(), pid: Map(), fname: Map(), pathDirs: [],
    gui: 0, lv: 0, sb: 0, search: 0,
    scanning: false, steps: [], step: 0, t0: 0, scanMs: 0,
    sortCol: 0, sortDesc: false, boldFont: 0, mutex: 0, nextEid: 1,
    histGui: 0, histList: 0, histFiles: [], histView: 0, histRestore: 0, histDirty: false
}
gSortRank := Map()
gSortCb := 0

if (A_Args.Length >= 1 && A_Args[1] = "--report") {
    RunReport(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\打开方式清理\scan-report.txt")
    ExitApp
}

if (A_Args.Length >= 1 && A_Args[1] = "--selftest") {
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest-result.txt")
    ExitApp
}

InitCaches()
GuardInstance()
BuildGui()
SetupTray()
StartScan()
return

; ── 基础设施 ────────────────────────────────────────────────────────

Qpc() {
    c := 0
    DllCall("QueryPerformanceCounter", "Int64*", &c)
    return c
}

MsSince(t) {
    static f := 0
    if !f
        DllCall("QueryPerformanceFrequency", "Int64*", &f)
    return (Qpc() - t) * 1000.0 / f
}

InitCaches() {
    global S
    S.mui := Map(), S.mui.CaseSense := false
    S.exe := Map(), S.exe.CaseSense := false
    S.pid := Map(), S.pid.CaseSense := false
    S.fname := Map(), S.fname.CaseSense := false
    S.pathDirs := []
    for d in StrSplit(EnvGet("PATH"), ";") {
        d := Trim(d, " `t`"")
        if (d != "")
            S.pathDirs.Push(d)
    }
    S.pathDirs.Push(A_WinDir "\System32")
    S.pathDirs.Push(A_WinDir)
}

GuardInstance() {
    global S
    S.mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", "AHKDeck.OpenWithCleaner", "Ptr")
    if (A_LastError = 183) {
        MsgBox "「打开方式清理」已经在运行了。", "打开方式清理", "Iconi"
        ExitApp
    }
}

HiveName(h) => h = "HKCU" ? "HKEY_CURRENT_USER" : h = "HKLM" ? "HKEY_LOCAL_MACHINE" : "HKEY_CLASSES_ROOT"
HiveToken(h) => h = "HKCU" ? "CurrentUser" : h = "HKLM" ? "LocalMachine" : "ClassesRoot"
HistDir() => A_ScriptDir "\打开方式清理\history"

EndsWith(s, suf) {
    n := StrLen(suf)
    return n <= StrLen(s) && SubStr(s, StrLen(s) - n + 1) = suf
}

BaseName(p) {
    i := InStr(p, "\", false, -1)
    j := InStr(p, "/", false, -1)
    if (j > i)
        i := j
    return i ? SubStr(p, i + 1) : p
}

ReadStr(key, name := "") {
    try return RegRead(key, name) ""
    return ""
}

SubKeys(key) {
    out := []
    try {
        Loop Reg, key, "K"
            out.Push(A_LoopRegName)
    }
    return out
}

ValNames(key) {
    out := []
    try {
        Loop Reg, key, "V"
            out.Push(A_LoopRegName)
    }
    return out
}

SplitReg(full) {
    p := InStr(full, "\")
    if !p
        return [0, ""]
    h := SubStr(full, 1, p - 1)
    root := (h = "HKCU" || h = "HKEY_CURRENT_USER") ? 0x80000001
          : (h = "HKLM" || h = "HKEY_LOCAL_MACHINE") ? 0x80000002
          : (h = "HKCR" || h = "HKEY_CLASSES_ROOT") ? 0x80000000 : 0
    return [root, SubStr(full, p + 1)]
}

OpenReg(full) {
    t := SplitReg(full)
    if !t[1]
        return 0
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", t[1], "WStr", t[2], "UInt", 0, "UInt", 0x20019, "Ptr*", &h) != 0
        return 0
    return h
}

KeyExists(full) {
    h := OpenReg(full)
    if !h
        return false
    DllCall("advapi32\RegCloseKey", "Ptr", h)
    return true
}

ValueExists(key, name) {
    h := OpenReg(key)
    if !h
        return false
    sz := 0
    r := DllCall("advapi32\RegQueryValueExW", "Ptr", h, "WStr", name, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt*", &sz)
    DllCall("advapi32\RegCloseKey", "Ptr", h)
    return r = 0
}

FileIsThere(p) {
    if (p = "")
        return false
    a := FileExist(p)
    return a != "" && !InStr(a, "D")
}

ExtractExe(cmd) {
    t := Trim(cmd)
    if (t = "")
        return ""
    if (SubStr(t, 1, 1) = '"') {
        e := InStr(t, '"', false, 2)
        return e > 1 ? SubStr(t, 2, e - 2) : ""
    }
    p := InStr(t, " ")
    return p ? SubStr(t, 1, p - 1) : t
}

; ── 名称与可用性（全部带缓存）──────────────────────────────────────

BuildMui() {
    global S
    for p in [RK.Mui1, RK.Mui2] {
        key := "HKCU\" p
        for n in ValNames(key) {
            if (n = "" || S.mui.Has(n))
                continue
            v := ReadStr(key, n)
            if (v != "")
                S.mui[n] := v
        }
    }
}

Friendly(prog) {
    global S
    if (prog = "")
        return ""
    if S.fname.Has(prog)
        return S.fname[prog]
    base := BaseName(prog)
    result := ""
    for cand in [prog, prog ".FriendlyAppName", "Applications\" prog, base, base ".FriendlyAppName"] {
        if (cand != "" && S.mui.Has(cand)) {
            result := S.mui[cand]
            break
        }
    }
    if (result = "") {
        result := ReadStr("HKCR\" prog)
        if (result = "")
            result := ReadStr("HKCR\" prog "\Application", "ApplicationName")
    }
    S.fname[prog] := result
    return result
}

ExeOk(prog) {
    global S
    if (prog = "")
        return false
    if S.exe.Has(prog)
        return S.exe[prog]
    ok := false
    if (InStr(prog, "\") || InStr(prog, "/"))
        ok := FileIsThere(prog)
    else {
        for d in S.pathDirs {
            if FileIsThere(d "\" prog) {
                ok := true
                break
            }
        }
    }
    S.exe[prog] := ok
    return ok
}

PidOk(pid) {
    global S
    if (pid = "")
        return false
    if S.pid.Has(pid)
        return S.pid[pid]
    ok := false
    if (StrLower(SubStr(pid, 1, 4)) = "appx") {
        if KeyExists("HKCR\" pid) {
            cmd := ReadStr("HKCR\" pid "\shell\open\command")
            ok := cmd != "" && FileIsThere(ExtractExe(cmd))
        }
    } else if (StrLower(SubStr(pid, 1, 13)) = "applications\") {
        ok := ExeOk(SubStr(pid, 14))
    } else if KeyExists("HKCR\" pid) {
        cmd := ReadStr("HKCR\" pid "\shell\open\command")
        ok := cmd = "" ? true : FileIsThere(ExtractExe(cmd))
    }
    S.pid[pid] := ok
    return ok
}

; ── 条目收集 ────────────────────────────────────────────────────────

AddRow(ext, prog, fname, src, status, hive, key, val, isSub := false) {
    global S
    id := StrLower(hive "|" key "|" val "|" (isSub ? "K" : "V"))
    if S.seen.Has(id) {
        S.dupes++
        return false
    }
    S.seen[id] := true
    full := isSub ? HiveName(hive) "\" key "\" val
                  : HiveName(hive) "\" key "  [" val "]"
    S.all.Push({eid: S.nextEid++, ext: ext, prog: prog, name: fname, src: src, status: status,
                hive: hive, key: key, val: val, sub: isSub, full: full, sel: false})
    return true
}

MruRows(hive, key, ext, src) {
    for n in ValNames(hive "\" key) {
        if (n = "" || StrLower(n) = "mrulist")
            continue
        prog := ReadStr(hive "\" key, n)
        if (Trim(prog) = "")
            continue
        AddRow(ext, prog, Friendly(prog), src, ExeOk(prog) ? "Exists" : "Missing", hive, key, n)
    }
}

PidRows(hive, key, ext, src) {
    for pid in ValNames(hive "\" key) {
        if (Trim(pid) = "")
            continue
        AddRow(ext, pid, Friendly(pid), src, PidOk(pid) ? "Exists" : "Missing", hive, key, pid)
    }
}

; ── 13 个扫描来源 ───────────────────────────────────────────────────

ScanFileExts() {
    for ext in SubKeys("HKCU\" RK.FileExts) {
        if (SubStr(ext, 1, 1) != ".")
            continue
        MruRows("HKCU", RK.FileExts "\" ext "\OpenWithList", ext, "MRU List")
        PidRows("HKCU", RK.FileExts "\" ext "\OpenWithProgids", ext, "ProgId")
    }
}

ScanApps() {
    for app in SubKeys("HKCU\" RK.Apps) {
        exe := ReadStr("HKCU\" RK.Apps "\" app)
        st := "Unknown"
        if (exe != "")
            st := FileIsThere(exe) ? "Exists" : "Missing"
        else if !ExeOk(app)
            st := "Missing"
        AddRow("*", app, exe != "" ? Friendly(exe) : "", "Application", st, "HKCU", RK.Apps, app, true)
    }
}

ScanUserClasses() {
    for ext in SubKeys("HKCU\" RK.Classes) {
        if (SubStr(ext, 1, 1) != ".")
            continue
        MruRows("HKCU", RK.Classes "\" ext "\OpenWithList", ext, "MRU List")
        PidRows("HKCU", RK.Classes "\" ext "\OpenWithProgids", ext, "ProgId")
    }
}

ScanGlobalMru() => MruRows("HKCR", "*\OpenWithList", "*", "Global MRU List")
ScanGlobalProgids() => PidRows("HKCR", "*\OpenWithProgids", "*", "Global ProgId")

ScanSysAssoc() {
    for t in SubKeys("HKCR\SystemFileAssociations")
        MruRows("HKCR", "SystemFileAssociations\" t "\OpenWithList", "(系统) " t, "System MRU List")
}

ScanLmApps() {
    for base in [RK.LmApps, RK.LmApps32] {
        for app in SubKeys("HKLM\" base) {
            exe := ReadStr("HKLM\" base "\" app)
            st := exe = "" ? "Unknown" : (FileIsThere(exe) ? "Exists" : "Missing")
            AddRow("*", app, exe != "" ? Friendly(exe) : "", "Application", st, "HKLM", base, app, true)
        }
    }
}

ScanExtProgids() {
    for t in [["HKCU", RK.Classes], ["HKLM", RK.LmClasses], ["HKLM", RK.LmClasses32]] {
        for ext in SubKeys(t[1] "\" t[2]) {
            if (SubStr(ext, 1, 1) != ".")
                continue
            PidRows(t[1], t[2] "\" ext "\OpenWithProgids", ext, "ProgId")
        }
    }
}

ScanExtMru() {
    for t in [["HKCU", RK.Classes], ["HKLM", RK.LmClasses], ["HKLM", RK.LmClasses32]] {
        for ext in SubKeys(t[1] "\" t[2]) {
            if (SubStr(ext, 1, 1) != ".")
                continue
            MruRows(t[1], t[2] "\" ext "\OpenWithList", ext, "MRU List")
        }
    }
}

ScanAppPaths() {
    for base in [RK.AppPaths, RK.AppPaths32] {
        for app in SubKeys("HKLM\" base) {
            k := "HKLM\" base "\" app
            exe := ReadStr(k)
            nm := ReadStr(k, "UseApplicationName")
            if (nm = "")
                nm := Friendly(app)
            st := exe = "" ? "Unknown" : (FileIsThere(exe) ? "Exists" : "Missing")
            AddRow("*", app, nm, "App Path", st, "HKLM", base, app, true)
        }
    }
}

ScanRecent() {
    for app in SubKeys("HKCU\" RK.Recent) {
        k := "HKCU\" RK.Recent "\" app
        exe := ReadStr(k, "ExePath")
        if (exe = "")
            exe := ReadStr(k)
        nm := ReadStr(k, "DisplayName")
        if (nm = "")
            nm := Friendly(app)
        st := exe = "" ? "Unknown" : (FileIsThere(exe) ? "Exists" : "Missing")
        AddRow("*", app, nm, "Recent App", st, "HKCU", RK.Recent, app, true)
    }
}

ScanRepo() {
    for pkg in SubKeys("HKCU\" RK.Repo) {
        k := "HKCU\" RK.Repo "\" pkg
        nm := ReadStr(k, "DisplayName")
        if (nm = "")
            nm := pkg
        for ext in SubKeys(k "\AppCapabilities\FileTypeAssociation") {
            if (SubStr(ext, 1, 1) != ".")
                continue
            AddRow(ext, pkg, nm, "Store App", "Exists", "HKCU",
                   RK.Repo "\" pkg "\AppCapabilities\FileTypeAssociation", ext, true)
        }
    }
}

ScanContract() {
    for pkg in SubKeys("HKCR\" RK.Contract) {
        for cls in SubKeys("HKCR\" RK.Contract "\" pkg "\ActivatableClassId") {
            rel := RK.Contract "\" pkg "\ActivatableClassId\" cls "\SupportedFileTypes"
            for ext in ValNames("HKCR\" rel) {
                if (SubStr(ext, 1, 1) != ".")
                    continue
                AddRow(ext, pkg, cls, "Store App", "Exists", "HKCR", rel, ext)
            }
        }
    }
}

ScanProgidReg() {
    static skipPre := [".", "appx", "app_", "{", "clsid", "interface", "installer", "typelib",
                       "record", "activatableclasses", "extensions", "local settings", "wow6432node", "processor"]
    static skipExact := "|applications|systemfileassociations|allfilesystemobjects|directory|drive|folder|network|printers|exefile|cmdfile|batfile|comfile|piffile|lnkfile|regfile|vbsfile|jsfile|jsefile|wsffile|wshfile|scrfile|hlpfile|inffile|chmfile|txtfile|unknown|briefcase|cabinet|shortcut|internetshortcut|device|audiocd|dvd|"
    for sub in SubKeys("HKCU\" RK.Classes) {
        low := StrLower(sub)
        if InStr(skipExact, "|" low "|")
            continue
        skip := false
        for p in skipPre {
            if (SubStr(low, 1, StrLen(p)) = p) {
                skip := true
                break
            }
        }
        if skip
            continue
        k := "HKCU\" RK.Classes "\" sub
        cmd := ReadStr(k "\shell\open\command")
        if (cmd = "") {
            def := ReadStr(k "\shell")
            if (def != "")
                cmd := ReadStr(k "\shell\" def "\command")
        }
        if (Trim(cmd) = "")
            continue
        exe := ExtractExe(cmd)
        nm := ReadStr(k)
        if (nm = "")
            nm := Friendly(sub)
        st := exe = "" ? "Unknown" : (FileIsThere(exe) ? "Exists" : "Missing")
        AddRow("*", sub, nm, "ProgId Registration", st, "HKCU", RK.Classes, sub, true)
    }
}

ScanClients() {
    for base in [RK.Clients, RK.Clients32] {
        for c in SubKeys("HKLM\" base) {
            k := "HKLM\" base "\" c
            nm := ReadStr(k)
            if (nm = "")
                nm := c
            rel := base "\" c "\Capabilities\FileAssociations"
            for ext in ValNames("HKLM\" rel) {
                if (SubStr(ext, 1, 1) != ".")
                    continue
                pid := ReadStr("HKLM\" rel, ext)
                if (Trim(pid) = "")
                    continue
                AddRow(ext, pid, nm, "Application", PidOk(pid) ? "Exists" : "Missing", "HKLM", rel, ext)
            }
        }
    }
}

ScanSteps() => [ScanFileExts, ScanApps, ScanUserClasses, ScanGlobalMru, ScanGlobalProgids,
                ScanSysAssoc, ScanLmApps, ScanExtProgids, ScanExtMru, ScanAppPaths,
                ScanRecent, ScanRepo, ScanContract, ScanProgidReg, ScanClients]

; ── 扫描驱动（分片，保持界面可响应）────────────────────────────────

StartScan() {
    global S
    if S.scanning
        return
    InitCaches()
    S.all := [], S.view := [], S.seen := Map(), S.dupes := 0
    S.scanning := true
    S.steps := ScanSteps()
    S.step := 0
    S.t0 := Qpc()
    BuildMui()
    S.sb.SetText("正在扫描 1/" S.steps.Length " …")
    SetTimer ScanTick, 1
}

ScanTick() {
    global S
    if (S.step >= S.steps.Length) {
        SetTimer ScanTick, 0
        S.scanning := false
        S.scanMs := MsSince(S.t0)
        ApplyFilter()
        return
    }
    i := S.step + 1
    S.steps[i]()
    S.step := i
    if (i < S.steps.Length)
        S.sb.SetText("正在扫描 " (i + 1) "/" S.steps.Length " …")
}

; ── 主窗口 ──────────────────────────────────────────────────────────

BuildGui() {
    global S
    g := Gui("+Resize +MinSize800x450", "打开方式清理")
    g.SetFont("s9", "Microsoft YaHei UI")
    g.MarginX := 10, g.MarginY := 10
    S.gui := g

    g.Add("Button", "x10 y10 w60 h26", "刷新").OnEvent("Click", (*) => StartScan())
    g.Add("Button", "x+6 w60 h26", "全选").OnEvent("Click", (*) => ToggleAll())
    g.Add("Button", "x+6 w84 h26", "删除失效项").OnEvent("Click", (*) => DeleteMissing())
    g.Add("Text", "x+8 y15 w28", "搜索")
    S.search := g.Add("Edit", "x+2 y10 w250 h26")
    S.search.OnEvent("Change", (*) => SetTimer(ApplySearch, -250))
    g.Add("Button", "x+6 w72 h26", "复制路径").OnEvent("Click", (*) => CopyPath())
    g.Add("Button", "x+6 w72 h26", "删除选中").OnEvent("Click", (*) => DeleteChecked())
    g.Add("Button", "x+6 w72 h26", "历史记录").OnEvent("Click", (*) => ShowHistory())

    S.lv := g.Add("ListView", "x10 y46 w1080 h560 Checked -Grid -Multi",
                  ["✓", "扩展名", "程序 / 关联标识", "显示名称", "状态", "来源"])
    S.lv.OnEvent("ColClick", OnColClick)
    S.lv.OnEvent("DoubleClick", OnRowDouble)
    S.lv.OnEvent("ContextMenu", OnRowContext)
    S.sb := g.Add("StatusBar", , "就绪")

    g.OnEvent("Size", OnGuiSize)
    g.OnEvent("Close", (*) => ExitApp())
    g.Show("w1100 h650 Center")

    S.boldFont := MakeBoldFont(S.lv.Hwnd)
    OnMessage(0x004E, LvNotify)
    OnExit(Cleanup)
    g.GetClientPos(,, &cw, &ch)
    OnGuiSize(g, 0, cw, ch)
}

MakeBoldFont(hwnd) {
    hf := SendMessage(0x0031, 0, 0, hwnd)
    if !hf
        return 0
    lf := Buffer(92, 0)
    if !DllCall("gdi32\GetObjectW", "Ptr", hf, "Int", 92, "Ptr", lf.Ptr)
        return 0
    NumPut("Int", 700, lf, 16)
    return DllCall("gdi32\CreateFontIndirectW", "Ptr", lf.Ptr, "Ptr")
}

Cleanup(*) {
    global S, gSortCb
    if gSortCb
        CallbackFree(gSortCb)
    if S.boldFont
        DllCall("gdi32\DeleteObject", "Ptr", S.boldFont)
    if S.mutex
        DllCall("CloseHandle", "Ptr", S.mutex)
    return 0
}

OnGuiSize(g, state, w, h) {
    global S
    if (!S.lv || w < 100 || h < 100)
        return
    lvW := w - 20
    S.lv.Move(10, 46, lvW, h - 74)
    progW := lvW - 680
    if (progW < 160)
        progW := 160
    nameW := lvW - 310 - progW
    if (nameW < 200)
        nameW := 200
    S.lv.ModifyCol(1, 30)
    S.lv.ModifyCol(2, 80)
    S.lv.ModifyCol(3, progW)
    S.lv.ModifyCol(4, nameW)
    S.lv.ModifyCol(5, 70)
    S.lv.ModifyCol(6, 130)
}

LvNotify(wp, lp, msg, hwnd) {
    global S
    if (!S.lv || hwnd != S.gui.Hwnd)
        return
    if (NumGet(lp, A_PtrSize * 2, "Int") != -12)
        return
    stage := NumGet(lp, 24, "UInt")
    if (stage = 1)
        return 0x20
    if (stage = 0x10001) {
        row := NumGet(lp, 56, "UInt")
        NumPut("UInt", (row & 1) ? 0xFAF5F0 : 0xFFFFFF, lp, 84)
        return 0x20
    }
    if (stage = 0x30001) {
        if (NumGet(lp, 88, "Int") != 4)
            return 0
        row := NumGet(lp, 56, "UInt") + 1
        if (row < 1 || row > S.view.Length)
            return 0
        st := S.view[row].status
        NumPut("UInt", st = "Exists" ? 0x008000 : st = "Missing" ? 0x008CFF : 0x808080, lp, 80)
        if S.boldFont
            DllCall("gdi32\SelectObject", "Ptr", NumGet(lp, 32, "Ptr"), "Ptr", S.boldFont)
        return 2
    }
}

SetupTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("打开方式清理", (*) => S.gui.Show())
    A_TrayMenu.Add("退出", (*) => ExitApp())
    A_TrayMenu.Default := "打开方式清理"
    A_IconTip := "打开方式清理"
    ; 宿主会镜像托盘菜单；独立运行才显示自己的图标。
    if !InStr(A_AhkPath, "AHKDeck.exe")
        A_IconHidden := false
}

; ── 列表填充、筛选、排序 ────────────────────────────────────────────

SyncChecks() {
    global S
    for e in S.view
        e.sel := false
    r := 0
    while (r := S.lv.GetNext(r, "Checked"))
        S.view[r].sel := true
}

FillList() {
    global S
    top := SendMessage(0x1027, 0, 0, S.lv.Hwnd)
    foc := S.lv.GetNext(0, "Focused")
    focEntry := foc ? S.view[foc] : 0
    SendMessage(0x100B, 0, 0, S.lv.Hwnd)
    S.lv.Delete()
    for e in S.view
        S.lv.Add(e.sel ? "Check" : "", "", e.ext, e.prog, e.name, L.Status[e.status], L.Source[e.src])
    ; 每行挂稳定条目号，排序时 comctl32 原地重排靠它认行（LVIF_PARAM，iItem@4，lParam@40）。
    li := Buffer(72, 0)
    NumPut("UInt", 0x0004, li, 0)
    for i, e in S.view {
        NumPut("Int", i - 1, li, 4)
        NumPut("Int64", e.eid, li, 40)
        SendMessage(0x104C, 0, li.Ptr, S.lv.Hwnd)
    }
    SendMessage(0x100B, 1, 0, S.lv.Hwnd)
    if (top > 0 && top < S.view.Length)
        SendMessage(0x1013, top, 0, S.lv.Hwnd)
    if focEntry {
        for i, e in S.view {
            if (e = focEntry) {
                S.lv.Modify(i, "Focus")
                break
            }
        }
    }
    S.lv.Redraw()
    UpdateStatus()
}

ApplySearch() {
    SyncChecks()
    ApplyFilter()
}

ApplyFilter() {
    global S
    q := Trim(S.search.Value)
    if (q = "")
        S.view := S.all.Clone()
    else {
        ql := StrLower(q)
        S.view := []
        for e in S.all {
            if InStr(StrLower(e.ext), ql) || InStr(StrLower(e.prog), ql) || InStr(StrLower(e.name), ql)
                || InStr(StrLower(L.Source[e.src]), ql) || InStr(StrLower(e.full), ql)
                || InStr(StrLower(L.Status[e.status]), ql)
                S.view.Push(e)
        }
    }
    if S.sortCol
        SortView()
    FillList()
}

SortView() {
    global S
    c := S.sortCol
    buf := ""
    for i, e in S.view {
        v := c = 1 ? (e.sel ? "1" : "0")
           : c = 2 ? e.ext
           : c = 3 ? e.prog
           : c = 4 ? e.name
           : c = 5 ? L.Status[e.status] : L.Source[e.src]
        buf .= v "`t" i "`n"
    }
    buf := Sort(buf, S.sortDesc ? "R" : "")
    out := []
    for line in StrSplit(buf, "`n") {
        if (line = "")
            continue
        p := InStr(line, "`t")
        if p
            out.Push(S.view[Integer(SubStr(line, p + 1))])
    }
    if (out.Length = S.view.Length)
        S.view := out
}

OnColClick(ctrl, col) {
    global S
    if (col = S.sortCol)
        S.sortDesc := !S.sortDesc
    else
        S.sortCol := col, S.sortDesc := false
    SyncChecks()
    SortView()
    SortListInPlace()
    UpdateStatus()
}

; 排序口径仍由 SortView（AHK Sort）给出；这里只把目标名次交给 comctl32 原地重排，
; 不删行不重建，勾选/焦点随行移动。LVM_SORTITEMS 回调收到的是两行的 lParam（条目号）。
SortCmp(lp1, lp2, sp) {
    global gSortRank
    return gSortRank[lp1] - gSortRank[lp2]
}

SortListInPlace() {
    global S, gSortRank, gSortCb
    gSortRank := Map()
    for i, e in S.view
        gSortRank[e.eid] := i
    if !gSortCb
        gSortCb := CallbackCreate(SortCmp, "F", 3)
    SendMessage(0x1030, 0, gSortCb, S.lv.Hwnd)
}

UpdateStatus() {
    global S
    if !S.all.Length {
        S.sb.SetText(S.scanning ? "正在扫描…" : "就绪")
        return
    }
    exts := Map(), missing := 0
    for e in S.view {
        exts[e.ext] := true
        if (e.status = "Missing")
            missing++
    }
    checked := 0, r := 0
    while (r := S.lv.GetNext(r, "Checked"))
        checked++
    filtered := S.view.Length != S.all.Length
    txt := filtered ? "显示 " S.view.Length " / " S.all.Length "，" exts.Count " 种扩展名"
                    : "共 " S.view.Length " 个条目，" exts.Count " 种扩展名"
    if (missing && !filtered)
        txt .= " | " missing " 个失效"
    if checked
        txt .= " | ☑ " checked
    S.sb.SetText(txt)
}

ToggleAll() {
    global S
    SyncChecks()
    allOn := S.view.Length > 0
    for e in S.view {
        if !e.sel {
            allOn := false
            break
        }
    }
    newState := !allOn
    for i, e in S.view {
        e.sel := newState
        S.lv.Modify(i, newState ? "Check" : "Check0")
    }
    UpdateStatus()
}

FocusedRow() {
    global S
    return S.lv.GetNext(0, "Focused")
}

CopyPath(*) {
    global S
    r := FocusedRow()
    if !r {
        Flash("先选中一行")
        return
    }
    A_Clipboard := S.view[r].full
    Flash("已复制路径到剪贴板")
}

OnRowDouble(ctrl, row) {
    global S
    if !row
        return
    A_Clipboard := S.view[row].full
    Flash("已复制路径到剪贴板")
}

OnRowContext(ctrl, row, isRight, x, y) {
    global S
    if !row
        return
    m := Menu()
    m.Add("复制注册表路径", (*) => (A_Clipboard := S.view[row].full, Flash("已复制路径到剪贴板")))
    m.Add("复制程序名", (*) => (A_Clipboard := S.view[row].prog, Flash("已复制程序名")))
    m.Add()
    m.Add("删除这一条", (*) => DeleteOne(row))
    m.Show(x, y)
}

DeleteOne(row) {
    global S
    e := S.view[row]
    if (MsgBox("确定删除这一条？`n`n" e.full, "删除确认", "YesNo Icon!") != "Yes")
        return
    Backup([e])
    ok := DeleteEntry(e)
    MsgBox ok ? "已删除 1 个条目。" : "删除失败，可能需要管理员权限。", "删除结果", ok ? "Iconi" : "Icon!"
    StartScan()
}

Flash(text) {
    ToolTip text
    SetTimer(() => ToolTip(), -1500)
}

; ── 删除、备份、提权 ────────────────────────────────────────────────

DeleteChecked() {
    global S
    SyncChecks()
    targets := []
    for e in S.view
        if e.sel
            targets.Push(e)
    if !targets.Length {
        MsgBox "未勾选任何项目。`n请勾选要删除的条目。", "打开方式清理", "Iconi"
        return
    }
    ConfirmAndDelete(targets)
}

DeleteMissing() {
    global S
    targets := []
    for e in S.all
        if (e.status = "Missing")
            targets.Push(e)
    if !targets.Length {
        MsgBox "未发现失效条目。", "打开方式清理", "Iconi"
        return
    }
    ConfirmAndDelete(targets)
}

ConfirmAndDelete(targets) {
    n := targets.Length
    msg := "确定删除 " n " 个条目？`n`n这将从右键菜单「打开方式」中移除。`n如果再次使用这些程序，Windows 可能重新创建。"
    if (MsgBox(msg, "删除确认", "YesNo Icon!") != "Yes")
        return
    Backup(targets)
    ok := 0, fail := 0, gone := Map()
    for e in targets {
        if DeleteEntry(e) {
            ok++
            gone[e.full] := true
        } else
            fail++
    }
    if gone.Count
        DropRows(gone)
    sum := "已删除 " ok " 个条目。"
    if fail {
        sum .= " " fail " 个失败。`n" fail " 个条目需要管理员权限。"
        MsgBox sum, "删除结果", "Icon!"
        if (MsgBox("是否以管理员身份重新运行本脚本，继续删除剩下的条目？", "删除结果", "YesNo Icon?") = "Yes")
            Elevate()
    } else
        MsgBox sum, "删除结果", "Iconi"
}

; 删除成功后原地摘行：不重扫、不整表重建，滚动位置尽量不动。
DropRows(gone) {
    global S
    SyncChecks()
    foc := S.lv.GetNext(0, "Focused")
    focEntry := foc ? S.view[foc] : 0
    SendMessage(0x100B, 0, 0, S.lv.Hwnd)
    i := S.view.Length
    while i >= 1 {
        if gone.Has(S.view[i].full)
            S.lv.Delete(i)
        i--
    }
    SendMessage(0x100B, 1, 0, S.lv.Hwnd)
    keep := []
    for e in S.all
        if !gone.Has(e.full)
            keep.Push(e)
    S.all := keep
    keepV := []
    for e in S.view
        if !gone.Has(e.full)
            keepV.Push(e)
    S.view := keepV
    if focEntry {
        for i, e in S.view {
            if (e = focEntry) {
                S.lv.Modify(i, "Focus")
                break
            }
        }
    }
    S.lv.Redraw()
    UpdateStatus()
}

DeleteEntry(e) {
    targets := e.hive = "HKCR"
        ? [["HKCU", "Software\Classes\" e.key], ["HKLM", "SOFTWARE\Classes\" e.key]]
        : [[e.hive, e.key]]
    done := false
    for t in targets {
        key := t[1] "\" t[2]
        if e.sub {
            if !KeyExists(key "\" e.val)
                continue
            try {
                RegDeleteKey(key "\" e.val)
                done := true
            }
        } else {
            if !ValueExists(key, e.val)
                continue
            try {
                RegDelete(key, e.val)
                done := true
                if EndsWith(t[2], "OpenWithList")
                    CleanupMru(key)
            }
        }
    }
    return done
}

CleanupMru(key) {
    rem := []
    for n in ValNames(key)
        if (n != "" && StrLower(n) != "mrulist")
            rem.Push(n)
    if !rem.Length {
        try RegWrite("", "REG_SZ", key, "MRUList")
        return
    }
    neu := ""
    for ch in StrSplit(ReadStr(key, "MRUList")) {
        for n in rem {
            if (n = ch) {
                neu .= ch
                break
            }
        }
    }
    try RegWrite(neu, "REG_SZ", key, "MRUList")
}

Backup(targets) {
    try DirCreate(HistDir())
    txt := ""
    for i, e in targets {
        txt .= "[" i "] Hive=" HiveToken(e.hive) "`tKey=" e.key "`tValue=" e.val
             . "`tType=" (e.sub ? "SubKey" : "Value") "`tProgram=" e.prog
             . "`tExt=" e.ext "`tFullPath=" e.full "`n"
    }
    try FileAppend(txt, HistDir() "\backup_" FormatTime(, "yyyyMMdd_HHmmss") ".txt", "UTF-8")
}

Elevate() {
    exe := A_AhkPath
    cmd := InStr(exe, "AHKDeck.exe")
        ? '"' exe '" --run "' A_ScriptFullPath '"'
        : '"' exe '" "' A_ScriptFullPath '"'
    try Run("*RunAs " cmd)
    catch {
        MsgBox "以管理员身份运行被取消或失败。", "删除结果", "Icon!"
        return
    }
    ExitApp
}

; ── 历史与恢复 ──────────────────────────────────────────────────────

ShowHistory() {
    global S
    if S.histGui {
        S.histGui.Show()
        return
    }
    try DirCreate(HistDir())
    files := []
    Loop Files, HistDir() "\*.txt"
        files.Push(A_LoopFileFullPath)
    files := SortArrayDesc(files)
    S.histFiles := files

    g := Gui("+Owner" S.gui.Hwnd " -MaximizeBox -MinimizeBox", "删除历史与恢复")
    g.SetFont("s9", "Microsoft YaHei UI")
    g.MarginX := 10, g.MarginY := 10
    S.histGui := g
    S.histList := g.Add("ListBox", "x10 y10 w596 h330")
    for f in files {
        t := FormatTime(FileGetTime(f, "C"), "yyyy-MM-dd HH:mm:ss")
        n := 0
        try {
            for ln in StrSplit(FileRead(f, "UTF-8"), "`n", "`r")
                if (Trim(ln) != "")
                    n++
        }
        S.histList.Add([t "  (" n " 条)"])
    }
    S.histView := g.Add("Button", "x330 y352 w80 h28", "查看")
    S.histRestore := g.Add("Button", "x+8 w80 h28", "恢复")
    g.Add("Button", "x+8 w80 h28", "关闭").OnEvent("Click", (*) => CloseHistory())
    S.histView.OnEvent("Click", (*) => ViewHistory())
    S.histRestore.OnEvent("Click", (*) => RestoreHistory())
    S.histList.OnEvent("Change", (*) => SyncHistButtons())
    g.OnEvent("Close", (*) => CloseHistory())
    g.OnEvent("Escape", (*) => CloseHistory())
    SyncHistButtons()
    g.Show("w616 h390 Center")
}

CloseHistory() {
    global S
    if !S.histGui
        return
    S.histGui.Destroy()
    S.histGui := 0
    if S.histDirty {
        S.histDirty := false
        StartScan()
    }
}

SortArrayDesc(arr) {
    buf := ""
    for i, v in arr
        buf .= v "`t" i "`n"
    buf := Sort(buf, "R")
    out := []
    for line in StrSplit(buf, "`n") {
        p := InStr(line, "`t")
        if p
            out.Push(arr[Integer(SubStr(line, p + 1))])
    }
    return out.Length = arr.Length ? out : arr
}

SyncHistButtons() {
    global S
    has := S.histList.Value > 0
    S.histView.Enabled := has
    S.histRestore.Enabled := has
}

ViewHistory() {
    global S
    i := S.histList.Value
    if !i
        return
    try Run('notepad.exe "' S.histFiles[i] '"')
}

RestoreHistory() {
    global S
    i := S.histList.Value
    if !i
        return
    f := S.histFiles[i]
    msg := "确定恢复所选备份？`n`n将尝试把备份中的所有条目重新写入注册表。`n注意：如果原始程序已卸载，恢复的条目可能无效。"
    if (MsgBox(msg, "恢复", "YesNo Icon!") != "Yes")
        return
    ok := 0, fail := 0
    try {
        for line in StrSplit(FileRead(f, "UTF-8"), "`n", "`r") {
            if (Trim(line) = "")
                continue
            if RestoreLine(line)
                ok++
            else
                fail++
        }
    } catch as err {
        MsgBox "恢复失败：" err.Message, "删除历史与恢复", "Iconx"
        return
    }
    MsgBox "已恢复 " ok " 个条目。" (fail ? "`n" fail " 个失败。" : ""), "删除历史与恢复", fail ? "Icon!" : "Iconi"
    S.histDirty := ok > 0
    CloseHistory()
}

RestoreLine(line) {
    if (SubStr(line, 1, 1) = "[") {
        p := InStr(line, "]")
        if (p > 0)
            line := LTrim(SubStr(line, p + 1))
    }
    parts := StrSplit(line, "`t")
    if (parts.Length < 3)
        return false
    hive := "", key := "", val := "", type := "Value", prog := ""
    for p in parts {
        if (SubStr(p, 1, 5) = "Hive=")
            hive := SubStr(p, 6)
        else if (SubStr(p, 1, 4) = "Key=")
            key := SubStr(p, 5)
        else if (SubStr(p, 1, 6) = "Value=")
            val := SubStr(p, 7)
        else if (SubStr(p, 1, 5) = "Type=")
            type := SubStr(p, 6)
        else if (SubStr(p, 1, 8) = "Program=")
            prog := SubStr(p, 9)
    }
    if (key = "" || val = "")
        return false
    root := hive = "CurrentUser" ? "HKCU" : hive = "LocalMachine" ? "HKLM" : hive = "ClassesRoot" ? "HKCR" : ""
    if (root = "")
        return false
    try {
        if (type = "SubKey") {
            if (prog != "")
                RegWrite(prog, "REG_SZ", root "\" key "\" val)
            else
                RegCreateKey(root "\" key "\" val)
        } else
            RegWrite(prog, "REG_SZ", root "\" key, val)
        return true
    }
    return false
}

; ── 合成键自测：--selftest [输出路径]（只动自建键，结束即清理） ───────

RunSelfTest(path) {
    out := ""
    Emit(s) => out .= s "`n"
    base := "Software\Classes\AHKDeckOwcSelfTest"
    hk := "HKCU\" base
    if KeyExists(hk) {
        FileAppend("FAIL 合成键已存在，放弃自测以免覆盖未知状态`n", path, "UTF-8")
        ExitApp(1)
    }
    RegWrite("notepad.exe", "REG_SZ", hk "\OpenWithList", "a")
    RegWrite("mspaint.exe", "REG_SZ", hk "\OpenWithList", "b")
    RegWrite("ab", "REG_SZ", hk "\OpenWithList", "MRUList")
    RegWrite("selftest-prog", "REG_SZ", hk "\SomeProgId")
    RegWrite("deep", "REG_SZ", hk "\SomeProgId\Deep")
    e1 := {hive: "HKCU", key: base "\OpenWithList", val: "a", sub: false, prog: "notepad.exe", ext: ".txt", full: ""}
    e2 := {hive: "HKCU", key: base, val: "SomeProgId", sub: true, prog: "selftest-prog", ext: "*", full: ""}
    e3 := {hive: "HKCR", key: "AHKDeckOwcSelfTest\OpenWithList", val: "b", sub: false, prog: "mspaint.exe", ext: ".txt", full: ""}

    Backup([e1, e2, e3])
    bf := "", bt := 0
    Loop Files HistDir() "\backup_*.txt" {
        if (A_LoopFileTimeModified > bt)
            bt := A_LoopFileTimeModified, bf := A_LoopFileFullPath
    }
    Emit((bf != "" ? "PASS " : "FAIL ") "备份文件已生成")
    lines := bf != "" ? StrSplit(FileRead(bf, "UTF-8"), "`n", "`r") : []

    Emit((DeleteEntry(e1) ? "PASS " : "FAIL ") "删除 HKCU 值 a")
    Emit((!ValueExists(hk "\OpenWithList", "a") ? "PASS " : "FAIL ") "值 a 已消失")
    Emit((ReadStr(hk "\OpenWithList", "MRUList") = "b" ? "PASS " : "FAIL ") "MRUList 收缩为 b")
    Emit((DeleteEntry(e3) ? "PASS " : "FAIL ") "HKCR 映射删除值 b")
    Emit((!ValueExists(hk "\OpenWithList", "b") ? "PASS " : "FAIL ") "值 b 已消失")
    Emit((ReadStr(hk "\OpenWithList", "MRUList") = "" ? "PASS " : "FAIL ") "MRUList 清空")
    Emit((DeleteEntry(e2) ? "PASS " : "FAIL ") "删除子键 SomeProgId")
    Emit((!KeyExists(hk "\SomeProgId\Deep") ? "PASS " : "FAIL ") "子键树递归删除")

    n := 0
    for ln in lines
        if (ln != "")
            n++
    ok := n = 3
    for ln in lines
        if (ln != "" && !RestoreLine(ln))
            ok := false
    Emit((ok ? "PASS " : "FAIL ") "三条备份行全部恢复")
    Emit((ReadStr(hk "\OpenWithList", "a") = "notepad.exe" ? "PASS " : "FAIL ") "恢复值 a 数据")
    Emit((ReadStr(hk "\OpenWithList", "b") = "mspaint.exe" ? "PASS " : "FAIL ") "恢复值 b 数据（经 HKCR）")
    Emit((ReadStr(hk "\SomeProgId") = "selftest-prog" ? "PASS " : "FAIL ") "恢复子键默认值")

    ; DropRows 原地摘行（隐藏列表，不碰注册表）
    S.all := [], S.view := [], S.seen := Map()
    g2 := Gui("+ToolWindow", "selftest-lv")
    S.lv := g2.Add("ListView", "w400 h200 Checked", ["✓", "扩展名", "程序", "名称", "状态", "来源"])
    S.sb := g2.Add("StatusBar", , "")
    g2.Show("Hide")
    AddRow(".t1", "p1", "", "ProgId", "Exists", "HKCU", base, "a")
    AddRow(".t2", "p2", "", "ProgId", "Missing", "HKCU", base, "b")
    AddRow(".t3", "p3", "", "ProgId", "Exists", "HKCU", base, "c")
    S.view := S.all.Clone()
    FillList()
    DropRows(Map(S.all[2].full, true))
    Emit((S.lv.GetCount() = 2 && S.all.Length = 2 && S.view.Length = 2 ? "PASS " : "FAIL ") "DropRows 原地摘行")
    Emit((S.view[1].ext = ".t1" && S.view[2].ext = ".t3" ? "PASS " : "FAIL ") "DropRows 保留顺序")
    ; 原地排序（LVM_SORTITEMS）：顺序、勾选、焦点都随行移动
    AddRow(".t0", "p4", "", "ProgId", "Exists", "HKCU", base, "d")
    AddRow(".t4", "p5", "", "ProgId", "Missing", "HKCU", base, "e")
    AddRow(".t2x", "p6", "", "ProgId", "Exists", "HKCU", base, "f")
    S.view := S.all.Clone()
    FillList()
    S.lv.Modify(2, "Check")
    S.lv.Modify(1, "Focus")
    S.sortCol := 2, S.sortDesc := false
    SyncChecks()
    SortView()
    SortListInPlace()
    ord := ""
    Loop S.lv.GetCount()
        ord .= S.lv.GetText(A_Index, 2) ","
    Emit((ord = ".t0,.t1,.t2x,.t3,.t4," && S.view.Length = 5 ? "PASS " : "FAIL ") "排序原地重排")
    cr := S.lv.GetNext(0, "Checked")
    Emit((cr && S.lv.GetText(cr, 2) = ".t3" ? "PASS " : "FAIL ") "排序勾选随行")
    fr := S.lv.GetNext(0, "Focused")
    Emit((fr && S.lv.GetText(fr, 2) = ".t1" ? "PASS " : "FAIL ") "排序焦点随行")
    g2.Destroy()
    S.lv := 0, S.sb := 0

    try RegDeleteKey(hk)
    Emit((!KeyExists(hk) ? "PASS " : "FAIL ") "合成键清理")
    if (bf != "")
        try FileDelete(bf)
    fails := 0
    for ln in StrSplit(out, "`n")
        if (SubStr(ln, 1, 5) = "FAIL ")
            fails++
    Emit("fails=" fails)
    try DirCreate(SubStr(path, 1, InStr(path, "\", false, -1) - 1))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

; ── 只读自测：--report [输出路径] ───────────────────────────────────

RunReport(path) {
    global S
    InitCaches()
    out := ""
    Emit(s) => out .= s "`n"

    tg := Gui(), ed := tg.Add("Edit", "w200"), tg.Show("Hide")
    r := SendMessage(0x1501, 1, StrPtr("搜索"), ed.Hwnd)
    Emit("cue_banner_ret=" r " err=" A_LastError)
    tg.Destroy()

    Emit("ahk=" A_AhkVersion " ptr=" A_PtrSize " admin=" A_IsAdmin " dpi=" A_ScreenDPI)
    Emit("scriptdir_is_build=" (InStr(A_ScriptDir, ".build") ? "yes" : "no"))

    t0 := Qpc()
    BuildMui()
    Emit("muicache_entries=" S.mui.Count " ms=" Round(MsSince(t0), 2))

    steps := ScanSteps()
    total := 0
    for i, f in steps {
        a := Qpc()
        before := S.all.Length
        f()
        added := S.all.Length - before
        total += added
        Emit("step" i " " f.Name " rows=" added " ms=" Round(MsSince(a), 2))
    }
    Emit("rows_total=" S.all.Length " dedup_removed=" S.dupes " scan_ms=" Round(MsSince(t0), 2))

    exts := Map(), st := Map("Exists", 0, "Missing", 0, "Unknown", 0), named := 0
    for e in S.all {
        exts[e.ext] := true
        st[e.status]++
        if (e.name != "")
            named++
    }
    Emit("ext_kinds=" exts.Count " exists=" st["Exists"] " missing=" st["Missing"] " unknown=" st["Unknown"])
    Emit("friendly_resolved=" named " cache_exe=" S.exe.Count " cache_pid=" S.pid.Count " cache_name=" S.fname.Count)

    a := Qpc()
    g := Gui("+ToolWindow", "report")
    lv := g.Add("ListView", "w900 h400 Checked -Grid", ["✓", "扩展名", "程序", "名称", "状态", "来源"])
    g.Show("Hide")
    for e in S.all
        lv.Add("", "", e.ext, e.prog, e.name, L.Status[e.status], L.Source[e.src])
    Emit("listview_fill_rows=" S.all.Length " ms=" Round(MsSince(a), 2))
    g.Destroy()

    try DirCreate(SubStr(path, 1, InStr(path, "\", false, -1) - 1))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
}

#HotIf S.gui && S.lv && WinActive("ahk_id " S.gui.Hwnd) && S.gui.FocusedCtrl && S.gui.FocusedCtrl.Hwnd = S.lv.Hwnd
Delete::DeleteChecked()
#HotIf