; ==UserScript==
; @name         夜灯
; @id           night-light
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.2.5
; @description  滑块调屏幕色温（GammaRamp），并同步写入 Windows 夜间模式设置
; @author       邱宗满
; @date         2026-11-18
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        托盘菜单「夜灯调整」；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 夜灯：用滑块调屏幕色温，并同步进 Windows 夜间模式的 CloudStore 值。
; 入口：托盘菜单「夜灯调整」（宿主内由宿主镜像，独立运行显示自己的图标）。全局热键交给 AHKDeck 指派，脚本不自设。
; 纯 AHK v2：GammaRamp 走 gdi32，注册表走 advapi32，不依赖外部 exe。
;
; 1.1.0：离屏 AlwaysOnTop 小窗并入 §10 的配色与版式口径。
; 1.2.0：去掉底部说明行；滑块改成自绘（系统 Trackbar 的经典灰槽 + 蓝滑块与浅色令牌不搭），
; 只用封版令牌（槽 BAND、滑块 FRAME 描边 + SOFT 内块）与已验证的 SS_NOTIFY + 轮询拖动，
; 不新增色值/字号；标题栏不再覆盖成 IDI_APPLICATION，恢复 AHK 默认图标。
; 关面板只关面板、脚本仍待命（Persistent），与「文件时间修改关窗即退出」是两种正确口径。
; 1.2.5：修两处实测问题——① 全屏游戏把 gamma LUT 重置成线性，夜灯看起来凭空失效，
; 补一个每秒回读 LUT、不一致才重写的守护；② 拖动结束后 20ms 轮询定时器没被真正关掉
; （SetTimer 按函数对象标识，ObjBindMethod 每次 new 都是新对象），残留定时器把「在窗口外
; 按下鼠标」当成拖动，滑块会跟着光标跑。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

MIN_K := 1200
MAX_K := 6500
NL_ROOT := 0x80000001
NL_KEY := "Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings\windows.data.bluelightreduction.settings"
NL_VALUE := "Data"
ICM_KEY := "Software\Microsoft\Windows NT\CurrentVersion\ICM"

