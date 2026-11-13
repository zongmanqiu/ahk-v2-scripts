; ==UserScript==
; @name         文件哈希
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.2.0
; @description  选或拖入文件，一趟读出 MD5/SHA1/SHA256/SHA384/SHA512 五种校验值，双击即复制
; @author       邱宗满
; @date         2026-11-13
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.2.2+（亦可独立运行）
; @entry        主窗口「选择文件」或拖放文件入窗；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 文件哈希：一次文件读取同时喂五个 CryptoAPI 哈希句柄，列表展示，双击行复制或「复制全部」。
; 1.1.0 增 SHA384（探针实测与 certutil 同值）。CRC32 经查不做：CryptoAPI 的 CALG_CRC32 在
; AES/FULL 两提供方下 CryptCreateHash 均报 NTE_BAD_ALGID（探针结论留档 info/HISTORY.md 1.1.0），
; 纯 AHK 逐字节查表 ~10MB/s 会拖垮"一趟读"卖点，判不达"小而美"准入。
; 形态偏离：以 GUI 窗口为唯一入口，不注册托盘菜单、不设全局热键；独立运行同样直接弹窗，
; 窗口关闭即退出。许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
; 来源与许可登记：调用链取证参考过社区实现 HashFile.ahk（原作 Deo，AHK 官方作者 lexikos
; 修订 v2；autohotkey.com 论坛 topic 66139），未复制其代码——本文件为独立 v2 实现，
; 结构相似源于 Advapi32 API 序列的固定性（Acquire→Create→Data→GetParam）。
; 自测黄金向量与本机系统 certutil 实测一致。零外部 exe、零网络、零注册表。
; FileSelect 坑（1.1.1 修）：(&sel, , 标题) 三参形式把标题绑到 RootDir，目录不存在则静默
; 返回 false、按钮看似失效；必须 (&sel, Options, RootDir, Prompt) 四参把标题放最后。
; 1.1.2 修按钮全哑：1.1.1 的「去 3D」把 GWL_ID(-12) 当成 GWL_STYLE(-16) 写，控件 ID 被改成
; 0x8004，AHK 靠 WM_COMMAND 的控件 ID 派发 Click，ID 一坏两个按钮都不响应（拖放不经控件 ID 故照常）。
; 改用 Text 纯色块按钮 + 全部文字 +0x200 垂直居中、行宽 640 对齐；宿主缺 comctl32 v6 manifest，
; 系统控件走经典 3D 绘制，色块靠 WM_CTLCOLORSTATIC 与主题无关，宿主零改动。
; 1.1.3 版式收敛：删掉自绘蓝色标题带与那行算法说明（窗口标题与列表已给出同样信息），
; 内容整体上移 34；系统标题栏改由 DWM 属性染色，不再用自绘色块冒充标题栏。
; 1.1.4 扁平化：AHK 默认给 Edit/ListView 加 WS_EX_CLIENTEDGE（script_gui.cpp:2938/2950/2964），
; 经典样式下就是那圈 3D 凹陷；控件选项 -E0x200 在 exstyle_remove 里抵消它（:3093）。
; 1.1.5 精确对齐：底块不再外扩 1px，改为与列头/按钮同 x/y/w/h，原生控件四周内缩 1px 露细线。
; 1.1.6 输入框文字真正垂直居中：EM_SETRECT(0xB3) 只对 ES_MULTILINE 生效，故改用
; "Multi -VScroll -WantReturn -Wrap" 凑出多行样式再设 top=2；单行 Edit 恒不动。
; 1.2.0 按 开发指南 §10 统一原生 UI：672 大窗坐标照 §10.3.3 重算（输入行
; 456+8+84+8+84=640、列表区整体框 149=26+121+2）；八色令牌换成浅底黑字，按钮改 1px
; 描边且不分主次（中蓝配近黑字发闷），列头带与列表落进同一个框，caption 与状态条同色。
; 状态条只留事实句与「·」，不写指令句、不写内部术语。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

PROV_RSA_AES := 24
CRYPT_VERIFYCONTEXT := 0xF0000000
HP_HASHVAL := 0x0002
ALGS := [{ name: "MD5", alg: 0x8003 },
         { name: "SHA1", alg: 0x8004 },
         { name: "SHA256", alg: 0x800C },
         { name: "SHA384", alg: 0x800D },
         { name: "SHA512", alg: 0x800E }]
CHUNK := 262144

gGui := 0, gPathEdit := 0, gInfo := 0, gList := 0, gStatus := 0

