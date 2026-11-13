; ==UserScript==
; @name         打开方式清理
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.5.4
; @description  扫描 Windows「打开方式」相关的 13 处注册表位置，列出并清理失效残留
; @author       邱宗满
; @date         2026-11-13
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
; 1.3.0 按 开发指南 §10 统一原生 UI：s9→s10、八色浅底黑字、按钮改 1px 描边色块、
; 状态条与标题栏同为 #DCE8F7，主窗口与历史窗口按 EDGE=16 / 行宽=客户区−32 重排；
; 自绘行色与状态字色改回令牌色，加粗不再用于数据行。原生 ListView 列头（ColClick 排序）、
; Checked 勾选框（动态行数）与原生滚动条保留，是 §10.10 登记的例外，理由见 info/HISTORY.md。
; 1.4.0 把列头与滚动条两条例外收掉：列头改自绘 BAND 带（点击仍走 OnColClick 排序），
; 滚动条整段复制 文件时间修改 的 FlatScroll 自绘；Checked 勾选框仍保留（行数动态、
; §10 没有逐行自绘配方），是唯一剩余例外。
; 1.5.0 修两个实机缺陷：滚轮此前完全不滚（原生滚动条被摘掉样式位后，ListView 不再响应
; 滚轮与键盘翻页，滚动范围也塌成 0），改为自管竖向滚动状态并由脚本接管滚轮与翻页；
; 最大化再复原后列表右侧留一大块白（改列宽后行底色范围停在旧列宽），改为改完列宽整表重绘。
; 横向滚动条撤掉：横向 LVM_SCROLL 实测不生效，那根条一直是装饰品，列宽改为做进视口。

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

; ── §10 UI 配方（单文件平铺，禁止 #Include 共享库） ─────────────────────

; 浅色底 + 近黑字之后按钮靠 1px 描边立形；两块都挂 Click，否则点在描边上没反应。
; 不用系统 Button：宿主缺 comctl32 v6 manifest 时系统控件退回经典 3D 凸起。
; 按钮是「外层描边块 + 内块」两层，返回值仍只给内块（调用方常拿它 .Move/.Enabled）；
; 外框句柄另存一张表，窗口重排时按内块句柄反查，两层一起挪。
gBtnFrames := Map()
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    global gBtnFrames
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    gBtnFrames[b.Hwnd] := f
    return b
}

