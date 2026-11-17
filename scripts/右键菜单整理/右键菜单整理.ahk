; ==UserScript==
; @name         右键菜单整理
; @id           context-menu-tidy
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.2.1
; @description  拖入文件/文件夹读出它的右键菜单，或看桌面空白/文件夹空白的菜单，逐项隐藏或调整位置，只写 HKCU 可恢复
; @author       邱宗满
; @date         2026-11-17
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        左侧三个入口（拖入对象/桌面空白/文件夹空白），拖入文件或文件夹即展开它的菜单；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 右键菜单整理：零提权的右键菜单管理器。右键菜单一个项来自三层，本脚本覆盖前两层：
;   · L1 静态 verb（shell\<verb>）——隐藏用 HKCU 影子键写 ProgrammaticAccessOnly，
;     位置用 Position=top/bottom；HKLM 原键一个字节都不动。
;   · L2 COM 扩展（shellex\ContextMenuHandlers）——隐藏用 Shell Extensions\Blocked
;     写 CLSID 值名，删值恢复；实测 HKCU 侧 Blocked 生效、CLSID 原键不动。
;   · L3 Win11 打包命令（IExplorerCommand）——本脚本不做，属 sparse MSIX 范畴。
;
; ★ 两层机制都实测过（探针用完即删，见 info/HISTORY.md 1.0.0/1.1.0）：
;   HKCU 影子键/Blocked 的值在 HKCR 合并视图可见；HKLM 原值与 command 仍照常合并；
;   菜单项不被写坏；删值即恢复。
;
; 1.2.0 起交互改「3 种场景」：拖入具体对象 / 桌面空白 / 文件夹空白。
;   ★ 只读渲染菜单（IContextMenu）拿不到可写的来源：COM 项是 OWNERDRAW 连 verb 都没有，
;   静态项只有 verb 没有位置根——故仍读注册表来源，再由脚本按对象类型合并展开，
;   "3 种"是交互形态，不是读取引擎（实测数据见 info/HISTORY.md 1.2.0）。
;   一个菜单项常同时来自多个位置（7-Zip 在 * 与 AllFilesystemObjects 都有），
;   列表去重合并成一项、记住全部 roots，隐藏时对每根都写影子键才有效。
;
; 蓝本：ContextMenuManager 的 ShellItem.cs（L1 隐藏/位置）+ registry-model.md 的 Blocked 纪律
; （L2 CLSID 黑名单）。本文件是独立 AHK v2 实现，未复制其代码。许可 AGPL-3.0。
;
; 坑（源码+实测，务必保留）：
;   · 四种 L1 隐藏标记 OR：HideBasedOnVelocityId==0x639bc8 / LegacyDisable /
;     ProgrammaticAccessOnly / CommandFlags%16>=8；判状态四种都看，只写 ProgrammaticAccessOnly。
;   · CommandFlags 是 EXPCMDFLAGS 功能位掩码，只读不写；opennewwindow 不能写 LegacyDisable（坏 Win+E）。
;   · COM 显示名优先级：handler 注册名（7-Zip/ima/360/Unlocker 这类好认）> CLSID 默认值
;     （"ShellContextMenu Class" 这类泛名不采）> GUID 兜底。
;   · 系统共享 CLSID（共享/投射/还原/照片/库）零提权也不能乱 Block，会连带系统功能，本脚本拒写。
;   · Blocked 按 CLSID 生效，一个 CLSID 可能在多个位置出现——关一次全局生效，状态列如实反映。
;   · AHK 的 = 不区分大小写，位置归一用 ==；嵌套函数写外层变量用 ByRef。
;   · 内核无 RegEnumKey：用 RegOpenKeyExW + RegEnumKeyExW，锁 KEY_WOW64_64KEY。
;   · 宿主 MCP 的 send_input 命中不到被装饰色块包住的 ListView（K19）：写操作走 --probe 分支测。
;   · 拖入区与导航都是 Text 色块，+0x200 才收 Click/DropFiles（K19）。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ── 常量 ────────────────────────────────────────────────────────────────
HKEY_CLASSES_ROOT  := 0x80000000
HKEY_CURRENT_USER  := 0x80000001
HKEY_LOCAL_MACHINE := 0x80000002
KEY_READ_64        := 0x20019 | 0x100
REG_DWORD          := 4
REG_SZ             := 1
MISSING            := "__ahkdeck_context_tidy_missing__"
HIDE_MARK          := "ProgrammaticAccessOnly"
VEL_HIDE_VALUE     := 6527944           ; 0x639bc8
BLOCK_PATH         := "Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"

