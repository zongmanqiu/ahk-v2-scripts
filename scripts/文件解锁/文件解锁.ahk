; ==UserScript==
; @name         文件解锁
; @id           file-unlock
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.3.1
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

gGui := 0, gList := 0, gStatus := 0, gInfo := 0, gScroll := 0
gLvWhite := 0, gLineTop := 0, gLineBot := 0, gLineLft := 0, gLineRgt := 0
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
    ; ★ 幂等：已带 \\?\ 必须原样返回。先判 UNC 会把 \\?\E:\x 当成 UNC
    ;   （rest="?\E:\x"）拼成 \\?\UNC\?\E:\x，DeleteFileW 直接回 err=53。
    if (SubStr(path, 1, 4) = "\\?\")
        return path
    if (SubStr(path, 1, 2) = "\\")
        return "\\?\UNC\" SubStr(path, 3)
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
; ★ 必须逐层掏空：只删顶层文件的话，子目录里的文件还在 →
;   RemoveDirectoryW 得 err=145（目录非空），整棵树删不掉。
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
    fails := []
    ; 子目录按深度降序：先掏空最深的目录，再删它
    dirs := []
    CollectDirsOnly(path, dirs, 0)
    for d in ArrayToDeepFirst(dirs) {
        DeleteFilesIn(d, fails)
        DllCall("kernel32\SetFileAttributesW", "Str", NtPath(d), "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
        if !DllCall("kernel32\RemoveDirectoryW", "Str", NtPath(d), "Int") {
            e := DllCall("kernel32\GetLastError", "UInt")
            if (e != ERROR_FILE_NOT_FOUND && e != ERROR_PATH_NOT_FOUND)
                fails.Push(ShortName(d) " dir err=" e)
        }
    }
    DeleteFilesIn(path, fails)
    DllCall("kernel32\SetFileAttributesW", "Str", np, "UInt", FILE_ATTRIBUTE_NORMAL, "Int")
    if DllCall("kernel32\RemoveDirectoryW", "Str", np, "Int")
        return [true, ""]
    e := DllCall("kernel32\GetLastError", "UInt")
    if (e = ERROR_FILE_NOT_FOUND || e = ERROR_PATH_NOT_FOUND)
        return [true, ""]
    detail := fails.Length ? "；" fails.Length " 项未删（首个：" fails[1] "）" : ""
    return [false, "dir err=" e detail]
}

; 删掉某目录下的直接文件，失败项追加进 fails
DeleteFilesIn(dir, fails) {
    Loop Files NtPath(dir) "\*", "F" {
        r := DeleteOneFile(A_LoopFilePath)
        if !r[1]
            fails.Push(ShortName(A_LoopFilePath) " " r[2])
    }
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

; 1px 描边按钮（范本同名函数）。返回 {outer, inner, w, h} 以便缩放时整体搬移。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return { outer: f, inner: b, w: w, h: h }
}

MoveBtn(btn, x, y) {
    btn.outer.Move(x, y, btn.w, btn.h)
    btn.inner.Move(x + 1, y + 1, btn.w - 2, btn.h - 2)
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

; ── 自绘滚动条 ──────────────────────────────────────────────────────────
; 整段复用《硬件信息》2.3.4 的 class FlatScroll（只竖轴版，可缩放窗口已验证）。
; 原生条由 comctl32 主题引擎绘制，脚本拿不到颜色；ShowScrollBar(FALSE) 只是「按需隐藏」，
; Move/Add/Delete/ModifyCol/LVM_SCROLL 都会把样式位置回，所以每次动作后补一刀 + Sync 兜底。
; 三个有意差异（均实测）：逐块 SetWindowPos 不用批量提交、滚动走 LVM_SCROLL 像素增量、
; 每页行数取 LVM_GETCOUNTPERPAGE。横向条撤掉，列宽做进视口。
class FlatScroll {
    __New(g, lv, x, y, w, h, t := 10) {
        this.g := g, this.lv := lv
        this.x := x, this.y := y, this.w := w, this.h := h, this.t := t
        this.tn := Max(3, t - 6), this.off := (t - this.tn) // 2
        this.pad := 2
        this.lvW := 0, this.lvH := 0, this.itemH := 23
        this.exV := false, this.dead := false
        this.lastV := -1, this.lastCount := -1
        this.rows := 0, this.viewRows := 1, this.top := 0, this.maxTop := 0
        this.ops := [], this.dragging := false
        ; SetTimer 按 FuncObj 身份认定时器：绑一次全程复用，否则关不掉、越叠越多。
        this.fnTick := ObjBindMethod(this, "DragTick")
        this.fnSync := ObjBindMethod(this, "Sync")
        ; +0x100 = SS_NOTIFY：不加静态控件命中测试透明，点击穿透到父窗口（K19）。
        ; 轨道拆「滑块前/后」两段，与滑块几何永不重叠（叠放抬 z 序压不住，K20）。
        this.vUp := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vDn := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapL := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapR := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumbV := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        for c in [this.vUp, this.vDn, this.vGapL, this.vGapR, this.thumbV]
            c.Visible := false
    }

    ; 内容超出才占位，与原生一致；最多三轮收敛。
    Layout() {
        if (!this.lv.Hwnd)
            return
        loop 3 {
            this.HideNative()
            this.Measure()
            w := this.w - (this.exV ? this.t : 0)
            if (w = this.lvW && this.h = this.lvH)
                break
            this.lv.Move(this.x, this.y, w, this.h)
            this.lvW := w, this.lvH := this.h
        }
        ; 循环最后一步是 Move（会把原生条样式位置回），收尾必须再清一次。
        this.HideNative()
        if (this.lv.GetCount() > 0 && this.lvH > 0) {
            rc := Buffer(16, 0)
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x100E, "Ptr", 0, "Ptr", rc, "Ptr")
            ih := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
            if (ih > 0)
                this.itemH := ih
        }
        this.Repaint()
        this.Paint()
    }

    ; 逐块 SetWindowPos：实测批量提交在「列表刚 Move 完」那拍会整批失败返回 NULL。
    Put(c, on, x, y, w, h) {
        this.ops.Push({ c: c.Hwnd, on: on && w > 0 && h > 0, x: x, y: y, w: w, h: h })
    }
    Flush() {
        ops := this.ops
        this.ops := []
        for o in ops {
            if (o.on)
                DllCall("user32\SetWindowPos", "Ptr", o.c, "Ptr", 0, "Int", o.x, "Int", o.y
                    , "Int", o.w, "Int", o.h, "UInt", 0x0054, "Ptr")
            else
                DllCall("user32\ShowWindow", "Ptr", o.c, "Int", 0)
        }
    }
    TrackLen() {
        return this.lvH - this.pad * 2
    }
    Paint() {
        t := this.t, tn := this.tn, off := this.off, pd := this.pad
        this.ops := []
        if (this.exV) {
            g := this.Geo(this.TrackLen())
            bx := this.x + this.lvW
            a := this.y + pd + g.start
            b := a + g.len
            this.Put(this.vUp, true, bx, this.y, t, pd + g.start)
            this.Put(this.vDn, true, bx, b, t, this.y + this.lvH - b)
            this.Put(this.vGapL, true, bx, a, off, g.len)
            this.Put(this.vGapR, true, bx + off + tn, a, t - off - tn, g.len)
            this.Put(this.thumbV, true, bx + off, a, tn, g.len)
        } else {
            for c in [this.vUp, this.vDn, this.vGapL, this.vGapR, this.thumbV]
                this.Put(c, false, 0, 0, 0, 0)
        }
        this.Flush()
    }
    EnsureHidden() {
        try {
            v := DllCall("user32\GetWindowLongW", "Ptr", this.lv.Hwnd, "Int", -16, "Int")
            if (v & 0x00300000)
                this.HideNative()
        }
    }
    HideNative() {
        DllCall("user32\ShowScrollBar", "Ptr", this.lv.Hwnd, "Int", 1, "Int", 0)
        DllCall("user32\ShowScrollBar", "Ptr", this.lv.Hwnd, "Int", 0, "Int", 0)
    }
    Measure() {
        this.rows := this.lv.GetCount()
        this.top := this.ReadTop()
        ; LVM_GETCOUNTPERPAGE 给真实每页行数（按 lvH/itemH 估算会少算半行）。
        n := DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1028, "Ptr", 0, "Ptr", 0, "Ptr")
        this.viewRows := Max(1, n ? n : Floor(this.lvH / this.itemH))
        this.maxTop := Max(0, this.rows - this.viewRows)
        this.exV := this.rows > this.viewRows
    }
    ReadTop() {
        return DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1027, "Ptr", 0, "Ptr", 0, "Ptr")
    }
    ; LVM_SCROLL 按像素滚并自己夹住范围；滚前滚后各压一次原生条（K22）。
    ScrollToRow(target) {
        if (!this.lv.Hwnd)
            return
        target := Max(0, Min(this.maxTop, target))
        dy := (target - this.top) * this.itemH
        if (dy = 0) {
            this.Paint()
            return
        }
        this.HideNative()
        DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1014, "Ptr", 0, "Ptr", dy, "Ptr")
        this.top := this.ReadTop()
        this.HideNative()
        this.Repaint()
        this.Paint()
    }
    ; 不带 RDW_ERASE —— 带 ERASE 每次滚轮都会先擦成父底色再画，闪一下白（K44）。
    Repaint() {
        if (this.lv.Hwnd)
            DllCall("user32\RedrawWindow", "Ptr", this.lv.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0101)
    }
    ScrollRows(n) {
        this.ScrollToRow(this.top + n)
    }
    OnWheelDelta(delta) {
        this.ScrollRows(-Round(delta / 120) * 3)
    }
    OnKey(vk) {
        if (vk = 0x21) {
            this.ScrollRows(-this.viewRows)
            return 1
        }
        if (vk = 0x22) {
            this.ScrollRows(this.viewRows)
            return 1
        }
        if (vk = 0x24) {
            this.ScrollRows(-this.rows)
            return 1
        }
        if (vk = 0x23) {
            this.ScrollRows(this.rows)
            return 1
        }
        return 0
    }
    ClientW() {
        return this.lvW
    }
    Geo(trackLen) {
        len := Max(24, Min(trackLen, Round(trackLen * this.viewRows / Max(1, this.rows))))
        span := trackLen - len
        frac := (this.maxTop > 0) ? this.top / this.maxTop : 0
        return { len: len, start: Round(frac * span), span: span }
    }
    OnDown(hwnd) {
        if (hwnd = this.thumbV.Hwnd || hwnd = this.vGapL.Hwnd || hwnd = this.vGapR.Hwnd)
            this.BeginDrag()
        else if (hwnd = this.vUp.Hwnd || hwnd = this.vDn.Hwnd)
            this.PageJump()
    }
    PageJump() {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := NumGet(pt, 4, "Int")
        r := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "Ptr", this.thumbV.Hwnd, "Ptr", r)
        a := NumGet(r, 4, "Int"), b := NumGet(r, 12, "Int")
        dir := (c < a) ? -1 : 1
        this.ScrollRows(dir * this.viewRows)
    }
    BeginDrag() {
        g := this.Geo(this.TrackLen())
        if (g.span <= 0 || this.maxTop <= 0)
            return
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        this.dragging := true, this.gBase := g, this.pBase := this.top
        this.cBase := NumGet(pt, 4, "Int")
        DllCall("user32\SetCapture", "Ptr", this.thumbV.Hwnd)
        SetTimer(this.fnTick, 20)
    }
    DragTick() {
        if (!GetKeyState("LButton", "P")) {
            SetTimer(this.fnTick, 0)
            DllCall("user32\ReleaseCapture")
            this.dragging := false
            return
        }
        if (!this.dragging)
            return
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := NumGet(pt, 4, "Int")
        g := this.gBase
        start := Max(0, Min(g.span, g.start + (c - this.cBase)))
        this.ScrollToRow(this.pBase + Round((start - g.start) / g.span * this.maxTop))
    }
    Sync() {
        if (this.dead)
            return
        try {
            this.EnsureHidden()
            if (this.dragging)
                return
            n := this.lv.GetCount()
            if (n != this.lastCount) {
                this.lastCount := n
                this.Layout()
                return
            }
            v := this.ReadTop()
            if (v != this.lastV) {
                this.lastV := v
                this.top := v
                this.Paint()
            }
        }
    }
    ; 关窗前先 Stop，否则定时器下一拍访问已销毁控件（K21）。
    Stop() {
        if (this.dead)
            return
        this.dead := true
        SetTimer(this.fnSync, 0)
        SetTimer(this.fnTick, 0)
        if (this.dragging)
            DllCall("user32\ReleaseCapture")
    }
}

