; ==UserScript==
; @name         文件时间修改
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      2.3.2
; @description  拖入文件或文件夹，点「更新时间」后设定创建/修改/访问时间；勾选「包含子文件（夹）」才连同内部所有文件与子文件夹一起生效
; @author       邱宗满
; @date         2026-11-12
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

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global gGui := 0, gList := 0, gStatus := 0
global gChkM := 0, gChkC := 0, gChkA := 0
global gDayM := 0, gDayC := 0, gDayA := 0
global gTimeM := 0, gTimeC := 0, gTimeA := 0
global gChkRec := 0
global gBtnApply := 0, gBtnClear := 0
global gSeen := Map()

BuildGui()
return

FT(dayCtrl, timeCtrl) {
    return SubStr(dayCtrl.Value, 1, 8) SubStr(timeCtrl.Value, 9, 6)
}

SetStatus(s) {
    global gStatus
    gStatus.Value := "  " s
}

PaintCaption() {
    global gGui
    c := Buffer(4, 0)
    NumPut("UInt", 0xB46E3C, c)
    t := Buffer(4, 0)
    NumPut("UInt", 0xFFFFFF, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

BuildGui() {
    global
    gGui := Gui("", "文件时间修改 v2.3.2")
    gGui.BackColor := "FFFFFF"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.MarginX := 12
    gGui.MarginY := 10

    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x12 y10 w396 h26 Background3C6EB4")
    gGui.Add("Text", "x20 y10 w96 h26 Background3C6EB4 cFFFFFF +0x200", "时间类型")
    gGui.Add("Text", "x116 y10 w146 h26 Background3C6EB4 cFFFFFF +0x200", "年/月/日")
    gGui.Add("Text", "x268 y10 w130 h26 Background3C6EB4 cFFFFFF +0x200", "时/分/秒")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    gChkM := gGui.Add("CheckBox", "x14 y42 w100 BackgroundFFFFFF Checked", "修改时间")
    gDayM := gGui.Add("DateTime", "x116 y40 w146", "yyyy/MM/dd")
    gTimeM := gGui.Add("DateTime", "x268 y40 w130 +0x1", "HH:mm:ss")

    gChkC := gGui.Add("CheckBox", "x14 y72 w100 BackgroundFFFFFF Checked", "创建时间")
    gDayC := gGui.Add("DateTime", "x116 y70 w146", "yyyy/MM/dd")
    gTimeC := gGui.Add("DateTime", "x268 y70 w130 +0x1", "HH:mm:ss")

    gChkA := gGui.Add("CheckBox", "x14 y102 w100 BackgroundFFFFFF Checked", "访问时间")
    gDayA := gGui.Add("DateTime", "x116 y100 w146", "yyyy/MM/dd")
    gTimeA := gGui.Add("DateTime", "x268 y100 w130 +0x1", "HH:mm:ss")

    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gGui.Add("Text", "x12 y132 w396 h26 Background3C6EB4")
    gGui.Add("Text", "x20 y132 w200 h26 Background3C6EB4 cFFFFFF +0x200", "路径")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    gList := gGui.Add("ListView", "x12 y162 w396 h176 -Hdr BackgroundFFFFFF c202B3A", ["路径"])
    gList.ModifyCol(1, 600)

    gChkRec := gGui.Add("CheckBox", "x14 y344 w170 h26 BackgroundFFFFFF", "包含子文件（夹）")
    gChkRec.OnEvent("Click", (*) => RefreshStatus())

    gBtnApply := gGui.Add("Text", "x216 y344 w88 h26 Background3C6EB4 cFFFFFF +0x200 Center", "更新时间")
    gBtnApply.OnEvent("Click", (*) => ApplyAll())
    gBtnClear := gGui.Add("Text", "x312 y344 w88 h26 BackgroundE3EAF6 c24406B +0x200 Center", "清空列表")
    gBtnClear.OnEvent("Click", (*) => ClearList())

    gStatus := gGui.Add("Text", "x0 y378 w420 h28 Background3C6EB4 cFFFFFF +0x200", "")
    gGui.OnEvent("DropFiles", OnDropFiles)
    gGui.OnEvent("Close", (*) => gGui.Destroy())
    gGui.Show("w420 h406")
    PaintCaption()
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
}

ClearList() {
    global
    gList.Delete()
    gSeen := Map()
    RefreshStatus()
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