gGui := 0
gTrack := 0
gPct := 0
gIntensity := 0
; 系统 Trackbar 由 comctl32 主题引擎画，宿主里是经典灰槽 + 蓝色系统滑块，与浅色令牌不搭。
; 改自绘，但只借用 §10 已封版的令牌与按钮描边配方，不新增色值/字号：
; 槽 BAND(DCE8F7)、滑块外框 FRAME(B7C8E0) + 内块 SOFT(EBF2FB)。
; 交互靠 +0x100(SS_NOTIFY) + OnMessage(0x201) + 20ms 轮询，与 FlatScroll 同一套已验证机制。
class FlatTrack {
    __New(g, x, y, w, h, value, cb) {
        this.g := g, this.x := x, this.y := y, this.w := w, this.h := h
        this.tw := 12, this.th := 20
        this.value := Max(0, Min(100, value))
        this.cb := cb
        this.dragging := false, this.dead := false
        ; 定时器真实触发次数：只给 --selftest 用，用来证明「关掉之后它真的不再跑」。
        this.fires := 0
        ; SetTimer 按「函数对象本身」认计时器：ObjBindMethod 每次 new 都是一个新对象，
        ; 用新对象 SetTimer(…, 0) 关不掉旧对象注册的那个定时器（实测：关掉后仍在跑）。
        ; 所以轮询定时器只在建对象时生成一次，之后开/关都用这同一个 this.tickFn。
        this.tickFn := ObjBindMethod(this, "Tick")
        ; 滑块高 th(20) 比槽高 h(10) 各高出 5px；滑块移开后腾出的那两条 5px
        ; 属于「窗口背景」，宿主不重绘这块区域 → 拖动时留下残影。
        ; 先铺一条与滑块同高的同色底衬，腾出的像素就归属一个会正常重绘的控件。
        this.bed := g.Add("Text", "x" x " y" (y - (this.th - h) // 2)
            " w" w " h" this.th " +0x100 BackgroundF7F9FC")
        this.track := g.Add("Text", "x" x " y" y " w" w " h" h " +0x100 BackgroundDCE8F7")
        ; 后创建的盖在槽上：外框 1px、内块缩进 1px，与 FlatButton 同一套描边。
        this.outer := g.Add("Text", "x0 y0 w0 h0 +0x100 BackgroundB7C8E0")
        this.inner := g.Add("Text", "x0 y0 w0 h0 +0x100 BackgroundEBF2FB")
        this.Paint()
    }
    Hit(hwnd) {
        return hwnd = this.track.Hwnd || hwnd = this.bed.Hwnd
            || hwnd = this.outer.Hwnd || hwnd = this.inner.Hwnd
    }
    Paint() {
        span := this.w - this.tw
        tx := this.x + Round(span * this.value / 100)
        ty := this.y - (this.th - this.h) // 2
        ; 两个色块逐个 Move 会出现「外框已到、内块还在旧位」的中间帧，
        ; 拖动时 20ms 一拍，中间帧会被看见（K24 同型坑）。批量提交只有一次布局。
        h := DllCall("user32\BeginDeferWindowPos", "Int", 2, "Ptr")
        if (h) {
            f := 0x0004 | 0x0010 | 0x0040      ; SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW
            h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", this.outer.Hwnd
                , "Ptr", 0, "Int", tx, "Int", ty, "Int", this.tw, "Int", this.th, "UInt", f, "Ptr")
            h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", this.inner.Hwnd
                , "Ptr", 0, "Int", tx + 1, "Int", ty + 1, "Int", this.tw - 2, "Int", this.th - 2, "UInt", f, "Ptr")
            if (h)
                DllCall("user32\EndDeferWindowPos", "Ptr", h)
            return
        }
        this.outer.Move(tx, ty, this.tw, this.th)
        this.inner.Move(tx + 1, ty + 1, this.tw - 2, this.th - 2)
    }
    Set(v, fire := false) {
        v := Max(0, Min(100, Round(v)))
        if (v = this.value)
            return
        this.value := v
        this.Paint()
        ; 属性里存的是函数对象，必须显式 .Call(v)：写成 this.cb(v) 会被当成
        ; 「方法」调用并隐式多传一个 this，两个内核都会报参数过多。
        if (fire && this.cb)
            this.cb.Call(v)
    }
    BeginDrag() {
        if (this.dead || this.dragging)
            return
        this.dragging := true
        this.Tick()
        SetTimer(this.tickFn, 20)
    }
    ; Text 控件拿不到中途的 MOUSEMOVE，用 GetCursorPos + GetKeyState 轮询反而稳。
    Tick() {
        this.fires += 1
        ; dragging 是第二道闸：即便哪天定时器又被弄成关不掉，没有拖动意图时这里也不会
        ; 拿光标位置去改值——1.2.5 之前「在面板外点一下鼠标，滑块跟着跳」就是漏了这道闸。
        if (this.dead || !this.dragging || !GetKeyState("LButton", "P")) {
            this.dragging := false
            SetTimer(this.tickFn, 0)
            return
        }
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        sx := NumGet(pt, 0, "Int")
        r := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "Ptr", this.track.Hwnd, "Ptr", r)
        left := NumGet(r, 0, "Int"), right := NumGet(r, 8, "Int")
        span := (right - left) - this.tw
        if (span <= 0)
            return
        this.Set((sx - left - this.tw // 2) / span * 100, true)
    }
    Key(wp) {
        v := this.value
        switch wp {
            case 0x25: v -= 1
            case 0x27: v += 1
            case 0x21: v -= 10
            case 0x22: v += 10
            case 0x24: v := 0
            case 0x23: v := 100
            default: return false
        }
        this.Set(v, true)
        return true
    }
    Stop() {
        this.dead := true
        SetTimer(this.tickFn, 0)
        this.dragging := false
    }
}

OnTrackDown(wp, lp, msg, hwnd) {
    global gTrack
    if (gTrack && gTrack.Hit(hwnd))
        gTrack.BeginDrag()
}

OnTrackKey(wp, lp, msg, hwnd) {
    global gTrack, gGui
    if (!gTrack || !gGui)
        return
    if (hwnd != gGui.Hwnd && !gTrack.Hit(hwnd))
        return
    if (gTrack.Key(wp))
        return 0
}

gHighestWritten := 0
gWritePending := false

ClampF(v, lo, hi) {
    if (v < lo)
        return lo
    if (v > hi)
        return hi
    return v
}

RedFactor(k) {
    if (k > 6600)
        return ClampF(329.698727446 * ((k / 100 - 60) ** -0.1332047592) / 255, 0, 1)
    return 1.0
}