; 客户区 820×450；左侧三入口 + 拖入区，右侧四列。
WIN_W := 820, WIN_H := 450
NAV_X := 16, NAV_W := 140, NAV_ITEM_H := 28, NAV_GAP := 4
LIST_X := 172, LIST_Y := 16, LIST_W := 632, HEAD_H := 28, LIST_H := 334
; 四列宽之和 = 318+60+86+150 = 614 ≤ 自绘滚动条占位后的列表内宽（630-10=620），
; 否则列宽溢出又会冒出原生横条（K30）。末列吃下余量。
COL_NAME_W := 318, COL_SRC_W := 60, COL_STATE_W := 86, COL_POS_W := 150
; 垂直节奏（§10）：列表底 378 → BLOCK_GAP 6 → 按钮 384..414 → BLOCK_GAP 6 → 状态条 420..450 贴底。
BTN_Y := 384, BTN_H := 30
STATUS_Y := 420, STATUS_H := 30
DROP_Y := 128, DROP_H := 116

; 三种场景（交互形态）。位置根由 SceneRoots() 按对象类型展开。
SceneDefs() => [
    { key: "obj",    name: "拖入文件/文件夹" },
    { key: "deskbg", name: "桌面空白处" },
    { key: "dirbg",  name: "文件夹空白处" }
]

; 系统共享 CLSID：零提权也不能 Block，会连带系统菜单功能。
; （显示名不走这张表——显示一律先查 FriendlyClsids。）
SharedClsids() => Map(
    "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}", "授予访问权限",
    "{7AD84985-87B4-4a16-BE58-8B72A5B390F7}", "投射到设备",
    "{596AB062-B4D2-4215-9F74-E9109B0A8153}", "还原以前的版本",
    "{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}", "照片编辑",
    "{E2BF9676-5F8F-435C-97EB-11607A5BEDF7}", "共享",
    "{3dad6c5d-2167-4cae-9914-f99e41c12cfa}", "包含到库中",
    "{00021401-0000-0000-c000-000000000046}", "快捷方式打开"
)

; COM 扩展友好名：CLSID 键默认值全是英文泛名（"Microsoft SendTo Service"），
; 用户在真实菜单里看到的是这些中文名（注册表探针逐一核对，见 HISTORY 1.2.1）。
FriendlyClsids() => Map(
    "{7BA4C740-9E81-11CF-99D3-00AA004AE837}", "发送到",
    "{f3d06e7c-1e45-4a26-847e-f9fcdee59be0}", "复制文件地址",
    "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}", "授予访问权限",
    "{596AB062-B4D2-4215-9F74-E9109B0A8153}", "还原以前的版本",
    "{3dad6c5d-2167-4cae-9914-f99e41c12cfa}", "包含到库中",
    "{470C0EBD-5D73-4d58-9CED-E91E22E23282}", "固定到“开始”屏幕",
    "{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}", "固定到“开始”屏幕",
    "{90AA3A4E-1CBA-4233-B8BB-535773D48449}", "固定到任务栏",
    "{D969A300-E7FF-11d0-A93B-00A0C90F2719}", "新建",
    "{09799AFB-AD67-11d1-ABCD-00C04FC30936}", "打开方式",
    "{A470F8CF-A1E8-4f65-8335-227475AA5C46}", "加密",
    "{E61BF828-5E63-4287-BEF1-60B1A4FDE0E3}", "工作文件夹",
    "{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}", "使用照片编辑",
    "{7AD84985-87B4-4a16-BE58-8B72A5B390F7}", "投射到设备",
    "{E2BF9676-5F8F-435C-97EB-11607A5BEDF7}", "共享",
    "{3D1975AF-48C6-4f8e-A182-BE0E08FA86A9}", "NVIDIA 控制面板"
)

; 静态 verb 的 shell 内建名：键值全空的 verb（open 等）真实菜单显示这些词，
; 注册表里查不到，只能内建映射兜底。
BuiltinVerbNames() => Map(
    "open", "打开",
    "edit", "编辑",
    "rename", "重命名",
    "delete", "删除",
    "cut", "剪切",
    "copy", "复制",
    "paste", "粘贴",
    "properties", "属性",
    "runas", "以管理员身份运行",
    "print", "打印",
    "find", "查找"
)
BuiltinFallback(verb) {
    m := BuiltinVerbNames()
    return m.Has(verb) ? m[verb] : verb
}

; ── 纯函数（--selftest 可测，不碰注册表）─────────────────────────────────
HiddenByMarks(vals) {
    if (vals.Has("HideBasedOnVelocityId") && vals["HideBasedOnVelocityId"] = VEL_HIDE_VALUE)
        return true
    for n in ["LegacyDisable", "ProgrammaticAccessOnly"]
        if vals.Has(n)
            return true
    if (vals.Has("CommandFlags") && Mod(vals["CommandFlags"], 16) >= 8)
        return true
    return false
}