HookBarInput() {
    OnMessage(0x201, OnBarDown)
    OnMessage(0x20A, OnBarWheel)
    OnMessage(0x100, OnBarKey)
}
OnBarDown(wp, lp, msg, hwnd) {
    global gScroll
    if (gScroll && !gScroll.dead)
        gScroll.OnDown(hwnd)
}
OnBarWheel(wp, lp, msg, hwnd) {
    global gScroll, gGui
    if (!gScroll || gScroll.dead)
        return
    delta := (wp >> 16) & 0xFFFF
    if (delta & 0x8000)
        delta := delta - 0x10000
    ; 摘掉原生条后 ListView 不再自己处理滚轮：窗口内任意控件上都滚列表。
    if (gGui.Hwnd && DllCall("user32\IsChild", "Ptr", gGui.Hwnd, "Ptr", hwnd)) {
        gScroll.OnWheelDelta(delta)
        return 1
    }
}
OnBarKey(wp, lp, msg, hwnd) {
    global gScroll, gList
    if (!gScroll || gScroll.dead || !gList || hwnd != gList.Hwnd)
        return
    if (gScroll.OnKey(wp))
        return 1
}

; ── GUI ────────────────────────────────────────────────────────────────
; 版式照 UI规范 §10.3：默认客户区 672×352。垂直节奏 TOP(12) → 列表区 → BLOCK_GAP(6)
; → 操作行(28) → BLOCK_GAP(6) → 状态条(30) → 贴窗口底。
; 窗口可缩放/最大化（长路径需要）：所有块由 Layout(cw,ch) 按客户区重算，
; 只有列表区吸收纵向余量、路径列吸收横向余量；按钮宽由文字宽定，永不被拉伸。
BuildGui() {
    global gGui, gList, gStatus, gInfo, gScroll
    global gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt
    global gBand, gHdrPath, gHdrType, gHdrOcc, gStBand, gBtnUnlock, gBtnDel
    global EDGE, ROW_W
    gGui := Gui("+Resize +0x02000000", "文件解锁")   ; WS_CLIPCHILDREN：父窗口别刷在子控件上
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    ; 自绘滚动条定时器必须先停，否则关窗后还会有一拍访问已销毁的列表（K21）。
    gGui.OnEvent("Close", (*) => (gScroll ? gScroll.Stop() : 0, ExitApp()))
    gGui.OnEvent("DropFiles", OnDropFiles)
    gGui.OnEvent("Size", OnSize)

    ; 列表区：白底块 + 四边各一条 1px FRAME 线（§10.4 / K42）。
    ; ★不能整块 B7C8E0 打底：原生条被摘掉后那块区域不重绘，底色会从缝里露出 16px 竖条。
    ; 白底块让露出来的永远是白底，与列表同色看不见。
    gLvWhite := gGui.Add("Text", "x" (EDGE + 1) " y13 w" (ROW_W - 2) " h" (270 - 2) " BackgroundFFFFFF")
    gLineTop := gGui.Add("Text", "x" EDGE " y12 w" ROW_W " h1 BackgroundB7C8E0")
    gLineBot := gGui.Add("Text", "x" EDGE " y281 w" ROW_W " h1 BackgroundB7C8E0")
    gLineLft := gGui.Add("Text", "x" EDGE " y12 w1 h270 BackgroundB7C8E0")
    gLineRgt := gGui.Add("Text", "x" (EDGE + ROW_W - 1) " y12 w1 h270 BackgroundB7C8E0")

    gBand := gGui.Add("Text", "x" (EDGE + 1) " y13 w" (ROW_W - 2) " h" H_HEADER " BackgroundDCE8F7")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gHdrPath := gGui.Add("Text", "x24 y13 w424 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "路径")
    gHdrType := gGui.Add("Text", "x451 y13 w72 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "类型")
    gHdrOcc := gGui.Add("Text", "x527 y13 w122 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "占用程序")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")
    gList := gGui.Add("ListView", "x" (EDGE + 1) " y" (13 + H_HEADER) " w" (ROW_W - 2)
        . " h" (270 - 2 - H_HEADER) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["路径", "类型", "占用程序"])
    ; LVS_EX_DOUBLEBUFFER：滚动重绘走后台缓冲，避免整块重画闪一下（K44）。
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)

    gInfo := gGui.Add("Text", "x" EDGE " y288 w474 h" H_ACTION " BackgroundF7F9FC c202B3A +0x200", "")
    gBtnUnlock := FlatButton(gGui, 506, 288, MeasureTextWidth("解除占用") + 32, H_ACTION
        , "解除占用", "EBF2FB", "B7C8E0", (*) => UnlockSelected())
    gBtnDel := FlatButton(gGui, 598, 288, MeasureTextWidth("删除") + 32, H_ACTION
        , "删除", "EBF2FB", "B7C8E0", (*) => DeleteSelected())

    ; 状态条：贴窗口底
    gStBand := gGui.Add("Text", "x0 y322 w672 h" H_STATUS " BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y322 w648 h" H_STATUS " BackgroundDCE8F7 c202B3A +0x200", "就绪 · 拖入文件开始")

    gGui.Show("w672 h352 Center")
    PaintCaption()

    ; 自绘滚动条：后四个数 = 列表可用内空（x/y/w/h），Show 后建、再 Layout。
    gScroll := FlatScroll(gGui, gList, EDGE + 1, 13 + H_HEADER, ROW_W - 2, 270 - 2 - H_HEADER)
    HookBarInput()
    SetTimer(gScroll.fnSync, 60)
    Layout(672, 352)
}

; 缩放：按客户区重算所有块。★不再整窗 Redraw —— 那在拖边框时会整屏闪（K44/K47）。
; 静态色块的背景走 WM_CTLCOLORSTATIC：只改几何不会重画，最大化后会停在旧宽度，
; 但要逐个 InvalidateRect（第三参 0 = 不擦背景），整窗 Redraw 会闪。
OnSize(guiObj, minMax, width, height) {
    if (minMax = -1 || width < 1 || height < 1 || !IsObject(gScroll))
        return
    Layout(width, height)
}

; 拖拽边框最小值（WM_GETMINMAXINFO，ptMinTrackSize 在 offset 24/28）
; ★ 该消息在 Gui() 构造期间就会到达，此时 gGui 尚未赋值 —— 必须先判空。
OnMessage(0x24, WM_GetMinMaxInfo)
WM_GetMinMaxInfo(wParam, lParam, msg, hwnd) {
    global gGui
    if (!IsSet(gGui) || !IsObject(gGui))
        return
    if (hwnd != gGui.Hwnd)
        return
    NumPut("Int", 560, lParam, 24)
    NumPut("Int", 340, lParam, 28)
}

Layout(cw, ch) {
    global EDGE, INLINE_GAP, BLOCK_GAP, H_ACTION, H_STATUS, H_HEADER
    global gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt
    global gBand, gHdrPath, gHdrType, gHdrOcc, gList, gScroll, gInfo
    global gStBand, gStatus, gBtnUnlock, gBtnDel
    RIGHT := cw - EDGE
    ROW_W := cw - 2 * EDGE
    LIST_Y := 12
    ST_Y := ch - H_STATUS
    ACT_Y := ST_Y - BLOCK_GAP - H_ACTION
    LIST_H := ACT_Y - BLOCK_GAP - LIST_Y
    if (LIST_H < 60)
        LIST_H := 60

    ; 白底块 + 四边 1px 线：底块与线同 x/y/w/h，原生控件内缩 1px（K7）。
    gLvWhite.Move(EDGE + 1, LIST_Y + 1, ROW_W - 2, LIST_H - 2)
    gLineTop.Move(EDGE, LIST_Y, ROW_W, 1)
    gLineBot.Move(EDGE, LIST_Y + LIST_H - 1, ROW_W, 1)
    gLineLft.Move(EDGE, LIST_Y, 1, LIST_H)
    gLineRgt.Move(EDGE + ROW_W - 1, LIST_Y, 1, LIST_H)
    gBand.Move(EDGE + 1, LIST_Y + 1, ROW_W - 2, H_HEADER)
    ; 列头与列表列宽同步：占用列固定 122、类型列固定 72，路径列吸收余量
    occX := RIGHT - 129
    typeX := occX - 76
    pathX := EDGE + 8
    pathW := typeX - 4 - pathX
    gHdrPath.Move(pathX, LIST_Y + 1, pathW, H_HEADER)
    gHdrType.Move(typeX, LIST_Y + 1, 72, H_HEADER)
    gHdrOcc.Move(occX, LIST_Y + 1, 122, H_HEADER)

    ; 静态色块逐个失效（不擦背景）—— 只改几何不会触发重画，整窗 Redraw 会闪（K47）。
    for c in [gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt, gBand, gHdrPath, gHdrType, gHdrOcc]
        DllCall("user32\InvalidateRect", "Ptr", c.Hwnd, "Ptr", 0, "Int", 0)

    ; 列表几何交给 gScroll：它按内容超出与否决定给竖条留 10px，再 Move 列表（K43）。
    gScroll.x := EDGE + 1, gScroll.y := LIST_Y + 1 + H_HEADER
    gScroll.w := ROW_W - 2, gScroll.h := LIST_H - 2 - H_HEADER
    gScroll.Layout()
    FixCols()

    xDel := RIGHT - gBtnDel.w
    xUn := xDel - INLINE_GAP - gBtnUnlock.w
    MoveBtn(gBtnUnlock, xUn, ACT_Y)
    MoveBtn(gBtnDel, xDel, ACT_Y)
    gInfo.Move(EDGE, ACT_Y, xUn - EDGE - INLINE_GAP, H_ACTION)

    gStBand.Move(0, ST_Y, cw, H_STATUS)
    gStatus.Move(12, ST_Y, cw - 24, H_STATUS)
    for c in [gStBand, gStatus, gInfo]
        DllCall("user32\InvalidateRect", "Ptr", c.Hwnd, "Ptr", 0, "Int", 0)
}

; 列宽按「可视宽」分配：出现竖条时可视宽少 10px，路径列跟着收，否则长路径被裁。
; 横向条撤掉，列宽做进视口（K30）。改列宽后必须整表 Redraw（K31：行底色停在旧列宽）。
FixCols() {
    global gList, gScroll
    w := gScroll ? gScroll.ClientW() : 0
    if (w <= 0)
        return
    c1 := w - 78 - 128 - 2
    if (c1 < 120)
        c1 := 120
    gList.ModifyCol(1, c1), gList.ModifyCol(2, 78), gList.ModifyCol(3, 128)
    try gList.Redraw()
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

; 检测单个项：展开其下文件，得出「占用程序 / 无占用 / 无权限」
; it.occ 是机器可读码（free/locked/denied/gone），it.names 才是给人看的文案
DetectItem(it) {
    files := []
    CollectFiles(it.path, files)
    if !files.Length {
        it.owners := []
        it.occ := "gone"
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
        nm := ProcName(pid)
        if !InStr("," names ",", "," nm ",")        ; 同名多进程只显示一次
            names .= (names ? ", " : "") nm
    }
    if (lockedCount > 0) {
        it.occ := "locked"
        it.names := names ? names : "占用（无法识别进程）"
    } else if (deniedCount > 0) {
        it.occ := "denied"
        it.names := "无权限"                       ; ACL 拒绝 ≠ 被占用，不误导去解占用
    } else {
        it.occ := "free"
        it.names := "无占用"
    }
}

RefreshList() {
    global gList, gItems, gScroll
    gList.Delete()
    Loop gItems.Length {
        it := gItems[A_Index]
        if !IsObject(it)
            continue
        gList.Add("", it.path, it.kind, it.names)
    }
    ; Delete/Add 会把 WS_VSCROLL 样式位置回、原生条露出（K22/K36）：填完统一重算占位 + 摘条 + 重绘。
    if IsObject(gScroll) {
        gScroll.Layout()
        FixCols()
    }
}

UpdateSummary() {
    global gItems, gInfo, gStatus
    locked := 0, denied := 0
    Loop gItems.Length {
        it := gItems[A_Index]
        if !IsObject(it)
            continue
        if (it.occ = "locked")
            locked++
        else if (it.occ = "denied")
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
            . "`n未保存的数据可能丢失，确定继续？", "文件解锁 · 确认解除", 0x4 | 0x30) != "Yes"
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
    ; 复查状态（先等内核回收被杀进程的句柄，否则会读到残留共享冲突）
    gStatus.Value := "已结束 " killed " 个进程" (failed ? "，失败 " failed " 个" : "") " · 正在复查…"
    Sleep 400
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
    ; 回收站放不进去的项（Windows 保留名 nul/con/aux/prn/com1…）必须提前说清楚
    hard := 0
    for i in idxs {
        if (i >= 1 && i <= gItems.Length && IsReservedName(gItems[i].path))
            hard++
    }
    tip := "将把以下项目放入回收站（可在回收站还原）：`n`n" names
    if hard
        tip .= "`n其中 " hard " 项是 Windows 保留名文件，回收站不支持，只能永久删除。`n"
    if MsgBox(tip . "`n确定继续？", "文件解锁 · 确认删除", 0x4 | 0x30) != "Yes"
    {
        gStatus.Value := "已取消"
        return
    }
    recycled := 0, purged := 0, fail := 0
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
        if (FileAttrs(it.path) = 0xFFFFFFFF) {
            recycled++, removed[i] := 1       ; 已不存在，视为成功
            continue
        }
        ; 被占用先解除（与「解除占用」同一套保护名单），否则回收站也搬不动
        if (it.occ = "locked" && it.owners.Length) {
            KillOwnersOf(it.owners)
            Sleep 200
        }
        res := DeleteItem(it.path)
        if res[1] {
            if (res[3] = "purged")
                purged++
            else
                recycled++
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
    txt := "删除完成 · 回收站 " recycled " 项"
    if purged
        txt .= " · 永久删除 " purged " 项"
    if fail
        txt .= " · 失败 " fail failDetail
    gStatus.Value := txt
}

; ── 删除单项：优先回收站（可还原），保留名只能永久删 ──────────────────
; 返回 [成功?, 错误, "recycled"/"purged"]
DeleteItem(path) {
    if IsReservedName(path) {
        r := IsDirPath(path) ? DeleteDirTree(path) : DeleteOneFile(path)
        return r[1] ? [true, "", "purged"] : [false, r[2], ""]
    }
    r := RecyclePath(path)
    if r[1]
        return [true, "", "recycled"]
    return [false, r[2], ""]
}

; ── 放进回收站：SHFileOperationW(FO_DELETE + FOF_ALLOWUNDO) ───────────
; 不用 \\?\ 前缀（Shell 不认）；目录整棵进回收站，还原时也是整棵回来。
; 失败时**不悄悄改成永久删除**——宁可报错，也不让用户以为还能还原。
RecyclePath(path) {
    if (FSState(path) = "gone")
        return [true, ""]
    buf := Buffer(StrPut(path, "UTF-16") * 2 + 2, 0)   ; 双 null 结尾
    StrPut(path, buf, "UTF-16")
    fos := Buffer(56, 0)
    NumPut("Ptr", 0, fos, 0)                          ; hwnd
    NumPut("UInt", 3, fos, 8)                         ; FO_DELETE
    NumPut("Ptr", buf.Ptr, fos, 16)                   ; pFrom
    NumPut("Ptr", 0, fos, 24)                         ; pTo
    NumPut("UShort", 0x4 | 0x10 | 0x40 | 0x400        ; SILENT|NOCONFIRMATION|ALLOWUNDO|NOERRORUI
        , fos, 32)
    NumPut("Int", 0, fos, 36)                         ; fAnyOperationsAborted
    NumPut("Ptr", 0, fos, 40)                         ; hNameMappings
    NumPut("Ptr", 0, fos, 48)                         ; lpszProgressTitle
    rc := DllCall("shell32\SHFileOperationW", "Ptr", fos, "Int")
    aborted := NumGet(fos, 36, "Int")
    if (!rc && !aborted && FileAttrs(path) = 0xFFFFFFFF)
        return [true, ""]
    if (!rc && !aborted)
        return [false, "回收站未生效"]                  ; rc=0 却还在：少见，按失败报
    if (aborted)
        return [false, "回收站操作被中止"]
    return [false, "回收站失败：" RecycleErrText(rc)]
}

; SHFileOperation 的 DE_* 码翻成人话（原始码留在括号里方便排查）
RecycleErrText(rc) {
    if (rc = 0x78 || rc = 5)
        return "拒绝访问（权限或 ACL）"
    if (rc = 0x7C || rc = 32 || rc = 33)
        return "文件正被占用"
    if (rc = 2 || rc = 3 || rc = 0x7D)
        return "路径不存在"
    if (rc = 0x7E)
        return "文件名不合法"                    ; DE_INVALIDFILES
    if (rc = 0x74)
        return "不在同一磁盘"                    ; DE_DIFFDIR
    return "err=" rc
}

; ── Windows 保留名（回收站与普通 Shell API 都不支持）──────────────────
IsReservedName(path) {
    SplitPath path, &nm
    if (dt := InStr(nm, "."))
        nm := SubStr(nm, 1, dt - 1)
    nm := Trim(nm, " ")
    if (nm = "")
        return false
    base := StrLower(nm)
    if (base = "con" || base = "prn" || base = "aux" || base = "nul")
        return true
    ; com1-com9 / lpt1-lpt9（COM¹ 等上标形式也一并算）
    if (SubStr(base, 1, 3) = "com" || SubStr(base, 1, 3) = "lpt") {
        rest := SubStr(base, 4)
        if (rest = "1" || rest = "2" || rest = "3" || rest = "4" || rest = "5"
            || rest = "6" || rest = "7" || rest = "8" || rest = "9")
            return true
    }
    return false
}

; 结束一批占用进程（保护名单内的跳过）
KillOwnersOf(owners) {
    for pid in owners {
        nm := ProcName(pid)
        if !CRITICAL_PROCS.Has(StrLower(nm))
            KillProcess(pid, nm)
    }
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
    ; 幂等：Loop Files 给出的 \\?\ 路径会再进 DeleteOneFile/ClearAttributes，
    ; 重复前缀会变成 \\?\UNC\?\E:\... → DeleteFileW err=53（1.1.3 的真 bug）
    Emit((NtPath("\\?\C:\a\b") = "\\?\C:\a\b" ? "PASS " : "FAIL ") "NtPath 幂等（已带 \\?\ 不加第二层）")
    ; 保留名识别：回收站放不进去，删除时必须走永久删分支并如实提示
    Emit((IsReservedName("C:\a\nul") ? "PASS " : "FAIL ") "保留名识别 nul")
    Emit((IsReservedName("C:\a\CON.txt") ? "PASS " : "FAIL ") "保留名识别 CON.txt（带扩展名也算）")
    Emit((IsReservedName("C:\a\com7") ? "PASS " : "FAIL ") "保留名识别 com7")
    Emit((!IsReservedName("C:\a\console.txt") ? "PASS " : "FAIL ") "普通文件名不误判为保留名")

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

    ; 5. 删含子目录的文件夹：覆盖 "Loop Files 给出 \\?\ 路径 → 再进删除函数" 这条链路
    dt := A_Temp "\ahkdeck_deltree_" myPid
    try DirDelete(dt, 1)
    try DirCreate(dt "\sub")
    try FileAppend("x", dt "\a.txt")
    try FileAppend("y", dt "\sub\b.txt")
    dres := DeleteDirTree(dt)
    Emit((dres[1] ? "PASS " : "FAIL ") "删除含子目录的文件夹（自底向上）" (dres[1] ? "" : " " dres[2]))
    try DirDelete(dt, 1)

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
