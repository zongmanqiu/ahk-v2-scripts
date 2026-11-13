; ==UserScript==
; @name         文件时间修改
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      2.4.7
; @description  拖入文件或文件夹，点「更新时间」后设定创建/修改/访问时间；勾选「包含子文件（夹）」才连同内部所有文件与子文件夹一起生效
; @author       邱宗满
; @date         2026-11-13
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        主窗口「更新时间」按钮；拖放文件/文件夹入列表
; ==/UserScript==
;
; 文件时间修改：拖放路径入列表，按三个可独立设定的时间改写创建/修改/访问时间。
; 形态偏离：以 GUI 窗口为唯一入口，不注册托盘菜单、不设全局热键；宿主内由宿主启动窗口，
; 独立运行同样直接弹窗，窗口关闭即退出。
; 功能交互参考同类时间戳工具 NewFileTime / WTouch / BatchTimeChanger，代码为纯 AHK v2 原创实现，
; 未复用其源码；许可 AGPL-3.0，全文见仓库根目录 LICENSE。
; 2.4.6 修滚动：原生滚动条被摘掉样式位后 ListView 不再响应滚轮与键盘翻页，
; 改为自管竖向滚动状态并由脚本接管滚轮与翻页；横向条撤掉（横向 LVM_SCROLL 实测无效），
; 路径列宽改为做进视口。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global gGui := 0, gList := 0, gStatus := 0
global gChkM := 0, gChkC := 0, gChkA := 0
global gDayM := 0, gDayC := 0, gDayA := 0
global gTimeM := 0, gTimeC := 0, gTimeA := 0
global gChkRec := 0
global gBtnApply := 0, gBtnClear := 0
global gSeen := Map(), gScroll := 0

; 系统 CheckBox 在宿主里是经典黑勾方框，样式位去不掉，改成三层 Text 色块自绘；
; Value 保持 0/1 语义，方框与文字都能点击切换。类声明是运行期语句、不会被提升，
; 必须写在 BuildGui() 调用之前，否则加载时报「This line will never execute」。
class FlatCheck {
    __New(g, x, y, w, h, text, checked := false) {
        this.Value := checked ? 1 : 0
        this.cb := 0
        boxY := y + (h - 16) // 2
        this.frame := g.Add("Text", "x" x " y" boxY " w16 h16 BackgroundB7C8E0")
        this.fill := g.Add("Text", "x" (x + 1) " y" (boxY + 1) " w14 h14 +0x200 Center", "")
        ; 14px 小方块里 s10 的「√」只有 1px 细线、看不出形状；实测 ✓ + s11 Bold 笔画约 2px，
        ; 与系统勾选框观感最接近，且不溢出方块（✔ U+2714 会糊成一团）。
        this.fill.SetFont("s11 Bold", "Microsoft YaHei UI")
        this.label := g.Add("Text", "x" (x + 22) " y" y " w" (w - 22) " h" h
            " BackgroundF7F9FC c202B3A +0x200", text)
        this.Paint()
        for c in [this.frame, this.fill, this.label]
            c.OnEvent("Click", (*) => this.Toggle())
    }
    ; 浅色方案下「勾上」只表态、不抢眼：白块 -> 次按钮底（#EBF2FB），勾仍是近黑。
    ; 选中的色块不再比周围按钮深，勾形本身才是状态标识。
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
        ; 属性里存的是函数对象，必须显式 .Call()：写成 this.cb() 会被当成
        ; 「方法」调用并隐式多传一个 this，两个内核都会报参数过多。
        if (this.cb)
            this.cb.Call()
    }
    OnEvent(name, cb) {
        if (name = "Click")
            this.cb := cb
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
    global gScroll, gGui
    if (!gScroll)
        return
    delta := (wp >> 16) & 0xFFFF
    if (delta & 0x8000)
        delta := delta - 0x10000
    ; 落在本窗口任意控件上都滚列表：原生滚动条被摘掉后 ListView 自己不再处理滚轮。
    if (gGui.Hwnd && DllCall("user32\IsChild", "Ptr", gGui.Hwnd, "Ptr", hwnd)) {
        gScroll.OnWheelDelta(delta)
        return 1
    }
    return
}