; 内外两层一起挪：只挪内块的话，外层描边块会留在原地露出旧边。
MoveFlatButton(body, x, y, w, h) {
    global gBtnFrames
    f := gBtnFrames.Has(body.Hwnd) ? gBtnFrames[body.Hwnd] : 0
    if f
        f.Move(x, y, w, h)
    body.Move(x + 1, y + 1, w - 2, h - 2)
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

; 原生 StatusBar 没有 .Value、Win11 下 Background 需 -Theme、c 文字色无效，还自带分隔线；
; 改两块 Text 色块并保留 SetText() 接口，让全部既有调用点零改动。
; 类声明是运行期语句、不会被提升，必须写在 auto-execute 段之前（K18）。
class FlatStatus {
    __New(g, x, y, w, h, text := "") {
        this.band := g.Add("Text", "x" x " y" y " w" w " h" h " BackgroundDCE8F7")
        this.text := g.Add("Text", "x" (x + 12) " y" y " w" (w - 24) " h" h
            " BackgroundDCE8F7 c202B3A +0x200", text)
    }
    SetText(v) {
        if this.text
            this.text.Value := v
    }
    Move(x, y, w, h) {
        this.band.Move(x, y, w, h)
        this.text.Move(x + 12, y, w - 24, h)
    }
}

; 原生 ListView 的滚动条由 comctl32 的主题引擎画，脚本层拿不到颜色：WM_CTLCOLORSCROLLBAR
; 实测一次都不触发，SetWindowTheme("DarkMode_Explorer") 也只给浅色/深色两套外观。
; 所以隐藏原生条、用色块自绘一条：槽 #DCE8F7、滑块 #6E9BD4，与整体配色同一套令牌。
; 隐藏用 ShowScrollBar(FALSE) 而不是 -VScroll —— 去掉样式后控件不再维护滚动范围，
; 只隐藏则范围与滚动都保留（实测竖 0..39/页 7、横 0..599/页 355 均可读可滚）。
; 滚动统一走 LVM_SCROLL 像素增量，滚轮、点击槽、拖动滑块都汇到这一条通路；
; 滑块位置每帧从真实 nPos 反算，所以键盘翻页、滚轮之后也不会错位。
class FlatScroll {
    __New(g, lv, x, y, w, h, t := 10) {
        this.g := g, this.lv := lv
        this.x := x, this.y := y, this.w := w, this.h := h, this.t := t
        ; 系统样式：轨道整条宽 t（浅蓝），滑块比轨道窄，居中浮在里面（深蓝）。
        ; 滑块厚度 = t-6，两侧各留 3px 露出轨道；t=10 → 轨道 10、滑块 4。
        this.tn := Max(3, t - 6), this.off := (t - this.tn) // 2
        ; 条的「开口端」各让 pad 的空隙：滑块拖到端点时不会跟列表边框、相邻的条粘成一整块。
        ; 与角落相接的一端不留（那本来就是闭合端），否则角落处会多一道缝。
        this.pad := 2
        this.lvW := 0, this.lvH := 0, this.itemH := 23
        this.exV := false, this.exH := false, this.dead := false
        this.lastV := -1, this.lastH := -1
        this.lastCount := -1
        this.rows := 0, this.viewRows := 1, this.top := 0, this.maxTop := 0
        this.ops := []
        ; 拖动轴 1=竖 0=横，用独立布尔记录「是否在拖」，别拿轴号兼作标志：横轴是 0，会被判成假。
        this.dragging := false, this.dragAxis := 1
        ; +0x100 是 SS_NOTIFY：不加的静态控件对命中测试返回 HTTRANSPARENT，点击会穿透到父窗口，
        ; 自绘条就永远收不到 WM_LBUTTONDOWN（实测 hwnd 全是主窗口）。
        ; 轨道拆成「滑块前」「滑块后」两段，与滑块永不重叠 —— 叠放时谁在上由 z 序决定，
        ; 宿主里实测 SetWindowPos 抬到 HWND_TOP 也压不住，索性别让它有重叠关系。
        this.vUp := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vDn := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.hLt := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.hRt := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        ; 滑块比轨道窄，滑块那一段的两侧各留一条同色细缝，轨道才是连续的一条浅蓝槽；
        ; 这四条缝与滑块沿轴相邻、宽窄错开，几何上依旧不重叠。
        this.vGapL := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapR := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.hGapT := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.hGapB := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumbV := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        this.thumbH := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        this.corner := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        for c in [this.vUp, this.vDn, this.hLt, this.hRt, this.vGapL, this.vGapR
            , this.hGapT, this.hGapB, this.thumbV, this.thumbH, this.corner]
            c.Visible := false
    }

    ; 内容超出才占位，与原生一致：按当前尺寸量一次，超出就缩列表再量，最多三轮收敛。
    Layout() {
        if (!this.lv.Hwnd)
            return
        loop 3 {
            this.HideNative()
            ; 竖向滚动状态自己维护：原生条摘掉后 ListView 不再算范围，也不再响应
            ; 滚轮与键盘翻页（实测），所以行数、可视行数、首行号都自己掌握。
            this.Measure()
            w := this.w - (this.exV ? this.t : 0)
            hh := this.h
            if (w = this.lvW && hh = this.lvH)
                break
            this.lv.Move(this.x, this.y, w, hh)
            this.lvW := w, this.lvH := hh
        }
        ; Move() 本身就会让 ListView 重算滚动条并把原生条重新显示（实测样式位被置回），
        ; 循环最后一步正是 Move，所以收尾必须再清一次 —— 否则原生条与自绘条同时出现。
        this.HideNative()
        if (this.lv.GetCount() > 0) {
            rc := Buffer(16, 0)
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x100E, "Ptr", 0, "Ptr", rc, "Ptr")
            ih := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
            if (ih > 0)
                this.itemH := ih
        } else if (this.Info(0).pos > 0) {
            ; 清空后横向位置可能停在中间，再拖入时就看不到路径开头了，归零。
            this.ScrollTo(0, 0)
        }
        this.Paint()
    }

    Place() {
        this.ops := []
        t := this.t
        this.Put(this.corner, this.exV && this.exH, this.x + this.lvW, this.y + this.lvH, t, t)
    }

    ; 一次 Paint 里的所有色块用 DeferWindowPos 批量提交。逐个 Move 时屏幕上会出现
    ; 「槽已让位、滑块还没到」的中间帧 —— 拖动时就是一道道断点；批量提交只有一次
    ; 布局，中间帧不存在。
    Put(c, on, x, y, w, h) {
        this.ops.Push({ c: c.Hwnd, on: on && w > 0 && h > 0, x: x, y: y, w: w, h: h })
    }

    Flush() {
        ops := this.ops
        this.ops := []
        if (!ops.Length)
            return
        h := DllCall("user32\BeginDeferWindowPos", "Int", ops.Length, "Ptr")
        if (!h)
            return
        for o in ops {
            f := 0x0004 | 0x0010                        ; SWP_NOZORDER | SWP_NOACTIVATE
            if (o.on)
                h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", o.c, "Ptr", 0
                    , "Int", o.x, "Int", o.y, "Int", o.w, "Int", o.h, "UInt", f | 0x0040, "Ptr")
            else
                h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", o.c, "Ptr", 0
                    , "Int", 0, "Int", 0, "Int", 0, "Int", 0
                    , "UInt", f | 0x0080 | 0x0001 | 0x0002, "Ptr")
        }
        DllCall("user32\EndDeferWindowPos", "Ptr", h)
    }

    ; 滑块可用行程：两端各让 pad，滑块走到尽头时四周仍有一圈槽色，不会跟列表边界、
    ; 角落方块「粘」成一整块。轨道本身照旧铺满，槽不会被咬出缺口。
    ; Paint 与 BeginDrag 必须用同一个口径，否则拖动时滑块会比手指走得快或慢。
    TrackLen(v) {
        return (v ? this.lvH : this.lvW) - this.pad * 2
    }

    ; 滑块位置每帧从 nPos 反算，任何来源的滚动都会在下一拍自动对齐；
    ; 轨道两段随滑块重算，所以滑块与轨道之间永远没有空隙。
    Paint() {
        t := this.t, tn := this.tn, off := this.off, pd := this.pad
        this.Place()
        if (this.exV) {
            g := this.Geo(1, this.TrackLen(1))
            bx := this.x + this.lvW
            a := this.y + pd + g.start
            b := a + g.len
            this.Put(this.vUp, true, bx, this.y, t, pd + g.start)
            this.Put(this.vDn, true, bx, b, t, this.y + this.lvH - b)
            this.Put(this.vGapL, true, bx, a, off, g.len)
            this.Put(this.vGapR, true, bx + off + tn, a, t - off - tn, g.len)
            this.Put(this.thumbV, true, bx + off, a, tn, g.len)
        } else {
            this.Put(this.vUp, false, 0, 0, 0, 0)
            this.Put(this.vDn, false, 0, 0, 0, 0)
            this.Put(this.vGapL, false, 0, 0, 0, 0)
            this.Put(this.vGapR, false, 0, 0, 0, 0)
            this.Put(this.thumbV, false, 0, 0, 0, 0)
        }
        if (this.exH) {
            g := this.Geo(0, this.TrackLen(0))
            by := this.y + this.lvH
            a := this.x + pd + g.start
            b := a + g.len
            this.Put(this.hLt, true, this.x, by, pd + g.start, t)
            this.Put(this.hRt, true, b, by, this.x + this.lvW - b, t)
            this.Put(this.hGapT, true, a, by, g.len, off)
            this.Put(this.hGapB, true, a, by + off + tn, g.len, t - off - tn)
            this.Put(this.thumbH, true, a, by + off, g.len, tn)
        } else {
            this.Put(this.hLt, false, 0, 0, 0, 0)
            this.Put(this.hRt, false, 0, 0, 0, 0)
            this.Put(this.hGapT, false, 0, 0, 0, 0)
            this.Put(this.hGapB, false, 0, 0, 0, 0)
            this.Put(this.thumbH, false, 0, 0, 0, 0)
        }
        this.Flush()
    }

    ; ShowScrollBar 只是「按需要隐藏」，ListView 每次重算滚动范围（Move/Add/Delete/
    ; ModifyCol）都会把它自己那份置回来，所以这是「每次动作后都要补一刀」的操作，
    ; 不是一劳永逸的初始化。样式位残留时才算真被置回。
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

    ; 自己维护的竖向滚动状态。
    Measure() {
        this.rows := this.lv.GetCount()
        this.top := this.ReadTop()
        this.viewRows := Max(1, Floor(this.lvH / this.itemH))
        this.maxTop := Max(0, this.rows - this.viewRows)
        this.exV := this.rows > this.viewRows
        ; 横向 LVM_SCROLL 实测不生效，横向条不画，列宽由调用方做进视口。
        this.exH := false
    }

    ReadTop() {
        return DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1027, "Ptr", 0, "Ptr", 0, "Ptr")
    }

    ; 滚到指定首行：向下滚用「让目标视区最后一行可见」，向上滚用「让目标行可见」，
    ; 两者都走 LVM_ENSUREVISIBLE（摘掉原生条后依然精确到位）。
    ScrollToRow(target) {
        if (!this.exV)
            return
        target := Max(0, Min(this.maxTop, target))
        if (target = this.top)
            return
        if (target > this.top) {
            last := Min(this.rows - 1, target + this.viewRows - 1)
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1013, "Ptr", last, "Ptr", 0, "Ptr")
        } else {
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1013, "Ptr", target, "Ptr", 0, "Ptr")
        }
        ; LVM_ENSUREVISIBLE 会让 ListView 重算滚动范围、把 WS_VSCROLL 重新置回，
        ; 原生灰条于是露出来（实测：滚动后右侧出现 16px 的 F0F0F0）。
        ; 不能等 Sync 的 60ms 兜底 —— 每次滚动动作后必须当场再藏一次。
        this.HideNative()
        this.top := this.ReadTop()
        this.Paint()
    }

    ScrollRows(n) {
        this.ScrollToRow(this.top + n)
    }

    ; 滚轮增量：正数向上，一格 120，滚动 3 行。
    OnWheelDelta(delta) {
        this.ScrollRows(-Round(delta / 120) * 3)
    }

    ; 键盘翻页。返回 1 表示已处理，调用方要压掉默认处理。
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

    ; 列表可视宽（已扣掉自绘竖条占位），外部按它分列宽。
    ClientW() {
        return this.lvW
    }

    Info(bar) {
        si := Buffer(28, 0)
        NumPut("UInt", 28, si, 0)
        NumPut("UInt", 0x17, si, 4)
        DllCall("user32\GetScrollInfo", "Ptr", this.lv.Hwnd, "Int", bar, "Ptr", si)
        return { min: NumGet(si, 8, "Int"), max: NumGet(si, 12, "Int")
            , page: NumGet(si, 16, "UInt"), pos: NumGet(si, 20, "Int") }
    }

    ; len 滑块长度、start 滑块起点、ext 可滚动行程、span 滑块可用行程
    Geo(bar, trackLen) {
        if (bar) {
            ; 竖向自己算：滑块长度 = 可视行数占比，位置 = 首行号占比。
            len := Max(24, Min(trackLen, Round(trackLen * this.viewRows / Max(1, this.rows))))
            span := trackLen - len
            frac := (this.maxTop > 0) ? this.top / this.maxTop : 0
            return { len: len, start: Round(frac * span), ext: this.maxTop, span: span }
        }
        s := this.Info(0)
        ext := Max(0, s.max - s.page + 1)
        len := Round(trackLen * s.page / Max(1, s.max - s.min + 1))
        len := Max(24, Min(trackLen, len))
        span := trackLen - len
        frac := (ext > 0 && span > 0) ? (s.pos - s.min) / ext : 0
        return { len: len, start: Round(frac * span), ext: ext, span: span }
    }

    ; v=1 竖（单位行），v=0 横（单位像素）
    ; LVM_SCROLL 自己也会把原生条置回来（实测滚动后样式位立刻变 H1V1），所以每次滚动
    ; 之后要立刻补一刀 —— 否则拖动时原生条会跟着滑块一起出现在画面上。
    ; 竖向一律走 ScrollToRow（LVM_ENSUREVISIBLE）；横向 LVM_SCROLL 实测不生效，
    ; 旧代码还把 delta 传给了 wParam（那应是 SB_HORZ），所以横向条一直是装饰品，
    ; 这次直接不画，列宽由调用方做进视口。
    ScrollBy(v, delta) {
        if (v)
            this.ScrollRows(delta)
    }

    ScrollTo(v, target) {
        if (v)
            this.ScrollToRow(target)
    }

    ; 滑块只有 6px，两侧 2px 的缝也算滑块热区（与系统一致：整条槽宽都能抓），
    ; 所以点缝等同于抓滑块拖动，而不是翻页。
    OnDown(hwnd) {
        axis := -1
        if (hwnd = this.thumbV.Hwnd || hwnd = this.vGapL.Hwnd || hwnd = this.vGapR.Hwnd)
            axis := 1
        else if (hwnd = this.thumbH.Hwnd || hwnd = this.hGapT.Hwnd || hwnd = this.hGapB.Hwnd)
            axis := 0
        if (axis >= 0) {
            this.BeginDrag(axis)
            return
        }
        if (hwnd = this.vUp.Hwnd || hwnd = this.vDn.Hwnd)
            this.PageJump(1)
        else if (hwnd = this.hLt.Hwnd || hwnd = this.hRt.Hwnd)
            this.PageJump(0)
    }

    ; 槽上空白处翻一页，方向按鼠标落在滑块前还是后来判断。
    PageJump(v) {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := v ? NumGet(pt, 4, "Int") : NumGet(pt, 0, "Int")
        r := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "Ptr", (v ? this.thumbV : this.thumbH).Hwnd, "Ptr", r)
        a := NumGet(r, v ? 4 : 0, "Int")
        b := NumGet(r, v ? 12 : 8, "Int")
        dir := (c < a || c > b) ? (c < a ? -1 : 1) : 1
        this.ScrollBy(v, dir * this.Info(v ? 1 : 0).page)
    }

    ; 拖动用轮询而不是 SetCapture + 鼠标消息：Text 控件只在抬起时给一次 Click，
    ; 拿不到中途移动，轮询 GetCursorPos 反而稳，且不依赖控件自身的命中矩形。
    BeginDrag(v) {
        s := this.Info(v ? 1 : 0)
        g := this.Geo(v ? 1 : 0, this.TrackLen(v))
        if (g.ext <= 0 || g.span <= 0)
            return
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        this.dragging := true, this.dragAxis := v, this.gBase := g, this.pBase := v ? this.top : s.pos
        this.cBase := v ? NumGet(pt, 4, "Int") : NumGet(pt, 0, "Int")
        DllCall("user32\SetCapture", "Ptr", (v ? this.thumbV : this.thumbH).Hwnd)
        SetTimer(ObjBindMethod(this, "DragTick"), 20)
    }

    DragTick() {
        if (!GetKeyState("LButton", "P")) {
            SetTimer(ObjBindMethod(this, "DragTick"), 0)
            DllCall("user32\ReleaseCapture")
            this.dragging := false
            return
        }
        if (!this.dragging)
            return
        v := this.dragAxis
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := v ? NumGet(pt, 4, "Int") : NumGet(pt, 0, "Int")
        g := this.gBase
        start := Max(0, Min(g.span, g.start + (c - this.cBase)))
        this.ScrollTo(v, this.pBase + Round((start - g.start) / g.span * g.ext))
    }

    ; 滚轮落在自绘条上时转发给列表，否则列表收不到。
    OnWheel(hwnd, wp) {
        if (hwnd != this.vUp.Hwnd && hwnd != this.vDn.Hwnd && hwnd != this.thumbV.Hwnd
            && hwnd != this.hLt.Hwnd && hwnd != this.hRt.Hwnd && hwnd != this.thumbH.Hwnd
            && hwnd != this.vGapL.Hwnd && hwnd != this.vGapR.Hwnd
            && hwnd != this.hGapT.Hwnd && hwnd != this.hGapB.Hwnd
            && hwnd != this.corner.Hwnd)
            return
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        l := NumGet(pt, 0, "Int") | (NumGet(pt, 4, "Int") << 32)
        DllCall("user32\PostMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x20A, "Ptr", wp, "Ptr", l)
        return 0
    }

    ; 键盘翻页、滚轮、拖动都会改 nPos，统一在这一拍对齐滑块；
    ; 顺手兜一次原生条（万一被别的重算动作置回来了）。拖动中只兜原生条、不重排色块 ——
    ; DragTick 已经在画了，两处同时画会在同一帧里交叉，正是断点的来源。
    ; 每拍只在 nPos 真的变了才重排控件 —— 空闲时窗口里十几个色块不该被无谓 Move。
    Sync() {
        if (this.dead)
            return
        try {
            this.EnsureHidden()
            if (this.dragging)
                return
            ; 行数变化（扫描/筛选/删除/恢复）会改变滚动范围，必须重算占位。
            ; 放到每拍里自检，比依赖外部调用点可靠 —— 外部守卫漏一次就再也不画条。
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

    ; 定时器会让脚本在窗口关闭后继续存活，必须显式停掉，否则下一拍就会去访问
    ; 已销毁的列表控件（报「The control is destroyed」）。关闭窗口前先 Stop()。
    Stop() {
        if (this.dead)
            return
        this.dead := true
        SetTimer(ObjBindMethod(this, "Sync"), 0)
        SetTimer(ObjBindMethod(this, "DragTick"), 0)
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
    if (gScroll)
        gScroll.OnDown(hwnd)
}

OnBarWheel(wp, lp, msg, hwnd) {
    global gScroll, S
    if (!gScroll)
        return
    delta := (wp >> 16) & 0xFFFF
    if (delta & 0x8000)
        delta := delta - 0x10000
    ; 落在本窗口任意控件上都滚列表：原生滚动条被摘掉后 ListView 自己不再处理滚轮。
    if (S.gui.Hwnd && DllCall("user32\IsChild", "Ptr", S.gui.Hwnd, "Ptr", hwnd)) {
        gScroll.OnWheelDelta(delta)
        return 1
    }
    return
}

; 键盘翻页：只在列表控件上接管，别的控件保持原生行为。
OnBarKey(wp, lp, msg, hwnd) {
    global gScroll, S
    if (!gScroll || !S.lv || hwnd != S.lv.Hwnd)
        return
    if (gScroll.OnKey(wp))
        return 1
    return
}

; 列头文案也是列宽与排序的索引，主窗口与状态条共用同一份。
HDR := ["✓", "扩展名", "程序 / 关联标识", "显示名称", "状态", "来源"]

; 箭头函数不能直接在 for 里捕获循环变量（会全部指向最后一个 i），
; 用带参数的函数包一层，n 是每次调用的局部值。
HeaderClick(n) {
    global S
    return (*) => OnColClick(S.lv, n)
}

S := {
    all: [], view: [], seen: Map(), dupes: 0,
    mui: Map(), exe: Map(), pid: Map(), fname: Map(), pathDirs: [],
    gui: 0, lv: 0, lvFrame: 0, sb: 0, search: 0,
    fTop: 0, fBot: 0, fLft: 0, fRgt: 0,
    hdr: [], hdrBand: 0, colW: [],
    scanning: false, steps: [], step: 0, t0: 0, scanMs: 0,
    sortCol: 0, sortDesc: false, mutex: 0, nextEid: 1,
    histGui: 0, histList: 0, histFiles: [], histView: 0, histRestore: 0, histDirty: false
}
gSortRank := Map()
gSortCb := 0
; --selftest / --report 不走 BuildGui，gScroll 一直为空；AHK v2 读「声明过但未赋值」
; 的 global 会抛错（不是空值），所以必须在这里给初值，UpdateStatus 的守卫才安全。
gScroll := 0

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

; 类型/应用的显示名。顺序按「谁更可信」排，不以「哪条先读到」为准：
; ① MuiCache（资源管理器自己登记过的名称，应用类几乎都在这里）；
; ② FriendlyTypeName（Shell 显示类型名用的正是它，常见是 "@dll,-123" 间接串，
;    要 SHLoadIndirectString 解成本地化文本）；
; ③ 键的默认值 —— 最后才用。它不是 Shell 的取数口，而且可能被旧软件写坏：
;    实测本机 HKCR\txtfile 的默认值是 UTF-8 字节直接写进 REG_SZ 的产物
;    （U+93C2 U+56E8 U+6E70 U+93C2 U+56E8 U+3002 = 「文本文档」的 UTF-8 被按 GBK 读），
;    显示出来就是那种「没见过的中文」。优先级排对，脏数据自然被绕开。
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
    if (result = "")
        result := ResolveIndirect(ReadStr("HKCR\" prog, "FriendlyTypeName"))
    if (result = "") {
        result := ReadStr("HKCR\" prog)
        if (result = "")
            result := ReadStr("HKCR\" prog "\Application", "ApplicationName")
    }
    S.fname[prog] := result
    return result
}

; "@%SystemRoot%\system32\shell32.dll,-30598" 这类间接串交给 Shell 自己解，
; 拿到的是当前 UI 语言的正式名称；解不出来（dll 缺失、索引越界）返回空串，交回上层兜底。
ResolveIndirect(s) {
    if (s = "" || SubStr(s, 1, 1) != "@")
        return s
    buf := Buffer(2048, 0)
    if DllCall("shlwapi\SHLoadIndirectString", "WStr", s, "Ptr", buf, "UInt", 1024, "Ptr", 0, "Ptr") != 0
        return ""
    return StrGet(buf, "UTF-16")
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
    S.sb.SetText("正在扫描 · 1/" S.steps.Length)
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
        S.sb.SetText("正在扫描 · " (i + 1) "/" S.steps.Length)
}

; ── 主窗口 ──────────────────────────────────────────────────────────

BuildGui() {
    global S, gScroll, HDR
    ; 版式照 开发指南 §10：客户区 1100×650，行宽 1068（1100−16×2）。工具行
    ; 58+58+96+32+516+84+84+84 + 7×8 = 1068；按钮宽由文字定，搜索框吃余量。
    ; 列表区靠 FRAME 父块露 1px 线，状态条贴窗口底 h30，caption 与它同为 #DCE8F7。
    ; 原生列头（ColClick 排序）与 Checked 勾选框（动态行数）保留，属 §10.10 例外。
    g := Gui("+Resize +MinSize800x450", "打开方式清理")
    g.BackColor := "F7F9FC"
    g.SetFont("s10", "Microsoft YaHei UI")
    S.gui := g

    ; 工具行 y12 h28：全部绝对坐标，同排同 y 同 h。
    FlatButton(g, 16, 12, 58, 28, "刷新", "EBF2FB", "B7C8E0", (*) => StartScan())
    FlatButton(g, 82, 12, 58, 28, "全选", "EBF2FB", "B7C8E0", (*) => ToggleAll())
    FlatButton(g, 148, 12, 96, 28, "删除失效项", "EBF2FB", "B7C8E0", (*) => DeleteMissing())
    g.Add("Text", "x252 y12 w32 h28 BackgroundF7F9FC c202B3A +0x200", "搜索")
    ; 工具行分三段：左侧 3 个固定按钮、右侧 3 个贴右缘按钮、中间搜索框吃余量。
    ; 三个右侧按钮的句柄要留着，OnGuiSize 里随窗口宽度一起挪。
    S.searchFrame := g.Add("Text", "x292 y12 w516 h28 BackgroundB7C8E0")
    S.search := g.Add("Edit", "x293 y13 w514 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(S.search.Hwnd, 8, 2, 508, 26)
    S.search.OnEvent("Change", (*) => SetTimer(ApplySearch, -250))
    S.btnCopy := FlatButton(g, 816, 12, 84, 28, "复制路径", "EBF2FB", "B7C8E0", (*) => CopyPath())
    S.btnDel := FlatButton(g, 908, 12, 84, 28, "删除选中", "EBF2FB", "B7C8E0", (*) => DeleteChecked())
    S.btnHist := FlatButton(g, 1000, 12, 84, 28, "历史记录", "EBF2FB", "B7C8E0", (*) => ShowHistory())

    ; 白底块与列表同 x/y/w/h，四条 1px FRAME 色块各占一边（§10.4「色块当线」）。
    ; 不铺大块 FRAME：原生 ListView 在列宽之外与空白行不保证重绘，会漏出一大片底色。
    S.lvFrame := g.Add("Text", "x16 y46 w1068 h568 BackgroundFFFFFF")
    S.fTop := g.Add("Text", "x16 y46 w1068 h1 BackgroundB7C8E0")
    S.fBot := g.Add("Text", "x16 y613 w1068 h1 BackgroundB7C8E0")
    S.fLft := g.Add("Text", "x16 y46 w1 h568 BackgroundB7C8E0")
    S.fRgt := g.Add("Text", "x1083 y46 w1 h568 BackgroundB7C8E0")

    ; 列头自带绘：-Hdr 去掉 comctl32 的经典 3D 列头，点击仍走原来的 OnColClick 排序。
    ; 加粗只给列头，写完立刻 Norm 还原（§10.2.2）。
    S.hdrBand := g.Add("Text", "x17 y47 w1066 h26 BackgroundDCE8F7")
    g.SetFont("s10 Bold", "Microsoft YaHei UI")
    for t in HDR
        S.hdr.Push(g.Add("Text", "x0 y47 w0 h26 BackgroundDCE8F7 c202B3A +0x200", t))
    g.SetFont("s10 Norm", "Microsoft YaHei UI")
    for i, c in S.hdr
        c.OnEvent("Click", HeaderClick(i))

    S.lv := g.Add("ListView", "x17 y73 w1066 h540 Checked -Grid -Multi -Hdr -E0x200 BackgroundFFFFFF c202B3A", HDR)
    S.lv.OnEvent("DoubleClick", OnRowDouble)
    S.lv.OnEvent("ContextMenu", OnRowContext)

    ; 原生滚动条由主题引擎画且拿不到颜色，整段复用已验证的 FlatScroll（槽 BAND / 滑块 ACCENT）。
    gScroll := FlatScroll(g, S.lv, 17, 73, 1066, 540)
    SetTimer(ObjBindMethod(gScroll, "Sync"), 60)
    HookBarInput()

    S.sb := FlatStatus(g, 0, 620, 1100, 30, "就绪")
    g.OnEvent("Size", OnGuiSize)
    g.OnEvent("Close", (*) => (gScroll.Stop(), ExitApp()))
    g.Show("w1100 h650 Center")
    PaintCaption(g.Hwnd)
    OnMessage(0x004E, LvNotify)
    OnExit(Cleanup)
    g.GetClientPos(,, &cw, &ch)
    OnGuiSize(g, 0, cw, ch)
}

Cleanup(*) {
    global S, gSortCb, gScroll
    if gScroll
        gScroll.Stop()
    if gSortCb
        CallbackFree(gSortCb)
    if S.mutex
        DllCall("CloseHandle", "Ptr", S.mutex)
    return 0
}

OnGuiSize(g, state, w, h) {
    global S, gScroll
    if (!S.lv || w < 100 || h < 100)
        return
    ; 行宽 = 客户区 − 32；列表底 = 状态条顶 − BLOCK_GAP(6)，状态条 h30 贴底。
    lvW := w - 32
    lvH := h - 82
    S.lvFrame.Move(16, 46, lvW, lvH)
    S.fTop.Move(16, 46, lvW, 1)
    S.fBot.Move(16, 46 + lvH - 1, lvW, 1)
    S.fLft.Move(16, 46, 1, lvH)
    S.fRgt.Move(16 + lvW - 1, 46, 1, lvH)
    S.hdrBand.Move(17, 47, lvW - 2, 26)

    ; 工具行：右侧三个按钮贴右缘（各 84 宽、间距 8），搜索框吃掉剩余宽度。
    ; 按钮宽由文字定死，所以只挪位置；搜索框要同时改框线与文本块的宽度。
    histX := w - 16 - 84
    delX := histX - 8 - 84
    copyX := delX - 8 - 84
    MoveFlatButton(S.btnCopy, copyX, 12, 84, 28)
    MoveFlatButton(S.btnDel, delX, 12, 84, 28)
    MoveFlatButton(S.btnHist, histX, 12, 84, 28)
    searchW := copyX - 8 - 292
    if (searchW < 120)
        searchW := 120
    S.searchFrame.Move(292, 12, searchW + 2, 28)
    S.search.Move(293, 13, searchW, 26)
    SetEditRect(S.search.Hwnd, 8, 2, searchW - 6, 26)

    ; 原生滚动条在列表内部：先定列表尺寸，再按「可视宽」（已扣掉原生竖条）分配列宽，
    ; 否则列宽按窗口宽算会多出一条，溢出到横向条上。
    if gScroll {
        gScroll.x := 17, gScroll.y := 73
        gScroll.w := lvW - 2, gScroll.h := lvH - 2 - 26
        gScroll.Layout()
    }
    usable := gScroll ? gScroll.ClientW() : lvW - 2
    progW := usable - 680
    if (progW < 160)
        progW := 160
    nameW := usable - 310 - progW
    if (nameW < 200)
        nameW := 200
    S.colW := [30, 80, progW, nameW, 70, 130]
    ; 列头文字块 x = 该列起点 + CELL_PAD 6，宽 = 列宽 − 12，末列不得越出带右缘。
    hx := 17
    for i, cw in S.colW {
        S.lv.ModifyCol(i, cw)
        S.hdr[i].Move(hx + 6, 47, Max(0, Min(cw - 12, 17 + usable - hx - 6)), 26)
        hx += cw
    }
    ; 列宽变了，横向溢出状态可能跟着变，原生条再定一次。
    if gScroll
        gScroll.Layout()
    ; 改列宽后 ListView 的行底色范围会停在旧列宽的位置（实测：满宽 1023px 缩到 478px，
    ; 最大化后复原也不恢复），必须整表重绘，否则右侧留下一大块白。
    S.lv.Redraw()
    S.sb.Move(0, h - 30, w, 30)
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
        NumPut("UInt", (row & 1) ? 0x00FCF9F7 : 0xFFFFFF, lp, 84)
        return 0x20
    }
    if (stage = 0x30001) {
        if (NumGet(lp, 88, "Int") != 4)
            return 0
        row := NumGet(lp, 56, "UInt") + 1
        if (row < 1 || row > S.view.Length)
            return 0
        ; 状态靠「有效 / 未找到 / 未知」的文字区分，不用绿橙灰，也不给数据行加粗。
        NumPut("UInt", 0x3A2B20, lp, 80)
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
    global S, gScroll
    top := SendMessage(0x1027, 0, 0, S.lv.Hwnd)
    foc := S.lv.GetNext(0, "Focused")
    focEntry := foc ? S.view[foc] : 0
    hadFocus := S.gui.FocusedCtrl && S.gui.FocusedCtrl.Hwnd = S.lv.Hwnd
    ; ★ 填表期间把列表整个藏起来。
    ; WM_SETREDRAW 只压得住「客户端」绘制，压不住非客户区：行一多 comctl32 就把竖条
    ; 置回并**当场把滚动条刷出来**；竖条又让客户区窄 16px，按整幅宽算好的列宽立刻溢出，
    ; 横条跟着再冒一条 —— 屏幕上就是「空列表 + 两条原生灰条」（实测截图复现）。
    ; 藏起来的窗口一个像素都不画，填完再 SW_SHOW，一次干净的整幅重绘。
    DllCall("user32\ShowWindow", "Ptr", S.lv.Hwnd, "Int", 0)      ; SW_HIDE
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
    ; 滚动定位与焦点也在「不可见」区间里做完。
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
    ; 摘条 → 打开重绘 → 显示 → 画自绘条。顺序不能动：显示之后 ListView 会连非客户区
    ; 一起重刷，样式位还在就等于把灰条画到屏幕上。
    if gScroll
        gScroll.HideNative()
    SendMessage(0x100B, 1, 0, S.lv.Hwnd)
    DllCall("user32\ShowWindow", "Ptr", S.lv.Hwnd, "Int", 5)      ; SW_SHOW
    ; 藏过一次以后焦点会丢，键盘翻页、Delete 键就哑了，补回来。
    ; 本来就没焦点时（启动后第一次填表）也把焦点给列表，省得用户还要先点一下。
    if (hadFocus || !S.gui.FocusedCtrl)
        S.lv.Focus()
    if gScroll
        gScroll.Sync()
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
    global S, gScroll, HDR
    if !S.all.Length {
        S.sb.SetText(S.scanning ? "正在扫描" : "就绪")
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
    txt := filtered ? "显示 " S.view.Length " / " S.all.Length " · " exts.Count " 种扩展名"
                    : "共 " S.view.Length " 个条目 · " exts.Count " 种扩展名"
    if (missing && !filtered)
        txt .= " · " missing " 个失效"
    if checked
        txt .= " · 已勾选 " checked
    if S.sortCol
        txt .= " · 按「" (S.sortCol = 1 ? "勾选" : HDR[S.sortCol]) "」" (S.sortDesc ? "降序" : "升序")
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

    ; 版式照 §10：客户区 616×390，行宽 584（616−16×2）；列表区外框 y12 h308，
    ; 操作行 y326 h28 三按钮右对齐到 600，状态条 y360 h30 贴窗口底。
    g := Gui("+Owner" S.gui.Hwnd " -MaximizeBox -MinimizeBox", "删除历史与恢复")
    g.BackColor := "F7F9FC"
    g.SetFont("s10", "Microsoft YaHei UI")
    S.histGui := g
    g.Add("Text", "x16 y12 w584 h308 BackgroundFFFFFF")
    g.Add("Text", "x16 y12 w584 h1 BackgroundB7C8E0")
    g.Add("Text", "x16 y319 w584 h1 BackgroundB7C8E0")
    g.Add("Text", "x16 y12 w1 h308 BackgroundB7C8E0")
    g.Add("Text", "x599 y12 w1 h308 BackgroundB7C8E0")
    S.histList := g.Add("ListBox", "x17 y13 w582 h306 -E0x200 BackgroundFFFFFF c202B3A")
    for f in files {
        t := FormatTime(FileGetTime(f, "C"), "yyyy-MM-dd HH:mm:ss")
        n := 0
        try {
            for ln in StrSplit(FileRead(f, "UTF-8"), "`n", "`r")
                if (Trim(ln) != "")
                    n++
        }
        S.histList.Add([t " · " n " 条"])
    }
    S.histView := FlatButton(g, 410, 326, 58, 28, "查看", "EBF2FB", "B7C8E0", (*) => ViewHistory())
    S.histRestore := FlatButton(g, 476, 326, 58, 28, "恢复", "EBF2FB", "B7C8E0", (*) => RestoreHistory())
    FlatButton(g, 542, 326, 58, 28, "关闭", "EBF2FB", "B7C8E0", (*) => CloseHistory())
    S.histList.OnEvent("Change", (*) => SyncHistButtons())
    g.Add("Text", "x0 y360 w616 h30 BackgroundDCE8F7")
    g.Add("Text", "x12 y360 w592 h30 BackgroundDCE8F7 c202B3A +0x200", "共 " files.Length " 份备份")
    g.OnEvent("Close", (*) => CloseHistory())
    g.OnEvent("Escape", (*) => CloseHistory())
    SyncHistButtons()
    g.Show("w616 h390 Center")
    PaintCaption(g.Hwnd)
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
    S.sb := FlatStatus(g2, 0, 0, 400, 30, "")
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