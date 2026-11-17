; ==UserScript==
; @name         文件解锁
; @id           file-unlock
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.0
; @description  检测文件或文件夹被哪个进程占用，列出占用者，可手动结束进程解锁
; @author       邱宗满
; @date         2026-11-17
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口「检测占用」或拖入文件/文件夹；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 文件解锁：找出占用文件/文件夹的进程，列出供用户确认后结束，从而解除占用。
; 形态：以 GUI 窗口为唯一入口，不注册托盘菜单、不设全局热键；独立运行直接弹窗，
; 窗口关闭即退出。许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
;
; 技术路线（2026-11-17 本机 Win11 build 26200 实测，详见 info/HISTORY.md）：
;  - 占用检测：CreateFileW 以 DELETE(0x10000)+全共享(7) 试探开，被占用返回
;    INVALID_HANDLE_VALUE 且 GetLastError=32(共享冲突)/33(字节锁)。
;  - 找占用者：NtQueryInformationFile 的 FileProcessIdsUsingFileInformation(47)
;    一次调用直接返回"正在使用该文件的进程 PID 列表"——无需管理员、无需遍历
;    全系统句柄、瞬间完成。结构体 = ULONG count + 4字节pad + ULONG_PTR PID[]（x64）。
;    实测：holder 占用文件时返回其 PID；count=0 表示无进程占用。
;    走过的弯路（都已证伪，别重走）：Restart Manager 在本机 session 句柄恒 0、
;    RmGetList 挂起；全系统句柄枚举逐个 dup 路径要 90s+；句柄表 Object 字段
;    Win8+ 恒为 0 无法比对。FPIF 才是正解。
;  - 解锁动作：只对用户勾选的进程调用 TerminateProcess，且经系统关键进程保护名单
;    拦截 + 二次确认。绝不自动杀、绝不杀自身。exe 主模块占用无解（卸映射=杀进程）。
;  - 零外部 exe、零注册表写入、零网络。运行时产物只写 A_ScriptDir\文件解锁\。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ── 常量 ──────────────────────────────────────────────────────────────
FILE_SHARE_ALL := 0x1 | 0x2 | 0x4
DELETE_ACCESS := 0x10000
READ_ATTR := 0x80
INVALID_HANDLE_VALUE := -1
ERROR_SHARING_VIOLATION := 32
ERROR_LOCK_VIOLATION := 33
ERROR_ACCESS_DENIED := 5
PROCESS_QUERY_LIMITED_INFO := 0x1000
PROCESS_TERMINATE := 0x1
FILE_PROCESS_IDS_USING_FILE := 47

; 系统关键进程保护名单（小写文件名）：结束它们会导致系统不稳定。
CRITICAL_PROCS := Map("smss.exe", 1, "csrss.exe", 1, "wininit.exe", 1, "winlogon.exe", 1
    , "services.exe", 1, "lsass.exe", 1, "lsaiso.exe", 1, "fontdrvhost.exe", 1
    , "dwm.exe", 1, "sihost.exe", 1, "svchost.exe", 1, "audiodg.exe", 1
    , "conhost.exe", 1, "explorer.exe", 1, "System", 1, "Registry", 1)

gGui := 0, gTargetEdit := 0, gInfo := 0, gList := 0, gStatus := 0
gOwners := []          ; 当前列表对应 [{pid,name,files}]，供"结束选中"取用

; ── 占用检测：DELETE+全共享试探开 ──────────────────────────────────────
IsLocked(path) {
    h := DllCall("kernel32\CreateFileW", "Str", path, "UInt", DELETE_ACCESS
        , "UInt", FILE_SHARE_ALL, "Ptr", 0, "UInt", 3   ; OPEN_EXISTING
        , "UInt", 0x80, "Ptr", 0, "Ptr")
    if (h != INVALID_HANDLE_VALUE && h != 0) {
        DllCall("kernel32\CloseHandle", "Ptr", h)
        return ""
    }
    e := A_LastError
    if (e = ERROR_SHARING_VIOLATION)
        return "共享冲突(32)"
    if (e = ERROR_LOCK_VIOLATION)
        return "字节锁(33)"
    if (e = ERROR_ACCESS_DENIED)
        return "拒绝访问(5)"
    return "无法打开(" e ")"
}

