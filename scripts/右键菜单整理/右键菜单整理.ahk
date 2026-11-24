; ==UserScript==
; @name         右键菜单整理
; @id           context-menu-tidy
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.8.1
; @description  拖入文件/文件夹读出它的右键菜单，或看桌面空白/文件夹空白的菜单，逐项隐藏、逐位调顺序、新增自定义命令项，只写 HKCU 随时可恢复
; @author       邱宗满
; @date         2026-11-25
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
;   · 宿主 MCP 的 send_input 命中不到被装饰色块包住的 ListView（K19）：写操作走 --probe 分支测；
;     GUI 点击验证只能靠真实鼠标（SetCursorPos + mouse_event），合成点击会被装饰块吃掉。
;   · 1.4.0 顺序真相（实测）：shell 按 **verb 键名的字母序** 排静态项，与 MUIVerb 显示名无关
;     （写 0000zzA/0001zzB/0002zzC 显示名 AAA/ZZZ/MMM，菜单实际 AAA→ZZZ→MMM）；Position 只有
;     top/bottom 两档、没有「第 N 位」。所以「逐位上移/下移」只能靠接管：把该根下静态 verb 复制成
;     HKCU 下的 p0001#<verb> 副本（p > o，排在 open 之后），原件写 ProgrammaticAccessOnly 让位，
;     改编号即改真实顺序。删副本 + 清标记即完全恢复。
;   · RegDeleteTreeW/RegDeleteKeyW 的路径**不能带 HKCU\ 前缀**（传了返回 2）；AHK 的 RegDelete
;     删不掉带值或带子键的键，删旧副本必须走这两个 Win32。
;   · 拖入区与导航都是 Text 色块（+0x200 让文字垂直居中，Click 本身与样式位无关）。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; 警告默认弹框（WarningMode=MsgBox）：脱离宿主运行时会把整台机器卡住，且文字留不下来。
; 改 StdOut 后走 stderr／宿主控制台，永不弹窗；宿主内本来就是写日志，不受影响（开发指南 §4.2）。
#Warn All, StdOut

; GUI 事件层（按钮 Click 等）抛的异常默认被静默吞掉，表现成「点了按钮没反应」。
; 统一落到脚本目录的 error.log，排查时不用再靠猜。
OnError(LogRuntimeError)
LogRuntimeError(err, mode) {
    dir := A_ScriptDir "\右键菜单整理"
    ; 脚本放在只读目录（Program Files / 只读 U 盘）时这里会失败，
    ; 原来整块被 try 吞掉 → 连日志都没有，表现成「点了没反应」。退回 %TEMP%。
    if !DirExist(dir)
        try DirCreate dir
    if !DirExist(dir)
        dir := A_Temp
    try {
        FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " err.Message "`n"
            . err.File ":" err.Line " in " err.What "`n" err.Stack "`n`n", dir "\error.log", "UTF-8"
    }
    return 1        ; 已处理，不再弹默认的错误对话框
}

; 1.8.0：本脚本是纯 GUI 工具，没有托盘菜单。宿主 m132 把脚本自己的 A_TrayMenu 快照
; 挂到列表齿轮上；不清空就会把 AHK 默认的 Open/Reload/Edit/Exit/Suspend/Help 全弹出来。
; 空菜单是宿主明确支持的合法状态（DeckEngine.cpp:1585）——齿轮变灰、点击只前置窗口。
A_TrayMenu.Delete()

; ── 常量 ────────────────────────────────────────────────────────────────
HKEY_CLASSES_ROOT  := 0x80000000
HKEY_CURRENT_USER  := 0x80000001
HKEY_LOCAL_MACHINE := 0x80000002
KEY_READ_64        := 0x20019 | 0x100
REG_DWORD          := 4
REG_SZ             := 1
MISSING            := "__ahkdeck_context_tidy_missing__"
HIDE_MARK          := "ProgrammaticAccessOnly"
SENDTO_CLSID       := "{7ba4c740-9e81-11cf-99d3-00aa004ae837}"
NEW_MENU_CLSID     := "{d969a300-e7ff-11d0-a93b-00a0c90f2719}"
LIBRARY_CLSID      := "{3dad6c5d-2167-4cae-9914-f99e41c12cfa}"
VEL_HIDE_VALUE     := 6527944           ; 0x639bc8
BLOCK_PATH         := "Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"

; 客户区 820×450；左侧三入口 + 拖入区，右侧五列（1.5.0 删掉「位置」，1.7.0 加「可改」——
; 用户问「哪些能隐藏能移动」，看表比点一次被拒一次快）。
WIN_W := 820, WIN_H := 450
NAV_X := 16, NAV_W := 140, NAV_ITEM_H := 28, NAV_GAP := 4
LIST_X := 172, LIST_Y := 16, LIST_W := 632, HEAD_H := 28, LIST_H := 334
; 五列宽之和 = 46+262+84+88+140 = 620 = 自绘滚动条占位后的列表内宽（630-10），
; 少 1px 都会冒出原生横条（K30）。
COL_ORD_W := 46, COL_NAME_W := 262, COL_SRC_W := 84, COL_CAP_W := 88, COL_STATE_W := 140
; 垂直节奏（§10）：列表底 378 → BLOCK_GAP 6 → 按钮 384..414 → BLOCK_GAP 6 → 状态条 420..450 贴底。
BTN_Y := 384, BTN_H := 30
BTN_W := 72, BTN_GAP := 8
STATUS_Y := 420, STATUS_H := 30
DROP_Y := 128, DROP_H := 116

; 顺序接管：把某根下的静态 verb 全部复制成 HKCU 下带 p0001# 前缀的副本，
; 原件写隐藏标记让位。shell 按 verb 键名字母序排菜单项
; （1.4.0 实测：显示名 AAA/ZZZ/MMM 跟着键名 0000/0001/0002 走，与显示名无关），
; 所以改副本名前缀就能把菜单项摆到任意位置——这是 shell 里唯一能做到「逐位」的办法
; （Position 只有 top/bottom 两档，没有第 N 位）。
; 前缀用字母 p：'p' > 'o'，副本因此永远排在 open 之后；数字段保证组内次序。
REPLICA_MARK := "p"
; 1.8.0 新增项：键名前缀，既是唯一性来源也是「这是本脚本加的」标记（删得掉）。
CUSTOM_PREFIX := "ahkdeckadd_"
; 接管时给「原件」额外写一个自己的标记值：原件的 ProgrammaticAccessOnly 是我们写的、
; 不代表用户想隐藏，靠这个值把两者区分开（否则重跑一次接管，用户意图会被当成隐藏）。
TAKE_MARK := "_AhkDeckTakenOver"

; 三种场景（交互形态）。位置根由 SceneRoots() 按对象类型展开。
SceneDefs() => [
    { key: "obj",    name: "拖入文件(夹)" },
    { key: "deskbg", name: "桌面空白处" },
    { key: "dirbg",  name: "文件夹空白处" }
]

; 系统共享 CLSID：零提权也不能 Block，会连带系统菜单功能。
; （显示名不走这张表——显示一律先查 FriendlyClsids。）
SharedClsids() {
    static m := 0
    if IsObject(m)
        return m
    return m := Map(
    "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}", "授予访问权限",
    "{7ad84985-87b4-4a16-be58-8b72a5b390f7}", "投射到设备",
    "{596ab062-b4d2-4215-9f74-e9109b0a8153}", "还原以前的版本",
    "{bfe0e2a4-c70c-4ad7-ac3d-10d1ecebb5b4}", "照片编辑",
    "{e2bf9676-5f8f-435c-97eb-11607a5bedf7}", "共享",
    "{3dad6c5d-2167-4cae-9914-f99e41c12cfa}", "包含到库中",
    "{00021401-0000-0000-c000-000000000046}", "快捷方式打开"
    )
}

; COM 扩展友好名：CLSID 键默认值全是英文泛名（"Microsoft SendTo Service"），
; 用户在真实菜单里看到的是这些中文名（注册表探针逐一核对，见 HISTORY 1.2.1）。
FriendlyClsids() {
    static m := 0
    if IsObject(m)
        return m
    return m := Map(
    "{7ba4c740-9e81-11cf-99d3-00aa004ae837}", "发送到",
    "{f3d06e7c-1e45-4a26-847e-f9fcdee59be0}", "复制文件地址",
    "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}", "授予访问权限",
    "{596ab062-b4d2-4215-9f74-e9109b0a8153}", "还原以前的版本",
    "{3dad6c5d-2167-4cae-9914-f99e41c12cfa}", "包含到库中",
    "{470c0ebd-5d73-4d58-9ced-e91e22e23282}", "固定到“开始”屏幕",
    "{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}", "固定到“开始”屏幕",
    "{90aa3a4e-1cba-4233-b8bb-535773d48449}", "固定到任务栏",
    "{d969a300-e7ff-11d0-a93b-00a0c90f2719}", "新建",
    "{09799afb-ad67-11d1-abcd-00c04fc30936}", "打开方式",
    "{a470f8cf-a1e8-4f65-8335-227475aa5c46}", "加密",
    "{e61bf828-5e63-4287-bef1-60b1a4fde0e3}", "工作文件夹",
    "{bfe0e2a4-c70c-4ad7-ac3d-10d1ecebb5b4}", "使用照片编辑",
    "{7ad84985-87b4-4a16-be58-8b72a5b390f7}", "投射到设备",
    "{e2bf9676-5f8f-435c-97eb-11607a5bedf7}", "共享",
    "{3d1975af-48c6-4f8e-a182-be0e08fa86a9}", "NVIDIA 控制面板",
    "{1762508c-62c7-4eb9-aa6c-268421c050fa}", "上传至ima知识库",
    "{474c98ee-cf3d-41f5-80e3-4aab0ab04301}", "脱机文件",
    "{f2e8b4a1-9c7d-4f6e-b3a5-8d2c1f4e9b7a}", "NVIDIA App"
    )
}

; 静态 verb 的 shell 内建名：键值全空的 verb（open 等）真实菜单显示这些词，
; 注册表里查不到，只能内建映射兜底。
BuiltinVerbNames() {
    static m := 0
    if IsObject(m)
        return m
    return m := Map(
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
}
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
    if (vals.Has("CommandFlags") && IsNumber(vals["CommandFlags"])
            && Mod(vals["CommandFlags"], 16) >= 8)
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

; 间接字符串（"@shell32.dll,-8506"）解析成当前语言的文字；解析不了回空串。
IndirectText(raw) {
    if (raw = "" || raw = MISSING)
        return ""
    if !IsIndirectString(raw)
        return raw
    out := Buffer(1024, 0)
    if DllCall("shlwapi\SHLoadIndirectString", "Str", raw, "Ptr", out,
            "UInt", 512, "Ptr", 0, "Int") = 0
        return StrGet(out, "UTF-16")
    return ""
}

; 「打开」系内建动词：真实右键菜单把它们固定摆在前几行（打开 / 在新窗口中打开 / 固定到快速访问）。
IsShellBuiltinVerb(v) => (v = "open" || v = "opennewwindow" || v = "opennewtab"
    || v = "opennewprocess" || v = "explore" || v = "pintohome")
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
        return StripAccel(clsidDefault)
    return StripAccel(handlerName != "" ? handlerName : "(未命名扩展)")
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
        ; 按 NUL 结尾读：sz 是字节数、含结尾 NUL，按 sz//2 读会把那颗 NUL 当成字符
        ; 塞进字符串（"空值"变成 1 个字符而不是 0 个，Trim 之后仍非空，接管闸门会误判）。
        return StrGet(buf, "UTF-16")
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
}

; 键存不存在（ShellNew 这类「有子键但没默认值」的判据）。
KeyExists(root, path) {
    h := 0
    if DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0,
            "UInt", KEY_READ_64, "Ptr*", &h, "Int") != 0
        return false
    DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
    return true
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

; 读某键的全部值（名字 → {type, data}）：递归复制副本键要用。
; 只处理字符串与 DWORD；REG_BINARY（少见）跳过，避免把二进制串当文本写坏。
RegEnumValues(root, path) {
    vals := Map()
    h := 0
    r0 := DllCall("advapi32\RegOpenKeyExW", "Ptr", root, "Str", path, "UInt", 0
        , "UInt", KEY_READ_64, "Ptr*", &h, "Int")
    if (r0 != 0)
        return vals
    i := 0
    try {
        Loop {
            nbuf := Buffer(1024, 0), nlen := 512, typ := 0, sz := 0
            r := DllCall("advapi32\RegEnumValueW", "Ptr", h, "UInt", i, "Ptr", nbuf, "UInt*", &nlen
                , "Ptr", 0, "Ptr*", &typ, "Ptr", 0, "Ptr*", &sz, "Int")
            ; 234 = ERROR_MORE_DATA：lpData 传空探大小时可能回这个码，属正常。
            if (r != 0 && r != 234)
                break
            name := StrGet(nbuf, nlen, "UTF-16")
            if (sz = 0) {
                vals[name] := { type: "REG_SZ", data: "" }
            } else {
                buf := Buffer(sz + 8, 0)
                nlen2 := 512
                r2 := DllCall("advapi32\RegEnumValueW", "Ptr", h, "UInt", i, "Ptr", nbuf, "UInt*", &nlen2
                    , "Ptr", 0, "Ptr*", &typ, "Ptr", buf, "Ptr*", &sz, "Int")
                if (r2 = 0) {
                    if (typ = REG_DWORD)
                        vals[name] := { type: "REG_DWORD", data: NumGet(buf, 0, "UInt") }
                    else if (typ = 1 || typ = 2)
                        vals[name] := { type: typ = 2 ? "REG_EXPAND_SZ" : "REG_SZ"
                                      , data: StrGet(buf, "UTF-16") }
                }
            }
            i++
        }
    } finally
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
    return vals
}