; 键盘翻页：只在列表控件上接管，别的控件保持原生行为。
OnBarKey(wp, lp, msg, hwnd) {
    global gScroll, gList
    if (!gScroll || !gList || hwnd != gList.Hwnd)
        return
    if (gScroll.OnKey(wp))
        return 1
    return
}

BuildGui()
return

FT(dayCtrl, timeCtrl) {
    return SubStr(dayCtrl.Value, 1, 8) SubStr(timeCtrl.Value, 9, 6)
}

SetStatus(s) {
    global gStatus
    gStatus.Value := s
}

PaintCaption() {
    global gGui
    c := Buffer(4, 0)
    NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0)
    NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; SysDateTimePick32 自己画 2px 立体边、以及那个灰底 3D 下拉/微调按钮，样式位与主题都改不掉。
; 办法是把控件裁到「只剩文字区」：右边界停在按钮左沿，按钮区整体被裁掉、不再绘制，
; 由自绘色块顶替。点击不落在控件上，所以再按控件自己的按钮坐标把消息转发回去。
ClipField(hwnd, right, h) {
    rgn := DllCall("gdi32\CreateRectRgn", "Int", 2, "Int", 2, "Int", right, "Int", h - 2, "Ptr")
    if (rgn && !DllCall("user32\SetWindowRgn", "Ptr", hwnd, "Ptr", rgn, "Int", 1, "Int"))
        DllCall("gdi32\DeleteObject", "Ptr", rgn)
}

