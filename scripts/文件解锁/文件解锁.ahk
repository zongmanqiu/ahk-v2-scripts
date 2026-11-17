; ==UserScript==
; @name         文件解锁
; @id           file-unlock
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.1.2
; @description  拖入文件或文件夹，自动检测占用，一键解除占用或删除（含保留名/权限受限文件）
; @author       邱宗满
; @date         2026-11-17
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口：拖入文件/文件夹即自动检测；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 文件解锁：把文件/文件夹拖进窗口即自动检测占用状态，可「解除占用」（结束占用进程）
; 或「删除」（含 nul/con 等保留设备名、只读/权限受限文件）。
; 形态：以 GUI 窗口为唯一入口，不注册托盘菜单、不设全局热键；独立运行直接弹窗，
; 窗口关闭即退出。许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
;
; 技术路线（2026-11-17 本机 Win11 build 26200 实测，详见 info/HISTORY.md）：
;  - 占用检测：CreateFileW 以 DELETE(0x10000)+全共享(7) 试探开，被占用返回
;    INVALID_HANDLE_VALUE 且 GetLastError=32/33；文件夹加 FILE_FLAG_BACKUP_SEMANTICS。
;  - 找占用者：NtQueryInformationFile 的 FileProcessIdsUsingFileInformation(47)
;    一次调用返回"正在使用该文件的进程 PID 列表"——无需管理员、无需遍历全系统句柄、
;    瞬间完成。结构体 = ULONG count + 4字节pad + ULONG_PTR PID[]（x64）。
;  - 解除占用：只对确认后的占用进程 TerminateProcess，经系统关键进程保护名单拦截 +
;    二次确认，绝不自动杀、绝不杀自身。
;  - 删除：\\?\ 前缀直通路径（绕过 Win32 保留设备名/长路径解析）→ 清只读/隐藏/系统
;    属性 → 若仍被占用则先解除 → DeleteFileW（文件）/ RemoveDirectoryW 自底向上（目录，
;    reparse point 只删链接本身）。实测：普通 DeleteFileW 删 nul 报 err=5（就是用户看到
;    的"需要管理员权限"假象），\\?\ 前缀 rc=1 成功删掉。
;  - 走过的弯路（已证伪，别重走）：Restart Manager 在本机 session 句柄恒 0、RmGetList
;    挂起；全系统句柄枚举逐个 dup 路径要 90s+；句柄表 Object 字段 Win8+ 恒为 0。
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
ERROR_FILE_NOT_FOUND := 2
ERROR_PATH_NOT_FOUND := 3
PROCESS_QUERY_LIMITED_INFO := 0x1000
PROCESS_TERMINATE := 0x1
FILE_PROCESS_IDS_USING_FILE := 47
FILE_FLAG_BACKUP_SEMANTICS := 0x2000000
FILE_ATTRIBUTE_NORMAL := 0x80
FILE_ATTRIBUTE_REPARSE_POINT := 0x400

; ── 版式常量（UI规范 §10.2.3）──────────────────────────────────────────
EDGE := 16                ; 内容行左边距；行宽 = 客户区宽 − 2×EDGE
ROW_W := 640              ; 内容行宽（672 − 32）
BTN_PAD := 16             ; 按钮文字左右各留白
INLINE_GAP := 8           ; 同排控件/按钮之间
BLOCK_GAP := 6            ; 不同语义区块之间（列表区 → 操作行 → 状态条）
H_ACTION := 28            ; 按钮/操作行高
H_STATUS := 30            ; 状态条高
H_HEADER := 26            ; 列头带高

; 系统关键进程保护名单（小写文件名）：结束它们会导致系统不稳定。
CRITICAL_PROCS := Map("smss.exe", 1, "csrss.exe", 1, "wininit.exe", 1, "winlogon.exe", 1
    , "services.exe", 1, "lsass.exe", 1, "lsaiso.exe", 1, "fontdrvhost.exe", 1
    , "dwm.exe", 1, "sihost.exe", 1, "svchost.exe", 1, "audiodg.exe", 1
    , "conhost.exe", 1, "explorer.exe", 1, "System", 1, "Registry", 1)

gGui := 0, gList := 0, gStatus := 0, gInfo := 0
gItems := []          ; [{path, isDir, owners:[pid], names:"进程名列表"}]，每行对应一项