; ── 找占用者：NtQueryInformationFile(FileProcessIdsUsingFileInformation) ─
; 返回 PID 数组（可能为空）。打开文件 → 查询 → 读 count + PID[]。
FindOwners(path) {
    pids := []
    h := DllCall("kernel32\CreateFileW", "Str", path, "UInt", READ_ATTR
        , "UInt", FILE_SHARE_ALL, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
    if (h = INVALID_HANDLE_VALUE || h = 0)
        return pids
    try {
        iosb := Buffer(16, 0)                 ; IO_STATUS_BLOCK: status(4)+pad(4)+info(8)
        buf := Buffer(8192, 0)                ; 容纳较多 PID（每个 8 字节）
        st := DllCall("ntdll\NtQueryInformationFile", "Ptr", h, "Ptr", iosb
            , "Ptr", buf, "UInt", buf.Size, "UInt", FILE_PROCESS_IDS_USING_FILE, "UInt")
        if ((st & 0xFFFFFFFF) = 0) {
            cnt := NumGet(buf, 0, "UInt")
            if (cnt > 0 && cnt < 1000) {
                Loop cnt {
                    pid := NumGet(buf, 8 + (A_Index - 1) * 8, "UInt64")  ; count(4)+pad(4) 后是 PID[]（x64）
                    if (pid > 0)
                        pids.Push(pid)
                }
            }
        }
    } finally
        DllCall("kernel32\CloseHandle", "Ptr", h)
    return pids
}

; ── 进程名（QueryFullProcessImageNameW）────────────────────────────────
ProcName(pid) {
    h := DllCall("kernel32\OpenProcess", "UInt", PROCESS_QUERY_LIMITED_INFO, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return "(无法打开进程)"
    buf := Buffer(520, 0)
    len := Buffer(4, 0)
    NumPut("UInt", 260, len, 0)
    ok := DllCall("kernel32\QueryFullProcessImageNameW", "Ptr", h, "UInt", 0
        , "Ptr", buf, "Ptr", len, "Int")
    DllCall("kernel32\CloseHandle", "Ptr", h)
    if (!ok)
        return "(无法确定进程)"
    full := StrGet(buf, NumGet(len, 0, "UInt"), "UTF-16")
    SplitPath full, &name
    return name
}

; ── 结束进程（带保护名单）──────────────────────────────────────────────
KillProcess(pid, name) {
    myPid := DllCall("kernel32\GetCurrentProcessId", "UInt")
    if (pid = myPid)
        return "拒绝：不能结束自身"
    if (CRITICAL_PROCS.Has(StrLower(name)) || CRITICAL_PROCS.Has(name))
        return "拒绝：系统关键进程"
    h := DllCall("kernel32\OpenProcess", "UInt", PROCESS_TERMINATE, "Int", 0, "UInt", pid, "Ptr")
    if !h
        return "拒绝：无法打开进程（权限不足或已退出）"
    ok := DllCall("kernel32\TerminateProcess", "Ptr", h, "UInt", 1, "Int")
    DllCall("kernel32\CloseHandle", "Ptr", h)
    return ok ? "已结束" : "失败：TerminateProcess 返回 0"
}

; ── 递归收集文件夹下的文件 ──────────────────────────────────────────────
CollectFiles(path, out, depth := 0) {
    if (depth > 32)
        return
    if FileExist(path) = "D" {
        Loop Files path "\*", "F"
            out.Push(A_LoopFilePath)
        Loop Files path "\*", "D"
            CollectFiles(A_LoopFilePath, out, depth + 1)
    } else if FileExist(path) {
        out.Push(path)
    }
}

; ── DWM caption 染色（令牌色，照范本）───────────────────────────────────
PaintCaption() {
    global gGui
    c := Buffer(4, 0)
    NumPut("UInt", 0x00F7E8DC, c)      ; #DCE8F7 COLORREF
    t := Buffer(4, 0)
    NumPut("UInt", 0x3A2B20, t)        ; #202B3A
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

SetEditRect(hwnd, left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0)
    NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8)
    NumPut("Int", bottom, rc, 12)
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0xB3, "Ptr", 0, "Ptr", rc, "Ptr")
}