; 必须 Post 而不是 SendMessage：日历下拉会在控件内部跑嵌套消息循环，
; 同步发送会把脚本卡在那个循环里，直到用户关掉日历才返回。
PopCalendar(ctrl) {
    ctrl.Focus()
    l := (14 << 16) | 131
    DllCall("user32\PostMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x201, "Ptr", 1, "Ptr", l)
    DllCall("user32\PostMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x202, "Ptr", 0, "Ptr", l)
}

; 上下键沿用控件自己的语义（改当前选中的那一段），不自己算时间、不覆盖用户的输入游标。
StepTime(ctrl, vk) {
    ctrl.Focus()
    DllCall("user32\PostMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x100, "Ptr", vk, "Ptr", 0)
    DllCall("user32\PostMessageW", "Ptr", ctrl.Hwnd, "UInt", 0x101, "Ptr", vk, "Ptr", 0)
}

; 日期框：裁到 115 —— 有主题时 DTP 会在 116..121 自绘一个日历小图标，必须整块裁掉，
; 否则会看到「图标 + 三角」两个重复入口。115..121 用白块补齐当右内边距，
; 122 画分隔线，123..139 才是 ▼ 色块，按钮宽度在两种环境下保持一致（17px）。
MakeDateField(g, x, y) {
    g.Add("Text", "x" x " y" y " w140 h26 BackgroundB7C8E0")
    c := g.Add("DateTime", "x" (x - 1) " y" (y - 1) " w142 h28 -0x800000", "yyyy/MM/dd")
    ClipField(c.Hwnd, 115, 28)
    g.Add("Text", "x" (x + 114) " y" (y + 1) " w7 h24 BackgroundFFFFFF")
    g.Add("Text", "x" (x + 121) " y" (y + 1) " w1 h24 BackgroundB7C8E0")
    b := g.Add("Text", "x" (x + 122) " y" (y + 1) " w17 h24 BackgroundFFFFFF c202B3A +0x200 Center", "▼")
    b.SetFont("s9", "Microsoft YaHei UI")
    b.OnEvent("Click", (*) => PopCalendar(c))
    return c
}

; 时分秒框：134 宽控件裁到 115，115..131 交给自绘的 ▲▼ 两块。
MakeTimeField(g, x, y) {
    g.Add("Text", "x" x " y" y " w132 h26 BackgroundB7C8E0")
    c := g.Add("DateTime", "x" (x - 1) " y" (y - 1) " w134 h28 -0x800000 +0x1", "HH:mm:ss")
    ClipField(c.Hwnd, 115, 28)
    g.Add("Text", "x" (x + 114) " y" (y + 1) " w1 h24 BackgroundB7C8E0")
    up := g.Add("Text", "x" (x + 115) " y" (y + 1) " w16 h11 BackgroundFFFFFF c202B3A +0x200 Center", "▲")
    dn := g.Add("Text", "x" (x + 115) " y" (y + 12) " w16 h13 BackgroundFFFFFF c202B3A +0x200 Center", "▼")
    up.SetFont("s9", "Microsoft YaHei UI")
    dn.SetFont("s9", "Microsoft YaHei UI")
    up.OnEvent("Click", (*) => StepTime(c, 0x26))
    dn.OnEvent("Click", (*) => StepTime(c, 0x28))
    return c
}

; 浅色底 + 黑字之后，按钮不再靠底色深浅立形，改靠 1px 描边：外块铺边框色、内块四周
; 缩进 1px 铺底色。两块都挂 Click —— 否则点在 1px 边上没反应，手感像坏了。
; 同样不用系统 Button：宿主缺 comctl32 v6 manifest 时系统控件退回经典 3D 凸起。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

BuildGui() {
    global
    ; 版式照 开发指南 §10：客户区 420，内容行 x16 w388（420-16*2）；同排控件同 y 同 h，
    ; 文字控件固定高 +0x200 垂直居中；状态条铺满窗口底，caption 由 DWM 染成同一个 #DCE8F7。
    gGui := Gui("", "文件时间修改")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    ; 窗口是本脚本唯一入口：关掉窗口就该退出，不能只 Destroy 让脚本继续挂着。
    ; gScroll 的 Sync 定时器必须先停，否则 ExitApp 之外还会留一拍访问已销毁控件（K21）。
    gGui.OnEvent("Close", (*) => (gScroll.Stop(), ExitApp()))
    gGui.OnEvent("DropFiles", OnDropFiles)

    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x16 y12 w388 h26 BackgroundDCE8F7")
    gGui.Add("Text", "x22 y12 w94 h26 BackgroundDCE8F7 c202B3A +0x200", "时间类型")
    gGui.Add("Text", "x124 y12 w140 h26 BackgroundDCE8F7 c202B3A +0x200", "年/月/日")
    gGui.Add("Text", "x272 y12 w132 h26 BackgroundDCE8F7 c202B3A +0x200", "时/分/秒")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    ; 按钮不用系统 Button：宿主缺 comctl32 v6 manifest 时系统控件退回经典 3D 样式，
    ; Text 色块靠 WM_CTLCOLORSTATIC 生效、与主题无关。
    gChkM := FlatCheck(gGui, 16, 42, 100, 26, "修改时间", true)
    gDayM := MakeDateField(gGui, 124, 42)
    gTimeM := MakeTimeField(gGui, 272, 42)

    gChkC := FlatCheck(gGui, 16, 72, 100, 26, "创建时间", true)
    gDayC := MakeDateField(gGui, 124, 72)
    gTimeC := MakeTimeField(gGui, 272, 72)

    gChkA := FlatCheck(gGui, 16, 102, 100, 26, "访问时间", true)
    gDayA := MakeDateField(gGui, 124, 102)
    gTimeA := MakeTimeField(gGui, 272, 102)

    ; 路径区是一个整体：外框 #B7C8E0 从标题带顶边一直包到列表底边（y132..338），
    ; 标题带与列表内缩 1px 落进框里。原先标题带是独立的一条浅蓝、列表自带一圈外框，
    ; 两条边不共用，看着像「一块色条压在一个框上」而不是同一个区块。
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x16 y132 w388 h206 BackgroundB7C8E0")
    gGui.Add("Text", "x17 y133 w386 h26 BackgroundDCE8F7")
    gGui.Add("Text", "x23 y133 w380 h26 BackgroundDCE8F7 c202B3A +0x200", "路径")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    ; AHK 默认给 ListView 加 WS_EX_CLIENTEDGE，经典样式下就是 3D 凹陷；-E0x200 抵消。
    ; 列表与外框内缘同 x/w，靠父块露出的 1px 当边框；顶边紧贴标题带底，不要留缝。
    gList := gGui.Add("ListView", "x17 y159 w386 h178 -Hdr -E0x200 BackgroundFFFFFF c202B3A", ["路径"])
    ; 未解锁条已取消，樚向条不能滚动，列宽放进视口＋
    gList.ModifyCol(1, 376)
    gScroll := FlatScroll(gGui, gList, 17, 159, 386, 178)

    gChkRec := FlatCheck(gGui, 16, 344, 168, 28, "包含子文件（夹）", false)
    gChkRec.OnEvent("Click", (*) => RefreshStatus())
    ; 两枚按钮同一套配色（底 #EBF2FB、边 #B7C8E0），不分主次：主按钮那档中蓝压黑字
    ; 显得脏，动作主次交给位置（右对齐、靠右更近鼠标）与文案。
    ; 宽度按「四字 + 左右各 16」定，间隔 8px，右对齐到内容右边（404）。
    gBtnApply := FlatButton(gGui, 228, 344, 84, 28, "更新时间", "EBF2FB", "B7C8E0", (*) => ApplyAll())
    gBtnClear := FlatButton(gGui, 320, 344, 84, 28, "清空列表", "EBF2FB", "B7C8E0", (*) => ClearList())

    gGui.Add("Text", "x0 y378 w420 h30 BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y378 w396 h30 BackgroundDCE8F7 c202B3A +0x200", "")
    gGui.Show("w420 h408 Center")
    PaintCaption()
    gScroll.Layout()
    SetTimer(ObjBindMethod(gScroll, "Sync"), 60)
    HookBarInput()
    RefreshStatus()
}

RefreshStatus() {
    global
    n := gList.GetCount()
    if (!gChkRec.Value || n = 0) {
        SetStatus("拖入 " n " 个路径")
        return
    }
    files := 0, dirs := 0
    loop n {
        for _, item in CollectTargets(gList.GetText(A_Index, 1), true) {
            if (DirExist(item))
                dirs++
            else
                files++
        }
    }
    SetStatus("拖入 " n " 个路径 · 共 " (files + dirs) " 项（文件 " files "、文件夹 " dirs "）")
}

OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global
    for _, path in files {
        if (gSeen.Has(path))
            continue
        gSeen[path] := true
        gList.Add("", path)
    }
    RefreshStatus()
    gScroll.Layout()
}

ClearList() {
    global
    gList.Delete()
    gSeen := Map()
    RefreshStatus()
    gScroll.Layout()
}

CollectTargets(p, recurse) {
    out := []
    if (!FileExist(p) && !DirExist(p))
        return out
    out.Push(p)
    if (recurse && DirExist(p)) {
        Loop Files, p "\*", "FDR"
            out.Push(A_LoopFileFullPath)
    }
    return out
}

ApplyAll() {
    global
    useM := gChkM.Value, ftM := FT(gDayM, gTimeM)
    useC := gChkC.Value, ftC := FT(gDayC, gTimeC)
    useA := gChkA.Value, ftA := FT(gDayA, gTimeA)

    if (!useM && !useC && !useA) {
        SetStatus("请至少勾选一种时间")
        return
    }
    n := gList.GetCount()
    if (n = 0) {
        SetStatus("列表为空，请先拖入文件或文件夹")
        return
    }

    ok := 0, fail := 0, skip := 0
    rec := gChkRec.Value
    loop n {
        root := gList.GetText(A_Index, 1)
        targets := CollectTargets(root, rec)
        if (targets.Length = 0) {
            skip++
            continue
        }
        for _, item in targets {
            err := ""
            if (useM) {
                try {
                    FileSetTime(ftM, item, "M")
                } catch as e {
                    err .= "修改:" e.Message " "
                }
            }
            if (useC) {
                try {
                    FileSetTime(ftC, item, "C")
                } catch as e {
                    err .= "创建:" e.Message " "
                }
            }
            if (useA) {
                try {
                    FileSetTime(ftA, item, "A")
                } catch as e {
                    err .= "访问:" e.Message " "
                }
            }
            if (err = "")
                ok++
            else
                fail++
        }
    }
    SetStatus(FormatTime(A_Now, "HH:mm:ss") " 成功 " ok " 项，失败 " fail " 项" (skip ? "，路径失效 " skip : ""))
}