; ── 文件系统属性判断（一律走 \\?\ 直通；FileExist 对 junction/保留名不可靠）──
FileAttrs(path) {
    return DllCall("kernel32\GetFileAttributesW", "Str", NtPath(path), "UInt")
}
IsDirPath(path) {
    a := FileAttrs(path)
    return (a != 0xFFFFFFFF && (a & 0x10))          ; FILE_ATTRIBUTE_DIRECTORY
}
IsLinkPath(path) {
    a := FileAttrs(path)
    return (a != 0xFFFFFFFF && (a & FILE_ATTRIBUTE_REPARSE_POINT))
}

; ── 占用/权限状态：DELETE+全共享试探开（文件夹加 BACKUP_SEMANTICS）──────
; 关键：一律用 \\?\ 直通路径打开。否则 nul/con 等保留名会被 Win32 解析成设备，
; 试探开/FPIF 会把一堆无关进程当成占用者（实测 nul 误报几十个 PID）。
; 返回分类："" 可删（未占用且有权限）；"locked" 被进程占用（32/33）；
;           "denied" 无权限（5，ACL 拒绝，与占用是两回事）；"gone" 不存在；"err<码>" 其他。
FSState(path) {
    flags := 0x80 | (IsDirPath(path) ? FILE_FLAG_BACKUP_SEMANTICS : 0)
    h := DllCall("kernel32\CreateFileW", "Str", NtPath(path), "UInt", DELETE_ACCESS
        , "UInt", FILE_SHARE_ALL, "Ptr", 0, "UInt", 3   ; OPEN_EXISTING
        , "UInt", flags, "Ptr", 0, "Ptr")
    if (h != INVALID_HANDLE_VALUE && h != 0) {
        DllCall("kernel32\CloseHandle", "Ptr", h)
        return ""
    }
    e := A_LastError
    if (e = ERROR_FILE_NOT_FOUND || e = ERROR_PATH_NOT_FOUND)
        return "gone"                           ; 不存在（已删/设备名），不算占用
    if (e = ERROR_SHARING_VIOLATION || e = ERROR_LOCK_VIOLATION)
        return "locked"                         ; 32/33 = 真的被进程占用
    if (e = ERROR_ACCESS_DENIED)
        return "denied"                         ; 5 = ACL 拒绝，不是占用
    return "err" e
}

; 仅"被进程占用"才算 locked；无权限/不存在都不算（避免误导用户去解占用）。
PathLocked(path) {
    return FSState(path) = "locked"
}

; ── 找占用者：NtQueryInformationFile(FileProcessIdsUsingFileInformation) ─
; 同样用 \\?\ 直通路径，避免保留名被解析成设备而误报一堆 PID。
FindOwners(path) {
    pids := []
    flags := 0x80 | (IsDirPath(path) ? FILE_FLAG_BACKUP_SEMANTICS : 0)
    h := DllCall("kernel32\CreateFileW", "Str", NtPath(path), "UInt", READ_ATTR
        , "UInt", FILE_SHARE_ALL, "Ptr", 0, "UInt", 3, "UInt", flags, "Ptr", 0, "Ptr")
    if (h = INVALID_HANDLE_VALUE || h = 0)
        return pids
    try {
        iosb := Buffer(16, 0)
        buf := Buffer(8192, 0)
        st := DllCall("ntdll\NtQueryInformationFile", "Ptr", h, "Ptr", iosb
            , "Ptr", buf, "UInt", buf.Size, "UInt", FILE_PROCESS_IDS_USING_FILE, "UInt")
        if ((st & 0xFFFFFFFF) = 0) {
            cnt := NumGet(buf, 0, "UInt")
            if (cnt > 0 && cnt < 1000) {
                Loop cnt {
                    pid := NumGet(buf, 8 + (A_Index - 1) * 8, "UInt64")
                    if (pid > 0)
                        pids.Push(pid)
                }
            }
        }
    } finally
        DllCall("kernel32\CloseHandle", "Ptr", h)
    return pids
}

; ── 进程名 ────────────────────────────────────────────────────────────
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

; ── 结束进程（带保护名单）─────────────────────────────────────────────
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