; 1px 描边按钮（范本同名函数）
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

; ── GUI ────────────────────────────────────────────────────────────────
; 版式照 UI规范 §10：客户区 672×330，内容行 x16 w640；同排控件同 y 同 h，
; 文字控件固定高 +0x200 垂直居中；列表区整体框（父块露 1px 线），
; caption 由 DWM 染成与状态条同一个 #DCE8F7。坐标按 §10.3.1 规则自算。
BuildGui() {
    global gGui, gTargetEdit, gInfo, gList, gStatus
    gGui := Gui("", "文件解锁")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())
    gGui.OnEvent("DropFiles", OnDropFiles)

    ; 输入行：输入框 456 + 8 + 84 + 8 + 84 = 640
    gGui.Add("Text", "x16 y12 w456 h28 BackgroundB7C8E0")
    gTargetEdit := gGui.Add("Edit", "x17 y13 w454 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(gTargetEdit.Hwnd, 8, 2, 448, 26)
    FlatButton(gGui, 480, 12, 84, 28, "选择路径", "EBF2FB", "B7C8E0", PickPath)
    FlatButton(gGui, 572, 12, 84, 28, "检测占用", "EBF2FB", "B7C8E0", (*) => Detect())

    gInfo := gGui.Add("Text", "x16 y48 w640 h24 BackgroundF7F9FC c202B3A +0x200", "未选择文件或文件夹")

    ; 列表区整体框：外框 y78 h180，标题带与列表内缩 1px
    gGui.Add("Text", "x16 y78 w640 h180 BackgroundB7C8E0")
    gGui.Add("Text", "x17 y79 w638 h26 BackgroundDCE8F7")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x23 y79 w292 h26 BackgroundDCE8F7 c202B3A +0x200", "进程名")
    gGui.Add("Text", "x321 y79 w112 h26 BackgroundDCE8F7 c202B3A +0x200", "PID")
    gGui.Add("Text", "x439 y79 w216 h26 BackgroundDCE8F7 c202B3A +0x200", "占用文件")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")
    gList := gGui.Add("ListView", "x17 y105 w638 h152 -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["进程名", "PID", "占用文件"])
    gList.ModifyCol(1, 298), gList.ModifyCol(2, 118), gList.ModifyCol(3, 222)

    ; 操作行：结束选中进程（右对齐，宽 140）
    FlatButton(gGui, 460, 266, 140, 28, "结束选中进程", "EBF2FB", "B7C8E0", (*) => KillSelected())

    ; 状态条
    gGui.Add("Text", "x0 y300 w672 h30 BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y300 w648 h30 BackgroundDCE8F7 c202B3A +0x200", "就绪")

    gGui.Show("w672 h330 Center")
    PaintCaption()
}

PickPath(*) {
    global gTargetEdit
    p := ""
    if FileSelect(&p, "MFD", , "选择文件或文件夹")   ; 四参形式，标题放最后（范本坑）
        gTargetEdit.Value := p
}

OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global gTargetEdit
    if files.Length
        gTargetEdit.Value := files[1]
}