; 一趟读取喂多柄。文件打不开直接抛 OSError（调用方呈现，不假成功）；
; 单算法建柄失败只污染自己那格，其余照常用同一趟数据出结果——失败隔离。
Compute(path, algList) {
    global PROV_RSA_AES, CRYPT_VERIFYCONTEXT, HP_HASHVAL, CHUNK, gStatus
    hbuf := Buffer(8, 0)
    if !DllCall("advapi32\CryptAcquireContextW", "Ptr", hbuf, "Ptr", 0, "Ptr", 0,
            "UInt", PROV_RSA_AES, "UInt", CRYPT_VERIFYCONTEXT, "Int")
        throw OSError(A_LastError, -1, "CryptAcquireContextW")
    hProv := NumGet(hbuf, 0, "Ptr")
    hashes := []
    results := []
    try {
        for a in algList {
            hh := { name: a.name, h: 0, err: "" }
            hcb := Buffer(8, 0)
            if DllCall("advapi32\CryptCreateHash", "Ptr", hProv, "UInt", a.alg, "UInt", 0,
                    "UInt", 0, "Ptr", hcb, "Int") {
                hh.h := NumGet(hcb, 0, "Ptr")
                if !hh.h
                    hh.err := "建柄返回空句柄"
            } else
                hh.err := "算法不可用（错误码 " A_LastError "）"
            hashes.Push(hh)
        }
        f := FileOpen(path, "r")
        try {
            f.Pos := 0
            buf := Buffer(CHUNK, 0)
            while (n := f.RawRead(buf, CHUNK)) {
                for hh in hashes
                    if hh.h && !DllCall("advapi32\CryptHashData", "Ptr", hh.h, "Ptr", buf,
                            "UInt", n, "UInt", 0, "Int") {
                        hh.err := "喂数据失败（错误码 " A_LastError "）"
                        DllCall("advapi32\CryptDestroyHash", "Ptr", hh.h)
                        hh.h := 0
                    }
                if gStatus
                    gStatus.Value := "计算中 · 已读 " FormatSize(f.Pos)
            }
        } finally
            f.Close()
        for hh in hashes {
            hexv := ""
            if hh.h {
                ; 探针实测教训：HP_HASHSIZE 查询在 pbData 传空时只回显入参大小、不给真实长度，
                ; 拿它定缓冲会截错。直接用 64 字节大缓冲走 HP_HASHVAL，由 pdwDataLen 回真长度。
                big := Buffer(64, 0)
                cbLen := Buffer(4, 0)
                NumPut("UInt", 64, cbLen)
                if DllCall("advapi32\CryptGetHashParam", "Ptr", hh.h, "UInt", HP_HASHVAL,
                        "Ptr", big, "Ptr", cbLen, "UInt", 0, "Int") {
                    got := NumGet(cbLen, 0, "UInt")
                    if got < 16 || got > 64
                        hh.err := "返回长度异常（" got " 字节）"
                    else
                        Loop got
                            hexv .= Format("{:02x}", NumGet(big, A_Index - 1, "UChar"))
                } else
                    hh.err := "取值失败（错误码 " A_LastError "）"
            }
            results.Push({ name: hh.name, hex: hh.err ? "" : hexv, err: hh.err })
        }
    } finally {
        for hh in hashes
            if hh.h
                DllCall("advapi32\CryptDestroyHash", "Ptr", hh.h)
        DllCall("advapi32\CryptReleaseContext", "Ptr", hProv, "UInt", 0)
    }
    return results
}

; DWM 属性 35/36/34 只写不读，验证只能看截图像素；COLORREF 是 0x00BBGGRR。
; #DCE8F7 → 0x00F7E8DC、#202B3A → 0x3A2B20，与状态条同色。
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

SetEditRect(hwnd, left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0)
    NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8)
    NumPut("Int", bottom, rc, 12)
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0xB3, "Ptr", 0, "Ptr", rc, "Ptr")
}

; 浅色底 + 近黑字之后，按钮不能靠「底色比别人深」立形，改成 1px 描边：外块铺边框色、
; 内块四周缩进 1px 铺底色。两块都挂 Click —— 否则点在 1px 边上没反应，手感像坏了。
; 不用系统 Button：宿主缺 comctl32 v6 manifest 时会退回经典 3D 凸起。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