NormalizePos(v) {
    s := StrLower(Trim(v))
    if (s = "")
        return "default"
    return (s = "top" || s = "bottom") ? s : "default"
}

; Shell 对 Position 不区分大小写（注册表实测存 "Bottom"），归一必须同样不敏感。

IsIndirectString(s) => (s != "" && SubStr(s, 1, 1) = "@")
IsProtectedVerb(v) => (v = "open" || v = "edit")
ShadowKey(suffix, verb) => "HKCU\Software\Classes\" suffix "\shell\" verb

; 文件对象的来源根：通用项 + 扩展名键 + ProgID。
; 拆成纯函数便于 selftest：isDir 由 DirExist 判，ext 带点，progid 来自 HKCR\.<ext> 默认值。
ObjRoots(isDir, ext := "", progid := "") {
    if (isDir)
        return ["Directory", "Folder", "AllFilesystemObjects"]
    roots := ["*", "AllFilesystemObjects"]
    if (ext != "")
        roots.Push("SystemFileAssociations\" ext)
    if (progid != "")
        roots.Push(progid)
    return roots
}

; 三场景 → 要枚举的位置根（实测映射，见 HISTORY 1.2.0）。
;   deskbg = Directory\Background（新建/AnyCode/cmd）+ DesktopBackground（个性化/壁纸）
;   dirbg  = Directory\Background
;   obj    = 按文件/文件夹分别展开 ObjRoots()
SceneRoots(sceneKey, dropPath := "") {
    switch sceneKey {
        case "deskbg":
            return ["Directory\Background", "DesktopBackground"]
        case "dirbg":
            return ["Directory\Background"]
        case "obj":
            if (dropPath = "")
                return []
            if DirExist(dropPath)
                return ObjRoots(true)
            SplitPath(dropPath, , , &ext)   ; AHK 的 Ext 不带点："md"
            if (ext != "" && SubStr(ext, 1, 1) != ".")
                ext := "." ext
            pid := RegGet(HKEY_CLASSES_ROOT, ext, "", "")
            return ObjRoots(false, ext, pid)
    }
    return []
}

; 多来源合并：隐藏优先于系统隐藏优先于显示；置顶 > 置底 > 默认。
MergeState(states) {
    if (states.Has("hidden"))
        return "hidden"
    if (states.Has("syshidden"))
        return "syshidden"
    return "show"
}
MergePos(poses) {
    if (poses.Has("top"))
        return "top"
    if (poses.Has("bottom"))
        return "bottom"
    return "default"
}

; CLSID 是不是系统共享（拒写）。
IsSharedClsid(g) => SharedClsids().Has(g)

; COM 显示名：泛名（含 " Class" / "Shell extension"）不采，回退注册名。
ComLabel(handlerName, clsidDefault) {
    if (handlerName != "")
        return handlerName
    if (clsidDefault != "" && !InStr(clsidDefault, " Class") && !InStr(clsidDefault, "Shell extension"))
        return clsidDefault
    return handlerName != "" ? handlerName : "(未命名扩展)"
}

; ── Win32 注册表读取 ────────────────────────────────────────────────────
RegGet(root, path, name, default := MISSING) {
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0,
            "UInt", KEY_READ_64, "Ptr*", &h, "Int") != 0
        return default
    try {
        typ := 0, sz := 0
        if DllCall("advapi32\RegQueryValueExW", "Ptr", h, "Str", name, "Ptr", 0,
                "Ptr*", &typ, "Ptr", 0, "Ptr*", &sz, "Int") != 0
            return default
        if (sz = 0)
            return ""
        buf := Buffer(sz, 0)
        if DllCall("advapi32\RegQueryValueExW", "Ptr", h, "Str", name, "Ptr", 0,
                "Ptr*", &typ, "Ptr", buf, "Ptr*", &sz, "Int") != 0
            return default
        if (typ = REG_DWORD)
            return NumGet(buf, 0, "UInt")
        return StrGet(buf, sz // 2, "UTF-16")
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
}

EnumSubkeys(root, path) {
    arr := []
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0,
            "UInt", KEY_READ_64, "Ptr*", &h, "Int") != 0
        return arr
    try {
        i := 0
        loop {
            buf := Buffer(512, 0), cch := 256
            r := DllCall("advapi32\RegEnumKeyExW", "Ptr", h, "UInt", i, "Ptr", buf,
                "UInt*", &cch, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Int")
            if (r != 0)
                break
            arr.Push(StrGet(buf, cch, "UTF-16"))
            i++
        }
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
    return arr
}

VerbMarks(root, path, verb) {
    vals := Map()
    base := path "\" verb
    for n in ["HideBasedOnVelocityId", "LegacyDisable", "ProgrammaticAccessOnly", "CommandFlags"] {
        v := RegGet(root, base, n, MISSING)
        if (v != MISSING)
            vals[n] := v
    }
    return vals
}

VerbLabel(root, path, verb) {
    base := path "\" verb
    raw := RegGet(root, base, "MUIVerb", MISSING)
    if (raw = MISSING || raw = "")
        raw := RegGet(root, base, "", verb)
    if (raw = MISSING || raw = "")
        return BuiltinFallback(verb)
    if IsIndirectString(raw) {
        out := Buffer(1024, 0)
        if DllCall("shlwapi\SHLoadIndirectString", "Str", raw, "Ptr", out,
                "UInt", 512, "Ptr", 0, "Int") = 0 {
            s := StrGet(out, "UTF-16")
            if (s != "")
                return s
        }
        return BuiltinFallback(verb)
    }
    return raw
}

; COM 项：读 handler 默认值拿 CLSID，再读 CLSID 键默认值当显示名候选。
ComItem(root, base, name) {
    dv := RegGet(root, base "\" name, "", MISSING)
    guid := name
    if (dv != MISSING && SubStr(dv, 1, 1) = "{")
        guid := dv
    clsidDefault := RegGet(HKEY_CLASSES_ROOT, "CLSID\" guid, "", "")
    ; 显示优先级：友好名映射 > 系统共享名 > 泛名/注册名。
    label := FriendlyClsids().Has(guid) ? FriendlyClsids()[guid]
           : IsSharedClsid(guid) ? SharedClsids()[guid] : ComLabel(name, clsidDefault)
    return { name: name, guid: guid, label: label }
}

ComBlockedState(guid) {
    if RegGet(HKEY_CURRENT_USER, BLOCK_PATH, guid, MISSING) != MISSING
        return "hidden"
    if RegGet(HKEY_LOCAL_MACHINE, BLOCK_PATH, guid, MISSING) != MISSING
        return "syshidden"
    return "show"
}

NotifyAssocChanged() =>
    DllCall("shell32\SHChangeNotify", "Int", 0x08000000, "UInt", 0, "Ptr", 0, "Ptr", 0)

; ── 全局状态 ────────────────────────────────────────────────────────────
global gGui := 0, gList := 0, gStatus := 0, gNavBtns := []
global gItems := [], gScene := 1, gScroll := 0
global gDropPath := ""

; ── 数据层 ──────────────────────────────────────────────────────────────
; 合并多个来源：同一 verb / CLSID 只出一行，roots 记下全部来源，隐藏时逐根写。
MakeItems(scene) {
    items := [], seenVerb := Map(), seenCom := Map()
    roots := SceneRoots(scene.key, gDropPath)
    for root in roots {
        ; L1 静态 verb
        for verb in EnumSubkeys(HKEY_CLASSES_ROOT, root "\shell") {
            effHidden := HiddenByMarks(VerbMarks(HKEY_CLASSES_ROOT, root "\shell", verb))
            own := VerbMarks(HKEY_CURRENT_USER, "Software\Classes\" root "\shell", verb)
            state := effHidden ? (own.Has(HIDE_MARK) ? "hidden" : "syshidden") : "show"
            pos := NormalizePos(RegGet(HKEY_CLASSES_ROOT, root "\shell\" verb, "Position", ""))
            if seenVerb.Has(verb) {
                it := items[seenVerb[verb]]
                it.roots.Push(root)
                it.state := MergeState(Map(it.state, 1, state, 1))
                it.pos := MergePos(Map(it.pos, 1, pos, 1))
                continue
            }
            seenVerb[verb] := items.Length + 1
            items.Push({ layer: "verb", key: verb, label: VerbLabel(HKEY_CLASSES_ROOT, root "\shell", verb)
                       , state: state, pos: pos, src: "静态", roots: [root] })
        }
        ; L2 COM 扩展
        for name in EnumSubkeys(HKEY_CLASSES_ROOT, root "\shellex\ContextMenuHandlers") {
            ci := ComItem(HKEY_CLASSES_ROOT, root "\shellex\ContextMenuHandlers", name)
            guid := ci.guid
            if seenCom.Has(guid) {
                items[seenCom[guid]].roots.Push(root)
                continue
            }
            seenCom[guid] := items.Length + 1
            items.Push({ layer: "com", key: guid, name: name, label: ci.label
                       , state: ComBlockedState(guid), pos: ""
                       , src: "COM", roots: [root], shared: IsSharedClsid(guid) })
        }
    }
    ; shell 真实顺序：置顶在最前、置底在最后、其余按注册枚举序（分桶拼接即稳定）。
    top := [], mid := [], bot := []
    for it in items {
        if (it.pos = "top")
            top.Push(it)
        else if (it.pos = "bottom")
            bot.Push(it)
        else
            mid.Push(it)
    }
    out := []
    for bucket in [top, mid, bot]
        for it in bucket
            out.Push(it)
    return out
}

RefreshItems() {
    global gList, gStatus, gItems, gScene, gScroll, gDropPath
    scene := SceneDefs()[gScene]
    gItems := MakeItems(scene)
    gList.Delete()
    nVerb := 0, nCom := 0, nHide := 0, nSys := 0
    for it in gItems {
        st := it.state = "show" ? "显示" : it.state = "hidden" ? "已隐藏" : "系统隐藏"
        ps := it.layer = "com" ? "—" : it.pos = "top" ? "置顶" : it.pos = "bottom" ? "置底" : "默认"
        gList.Add("", it.label, it.src, st, ps)
        if (it.layer = "verb")
            nVerb++
        else
            nCom++
        if (it.state = "hidden")
            nHide++
        if (it.state = "syshidden")
            nSys++
    }
    scope := scene.key = "obj" ? (gDropPath != "" ? "拖入对象 · " gDropPath : "拖入对象（待拖入）")
                               : scene.name
    gStatus.Value := scope " · verb " nVerb " 项 / COM " nCom " 项 · 已隐藏 " nHide " · 系统隐藏 " nSys
    ; Delete/Add 会把 WS_VSCROLL 样式位置回、原生条露出（K22/K36）：填完统一重算占位+摘条。
    if (gScroll && !gScroll.dead)
        gScroll.Layout()
}

SelectedItem() {
    global gList, gItems
    r := gList.GetNext(0, "F")
    if !r
        r := gList.GetNext(0)
    return r ? gItems[r] : 0
}

; ── 写操作 ──────────────────────────────────────────────────────────────
; 静态项对每个来源根都写影子键，否则其它位置仍会把菜单项带出来。
WriteVerbMarks(roots, verb, action, pos := "") {
    errs := 0
    for root in roots {
        key := ShadowKey(root, verb)
        try {
            switch action {
                case "hide":    RegWrite "", "REG_SZ", key, HIDE_MARK
                case "show":    try RegDelete key, HIDE_MARK
                case "pos":     RegWrite pos, "REG_SZ", key, "Position"
                case "default": try RegDelete key, "Position"
            }
        } catch
            errs++
    }
    return errs
}

SetHide(on) {
    global gStatus
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if (it.layer = "verb" && IsProtectedVerb(it.key)) {
        gStatus.Value := "「" it.key "」是打开动词，本脚本不改动它"
        return
    }
    if (it.layer = "com" && it.shared && on) {
        gStatus.Value := "「" it.label "」是系统共享扩展，零提权禁用会连带系统功能，已拒绝"
        return
    }
    if (it.layer = "verb") {
        errs := WriteVerbMarks(it.roots, it.key, on ? "hide" : "show")
        if errs {
            gStatus.Value := "有 " errs " 处写入失败（可能需管理员权限）"
            return
        }
        extra := on ? "" : (it.state = "syshidden" ? "（仍有系统级隐藏标记，需管理员权限）" : "")
        msg := (on ? "已隐藏 verb「" : "已恢复 verb「") it.label "」" extra " · " it.roots.Length " 处来源"
        gStatus.Value := msg
    } else {
        ; COM：Blocked 键按 CLSID 写/删（HKCU，零提权；全局生效，与来源个数无关）
        try {
            if on {
                RegWrite "", "REG_SZ", "HKCU\" BLOCK_PATH, it.key
                gStatus.Value := "已隐藏 COM 扩展「" it.label "」（全局生效）"
            } else {
                RegDelete "HKCU\" BLOCK_PATH, it.key
                gStatus.Value := "已恢复 COM 扩展「" it.label "」"
            }
        } catch as e {
            gStatus.Value := "操作失败 · " e.Message
            return
        }
    }
    NotifyAssocChanged()
    RefreshItems()
}

SetPos(pos) {
    global gStatus
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if (it.layer = "com") {
        gStatus.Value := "COM 扩展由 DLL 动态绘制，不支持置顶/置底"
        return
    }
    if IsProtectedVerb(it.key) {
        gStatus.Value := "「" it.key "」是打开动词，本脚本不改动它"
        return
    }
    errs := WriteVerbMarks(it.roots, it.key, pos = "default" ? "default" : "pos", pos)
    if errs {
        gStatus.Value := "有 " errs " 处调整失败（可能需管理员权限）"
        return
    }
    posName := pos = "top" ? "置顶" : pos = "bottom" ? "置底" : "默认"
    gStatus.Value := "「" it.label "」位置已设为" posName " · " it.roots.Length " 处来源"
    NotifyAssocChanged()
    RefreshItems()
}

; ── 自绘滚动条 ──────────────────────────────────────────────────────────
; 整段复用《文件解锁》1.3.1 /《硬件信息》2.3.4 的 class FlatScroll（只竖轴）。
; 原生条由 comctl32 主题引擎绘制，脚本拿不到颜色；ShowScrollBar(FALSE) 只是「按需隐藏」，
; Move/Add/Delete/ModifyCol/LVM_SCROLL 都会把样式位置回，所以每次动作后补一刀 + Sync 兜底。
; 横向条撤掉，列宽做进视口。
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
        this.fnTick := ObjBindMethod(this, "DragTick")
        this.fnSync := ObjBindMethod(this, "Sync")
        ; +0x100 = SS_NOTIFY：否则静态控件命中测试透明，点击穿透（K19）。
        this.vUp := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vDn := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapL := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapR := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumbV := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        for c in [this.vUp, this.vDn, this.vGapL, this.vGapR, this.thumbV]
            c.Visible := false
    }
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
        n := DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1028, "Ptr", 0, "Ptr", 0, "Ptr")
        this.viewRows := Max(1, n ? n : Floor(this.lvH / this.itemH))
        this.maxTop := Max(0, this.rows - this.viewRows)
        this.exV := this.rows > this.viewRows
    }
    ReadTop() {
        return DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1027, "Ptr", 0, "Ptr", 0, "Ptr")
    }
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

; ── UI ──────────────────────────────────────────────────────────────────
PaintCaption() {
    global gGui
    c := Buffer(4, 0), NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0), NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

FlatButton(g, x, y, w, h, text, cb, fill := "EBF2FB", edge := "B7C8E0") {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

NavClick(i, *) {
    global gNavBtns, gScene
    gScene := i
    for j, b in gNavBtns
        b.Opt("Background" (j = i ? "EBF2FB" : "F7F9FC"))
    RefreshItems()
}

OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global gScene, gNavBtns, gDropPath, gStatus
    if !files.Length
        return
    gDropPath := files[1]
    gScene := 1
    for j, b in gNavBtns
        b.Opt("Background" (j = 1 ? "EBF2FB" : "F7F9FC"))
    RefreshItems()
}

BuildGui() {
    global gGui, gList, gStatus, gNavBtns, gScroll
    gGui := Gui("", "右键菜单整理")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => (gScroll ? gScroll.Stop() : 0, ExitApp()))
    gGui.OnEvent("DropFiles", OnDropFiles)

    gNavBtns := []
    y := 16
    for i, sc in SceneDefs() {
        b := gGui.Add("Text", "x" NAV_X " y" y " w" NAV_W " h" NAV_ITEM_H
            " Background" (i = 1 ? "EBF2FB" : "F7F9FC") " c202B3A +0x200 Center", sc.name)
        b.OnEvent("Click", NavClick.Bind(i))
        gNavBtns.Push(b)
        y += NAV_ITEM_H + NAV_GAP
    }

    ; 拖入区：白底 + 1px 框 + 居中提示（Text 色块 +0x200 才收 DropFiles）。
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w" NAV_W " h" DROP_H " BackgroundFFFFFF")
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w" NAV_W " h1 BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" NAV_X " y" (DROP_Y + DROP_H - 1) " w" NAV_W " h1 BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w1 h" DROP_H " BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" (NAV_X + NAV_W - 1) " y" DROP_Y " w1 h" DROP_H " BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" (NAV_X + 6) " y" (DROP_Y + 38) " w" (NAV_W - 12) " h20"
        " BackgroundFFFFFF c202B3A +0x200 Center", "把文件或文件夹")
    gGui.Add("Text", "x" (NAV_X + 6) " y" (DROP_Y + 64) " w" (NAV_W - 12) " h20"
        " BackgroundFFFFFF c202B3A +0x200 Center", "拖到这里")

    ; 列表区：白底块 + 四边线；装饰块 +0x100 让点击穿透（实测 K19）。
    gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_Y + 1) " w" (LIST_W - 2)
        " h" (HEAD_H + LIST_H - 1) " BackgroundFFFFFF +0x100")
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w" LIST_W " h1 BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" LIST_X " y" (LIST_Y + HEAD_H + LIST_H) " w" LIST_W " h1 BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" (LIST_X + LIST_W - 1) " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 +0x100")
    gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_Y + 1) " w" (LIST_W - 2) " h" HEAD_H " BackgroundDCE8F7 +0x100")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    hx := LIST_X + 7
    gGui.Add("Text", "x" hx " y" (LIST_Y + 1) " w" (COL_NAME_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "菜单项")
    hx += COL_NAME_W
    gGui.Add("Text", "x" hx " y" (LIST_Y + 1) " w" (COL_SRC_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "来源")
    hx += COL_SRC_W
    gGui.Add("Text", "x" hx " y" (LIST_Y + 1) " w" (COL_STATE_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "状态")
    hx += COL_STATE_W
    gGui.Add("Text", "x" hx " y" (LIST_Y + 1) " w" (COL_POS_W - 6) " h" HEAD_H
        " BackgroundDCE8F7 c202B3A +0x200", "位置")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    gList := gGui.Add("ListView", "x" (LIST_X + 1) " y" (LIST_Y + HEAD_H + 1)
        " w" (LIST_W - 2) " h" (LIST_H - 1) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["菜单项", "来源", "状态", "位置"])
    gList.ModifyCol(1, COL_NAME_W), gList.ModifyCol(2, COL_SRC_W), gList.ModifyCol(3, COL_STATE_W)
    gList.ModifyCol(4, COL_POS_W)
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)

    FlatButton(gGui, 172, BTN_Y, 64, BTN_H, "隐藏", () => SetHide(true))
    FlatButton(gGui, 244, BTN_Y, 64, BTN_H, "显示", () => SetHide(false))
    FlatButton(gGui, 332, BTN_Y, 64, BTN_H, "置顶", () => SetPos("top"))
    FlatButton(gGui, 404, BTN_Y, 64, BTN_H, "置底", () => SetPos("bottom"))
    FlatButton(gGui, 492, BTN_Y, 88, BTN_H, "恢复位置", () => SetPos("default"))
    FlatButton(gGui, 600, BTN_Y, 64, BTN_H, "刷新", (*) => RefreshItems())

    gGui.Add("Text", "x0 y" STATUS_Y " w" WIN_W " h" STATUS_H " BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y" STATUS_Y " w" (WIN_W - 24) " h" STATUS_H
        " BackgroundDCE8F7 c202B3A +0x200", "就绪")

    gGui.Show("w" WIN_W " h" WIN_H " Center")
    PaintCaption()

    ; 自绘滚动条：四个数 = 列表可用内空（x/y/w/h），Show 后建再挂输入钩子 + Sync 兜底。
    gScroll := FlatScroll(gGui, gList, LIST_X + 1, LIST_Y + HEAD_H + 1, LIST_W - 2, LIST_H - 1)
    HookBarInput()
    SetTimer(gScroll.fnSync, 60)
    RefreshItems()
}

; ── 无 GUI 分支 ─────────────────────────────────────────────────────────
if (A_Args.Length && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\右键菜单整理\selftest-result.txt")

; --probe <verb|com|roots> ...：实机回归驱动同一套写函数，验证注册表效果。
;   verb:  --probe verb  <根suffix> <verb名> <hide|show|top|bottom|default>
;   com:   --probe com   <CLSID>    <hide|show>
;   roots: --probe roots <场景key> <结果文件> [拖入路径] → 该场景展开的位置根（逗号分隔）
if (A_Args.Length >= 3 && A_Args[1] = "--probe") {
    if (A_Args[2] = "roots" && A_Args.Length >= 4)
        ProbeRoots(A_Args[3], A_Args.Length >= 5 ? A_Args[5] : "", A_Args[4])
    else if (A_Args.Length >= 4 && A_Args[2] = "verb" && A_Args.Length >= 5)
        ProbeVerb(A_Args[3], A_Args[4], A_Args[5])
    else if (A_Args.Length >= 4 && A_Args[2] = "com")
        ProbeCom(A_Args[3], A_Args[4])
    else
        throw ValueError("probe 参数不对")
    ExitApp(0)
}

ProbeVerb(root, verb, action) {
    errs := WriteVerbMarks([root], verb, action = "hide" ? "hide" : action = "show" ? "show"
        : action = "default" ? "default" : "pos", action = "top" || action = "bottom" ? action : "")
    NotifyAssocChanged()
    if errs
        ExitApp(1)
}

ProbeCom(guid, action) {
    switch action {
        case "hide": RegWrite "", "REG_SZ", "HKCU\" BLOCK_PATH, guid
        case "show": try RegDelete "HKCU\" BLOCK_PATH, guid
        default: throw ValueError("未知 probe 动作: " action)
    }
    NotifyAssocChanged()
}

ProbeRoots(sceneKey, dropPath, outPath) {
    roots := SceneRoots(sceneKey, dropPath)
    s := ""
    for r in roots
        s .= (A_Index = 1 ? "" : ",") r
    ; 测试传来的路径可能是正斜杠（MCP 参数习惯），两个分隔符都找。
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete(outPath)
    FileAppend(s, outPath, "UTF-8")
}

RunSelfTest(path) {
    out := "", fails := 0
    Chk(cond, name, &out, &fails) {
        out .= (cond ? "PASS " : "FAIL ") name "`n"
        if !cond
            fails++
    }
    defs := SceneDefs()
    Chk(defs.Length = 3 && defs[1].key = "obj" && defs[2].key = "deskbg" && defs[3].key = "dirbg"
        , "三场景：拖入/桌面空白/文件夹空白", &out, &fails)
    r1 := SceneRoots("deskbg"), r2 := SceneRoots("dirbg")
    Chk(r1.Length = 2 && r1[1] = "Directory\Background" && r1[2] = "DesktopBackground"
        && r2.Length = 1 && r2[1] = "Directory\Background"
        , "桌面空白=背景+个性化、文件夹空白=背景", &out, &fails)
    rf := ObjRoots(false, ".md", "txtfile"), rd := ObjRoots(true)
    Chk(rf[1] = "*" && rf[2] = "AllFilesystemObjects" && rf[3] = "SystemFileAssociations\.md"
        && rf[4] = "txtfile", "文件对象展开四类来源", &out, &fails)
    Chk(rd[1] = "Directory" && rd[2] = "Folder" && rd[3] = "AllFilesystemObjects"
        && rd.Length = 3, "文件夹对象展开三类来源", &out, &fails)
    Chk(MergeState(Map("show", 1, "hidden", 1)) = "hidden"
        && MergeState(Map("show", 1, "syshidden", 1)) = "syshidden", "多来源状态合并", &out, &fails)
    Chk(MergePos(Map("default", 1, "bottom", 1, "top", 1)) = "top", "多来源位置合并", &out, &fails)
    m1 := Map("ProgrammaticAccessOnly", ""), m2 := Map("HideBasedOnVelocityId", VEL_HIDE_VALUE)
    m3 := Map("LegacyDisable", ""), m4 := Map("CommandFlags", 8), m5 := Map("CommandFlags", 7)
    Chk(HiddenByMarks(m1) && HiddenByMarks(m2) && HiddenByMarks(m3) && HiddenByMarks(m4), "四种隐藏标记都认", &out, &fails)
    Chk(!HiddenByMarks(m5) && !HiddenByMarks(Map()), "CommandFlags 低4位<8 算显示", &out, &fails)
    Chk(NormalizePos("top") = "top" && NormalizePos("Top") = "top" && NormalizePos("BOTTOM") = "bottom"
        && NormalizePos("Left") = "default", "位置归一不区分大小写", &out, &fails)
    Chk(BuiltinFallback("open") = "打开" && BuiltinFallback("runas") = "以管理员身份运行"
        && BuiltinFallback("zzz") = "zzz", "内建 verb 名兜底", &out, &fails)
    Chk(FriendlyClsids()["{7BA4C740-9E81-11CF-99D3-00AA004AE837}"] = "发送到"
        && FriendlyClsids()["{D969A300-E7FF-11d0-A93B-00A0C90F2719}"] = "新建", "COM 友好名映射", &out, &fails)
    Chk(IsIndirectString("@shell32.dll,-8506") && !IsIndirectString("在此处打开"), "间接串识别", &out, &fails)
    Chk(IsProtectedVerb("open") && IsProtectedVerb("edit") && !IsProtectedVerb("cmd"), "保护 open/edit 动词", &out, &fails)
    Chk(ShadowKey("*", "cmd") = "HKCU\Software\Classes\*\shell\cmd", "verb 影子键只落在 HKCU", &out, &fails)
    Chk(IsSharedClsid("{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}") && !IsSharedClsid("{23170F69-40C1-278A-1000-000100020000}")
        , "系统共享 CLSID 识别、7-Zip 不误判", &out, &fails)
    Chk(ComLabel("7-Zip", "7-Zip Shell Extension") = "7-Zip"
        && ComLabel("{guid}", "ShellContextMenu Class") = "{guid}", "COM 泛显示名回退注册名", &out, &fails)
    out .= "fails=" fails "`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

BuildGui()