GreenFactor(k) {
    if (k > 6600)
        return ClampF(288.1221695283 * ((k / 100 - 60) ** -0.0755148492) / 255, 0, 1)
    return ClampF((99.4708025861 * Ln(k / 100) - 161.1195681661) / 255, 0, 1)
}

BlueFactor(k) {
    if (k >= 6600)
        return 1.0
    if (k <= 1900)
        return 0.0
    return ClampF((138.5177312231 * Ln(k / 100 - 10) - 305.0447927307) / 255, 0, 1)
}

BuildRamp(k) {
    b := Buffer(1536, 0)
    rf := RedFactor(k)
    gf := GreenFactor(k)
    bf := BlueFactor(k)
    Loop 256 {
        i := A_Index - 1
        level := Floor(i / 255 * 65535)
        NumPut("UShort", Min(65535, Floor(level * rf)), b, i * 2)
        NumPut("UShort", Min(65535, Floor(level * gf)), b, 512 + i * 2)
        NumPut("UShort", Min(65535, Floor(level * bf)), b, 1024 + i * 2)
    }
    return b
}

; 桌面 DC 的 gamma 表按色温缓存：守护每秒跑一次，没必要每次都重算 768 个采样点。
gRampK := -1
gRampBuf := 0

DesiredRamp(k) {
    global gRampK, gRampBuf
    if (!gRampBuf || k != gRampK) {
        gRampBuf := BuildRamp(k)
        gRampK := k
    }
    return gRampBuf
}