; 把一个键整棵树复制到 HKCU\dstPath（值 + 子键，深度通常只有 command 一层）。
; skip 是要丢掉的值名（",Position," 这种逗号包裹的形式）。
CopyKeyTree(root, srcPath, dstPath, skip := "") {
    ; 先把目标键建出来：像 UWTSettings 这种级联项没有任何值、只有 shell 子键，
    ; 光靠 RegWrite 写值不会创建键，校验时就当成复制失败（1.4.0 实测踩过）。
    EnsureKey(dstPath)
    for name, v in RegEnumValues(root, srcPath) {
        if (skip != "" && InStr(skip, "," name ","))
            continue
        try {
            if (name = "")
                RegWrite v.data, v.type, "HKCU\" dstPath
            else
                RegWrite v.data, v.type, "HKCU\" dstPath, name
        }
    }
    for sub in EnumSubkeys(root, srcPath)
        CopyKeyTree(root, srcPath "\" sub, dstPath "\" sub)
}

; 建空键（含中间层）。RegWrite 只能连带建出「值所在的键」，空键得显式建。
EnsureKey(path) {
    h := 0
    if DllCall("advapi32\RegCreateKeyExW", "Ptr", HKEY_CURRENT_USER, "Str", path, "UInt", 0, "Ptr", 0
            , "UInt", 0, "UInt", 0x20006, "Ptr", 0, "Ptr*", &h, "Ptr", 0, "Int") = 0
        DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
}

; 递归删键：AHK 的 RegDelete 删不掉「还带值或子键」的键（1.4.0 实测删完旧副本仍残留，
; 新一轮按同号又建一份，菜单里出现重复项），逐值删又卡在默认值上。直接调 Win32：
; RegDeleteTreeW 清空内容、RegDeleteKeyW 删键本身。
RegDelTree(path) {
    h := 0
    r0 := DllCall("advapi32\RegOpenKeyExW", "Ptr", HKEY_CURRENT_USER, "Str", path, "UInt", 0
            , "UInt", 0xF003F, "Ptr*", &h, "Int")
    if (r0 != 0)        ; 键本来就不存在，没什么可删
        return
    DllCall("advapi32\RegDeleteTreeW", "Ptr", h, "Ptr", 0, "Int")
    DllCall("advapi32\RegCloseKey", "Ptr", h, "Int")
    DllCall("advapi32\RegDeleteKeyW", "Ptr", HKEY_CURRENT_USER, "Str", path, "Int")
}

; 副本名 #0001#cmd → 原 verb = 第二个 # 之后的部分。
IsReplicaName(name) => RegExMatch(name, "^" REPLICA_MARK "\d{4}#") = 1
ReplicaVerb(name) {
    p := InStr(name, "#")
    return p > 0 ? SubStr(name, p + 1) : ""
}
ReplicaName(rank, verb) => REPLICA_MARK Format("{:04}", rank) "#" verb
ReplicaRank(name) {
    if !IsReplicaName(name)
        return 0
    return Integer(SubStr(name, 2, 4))
}

; 某根下已建的副本：原 verb → 副本键名。
ReplicaMap(root) {
    m := Map()
    for name in EnumSubkeys(HKEY_CURRENT_USER, "Software\Classes\" root "\shell") {
        if !IsReplicaName(name)
            continue
        v := ReplicaVerb(name)
        if (v != "")
            m[v] := name
    }
    return m
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
        ; 默认值不存在时必须回 MISSING：若把默认值写成 verb，下面永远拿到 "open"，
        ; 内建名兜底就永远走不到（1.3.0 实测）。
        raw := RegGet(root, base, "", MISSING)
    if (raw = MISSING || raw = "")
        return BuiltinFallback(verb)
    if IsIndirectString(raw) {
        out := Buffer(1024, 0)
        if DllCall("shlwapi\SHLoadIndirectString", "Str", raw, "Ptr", out,
                "UInt", 512, "Ptr", 0, "Int") = 0 {
            s := StrGet(out, "UTF-16")
            if (s != "")
                return StripAccel(s)   ; 1.8.0：@shell32.dll 串里带 (&V)/(&S)，真菜单不显示
        }
        return BuiltinFallback(verb)
    }
    return StripAccel(BuiltinFallback(raw))
}

; COM 项：读 handler 默认值拿 CLSID，再读 CLSID 键默认值当显示名候选。
ComItem(root, base, name) {
    dv := RegGet(root, base "\" name, "", MISSING)
    guid := name
    if (dv != MISSING && SubStr(dv, 1, 1) = "{")
        guid := dv
    ; ★ CLSID 一律小写归一：AHK 的 Map 字符串键默认区分大小写，而同一个 CLSID 在不同
    ;   软件写入注册表时大小写可能不同。不归一就会连环出错——共享 CLSID 的拒写保护失效
    ;   （用户能把「共享/投射/还原以前的版本」禁掉）、友好名退回英文泛名、
    ;   同一个扩展被当成两项重复列出。注册表本身不区分大小写，写 Blocked 不受影响。
    guid := StrLower(guid)
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

; ── 真实菜单校验（1.5.0）───────────────────────────────────────────────
; 注册表里有 ≠ 菜单里显示。COM 扩展的 DLL 可以在 QueryContextMenu 里当场决定这次不出项，
; 本机实测这几个都属于此列：Safe360Ext（360）、加密（EFS，非 NTFS/非加密卷不出）、
; Offline Files、工作文件夹、ModernSharing。光看注册表永远判不出来。
; 所以直接问 shell 要一次真实菜单，拿它渲染出的文字集合当白名单；对不上的一律标「菜单外」，
; 默认被「隐藏不可见项」过滤掉，取消勾选仍能看到（不会悄悄消失）。
GUIDBuf(s) {
    b := Buffer(16, 0)
    s := RegExReplace(s, "[{}\-]")
    NumPut("UInt", Integer("0x" SubStr(s, 1, 8)), b, 0)
    NumPut("UShort", Integer("0x" SubStr(s, 9, 4)), b, 4)
    NumPut("UShort", Integer("0x" SubStr(s, 13, 4)), b, 6)
    loop 8
        NumPut("UChar", Integer("0x" SubStr(s, 17 + (A_Index - 1) * 2, 2)), b, 8 + A_Index - 1)
    return b
}

; 拿某个文件/文件夹对象的真实上下文菜单文字；拿不到返回 0（调用方据此不做过滤）。
; 1.6.2：改用 ContextMenuFor 取 IContextMenu，COM 引用与 PIDL 由它统一释放。
RealMenuWords(path) {
    pcm := ContextMenuFor(path, false)
    if !pcm
        return 0
    hmenu := DllCall("user32\CreatePopupMenu", "Ptr")
    words := Map()
    try {
        ; CMF_CANRENAME：不传这个标志，shell 不会把「重命名」放进菜单。探针实测。
        ComCall(3, pcm, "Ptr", hmenu, "UInt", 0, "UInt", 1, "UInt", 0x7FFF, "UInt", 0x10, "Int")
        CollectMenuWords(hmenu, words)
    } finally {
        DllCall("user32\DestroyMenu", "Ptr", hmenu)
        ObjRelease(pcm)
    }
    return words.Count ? words : 0
}

CollectMenuWords(h, words) {
    static MII_SIZE := A_PtrSize = 8 ? 80 : 48
    static OFF_TYPEDATA := A_PtrSize = 8 ? 56 : 36
    static OFF_CCH := A_PtrSize = 8 ? 64 : 40
    cnt := DllCall("user32\GetMenuItemCount", "Ptr", h, "Int")
    if (cnt <= 0)
        return
    mii := Buffer(MII_SIZE, 0), buf := Buffer(1024, 0)
    loop cnt {
        i := A_Index - 1
        NumPut("UInt", MII_SIZE, mii, 0)
        NumPut("UInt", 0x100 | 0x4 | 0x40, mii, 4)     ; MIIM_FTYPE|SUBMENU|STRING
        NumPut("Ptr", buf.Ptr, mii, OFF_TYPEDATA)
        NumPut("UInt", 512, mii, OFF_CCH)
        if DllCall("user32\GetMenuItemInfoW", "Ptr", h, "UInt", i, "Int", 1, "Ptr", mii, "Int") {
            w := NormMenuWord(StrGet(buf, "UTF-16"))
            if (w != "")
                words[w] := true
        }
    }
}

; 归一化到「可比对的最小形式」：去尾部加速键 (&X)、去全部 &、去空白、转小写。
NormMenuWord(s) {
    s := RegExReplace(s, "\s*\(&?[A-Za-z0-9]\)\s*$", "")
    s := RegExReplace(s, "&", "")
    s := RegExReplace(s, "\s+", "")
    return StrLower(Trim(s))
}

; 宽松比对：双向子串。友好名「固定到“开始”屏幕」要能对上 shell 的「固定到“开始”」。
RealMenuHas(words, label) {
    n := NormMenuWord(label)
    if (n = "")
        return false
    for w in words {
        if (w = n || InStr(w, n) || InStr(n, w))
            return true
    }
    return false
}

; ── 真实菜单树（1.6.0）─────────────────────────────────────────────────
; 1.5.0 只拿真实菜单判「在不在」，顺序靠猜桶，于是 7-Zip / 上传至ima 排错位置、
; 二级内容也只有硬编码的三类。1.6.0 改成把整棵菜单树读下来当准绳。
; 三条本机实测事实（Win11 26200）：
;   ① QueryContextMenu 之后每一项的 verb 可由 IContextMenu::GetCommandString(GCS_VERBW) 拿到
;      （open / pintohome / TakeOwnerShip / ZCode.OpenInZCode / SevenZip 全部命中），
;      注册表项与菜单项因此有了确定的一一对应，位次不必再猜；
;   ② 7-Zip（7 项，含 CRC SHA 再下一层 14 项）、包含到库中（7 项）的子菜单在
;      QueryContextMenu 时就建好了，直接递归读；
;   ③ 授予访问权限 / 发送到 是延迟填充的：自己发一条 WM_INITMENUPOPUP 并转给
;      IContextMenu2::HandleMenuMsg 就能补出来（实测「授予访问权限」由 1 个空项
;      变成「删除访问 / 特定用户...」）。所以二级菜单不再需要按 CLSID 白名单猜。
gMenuPcm2 := 0, gMenuHostHwnd := 0, gMenuHostGui := 0

; WM_INITMENUPOPUP 必须有窗口接收，否则消息无处可发。
; 有主窗口就直接借用——另建一个隐藏窗会被 UI 检查当成新窗口，主窗状态条就读不到了。
MenuHostHwnd() {
    global gMenuHostHwnd, gMenuHostGui, gGui
    static hooked := false
    if !hooked {
        OnMessage(0x0117, OnMenuInitPopup)
        hooked := true
    }
    if (IsObject(gGui) && gGui.Hwnd)
        return gGui.Hwnd
    if (gMenuHostHwnd && DllCall("user32\IsWindow", "Ptr", gMenuHostHwnd, "Int"))
        return gMenuHostHwnd
    g := Gui("+ToolWindow -Caption -DPIScale", "ahkdeck-menu-host")
    g.Show("x-32000 y-32000 w1 h1 NoActivate")
    ; 必须留引用：Gui 对象被回收时窗口跟着销毁，正好在递归读菜单的过程中失效，
    ; WM_INITMENUPOPUP 打空号 → 延迟填充（发送到 / 授予访问权限）静默失败。
    gMenuHostGui := g
    gMenuHostHwnd := g.Hwnd
    OnMessage(0x0117, OnMenuInitPopup)
    return gMenuHostHwnd
}

OnMenuInitPopup(wParam, lParam, msg, hwnd) {
    global gMenuPcm2
    if (gMenuPcm2)
        ComCall(6, gMenuPcm2, "UInt", msg, "Ptr", wParam, "Ptr", lParam, "Int")
    return 0
}

; 菜单项 id → verb。idCmd 相对 idCmdFirst(=1)，所以要减一。
CmdVerb(pcm, id) {
    if (!pcm || !id)
        return ""
    buf := Buffer(1024, 0)
    if (ComCall(5, pcm, "Ptr", id - 1, "UInt", 0x4, "Ptr", 0, "Ptr", buf.Ptr, "UInt", 512, "Int") = 0)
        return StrGet(buf, "UTF-16")
    return ""
}

ReadMenuLevel(h, hwndOwner, pcm, depth) {
    ; MENUITEMINFO 的布局按指针宽度分两套：x64 里 wID 之后有 4 字节填充、hSubMenu 落在 24，
    ; 结构体末尾还有 hbmpItem（所以 sizeof=80）；x86 没有填充，sizeof=48。
    ; 1.6.1 之前的 x86 偏移是错的（44/4/12/16），32 位宿主下 id/子菜单/分隔线全会读错。
    static MII_SIZE := A_PtrSize = 8 ? 80 : 48
    static OFF_TYPE := 8
    static OFF_ID := 16
    static OFF_SUB := A_PtrSize = 8 ? 24 : 20
    static OFF_TYPEDATA := A_PtrSize = 8 ? 56 : 36
    static OFF_CCH := A_PtrSize = 8 ? 64 : 40
    rows := []
    cnt := DllCall("user32\GetMenuItemCount", "Ptr", h, "Int")
    if (cnt <= 0)
        return rows
    mii := Buffer(MII_SIZE, 0), buf := Buffer(2048, 0)
    loop cnt {
        i := A_Index - 1
        NumPut("UInt", MII_SIZE, mii, 0)
        NumPut("UInt", 0x2 | 0x4 | 0x100 | 0x40, mii, 4)      ; ID|SUBMENU|FTYPE|STRING
        NumPut("Ptr", buf.Ptr, mii, OFF_TYPEDATA)
        NumPut("UInt", 1024, mii, OFF_CCH)
        if !DllCall("user32\GetMenuItemInfoW", "Ptr", h, "UInt", i, "Int", 1, "Ptr", mii, "Int")
            continue
        if (NumGet(mii, OFF_TYPE, "UInt") & 0x800) {          ; 分隔线不占位次，也不显示
            rows.Push({ sep: true, label: "", verb: "", subs: [] })
            continue
        }
        id := NumGet(mii, OFF_ID, "UInt")
        sub := NumGet(mii, OFF_SUB, "Ptr")
        subs := []
        if (sub) {
            if (hwndOwner && gMenuPcm2)
                DllCall("user32\SendMessageW", "Ptr", hwndOwner, "UInt", 0x0117
                    , "Ptr", sub, "Ptr", i, "Ptr")
            if (depth < 6)
                subs := ReadMenuLevel(sub, hwndOwner, pcm, depth + 1)
        }
        rows.Push({ sep: false, label: StripAccel(StrGet(buf, "UTF-16"))
                  , verb: CmdVerb(pcm, id), subs: subs })
    }
    return rows
}

; 读一整棵菜单树；拿不到返回 0（调用方回退到按注册表推顺序）。
RealMenuTree(pcm, flags := 0x10) {
    global gMenuPcm2
    hwnd := MenuHostHwnd()
    iid2 := GUIDBuf("{000214F4-0000-0000-C000-000000000046}")
    p2 := 0
    hr := ComCall(0, pcm, "Ptr", iid2.Ptr, "Ptr*", &p2, "Int")
    gMenuPcm2 := (hr = 0) ? p2 : 0
    hmenu := DllCall("user32\CreatePopupMenu", "Ptr")
    if !hmenu {
        gMenuPcm2 := 0
        return 0
    }
    rows := 0
    try {
        ComCall(3, pcm, "Ptr", hmenu, "UInt", 0, "UInt", 1, "UInt", 0x7FFF, "UInt", flags, "Int")
        rows := ReadMenuLevel(hmenu, hwnd, pcm, 1)
    } finally {
        DllCall("user32\DestroyMenu", "Ptr", hmenu)
        gMenuPcm2 := 0
        if p2
            ObjRelease(p2)
    }
    return (IsObject(rows) && rows.Length) ? rows : 0
}

; 取对象的 IContextMenu。background=1 时取「进入文件夹后的空白处」菜单
; （IShellFolder::CreateViewObject），否则取对象本身的菜单（GetUIObjectOf）。
ContextMenuFor(path, background := false) {
    path := StrReplace(path, "/", "\\")
    if (path = "" || !FileExist(path))
        return 0
    pDesktop := 0, pidl := 0, pParent := 0, pFolder := 0, pcm := 0
    try {
        if DllCall("shell32\SHGetDesktopFolder", "Ptr*", &pDesktop, "Int")
            return 0
        iidSF := GUIDBuf("{000214E6-0000-0000-C000-000000000046}")
        iidCM := GUIDBuf("{000214E4-0000-0000-C000-000000000046}")
        eaten := 0
        if ComCall(3, pDesktop, "Ptr", 0, "Ptr", 0, "Str", path, "UInt*", &eaten
                , "Ptr*", &pidl, "Ptr", 0, "Int")
            return 0
        pidlLast := 0
        if DllCall("shell32\SHBindToParent", "Ptr", pidl, "Ptr", iidSF.Ptr
                , "Ptr*", &pParent, "Ptr*", &pidlLast, "Int")
            return 0
        if background {
            if ComCall(5, pParent, "Ptr", pidlLast, "Ptr", 0, "Ptr", iidSF.Ptr, "Ptr*", &pFolder, "Int")
                return 0
            if ComCall(8, pFolder, "Ptr", MenuHostHwnd(), "Ptr", iidCM.Ptr, "Ptr*", &pcm, "Int")
                return 0
            return pcm
        }
        apidl := Buffer(A_PtrSize, 0)
        NumPut("Ptr", pidlLast, apidl, 0)
        if ComCall(10, pParent, "Ptr", 0, "UInt", 1, "Ptr", apidl.Ptr, "Ptr", iidCM.Ptr
                , "Ptr", 0, "Ptr*", &pcm, "Int")
            return 0
        return pcm
    } finally {
        ; 每次刷新都会走这里；以前一个都不 Release，常驻扩展 DLL 会一路涨到不卸载。
        ; pidl 是 SHParseDisplayName 用 CoTaskMemAlloc 分配的，pidlLast 指向它内部，不能单独 free。
        if pFolder
            ObjRelease(pFolder)
        if pParent
            ObjRelease(pParent)
        if pDesktop
            ObjRelease(pDesktop)
        if pidl
            DllCall("ole32\CoTaskMemFree", "Ptr", pidl)
    }
}

; 桌面空白处：桌面壳本身就是 IShellFolder，CreateViewObject 给的就是桌面背景菜单。
DesktopMenuTree() {
    iidSF := GUIDBuf("{000214E6-0000-0000-C000-000000000046}")
    iidCM := GUIDBuf("{000214E4-0000-0000-C000-000000000046}")
    pDesktop := 0, pFolder := 0, pcm := 0
    try {
        if DllCall("shell32\SHGetDesktopFolder", "Ptr*", &pDesktop, "Int")
            return 0
        if ComCall(0, pDesktop, "Ptr", iidSF.Ptr, "Ptr*", &pFolder, "Int")
            return 0
        if ComCall(8, pFolder, "Ptr", MenuHostHwnd(), "Ptr", iidCM.Ptr, "Ptr*", &pcm, "Int")
            return 0
        return pcm ? RealMenuTree(pcm) : 0
    } finally {
        if pcm
            ObjRelease(pcm)
        if pFolder
            ObjRelease(pFolder)
        if pDesktop
            ObjRelease(pDesktop)
    }
}

RealMenuTreeFor(sceneKey) {
    global gDropPath
    if (sceneKey = "obj") {
        if (gDropPath = "" || !FileExist(gDropPath))
            return 0
        pcm := ContextMenuFor(gDropPath, false)
    } else if (sceneKey = "dirbg") {
        dir := gDropPath
        ; GUI 的「文件夹空白处」没有具体目录：背景菜单的结构（查看/排序方式/刷新/
        ; 粘贴/新建/属性…）对任何文件夹都一致，用临时目录当代理把真树读出来。
        if (dir = "" || !DirExist(dir))
            dir := A_Temp
        pcm := ContextMenuFor(dir, true)
    } else
        return DesktopMenuTree()
    return pcm ? RealMenuTree(pcm) : 0
}

; 视图层内建补位（1.6.1 补「在新窗口中打开」的同类做法）：
; 「查看 / 排序方式 / 刷新 / 粘贴 / 粘贴快捷方式」由 explorer 的 shell view（DefView）
; 注入背景菜单——注册表里没有可写的键、IShellFolder 的 IContextMenu 也拿不到
; （0x0/0x4/0x14/0x24/0x2C 各 flags 实测均无），所以 COM 层永远列不出它们。
; 但它们真实存在且永远摆在经典菜单最前面，位次固定，按已知位次补回列表，
; 标「内建 / 只读」——与「在新窗口中打开」同一套纪律：找不到锚点就不补，这里
; 锚点条件是「这是背景场景」（deskbg/dirbg），补在列表最前，顺序号自然连续。
SureViewBuiltins(list, sceneKey) {
    if (sceneKey != "deskbg" && sceneKey != "dirbg")
        return list
    ; 2026-11-18 用户截图实锤的真实顺序：
    ; 桌面顶部：查看/排序方式/刷新/粘贴(灰)/撤销 删除；底部（新建之后）：显示设置/个性化。
    ; 文件夹顶部：查看/排序方式/分组依据/刷新/自定义文件夹.../粘贴/撤销 删除；底部：属性。
    top := sceneKey = "deskbg"
        ? ["查看", "排序方式", "刷新", "粘贴", "撤销 删除"]
        : ["查看", "排序方式", "分组依据", "刷新", "自定义文件夹...", "粘贴", "撤销 删除"]
    bot := sceneKey = "deskbg" ? ["显示设置", "个性化"] : ["属性"]
    mk(n) => { layer: "menu", key: "", name: "", label: n
             , state: "show", pos: "", src: "内建", roots: []
             , extended: false, rank: 0 }
    ; 代理目录的真树通常已含这些内建行（ComposeFromTree 对池外树行自动标「内建」），
    ; 补位前按显示名去重，绝不能出两份。
    have := Map()
    for it in list
        have[it.label] := true
    out := []
    for i, name in top
        if (!have.Has(name))
            out.Push(mk(name))
    for it in list
        out.Push(it)
    for i, name in bot
        if (!have.Has(name))
            out.Push(mk(name))
    return out
}

; ── 全局状态 ────────────────────────────────────────────────────────────
global gGui := 0, gList := 0, gStatus := 0, gNavBtns := []
global gItems := [], gScene := 1, gScroll := 0, gLvNcProc := 0, gLvMainHwnd := 0
; 过滤后 ListView 行号与 gItems 的下标不再一一对应，另存一份「行号 -> 项」。
global gRowMap := []
global gDropPath := ""
; 只留真实右键菜单里会出现的项（state=show 且不带 Extended）：
; 默认开——用户要"只看到现存的项"，过滤后项数与真实菜单基本对齐。
global gOnlyVisible := 1
; 表头排序状态：默认按「顺序」列升序（1=顺序 2=菜单项 3=来源 4=可改 5=状态）。
global gSortCol := 1, gSortAsc := true, gHeadBlocks := []
global gBusy := false

; ── 数据层 ──────────────────────────────────────────────────────────────
; 合并多个来源：同一 verb / CLSID 只出一行，roots 记下全部来源，隐藏时逐根写。
; 某根一旦被「顺序接管」，该项的状态与位置改从副本键读（原件已被我们隐藏）。
MakeItems(scene) {
    items := [], seenVerb := Map(), seenCom := Map(), seenComLabel := Map()
    roots := SceneRoots(scene.key, gDropPath)
    ; 只有「拖入对象」能拿到精确的真菜单（有具体路径）。桌面/文件夹空白场景没有确定对象，
    ; 拿不到就返回 0，下面的校验整体跳过——宁可多列，也不误删。
    realWords := (scene.key = "obj" && gDropPath != "") ? RealMenuWords(gDropPath) : 0
    ; 1.6.0：真实菜单树优先。拿到就照 shell 自己渲染的位次与二级内容出列表；
    ; 拿不到（没拖入对象、也没指定文件夹）才回退到下面的桶规则。
    tree := RealMenuTreeFor(scene.key)
    for root in roots {
        reps := ReplicaMap(root)
        ; L1 静态 verb
        for verb in EnumSubkeys(HKEY_CLASSES_ROOT, root "\shell") {
            if IsReplicaName(verb)
                continue                        ; 我们自己的副本，不是真实菜单项
            taken := reps.Has(verb)
            marks := taken ? VerbMarks(HKEY_CURRENT_USER, "Software\Classes\" root "\shell", reps[verb])
                           : VerbMarks(HKEY_CLASSES_ROOT, root "\shell", verb)
            effHidden := HiddenByMarks(marks)
            own := taken ? marks : VerbMarks(HKEY_CURRENT_USER, "Software\Classes\" root "\shell", verb)
            state := effHidden ? (own.Has(HIDE_MARK) ? "hidden" : "syshidden") : "show"
            pos := taken ? "default"
                          : NormalizePos(RegGet(HKEY_CLASSES_ROOT, root "\shell\" verb, "Position", ""))
            rank := taken ? ReplicaRank(reps[verb]) : 0
            if seenVerb.Has(verb) {
                it := items[seenVerb[verb]]
                it.roots.Push(root)
                it.state := MergeState(Map(it.state, 1, state, 1))
                it.pos := MergePos(Map(it.pos, 1, pos, 1))
                if (rank > 0 && (it.rank = 0 || rank < it.rank))
                    it.rank := rank
                continue
            }
            seenVerb[verb] := items.Length + 1
            ; Extended = 只在按住 Shift 时才出现，与隐藏标记一样默认不该露出来。
            ext := RegGet(HKEY_CLASSES_ROOT, root "\shell\" verb, "Extended", MISSING) != MISSING
            isCustom := (SubStr(verb, 1, StrLen(CUSTOM_PREFIX)) = CUSTOM_PREFIX)
            items.Push({ layer: "verb", key: verb, label: VerbLabel(HKEY_CLASSES_ROOT, root "\shell", verb)
                       , state: state, pos: pos, src: isCustom ? "自定义" : "静态"
                       , roots: [root], extended: ext, rank: rank, custom: isCustom })
        }
        ; L2 COM 扩展
        for name in EnumSubkeys(HKEY_CLASSES_ROOT, root "\shellex\ContextMenuHandlers") {
            ci := ComItem(HKEY_CLASSES_ROOT, root "\shellex\ContextMenuHandlers", name)
            guid := ci.guid
            if seenCom.Has(guid) {
                items[seenCom[guid]].roots.Push(root)
                continue
            }
            ; 同一功能常有两代 CLSID（PintoStartScreen / StartMenuPin 都叫「固定到“开始”屏幕」），
            ; 显示名一模一样就并成一行：keys 记住全部 CLSID，隐藏时逐个写 Blocked。
            ; ★ seenCom[guid] 必须在「确认要新起一行」之后才写：合并分支里先写会把索引
            ;   指到下一行（还没建出来），之后这个 CLSID 在别的根再出现时会把来源挂错项。
            if seenComLabel.Has(ci.label) {
                idx := seenComLabel[ci.label]
                seenCom[guid] := idx
                items[idx].keys.Push(guid)
                items[idx].roots.Push(root)
                cs := ComBlockedState(guid)
                if ((cs = "hidden" || cs = "syshidden")
                        && (items[idx].state = "show" || items[idx].state = "absent"))
                    items[idx].state := cs
                continue
            }
            seenCom[guid] := items.Length + 1
            seenComLabel[ci.label] := items.Length + 1
            cstate := ComBlockedState(guid)
            ; 注册了但这次没渲染 → 标「菜单外」。判据只认真实菜单文字，不猜。
            if (cstate = "show" && realWords && !RealMenuHas(realWords, ci.label))
                cstate := "absent"
            items.Push({ layer: "com", key: guid, name: name, label: ci.label
                       , state: cstate, pos: "", keys: [guid]
                       , src: "COM", roots: [root], shared: IsSharedClsid(guid), extended: false, rank: 0 })
        }
    }
    if tree
        return SureViewBuiltins(ComposeFromTree(tree, items), scene.key)
    ; shell 真实顺序（本机能对齐的部分）：置顶最前、置底最后，其余分两段——
    ; ①「打开」系内建动词（open / opennewwindow / opennewtab / explore / pintohome）
    ;   真实菜单永远摆在最上面；
    ; ② 其余静态与 COM 扩展按注册枚举序。
    ; COM 项的实际先后由各 DLL 的 QueryContextMenu 插入位决定，注册表无此信息，
    ; 这部分对齐不了（HISTORY 1.3.0 记录了实测结论）。
    ; 无树回退分支也补视图层内建（补项总是真实菜单最前面的那几条）。
    ranked := [], top := [], builtin := [], midV := [], midC := [], bot := []
    for it in items {
        if (it.rank > 0)
            ranked.Push(it)
        else if (it.pos = "top")
            top.Push(it)
        else if (it.pos = "bottom")
            bot.Push(it)
        else if (it.layer = "verb" && IsShellBuiltinVerb(it.key))
            builtin.Push(it)
        else if (it.layer = "verb")
            midV.Push(it)
        else
            midC.Push(it)
    }
    ; 接管过的项按副本名前缀排（shell 就是按 verb 键名字母序摆菜单的）。
    ranked := SortByKey(ranked, (it) => it.rank)
    ; 「打开」必须是第一行。
    for i, it in builtin.Clone() {
        if (it.key = "open") {
            builtin.RemoveAt(i)
            builtin.InsertAt(1, it)
            break
        }
    }
    ; 静态项整体排在 COM 扩展前面：真实菜单里也是「注册表静态项 → 各 DLL 插的扩展」，
    ; 混着排会让「新建」这类 COM 项跑到最上面（实测桌面菜单里它排在 NVIDIA 之后）。
    ; 1.5.0：可调序项（ranked = p000N# 副本）排在「不能改名的静态项」之后——
    ; shell 按键名字母序摆项，'Powershell' 这类原名一定在 'p0001#xxx' 之前，如实照搬。
    out := []
    for bucket in [top, builtin, midV, ranked, midC, bot]
        for it in bucket
            out.Push(it)
    ; 二级内容（发送到 / 新建 / 包含到库中）紧跟在父项后面缩进列出。
    ; 1.5.0 修：旧代码插入一组子项后直接 break，于是「新建」把后面所有父项的子项都吞掉了，
    ; 用户拖入文件夹时只看得到「包含到库中」一份子菜单。现在用累计偏移量逐组插入，
    ; 每个有数据源的父项都能挂上自己的子项。
    offset := 0
    for i, it in out.Clone() {
        subs := SubItemsFor(it)
        if !subs.Length
            continue
        pos := i + 1 + offset
        for s in subs {
            s.parent := it
            out.InsertAt(pos, s)
            pos++
        }
        offset += subs.Length
    }
    ; 顺序号：就是它在真实菜单里的位次（1 起）。子项不占号。
    n := 0
    for it in out {
        if (it.layer = "sub")
            it.ord := n
        else
            it.ord := ++n
    }
    return out
}

; 稳定插入排序：菜单行数只有几十，自己排比 Array.Sort 少踩「比较函数返回值约定」的坑。
; 比较一律走 StrCompare —— AHK 的 > 只认数字，传字符串会抛 "Expected a Number"。
SortByKey(arr, keyFn, cmp := "Logical") {
    out := []
    for it in arr {
        k := keyFn(it)
        pos := out.Length + 1
        while (pos > 1 && StrCompare(keyFn(out[pos - 1]), k, cmp) > 0)
            pos--
        out.InsertAt(pos, it)
    }
    return out
}

; 子项（二级内容）只在父项自己可见时才有意义。父项引用在构建 view 时就挂好了
; （AppendSubRows / SubItemsFor 的调用点），这里只做一次判断，不再全表扫描。
; 1.6.1 及以前是 ParentVisible(gItems)：对每一行 sub 都重新扫一遍全表、每个 COM 项
; 还要重算一次 SubItemsFor（「新建」那条要枚举整个 HKCR），桌面场景一次刷新能把
; HKCR 扫几十遍——这是「点了像没反应」的一个真实来源。
SubVisible(it) {
    if (it.layer != "sub")
        return true
    p := it.HasOwnProp("parent") ? it.parent : 0
    return p ? VisibleItem(p) : true
}

; 二级内容的通用行：缩进四格 + 圆点，来源列写明是哪一类的子项。
SubItem(label, src) => { layer: "sub", key: "", label: "    · " label, state: "sub"
                       , pos: "", src: src, roots: [], extended: false, parent: 0 }

; ── 真实菜单树 → 列表行（1.6.0）─────────────────────────────────────────
; pool 是注册表枚举出来的「可操作清单」：谁能隐藏、谁能调序由它决定。
; 树决定这些项排在哪、有没有二级内容。两边靠 verb 对齐（拿不到 verb 再退回文字）。
ComposeFromTree(tree, pool) {
    out := [], used := Map()
    for row in tree {
        if row.sep
            continue
        it := PickPoolItem(row, pool, used)
        if !it
            it := { layer: "menu", key: "", name: "", label: row.label
                  , state: "show", pos: "", src: "内建", roots: []
                  , extended: false, rank: 0 }
        else
            it.label := row.label           ; 菜单里显示什么就写什么
        out.Push(it)
        ; 二级内容 = 真实树 ∪ 数据源，**不能只挑一边**：
        ;   · 「发送到」是延迟填充的子菜单（要自己发 WM_INITMENUPOPUP 才长出项），真实树经常
        ;     只回一两条、甚至只回一条没文字的空壳 —— 1.6.3 用户报「发送到 缺内容」就是它；
        ;   · 发送到/新建/包含到库中这三项，shell 自己也是读「SendTo 文件夹 / ShellNew 键 /
        ;     库目录」这份清单的，所以数据源就是真相：它排前面，真实树里数据源没有的补在后面。
        ; 7-Zip、授予访问权限这类由 DLL 当场生成、没有静态数据源的，SubItemsFor 返回空，
        ; 照旧只用真实树。
        block := []
        AppendSubRows(block, row.subs, 1, it)      ; 真实树：位次与顺序的真相，空标签在函数里跳过
        ; 二级内容以谁为准，按父项分两类，别一把抓：
        ;   · 「发送到 / 新建 / 包含到库中」才有静态数据源（SendTo 目录 / ShellNew 键 / 库目录），
        ;     这几项一律以数据源为准：它们的真实树是延迟填充或当场生成的，同一次刷新里
        ;     「发送到」只回了一条空壳、「新建」只回了 14 条（漏掉 RAR/文本文档/库/联系人/
        ;     压缩）——1.6.3 用户报「发送到 二级菜单缺内容」就是这么来的。
        ;     也不能按显示名去重：SendTo 里真有两个都叫「传真收件人」的项，shell 也列两条。
        ;   · 其余（7-Zip / 授予访问权限 / 上传至ima）由 DLL 当场生成，SubItemsFor 返回空，
        ;     照旧只用真实树。
        src := SubItemsFor(it)
        if (src.Length) {
            block := []
            for s in src {
                s.parent := it
                block.Push(s)
            }
        }
        for r in block
            out.Push(r)
    }
    ; 「在新窗口中打开」这一类由 explorer 自己往文件夹菜单里加，shell 的
    ; CDefaultContextMenu 会把它从 IShellFolder 的公开菜单里滤掉，所以我们读不到。
    ; 实测（--probe exmenu）它紧跟在「打开」后面、在「固定到快速访问」前面。
    ; 必须在标「菜单外」之前补：标过之后 state 已变成 absent，就补不进去了。
    SureBuiltin(out, pool, used, "opennewwindow")
    ; 注册表登记了、这次 shell 却没渲染：追加末尾并标「菜单外」，不悄悄消失。
    ; ★ 只改「显示」的项：隐藏/系统隐藏的项本来就不该出现在真菜单里，
    ;   无条件改成 absent 会让用户刚点完的「已隐藏」立刻变成「菜单外」，
    ;   状态条的「已隐藏 N」永远归零，而且按钮显示「显示」却删不掉任何标记。
    for i, it in pool {
        if used.Has(i)
            continue
        if (it.state = "show")
            it.state := "absent"
        out.Push(it)
    }
    n := 0
    for it in out {
        if (it.layer = "sub")
            it.ord := n
        else
            it.ord := ++n
    }
    return out
}

; 把「资源管理器自己加、但 IShellFolder 不渲染」的内建项放回列表：插在「打开」之后。
; 只对确实存在于注册表、且没被隐藏/没标 Extended 的项生效，否则不动。
SureBuiltin(out, pool, used, verb) {
    for i, it in pool {
        if (used.Has(i) || it.layer != "verb" || it.key != verb)
            continue
        if (it.state != "show" || it.extended)
            return false
        it.label := StripAccel(it.label)
        for k, row in out {
            if (row.layer = "verb" && row.key = "open") {
                used[i] := true
                out.InsertAt(k + 1, it)
                return true
            }
        }
        ; 没有「打开」做锚点就干脆不补：位置放错比不显示更糟。
        return false
    }
    return false
}

; parent 指回父项对象：过滤时「子项跟着自己的父项走」，而不是跟着列表里第一个有子项的项走。
AppendSubRows(out, subs, depth, parent := 0) {
    for row in subs {
        if (row.sep || Trim(row.label) = "")
            continue
        pad := ""
        loop depth
            pad .= "    "
        out.Push({ layer: "sub", key: "", label: pad "· " row.label
                 , state: "sub", pos: "", src: "二级", roots: []
                 , extended: false, rank: 0, ord: 0, parent: parent })
        if row.subs.Length
            AppendSubRows(out, row.subs, depth + 1, parent)
    }
}

; 菜单项 → 注册表项：先认 verb（一一对应），再退回文字比对。
PickPoolItem(row, pool, used) {
    if (row.verb != "") {
        for i, it in pool {
            if (used.Has(i) || it.layer != "verb")
                continue
            if (it.key = row.verb) {
                used[i] := true
                return it
            }
        }
    }
    n := NormMenuWord(row.label)
    if (n = "")
        return 0
    for i, it in pool {
        if (used.Has(i) || NormMenuWord(it.label) != n)
            continue
        used[i] := true
        return it
    }
    for i, it in pool {
        if used.Has(i)
            continue
        l := NormMenuWord(it.label)
        if (l != "" && (InStr(l, n) || InStr(n, l))) {
            used[i] := true
            return it
        }
    }
    return 0
}

; 只读展示：SendTo 文件夹里的每一项就是「发送到」子菜单的一项。
; ★ 1.7.0：**跳过 .lnk 快捷方式**。1.6.3 直接把目录全列出来，本机 8 项，可真实菜单只有
;   4 项（文档 / 压缩(zipped)文件夹 / 邮件收件人 / 桌面快捷方式），用户直接说「内容太多」。
;   本机实测（Win11 26200）：外壳的「发送到」只列注册了发送处理器的项
;   （.ZFSendToTarget / .DeskLink / .MAPIMail / .mydocs 这些），SendTo 里的 .lnk 一个都不进菜单
;   （ALTRun.lnk / Fax Recipient.lnk / 传真收件人.lnk / 蓝牙文件传送.LNK 全部不显示）。
;   试过的、走不通的路（别再重试）：
;     · WM_INITMENUPOPUP + IContextMenu2/3 HandleMenuMsg(2)：hr=0 但子菜单一直是 1 个空项；
;     · 直接 CoCreateInstance(CLSID_SendTo) + IShellExtInit::Initialize：同上，空壳；
;     · 每项 DragEnter 判「能否接收拖放」：本机 8 项全部 DROPEFFECT_NONE，分辨不出；
;     · GetUIObjectOf(IDropTarget) 是否存在：换调用路径结论就翻，不可靠。
;   所以这里按「.lnk 不进菜单」这条实测规律过滤，剩下的正好是真实菜单那 4 项。
SendToChildren() {
    dir := EnvGet("APPDATA") "\Microsoft\Windows\SendTo"
    subs := []
    if !DirExist(dir)
        return subs
    loop files, dir "\*.*" {
        name := A_LoopFileName
        if (name = "desktop.ini")
            continue
        if (A_LoopFileExt = "lnk" || A_LoopFileExt = "LNK")
            continue
        nm := ShellDisplayName(A_LoopFileFullPath)
        if (nm = "")
            nm := CleanSendToName(name)
        subs.Push(SubItem(nm, "发送到"))
    }
    ; shell 按显示名的本地化次序（中文按拼音：文档 → 压缩 → 邮件 → 桌面），
    ; 不是按键名/码位，所以要用 Locale 比较；Logical（自然序）会给出「压缩 → 桌面 → 邮件 → 文档」。
    return SortByKey(subs, (s) => s.label, "Locale")
}

; 一个 shell 项的显示名 = 真实右键菜单里那一行写的字。
; 「发送到」里的 .ZFSendToTarget / .DeskLink / .MAPIMail / .mydocs 不是普通文件：
; 文件名是英文（Compressed (zipped) Folder…），菜单显示的是本地化名（压缩(zipped)文件夹）。
; 只有 IShellItem::GetDisplayName(SIGDN_NORMALDISPLAY) 给出同一份文字——1.6.3 实测：
; ALTRun / 压缩(zipped)文件夹 / 桌面快捷方式 / 传真收件人 / 邮件收件人 / 文档 / 蓝牙设备。
; 读不到就返回空串，调用方退回按文件名截扩展名的老办法。
ShellDisplayName(path) {
    static iid := 0
    if !iid
        iid := GUIDBuf("{43826d1e-e718-42ee-bc55-a1e261c37bfe}")
    psi := 0
    if (DllCall("shell32\SHCreateItemFromParsingName", "WStr", path, "Ptr", 0
            , "Ptr", iid.Ptr, "Ptr*", &psi, "Int") != 0 || !psi)
        return ""
    try {
        pw := 0
        if (ComCall(5, psi, "UInt", 0, "Ptr*", &pw, "Int") != 0 || !pw)
            return ""
        try
            return StrGet(pw, "UTF-16")
        finally
            DllCall("ole32\CoTaskMemFree", "Ptr", pw)
    } finally
        ObjRelease(psi)
}

; 1.8.0：调研报告 §2.5 的权威判据——ShellNew 键里至少要有一个
; NullFile/Data/FileName/Directory/Command/Handler，否则 shell 不列它。
; 旧版只判「键存在」，本机凭空多出 AMOS×6 / RAR / 库 共 8 个幻影项（实测 .rar\ShellNew 空）。
ShellNewHasValue(vals) {
    for n in ["NullFile", "Data", "FileName", "Directory", "Command", "Handler"]
        if vals.Has(n)
            return true
    return false
}
ShellNewValid(key) => ShellNewHasValue(RegEnumValues(HKEY_CLASSES_ROOT, key))

; 「新建」子菜单：每个带 ShellNew 子键的扩展名就是一项。
; 显示名一律走 SHGetFileInfoW 的类型名（资源管理器「类型」列同一来源），
; 这样「文本文档 / 压缩(zipped)文件夹 / 快捷方式」都是系统自带的中文名；
; 读注册表 ProgID 默认值会踩到软件写坏的 UTF-8 字节（实测出现「鏂囨湰鏂囨。」这种）。
; 「文件夹」是 shell 内建、注册表里没有 ShellNew 键，这里补一条。
NewMenuChildren() {
    ; 「新建」子项跟系统安装的扩展名相关，进程内不变；每刷新枚举一遍整个 HKCR（上万键）
    ; 是桌面空白场景卡顿的主因（1.6.1 实测每次刷新要重复几十遍）。
    ; 只缓存名字，行对象每次重建——行对象带 ord/state，跨刷新复用会被上一层改脏。
    static nameCache := 0
    subs := [SubItem("文件夹", "新建")]
    if IsObject(nameCache) {
        for nm in nameCache
            subs.Push(SubItem(nm, "新建"))
        return subs
    }
    names := []
    for ext in EnumSubkeys(HKEY_CLASSES_ROOT, "") {
        if (SubStr(ext, 1, 1) != ".")
            continue
        ; ShellNew 有两种挂法：直接挂在扩展名下，或挂在它的 ProgID 子键下。
        ; Office 是后者（.docx\Word.Document.12\ShellNew），只查第一层会把
        ; Word / Excel / PowerPoint / Publisher 全漏掉——1.6.3 实测。
        key := ShellNewKey(ext)
        if (key = "")
            continue
        if !ShellNewValid(key)          ; 1.8.0：空 ShellNew 键是幻影项
            continue
        ; ShellNewHandler 是「从新建菜单里删掉」的反向标记，不算一项。
        if RegGet(HKEY_CLASSES_ROOT, key, "ShellNewHandler", MISSING) != MISSING
            continue
        nm := StripAccel(IndirectText(RegGet(HKEY_CLASSES_ROOT, key, "MenuText", "")))
        if (nm = "")
            nm := StripAccel(IndirectText(RegGet(HKEY_CLASSES_ROOT, key, "ItemName", "")))
        if (nm = "")
            nm := StripAccel(ExtTypeName(ext))
        if (nm = "")
            nm := SubStr(ext, 2)
        names.Push(nm)
    }
    names := SortByKey(names, (v) => v)
    nameCache := names
    for nm in names
        subs.Push(SubItem(nm, "新建"))
    return subs
}

; 去掉菜单加速键标记：「快捷方式(&S)」→「快捷方式」。
; 真菜单文字里还有「&UWTSettings」这种把 & 写在字母前的写法，shell 显示时会吞掉 &，
; 直接照抄就露出一个「&」（1.6.0 实测）。
StripAccel(s) => RegExReplace(RegExReplace(s, "\s*\(&.\)$", ""), "&", "")

; 扩展名的类型显示名：SHGetFileInfoW + SHGFI_TYPENAME + SHGFI_USEFILEATTRIBUTES，
; 不需要文件真的存在。返回空串表示系统没登记这个类型。
ExtTypeName(ext) {
    size := A_PtrSize + 8 + 520 + 160
    shfi := Buffer(size, 0)
    if !DllCall("shell32\SHGetFileInfoW", "Str", "x" ext, "UInt", 0x80
            , "Ptr", shfi, "UInt", size, "UInt", 0x410)
        return ""
    return StrGet(shfi.Ptr + A_PtrSize + 8 + 520, "UTF-16")
}

; 「包含到库中」子菜单：库目录下的 .library-ms 文件就是一项。
LibraryChildren() {
    subs := []
    dir := EnvGet("APPDATA") "\Microsoft\Windows\Libraries"
    if !DirExist(dir)
        return subs
    loop files, dir "\*.library-ms" {
        nm := A_LoopFileName
        nm := ShellDisplayName(A_LoopFileFullPath)
        if (nm = "")
            nm := SubStr(A_LoopFileName, 1, StrLen(A_LoopFileName) - StrLen(".library-ms"))
        subs.Push(SubItem(nm, "包含到库中"))
    }
    ; 真实菜单（--probe tree）实测是显示名的本地化序：Git → 保存的图片 → 本机照片 →
    ; 视频 → 图片 → 文档 → 音乐；目录枚举序是 NTFS 顺序，差得很远。
    return SortByKey(subs, (s) => s.label)
}

; 一个菜单项有没有二级内容：只认注册表/文件系统里有数据源的三种。
; 7-Zip、授予访问权限、上传至ima 这些子菜单由 DLL 当场生成，没有静态数据源，列不出来。
SubItemsFor(it) {
    if (it.layer != "com")
        return []
    ; 两代 CLSID 合并成一行时 keys 里有两个，it.key 只留第一个——按 keys 一个个试，
    ; 否则合并行的二级内容会整组丢掉。
    keys := it.HasOwnProp("keys") ? it.keys : [it.key]
    for k in keys {
        switch k {
            case SENDTO_CLSID:   return SendToChildren()
            case NEW_MENU_CLSID: return NewMenuChildren()
            case LIBRARY_CLSID:  return LibraryChildren()
        }
    }
    return []
}

; 这个扩展名的 ShellNew 在哪一层：.ext\ShellNew → 该扩展名**默认 ProgID** 的 ShellNew
; （.docx\Word.Document.12\ShellNew 或 Word.Document.12\ShellNew）。
; ★ 只认默认 ProgID：把 .ext 下每个子键都翻一遍，会把 AMOS 那类"登记过但 shell 不显示"
;   的 ProgID 也翻出来，列表里凭空多出 5 项（1.6.3 实测过）。
ShellNewKey(ext) {
    if KeyExists(HKEY_CLASSES_ROOT, ext "\ShellNew")
        return ext "\ShellNew"
    progid := RegGet(HKEY_CLASSES_ROOT, ext, "", "")
    if (progid != "") {
        for key in [ext "\" progid "\ShellNew", progid "\ShellNew"]
            if KeyExists(HKEY_CLASSES_ROOT, key)
                return key
    }
    return ""
}

; 「压缩(zipped)文件夹」这类是 .ZFSendToTarget / .DeskLink / .mydocs 之类的
; shell 特殊后缀，真实菜单只显示前缀；.lnk 也去掉扩展名。
CleanSendToName(file) {
    SplitPath(file, , , &ext)
    if (ext = "")
        return file
    return SubStr(file, 1, StrLen(file) - StrLen(ext) - 1)
}

; 这一项会不会真的出现在右键菜单里：本脚本没隐藏、系统没有隐藏标记、也不是 Extended。
; absent = 注册表里登记了、但这次 shell 根本没渲染（见 RealMenuWords 的说明）。
VisibleItem(it) {
    if (it.layer = "sub")
        return true        ; 子项是否列出由父项「发送到」的可见性决定
    return it.state = "show" && !it.extended
}

StatusRank(s) => s = "show" ? 1 : s = "hidden" ? 2 : s = "syshidden" ? 3 : s = "absent" ? 4 : 0
StatusText(s) => s = "show" ? "显示" : s = "hidden" ? "已隐藏"
    : s = "syshidden" ? "系统隐藏" : s = "absent" ? "菜单外" : ""

; 「可改」列：这一行到底能做什么。判据必须和按钮的真实守卫逐条对齐
; （ToggleSelected / MoveVerb / SetHide 里那几道闸门），否则会出现
; 「列里写着能调序、点上去却被拒绝」——那种自相矛盾比不写更糟。
;   隐藏·调序  静态 verb，且至少一个位置根下带 MUIVerb（可以安全复制成 p000N# 副本）
;   仅隐藏      静态 verb 没带 MUIVerb（改名会显示成 p0001#open），或 COM 扩展（位置由 DLL 决定）
;   只读        二级项 / 内建项（注册表无键）/ 打开·编辑动词（脚本明令不动）/ 系统共享 CLSID（禁写）
CapText(it) {
    global gScene, gDropPath
    static cache := Map()
    if (it.layer = "sub" || it.layer = "menu")
        return "只读"
    if (it.layer = "com")
        return it.shared ? "只读" : "仅隐藏"
    if (it.layer != "verb")
        return "只读"
    if IsProtectedVerb(it.key)
        return "只读"
    key := SceneDefs()[gScene].key "|" it.key
    if cache.Has(key)
        return cache[key]
    can := false
    for r in SceneRoots(SceneDefs()[gScene].key, gDropPath)
        if CanReplicate(r, it.key) {
            can := true
            break
        }
    res := can ? "隐藏·调序" : "仅隐藏"
    cache[key] := res
    return res
}
PosRank(p) => p = "top" ? 1 : p = "default" ? 2 : p = "bottom" ? 3 : 4

; 一列的排序键统一成可比较字符串：顺序号补零后按字符串比也不会错位。
SortKeyOf(it, col) {
    switch col {
        case 1: return Format("{:05}", it.ord)
        case 2: return it.label
        case 3: return it.src
        case 4: return CapText(it)
        case 5: return StatusRank(it.state) ""
    }
    return ""
}

; 组的稳定排序：二级项不单独参与比较，永远跟着父项走。
SortGroups(groups, col, asc) {
    keyed := []
    for g in groups
        keyed.Push({ g: g, k: SortKeyOf(g.it, col) })
    out := []
    for item in keyed {
        pos := out.Length + 1
        while (pos > 1) {
            cmp := StrCompare(out[pos - 1].k, item.k, "Logical")
            if (asc ? cmp <= 0 : cmp >= 0)
                break
            pos--
        }
        out.InsertAt(pos, item)
    }
    res := []
    for o in out
        res.Push(o.g)
    return res
}

; 读真实菜单时 QueryContextMenu 会泵消息，用户在这期间点按钮就可能重入刷新，
; 把 gItems / gRowMap 打断成半成品（列表空白或行号错位）。加一道守卫，重入直接忽略。
RefreshItems(keepMsg := "") {
    global gBusy
    if (gBusy)
        return
    gBusy := true
    try
        RefreshItemsCore(keepMsg)
    finally
        gBusy := false
}

RefreshItemsCore(keepMsg := "") {
    global gList, gStatus, gItems, gScene, gScroll, gDropPath, gOnlyVisible, gRowMap
    global gSortCol, gSortAsc
    scene := SceneDefs()[gScene]
    gItems := MakeItems(scene)
    gList.Delete()
    ; 重建后把视口拉回第一行：Delete/Add 之后 ListView 有时会保留旧的 top index，
    ; 表现为「顺序」列从 4 开始、前几行看不见。
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1013, "Ptr", 0, "Ptr", 0, "Ptr")
    gRowMap := []
    nShown := 0
    view := []
    for it in gItems {
        ; 子项跟随父项：父项被过滤时整组不出现。
        if (gOnlyVisible && !SubVisible(it))
            continue
        if (gOnlyVisible && !VisibleItem(it))
            continue
        view.Push(it)
    }
    ; 顺序号按「实际列出来的行」连续编：Shift 才显示的 Extended 项本来就不在菜单里，
    ; 跳过后不能留空号（否则第一行就显示 4，看着像丢了东西）。
    k := 0
    for it in view
        if (it.layer != "sub")
            it.ord := ++k
    ; 二级项并回父项成组，再整体排序——点表头排序时缩进的子项不会飞走。
    groups := []
    for it in view {
        if (it.layer = "sub" && groups.Length)
            groups[groups.Length].subs.Push(it)
        else
            groups.Push({ it: it, subs: [] })
    }
    groups := SortGroups(groups, gSortCol, gSortAsc)
    for g in groups {
        AddRow(g.it)
        for s in g.subs
            AddRow(s)
        nShown += 1 + g.subs.Length
    }
    scope := scene.key = "obj" ? ObjScopeLabel(gDropPath) : scene.name
    ; keepMsg 给写操作用：上移/下移刚刚做的事必须留在状态条上，否则一刷新就被
    ; 统计盖掉，用户点完看不到任何动静（1.5.0 就是被这个坑误导成"没反应"）。
    ; 1.8.0 打磨：状态栏只留「场景 · N 项」，verb/COM 细分、隐藏计数、可见性尾巴全删。
    if (keepMsg != "")
        gStatus.Value := keepMsg
    else
        gStatus.Value := scope " · " nShown " 项"
    ; Delete/Add 会把 WS_VSCROLL 样式位置回、原生条露出（K22/K36）：填完统一重算占位+摘条。
    if (gScroll && !gScroll.dead) {
        gScroll.Layout()
        ; 填完后强制同步重画（RDW_INVALIDATE|RDW_ALLCHILDREN|RDW_UPDATENOW）：
        ; 拖入路径 Delete/Add 之后 ListView 不重画、整块发白，滚一下滚轮才恢复（1.2.2 实测）；
        ; UPDATENOW 直接走 WM_PAINT，不等消息泵。
        DllCall("user32\RedrawWindow", "Ptr", gList.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0181)
        ; 同步重画 ListView 会盖掉自绘滑块（Z 序在 ListView 之下），补画一次。
        gScroll.Paint()
    }
    ; 列表重建后没有选中项，切换按钮回默认文案。
    SyncToggleLabel()
    SyncHeadArrows()
}

AddRow(it) {
    global gList, gRowMap
    st := it.layer = "sub" ? "" : StatusText(it.state)
    ; 「顺序」只标真菜单项：二级项没有独立位置，留空（标签自带「    · 」缩进标记，
    ; 这里再补一个点会出现「·  · 文件夹」两粒点）。
    gList.Add("", it.layer = "sub" ? "" : it.ord, it.label, it.src, CapText(it), st)
    gRowMap.Push(it)
}

; 操作对象 = 列表里的选中项（用户点一下就是它）。AHK 的 ListView.GetNext 只认
; "C"/"F" 不接受 "S"（1.3.0 踩过：第二参数非法，异常被事件层吞成"按钮没反应"），
; 所以直接用 LVM_GETNEXTITEM(-1, LVNI_SELECTED) 取选中行，焦点项只作后备。
; 两样都没有就返回 0，绝不默默拿第一行去改注册表。
SelectedItem() {
    global gList, gRowMap
    r := DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x100C
        , "Ptr", -1, "Ptr", 0x0002, "Ptr")      ; LVNI_SELECTED = 2
    if (r = -1 || r = 0xFFFFFFFF)
        r := 0
    else
        r += 1                                   ; LVM 返回 0-based
    if !r
        r := gList.GetNext(0, "F")               ; 键盘 Tab 进列表时只有焦点
    return (r && r <= gRowMap.Length) ? gRowMap[r] : 0
}

; ── 写操作 ──────────────────────────────────────────────────────────────
; 静态项对每个来源根都写影子键，否则其它位置仍会把菜单项带出来。
; 静态项对每个来源根都写影子键，否则其它位置仍会把菜单项带出来。
; 已经被「顺序接管」的根：可见性写在副本上（副本才是真实菜单项），
; 原件必须始终带着隐藏标记，否则原件和副本会各出一项。
WriteVerbMarks(roots, verb, action) {
    errs := 0
    for root in roots {
        reps := ReplicaMap(root)
        if (reps.Has(verb)) {
            key := "HKCU\Software\Classes\" root "\shell\" reps[verb]
            try {
                if (action = "hide")
                    RegWrite "", "REG_SZ", key, HIDE_MARK
                else
                    try RegDelete key, HIDE_MARK
            } catch
                errs++
            continue
        }
        key := ShadowKey(root, verb)
        try {
            if (action = "hide")
                RegWrite "", "REG_SZ", key, HIDE_MARK
            else
                try RegDelete key, HIDE_MARK
        } catch
            errs++
        ; 恢复完顺手把空壳键删掉：留着空 shell 键，shell 会多列一个没有命令的菜单项。
        ; 键里还有其它值（比如 Position）或子键时原样保留。
        if (action = "show")
            PruneKey(key)
    }
    return errs
}

; 把一个「只剩空壳」的影子键删掉：还有任何值或子键就原样保留。
; 空 shell 子键会被 shell 当成一个没有命令的菜单项，恢复隐藏之后必须真的清掉，
; 否则菜单里会多出一行空白（1.5.0 收尾时在 HKCU 里清出 6 个这种空壳）。
PruneKey(key) {
    path := StrReplace(key, "HKCU\", "")
    if RegEnumValues(HKEY_CURRENT_USER, path).Count
        return
    if EnumSubkeys(HKEY_CURRENT_USER, path).Length
        return
    try RegDelete key
}

; 一个按钮两态：选中项现在能看见就显示「隐藏」，已隐藏就显示「显示」。
ToggleSelected() {
    global gStatus
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if (it.layer = "sub") {
        gStatus.Value := "「" Trim(it.label, " ·") "」是二级项，只读展示、不可操作"
        return
    }
    SetHide(it.state = "show")
}

; 上移/下移 = 与相邻的静态项换个位次，一次只挪一位。
; ★ shell 的 Position 只有 top/bottom 两档，没有「第 N 位」；逐位唯一可行的办法是改
;   verb 键名——shell 按键名字母序摆菜单项（1.4.0 实测：显示名 AAA/ZZZ/MMM 跟着
;   键名 0000/0001/0002 走）。所以把该根下静态项整组复制成 p0001#<verb> 这样的副本，
;   原件写隐藏标记让位，改前缀号就是改真实顺序。还原 = 删副本 + 去标记。
MoveVerb(delta) {
    global gItems, gStatus, gScene, gDropPath, gRowMap
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if (it.layer = "com") {
        gStatus.Value := "「" it.label "」是 COM 扩展，菜单里的位置由它的 DLL 决定，注册表里没有可写的顺序"
        return
    }
    if (it.layer = "sub") {
        gStatus.Value := "「" Trim(it.label, " ·") "」是二级项，只读展示、不可调位置"
        return
    }
    if (it.layer = "menu") {
        gStatus.Value := "「" it.label "」是 Windows 内建菜单项，注册表里没有对应项，位置由系统决定"
        return
    }
    if IsProtectedVerb(it.key) {
        gStatus.Value := "「" it.label "」是打开/编辑动词，本脚本不动它"
        return
    }
    ; 能不能调：必须是「有显式 MUIVerb、改名后显示名不会坏」的 verb。
    ; 系统内建项（open / cmd / Powershell 这类）的显示名绑在键名上，复制成 p000N# 之后
    ; 菜单里会直接显示 "p0001#open"，所以只能原地不动（1.5.0 真机复现后加的闸门）。
    roots := SceneRoots(SceneDefs()[gScene].key, gDropPath)
    canMove := false
    for r in roots {
        if CanReplicate(r, it.key) {
            canMove := true
            break
        }
    }
    if !canMove {
        gStatus.Value := "「" it.label "」是系统内建项（显示名由 Windows 按动词名硬编码），改名会让菜单显示成乱码，只能由系统固定位置"
        return
    }
    idx := 0
    for i, x in gItems {
        ; 对象比较必须用 ObjPtr：AHK 的 = 是字符串比较，传对象会抛异常，
        ; 异常被 GUI 事件层吞掉，表现成「点了按钮没反应」（1.3.0/1.4.0 各踩一次）。
        if (ObjPtr(x) = ObjPtr(it)) {
            idx := i
            break
        }
    }
    if !idx {
        gStatus.Value := "找不到这一项，先点「刷新」"
        return
    }
    j := idx
    loop {
        j += delta
        if (j < 1 || j > gItems.Length) {
            gStatus.Value := "「" it.label "」已经是" (delta < 0 ? "第一" : "最后") "个可调的菜单项了"
            return
        }
        if (gItems[j].layer = "verb")
            break
    }
    other := gItems[j]
    if IsProtectedVerb(other.key) {
        gStatus.Value := "不能再往" (delta < 0 ? "上" : "下") "，「" other.label "」是系统固定项"
        return
    }
    gItems[idx] := other
    gItems[j] := it
    if (bad := ApplyVerbOrder(roots)) {
        gStatus.Value := "有 " bad " 处顺序写入失败（可能需管理员权限），已回滚"
        RefreshItems()
        return
    }
    NotifyAssocChanged()
    RefreshItems()
    SelectByKey(it.key)
    ; 位次在重排之后才准：按列表当前行数一遍，让用户看到「第 N 位」这个具体结果。
    rank := 0, found := 0
    for x in gRowMap {
        if (x.layer != "sub")
            rank++
        if (x.layer = "verb" && x.key = it.key) {
            found := rank
            break
        }
    }
    gStatus.Value := "「" it.label "」已" (delta < 0 ? "上移" : "下移") "一位"
        . (found ? "，现在第 " found " 位" : "") " · 关掉再打开右键菜单即可看到"
}

; 刷新后重新选中同一项并滚到可见，方便连点上下移。
SelectByKey(verb) {
    global gList, gRowMap
    for i, it in gRowMap {
        if (it.layer = "verb" && it.key = verb) {
            gList.Modify(i, "Select Focus")
            ; LVM_ENSUREVISIBLE(0x1013)：列表长过一屏时把选中行滚进来，
            ; 否则上移后选中行可能留在视口外，看着还是「没反应」。
            DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1013, "Ptr", i - 1
                , "Ptr", 1, "Ptr")
            return
        }
    }
}

; 把 gItems 里的 verb 次序写成每个根的副本序（带校验，失败不留半成品）。
ApplyVerbOrder(roots) {
    global gItems
    order := []
    for it in gItems
        if (it.layer = "verb" && !IsProtectedVerb(it.key))
            order.Push(it.key)
    bad := 0
    for root in roots {
        all := []
        for v in EnumSubkeys(HKEY_CLASSES_ROOT, root "\shell")
            if !IsReplicaName(v)
                all.Push(v)
        seq := []
        for v in all
            if IsProtectedVerb(v)
                seq.Push(v)
        for v in order
            for w in all
                if (w = v)
                    seq.Push(w)
        for v in all
            if !InList(seq, v)
                seq.Push(v)
        if !RebuildRoot(root, seq)
            bad++
    }
    return bad
}

InList(arr, v) {
    for x in arr
        if (x = v)
            return true
    return false
}

; 重建一个根的顺序：先记下旧的「用户隐藏」意图 → 删旧副本 → 按 seq 建新副本 → 回写隐藏 → 隐藏原件。
; 任一步失败就清掉已建副本并返回 false（宁可保持原状，也不留半套让菜单重复/失效）。
;
; ★ 1.5.0 修：只接管「有显式 MUIVerb/MuiVerb」的 verb。
;   实测把 open 这类内建动词复制成 p0001#open 之后，副本的显示名不是「打开」而是
;   字面的 "p0001#open"——shell 的内建显示名绑在键名上，改名即失效，菜单直接变乱码
;   （本轮真机复现：Folder 根接管后菜单第一项成了「&p0001#open」）。
;   所以没有 MUIVerb 的 verb 一律不复制、不隐藏，位置交给系统固定。
RebuildRoot(root, seq) {
    base := "Software\Classes\" root "\shell"
    ; 1) 快照：旧副本上的隐藏意图 + 原件上「我们上一轮写的」接管标记。
    ;    这份快照是回滚的唯一依据——失败时靠它把原件恢复成「该隐藏的隐藏、该显示的显示」。
    wasHidden := Map(), wasTaken := Map()
    for name in EnumSubkeys(HKEY_CURRENT_USER, base) {
        if !IsReplicaName(name)
            continue
        if RegGet(HKEY_CURRENT_USER, base "\" name, HIDE_MARK, MISSING) != MISSING
            wasHidden[ReplicaVerb(name)] := true
        wasTaken[ReplicaVerb(name)] := true
    }
    for verb in seq {
        if wasTaken.Has(verb)
            continue
        p := base "\" verb
        if RegGet(HKEY_CURRENT_USER, p, TAKE_MARK, MISSING) != MISSING {
            ; 原件上已经有我们的接管标记 → 那儿的 ProgrammaticAccessOnly 是我们写的，不是用户意图。
            wasTaken[verb] := true
            continue
        }
        if RegGet(HKEY_CURRENT_USER, p, HIDE_MARK, MISSING) != MISSING
            wasHidden[verb] := true
    }
    ; 2) 清旧副本
    for name in EnumSubkeys(HKEY_CURRENT_USER, base)
        if IsReplicaName(name)
            RegDelTree(base "\" name)
    ; 3) 按目标顺序建副本（跳过不能安全改名的 verb）
    made := [], numbering := Map()
    n := 0
    for verb in seq {
        if !CanReplicate(root, verb)
            continue
        n++
        dst := base "\" ReplicaName(n, verb)
        try CopyKeyTree(HKEY_CLASSES_ROOT, root "\shell\" verb, dst, CopySkip(root, verb))
        if !KeyExists(HKEY_CURRENT_USER, dst) {    ; 单个 verb 复制失败 → 整根回滚
            RollbackRoot(base, made, wasHidden)
            return false
        }
        made.Push(ReplicaName(n, verb))
        numbering[verb] := n
    }
    ; 4) 把旧意图写回新副本
    for verb in numbering {
        if wasHidden.Has(verb)
            try RegWrite "", "REG_SZ", "HKCU\" base "\" ReplicaName(numbering[verb], verb), HIDE_MARK
    }
    ; 5) 只让被复制的原件让位；没复制的原件保持系统原样（不能连带隐藏）。
    ;    ★ 这一步必须校验：任一处写入失败，副本在、原件没让位 → 菜单里同一项出两遍。
    ;    1.6.1 及以前用 try 一包就算成功，失败也没人知道（用户只看到菜单重复）。
    fails := 0
    for verb in numbering {
        p := "HKCU\" base "\" verb
        try {
            RegWrite "", "REG_SZ", p, HIDE_MARK
            RegWrite "1", "REG_SZ", p, TAKE_MARK
        } catch
            fails++
    }
    if fails {
        RollbackRoot(base, made, wasHidden)
        return false
    }
    return true
}

; 回滚一个根：删掉本轮新建的副本，再按快照把原件标记复位。
; 扫全根（而不是只看本轮 made）：上一轮可能留下「有 TAKE_MARK、却已经没有副本」的孤儿，
; 那种孤儿会让菜单项永远消失，顺手一并清掉。
RollbackRoot(base, made, wasHidden) {
    for m in made
        RegDelTree(base "\" m)
    for verb in EnumSubkeys(HKEY_CURRENT_USER, base) {
        if IsReplicaName(verb)
            continue
        p := base "\" verb
        if RegGet(HKEY_CURRENT_USER, p, TAKE_MARK, MISSING) = MISSING
            continue
        try RegDelete "HKCU\" p, TAKE_MARK
        if !wasHidden.Has(verb)
            try RegDelete "HKCU\" p, HIDE_MARK
        PruneKey("HKCU\" p)
    }
}

; 能不能把这项复制成 p000N# 副本而不坏掉显示名。
; 判据就是原件自己有没有显式名字（MUIVerb / MuiVerb）。没有 MUIVerb 的项，显示名由
; shell 按键名硬编码（open→「打开」、Powershell→「在此处打开 Powershell 窗口」），
; 改名前缀必然把菜单变成 "p0001#open" 这种乱码。
; 注意：opennewwindow / opennewtab 这类虽然算「打开」系内建动词（排最前），但它们
; 自己带 MUIVerb，改名是安全的，所以这里不再按 IsShellBuiltinVerb 拦。
CanReplicate(root, verb) {
    if IsProtectedVerb(verb)
        return false
    for n in ["MUIVerb", "MuiVerb"] {
        v := RegGet(HKEY_CLASSES_ROOT, root "\shell\" verb, n, MISSING)
        if (v != MISSING && Trim(v) != "")
            return true
    }
    return false
}


; 复制副本时要丢掉的值：Position 一律不要（顺序改由前缀号决定，留着会被拽回 top/bottom）；
; ProgrammaticAccessOnly / LegacyDisable 只有当 HKLM 原件自己有才保留（那是系统级隐藏），
; HKLM 没有就说明是脚本自己写的，不能继承过去，否则副本一出生就看不见。
CopySkip(root, verb) {
    hklm := "Software\Classes\" root "\shell\" verb
    skip := ",Position,"
    for n in [HIDE_MARK, "LegacyDisable"]
        if RegGet(HKEY_LOCAL_MACHINE, hklm, n, MISSING) = MISSING
            skip .= n ","
    return skip
}

; 撤销当前场景的顺序接管：删掉全部副本、去掉原件上的接管标记，菜单回到系统默认次序。
; 两条必须遵守：
;   ① 副本上带着用户的「已隐藏」意图，删副本前先把它搬回原件影子键，
;      否则用户主动隐藏过的项会在恢复后全冒出来（1.6.1 及以前就是这样）；
;   ② 只能扫副本表是不够的——历史失败可能留下「有 TAKE_MARK、没有副本」的孤儿，
;      那种原件会永远隐藏且在界面上无法自救。所以按 TAKE_MARK 扫全根。
RestoreOrder() {
    global gDropPath, gScene, gStatus
    n := 0
    for root in SceneRoots(SceneDefs()[gScene].key, gDropPath) {
        base := "Software\Classes\" root "\shell"
        reps := ReplicaMap(root)
        for verb, name in reps {
            if RegGet(HKEY_CURRENT_USER, base "\" name, HIDE_MARK, MISSING) != MISSING
                try RegWrite "", "REG_SZ", "HKCU\" base "\" verb, HIDE_MARK
            RegDelTree(base "\" name)
            n++
        }
        for verb in EnumSubkeys(HKEY_CURRENT_USER, base) {
            if IsReplicaName(verb)
                continue
            p := base "\" verb
            if RegGet(HKEY_CURRENT_USER, p, TAKE_MARK, MISSING) = MISSING
                continue
            try RegDelete "HKCU\" p, TAKE_MARK
            ; 副本还在的那些，隐藏意图刚搬回原件，必须留着；没副本的孤儿就是我们写坏了，清掉。
            if !reps.Has(verb)
                try RegDelete "HKCU\" p, HIDE_MARK
            ; 删完两个标记后，如果这键本来就是我们建的影子键，它已经空了 → 一并清掉，
            ; 否则残留的空 shell 键会让菜单多出一行没有命令的空白项。
            PruneKey("HKCU\" p)
        }
        try RegDelete "HKCU\" base
    }
    NotifyAssocChanged()
    RefreshItems()
    gStatus.Value := n ? "已撤销顺序接管（清除 " n " 个副本），菜单回到系统默认次序"
                    : "当前场景没有被接管的顺序"
}



SetOnlyVisible(on) {
    global gOnlyVisible
    gOnlyVisible := on ? 1 : 0
    RefreshItems()
}

; 选中项变了，切换按钮的文案跟着变（ListView 的 ItemFocus 事件）。
SyncToggleLabel() {
    global gToggleBtn, gStatus
    if (!gToggleBtn)
        return
    it := SelectedItem()
    if !it {
        gToggleBtn.Value := "隐藏"
        return
    }
    if (it.layer = "sub") {
        gToggleBtn.Value := "隐藏"
        return
    }
    gToggleBtn.Value := it.state = "show" ? "隐藏" : "显示"
}

SetHide(on) {
    global gStatus
    it := SelectedItem()
    if !it {
        gStatus.Value := "先在列表里选中一个菜单项"
        return
    }
    if (it.layer = "sub") {
        gStatus.Value := "「" it.label "」是「发送到」的二级项，只读展示、不可操作"
        return
    }
    ; Windows 自带的剪切/复制/删除/属性这类项由 shell 直接渲染，注册表里没有对应键，
    ; 既不能隐藏也不能调序，如实说明，不让按钮点了没反应。
    if (it.layer = "menu") {
        gStatus.Value := "「" it.label "」是 Windows 内建菜单项，注册表里没有对应项，改不了它的显示"
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
    msg := ""
    if (it.layer = "verb") {
        errs := WriteVerbMarks(it.roots, it.key, on ? "hide" : "show")
        if errs {
            gStatus.Value := "有 " errs " 处写入失败（可能需管理员权限）"
            return
        }
        extra := on ? "" : (it.state = "syshidden" ? "（仍有系统级隐藏标记，需管理员权限）" : "")
        msg := (on ? "已隐藏 verb「" : "已恢复 verb「") it.label "」" extra " · " it.roots.Length " 处来源"
    } else {
        ; COM：Blocked 键按 CLSID 写/删（HKCU，零提权；全局生效，与来源个数无关）
        ; 恢复时那个值可能本来就不存在（系统隐藏 / 菜单外），必须逐个 try ——
        ; 一处抛异常就整条报「操作失败」，用户会以为没成功。
        errs := 0
        for k in it.keys {
            try {
                if on
                    RegWrite "", "REG_SZ", "HKCU\" BLOCK_PATH, k
                else
                    try RegDelete "HKCU\" BLOCK_PATH, k
            } catch
                errs++
        }
        if errs {
            gStatus.Value := "有 " errs " 处写入失败（可能需管理员权限）"
            return
        }
        msg := (on ? "已隐藏 COM 扩展「" : "已恢复 COM 扩展「") it.label "」"
            . (it.keys.Length > 1 ? "（含 " it.keys.Length " 个注册项）" : "（全局生效）")
    }
    NotifyAssocChanged()
    ; ★ keepMsg：不带这个参数，RefreshItems 会把状态条改写成「显示 N 项 · 已隐藏 M」，
    ;   用户点完只看到统计，以为按钮没反应（1.5.0 上移/下移踩过同一个坑）。
    RefreshItems(msg)
}

; 拖入对象在状态栏显示「这一类对象」：改的从来不是单个文件，而是它代表的一整类
; （.zip 拖进来 = 所有 zip 文件的菜单；文件夹 = 所有文件夹的菜单），写明以免误会。
ObjScopeLabel(path) {
    if (path = "")
        return "拖入对象"
    if DirExist(path)
        return "文件夹"
    SplitPath path, , , &ext
    ext := StrLower(ext)
    ; v2 的 SplitPath 给的 ext 不带点（.zip → "zip"），直接拼即可。
    return ext != "" ? ext " 文件" : "文件"
}

; ── 新增菜单项（1.8.0）─────────────────────────────────────────────────
; 蓝本：ContextMenuManager 的 NewShellDialog.cs——<root>\shell\<唯一键> 写
; MUIVerb=显示名 + command\<默认>=命令行。零提权（只写 HKCU\Software\Classes），
; 删掉整个键即完全撤销；不碰命令、不碰 HKLM、不提权。
; 作用范围直接复用 SceneRoots()：和隐藏走同一批位置根，列表里立刻可见。
global gAddGui := 0, gAddName := 0, gAddCmd := 0, gAddRows := []

AddCustomVerb(sceneKey, dropPath, name, cmd) {
    roots := SceneRoots(sceneKey, dropPath)
    if (!roots.Length || name = "" || cmd = "")
        return ""
    n := 1
    loop {
        key := CUSTOM_PREFIX n
        free := true
        for r in roots
            if KeyExists(HKEY_CURRENT_USER, "Software\Classes\" r "\shell\" key)
                free := false
        if free
            break
        n++
        if (n > 9999)
            return ""
    }
    for r in roots {
        base := "Software\Classes\" r "\shell\" key
        EnsureKey(base)
        RegWrite name, "REG_SZ", "HKCU\" base, "MUIVerb"
        RegWrite cmd, "REG_SZ", "HKCU\" base "\command"
    }
    NotifyAssocChanged()
    return key
}

DeleteCustomVerb(sceneKey, dropPath, verb) {
    n := 0
    for r in SceneRoots(sceneKey, dropPath) {
        p := "Software\Classes\" r "\shell\" verb
        if KeyExists(HKEY_CURRENT_USER, p) {
            RegDelTree(p)
            n++
        }
    }
    NotifyAssocChanged()
    return n
}

CustomItemsInScene() {
    global gDropPath, gScene
    out := []
    for root in SceneRoots(SceneDefs()[gScene].key, gDropPath) {
        for verb in EnumSubkeys(HKEY_CURRENT_USER, "Software\Classes\" root "\shell") {
            if (SubStr(verb, 1, StrLen(CUSTOM_PREFIX)) != CUSTOM_PREFIX)
                continue
            base := "Software\Classes\" root "\shell\" verb
            nm := RegGet(HKEY_CURRENT_USER, base, "MUIVerb", verb)
            cmd := RegGet(HKEY_CURRENT_USER, base "\command", "", "")
            out.Push({ root: root, verb: verb, label: nm, cmd: cmd })
        }
    }
    return out
}

; 单行 Edit 的垂直居中：EM_SETRECT 对单行无效，必须 Multi -VScroll -WantReturn -Wrap。
SetEditRect(hwnd, left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0), NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8), NumPut("Int", bottom, rc, 12)
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0xB3, "Ptr", 0, "Ptr", rc, "Ptr")
}

BuildAddGui() {
    global gAddGui, gAddName, gAddCmd
    gAddGui := Gui("", "自定义菜单项")
    gAddGui.BackColor := "F7F9FC"
    gAddGui.SetFont("s10", "Microsoft YaHei UI")
    gAddGui.OnEvent("Close", (*) => gAddGui.Hide())
    gAddGui.Add("Text", "x16 y12 w388 h20 BackgroundF7F9FC c202B3A +0x200", "菜单项名称")
    gAddGui.Add("Text", "x16 y32 w388 h28 BackgroundB7C8E0 -0x100")
    gAddName := gAddGui.Add("Edit", "x17 y33 w386 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(gAddName.Hwnd, 8, 2, 378, 26)
    gAddGui.Add("Text", "x16 y68 w388 h20 BackgroundF7F9FC c202B3A +0x200", "命令行")
    gAddGui.Add("Text", "x16 y88 w388 h28 BackgroundB7C8E0 -0x100")
    gAddCmd := gAddGui.Add("Edit", "x17 y89 w386 h26 -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(gAddCmd.Hwnd, 8, 2, 378, 26)
    ; 仿 ContextMenuManager 的浏览：选 exe 自动填名称与命令行；再加两个常用模板。
    FlatButton(gAddGui, 16, 124, 84, 28, "浏览…", (*) => BrowseCustom())
    FlatButton(gAddGui, 108, 124, 84, 28, "PowerShell", (*) => TplCustom("ps"))
    FlatButton(gAddGui, 200, 124, 84, 28, "CMD", (*) => TplCustom("cmd"))
    gAddGui.Add("Text", "x16 y160 w388 h20 BackgroundF7F9FC c202B3A +0x200", "%1=选中的文件，%V=所在目录（模板已带好）")
    gAddGui.Add("Text", "x16 y188 w388 h1 BackgroundB7C8E0 -0x100")
    gAddGui.Add("Text", "x16 y194 w388 h20 BackgroundF7F9FC c202B3A +0x200", "已添加的项（点一下即删除）：")
    FlatButton(gAddGui, 16, 312, 84, 30, "添加", (*) => DoAddCustom())
    FlatButton(gAddGui, 108, 312, 84, 30, "关闭", (*) => gAddGui.Hide())
}

; 浏览选程序：名称填文件名（去扩展名），命令行 = "程序路径" + 对象参数。
; 拖入对象场景传 "%1"（选中的文件），桌面/文件夹空白场景传 "%V"（所在目录）。
BrowseCustom() {
    global gAddGui, gAddName, gAddCmd, gScene
    ; v2.0 的 FileSelect 没有 Filter 参数，选完不再校验扩展名——用户自己的机器自己负责。
    picked := FileSelect(1, , "选择程序")
    if (picked = "")
        return
    SplitPath picked, , , , &base
    gAddName.Value := base
    arg := SceneDefs()[gScene].key = "obj" ? ' "%1"' : ' "%V"'
    gAddCmd.Value := '"' picked '"' arg
}

; 常用模板：在当前目录打开 PowerShell / CMD。
TplCustom(kind) {
    global gAddCmd
    ; PS 命令里要包一层单引号（Chr(39)），避免引号套引号的转义歧义。
    if (kind = "ps")
        gAddCmd.Value := 'powershell.exe -NoExit -Command "Set-Location -LiteralPath ' Chr(39) '%V' Chr(39) '"'
    else
        gAddCmd.Value := 'cmd.exe /k cd /d "%V"'
}

RefreshAddRows() {
    global gAddGui, gAddRows
    for c in gAddRows
        try c.Destroy()
    gAddRows := []
    y := 216
    for ci in CustomItemsInScene() {
        if (y > 302)
            break
        t := gAddGui.Add("Text", "x16 y" y " w388 h24 BackgroundF7F9FC c202B3A +0x200", "× " ci.label)
        t.OnEvent("Click", DeleteCustom.Bind(ci))
        gAddRows.Push(t)
        y += 26
    }
}

OpenAddDialog() {
    global gAddGui, gScene, gDropPath, gStatus
    roots := SceneRoots(SceneDefs()[gScene].key, gDropPath)
    if !roots.Length {
        gStatus.Value := "先在左侧选场景或拖入一个文件/文件夹，再新增菜单项"
        return
    }
    if !IsObject(gAddGui)
        BuildAddGui()
    RefreshAddRows()
    gAddGui.Show("w420 h360 Center")
    PaintCaption(gAddGui.Hwnd)
}

DoAddCustom() {
    global gAddGui, gAddName, gAddCmd, gScene, gDropPath, gStatus
    name := Trim(gAddName.Value), cmd := Trim(gAddCmd.Value)
    if (name = "" || cmd = "") {
        gStatus.Value := "名称和命令行都不能为空"
        return
    }
    key := AddCustomVerb(SceneDefs()[gScene].key, gDropPath, name, cmd)
    if (key = "") {
        gStatus.Value := "新增失败：位置根为空或编号用尽"
        return
    }
    gAddName.Value := "", gAddCmd.Value := ""
    RefreshItems("已新增菜单项「" name "」（列表来源=自定义）")
    RefreshAddRows()
}

DeleteCustom(ci, *) {
    global gScene, gDropPath, gStatus
    n := DeleteCustomVerb(SceneDefs()[gScene].key, gDropPath, ci.verb)
    RefreshItems("已删除自定义菜单项「" ci.label "」（" n " 处来源）")
    RefreshAddRows()
}

; ── 自绘滚动条 ──────────────────────────────────────────────────────────
; 整段复用《文件解锁》1.3.1 /《硬件信息》2.3.4 的 class FlatScroll（只竖轴）。
; 原生条由 comctl32 主题引擎绘制，脚本拿不到颜色；ShowScrollBar(FALSE) 只是「按需隐藏」，
; Move/Add/Delete/ModifyCol/LVM_SCROLL 都会把样式位置回，所以每次动作后补一刀 + Sync 兜底。
; 横向条撤掉，列宽做进视口。
; 系统 CheckBox 在宿主里是经典黑勾方框，样式位去不掉，改成三层 Text 色块自绘
; （配方同《文件时间修改》1.5.x）：Value 保持 0/1，方框与文字都能点。
class FlatCheck {
    __New(g, x, y, w, h, text, checked := false) {
        this.Value := checked ? 1 : 0
        this.cb := 0
        boxY := y + (h - 16) // 2
        ; 同 FlatButton：16x16 描边框先建、14x14 填充块后建（Z 序在上，✓ 才看得见），
        ; 两块都挂 Click（宿主命中按创建序，先中的是框）。
        this.frame := g.Add("Text", "x" x " y" boxY " w16 h16 BackgroundB7C8E0 +0x200")
        this.fill := g.Add("Text", "x" (x + 1) " y" (boxY + 1) " w14 h14 +0x200 Center", "")
        this.fill.SetFont("s11 Bold", "Microsoft YaHei UI")
        this.label := g.Add("Text", "x" (x + 22) " y" y " w" (w - 22) " h" h
            " BackgroundF7F9FC c202B3A +0x200", text)
        this.Paint()
        for c in [this.frame, this.fill, this.label]
            c.OnEvent("Click", (*) => this.Toggle())
    }
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
        if (this.cb)
            this.cb.Call()
    }
    OnEvent(name, cb) {
        if (name = "Click")
            this.cb := cb
    }
}

class FlatScroll {
    __New(g, lv, x, y, w, h, t := 10) {
        this.g := g, this.lv := lv
        this.x := x, this.y := y, this.w := w, this.h := h, this.t := t
        ; 滑块占满轨道宽度留 1px 边 → 用户指出与「打开方式清理」长得不一样。
        ; 标准配方（UI组件手册附录，文件时间修改同款）：滑块厚度 = t-6、两侧各露 3px
        ; 轨道，t=10 → 轨道 10、滑块 4，系统样式观感。t=10 → tn=4, off=3。
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
        ; +0x100 = SS_NOTIFY：给静态控件发通知，按住拖动时宿主才会派发鼠标消息。
        this.track := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumb := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        for c in [this.track, this.thumb]
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
    ; 轨道整条画、滑块后画（Z 序后建在上，滑块一定盖住轨道）。
    ; 两块几何上永远嵌套、没有中缝，也就不会「断开」。
    Paint() {
        t := this.t, tn := this.tn, off := this.off, pd := this.pad
        this.ops := []
        if (this.exV) {
            g := this.Geo(this.TrackLen())
            bx := this.x + this.lvW
            a := this.y + pd + g.start
            this.Put(this.track, true, bx, this.y, t, this.lvH)
            this.Put(this.thumb, true, bx + off, a, tn, g.len)
        } else {
            this.Put(this.track, false, 0, 0, 0, 0)
            this.Put(this.thumb, false, 0, 0, 0, 0)
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
    ; 滚到指定首行：标准版（文件时间修改/打开方式清理同款）走 LVM_ENSUREVISIBLE。
    ; ★ 不能用 LVM_SCROLL——它每次都会把原生滚动条置回（样式位立刻 H1V1），
    ;   原生灰条在两帧之间一闪，正是用户报的「旧版滚动条闪过」。
    ScrollToRow(target) {
        if (!this.lv.Hwnd)
            return
        target := Max(0, Min(this.maxTop, target))
        if (target = this.top) {
            this.Paint()
            return
        }
        if (target > this.top) {
            last := Min(this.rows - 1, target + this.viewRows - 1)
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1013, "Ptr", last, "Ptr", 0, "Ptr")
        } else {
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1013, "Ptr", target, "Ptr", 0, "Ptr")
        }
        ; ENSUREVISIBLE 会让 ListView 重算范围、把 WS_VSCROLL 置回，必须当场再藏
        ; （不能等 Sync 的 60ms 兜底）；交界半截字用「不擦背景的整块作废」补画。
        this.HideNative()
        DllCall("user32\InvalidateRect", "Ptr", this.lv.Hwnd, "Ptr", 0, "Int", false)
        DllCall("user32\UpdateWindow", "Ptr", this.lv.Hwnd)
        this.top := this.ReadTop()
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
    Geo(trackLen) {
        len := Max(24, Min(trackLen, Round(trackLen * this.viewRows / Max(1, this.rows))))
        span := trackLen - len
        frac := (this.maxTop > 0) ? this.top / this.maxTop : 0
        return { len: len, start: Round(frac * span), span: span }
    }
    ; 只有两块控件，命中一定是轨道（先建先中）：落在滑块范围里就拖，否则按页跳。
    OnDown(hwnd) {
        if (hwnd != this.track.Hwnd && hwnd != this.thumb.Hwnd)
            return
        if (!this.exV)
            return
        if this.CursorInThumb()
            this.BeginDrag()
        else
            this.PageJump()
    }
    CursorInThumb() {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := NumGet(pt, 4, "Int")
        r := Buffer(16, 0)
        if !DllCall("user32\GetWindowRect", "Ptr", this.thumb.Hwnd, "Ptr", r)
            return false
        ; 滑块只有 4px 厚，上下各放宽 3px（=两侧露出的轨道）算进拖动命中，
        ; 与标准版「gap 块也算滑块」的手感一致。
        return (c >= NumGet(r, 4, "Int") - 3 && c < NumGet(r, 12, "Int") + 3)
    }
    PageJump() {
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        c := NumGet(pt, 4, "Int")
        r := Buffer(16, 0)
        DllCall("user32\GetWindowRect", "Ptr", this.thumb.Hwnd, "Ptr", r)
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
        DllCall("user32\SetCapture", "Ptr", this.thumb.Hwnd)
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
PaintCaption(hwnd := 0) {
    global gGui
    hwnd := hwnd ? hwnd : gGui.Hwnd   ; 1.8.0：对话框也刷同一套标题栏色
    c := Buffer(4, 0), NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0), NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; 按钮 = 外框块 f + 内块 b（b 带文字）。§10 的标准配方，两个控件。
; ★ Z 序：后建者在上。1.6.0 的「按钮变空白」是**建反了顺序**——先建内块、后建的外框块
;   把整块文字盖成边色；配方本身没问题。所以这里外框必须先建：框在下、内块在上，只剩 1px 边。
; ★ 不再用「内块 + 四条 1px 细条」拼边框：细条是独立窗口，重绘/缩放时容易漏掉一条边
;   （1.6.3 报「隐藏按钮没有边框线」）。两块定边框，边不会再少，窗口也少三个。
FlatButton(g, x, y, w, h, text, cb, fill := "EBF2FB", edge := "B7C8E0") {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    f.OnEvent("Click", (*) => cb())     ; 最外那 1px 是外框块，命中得先落在它身上
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    b.OnEvent("Click", (*) => cb())
    return b
}

NavClick(i, *) {
    global gNavBtns, gScene, gStatus
    gScene := i
    for j, b in gNavBtns {
        b.Opt("Background" (j = i ? "EBF2FB" : "F7F9FC"))
        b.Redraw()   ; Opt 改色不触发重绘，选中底色不跟随（用户实测）
    }
    try
        RefreshItems()
    catch as e {
        gStatus.Value := "刷新失败 · " e.Message "（第 " e.Line " 行）"
    }
}

; 点表头：同列再点一次反向，换列则按新列升序。1=顺序 2=菜单项 3=来源 4=可改 5=状态。
HeadClick(col, *) {
    global gSortCol, gSortAsc
    if (gSortCol = col)
        gSortAsc := !gSortAsc
    else
        gSortCol := col, gSortAsc := true
    RefreshItems()
}

; 只在当前排序列的名字后面挂箭头，其余列保持原名。
SyncHeadArrows() {
    global gHeadBlocks, gSortCol, gSortAsc
    for i, h in gHeadBlocks {
        if (h.ctrl.Value != h.title && i != gSortCol)
            h.ctrl.Value := h.title
        if (i = gSortCol) {
            txt := h.title "  " (gSortAsc ? "↑" : "↓")
            if (h.ctrl.Value != txt)
                h.ctrl.Value := txt
        }
    }
}

OnDropFiles(guiObj, ctrlObj, files, x, y) {
    global gScene, gNavBtns, gDropPath, gStatus
    if !files.Length
        return
    gDropPath := files[1]
    gScene := 1
    for j, b in gNavBtns {
        b.Opt("Background" (j = 1 ? "EBF2FB" : "F7F9FC"))
        b.Redraw()
    }
    RefreshItems()
}

; ── 原生滚动条根治（K51）：ListView 的 WM_NCCALCSIZE 子类 ──────────
; 原生灰条画在非客户区，ShowScrollBar(FALSE) 只摘样式位不擦像素、InvalidateRect(NULL) 只作废
; 客户区，「藏完再追着擦」永远差一拍。这里在 NC 空间计算时临时摘掉 WS_VSCROLL|WS_HSCROLL 再走
; 默认计算、算完恢复——原生条分不到 NC 空间、一个像素都画不出。滚动走 SetScrollInfo 不受影响。
LvNcCalcSize(hwnd, msg, wParam, lParam, idSubclass, refData) {
    if (msg = 0x0083 && wParam) {
        v := DllCall("user32\GetWindowLongW", "Ptr", hwnd, "Int", -16, "Int")
        if (v & 0x00300000) {
            DllCall("user32\SetWindowLongW", "Ptr", hwnd, "Int", -16, "Int", v & 0xFFCFFFFF)
            r := DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg
                , "Ptr", wParam, "Ptr", lParam, "Ptr")
            DllCall("user32\SetWindowLongW", "Ptr", hwnd, "Int", -16, "Int", v)
            return r
        }
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hwnd, "UInt", msg
        , "Ptr", wParam, "Ptr", lParam, "Ptr")
}

RemoveLvSub() {
    global gLvNcProc, gLvMainHwnd
    if (gLvMainHwnd && gLvNcProc)
        try DllCall("comctl32\RemoveWindowSubclass", "Ptr", gLvMainHwnd, "Ptr", gLvNcProc, "Ptr", 1)
}

BuildGui() {
    global gGui, gList, gStatus, gNavBtns, gScroll, gToggleBtn, gCheck, gHeadBlocks, gLvNcProc, gLvMainHwnd
    gGui := Gui("", "右键菜单整理")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => (gScroll ? gScroll.Stop() : 0, RemoveLvSub(), ExitApp()))
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

    ; 拖入区：白底 + 1px 框 + 居中提示（Text 色块，DropFiles 由父窗口转发）。
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w" NAV_W " h" DROP_H " BackgroundFFFFFF")
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w" NAV_W " h1 BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" NAV_X " y" (DROP_Y + DROP_H - 1) " w" NAV_W " h1 BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" NAV_X " y" DROP_Y " w1 h" DROP_H " BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" (NAV_X + NAV_W - 1) " y" DROP_Y " w1 h" DROP_H " BackgroundB7C8E0 +0x200")
    gGui.Add("Text", "x" (NAV_X + 6) " y" (DROP_Y + 38) " w" (NAV_W - 12) " h20"
        " BackgroundFFFFFF c202B3A +0x200 Center", "把文件(夹)")
    gGui.Add("Text", "x" (NAV_X + 6) " y" (DROP_Y + 64) " w" (NAV_W - 12) " h20"
        " BackgroundFFFFFF c202B3A +0x200 Center", "拖到这里")

    ; 列表区：四边线 + 表头背景块。装饰块一律不挂事件、且 -0x100 去 SS_NOTIFY。
    ; 注意：1.2.2 曾在这里铺一块 BackgroundFFFFFF 白底大块——AHK 的控件 Z 序与创建序
    ; 相反，后建的 ListView 反而在它之下，实测这块白底把整个列表的鼠标点击全吃掉
    ; （点行选不中）且拖入刷新后重绘盖白整块列表；它几何上被表头块+ListView 完全
    ; 覆盖，直接删除（ListView 自带 BackgroundFFFFFF）。
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w" LIST_W " h1 BackgroundB7C8E0 -0x100")
    gGui.Add("Text", "x" LIST_X " y" (LIST_Y + HEAD_H + LIST_H) " w" LIST_W " h1 BackgroundB7C8E0 -0x100")
    gGui.Add("Text", "x" LIST_X " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 -0x100")
    gGui.Add("Text", "x" (LIST_X + LIST_W - 1) " y" LIST_Y " w1 h" (HEAD_H + LIST_H + 1) " BackgroundB7C8E0 -0x100")
    gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_Y + 1) " w" (LIST_W - 2) " h" HEAD_H " BackgroundDCE8F7 -0x100")
    ; 表头本身是按钮：点一列按这列排，再点一次反向；列名后跟 ↑/↓ 指明当前排序列。
    ; 默认按「顺序」升序（1.4.0 用户定案），即脚本推断的真实菜单次序。
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gHeadBlocks := []
    hx := LIST_X + 7
    for i, cd in [[COL_ORD_W, "顺序"], [COL_NAME_W, "菜单项"]
                , [COL_SRC_W, "来源"], [COL_CAP_W, "可改"], [COL_STATE_W, "状态"]] {
        b := gGui.Add("Text", "x" hx " y" (LIST_Y + 1) " w" (cd[1] - 6) " h" HEAD_H
            " BackgroundDCE8F7 c202B3A +0x200", cd[2])
        b.OnEvent("Click", HeadClick.Bind(i))
        gHeadBlocks.Push({ ctrl: b, title: cd[2] })
        hx += cd[1]
    }
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    gList := gGui.Add("ListView", "x" (LIST_X + 1) " y" (LIST_Y + HEAD_H + 1)
        " w" (LIST_W - 2) " h" (LIST_H - 1) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["顺序", "菜单项", "来源", "可改", "状态"])
    gList.ModifyCol(1, COL_ORD_W), gList.ModifyCol(2, COL_NAME_W), gList.ModifyCol(3, COL_SRC_W)
    gList.ModifyCol(4, COL_CAP_W), gList.ModifyCol(5, COL_STATE_W)
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)
    ; K51：在 FlatScroll 建立、第一次填表之前挂 WM_NCCALCSIZE 子类，从第一帧起原生条就无空间。
    gLvMainHwnd := gList.Hwnd
    gLvNcProc := CallbackCreate(LvNcCalcSize)
    DllCall("comctl32\SetWindowSubclass", "Ptr", gList.Hwnd, "Ptr", gLvNcProc, "Ptr", 1, "Ptr", 0)

    ; 五个按钮同宽同距：状态切换（一个按钮两态）、上移、下移、新增、刷新。
    ; 1.8.0 用户裁决删掉「恢复」：它只撤销顺序接管，没调过序就毫无反应，看着像死按钮；
    ; 第四个按钮原位换成「新增」，几何完全不变。上移/下移仍是真·逐位换位。
    gToggleBtn := FlatButton(gGui, LIST_X, BTN_Y, BTN_W, BTN_H, "隐藏", (*) => ToggleSelected())
    FlatButton(gGui, LIST_X + BTN_W + BTN_GAP, BTN_Y, BTN_W, BTN_H, "上移", (*) => MoveVerb(-1))
    FlatButton(gGui, LIST_X + (BTN_W + BTN_GAP) * 2, BTN_Y, BTN_W, BTN_H, "下移", (*) => MoveVerb(1))
    FlatButton(gGui, LIST_X + (BTN_W + BTN_GAP) * 3, BTN_Y, BTN_W, BTN_H, "自定义", (*) => OpenAddDialog())
    FlatButton(gGui, LIST_X + (BTN_W + BTN_GAP) * 4, BTN_Y, BTN_W, BTN_H, "刷新", (*) => RefreshItems())

    ; 「隐藏不可见项」默认勾上：只看真实菜单里会出现的项。
    gCheck := FlatCheck(gGui, LIST_X + LIST_W - 140, BTN_Y, 140, BTN_H, "隐藏不可见项", gOnlyVisible)
    gCheck.OnEvent("Click", (*) => SetOnlyVisible(gCheck.Value))
    gList.OnEvent("ItemFocus", (*) => SyncToggleLabel())

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
;   items: --probe items <场景key> <结果文件> [拖入路径] → 该场景合并后的行（layer|显示名|来源|状态|位置|可见）
if (A_Args.Length >= 3 && A_Args[1] = "--probe") {
    if (A_Args[2] = "roots" && A_Args.Length >= 4)
        ProbeRoots(A_Args[3], A_Args.Length >= 5 ? A_Args[5] : "", A_Args[4])
    else if (A_Args[2] = "items" && A_Args.Length >= 4)
        ProbeItems(A_Args[3], A_Args.Length >= 5 ? A_Args[5] : "", A_Args[4])
    else if (A_Args.Length >= 4 && A_Args[2] = "verb" && A_Args.Length >= 5)
        ProbeVerb(A_Args[3], A_Args[4], A_Args[5])
    else if (A_Args[2] = "restore" && A_Args.Length >= 4)
        ProbeRestore(A_Args[3], A_Args[4])
    else if (A_Args[2] = "vals" && A_Args.Length >= 4)
        ProbeVals(A_Args[3], A_Args[4])
    else if (A_Args[2] = "real" && A_Args.Length >= 4)
        ProbeReal(A_Args[3], A_Args[4])
    else if (A_Args[2] = "order" && A_Args.Length >= 5)
        ProbeOrder(A_Args[3], A_Args[4], A_Args[5])
    else if (A_Args[2] = "tree" && A_Args.Length >= 4)
        ProbeTree(A_Args[3], A_Args[4], A_Args.Length >= 5 ? Integer(A_Args[5]) : 0x10)
    else if (A_Args[2] = "add" && A_Args.Length >= 6)
        ProbeAdd(A_Args[3], A_Args[4], A_Args[5], A_Args[6], A_Args.Length >= 7 ? A_Args[7] : "")
    else if (A_Args[2] = "delcustom" && A_Args.Length >= 5)
        ProbeDelCustom(A_Args[3], A_Args[4], A_Args[5], A_Args.Length >= 6 ? A_Args[6] : "")
    else if (A_Args[2] = "exmenu" && A_Args.Length >= 4)
        ProbeExplorerMenu(A_Args[3], A_Args[4])
    else if (A_Args.Length >= 4 && A_Args[2] = "com")
        ProbeCom(A_Args[3], A_Args[4])
    else
        throw ValueError("probe 参数不对")
    ExitApp(0)
}

; 新增项探针：--probe add <场景> <名称> <命令行> <结果文件> [拖入路径]
ProbeAdd(sceneKey, name, cmd, outPath, dropPath) {
    key := AddCustomVerb(sceneKey, dropPath, name, cmd)
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend "key=" key "`n", outPath, "UTF-8"
    ExitApp(0)
}

; 删除新增项探针：--probe delcustom <场景> <键名> <结果文件> [拖入路径]
ProbeDelCustom(sceneKey, key, outPath, dropPath) {
    n := DeleteCustomVerb(sceneKey, dropPath, key)
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend "deleted=" n "`n", outPath, "UTF-8"
    ExitApp(0)
}

; 行列表探针：把 MakeItems 的结果逐行写出，供 test/run.py 断言
; 「拖入场景到底列出什么」——拖放本身没法用 MCP 模拟，只能走这条。
; --probe tree <对象路径> <结果文件> [flags]：把 shell 真正渲染出的整棵菜单树（含 verb）打出来。
; 排查「顺序不对 / 少一项 / 子菜单没展开」时先看这个，它比列表更接近事实。
ProbeTree(path, outPath, flags := 0x10) {
    out := ""
    try {
        pcm := ContextMenuFor(path, false)
        out .= "flags=0x" Format("{:X}", flags) " pcm=" pcm "`n"
        if pcm {
            tree := RealMenuTree(pcm, flags)
            out .= tree ? MenuRowsText(tree, 0) : "(no tree)`n"
        }
    } catch as e {
        out .= "ERR " e.Message " @ " e.Line "`n" e.Stack
    }
    p := Max(InStr(outPath, "\\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend out, outPath, "UTF-8"
    ExitApp(0)
}

ProbeItems(sceneKey, dropPath, outPath) {
    global gDropPath
    gDropPath := dropPath
    try
        items := MakeItems({ key: sceneKey })
    catch as e {
        try FileDelete outPath
        FileAppend "ERR " e.Message " @ line " e.Line "`n" e.Stack, outPath, "UTF-8"
        ExitApp(3)
    }
    out := ""
    for it in items {
        vis := VisibleItem(it) ? "1" : "0"
        out .= it.layer "|" it.label "|" it.src "|" it.state "|" it.pos "|" vis "`n"
    }
    if (pos := InStr(outPath, "\", false, -1), p2 := InStr(outPath, "/", false, -1))
        pos := Max(pos, p2)
    if (pos > 1)
        try DirCreate(SubStr(outPath, 1, pos - 1))
    try FileDelete outPath
    FileAppend(out, outPath, "UTF-8")
    ExitApp(0)
}

; 探针：hide/show 走正式写函数；top/bottom/default 只写 HKCU 原件的 Position
; （1.4.0 起界面不再用 Position，留着这条只为回归验证 shell 认 Position 这一事实）。
ProbeVerb(root, verb, action) {
    errs := 0
    if (action = "hide" || action = "show") {
        errs := WriteVerbMarks([root], verb, action)
    } else {
        try {
            if (action = "default")
                RegDelete "HKCU\Software\Classes\" root "\shell\" verb, "Position"
            else
                RegWrite action, "REG_SZ", "HKCU\Software\Classes\" root "\shell\" verb, "Position"
        } catch
            errs := 1
    }
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

; 顺序接管探针：--probe order <场景key> <结果文件> <verb1,verb2,...>
; 按给定顺序把该场景的静态项写成副本，输出每个根下的副本名与原件隐藏标记。
ProbeOrder(sceneKey, outPath, list) {
    global gItems, gDropPath
    gDropPath := ""
    items := MakeItems({ key: sceneKey })
    want := StrSplit(list, ",")
    reordered := []
    for v in want
        for it in items
            if (it.layer = "verb" && it.key = v)
                reordered.Push(it)
    for it in items
        if !(it.layer = "verb" && InList(want, it.key))
            reordered.Push(it)
    gItems := reordered
    roots := SceneRoots(sceneKey, "")
    bad := ApplyVerbOrder(roots)
    out := "bad=" bad "`n"
    for root in roots {
        for name in EnumSubkeys(HKEY_CURRENT_USER, "Software\Classes\" root "\shell") {
            if !IsReplicaName(name)
                continue
            out .= root " => " name "`n"
        }
        for verb in want
            out .= root " hide " verb " = "
                . RegGet(HKEY_CURRENT_USER, "Software\Classes\" root "\shell\" verb, HIDE_MARK, "-") "`n"
    }
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend out, outPath, "UTF-8"
    ExitApp(0)
}

; 值枚举探针：--probe vals <HKCR 下的键路径> <结果文件>
ProbeVals(keyPath, outPath) {
    keyPath := StrReplace(keyPath, "/", "\")
    m := RegEnumValues(HKEY_CLASSES_ROOT, keyPath)
    out := "count=" m.Count "`n"
    for n, v in m
        out .= "[" n "] " v.type " = " v.data "`n"
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend out, outPath, "UTF-8"
    ExitApp(0)
}

; 真菜单探针：--probe real <路径> <结果文件>，把 IContextMenu 拿到的文字逐行写出。
ProbeReal(path, outPath) {
    out := ""
    path := StrReplace(path, "/", "\")
    try {
        pDesktop := 0
        hr := DllCall("shell32\SHGetDesktopFolder", "Ptr*", &pDesktop, "Int")
        out .= "desktop hr=" hr " p=" pDesktop "`n"
        pidl := 0, eaten := 0
        hr2 := ComCall(3, pDesktop, "Ptr", 0, "Ptr", 0, "Str", path, "UInt*", &eaten
            , "Ptr*", &pidl, "Ptr", 0, "Int")
        out .= "parse hr=" hr2 " pidl=" pidl " eaten=" eaten "`n"
        iidSF := GUIDBuf("{000214E6-0000-0000-C000-000000000046}")
        iidCM := GUIDBuf("{000214E4-0000-0000-C000-000000000046}")
        pParent := 0, pidlLast := 0
        hr3 := DllCall("shell32\SHBindToParent", "Ptr", pidl, "Ptr", iidSF.Ptr
            , "Ptr*", &pParent, "Ptr*", &pidlLast, "Int")
        out .= "bindparent hr=" hr3 " pParent=" pParent " last=" pidlLast "`n"
        apidl := Buffer(A_PtrSize, 0)
        NumPut("Ptr", pidlLast, apidl, 0)
        pcm := 0
        hr4 := ComCall(10, pParent, "Ptr", 0, "UInt", 1, "Ptr", apidl.Ptr, "Ptr", iidCM.Ptr
            , "Ptr", 0, "Ptr*", &pcm, "Int")
        out .= "getuiobject hr=" hr4 " pcm=" pcm "`n"
        hmenu := DllCall("user32\CreatePopupMenu", "Ptr")
        q := ComCall(3, pcm, "Ptr", hmenu, "UInt", 0, "UInt", 1, "UInt", 0x7FFF, "UInt", 0, "Int")
        out .= "query r=" q " menucount=" DllCall("user32\GetMenuItemCount", "Ptr", hmenu, "Int") "`n"

        words := Map()
        CollectMenuWords(hmenu, words)
        out .= "words=" words.Count "`n"
        for w, _v in words
            out .= "[" w "]`n"
        DllCall("user32\DestroyMenu", "Ptr", hmenu)
    } catch as e {
        out .= "ERR " e.Message " @ " e.Line "`n" e.Stack
    }
    p := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (p > 1)
        try DirCreate(SubStr(outPath, 1, p - 1))
    try FileDelete outPath
    FileAppend out, outPath, "UTF-8"
    ExitApp(0)
}

; 资源管理器真实菜单探针：--probe exmenu <对象路径> <结果文件>
; IShellFolder 给的菜单缺 opennew* 一族，需要用 explorer 自己渲染的菜单核对位次。
ProbeExplorerMenu(target, outPath) {
    last := Max(InStr(outPath, "\", false, -1), InStr(outPath, "/", false, -1))
    if (last > 1)
        try DirCreate(SubStr(outPath, 1, last - 1))
    try FileDelete outPath
    ProbeLog(outPath, "start")
    Run 'explorer.exe /select,"' target '"'
    hWin := 0
    loop 40 {
        if (h := WinExist("ahk_class CabinetWClass")) {
            hWin := h
            break
        }
        Sleep 200
    }
    if !hWin {
        ProbeLog(outPath, "no explorer window")
        ExitApp(0)
    }
    ProbeLog(outPath, "win=" hWin)
    WinRestore("ahk_id " hWin)
    WinActivate("ahk_id " hWin)
    loop 25 {
        if WinActive("ahk_id " hWin)
            break
        Sleep 120
    }
    Sleep 800
    hDU := FindDU(hWin)
    ProbeLog(outPath, "hdu=" hDU " active=" (WinActive("ahk_id " hWin) ? 1 : 0))
    if !hDU {
        ProbeLog(outPath, "no DirectUIHWND")
        ExitApp(0)
    }
    ; 光发 Send {AppsKey} 不行：/select 之后焦点不一定在列表项上。
    ; 先把焦点按到 DirectUIHWND 再发菜单键（实测这样才稳定弹出来）。
    try ControlFocus(hDU, "ahk_id " hWin)
    Sleep 250
    Send "{AppsKey}"
    ProbeLog(outPath, "appskey sent")
    hMenuWin := 0
    loop 30 {
        if (h := WinExist("ahk_class #32768")) {
            hMenuWin := h
            break
        }
        Sleep 200
    }
    ProbeLog(outPath, "menuwin=" hMenuWin)
    hMenu := 0
    if hMenuWin
        DllCall("user32\SendMessageTimeoutW", "Ptr", hMenuWin, "UInt", 0x01E1, "Ptr", 0
            , "Ptr", 0, "UInt", 0x2, "UInt", 1500, "Ptr*", &hMenu)
    ProbeLog(outPath, "hmenu=" hMenu)
    if hMenu
        ProbeLog(outPath, MenuRowsText(ReadMenuLevel(hMenu, 0, 0, 1), 0))
    ; 只在菜单还开着时收尾，免得 Esc 去关掉别的窗口。
    if WinExist("ahk_class #32768")
        Send "{Esc}"
    Sleep 300
    ProbeLog(outPath, "done")
    ExitApp(0)
}

ProbeLog(path, s) {
    try FileAppend s "`n", path, "UTF-8"
}

FindDU(parent) {
    h := 0
    while (h := DllCall("user32\FindWindowExW", "Ptr", parent, "Ptr", h, "Ptr", 0, "Ptr", 0, "Ptr")) {
        try cls := WinGetClass("ahk_id " h)
        catch
            continue
        if (cls = "DirectUIHWND")
            return h
        r := FindDU(h)
        if r
            return r
    }
    return 0
}

MenuRowsText(rows, depth) {
    pad := ""
    loop depth
        pad .= "  "
    out := ""
    for row in rows {
        if row.sep {
            out .= pad "---`n"
            continue
        }
        out .= pad row.label (row.verb != "" ? "  [" row.verb "]" : "") "`n"
        if row.subs.Length
            out .= MenuRowsText(row.subs, depth + 1)
    }
    return out
}

; 撤销探针：--probe restore <场景key> <结果文件>
ProbeRestore(sceneKey, outPath) {
    n := 0
    for root in SceneRoots(sceneKey, "") {
        base := "Software\Classes\" root "\shell"
        reps := ReplicaMap(root)
        for verb, name in reps {
            RegDelTree(base "\" name)
            n++
        }
        for verb in reps {
            try RegDelete "HKCU\" base "\" verb, HIDE_MARK
            try RegDelete "HKCU\" base "\" verb, TAKE_MARK
            ; 删完两个标记后，如果这键本来就是我们建的影子键，它已经空了 → 一并清掉，
            ; 否则残留的空 shell 键会让菜单多出一行没有命令的空白项。
            PruneKey("HKCU\" base "\" verb)
        }
    }
    try FileDelete outPath
    FileAppend "restored=" n, outPath, "UTF-8"
    ExitApp(0)
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
    Chk(FriendlyClsids()["{7ba4c740-9e81-11cf-99d3-00aa004ae837}"] = "发送到"
        && FriendlyClsids()["{d969a300-e7ff-11d0-a93b-00a0c90f2719}"] = "新建"
        && FriendlyClsids()["{1762508c-62c7-4eb9-aa6c-268421c050fa}"] = "上传至ima知识库"
        , "COM 友好名映射", &out, &fails)
    Chk(VisibleItem({ layer: "com", state: "show", extended: false })
        && !VisibleItem({ layer: "verb", state: "show", extended: true })
        && !VisibleItem({ layer: "verb", state: "syshidden", extended: false })
        && !VisibleItem({ layer: "verb", state: "hidden", extended: false })
        , "不可见判定：Extended/已隐藏/系统隐藏都算不可见", &out, &fails)
    Chk(CleanSendToName("Compressed (zipped) Folder.ZFSendToTarget") = "Compressed (zipped) Folder"
        && CleanSendToName("ALTRun.lnk") = "ALTRun"
        && CleanSendToName("Readme") = "Readme", "SendTo 子项名去扩展名", &out, &fails)
    Chk(IsIndirectString("@shell32.dll,-8506") && !IsIndirectString("在此处打开"), "间接串识别", &out, &fails)
    Chk(IsProtectedVerb("open") && IsProtectedVerb("edit") && !IsProtectedVerb("cmd"), "保护 open/edit 动词", &out, &fails)
    Chk(ShadowKey("*", "cmd") = "HKCU\Software\Classes\*\shell\cmd", "verb 影子键只落在 HKCU", &out, &fails)
    Chk(IsSharedClsid("{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}") && !IsSharedClsid("{23170f69-40c1-278a-1000-000100020000}")
        , "系统共享 CLSID 识别、7-Zip 不误判", &out, &fails)
    Chk(ComLabel("7-Zip", "7-Zip Shell Extension") = "7-Zip"
        && ComLabel("{guid}", "ShellContextMenu Class") = "{guid}", "COM 泛显示名回退注册名", &out, &fails)
    ; ── 1.4.0 顺序接管（副本）/ 五列 / 表头排序 ────────────────────────────
    Chk(ReplicaName(2, "cmd") = "p0002#cmd" && ReplicaVerb("p0002#cmd") = "cmd"
        && ReplicaRank("p0002#cmd") = 2
        , "副本键名可逆：p0002#cmd → rank2 + 原 verb", &out, &fails)
    Chk(IsReplicaName("p0001#cmd") && !IsReplicaName("cmd") && !IsReplicaName("p1#cmd")
        && !IsReplicaName("Personalize"), "副本名识别只认 p+四位数字+#", &out, &fails)
    Chk(StripAccel("使用 Visual Studio 打开(&V)") = "使用 Visual Studio 打开"
        && StripAccel("打开(&O)") = "打开" && StripAccel("Powershell(&S)") = "Powershell"
        , "去掉 & 快捷键标记", &out, &fails)
    Chk(SortKeyOf({ ord: 7 }, 1) = "00007" && SortKeyOf({ ord: 12 }, 1) = "00012"
        , "顺序列排序键定长补零（12 排在 7 之后）", &out, &fails)
    gs := SortGroups([{ it: { ord: 3, label: "c", src: "静态", state: "show", pos: "default" }, subs: [] }
        , { it: { ord: 1, label: "a", src: "静态", state: "show", pos: "default" }, subs: [] }
        , { it: { ord: 2, label: "b", src: "静态", state: "show", pos: "default" }, subs: [] }], 1, true)
    Chk(gs[1].it.ord = 1 && gs[2].it.ord = 2 && gs[3].it.ord = 3, "按顺序列升序排组", &out, &fails)
    gd := SortGroups([{ it: { ord: 1, label: "a", src: "静态", state: "show", pos: "default" }, subs: [] }
        , { it: { ord: 2, label: "b", src: "静态", state: "show", pos: "default" }, subs: [] }], 1, false)
    Chk(gd[1].it.ord = 2 && gd[2].it.ord = 1, "同列再点一次反向（降序）", &out, &fails)
    gn := SortGroups([{ it: { ord: 1, label: "b", src: "静态", state: "show", pos: "default" }, subs: [] }
        , { it: { ord: 2, label: "a", src: "静态", state: "show", pos: "default" }, subs: [] }], 2, true)
    Chk(gn[1].it.label = "a" && gn[2].it.label = "b", "按菜单项列排序（中文按 Logical）", &out, &fails)
    Chk(SubStr(SubItem("文件夹", "新建").label, 1, 6) = "    · "
        && SubItem("x", "发送到").layer = "sub", "二级项缩进标记与图层", &out, &fails)
    ; SHGetFileInfoW 对 "x.txt" 这类假文件也能给出本地化类型名（不用建文件）。
    ; 注意它对没有扩展名的 "x" 也会自己编「X 文件」，所以调用方必须自己判空扩展名。
    Chk(ExtTypeName(".txt") != "" && InStr(ExtTypeName(".txt"), ".") = 0
        , "SHGetFileInfo 类型名：拿到本地化类型名（TXT 文件）", &out, &fails)
    Chk(PosRank("top") = 1 && PosRank("default") = 2 && PosRank("bottom") = 3
        && StatusRank("show") = 1 && StatusRank("hidden") = 2 && StatusRank("syshidden") = 3
        && StatusRank("absent") = 4 && StatusText("absent") = "菜单外"
        , "位置/状态排序档位（含「菜单外」）", &out, &fails)
    ; 1.7.0「可改」列：判据必须和 ToggleSelected / MoveVerb / SetHide 的闸门一致，
    ; 否则会出现「列里说能改、点上去被拒」。这里只盖不碰注册表的那几条分支。
    Chk(CapText({ layer: "sub", key: "" }) = "只读"
        && CapText({ layer: "menu", key: "" }) = "只读"
        && CapText({ layer: "com", key: "{x}", shared: true }) = "只读"
        && CapText({ layer: "com", key: "{x}", shared: false }) = "仅隐藏"
        && CapText({ layer: "verb", key: "open" }) = "只读"
        && CapText({ layer: "verb", key: "edit" }) = "只读"
        , "可改列：二级/内建/共享 CLSID/打开动词＝只读，普通 COM＝仅隐藏", &out, &fails)
    ; ── 1.5.0 接管闸门 / 真菜单白名单 ────────────────────────────────────
    ; open 这类内建动词没有 MUIVerb，复制成 p000N#open 会让菜单直接显示键名；
    ; pintohome 自带 MUIVerb，改名安全。这条闸门就是那次真机事故留下的。
    Chk(!CanReplicate("Directory", "open") && !CanReplicate("Folder", "open")
        && CanReplicate("Folder", "pintohome")
        , "接管闸门：无 MUIVerb 的内建动词不复制，有 MUIVerb 的可以", &out, &fails)
    Chk(NormMenuWord("授予访问权限(&G)") = "授予访问权限"
        && NormMenuWord("7-Zip") = "7-zip"
        && NormMenuWord("在新窗口中打开(&E)") = "在新窗口中打开"
        && NormMenuWord("") = "", "真菜单文字归一化：去 & 与尾部加速键", &out, &fails)
    w := Map("授予访问权限", true, "固定到“开始”", true, "打开", true)
    Chk(RealMenuHas(w, "授予访问权限") && RealMenuHas(w, "固定到“开始”屏幕")
        && RealMenuHas(w, "打开") && !RealMenuHas(w, "Safe360Ext")
        && !RealMenuHas(w, "加密"), "真菜单白名单：友好名宽松匹配、菜单外的项判假", &out, &fails)
    ; 「在新窗口中打开」补位：有「打开」当锚点才补，没有就不动（宁可少一行也不错位）。
    tPool := [{ layer: "verb", key: "opennewwindow", label: "在新窗口中打开(&E)", state: "show"
              , pos: "", src: "静态", roots: ["Folder"], extended: false, rank: 0 }]
    tUsed := Map()
    tOut := [{ layer: "verb", key: "open", label: "打开", state: "show"
             , pos: "", src: "静态", roots: ["Folder"], extended: false, rank: 0 }]
    okAnchor := SureBuiltin(tOut, tPool, tUsed, "opennewwindow")
        && tOut.Length = 2 && tOut[2].key = "opennewwindow" && tOut[2].label = "在新窗口中打开"
    Anchor := SureBuiltin([{ layer: "verb", key: "7-Zip", label: "7-Zip" }]
        , [{ layer: "verb", key: "opennewwindow", label: "在新窗口中打开(&E)", state: "show"
           , pos: "", src: "静态", roots: [], extended: false, rank: 0 }], Map(), "opennewwindow")
    Chk(okAnchor && !Anchor, "内建补位：有「打开」做锚点才补，没有就不补", &out, &fails)
    ; ── 1.8.0 新增项 / ShellNew 判据 ──────────────────────────────────────
    Chk(SubStr(CUSTOM_PREFIX "1", 1, StrLen(CUSTOM_PREFIX)) = CUSTOM_PREFIX
        && CUSTOM_PREFIX "1" != "p0001#x", "自定义项键名前缀独立（不撞顺序副本）", &out, &fails)
    Chk(ShellNewHasValue(Map("NullFile", "")) && ShellNewHasValue(Map("FileName", "x"))
        && ShellNewHasValue(Map("Command", "x")) && !ShellNewHasValue(Map("IconPath", "x"))
        && !ShellNewHasValue(Map()), "ShellNew 有效值判据（空键幻影项挡掉）", &out, &fails)
    Chk(StripAccel("使用 Visual Studio 打开(&V)") = "使用 Visual Studio 打开"
        && StripAccel("在此处打开 Powershell 窗口(&S)") = "在此处打开 Powershell 窗口"
        , "加速键 (&X) 从显示名去掉", &out, &fails)
    Chk(ObjScopeLabel("") = "拖入对象" && ObjScopeLabel("C:/a/b.zip") = "zip 文件"
        && ObjScopeLabel(A_ScriptDir) = "文件夹" && ObjScopeLabel("C:/a/README") = "文件"
        , "拖入对象状态栏显示类型（zip 文件/文件夹）", &out, &fails)
    tView := SureViewBuiltins([{ layer: "verb", label: "新建" }], "dirbg")
    tDesk := SureViewBuiltins([], "deskbg")
    Chk(tView.Length = 9 && tView[1].label = "查看" && tView[3].label = "分组依据"
        && tView[6].label = "粘贴" && tView[8].label = "新建" && tView[9].label = "属性"
        && tDesk.Length = 7 && tDesk[4].label = "粘贴" && tDesk[5].label = "撤销 删除"
        && tDesk[6].label = "显示设置" && tDesk[7].label = "个性化"
        && tView[1].src = "内建"
        && SureViewBuiltins([], "obj").Length = 0
        , "背景场景按真实顺序补内建（桌面底部显示设置/个性化，文件夹分组依据/自定义文件夹/属性）", &out, &fails)
    out .= "fails=" fails "`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

; --open <路径>：直接以「拖入对象」场景打开，等于把该文件/文件夹拖进窗口。
; 日常可以用「发送到 → 右键菜单整理」；自动化测试靠它，因为拖放没法合成。
if (A_Args.Length >= 2 && A_Args[1] = "--open") {
    gDropPath := StrReplace(A_Args[2], "/", "\")
    gScene := 1
}

BuildGui()