; ── 递归收集文件夹下的文件（文件夹本身也作为一项）─────────────────────
; 遇 reparse point（junction/symlink）只收链接本身，绝不递归进目标——否则会把
; 目标目录里一堆无关文件算进来，删除时也可能误伤。用属性判断，不用 FileExist。
CollectFiles(path, out, depth := 0) {
    if (depth > 32)
        return
    a := FileAttrs(path)
    if (a = 0xFFFFFFFF)
        return
    if (a & 0x10) {                                  ; 目录
        if (a & FILE_ATTRIBUTE_REPARSE_POINT) {
            out.Push(path)                           ; 链接：只算它自己
            return
        }
        Loop Files path "\*", "F"
            out.Push(A_LoopFilePath)
        Loop Files path "\*", "D"
            CollectFiles(A_LoopFilePath, out, depth + 1)
    } else {
        out.Push(path)
    }
}

; ── \\?\ 直通路径（绕过保留设备名/长路径的 Win32 解析）─────────────────
NtPath(path) {
    ; 绝对路径（盘符或 UNC）。UNC 用 \\?\UNC\ 前缀。
    if (SubStr(path, 1, 2) = "\\") {
        rest := SubStr(path, 3)
        ; 去掉开头的 \\?\ 若已有
        if (SubStr(rest, 1, 4) = "?\")
            return path
        return "\\?\UNC\" rest
    }
    if (SubStr(path, 1, 4) = "\\?\")
        return path
    return "\\?\" StrReplace(path, "/", "\")
}

; ── 清属性（READONLY/HIDDEN/SYSTEM → NORMAL）─────────────────────────
ClearAttributes(path) {
    np := NtPath(path)
    a := DllCall("kernel32\GetFileAttributesW", "Str", np, "UInt")
    if (a = INVALID_HANDLE_VALUE)
        return false
    if (a & 0x1 | a & 0x2 | a & 0x4)   ; READONLY|HIDDEN|SYSTEM
        return DllCall("kernel32\SetFileAttributesW", "Str", np, "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
    return true
}

; ── 删除单个文件（\\?\ 前缀 + 清属性，失败则解占用后重试）─────────────
; 返回 [成功?, 错误信息]
DeleteOneFile(path) {
    ClearAttributes(path)
    np := NtPath(path)
    if DllCall("kernel32\DeleteFileW", "Str", np, "Int")
        return [true, ""]
    e := DllCall("kernel32\GetLastError", "UInt")
    ; 5=拒绝访问（可能占用或权限），32/33=占用 → 尝试结束占用进程后重试
    if (e = ERROR_ACCESS_DENIED || e = ERROR_SHARING_VIOLATION || e = ERROR_LOCK_VIOLATION) {
        for pid in FindOwners(path) {
            nm := ProcName(pid)
            if !CRITICAL_PROCS.Has(StrLower(nm))
                KillProcess(pid, nm)
        }
        ClearAttributes(path)
        if DllCall("kernel32\DeleteFileW", "Str", np, "Int")
            return [true, ""]
        e := DllCall("kernel32\GetLastError", "UInt")
    }
    if (e = ERROR_FILE_NOT_FOUND || e = ERROR_PATH_NOT_FOUND)
        return [true, ""]     ; 已不存在，视为成功
    return [false, "err=" e]
}

; ── 删除文件夹（自底向上；reparse point 只删链接本身，绝不递归进目标）──
; 返回 [成功?, 错误信息]
DeleteDirTree(path) {
    np := NtPath(path)
    ; reparse point：目录 junction/symlink 用 RemoveDirectoryW 直接删，不进内部
    a := DllCall("kernel32\GetFileAttributesW", "Str", np, "UInt")
    if (a != INVALID_HANDLE_VALUE && (a & FILE_ATTRIBUTE_REPARSE_POINT)) {
        DllCall("kernel32\SetFileAttributesW", "Str", np, "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
        if DllCall("kernel32\RemoveDirectoryW", "Str", np, "Int")
            return [true, ""]
        return [false, "reparse err=" DllCall("kernel32\GetLastError", "UInt")]
    }
    ; 先删内部所有文件（用直通路径枚举，处理保留名）
    Loop Files NtPath(path) "\*", "F"
        DeleteOneFile(A_LoopFilePath)
    ; 再自底向上删子目录
    dirs := []
    CollectDirsOnly(path, dirs, 0)
    for d in ArrayToDeepFirst(dirs) {
        DllCall("kernel32\SetFileAttributesW", "Str", NtPath(d), "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
        DllCall("kernel32\RemoveDirectoryW", "Str", NtPath(d), "Int")
    }
    DllCall("kernel32\SetFileAttributesW", "Str", np, "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
    if DllCall("kernel32\RemoveDirectoryW", "Str", np, "Int")
        return [true, ""]
    e := DllCall("kernel32\GetLastError", "UInt")
    if (e = ERROR_FILE_NOT_FOUND || e = ERROR_PATH_NOT_FOUND)
        return [true, ""]
    return [false, "dir err=" e]
}

CollectDirsOnly(path, out, depth) {
    if (depth > 32)
        return
    if !IsDirPath(path)
        return
    Loop Files path "\*", "D" {
        out.Push(A_LoopFilePath)
        if IsLinkPath(A_LoopFilePath)
            continue                    ; junction 只收它自己，不进目标
        CollectDirsOnly(A_LoopFilePath, out, depth + 1)
    }
}

ArrayToDeepFirst(arr) {
    ; 按路径深度降序（深层在前），深度相同按长度降序
    res := []
    for d in arr
        res.Push({ p: d, k: StrSplit(StrReplace(d, "\", "/"), "/").Length * 1000 + StrLen(d) })
    ; 简单插入排序（目录数量通常不大）
    for i, o in res {
        j := i - 1
        while (j >= 1 && res[j].k < o.k) {
            res[j + 1] := res[j]
            j--
        }
        res[j + 1] := o
    }
    out := []
    for o in res
        out.Push(o.p)
    return out
}

; ── DWM caption 染色（令牌色，照范本）─────────────────────────────────
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

; 1px 描边按钮（范本同名函数）
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

; ── 量文字实际宽（GDI，s10 Microsoft YaHei UI）───────────────────────────
; UI规范 §10.3.1-2：按钮宽 = 文字实际宽 + 2×BTN_PAD，禁止为了铺满撑宽（K25）。
; 实测 dpi=96 下：四汉字 52 → 按钮 84；两汉字 26 → 58。带缓存。
MeasureTextWidth(text, size := 10, fontName := "Microsoft YaHei UI") {
    static cache := Map()
    if cache.Has(text)
        return cache[text]
    hdc := DllCall("user32\GetDC", "Ptr", 0, "Ptr")
    dpiY := DllCall("gdi32\GetDeviceCaps", "Ptr", hdc, "Int", 90, "Int")
    h := DllCall("gdi32\CreateFontW"
        , "Int", -DllCall("kernel32\MulDiv", "Int", size, "Int", dpiY, "Int", 72, "Int")
        , "Int", 0, "Int", 0, "Int", 0, "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0
        , "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0, "Str", fontName, "Ptr")
    old := DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", h, "Ptr")
    sz := Buffer(8, 0)
    DllCall("gdi32\GetTextExtentPoint32W", "Ptr", hdc, "Str", text, "Int", StrLen(text), "Ptr", sz)
    w := NumGet(sz, 0, "Int")
    DllCall("gdi32\SelectObject", "Ptr", hdc, "Ptr", old, "Ptr")
    DllCall("gdi32\DeleteObject", "Ptr", h, "Int")
    DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", hdc)
    cache[text] := w
    return w
}

; ── GUI ────────────────────────────────────────────────────────────────
; 版式照 UI规范 §10.3：客户区 672×352。垂直节奏 TOP(12) → 列表区 → BLOCK_GAP(6)
; → 操作行(28) → BLOCK_GAP(6) → 状态条(30) → 贴窗口底。
; 按钮宽由文字实际宽 + 2×BTN_PAD 定（§10.3.1-2，K25），整组右对齐到行右缘（656），
; 余量留在按钮组左侧放汇总信息。列表区整体框（父块露 1px 线），caption 同 #DCE8F7。
BuildGui() {
    global gGui, gList, gStatus, gInfo
    global EDGE, ROW_W, INLINE_GAP, BLOCK_GAP, H_ACTION, H_STATUS, H_HEADER
    gGui := Gui("", "文件解锁")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())
    gGui.OnEvent("DropFiles", OnDropFiles)

    RIGHT := EDGE + ROW_W                       ; 行右缘 656
    LIST_Y := 12                                ; 列表区顶（原顶部说明行已去掉）
    LIST_H := 270                               ; 列表区整体高
    LIST_BOTTOM := LIST_Y + LIST_H              ; 282

    ; 列表区整体框：外框 → 标题带（内缩 1px）→ 列表（内缩 1px、紧贴标题带底）
    gGui.Add("Text", "x" EDGE " y" LIST_Y " w" ROW_W " h" LIST_H " BackgroundB7C8E0")
    gGui.Add("Text", "x" (EDGE + 1) " y" (LIST_Y + 1) " w" (ROW_W - 2) " h" H_HEADER " BackgroundDCE8F7")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x" (EDGE + 7) " y" (LIST_Y + 1) " w424 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "路径")
    gGui.Add("Text", "x451 y" (LIST_Y + 1) " w72 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "类型")
    gGui.Add("Text", "x527 y" (LIST_Y + 1) " w122 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "状态")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")
    gList := gGui.Add("ListView", "x" (EDGE + 1) " y" (LIST_Y + 1 + H_HEADER) " w" (ROW_W - 2)
        . " h" (LIST_H - 2 - H_HEADER) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["路径", "类型", "状态"])
    gList.ModifyCol(1, 430), gList.ModifyCol(2, 78), gList.ModifyCol(3, 128)

    ; 操作行：按钮组右对齐，余量在左侧放汇总信息
    ACT_Y := LIST_BOTTOM + BLOCK_GAP            ; 288
    wDel := MeasureTextWidth("删除") + 32       ; 58
    wUnlock := MeasureTextWidth("解除占用") + 32 ; 84
    xDel := RIGHT - wDel                        ; 598
    xUnlock := xDel - INLINE_GAP - wUnlock      ; 506
    gInfo := gGui.Add("Text", "x" EDGE " y" ACT_Y " w" (xUnlock - EDGE - INLINE_GAP)
        . " h" H_ACTION " BackgroundF7F9FC c202B3A +0x200", "")
    FlatButton(gGui, xUnlock, ACT_Y, wUnlock, H_ACTION, "解除占用", "EBF2FB", "B7C8E0", (*) => UnlockSelected())
    FlatButton(gGui, xDel, ACT_Y, wDel, H_ACTION, "删除", "EBF2FB", "B7C8E0", (*) => DeleteSelected())

    ; 状态条：贴窗口底
    ST_Y := ACT_Y + H_ACTION + BLOCK_GAP        ; 322
    gGui.Add("Text", "x0 y" ST_Y " w672 h" H_STATUS " BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y" ST_Y " w648 h" H_STATUS " BackgroundDCE8F7 c202B3A +0x200", "就绪 · 拖入文件开始")

    gGui.Show("w672 h" (ST_Y + H_STATUS) " Center")   ; 352
    PaintCaption()
}

; 拖入：加入列表并逐项自动检测
OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global gList, gItems, gStatus
    added := 0
    for path in files {
        if ItemIndex(path) > 0
            continue
        kind := KindOf(path)
        gItems.Push({ path: path, isDir: (kind != "文件"), kind: kind, owners: [], names: "检测中…" })
        gList.Add("", path, kind, "检测中…")
        added++
    }
    if !added
        return
    gStatus.Value := "检测中 · " added " 项…"
    ; 逐项检测（FPIF 瞬间完成，无需后台）
    for it in gItems {
        if (it.names != "检测中…")
            continue
        DetectItem(it)
    }
    RefreshList()
    UpdateSummary()
    gStatus.Value := "检测完成 · " gItems.Length " 项"
}

ItemIndex(path) {
    global gItems
    for i, it in gItems
        if (it.path = path)
            return i
    return 0
}

; 路径类型：链接 / 文件夹 / 文件（用属性判断，FileExist 对 junction/保留名不可靠）
KindOf(path) {
    a := FileAttrs(path)
    if (a = 0xFFFFFFFF)
        return "文件"
    if (a & FILE_ATTRIBUTE_REPARSE_POINT)
        return "链接"
    return (a & 0x10) ? "文件夹" : "文件"
}

; 检测单个项：展开其下文件，区分「被占用 / 无权限 / 未占用」
DetectItem(it) {
    files := []
    CollectFiles(it.path, files)
    if !files.Length {
        it.owners := []
        it.names := "不存在"
        return
    }
    pidSet := Map()
    lockedCount := 0
    deniedCount := 0
    for f in files {
        st := FSState(f)
        if (st = "locked") {
            lockedCount++
            for pid in FindOwners(f)
                pidSet[pid] := 1
        } else if (st = "denied") {
            deniedCount++
        }
    }
    it.owners := []
    names := ""
    for pid in pidSet {
        it.owners.Push(pid)
        names .= (names ? ", " : "") ProcName(pid)
    }
    if (lockedCount > 0)
        it.names := names ? "被占用 · " names : "被占用（未知进程）"
    else if (deniedCount > 0)
        it.names := "无权限（需管理员）"           ; ACL 拒绝 ≠ 被占用，不误导去解占用
    else
        it.names := "未占用"
}

RefreshList() {
    global gList, gItems
    gList.Delete()
    Loop gItems.Length {
        it := gItems[A_Index]
        if !IsObject(it)
            continue
        gList.Add("", it.path, it.kind, it.names)
    }
}

UpdateSummary() {
    global gItems, gInfo, gStatus
    locked := 0, denied := 0
    Loop gItems.Length {
        it := gItems[A_Index]
        if !IsObject(it)
            continue
        if InStr(it.names, "被占用")
            locked++
        else if InStr(it.names, "无权限")
            denied++
    }
    txt := gItems.Length " 项 · " locked " 项被占用"
    if denied
        txt .= " · " denied " 项无权限"
    gInfo.Value := txt
}

; 取当前选中的项索引数组（无选中则空）
SelectedIndexes() {
    global gList
    idxs := []
    r := gList.GetNext(0, "F")
    while r {
        idxs.Push(r)
        r := gList.GetNext(r, "F")
    }
    return idxs
}

; ── 解除占用：结束选中项（无选中=全部被占用项）的占用进程 ──────────────
UnlockSelected() {
    global gList, gItems, gStatus
    idxs := SelectedIndexes()
    if !idxs.Length {
        ; 无选中：取所有被占用项
        for i, it in gItems
            if (it.owners.Length)
                idxs.Push(i)
    }
    if !idxs.Length {
        gStatus.Value := "没有需要解除占用的项"
        return
    }
    ; 汇总 PID + 名称
    pidMap := Map()
    for i in idxs {
        if (i < 1 || i > gItems.Length)
            continue
        for pid in gItems[i].owners
            pidMap[pid] := ProcName(pid)
    }
    if !pidMap.Count {
        gStatus.Value := "选中项未发现占用进程"
        return
    }
    ; 过滤保护名单
    detail := ""
    blocked := 0
    for pid, nm in pidMap {
        if CRITICAL_PROCS.Has(StrLower(nm)) {
            blocked++
            continue
        }
        detail .= "  · " nm " (PID " pid ")`n"
    }
    warn := blocked ? "`n已跳过 " blocked " 个系统关键进程。`n" : ""
    if MsgBox("将结束以下占用进程以解除占用：`n`n" detail . warn
            . "`n未保存的数据可能丢失，确定继续？", "文件解锁 · 确认解除", 0x4 | 0x30) != 6
    {
        gStatus.Value := "已取消"
        return
    }
    killed := 0, failed := 0
    for pid, nm in pidMap {
        if CRITICAL_PROCS.Has(StrLower(nm))
            continue
        r := KillProcess(pid, nm)
        if InStr(r, "已结束")
            killed++
        else
            failed++
    }
    ; 复查状态
    gStatus.Value := "已结束 " killed " 个进程" (failed ? "，失败 " failed " 个" : "") " · 正在复查…"
    for i in idxs {
        if (i < 1 || i > gItems.Length)
            continue
        DetectItem(gItems[i])
    }
    RefreshList()
    UpdateSummary()
    gStatus.Value := "解除完成 · 已结束 " killed " 个进程" (failed ? "，失败 " failed " 个" : "")
}

; ── 删除：选中项（无选中=全部）强删，含保留名/权限受限 ─────────────────
DeleteSelected() {
    global gList, gItems, gStatus
    idxs := SelectedIndexes()
    if !idxs.Length {
        for i, it in gItems
            idxs.Push(i)
    }
    if !idxs.Length {
        gStatus.Value := "列表为空"
        return
    }
    names := ""
    for i in idxs {
        if (i < 1 || i > gItems.Length)
            continue
        names .= "  · " gItems[i].path "`n"
    }
    if MsgBox("将永久删除以下项目（不进回收站）：`n`n" names
            . "`n此操作不可撤销，确定继续？", "文件解锁 · 确认删除", 0x4 | 0x30) != 6
    {
        gStatus.Value := "已取消"
        return
    }
    ok := 0, fail := 0
    failDetail := ""
    ; 从后往前删，避免索引错位
    sorted := []
    for i in idxs
        sorted.Push(i)
    ; 降序排序（AHK v2 用 Loop）
    Loop sorted.Length - 1 {
        a := A_Index
        Loop sorted.Length - a {
            b := a + A_Index
            if sorted[b] > sorted[a] {
                tmp := sorted[a], sorted[a] := sorted[b], sorted[b] := tmp
            }
        }
    }
    ; 记录删除成功的下标，最后重建数组（不在遍历中 Delete，避免 AHK 数组空洞）
    removed := Map()
    for i in sorted {
        it := gItems[i]
        res := [false, ""]
        if (FileAttrs(it.path) = 0xFFFFFFFF) {
            res := [true, ""]                    ; 已不存在，视为成功
        } else if IsDirPath(it.path) {
            res := DeleteDirTree(it.path)        ; 目录（含 junction 走内部 reparse 分支）
        } else {
            res := DeleteOneFile(it.path)
        }
        if res[1] {
            ok++
            removed[i] := 1
        } else {
            fail++
            failDetail .= "`n" ShortName(it.path) " (" res[2] ")"
        }
    }
    ; 重建 gItems：只保留未删除项
    if removed.Count {
        kept := []
        Loop gItems.Length {
            if !removed.Has(A_Index)
                kept.Push(gItems[A_Index])
        }
        gItems := kept
    }
    RefreshList()
    UpdateSummary()
    if fail
        gStatus.Value := "删除完成 · 成功 " ok "，失败 " fail failDetail
    else
        gStatus.Value := "删除完成 · 成功 " ok " 项"
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
    myPid := DllCall("kernel32\GetCurrentProcessId", "UInt")

    ; 1. 保护名单
    Emit((CRITICAL_PROCS.Has("lsass.exe") ? "PASS " : "FAIL ") "保护名单含 lsass.exe")
    Emit((CRITICAL_PROCS.Has("dwm.exe") ? "PASS " : "FAIL ") "保护名单含 dwm.exe")
    Emit((!CRITICAL_PROCS.Has("notepad.exe") ? "PASS " : "FAIL ") "普通进程不在保护名单")

    ; 2. NtPath 直通路径
    Emit((NtPath("C:\a\b") = "\\?\C:\a\b" ? "PASS " : "FAIL ") "NtPath 盘符前缀")
    Emit((NtPath("\\srv\share\x") = "\\?\UNC\srv\share\x" ? "PASS " : "FAIL ") "NtPath UNC 前缀")

    ; 3. 占用检测 + FPIF 找占用者：CreateFileW(share=3) 持有才构成真正占用
    tf := A_Temp "\ahkdeck-unlock-selftest-" myPid ".txt"
    try FileDelete(tf)
    fh := DllCall("kernel32\CreateFileW", "Str", tf, "UInt", 0x40000000
        , "UInt", 0x1 | 0x2, "Ptr", 0, "UInt", 2, "UInt", 0x80, "Ptr", 0, "Ptr")
    lock1 := PathLocked(tf)
    owners := FindOwners(tf)
    foundSelf := false
    for pid in owners
        if (pid = myPid)
            foundSelf := true
    DllCall("kernel32\CloseHandle", "Ptr", fh)
    lock2 := PathLocked(tf)
    Emit((lock1 ? "PASS " : "FAIL ") "持有句柄时判为占用")
    Emit((foundSelf ? "PASS " : "FAIL ") "FPIF 找出占用本文件的进程 PID（" owners.Length " 个）")
    Emit((!lock2 ? "PASS " : "FAIL ") "关闭句柄后判为未占用")
    try FileDelete(tf)

    ; 4. 保留名文件删除：用 \\?\ 前缀造一个 con 文件再删（普通 API 做不到）
    dp := A_Temp "\ahkdeck_delprobe_" myPid
    try DirCreate(dp)
    conPath := "\\?\" dp "\con"
    hc := DllCall("kernel32\CreateFileW", "Str", conPath, "UInt", 0x40000000
        , "UInt", 0, "Ptr", 0, "UInt", 2, "UInt", 0x80, "Ptr", 0, "Ptr")
    if (hc != INVALID_HANDLE_VALUE && hc != 0) {
        DllCall("kernel32\CloseHandle", "Ptr", hc)
        delRes := DeleteOneFile(dp "\con")
        Emit((delRes[1] ? "PASS " : "FAIL ") "删除保留名文件 con（\\?\ 直通）" (delRes[1] ? "" : " " delRes[2]))
    } else {
        Emit("SKIP  造保留名文件失败（环境限制）")
    }
    try DirDelete(dp, 1)

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