Detect() {
    global gTargetEdit, gInfo, gList, gStatus, gOwners
    target := Trim(gTargetEdit.Value, " `t")
    if !target || !FileExist(target) {
        gInfo.Value := "路径不存在：" target
        gStatus.Value := "失败 · 路径无效"
        return
    }
    files := []
    CollectFiles(target, files)
    if !files.Length {
        gInfo.Value := "未找到任何文件"
        gStatus.Value := "失败 · 空目录"
        return
    }

    gStatus.Value := "检测中 · " files.Length " 个路径…"
    ; pid → 该文件集合；再统计被占用文件数
    ownerMap := Map()
    lockedCount := 0
    for f in files {
        if (IsLocked(f) = "")
            continue
        lockedCount++
        for pid in FindOwners(f) {
            if !ownerMap.Has(pid)
                ownerMap[pid] := Map()
            ownerMap[pid][f] := 1
        }
    }

    gList.Delete()
    gOwners := []
    for pid, fileMap in ownerMap {
        nm := ProcName(pid)
        names := ""
        for f in fileMap
            names .= (names ? ", " : "") ShortName(f)
        gList.Add("", nm, pid, names)
        gOwners.Push({ pid: pid, name: nm, files: names })
    }
    gInfo.Value := ShortName(target) " · " files.Length " 个文件，" lockedCount " 个被占用"
    if (lockedCount = 0)
        gStatus.Value := "完成 · 未发现占用"
    else if (ownerMap.Count = 0)
        gStatus.Value := "完成 · " lockedCount " 个被占用，但未识别占用进程"
    else
        gStatus.Value := "完成 · " ownerMap.Count " 个占用进程"
}

KillSelected() {
    global gList, gOwners, gStatus
    r := gList.GetNext(0, "F")
    if !r
        r := gList.GetNext(0)
    if !r || r > gOwners.Length {
        gStatus.Value := "未选中占用进程"
        return
    }
    o := gOwners[r]
    if MsgBox("确定结束进程 " o.name "（PID " o.pid "）？`n`n占用文件：" o.files "`n`n"
            . "未保存的数据可能丢失；系统关键进程会被自动拒绝。", "文件解锁 · 确认", 0x4 | 0x30) != 6
    {
        gStatus.Value := "已取消"
        return
    }
    result := KillProcess(o.pid, o.name)
    gStatus.Value := o.name " (PID " o.pid ")：" result
    if InStr(result, "已结束")
        Detect()    ; 结束成功后自动复查
}

ShortName(p) {
    SplitPath p, &nm
    return nm
}

; ── 无 GUI 自测：--selftest [输出路径] ──────────────────────────────────
if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\文件解锁\selftest-result.txt")

RunSelfTest(path) {
    out := ""
    Emit(s) => out .= s "`n"

    ; 1. 保护名单
    Emit((CRITICAL_PROCS.Has("lsass.exe") ? "PASS " : "FAIL ") "保护名单含 lsass.exe")
    Emit((CRITICAL_PROCS.Has("dwm.exe") ? "PASS " : "FAIL ") "保护名单含 dwm.exe")
    Emit((!CRITICAL_PROCS.Has("notepad.exe") ? "PASS " : "FAIL ") "普通进程不在保护名单")

    ; 2. 占用检测：CreateFileW(share=3, 不含 DELETE) 持有才构成真正占用
    tf := A_Temp "\ahkdeck-unlock-selftest-" DllCall("kernel32\GetCurrentProcessId", "UInt") ".txt"
    try FileDelete(tf)
    fh := DllCall("kernel32\CreateFileW", "Str", tf, "UInt", 0x40000000
        , "UInt", 0x1 | 0x2, "Ptr", 0, "UInt", 2, "UInt", 0x80, "Ptr", 0, "Ptr")
    lock1 := IsLocked(tf)
    ; 3. 找占用者：FPIF 应返回本进程 PID
    owners := FindOwners(tf)
    myPid := DllCall("kernel32\GetCurrentProcessId", "UInt")
    foundSelf := false
    for pid in owners
        if (pid = myPid)
            foundSelf := true
    DllCall("kernel32\CloseHandle", "Ptr", fh)
    lock2 := IsLocked(tf)
    Emit((lock1 != "" ? "PASS " : "FAIL ") "持有句柄时判为占用（" lock1 "）")
    Emit((foundSelf ? "PASS " : "FAIL ") "FPIF 找出占用本文件的进程 PID（" owners.Length " 个）")
    Emit((lock2 = "" ? "PASS " : "FAIL ") "关闭句柄后判为未占用")
    try FileDelete(tf)

    fails := 0
    for ln in StrSplit(out, "`n")
        if SubStr(ln, 1, 5) = "FAIL "
            fails++
    Emit("fails=" fails)
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

BuildGui()