; 版式照 开发指南 §10：客户区 672×263，内容行 x16 w640（672−16×2）；行内加和精确等于
; 640，按钮宽 = 文字 + 左右各 16，整组右对齐；文字控件固定高 +0x200 垂直居中；
; 列表区做成整体框（父块露 1px 线），caption 由 DWM 染成与状态条同一个 #DCE8F7。
; 不画自绘标题带：窗口标题已有名字、列头已列出三列，叠一条带属冗余。
; 切勿写控件的 GWL_ID(-12)：AHK 靠 WM_COMMAND 的控件 ID 派发 Click，改坏即按钮全哑。
BuildGui() {
    global gGui, gPathEdit, gInfo, gList, gStatus
    gGui := Gui("", "文件哈希")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())
    gGui.OnEvent("DropFiles", OnDropFiles)

    ; 输入行：输入框吃余量 456 + 8 + 84 + 8 + 84 = 640。
    ; -E0x200 抵消 AHK 默认加的 WS_EX_CLIENTEDGE；Multi 系列凑 ES_MULTILINE 才能用 EM_SETRECT
    ; 把墨迹推到垂直居中（单行 Edit 对 0xB3 无效），top=2 只对 s10 + h26 实证有效。
    gGui.Add("Text", "x16 y12 w456 h28 BackgroundB7C8E0")
    gPathEdit := gGui.Add("Edit", "x17 y13 w454 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(gPathEdit.Hwnd, 8, 2, 448, 26)
    FlatButton(gGui, 480, 12, 84, 28, "选择文件", "EBF2FB", "B7C8E0", PickFile)
    FlatButton(gGui, 572, 12, 84, 28, "复制全部", "EBF2FB", "B7C8E0", CopyAll)

    ; 信息行只写算完才有的事实，不重复窗口标题、不写操作说明。
    gInfo := gGui.Add("Text", "x16 y48 w640 h24 BackgroundF7F9FC c202B3A +0x200", "未选择文件")

    ; 列头带与列表落进同一个 FRAME 外框（K27）：外框 y78 h149，标题带与列表都内缩 1px，
    ; 四边共用一条线；底部相接处不留缝，BAND/WHITE 的分界就是线。
    gGui.Add("Text", "x16 y78 w640 h149 BackgroundB7C8E0")
    gGui.Add("Text", "x17 y79 w638 h26 BackgroundDCE8F7")
    ; 三列 74+448+116 = 638（列表内宽）；列头文字块比各列起点缩进 CELL_PAD=6，
    ; 与列表文字起点对齐。加粗只给列头，写完立刻 Norm 还原。
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x23 y79 w68 h26 BackgroundDCE8F7 c202B3A +0x200", "算法")
    gGui.Add("Text", "x97 y79 w442 h26 BackgroundDCE8F7 c202B3A +0x200", "哈希值")
    gGui.Add("Text", "x545 y79 w110 h26 BackgroundDCE8F7 c202B3A +0x200", "状态")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    ; -Hdr 去掉原生列头（宿主里是 3D 凸起且可拖宽），-E0x200 去 3D 凹陷。
    gList := gGui.Add("ListView", "x17 y105 w638 h121 -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["算法", "哈希值", "状态"])
    gList.OnEvent("DoubleClick", (*) => CopySelected())
    gList.ModifyCol(1, 74), gList.ModifyCol(2, 448), gList.ModifyCol(3, 116)

    ; 状态条自己铺底块：原生 StatusBar 在 Win11 下 Background 要 -Theme、c 文字色无效，
    ; 还会带一条自己的分隔线。文字块与底块同色同高，只差 STATUS_PAD 内缩。
    gGui.Add("Text", "x0 y233 w672 h30 BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y233 w648 h30 BackgroundDCE8F7 c202B3A +0x200", "就绪")
    gGui.Show("w672 h263 Center")
    PaintCaption()
}

PickFile(*) {
    sel := ""
    ; 坑：FileSelect(&sel, , 标题) 三参数形式会把标题绑到"起始目录"，目录不存在 → 静默 false、
    ; 按钮看起来失效。必须四参数形式 (&sel, Options, RootDir, Prompt) 把标题放到最后一位。
    if FileSelect(&sel, , , "选择要计算哈希的文件")
        LoadFile(sel)
}

OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global gStatus
    LoadFile(files[1])
    if files.Length > 1
        gStatus.Value .= " · 拖入 " files.Length " 个文件，只算了第一个"
}

LoadFile(path) {
    global gPathEdit, gInfo, gList, gStatus, ALGS
    gPathEdit.Value := path
    fi := 0
    try
        fi := FileOpen(path, "r")
    if !fi {
        gInfo.Value := "文件打不开或不存在：" path
        gStatus.Value := "失败 · 未完成计算"
        return
    }
    sz := fi.Length
    fi.Close()
    gInfo.Value := ShortName(path) . " · " . FormatSize(sz) . " · " . ALGS.Length . " 种算法"
    gList.Delete()
    for a in ALGS
        gList.Add("", a.name, "", "等待")
    try
        res := Compute(path, ALGS)
    catch as e {
        gStatus.Value := "失败 · " e.Message
        return
    }
    bad := 0
    for i, r in res {
        if r.err
            bad++
        gList.Modify(i, "", r.name, r.hex, r.err ? r.err : "双击复制")
    }
    gStatus.Value := bad ? "完成 · " bad " 个算法不可用" : "完成 · " ALGS.Length " 种算法"
}

