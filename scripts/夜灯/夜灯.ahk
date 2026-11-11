; ==UserScript==
; @name         夜灯
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.2
; @description  滑块调屏幕色温（GammaRamp），并同步写入 Windows 夜间模式设置
; @author       邱宗满
; @date         2026-11-12
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
gSlider := 0
gPct := 0
gIntensity := 0
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

ApplyRamp(k) {
    ramp := BuildRamp(k)
    hdc := DllCall("user32.dll\GetDC", "Ptr", 0, "Ptr")
    if !hdc
        return false
    ok := DllCall("gdi32.dll\SetDeviceGammaRamp", "Ptr", hdc, "Ptr", ramp.Ptr, "Int")
    DllCall("user32.dll\ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return ok != 0
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

ReadVarint(buf, pos) {
    val := 0
    shift := 0
    n := 0
    Loop 10 {
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
    if (NumGet(data, 0, "UChar") != 0x43 || NumGet(data, 1, "UChar") != 0x42)
        return 0
    p := 4
    if (NumGet(data, p, "UChar") != 0x0A)
        return 0
    p += 1
    Loop 16 {
        if (p >= data.Size)
            return 0
        c := NumGet(data, p, "UChar")
        p += 1
        if (c = 0)
            break
    }
    if (NumGet(data, p, "UChar") != 0x2A)
        return 0
    p += 1
    if (NumGet(data, p, "UChar") != 0x06)
        return 0
    p += 1
    tsPos := p
    r := ReadVarint(data, p)
    tsVal := r[1]
    tsLen := r[2]
    p += tsLen
    if (NumGet(data, p, "UChar") != 0x2A)
        return 0
    p += 1
    if (NumGet(data, p, "UChar") != 0x2B)
        return 0
    p += 1
    p += 1
    r := ReadVarint(data, p)
    count := r[1]
    p += r[2]
    innerPos := p
    tempPos := 0
    tempVal := 0
    i := 0
    while (i + 2 < count) {
        pos := innerPos + i
        if (NumGet(data, pos, "UChar") = 0xCF && NumGet(data, pos + 1, "UChar") = 0x28) {
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
    if !gPct
        return
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

OnSliderChange(ctrl, info) {
    global gIntensity
    gIntensity := ctrl.Value
    ApplyRamp(IntensityToKelvin(gIntensity))
    UpdatePct()
    ScheduleWrite()
}

OnPanelClose(*) {
    global gGui, gSlider, gPct
    if gGui
        gGui.Destroy()
    gGui := 0
    gSlider := 0
    gPct := 0
}

ShowPanel() {
    global gGui, gSlider, gPct, gIntensity
    if gGui {
        gGui.Show()
        WinActivate("ahk_id " . gGui.Hwnd)
        return
    }
    gGui := Gui("+AlwaysOnTop +Owner -MaximizeBox -MinimizeBox", "夜灯调整")
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.MarginX := 12
    gGui.MarginY := 8
    gSlider := gGui.Add("Slider", "w232 Range0-100 NoTicks ToolTip", gIntensity)
    gPct := gGui.Add("Text", "x+8 w42 Right", gIntensity . "%")
    gSlider.OnEvent("Change", OnSliderChange)
    gGui.OnEvent("Close", OnPanelClose)
    gGui.OnEvent("Escape", OnPanelClose)
    UpdatePct()
    MonitorGetWorkArea(1, &wl, &wt, &wr, &wb)
    gGui.Show("AutoSize x-20000 y-20000")
    gGui.GetPos(&gx, &gy, &gw, &gh)
    gGui.Move(wr - gw - 12, wb - gh - 12)
    hIcon := DllCall("LoadIconW", "Ptr", 0, "Ptr", 32512, "Ptr")
    DllCall("SendMessageW", "Ptr", gGui.Hwnd, "UInt", 0x80, "Ptr", 0, "Ptr", hIcon)
    DllCall("SendMessageW", "Ptr", gGui.Hwnd, "UInt", 0x80, "Ptr", 1, "Ptr", hIcon)
    DllCall("SendMessageW", "Ptr", gGui.Hwnd, "UInt", 0x127, "Ptr", 0x10001, "Ptr", 0)
    DllCall("SendMessageW", "Ptr", gSlider.Hwnd, "UInt", 0x128, "Ptr", 0x10001, "Ptr", 0)
    DllCall("SetFocus", "Ptr", gGui.Hwnd)
}

ResetToCool() {
    global gSlider, gIntensity, MAX_K
    gIntensity := 0
    if gSlider
        gSlider.Value := 0
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
; 只动纯函数与 HKCU 自建键：不写真实夜间模式值、不碰屏幕 Gamma、不改 HKLM。

if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest-result.txt")

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

; 首次运行为便于观察直接弹面板；不需要可删掉下一行。
SetTimer(() => ShowPanel(), -600)

OnExit(OnScriptExit)