ApplyRamp(k) {
    ramp := DesiredRamp(k)
    hdc := DllCall("user32.dll\GetDC", "Ptr", 0, "Ptr")
    if !hdc
        return false
    ok := DllCall("gdi32.dll\SetDeviceGammaRamp", "Ptr", hdc, "Ptr", ramp.Ptr, "Int")
    DllCall("user32.dll\ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return ok != 0
}

; 全屏（独占全屏）游戏切显示模式时，驱动会把 gamma LUT 重置回线性，我们写进去的色温
; 就凭空消失：面板里的值还在，屏幕却白了。这里每秒回读一次当前 LUT 与目标逐字节比对，
; 不一致才重写——正常情况只是读一次（无闪烁、无副作用），被游戏/驱动改掉后 1 秒内自愈。
; 强度 0（6500K）时直接不管：用户选的就是关灯，别去和游戏自己的亮度设置抢 LUT。
RampMatches(ramp) {
    cur := Buffer(1536, 0)
    hdc := DllCall("user32.dll\GetDC", "Ptr", 0, "Ptr")
    if !hdc
        return false
    ok := DllCall("gdi32.dll\GetDeviceGammaRamp", "Ptr", hdc, "Ptr", cur.Ptr, "Int")
    DllCall("user32.dll\ReleaseDC", "Ptr", 0, "Ptr", hdc)
    if !ok
        return false
    Loop 1536 {
        i := A_Index - 1
        if (NumGet(cur, i, "UChar") != NumGet(ramp, i, "UChar"))
            return false
    }
    return true
}

; 定时器与 WM_DISPLAYCHANGE 共用：* 吸收消息回调的四个参数，SetTimer 直调也不多传。
GuardRamp(*) {
    global gIntensity
    if (gIntensity <= 0)
        return
    k := IntensityToKelvin(gIntensity)
    if !RampMatches(DesiredRamp(k))
        ApplyRamp(k)
}

IntensityToKelvin(i) {
    global MIN_K, MAX_K
    i := Max(0, Min(100, i))
    return MAX_K - (MAX_K - MIN_K) * i // 100
}

KelvinToIntensity(k) {
    global MIN_K, MAX_K
    k := Max(MIN_K, Min(MAX_K, k))
    return (MAX_K - k) * 100 // (MAX_K - MIN_K)
}

AddVarint(arr, v) {
    Loop {
        byte := v & 0x7F
        v := v >> 7
        if v
            byte |= 0x80
        arr.Push(byte)
        if !v
            break
    }
}

; 带边界的单字节读取：越界返回 -1（合法字节 0..255），让所有 0xXX 比较自然失败。
; ParseNightLight 读的是注册表里 Windows 写的 CloudStore blob，畸形值不能让脚本读到缓冲区外。
GetByte(data, p) {
    if (p < 0 || p >= data.Size)
        return -1
    return NumGet(data, p, "UChar")
}

ReadVarint(buf, pos) {
    val := 0
    shift := 0
    n := 0
    Loop 10 {
        if (pos + n >= buf.Size)    ; 截断的 varint：在缓冲区末尾停，不读越界字节
            break
        c := NumGet(buf, pos + n, "UChar")
        val |= (c & 0x7F) << shift
        n += 1
        if !(c & 0x80)
            break
        shift += 7
    }
    return [val, n]
}

UnixNow() {
    ft := Buffer(8, 0)
    DllCall("kernel32.dll\GetSystemTimeAsFileTime", "Ptr", ft.Ptr)
    return (NumGet(ft, 0, "Int64") - 116444736000000000) // 10000000
}

RegOpen(root, path, access) {
    hk := Buffer(8, 0)
    rc := DllCall("advapi32.dll\RegOpenKeyExW", "Ptr", root, "WStr", path, "UInt", 0, "UInt", access, "Ptr", hk.Ptr, "Int")
    if (rc != 0)
        return 0
    return NumGet(hk, 0, "Ptr")
}

KeyExists(full) {
    root := 0x80000001
    sub := full
    if (SubStr(full, 1, 5) = "HKLM\")
        root := 0x80000002, sub := SubStr(full, 6)
    else if (SubStr(full, 1, 5) = "HKCU\")
        sub := SubStr(full, 6)
    h := RegOpen(root, sub, 0x20019)
    if !h
        return false
    DllCall("advapi32.dll\RegCloseKey", "Ptr", h)
    return true
}

RegReadBinary(root, path, name) {
    hKey := RegOpen(root, path, 0x20019)
    if !hKey
        return 0
    sz := Buffer(4, 0)
    ty := Buffer(4, 0)
    NumPut("UInt", 0, sz, 0)
    rc := DllCall("advapi32.dll\RegQueryValueExW", "Ptr", hKey, "WStr", name, "Ptr", 0, "Ptr", ty.Ptr, "Ptr", 0, "Ptr", sz.Ptr, "Int")
    size := NumGet(sz, 0, "UInt")
    buf := 0
    if (rc = 0 && size > 0 && size <= 65536) {
        buf := Buffer(size, 0)
        NumPut("UInt", size, sz, 0)
        rc := DllCall("advapi32.dll\RegQueryValueExW", "Ptr", hKey, "WStr", name, "Ptr", 0, "Ptr", ty.Ptr, "Ptr", buf.Ptr, "Ptr", sz.Ptr, "Int")
        if (rc != 0)
            buf := 0
    }
    DllCall("advapi32.dll\RegCloseKey", "Ptr", hKey)
    return buf
}

RegWriteBinary(root, path, name, buf) {
    hKey := RegOpen(root, path, 0x20006)
    if !hKey
        return false
    rc := DllCall("advapi32.dll\RegSetValueExW", "Ptr", hKey, "WStr", name, "UInt", 0, "UInt", 3, "Ptr", buf.Ptr, "UInt", buf.Size, "Int")
    DllCall("advapi32.dll\RegCloseKey", "Ptr", hKey)
    return rc = 0
}

ParseNightLight(data) {
    if (!data || data.Size < 12)
        return 0
    if (GetByte(data, 0) != 0x43 || GetByte(data, 1) != 0x42)
        return 0
    p := 4
    if (GetByte(data, p) != 0x0A)
        return 0
    p += 1
    Loop 16 {
        if (p >= data.Size)
            return 0
        c := GetByte(data, p)
        p += 1
        if (c = 0)
            break
    }
    if (GetByte(data, p) != 0x2A)
        return 0
    p += 1
    if (GetByte(data, p) != 0x06)
        return 0
    p += 1
    tsPos := p
    r := ReadVarint(data, p)
    tsVal := r[1]
    tsLen := r[2]
    p += tsLen
    if (GetByte(data, p) != 0x2A)
        return 0
    p += 1
    if (GetByte(data, p) != 0x2B)
        return 0
    p += 1
    p += 1
    r := ReadVarint(data, p)
    p += r[2]
    innerPos := p
    ; count 来自 blob 里的 varint，畸形值可以大到天文数字。把它夹到"缓冲区还剩多少"，
    ; 否则 while 会把 pos 推到缓冲区外：既有越界读，也会让自测空转。
    count := Min(r[1], data.Size - innerPos)
    tempPos := 0
    tempVal := 0
    i := 0
    while (i + 2 < count) {
        pos := innerPos + i
        ; 温度字段是 2 字节 varint，WriteNightLight 要在 tempPos/tempPos+1 各写 1 字节。
        ; 必须确认这 2 字节都落在缓冲区内，否则定位出来的 tempPos 会让写回越界。
        if (GetByte(data, pos) = 0xCF && GetByte(data, pos + 1) = 0x28 && pos + 3 < data.Size) {
            tempPos := pos + 2
            rr := ReadVarint(data, tempPos)
            zig := rr[1]
            tempVal := (zig >> 1) ^ -(zig & 1)
            break
        }
        i += 1
    }
    return {tsPos: tsPos, tsLen: tsLen, tsVal: tsVal, tempPos: tempPos, tempVal: tempVal}
}

ArrToBuffer(arr) {
    b := Buffer(arr.Length, 0)
    i := 0
    for _, v in arr {
        NumPut("UChar", v, b, i)
        i += 1
    }
    return b
}

BuildTemplate(k, ts) {
    arr := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06]
    AddVarint(arr, ts)
    arr.Push(0x2A, 0x2B, 0x0E, 0x21)
    inner := [0x43, 0x42, 0x01, 0x00,
              0xCA, 0x14, 0x0E, 0x15, 0x00,
              0xCA, 0x1E, 0x0E, 0x07, 0x00,
              0xCF, 0x28]
    AddVarint(inner, k * 2)
    inner.Push(0xCA, 0x32, 0x0E, 0x13, 0x2E, 0x11, 0x00,
               0xCA, 0x3C, 0x0E, 0x06, 0x2E, 0x26, 0x00,
               0x00)
    for _, v in inner
        arr.Push(v)
    arr.Push(0x00, 0x00, 0x00)
    return arr
}

ReadCurrentKelvin() {
    global NL_ROOT, NL_KEY, NL_VALUE, MIN_K, MAX_K
    data := RegReadBinary(NL_ROOT, NL_KEY, NL_VALUE)
    if !data
        return 0
    info := ParseNightLight(data)
    if (info && info.tempVal >= MIN_K && info.tempVal <= MAX_K)
        return info.tempVal
    return 0
}

WriteNightLight(k) {
    global NL_ROOT, NL_KEY, NL_VALUE, gHighestWritten
    data := RegReadBinary(NL_ROOT, NL_KEY, NL_VALUE)
    now := UnixNow()
    if data {
        info := ParseNightLight(data)
        if (info && info.tempPos) {
            patched := Buffer(data.Size, 0)
            i := 0
            Loop data.Size {
                NumPut("UChar", NumGet(data, i, "UChar"), patched, i)
                i += 1
            }
            vb := []
            AddVarint(vb, k * 2)
            if (vb.Length = 2) {
                NumPut("UChar", vb[1], patched, info.tempPos)
                NumPut("UChar", vb[2], patched, info.tempPos + 1)
            }
            newTs := Max(now, info.tsVal + 2, gHighestWritten + 2)
            tb := []
            AddVarint(tb, newTs)
            if (tb.Length = info.tsLen) {
                i := 0
                for _, v in tb {
                    NumPut("UChar", v, patched, info.tsPos + i)
                    i += 1
                }
                if RegWriteBinary(NL_ROOT, NL_KEY, NL_VALUE, patched) {
                    gHighestWritten := newTs
                    return true
                }
                return false
            }
            if RegWriteBinary(NL_ROOT, NL_KEY, NL_VALUE, patched) {
                gHighestWritten := Max(gHighestWritten, info.tsVal)
                return true
            }
            return false
        }
    }
    newTs := Max(now, gHighestWritten + 2)
    buf := ArrToBuffer(BuildTemplate(k, newTs))
    if RegWriteBinary(NL_ROOT, NL_KEY, NL_VALUE, buf) {
        gHighestWritten := newTs
        return true
    }
    return false
}

UnlockGammaRange() {
    global ICM_KEY
    hKey := RegOpen(0x80000002, ICM_KEY, 0x3)
    if !hKey
        return false
    v := Buffer(4, 0)
    NumPut("UInt", 256, v, 0)
    rc := DllCall("advapi32.dll\RegSetValueExW", "Ptr", hKey, "WStr", "GdiICMGammaRange", "UInt", 0, "UInt", 4, "Ptr", v.Ptr, "UInt", 4, "Int")
    DllCall("advapi32.dll\RegCloseKey", "Ptr", hKey)
    return rc = 0
}

UpdatePct() {
    global gPct, gIntensity
    if gPct
        gPct.Value := gIntensity . "%"
}

ScheduleWrite() {
    global gWritePending
    gWritePending := true
    SetTimer(FlushKelvin, 0)
    SetTimer(FlushKelvin, -400)
}

FlushKelvin() {
    global gIntensity, gWritePending
    gWritePending := false
    WriteNightLight(IntensityToKelvin(gIntensity))
}

OnTrackChange(v) {
    global gIntensity
    gIntensity := v
    ApplyRamp(IntensityToKelvin(v))
    UpdatePct()
    ScheduleWrite()
}

OnPanelClose(*) {
    global gGui, gTrack, gPct
    ; 拖动定时器会让脚本在面板销毁后继续存活，关闭前先停（K21 同型坑）。
    if gTrack
        gTrack.Stop()
    if gGui
        gGui.Destroy()
    gGui := 0
    gTrack := 0
    gPct := 0
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

ShowPanel() {
    global gGui, gTrack, gPct, gIntensity
    if gGui {
        gGui.Show()
        WinActivate("ahk_id " . gGui.Hwnd)
        return
    }
    ; 版式照 §10：客户区 320×52，行宽 288（320−32）；槽 w232 + 8 + 百分比 w48 = 288，
    ; 右缘 16+288 = 304 = 320−16。去掉底部说明行后，窗高 = 顶 12 + 行高 28 + 底 12 = 52。
    gGui := Gui("+AlwaysOnTop +Owner -MaximizeBox -MinimizeBox", "夜灯调整")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")

    gTrack := FlatTrack(gGui, 16, 21, 232, 10, gIntensity, OnTrackChange)
    gPct := gGui.Add("Text", "x256 y12 w48 h28 BackgroundF7F9FC c202B3A +0x200 Right", gIntensity . "%")
    gGui.OnEvent("Close", OnPanelClose)
    gGui.OnEvent("Escape", OnPanelClose)
    UpdatePct()

    MonitorGetWorkArea(1, &wl, &wt, &wr, &wb)
    gGui.Show("w320 h52 x-20000 y-20000")
    gGui.GetPos(&gx, &gy, &gw, &gh)
    gGui.Move(wr - gw - 12, wb - gh - 12)
    PaintCaption()
    ; 不再 LoadIcon / WM_SETICON：IDI_APPLICATION 会把 AHK 默认绿图标盖掉，
    ; 其它官方窗口都用默认图标。0x127 只隐藏焦点框，与图标无关。
    DllCall("SendMessageW", "Ptr", gGui.Hwnd, "UInt", 0x127, "Ptr", 0x10001, "Ptr", 0)
    DllCall("SetFocus", "Ptr", gGui.Hwnd)
}

ResetToCool() {
    global gTrack, gIntensity, MAX_K
    gIntensity := 0
    if gTrack
        gTrack.Set(0)
    ApplyRamp(MAX_K)
    UpdatePct()
    SetTimer(FlushKelvin, 0)
    FlushKelvin()
}

; 退出不碰显示：屏幕当前的样子就是用户最后选的样子，还原快照等于替用户改回去。
; 只把 debounce 里还没落盘的参数写进注册表，好让下次启动读到同一个值。
OnScriptExit(*) {
    global gWritePending
    SetTimer(FlushKelvin, 0)
    if gWritePending
        FlushKelvin()
    return 0
}

; ── 无 GUI 自测：--selftest [输出路径] ───────────────────────────────
; 只动纯函数、HKCU 自建键，以及一个从不 Show 的 Gui（测拖动轮询定时器的开关）：
; 不写真实夜间模式值、不碰屏幕 Gamma（Tick 头一拍就因 LButton 未按下而退出）、不改 HKLM。

if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\夜灯\selftest-result.txt")

RunSelfTest(path) {
    global MIN_K, MAX_K
    out := ""
    Emit(s) => out .= s "`n"

    okv := true
    for v in [0, 1, 127, 128, 300, 2400, 13000, 16383, 16384] {
        a := []
        AddVarint(a, v)
        r := ReadVarint(ArrToBuffer(a), 0)
        if (r[1] != v || r[2] != a.Length)
            okv := false
    }
    Emit((okv ? "PASS " : "FAIL ") "varint 编解码往返（9 组）")

    tpl := ArrToBuffer(BuildTemplate(3400, 1762900000))
    info := ParseNightLight(tpl)
    Emit((info && info.tempVal = 3400 ? "PASS " : "FAIL ") "模板解析回温度 3400")
    Emit((info && info.tsVal = 1762900000 ? "PASS " : "FAIL ") "模板解析回时间戳")
    Emit((info && info.tempPos > 0 ? "PASS " : "FAIL ") "温度字段可定位")
    Emit((ParseNightLight(Buffer(16, 0xFF)) = 0 ? "PASS " : "FAIL ") "坏数据解析被拒")

    ; 截断/畸形值：合法模板的每个前缀都要能安全解析——既不越界读，也不能给出
    ; 一个会让 WriteNightLight 写越界的 tempPos（tempPos+1 必须仍在缓冲区内）。
    ; 这组用例专治"读指针越过缓冲区"和"count 被伪造得极大导致空转/越界"。
    tpl := ArrToBuffer(BuildTemplate(3400, 1762900000))
    okTrunc := true
    Loop tpl.Size {
        m := A_Index - 1
        if (m < 4)
            continue
        part := Buffer(m, 0)
        n := 0
        Loop m {
            NumPut("UChar", NumGet(tpl, n, "UChar"), part, n)
            n += 1
        }
        inf := ParseNightLight(part)
        if (inf && inf.tempPos && inf.tempPos + 1 >= m)
            okTrunc := false
    }
    Emit((okTrunc ? "PASS " : "FAIL ") "截断模板逐前缀解析不越界")

    ; 伪造超大 count：varint 连发 9 个续字节 + 收尾，旧版会据此把循环推到缓冲区外。
    evil := ArrToBuffer([0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x2A, 0x06, 0x02, 0x2A, 0x2B, 0x0E,
        0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x01])
    Emit((ParseNightLight(evil) ? "PASS " : "FAIL ") "伪造超大 count 不崩溃")

    Emit((IntensityToKelvin(0) = MAX_K && IntensityToKelvin(100) = MIN_K ? "PASS " : "FAIL ") "强度端点 0/100")
    okk := true
    i := 0
    Loop 101 {
        if (Abs(KelvinToIntensity(IntensityToKelvin(i)) - i) > 1)
            okk := false
        i += 1
    }
    Emit((okk ? "PASS " : "FAIL ") "强度↔色温往返误差 ≤1")
    Emit((UnixNow() > 1700000000 ? "PASS " : "FAIL ") "系统时间戳合理")

    sub := "Software\AHKDeck\NightLightSelfTest"
    hk := "HKCU\" . sub
    if KeyExists(hk) {
        FileAppend("FAIL 自建键已存在，放弃自测以免覆盖未知状态`n", path, "UTF-8")
        ExitApp(1)
    }
    RegWrite("", "REG_SZ", hk)
    Emit((KeyExists(hk) ? "PASS " : "FAIL ") "自建键建立")
    w1 := ArrToBuffer([1, 2, 3, 4, 5, 6, 7, 8])
    Emit((RegWriteBinary(0x80000001, sub, "Data", w1) ? "PASS " : "FAIL ") "二进制值写入")
    rb := RegReadBinary(0x80000001, sub, "Data")
    same := rb && rb.Size = 8
    if same {
        n := 0
        Loop 8 {
            if (NumGet(rb, n, "UChar") != n + 1)
                same := false
            n += 1
        }
    }
    Emit((same ? "PASS " : "FAIL ") "二进制值读回逐字节相等")
    w2 := ArrToBuffer([9, 8, 7])
    RegWriteBinary(0x80000001, sub, "Data", w2)
    rb2 := RegReadBinary(0x80000001, sub, "Data")
    Emit((rb2 && rb2.Size = 3 && NumGet(rb2, 0, "UChar") = 9 ? "PASS " : "FAIL ") "覆盖写入生效")

    try RegDeleteKey(hk)
    Emit((!KeyExists(hk) ? "PASS " : "FAIL ") "自建键清理")
    try RegDeleteKey("HKCU\Software\AHKDeck")

    ; 拖动轮询定时器能不能真正关掉——1.2.5 的病灶就在这。
    ; SetTimer 按「函数对象」认计时器，旧代码每拍都 new 一个 ObjBindMethod 去关，
    ; 关的是不存在的那个，20ms 定时器永久残留：于是「在面板外按一下鼠标」也会被它
    ; 当成拖动，滑块跟着光标跳。fires 记的是真实触发次数，关不掉就会一直涨。
    ; 只动一个不 Show 的 Gui；Tick 头一拍就因为 LButton 不在按下状态而走停止分支，
    ; 不会调用 ApplyRamp（cb 传 0）。
    gT := Gui("+AlwaysOnTop")
    ft := FlatTrack(gT, 16, 21, 232, 10, 50, 0)
    ft.dragging := true
    SetTimer(ft.tickFn, 20)
    Sleep(100)
    n1 := ft.fires
    Sleep(150)
    n2 := ft.fires
    Emit((n1 >= 1 ? "PASS " : "FAIL ") "轮询定时器起得来（触发 " n1 " 次）")
    Emit((n2 = n1 ? "PASS " : "FAIL ") "轮询定时器关得掉（" n1 "→" n2 "）")

    ft.dead := false, ft.dragging := true
    SetTimer(ft.tickFn, 20)
    Sleep(100)
    ft.Stop()
    n3 := ft.fires
    Sleep(150)
    n4 := ft.fires
    Emit((n4 = n3 ? "PASS " : "FAIL ") "Stop() 停掉轮询（" n3 "→" n4 "）")
    gT.Destroy()

    ; ramp 缓存：换色温必须重算、换回来必须与首次一致（缓存键写错会一直套错的表）。
    ; 比的是缓冲内容而不是对象身份——判缓存对不对，看的是最终写进屏幕的那 1536 字节。
    ; 蓝通道从偏移 1024 起、每级 2 字节，取最后一级（i=255，偏移 1534）才有可比的强度。
    bA := NumGet(DesiredRamp(3400), 1534, "UShort")
    bB := NumGet(DesiredRamp(2000), 1534, "UShort")
    bC := NumGet(DesiredRamp(3400), 1534, "UShort")
    Emit((bB < bA ? "PASS " : "FAIL ") "换色温后 ramp 重算（蓝通道 " bA "→" bB "）")
    Emit((bC = bA ? "PASS " : "FAIL ") "换回原色温 ramp 与首次一致")

    fails := 0
    for ln in StrSplit(out, "`n")
        if (SubStr(ln, 1, 5) = "FAIL ")
            fails++
    Emit("fails=" . fails)
    try DirCreate(SubStr(path, 1, InStr(path, "\", false, -1) - 1))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

UnlockGammaRange()

current := ReadCurrentKelvin()
if current {
    gIntensity := KelvinToIntensity(current)
    ApplyRamp(IntensityToKelvin(gIntensity))
}

A_TrayMenu.Delete()
A_TrayMenu.Add("夜灯调整", (*) => ShowPanel())
A_TrayMenu.Add("还原冷色", (*) => ResetToCool())
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "夜灯调整"
A_IconTip := "夜灯"
; 宿主会镜像托盘菜单；独立运行才显示自己的图标。
if !InStr(A_AhkPath, "AHKDeck.exe")
    A_IconHidden := false

; 入口只有托盘菜单，没有热键、没有常驻定时器，靠面板这个窗口撑命；面板一关脚本就自行退出。
; 内核只把「热键/热字串、持久标记、启用的定时器、剪贴板监视、InputHook、可见 GUI」当作常驻理由，
; 往 A_TrayMenu 加项不算，所以这里显式声明常驻。
Persistent(true)

; 自绘轨的点击/键盘是全局消息，注册一次即可；面板关掉后 gTrack=0，回调自行空转。
OnMessage(0x201, OnTrackDown)
OnMessage(0x100, OnTrackKey)
; 全屏游戏/切分辨率会把 gamma LUT 重置成线性，夜灯看上去就失效了。守护每秒核对一次；
; WM_DISPLAYCHANGE(0x7E) 是系统在显示模式变更时广播的，抢在下一拍定时器之前先补一次。
SetTimer(GuardRamp, 1000)
OnMessage(0x7E, GuardRamp)
OnExit(OnScriptExit)