CopySelected() {
    global gList, gStatus
    ; GetNext 的 RowType 只认 F / C / 空，写 "Focused" 或 "Selected" 会抛错（K9）。
    r := gList.GetNext(0, "F")
    if !r
        r := gList.GetNext(0)
    if !r {
        gStatus.Value := "未选中行"
        return
    }
    v := gList.GetText(r, 2)
    if !v {
        gStatus.Value := "该行没有可复制的结果"
        return
    }
    A_Clipboard := v
    gStatus.Value := "已复制 " gList.GetText(r, 1) " · " StrLen(v) " 个字符"
}

CopyAll(*) {
    global gList, gStatus
    t := ""
    n := gList.GetCount()
    Loop n {
        v := gList.GetText(A_Index, 2)
        if v
            t .= gList.GetText(A_Index, 1) . " = " . v . "`n"
    }
    if t {
        A_Clipboard := t
        gStatus.Value := "已复制全部 · " StrLen(t) " 个字符"
    } else
        gStatus.Value := "无可复制的结果"
}

ShortName(p) {
    SplitPath p, &nm
    return nm
}

FormatSize(b) {
    if b < 1024
        return b " B"
    if b < 1048576
        return Round(b / 1024, 1) " KB"
    if b < 1073741824
        return Round(b / 1048576, 1) " MB"
    return Round(b / 1073741824, 2) " GB"
}

; ── 无 GUI 自测：--selftest [输出路径] ────────────────────────────────
; 黄金向量为本机系统 certutil 对内容 "abc" 的实测值；只建自创临时文件，结束即删。

if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\selftest-result.txt")

RunSelfTest(path) {
    global ALGS
    out := ""
    Emit(s) => out .= s "`n"

    GOLDEN := { MD5: "900150983cd24fb0d6963f7d28e17f72",
                SHA1: "a9993e364706816aba3e25717850c26c9cd0d89d",
                SHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                SHA384: "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                      . "8086072ba1e7cc2358baeca134c825a7" }
    golden512 := "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
    golden512 .= "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"

    tmp := A_Temp "\ahkdeck-hash-selftest-abc.bin"
    try FileDelete(tmp)
    tf := FileOpen(tmp, "w")
    tf.Write("abc")
    tf.Close()

    try {
        res := Compute(tmp, ALGS)
        want := ""
        for r in res {
            want := r.name = "SHA512" ? golden512 : GOLDEN.%r.name%
            Emit((!r.err && r.hex = want ? "PASS " : "FAIL ") "黄金 " r.name . (r.err ? " ←" r.err : ""))
        }
        res2 := Compute(tmp, ALGS)
        same := true
        for i, r in res2
            if r.hex != res[i].hex
                same := false
        Emit((same ? "PASS " : "FAIL ") "重复计算逐位确定性")

        soloOk := true
        for i, a in ALGS {
            one := Compute(tmp, [a])
            if one[1].hex != res[i].hex
                soloOk := false
        }
        Emit((soloOk ? "PASS " : "FAIL ") "单算法趟与多柄同趟一致（五柄交错无串味）")

        threw := false
        try Compute(A_Temp "\ahkdeck-不存在的文件-9527.bin", ALGS)
        catch
            threw := true
        Emit((threw ? "PASS " : "FAIL ") "不存在文件抛错拒算（不假成功）")

        bogus := Compute(tmp, [{ name: "BAD", alg: 0x7FFFF00D }])
        Emit((bogus[1].err && !bogus[1].hex ? "PASS " : "FAIL ") "非法算法位如实报不可用")

        mixed := Compute(tmp, [{ name: "BAD", alg: 0x7FFFF00D }, ALGS[3]])
        Emit((mixed[1].err && !mixed[2].err && mixed[2].hex = GOLDEN.SHA256 ? "PASS " : "FAIL ") "坏柄不污染好柄（失败隔离）")

        lenOk := true
        lens := [32, 40, 64, 96, 128]
        for i, r in res
            if StrLen(r.hex) != lens[i]
                lenOk := false
        Emit((lenOk ? "PASS " : "FAIL ") "五值长度 32/40/64/96/128 十六进制字符")
    } finally
        try FileDelete(tmp)

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
