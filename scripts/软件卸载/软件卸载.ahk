; ==UserScript==
; @name         软件卸载
; @id           software-uninstall
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.22
; @description  扫描已安装程序，静默卸载并清理注册表与文件残留（Win10/11）
; @author       邱宗满
; @date         2026-11-25
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口：扫描安装清单 → 选中卸载 → 清理残留；--selftest / --report 为无 GUI 分支
; ==/UserScript==
;
; 软件卸载：扫描三处 Uninstall 注册表键得到安装清单，按「静默串 → MSI → 安装器家族 →
; 原样运行」决策链卸载，等待卸载器真正退出后自动扫描残留（文件夹 + 注册表键），
; 清理时文件夹进回收站（可还原）、注册表先导出 .reg 备份再删除。
;
; 技术路线（来源：.ex\软件干净卸载 十项目调研报告 + 文件解锁 1.x 本机实测，见 AGENTS.md）：
;  - 检测：HKLM64 / HKLM32(Wow6432Node) / HKCU 三处 Uninstall 键；过滤 DisplayName 空、
;    SystemComponent=1、ParentKeyName 非空（更新补丁）。
;  - 决策链：QuietUninstallString 优先 → MSI（/I{GUID} 改写 /X{GUID} /qn /norestart）→
;    家族判定（unins\d+\.exe+同名 .dat → Inno /VERYSILENT /SUPPRESSMSGBOXES /NORESTART；
;    update.exe → Squirrel --uninstall --silent；uninst.exe/au_.exe 或文件内扫 Nullsoft
;    → NSIS /S）→ 原始 UninstallString 兜底。卸载串解析用「最长存在的 .exe 前缀」
;    规则（uproot），覆盖带引号/裸/无引号含空格三形态。
;  - 等待：Job Object（CreateJobObject → AssignProcessToJobObject →
;    QueryInformationJobObject 的 ActiveProcesses==0）叠加「注册表键消失 + 4 秒宽限」
;    （UAC 提权子进程会逃出 Job，靠键消失兜底）。SetTimer 状态机驱动，不冻结 UI。
;  - 残留：uproot 启发式——六大目录根 + 三处 Software\<名> + 残留 Uninstall 键；
;    泛用名黑名单（common/data/microsoft…绝不单独匹配）；交叉引用排除（候选与仍安装
;    应用的 InstallLocation/名字相交即跳过）；发行者嵌套（Software\<厂商>\<应用>）；
;    文件夹 >2GB 默认不勾选；reparse point 只算链接本身。
;  - 清理：文件夹 SHFileOperationW 进回收站（失败如实报错，绝不悄悄永久删除）；
;    注册表 reg.exe export 备份到 A_ScriptDir\软件卸载\backup\<时间戳>\ 再 SHDeleteKeyW。
;  - UI 层（UI规范 §10.8 顺序：全局变量 → class FlatScroll → 工具函数 → BuildGui() → 调用；
;    §10.7 黑名单）：填表与《文件解锁》同款——Delete/Add 完直接 Layout + FixCols，
;    全程在同一个消息处理里，不等重绘就不会露出「空列表 + 两条原生灰条」；
;    启动扫描延后到窗口画完首帧再跑（K38：长任务期间定时器不来，同步块里不碰 UI）。
;  - 原生滚动条残影根治（1.0.22）：ListView 挂 WM_NCCALCSIZE 子类（见 LvNcCalcSize），
;    非客户区空间计算时临时摘 WS_VSCROLL/WS_HSCROLL——原生条永远分不到屏幕空间，
;    像素自始画不出来。此前「ShowScrollBar 藏 + InvalidateRect 擦」追着补刀仍留残影，
;    根因：InvalidateRect 只作废客户区，原生灰条像素画在非客户区，事后永远擦不到；
;    且原生竖条一占位，实际客户区瞬间窄 17px、列宽相对超出，还会点亮横向原生条
;    （用户截图：列表底部整条 #808080 横条 + 右缘竖向残块 + 14px 死区）。原有
;    HideNative/Repair/QueueRepair 补刀体系保留作保险丝，从此没有像素可擦。
;  - 安装时间（1.0.6）：InstallDate 只有一半应用填，按「InstallDate → 登记键最后写入
;    时间 → 安装目录创建时间 → 卸载器 exe 创建时间」四档取值，显示口径统一成
;    "YYYY-MM-DD"，不加「约」前缀。
;  - 背景块与内容控件的重绘纪律（1.0.6）：AHK 的 Text 背景块与它的内容控件是兄弟窗口，
;    背景块在 z 序更靠上；若只单独 InvalidateRect 背景块，它会把上面的内容整块盖成
;    纯色（实测：搜索框被 B7C8E0 盖死）。因此 Layout 里只让 Move 自带的失效生效，
;    不单独失效任何背景块/外框。
;  - 走过的弯路（已证伪，别重走）：Restart Manager 在本机 session 句柄恒 0、RmGetList
;    挂起（AHK + Python 双证，见 文件解锁\info\HISTORY.md 1.0.0 段）——本脚本不需要
;    RM，卸载命令直接来自注册表；全系统句柄枚举 90s+；句柄表 Object 字段 Win8+ 恒 0。
;  - 零外部 exe 依赖（reg.exe 是系统自带）、零网络。运行时产物只写 A_ScriptDir\软件卸载\。
;  - 适用 Win10/Win11：所用 API（DWM 34/35/36、SHFileOperationW、Job Object、
;    SHDeleteKeyW、reg.exe）均为 Win7+ 资产；不做 UWP/AppX 卸载（v2 候选，见 AGENTS.md）。

#Requires AutoHotkey v2.0
#SingleInstance Force
; #NoTrayIcon 去掉：宿主 DeckEngine.cpp 用 AHKDECK_NO_TRAY=1 环境变量 + script.cpp patch
; 强制让 g_NoTrayIcon=true，脚本托盘本来就会被压掉。这里写 #NoTrayIcon 反而让脚本完全没有
; 托盘图标，宿主的 tray bridge（script2.cpp patch）没东西可合并，fallback 回 AHK 标准托盘菜单
; （Open/Help/Window Spy/Reload Script/Suspend Hotkeys/Pause Script/Exit Script）。
; 去掉后脚本在宿主内正常显示托盘图标 → 宿主 merge 到自己的托盘。独立运行时脚本会多一个
; 托盘图标（AHK 默认），这是临时妥协，等宿主内托盘菜单消失后再用 A_AhkPath 条件化。
#Warn All, StdOut

; GUI 事件层（按钮 Click 等）抛的异常默认被静默吞掉，表现成「点了按钮没反应」。
; 统一落到脚本目录的 error.log，排查时不用再靠猜。
OnError(LogRuntimeError)
LogRuntimeError(err, mode) {
    global gSelfTestPath
    dir := A_ScriptDir "\软件卸载"
    ; 脚本放在只读目录（Program Files / 只读 U 盘）时这里会失败，退回 %TEMP%。
    if !DirExist(dir)
        try DirCreate dir
    if !DirExist(dir)
        dir := A_Temp
    try {
        FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " err.Message "`n"
            . err.File ":" err.Line " in " err.What "`n" err.Stack "`n`n", dir "\error.log", "UTF-8"
    }
    ; 无 GUI 分支中途崩溃必须落 FAIL 结果并退出码 1（4.txt N7：OnError 返回 1 会
    ; 终止线程，末尾的 FileAppend/ExitApp 不再执行，CI 会看到「无文件 + rc=0」假通过）。
    if (gSelfTestPath != "") {
        try {
            FileAppend "FAIL 无 GUI 分支中途崩溃: " err.Message " @ " err.File ":" err.Line "`nfails=1`n"
                , gSelfTestPath, "UTF-8"
        }
        ExitApp(1)
    }
    return 1        ; 已处理，不再弹默认的错误对话框
}

gSelfTestPath := ""    ; 无 GUI 分支的结果文件路径；非空时中途崩溃也要落 FAIL 结果（4.txt N7）

; ── 常量 ──────────────────────────────────────────────────────────────
FILE_ATTRIBUTE_REPARSE_POINT := 0x400
BIG_FOLDER := 2 * 1024 * 1024 * 1024     ; >2GB 默认不勾选（回收站可能装不下）
FOLDER_SIZE_CAP := 50000                  ; 文件计数上限，超过按"过大"处理
WAIT_TIMEOUT_MS := 600000                 ; 卸载等待上限 10 分钟
GRACE_MS := 4000                          ; 注册表键消失后的宽限（防卸载器收尾开网页干扰）
GRACE_EXIT_MS := 60000                    ; 进程退出但键仍在：给后台收尾 60 秒（2.txt A2——
                                          ; 未提权卸 HKLM 时 stub 退出后提权子进程才刚开始，4 秒
                                          ; 会把刚启动的真卸载误报成「条目仍在」）
JOB_ACTIVE_LIMIT := 100000                ; ActiveProcesses 合理性上限（防御读错结构体）

; ── 版式常量（UI规范 §10.2.3）──────────────────────────────────────────
EDGE := 16                ; 内容行左边距；行宽 = 客户区宽 − 2×EDGE
ROW_W := 640              ; 672 窗的行宽（672 − 32）
BTN_PAD := 16             ; 按钮文字左右各留白
INLINE_GAP := 8           ; 同排控件/按钮之间
BLOCK_GAP := 6            ; 不同语义区块之间（列表区 → 操作行 → 状态条）
H_ACTION := 28            ; 按钮/操作行高
H_STATUS := 30            ; 状态条高
H_HEADER := 26            ; 列头带高（§10.2.3 H_FIELD）
CELL_PAD := 6             ; 区块内文字相对内缘的左内缩（§10.2.3）

; 泛用名黑名单（已按 Norm 归一的小写字母数字 + 中文泛用词）：这些名字绝不能单独作为
; 残留匹配依据（含注册表分支与文件夹分支；3.txt Q19 补中文泛用词）
GENERIC := Map(
    "common", 1, "commonfiles", 1, "shared", 1, "data", 1, "bin", 1,
    "app", 1, "apps", 1, "tools", 1, "update", 1, "updates", 1, "updater", 1,
    "temp", 1, "tmp", 1, "cache", 1, "logs", 1, "plugins", 1,
    "games", 1, "game", 1, "program", 1, "programs", 1, "launcher", 1,
    "setup", 1, "installer", 1, "microsoft", 1, "windows", 1,
    "intel", 1, "amd", 1, "nvidia", 1, "nvidiacorporation", 1,
    "google", 1, "mozilla", 1, "adobe", 1, "apple", 1,
    "packages", 1, "classes", 1, "policies", 1, "clients", 1,
    "wow6432node", 1, "registeredapplications", 1, "system", 1,
    "software", 1, "users", 1, "default", 1, "settings", 1, "config", 1,
    "数据", 1, "缓存", 1, "日志", 1, "公共", 1, "程序", 1, "软件", 1, "工具", 1, "下载", 1)

; ── 全局变量（§10.8 顺序：全局变量 → class → 工具函数 → BuildGui() → 调用）──
gGui := 0, gList := 0, gStatus := 0, gInfo := 0, gScroll := 0
gLvWhite := 0
gLvNcProc := 0         ; ListView 的 WM_NCCALCSIZE 子类回调句柄（1.0.22，根治原生条残影）
gLineTop := 0, gLineBot := 0, gLineLft := 0, gLineRgt := 0
gBand := 0, gHdr1 := 0, gHdr2 := 0, gHdr3 := 0, gHdr4 := 0, gHdr5 := 0, gStBand := 0
gBtnMain := 0, gBtnSub := 0
gSearchFrame := 0, gSearch := 0, gSearchLabel := 0
gApps := []           ; 已安装程序 [{keyPath,name,version,publisher,instDate,location,uninstall,quiet,msi,info}]
gLeft := []           ; 残留项 [{path,isReg,kind,bytes,note,checked}]
gView := []           ; 当前显示行 = gApps/gLeft 经搜索过滤 + 排序后的子集
gSearchText := ""     ; 搜索框内容
gSortCol := 0         ; 0=不排序（自然序），1..5=按第 N 列
gSortDesc := false    ; 列排序方向
gMode := "installed"  ; installed / leftover
gCW := 672, gCH := 386
gUnin := 0            ; 卸载中 {app,job,pid,start,gone}
gLvTracking := false  ; 是否已对列表注册 TME_LEAVE（收到 WM_MOUSELEAVE 后复位）
gLvTipKey := ""       ; 当前悬停提示的单元格 "行.列"（只在换格时重设 ToolTip）

; 读自身头部的 @version（避免版本号在代码里再写一份而漂移）。状态条用它标版本，
; 用户一眼能确认宿主里跑的是哪一版，排查「明明修了还复现」时不用猜。
ScriptVersion() {
    try {
        txt := FileRead(A_LineFile, "UTF-8")
        if RegExMatch(txt, "m)^; @version\s+(\S+)", &m)
            return "v" m[1]
    }
    return ""
}

; ── 自绘滚动条 ──────────────────────────────────────────────────────────
; 1.0.11 起**整类照抄《硬件信息》v2.3.4 的 FlatScroll**（用户指令：滚动条问题久拖，
; 硬件信息在同一宿主里从无白块/残迹/闪条，任何手工微调都会引入偏差，逐字复制）。差异仅三处：
;  ① OnBarWheel 滚动后收掉悬停提示（本脚本 1.0.6 新增的列表悬停功能需要）；
;  ② OnBarKey 不带 Ctrl+C 复制（本脚本无复制功能分支）；
;  ③ 1.0.22 起列表在 BuildGui 里挂 WM_NCCALCSIZE 子类（见 LvNcCalcSize）——原生条从
;     源头分不到非客户区空间，滚动残影根治；本类里各处 HideNative / Repair 补刀逻辑
;     原样保留，降级为保险丝（没有像素可擦，最多空转）。
class FlatScroll {
    __New(g, lv, x, y, w, h, t := 10) {
        this.g := g, this.lv := lv
        this.x := x, this.y := y, this.w := w, this.h := h, this.t := t
        ; 轨道整条宽 t（浅蓝），滑块比轨道窄、居中浮在里面（深蓝）：t=10 → 轨道 10、滑块 4。
        this.tn := Max(3, t - 6), this.off := (t - this.tn) // 2
        ; 两端各让 pad，滑块走到尽头时不会跟列表边框粘成一整块。
        this.pad := 2
        this.lvW := 0, this.lvH := 0, this.itemH := 23
        this.exV := false, this.dead := false
        this.lastV := -1, this.lastCount := -1
        this.rows := 0, this.viewRows := 1, this.top := 0, this.maxTop := 0
        this.ops := [], this.dragging := false
        ; SetTimer 按 FuncObj 的「身份」认定时器：每次 ObjBindMethod 都是新对象，
        ; 拿它去关会关不掉（旧定时器照跑，重复开还会越叠越多）。所以这里绑一次、全程复用。
        this.fnTick := ObjBindMethod(this, "DragTick")
        this.fnSync := ObjBindMethod(this, "Sync")
        this.fnRepair := ObjBindMethod(this, "Repair")
        ; +0x100 是 SS_NOTIFY：不加的静态控件对命中测试返回 HTTRANSPARENT，点击会穿透到父窗口，
        ; 自绘条就永远收不到 WM_LBUTTONDOWN。轨道拆成「滑块前」「滑块后」两段，与滑块永不重叠
        ; —— 叠放时谁在上由 z 序决定，宿主里实测抬到 HWND_TOP 也压不住，索性别让它重叠。
        ; K33 正解①：整条轨道先铺一条**静止**的浅蓝底衬 trackBg，所有可移动色块（vUp/vDn/缝/滑块）
        ; 都叠在它上面。滑块移到新位、轨道段还没补上的那一瞬，露出的永远是这条静止浅蓝，而不是底下的
        ; gLvWhite 纯白——这正是「滑块背后白色块 / 旧滚动条」的来源（打开方式清理没有白底衬，露的是
        ; 接近轨道色的米色，所以不显眼）。trackBg 必须在 vUp 之前建，靠创建顺序天然压在色块下层。
        this.trackBg := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vUp := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vDn := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        ; 滑块两侧各留一条同色细缝，轨道才是连续的一条浅蓝槽（缝与滑块沿轴相邻、几何不重叠）。
        this.vGapL := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapR := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumbV := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        for c in [this.trackBg, this.vUp, this.vDn, this.vGapL, this.vGapR, this.thumbV]
            c.Visible := false
    }

    ; 内容超出才占位，与原生一致：按当前尺寸量一次，超出就缩列表再量，最多三轮收敛。
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
        ; Move() 本身就会让 ListView 重算滚动条并把原生条重新显示（实测样式位被置回），
        ; 循环最后一步正是 Move，所以收尾必须再清一次 —— 否则原生条与自绘条同时出现。
        this.HideNative()
        if (this.lv.GetCount() > 0 && this.lvH > 0) {
            rc := Buffer(16, 0)
            DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x100E, "Ptr", 0, "Ptr", rc, "Ptr")
            ih := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
            if (ih > 0)
                this.itemH := ih
        }
        ; 静止底衬：覆盖整条槽（含滑块位），不随滚动移动。任何色块移动/重排那一瞬露出的都是这条
        ; 浅蓝底衬，而不是底下的 gLvWhite 纯白——从根上消除「滑块背后白色块 / 旧滚动条」。
        if (this.exV) {
            this.trackBg.Move(this.x + this.lvW, this.y, this.t, this.lvH)
            this.trackBg.Visible := true
        } else
            this.trackBg.Visible := false
        this.Repaint()
        this.Paint()
    }

    ; 逐块 SetWindowPos 而不是 DeferWindowPos 批量提交：实测批量提交在「列表刚 Move 完」
    ; 这一拍会整批失败返回 NULL，色块一起保持隐藏 —— 表现为切页后滚动条不出现。
    Put(c, on, x, y, w, h) {
        this.ops.Push({ c: c.Hwnd, on: on && w > 0 && h > 0, x: x, y: y, w: w, h: h })
    }

    Flush() {
        ops := this.ops
        this.ops := []
        if (!ops.Length)
            return
        ; 原子提交（K33 正解②）：BeginDeferWindowPos 排好全部色块、EndDeferWindowPos 一次
        ; 刷上屏，滑块与轨道段同帧到位，不留「滑块已移走、轨道还没补上」的中间帧——那正是
        ; 滚动条拖影的根因。1.0.11 起退化成逐个 SetWindowPos 是为绕开「列表刚 Move 完 Defer
        ; 整批失败返回 NULL」，代价就是滚动拖影。这里优先 Defer，仅当批量真失败才回退逐个。
        h := DllCall("user32\BeginDeferWindowPos", "Int", ops.Length, "Ptr")
        if (h) {
            done := true
            for o in ops {
                if (o.on)
                    h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", o.c, "Ptr", 0
                        , "Int", o.x, "Int", o.y, "Int", o.w, "Int", o.h, "UInt", 0x0054, "Ptr")
                else
                    h := DllCall("user32\DeferWindowPos", "Ptr", h, "Ptr", o.c, "Ptr", 0
                        , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0097, "Ptr")
                if (!h) {
                    done := false
                    break
                }
            }
            if (done && DllCall("user32\EndDeferWindowPos", "Ptr", h, "Ptr")) {
                ; 原子定位后按 ops 顺序（vUp/vDn 浅蓝轨道在前、thumbV 深蓝滑块最后）逐块同步重画。
                ; 只 InvalidateRect 不够：色块移走后腾出的旧滑块位显示的是屏幕上原来的深蓝像素，
                ; 重画要等宿主空闲的 WM_PAINT，连续滚动时主线程忙、WM_PAINT 挤不进来，旧深蓝就停在
                ; 屏上（用户报的拖影）。紧跟 UpdateWindow 强制同步重画，于是旧滑块位先被浅蓝轨道盖掉、
                ; 滑块再画到新位，不留深蓝残影。resize 新增区也靠这一步补画（1.0.12 白块）。
                for o in ops
                    if (o.on) {
                        DllCall("user32\InvalidateRect", "Ptr", o.c, "Ptr", 0, "Int", 1)
                        DllCall("user32\UpdateWindow", "Ptr", o.c)
                    }
                return
            }
        }
        ; 回退：批量提交真失败（如列表刚 Move 完）时逐个 SetWindowPos，同样逐块同步重画。
        for o in ops {
            if (o.on) {
                DllCall("user32\SetWindowPos", "Ptr", o.c, "Ptr", 0, "Int", o.x, "Int", o.y
                    , "Int", o.w, "Int", o.h, "UInt", 0x0054, "Ptr")
                DllCall("user32\InvalidateRect", "Ptr", o.c, "Ptr", 0, "Int", 1)
                DllCall("user32\UpdateWindow", "Ptr", o.c)
            } else
                DllCall("user32\ShowWindow", "Ptr", o.c, "Int", 0)
        }
    }

    TrackLen() {
        return this.lvH - this.pad * 2
    }

    ; 滑块位置每帧从真实首行号反算，任何来源的滚动都在下一拍自动对齐；
    ; 轨道两段随滑块重算，滑块与轨道之间永远没有空隙。
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

    ; ShowScrollBar 只是「按需要隐藏」，ListView 每次重算滚动范围（Move/Add/Delete/
    ; ModifyCol）都会把它自己那份置回来，所以这是每次动作后都要补一刀的操作。
    ; 返回 true = 这一拍真的发现了被置回的原生条（说明列表在 ScrollToRow 之外
    ; 滚过或重排过），调用方据此决定要不要擦像素。
    EnsureHidden() {
        try {
            v := DllCall("user32\GetWindowLongW", "Ptr", this.lv.Hwnd, "Int", -16, "Int")
            if (v & 0x00300000) {
                this.HideNative()
                return true
            }
        }
        return false
    }

    HideNative() {
        ; 1.0.20 对齐《打开方式清理》（无残留参照）：只摘样式位，不做 SWP_FRAMECHANGED、不刷
        ; CoverNative。摘样式位后原生条区域并入客户区，露出的灰条由调用方（ScrollToRow / Sync /
        ; Repair）紧随其后的 InvalidateRect(lv,NULL,FALSE)+UpdateWindow(lv) 整块重绘盖掉——参照
        ; 正是这么做的。1.0.14 加的 SWP_FRAMECHANGED 每次滚动都强制 ListView 重算非客户区、重新
        ; 评估滚动条，反而让原生条闪现；CoverNative 在本窗口无边框 ListView 上是空操作。
        DllCall("user32\ShowScrollBar", "Ptr", this.lv.Hwnd, "Int", 1, "Int", 0)
        DllCall("user32\ShowScrollBar", "Ptr", this.lv.Hwnd, "Int", 0, "Int", 0)
    }

    ; 兜底擦像素：comctl32 点亮原生条那一刻已经把灰条画进非客户区，
    ; ShowScrollBar(FALSE) 只摘样式位、不擦像素。整块作废重画（NULL + 不擦背景，
    ; K50）把灰条像素盖掉；首行号变了顺手对齐滑块。
    Repair() {
        if (this.dead || !this.lv.Hwnd)
            return
        this.HideNative()
        DllCall("user32\InvalidateRect", "Ptr", this.lv.Hwnd, "Ptr", 0, "Int", false)
        DllCall("user32\UpdateWindow", "Ptr", this.lv.Hwnd)
        v := this.ReadTop()
        if (v != this.top) {
            this.top := v
            this.Paint()
        }
    }

    ; 交给本线程消息循环的下一拍执行：OnMessage 回调跑在 ListView 处理这条
    ; 键/点击之前，等它滚完再擦才擦得到它画出来的灰条。负周期 = 只触发一次。
    QueueRepair() {
        SetTimer(this.fnRepair, -1)
    }

    Measure() {
        this.rows := this.lv.GetCount()
        this.top := this.ReadTop()
        ; LVM_GETCOUNTPERPAGE 给真实「每页行数」：按 lvH/itemH 估算会少算列表底部那
        ; 半行，导致滚到底时下沿露出一条空白，滑块也差一截到不了头。
        n := DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1028, "Ptr", 0, "Ptr", 0, "Ptr")
        this.viewRows := Max(1, n ? n : Floor(this.lvH / this.itemH))
        this.maxTop := Max(0, this.rows - this.viewRows)
        this.exV := this.rows > this.viewRows
    }

    ReadTop() {
        return DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1027, "Ptr", 0, "Ptr", 0, "Ptr")
    }

    ; 滚动配方照抄《打开方式清理》1.5.x（1.0.13）：LVM_SCROLL 双压实测仍拦不住滚动
    ; 那一拍的原生灰条（用户截图：右缘中部留一截灰色原生滑块）。改用 LVM_ENSUREVISIBLE：
    ; 向下滚 ENSURE 视区末行、向上滚 ENSURE 目标行；摘样式位后仍精确到位，滚完当场
    ; 再 HideNative + 整块作废重画消位块拷贝残影。
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
        ; 原生灰条于是露出来（打开方式清理实测：滚动后右侧出现 16px 的 F0F0F0）。
        ; 不能等 Sync 的 60ms 兜底——每次滚动动作后必须当场再藏一次。
        this.HideNative()
        ; 再整块重画：ENSUREVISIBLE 靠位块拷贝搬旧像素，交界处会留半截文字。
        ; FALSE = 不擦背景只作废区域，不会闪；参数必须 NULL（整个客户区）。
        DllCall("user32\InvalidateRect", "Ptr", this.lv.Hwnd, "Ptr", 0, "Int", false)
        DllCall("user32\UpdateWindow", "Ptr", this.lv.Hwnd)
        this.top := this.ReadTop()
        this.Paint()
    }

    ; ★隐藏原生条后 ListView 自己算不准需要重绘的范围：滚动或切页后常留一整块没画到的
    ; 区域。这里只 RDW_INVALIDATE|RDW_UPDATENOW，**不能带 RDW_ERASE** —— 带 ERASE 会
    ; 先把客户区擦成父窗口底色再画，每次滚轮（哪怕已经没有可滚内容）都会闪一下白。
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

    ClientW() {
        return this.lvW
    }

    ; len 滑块长度、start 滑块起点、span 滑块可用行程
    Geo(trackLen) {
        len := Max(24, Min(trackLen, Round(trackLen * this.viewRows / Max(1, this.rows))))
        span := trackLen - len
        frac := (this.maxTop > 0) ? this.top / this.maxTop : 0
        return { len: len, start: Round(frac * span), span: span }
    }

    ; 滑块只有 6px，两侧 2px 的缝也算热区（与系统一致：整条槽宽都能抓）。
    OnDown(hwnd) {
        if (hwnd = this.thumbV.Hwnd || hwnd = this.vGapL.Hwnd || hwnd = this.vGapR.Hwnd)
            this.BeginDrag()
        else if (hwnd = this.vUp.Hwnd || hwnd = this.vDn.Hwnd)
            this.PageJump()
    }

    ; 槽上空白处翻一页，方向按鼠标落在滑块前还是后来判断。
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

    ; 拖动用轮询而不是 SetCapture + 鼠标消息：Text 控件只在抬起时给一次 Click，
    ; 拿不到中途移动，轮询 GetCursorPos 反而稳。
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

    ; 键盘翻页、滚轮、拖动都会改首行号，统一在这一拍对齐滑块；
    ; 顺手兜一次原生条。拖动中只兜原生条、不重排色块（DragTick 已在画，两处交叉就是断点）。
    Sync() {
        if (this.dead)
            return
        try {
            ; 这一拍抓到被置回的原生条 = 列表在 ScrollToRow 之外滚过或重排过：
            ; 灰条像素此刻已经在屏上，光摘样式位擦不掉（1.0.14）。补一次整块
            ; 作废重画，否则那 17px 灰条会一直留到下次整表重绘。
            if (this.EnsureHidden()) {
                DllCall("user32\InvalidateRect", "Ptr", this.lv.Hwnd, "Ptr", 0, "Int", false)
                DllCall("user32\UpdateWindow", "Ptr", this.lv.Hwnd)
            }
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

    ; 定时器会让脚本在窗口关闭后继续存活，必须显式停掉。
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

; ── 原生滚动条根治（1.0.22）：ListView 的 WM_NCCALCSIZE 子类 ──────────
; 机理：comctl32 每次重算滚动范围（Move / ModifyCol / 增删行 / ENSUREVISIBLE /
; 键盘滚动）都会把 WS_VSCROLL / WS_HSCROLL 重新点亮，原生灰条像素画进**非客户区**。
; 而事后补救工具 InvalidateRect(lv, NULL, FALSE) 只作废**客户区**——非客户区里的
; 灰条像素一个都擦不到，这就是 1.0.11~1.0.21 十版「藏完再追着擦」仍偶发残影的根因
; （截图实证：自绘滑块旁 #808080 竖向残块 + 列表底部整条 #808080 横条；横条是原生
; 竖条占位后实际客户区瞬间窄 17px、列宽总和相对超出、横向原生条被点亮）。
; 解法：在「非客户区空间计算」这一层动手——WM_NCCALCSIZE 到达时临时摘掉两个滚动条
; 样式位再走默认计算，算完恢复。原生条于是永远分不到一寸屏幕空间，一个像素也画不出
; 来；comctl32 之后爱怎么置回样式位都无所谓。滚动功能不受影响：滚动位置/范围走
; SetScrollInfo，与滚动条视觉是两套机制，LVM_ENSUREVISIBLE / LVM_SCROLL 照常工作。
; 这是 Win32 经典技法（SO「hide scrollbar but keep scrolling」的标准答案）。SetWindowLongW
; 改样式位不会触发新一轮 NCCALCSIZE（那需要 SWP_FRAMECHANGED），无递归风险。
; 旧的 HideNative / Repair / QueueRepair「追着擦」体系全部保留作保险丝——从此它们
; 没有像素可擦，最多空转。
LvNcCalcSize(hwnd, msg, wParam, lParam, idSubclass, refData) {
    ; 0x0083 = WM_NCCALCSIZE；wParam=1 才是「计算客户区」形态（=0 的旧形态直接放行）。
    if (msg = 0x0083 && wParam) {
        v := DllCall("user32\GetWindowLongW", "Ptr", hwnd, "Int", -16, "Int")
        ; 0x00300000 = WS_HSCROLL(0x100000) | WS_VSCROLL(0x200000)；有才需要摘。
        if (v & 0x00300000) {
            ; 摘位 → 默认计算（客户区不含滚动条槽）→ 恢复样式位 → 原样返回。
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

HookBarInput() {
    OnMessage(0x201, OnBarDown)
    OnMessage(0x20A, OnBarWheel)
    OnMessage(0x100, OnBarKey)
    OnMessage(0x204, OnBarRDown)
}
OnBarDown(wp, lp, msg, hwnd) {
    global gScroll, gList
    if (gScroll && !gScroll.dead)
        gScroll.OnDown(hwnd)
    ; 点在列表上可能让 comctl32 为「把选中行露出来」自己滚一下并点亮原生条，
    ; 等这条消息处理完立刻补一刀擦像素（OnMessage 回调跑在 ListView 之前）。
    if (gScroll && !gScroll.dead && gList && hwnd = gList.Hwnd)
        gScroll.QueueRepair()
}

; 硬件信息 的 HookBarInput 原文挂了 0x204（右键）并回调 OnBarRDown；那边靠它做
; 「右键行弹复制菜单」（依赖 RowAt/SelectRow/ShowCopyMenu，本脚本没有）。这里保留
; 空实现托住挂钩，行为与未挂时一致。
OnBarRDown(wp, lp, msg, hwnd) {
    global gList
    if (!gList || hwnd != gList.Hwnd)
        return
    return 1
}
OnBarWheel(wp, lp, msg, hwnd) {
    global gScroll, gGui, gLvTipKey
    if (!gScroll || gScroll.dead)
        return
    delta := (wp >> 16) & 0xFFFF
    if (delta & 0x8000)
        delta := delta - 0x10000
    ; 原生条被摘掉后 ListView 自己不再处理滚轮，落在窗口任意位置都转给列表。
    ; 注意 IsChild(parent, parent) 返回假：鼠标压在窗口空白处时消息的 hwnd 就是
    ; 主窗口本身，漏掉这一支那一片区域就滚不动。
    if (gGui.Hwnd && (hwnd = gGui.Hwnd || DllCall("user32\IsChild", "Ptr", gGui.Hwnd, "Ptr", hwnd))) {
        gScroll.OnWheelDelta(delta)
        ; 滚完再排一次擦像素：ENSUREVISIBLE 会让 comctl32 在本条消息之后还补一次
        ; 滚动条重算，那一拍可能又把原生条画出来（实测滚轮后 50ms 仍能采到 F0F0F0）。
        gScroll.QueueRepair()
        ; 滚完原来的悬停格已换成别的行，提示立刻收掉（鼠标没动就不会再来 WM_MOUSEMOVE）。
        if (gLvTipKey != "") {
            gLvTipKey := ""
            ToolTip()
        }
        return 1
    }
}
OnBarKey(wp, lp, msg, hwnd) {
    global gScroll, gList
    if (!gScroll || gScroll.dead || !gList || hwnd != gList.Hwnd)
        return
    if (gScroll.OnKey(wp))
        return 1
    ; ↑/↓ 等键由 ListView 自己处理：它会滚动并把原生条点亮、当场画出灰条。
    ; 不拦（拦了选中行就动不了），但等这条消息处理完补一刀擦掉像素。
    gScroll.QueueRepair()
}

; ── 列表悬停提示：被列宽截断的单元格浮出完整文本（用户要求 2/3 列收窄后仍可看全）──
; 判据用 MeasureTextWidth 实量：只有「文本宽 > 列宽 − 内边距」才弹，没截断不打扰。
; 只有切到别的单元格才重设 ToolTip，避免每次 WM_MOUSEMOVE 都把提示顶回起点。
HookListHover() {
    OnMessage(0x200, OnLvHover)         ; WM_MOUSEMOVE
    OnMessage(0x2A3, OnLvHoverLeave)    ; WM_MOUSELEAVE
}
OnLvHover(wp, lp, msg, hwnd) {
    global gList, gLvTracking, gLvTipKey
    if (!IsObject(gList) || hwnd != gList.Hwnd)
        return
    if (!gLvTracking) {
        gLvTracking := true
        ; TRACKMOUSEEVENT{cbSize, TME_LEAVE, hwndTrack, dwHoverTime}
        tme := Buffer(24, 0)
        NumPut("UInt", 24, tme, 0), NumPut("UInt", 2, tme, 4), NumPut("Ptr", hwnd, tme, 8)
        DllCall("user32\TrackMouseEvent", "Ptr", tme)
    }
    ; 0x1039 = LVM_SUBITEMHITTEST：★返回值是 0 基**行**号，不是列号（MSDN 文案有坑，
    ; 本机实测 (306,11) 落在第 1 行第 3 列时返 0、iSubItem=2）。列号从 LVHITTESTINFO
    ; 的 iSubItem 取：pt(0..7)、flags(8)、iItem(12)、iSubItem(16)、iGroup(20)。
    info := Buffer(24, 0)
    cx := lp & 0xFFFF, cy := (lp >> 16) & 0xFFFF
    if (cx > 0x7FFF)
        cx -= 0x10000
    if (cy > 0x7FFF)
        cy -= 0x10000
    NumPut("Int", cx, info, 0), NumPut("Int", cy, info, 4)
    ; ★返回类型必须是 Int：该消息未命中时返回 -1，用 Ptr 接会变成无符号大数，
    ;   `sub < 0` 判断失效，后面按超长列号取值直接把提示吞掉。
    sub := DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0x1039, "Ptr", 0, "Ptr", info, "Int")
    if (sub < 0) {
        if (gLvTipKey != "") {
            gLvTipKey := ""
            ToolTip()
        }
        return
    }
    row := sub + 1, col := NumGet(info, 16, "Int") + 1
    if (col < 1)
        return
    key := row "." col
    if (key = gLvTipKey)
        return
    gLvTipKey := key
    txt := ""
    try txt := gList.GetText(row, col)
    colW := DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0x101D, "Ptr", col - 1, "Ptr", 0, "Int")
    tip := CellTip(txt, colW)
    if (tip = "") {
        ToolTip()
        return
    }
    ; 不给坐标：AHK 把提示摆在鼠标当前位置，省掉 Screen/Client 坐标口径之争。
    ToolTip(tip)
}
OnLvHoverLeave(wp, lp, msg, hwnd) {
    global gList, gLvTracking, gLvTipKey
    if (!IsObject(gList) || hwnd != gList.Hwnd)
        return
    gLvTracking := false, gLvTipKey := ""
    ToolTip()
}

; 单元格是否被列宽截断：截断则返回原文（给 ToolTip），否则空串。
CellTip(text, colW, pad := 12) {
    if (text = "" || colW <= pad)
        return ""
    return MeasureTextWidth(text) > colW - pad ? text : ""
}

; ── 纯函数（selftest 直接覆盖）────────────────────────────────────────

; 运行环境守卫：强制 64 位解释器（2.txt#5）。32 位下 HKLM\SOFTWARE 会被重定向到
; Wow6432Node——三源清单重复、64 位产品漏扫，RegKeyExists 还会把 64 位登记误判成
; 「键不存在」，卸载刚启动 4 秒宽限一过就误报「已卸载」。位数不对直接拒绝运行。
; 位数不对直接拒绝运行。N6（1.txt，发版前必修）：--selftest/--report 走无 GUI 分支时
; 绝不能弹 MsgBox——CI/服务/计划任务没有桌面，弹框会卡死进程；且 ExitApp(0) 让 CI 看到
; rc=0 + 无结果文件的"假通过"。无 GUI 时把 FAIL 写进结果文件并以退出码 1 结束。
CheckRuntime(guiMode := true, resultPath := "") {
    if (A_PtrSize != 8) {
        if (guiMode) {
            MsgBox("本脚本需要 64 位 AutoHotkey 运行。`n32 位解释器会把 HKLM\SOFTWARE 重定向到"
                . " Wow6432Node，导致安装清单漏扫与「已卸载」误判。", "软件卸载", 0x10)
        } else if (resultPath != "") {
            try FileAppend("FAIL 需要 64 位 AutoHotkey（当前 32 位）`nfails=1`n", resultPath, "UTF-8")
        }
        ExitApp(guiMode ? 0 : 1)
    }
    return A_IsAdmin
}

; 归一：小写 + 只留字母/数字/常用汉字（英文工具的 foobar 匹配 + 中文应用名可直接对上）
Norm(s) {
    s := StrLower(s)
    return RegExReplace(s, "[^0-9a-z一-龥]")
}

; 清洗显示名：去括注 (x64)/(64-bit)、点分版本号，Trim 标点。"Fallout 4" 的单个数字保留。
CleanName(s) {
    s := RegExReplace(s, "\(([^)]*)\)")
    s := RegExReplace(s, "\b\d+(\.\d+)+\b")
    s := RegExReplace(s, "(?i)\b(x64|x86|64bit|32bit)\b")
    return Trim(s, " ,.-_()·")
}

; 泛用名判定（入参必须是 Norm 后的串）
IsGenericNorm(n) {
    return GENERIC.Has(n)
}

InArray(arr, v) {
    for x in arr
        if (x = v)
            return true
    return false
}

PathLeaf(p) {
    SplitPath p, &nm
    return nm
}

; ── MSI 产品码 ────────────────────────────────────────────────────────
; GUID 只认 msiexec /I{ 或 /X{ 后面的（2.txt A3：任意位置的 {8-4-4-4-12} 串可能是
; 路径名或普通参数，误判会把非 MSI 安装器改写成 msiexec /X 静默失败）。
; 门控在上层：仅当串含 msiexec 或 WindowsInstaller=1 时才调用本函数。
ExtractMsiGuid(s) {
    if RegExMatch(s, "i)/[IX]\s*(\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\})", &m)
        return m[1]
    return ""
}

BuildMsiCommand(guid) {
    return "msiexec.exe /X" guid " /qn /norestart"
}

; ── 卸载串解析（uproot 三形态规则）────────────────────────────────────
; 返回 [file, args]。带引号直接取；无引号路径含空格时取"最长且真实存在的 .exe 前缀"。
SplitCommand(cmd) {
    cmd := Trim(cmd)
    if (SubStr(cmd, 1, 1) = '"') {
        end := InStr(cmd, '"', false, 2)
        if (end > 1)
            return [SubStr(cmd, 2, end - 2), Trim(SubStr(cmd, end + 1))]
    }
    if (InStr(cmd, ":") || SubStr(cmd, 1, 2) = "\\") {
        at := 0
        loop {
            at := InStr(cmd, ".exe", false, at + 1)
            if (at = 0)
                break
            exeFile := SubStr(cmd, 1, at + 3)
            nxt := SubStr(cmd, at + 4, 1)
            ; 分隔符只认串尾/空格/制表符（3.txt Q6：「.exe"/S」紧贴引号、「.exe\t/S」
            ; 制表符分隔会落到按空格切分的错误分支）。
            if (nxt = "" || nxt = " " || nxt = "`t")
                if (FileExist(exeFile) || InStr(cmd, ".exe", false, at + 4) = 0)
                    return [exeFile, Trim(SubStr(cmd, at + 4))]
        }
    }
    sp := InStr(cmd, " ")
    return (sp = 0) ? [cmd, ""] : [SubStr(cmd, 1, sp - 1), Trim(SubStr(cmd, sp + 1))]
}

; ── 安装器家族判定 ────────────────────────────────────────────────────
; 返回 "Inno"/"Squirrel"/"NSIS"/""。先看文件名（快），NSIS 只能扫文件内容（限 128KB）。
DetectFamily(file) {
    SplitPath file, &nm
    low := StrLower(nm)
    if RegExMatch(nm, "i)^unins\d+\.exe$") {
        dat := SubStr(file, 1, StrLen(file) - 3) "dat"
        if FileExist(dat)
            return "Inno"
    }
    if (low = "update.exe")
        return "Squirrel"
    if (low = "uninst.exe" || low = "au_.exe")
        return "NSIS"
    try {
        f := FileOpen(file, "r", "CP0")
        if f {
            n := Min(f.Length, 131072)
            s := f.Read(n)
            f.Close()
            if InStr(s, "Nullsoft")
                return "NSIS"
        }
    }
    return ""
}

ExpandEnv(s) {
    n := DllCall("kernel32\ExpandEnvironmentStringsW", "Str", s, "Ptr", 0, "UInt", 0, "UInt")
    if (n <= 0)
        return s
    buf := Buffer(n * 2, 0)
    DllCall("kernel32\ExpandEnvironmentStringsW", "Str", s, "Ptr", buf, "UInt", n, "UInt")
    return StrGet(buf, n - 1, "UTF-16")
}

; ── 静默命令决策链 ────────────────────────────────────────────────────
; 返回 {cmd, kind, note}。kind: quiet/msi/inno/nsis/squirrel/raw/gone/none
DecideCommand(a) {
    if (a.quiet != "") {
        ; QuietUninstallString 是发行商手写的，不无条件信任（1.txt#3 / 3.txt Q3）：
        ; 可能指向已删除的文件、网页 URL 或交互式程序。校验通过才走 quiet，
        ; 否则回落常规决策链（uninstall 串可能仍可用），不直接报 gone。
        qfull := ExpandEnv(a.quiet)
        q := SplitCommand(qfull)
        qf := q[1]
        ; N1（4.txt）：相对 exe 名按安装目录拼成绝对路径再校验（Squirrel 常见写法
        ; "Update.exe" --uninstall 依赖工作目录，不解析会在脚本目录/PATH 里找错）。
        qAbs := ""
        if (qf != "" && !InStr(qf, "\") && a.location != "") {
            cand := RTrim(a.location, "\") "\" qf
            if FileExist(cand)
                qAbs := cand
        }
        ; 裸命令只放行已知宿主（4.txt Q3：任意不含反斜杠的裸名一律降级 raw）
        bareOK := (qf != "" && !InStr(qf, "\") && QuietBareHost(qf))
        pathOK := (InStr(qf, "\") && FileExist(qf)) || (qAbs != "")
        ; QuietUnsafe 扫整条命令（含参数里的 URL/网页，2.txt A3 同源问题）
        if ((pathOK || bareOK) && !QuietUnsafe(qfull)) {
            cmd := (qAbs != "") ? ('"' qAbs '" ' q[2]) : a.quiet
            note := (qAbs != "") ? "注册表自带静默串（相对名已按安装目录解析）" : "注册表自带静默串"
            return {cmd: cmd, kind: "quiet", note: note}
        }
    }
    if (a.msi != "")
        return {cmd: BuildMsiCommand(a.msi), kind: "msi", note: "MSI 静默卸载"}
    if (a.uninstall = "")
        return {cmd: "", kind: "none", note: "无卸载器"}
    full := ExpandEnv(a.uninstall)
    parts := SplitCommand(full)
    exeFile := parts[1]
    ; N1：相对 exe 名按安装目录解析成绝对路径（同 Quiet 分支）
    if (exeFile != "" && !InStr(exeFile, "\") && a.location != "") {
        cand := RTrim(a.location, "\") "\" exeFile
        if FileExist(cand)
            exeFile := cand
    }
    if (exeFile = "" || (!FileExist(exeFile) && InStr(exeFile, "\"))) {
        return {cmd: a.uninstall, kind: "gone", note: "卸载器文件缺失"}
    }
    if (InStr(exeFile, "\") && FileExist(exeFile)) {
        fam := DetectFamily(exeFile)
        if (fam = "Inno")
            return {cmd: '"' exeFile '" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART', kind: "inno", note: "InnoSetup 静默"}
        if (fam = "Squirrel") {
            if SquirrelOwned(exeFile, a)
                return {cmd: '"' exeFile '" --uninstall --silent', kind: "squirrel", note: "Squirrel 静默"}
            ; 1.txt N3：update.exe 无归属证据时不能落 raw 原样运行——无参数运行
            ; update.exe 是「检查更新」而非卸载，单独分类让用户明确知情。
            return {cmd: a.uninstall, kind: "upd", note: "update.exe 无归属证据（可能是更新器，非卸载器）"}
        }
        if (fam = "NSIS")
            return {cmd: '"' exeFile '" /S', kind: "nsis", note: "NSIS 静默"}
    }
    return {cmd: a.uninstall, kind: "raw", note: "按注册表原样运行"}
}

; Quiet 串的裸命令宿主白名单（4.txt Q3）：msiexec/rundll32 等系统宿主放行，
; 其余不含反斜杠的裸名（可能是二合一程序、写错的文件名）一律降级 raw。
QuietBareHost(qf) {
    low := StrLower(qf)
    return low = "msiexec.exe" || low = "msiexec" || low = "rundll32.exe" || low = "rundll32"
        || low = "cmd.exe" || low = "cmd" || low = "powershell.exe" || low = "powershell"
        || low = "wscript.exe" || low = "wscript" || low = "cscript.exe" || low = "cscript"
        || low = "regsvr32.exe" || low = "regsvr32"
}

; QuietUninstallString 指向网页/含 URL 参数时不静默执行（3.txt Q3 + 2.txt A3：
; 只查 exeFile 漏掉参数里的 URL——改扫整条命令）
QuietUnsafe(cmd) {
    low := StrLower(cmd)
    if InStr(low, "http://") || InStr(low, "https://") || RegExMatch(low, "(^|\s)www\.")
        return true
    if RegExMatch(low, '\.(htm|html|mhtml)(\s|"|$)')
        return true
    return false
}

; Squirrel 归属证据（3.txt Q10 高危：update.exe 同名误伤）——update.exe 必须位于
; 该应用自己的安装目录内，否则不判 Squirrel、回落原样运行。
SquirrelOwned(exeFile, a) {
    loc := StrLower(RTrim(a.location, "\"))
    if (loc = "")
        return false
    dir := ""
    SplitPath exeFile, , &pdir
    dir := StrLower(RTrim(pdir, "\"))
    return Within(dir, loc)
}

; 安装清单状态列文案
StatusText(a) {
    k := a.info.kind
    if (k = "quiet")
        return "静默串"
    if (k = "msi")
        return "MSI 静默"
    if (k = "inno")
        return "Inno 静默"
    if (k = "nsis")
        return "NSIS 静默"
    if (k = "squirrel")
        return "Squirrel 静默"
    if (k = "upd")
        return "疑似更新器"
    if (k = "raw")
        return "交互卸载"
    if (k = "gone")
        return "卸载器缺失"
    return "无卸载器"
}

; ── 残留匹配辅助 ──────────────────────────────────────────────────────

; 应用名/安装目录尾段 归一后的强匹配名
; 阈值 2/3（1.txt#5）：微信/QQ/钉钉等 2 字符应用此前被完全排除，残留一个都扫不到；
; 误匹配风险由泛用名黑名单 + 交叉引用排除兜住。
StrongNames(a) {
    arr := []
    n := Norm(CleanName(a.name))
    if (StrLen(n) >= 2)
        arr.Push(n)
    loc := RTrim(a.location, "\")
    if (loc != "") {
        t := Norm(PathLeaf(loc))
        if (StrLen(t) >= 3 && !IsGenericNorm(t) && !InArray(arr, t))
            arr.Push(t)
    }
    return arr
}

; 发行者归一（<3 字符或与名相同 → 不用于嵌套匹配）
PubNorm(a) {
    p := Norm(CleanName(a.publisher))
    if (StrLen(p) < 3 || p = Norm(CleanName(a.name)))
        return ""
    return p
}

; a 在 b 内（含相等），路径两侧须已小写、去尾部 \
Within(a, b) {
    la := StrLen(a), lb := StrLen(b)
    if (la < lb || lb = 0)
        return false
    if (SubStr(a, 1, lb) != b)
        return false
    return (la = lb || SubStr(a, lb + 1, 1) = "\")
}

BackslashCount(s) {
    return StrLen(s) - StrLen(StrReplace(s, "\"))
}

; ═════════════════════════════════════════════════════════════════════
;  安装清单扫描
; ═════════════════════════════════════════════════════════════════════

RegReadSafe(key, name) {
    try
        return RegRead(key, name, "")
    catch
        return ""
}

; 安装时间：注册表 InstallDate 多为 "YYYYMMDD"（REG_SZ 或 DWORD 转成的 8 位串）。
; 解析成 "YYYY-MM-DD" 便于排序（字典序即时间序）；缺失或非 8 位数字返回空串。
FormatInstallDate(s) {
    s := Trim(s)
    if (StrLen(s) = 8 && s ~= "^\d{8}$")
        return SubStr(s, 1, 4) "-" SubStr(s, 5, 2) "-" SubStr(s, 7, 2)
    return ""
}

; FILETIME → 本地日期 "YYYY-MM-DD"（注册表键时间、文件时间共用）。
; 注册表里存的是 UTC，先转本地再取年月日，否则东八区凌晨装的会显示成前一天。
FileTimeDate(ftPtr) {
    localFt := Buffer(8, 0), st := Buffer(16, 0)
    if !DllCall("kernel32\FileTimeToLocalFileTime", "Ptr", ftPtr, "Ptr", localFt)
        return ""
    if !DllCall("kernel32\FileTimeToSystemTime", "Ptr", localFt, "Ptr", st)
        return ""
    y := NumGet(st, 0, "UShort"), m := NumGet(st, 2, "UShort"), d := NumGet(st, 6, "UShort")
    if (y < 1990)                      ; 0 值/脏值（1601）不当成安装时间
        return ""
    return Format("{:04d}-{:02d}-{:02d}", y, m, d)
}

; 卸载登记键的「最后写入时间」：本机 136 条清单里 136 条都有，是 InstallDate 缺失时
; 最可靠的一档兜底（键随安装创建，之后除升级/修复很少再动）。
RegKeyDate(k) {
    parts := RegSplit(k)
    if (parts[1] = 0)
        return ""
    h := 0
    if (DllCall("advapi32\RegOpenKeyExW", "Ptr", parts[1], "Str", parts[2]
        , "UInt", 0, "UInt", 0x20019, "Ptr*", &h, "Int") != 0)
        return ""
    ft := Buffer(8, 0)
    rc := DllCall("advapi32\RegQueryInfoKeyW", "Ptr", h, "Ptr", 0, "Ptr", 0, "Ptr", 0
        , "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0
        , "Ptr", ft, "Int")
    DllCall("advapi32\RegCloseKey", "Ptr", h)
    return (rc = 0) ? FileTimeDate(ft) : ""
}

; 路径（文件或目录）的创建时间，再下一档兜底。
PathDate(p) {
    if (p = "" || !FileExist(p))
        return ""
    try
        return FormatTime(FileGetTime(p, "C"), "yyyy-MM-dd")
    return ""
}

ScanInstalled() {
    apps := []
    sources := ["HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        , "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        , "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall"]
    for src in sources {
        Loop Reg, src, "K" {
            kp := src "\" A_LoopRegName
            name := RegReadSafe(kp, "DisplayName")
            if (name = "")
                continue
            if (RegReadSafe(kp, "SystemComponent") = "1")
                continue
            if (RegReadSafe(kp, "ParentKeyName") != "")
                continue
            if (RegReadSafe(kp, "ReleaseType") != "")
                continue          ; Security Update / Hotfix / Update Rollup 等系统补丁（2.txt C4）
            locTmp := Trim(RegReadSafe(kp, "InstallLocation"), ' "')
            ; 安装时间四档兜底：InstallDate → 登记键最后写入 → 安装目录创建 → 卸载器 exe 创建。
            ; 后三档是推算值，但显示口径与 InstallDate 一致：只写日期，不加任何前缀
            ; （用户明确要求「时间开头不要有约等号」）。
            d := FormatInstallDate(RegReadSafe(kp, "InstallDate"))
            if (d = "")
                d := RegKeyDate(kp)
            if (d = "")
                d := PathDate(locTmp)
            if (d = "")
                d := PathDate(SplitCommand(RegReadSafe(kp, "UninstallString"))[1])
            a := {keyPath: kp, name: name
                , version: RegReadSafe(kp, "DisplayVersion")
                , publisher: RegReadSafe(kp, "Publisher")
                , instDate: d
                , location: (locTmp != "" ? RTrim(locTmp, "\") : "")
                , uninstall: RegReadSafe(kp, "UninstallString")
                , quiet: RegReadSafe(kp, "QuietUninstallString")
                , winInstaller: RegReadSafe(kp, "WindowsInstaller")}
            a.msi := ""
            if (RegExMatch(a.uninstall, "i)msiexec") || a.winInstaller = "1")
                a.msi := ExtractMsiGuid(a.uninstall)
            ; WindowsInstaller=1 且串内无 /I|/X{GUID} 时不再从子键名兜底取 GUID（3.txt Q5：
            ; 子键名可能是升级码/补丁 GUID，msoexec /X 会卸错产品）——落回常规链原样运行。
            a.info := DecideCommand(a)
            apps.Push(a)
        }
    }
    ; 去重两层：MSI 按产品码 GUID（大小写归一；HKLM64 与 Wow6432Node 常重复登记）；
    ; 非 MSI 按 UninstallString 原文 + 名称（4.txt N2：共用卸载器的两个不同应用
    ; 不能只按串去重——会丢掉交叉引用排除需要的 location）。
    seen := Map()
    seenU := Map()
    out := []
    for a in apps {
        if (a.msi != "") {
            mk := StrLower(a.msi)
            if seen.Has(mk)
                continue
            seen[mk] := 1
        }
        if (a.uninstall != "") {
            uk := a.uninstall "|" a.name
            if seenU.Has(uk)
                continue
            seenU[uk] := 1
        }
        out.Push(a)
    }
    return out
}

; ═════════════════════════════════════════════════════════════════════
;  卸载执行（Job Object 等待 + 键消失宽限，SetTimer 状态机）
; ═════════════════════════════════════════════════════════════════════

UninstallSelected() {
    global gList, gApps, gView, gStatus, gUnin, gMode
    if (gMode != "installed")
        return
    if IsObject(gUnin) {
        gStatus.Value := "已有卸载在进行中"
        return
    }
    row := gList.GetNext(0)
    if !row {
        gStatus.Value := "未选中程序"
        return
    }
    a := gView[row]      ; 列表显示的是过滤/排序后的 gView，行号必须取 gView 不是 gApps
    if !IsObject(a)
        return
    if (a.info.kind = "none") {
        gStatus.Value := a.name "：无卸载器，无法卸载"
        return
    }
    if (a.info.kind = "gone") {
        if MsgBox(a.name " 的卸载器文件已缺失，无法本体卸载。`n是否直接扫描该程序的残留？",
            "软件卸载 · 扫描残留", 0x4 | 0x20) = "Yes"
            ShowLeftoversFor(a, true)      ; 程序仍安装着：自身卸载键不列为残留（4.txt N6）
        else
            gStatus.Value := "已取消"     ; N9（1.txt）：点 No 也要回写状态，别停在旧文案
        return
    }
    if (a.info.kind = "upd") {
        ; 1.txt N3：update.exe 无归属证据时不能原样静默跑——很可能是「检查更新」程序
        ; N8/F5（1.txt/4.txt）：补展示实际命令，并明说"运行后可能只是启动更新器、不会卸载"。
        if MsgBox(a.name " 的卸载器是 update.exe，但缺少归属证据——它很可能是「检查更新」"
            . "程序而非卸载器，运行后可能只是启动更新器、并不会真正卸载。`n命令："
            . ExpandEnv(a.info.cmd) "`n`n是否仍按注册表原样运行？", "软件卸载 · 疑似更新器",
            0x4 | 0x30) != "Yes" {
            gStatus.Value := "已取消（疑似更新器）"
            return
        }
        StartUninstall(a)
        return
    }
    tip := "将卸载：" a.name (a.version != "" ? " " a.version : "")
        . "`n执行方式：" a.info.note
        . "`n命令：" ExpandEnv(a.info.cmd)     ; 展示实际执行的展开后命令（4.txt Q3）
    if (a.info.kind = "raw")
        tip .= "`n（该程序没有已知静默参数，会弹出它自己的卸载界面，请手动完成）"
    if (SubStr(a.keyPath, 1, 4) = "HKLM" && !A_IsAdmin)
        tip .= "`n（当前未以管理员运行：HKLM 来源的卸载与残留清理可能失败）"
    tip .= "`n`n确定继续？"
    if MsgBox(tip, "软件卸载 · 确认卸载", 0x4 | 0x30) != "Yes" {
        gStatus.Value := "已取消"
        return
    }
    StartUninstall(a)
}

StartUninstall(a) {
    global gUnin, gStatus
    full := ExpandEnv(a.info.cmd)
    parts := SplitCommand(full)
    exeFile := parts[1]
    pid := 0
    if (InStr(exeFile, "\") && FileExist(exeFile)) {
        SplitPath exeFile, , &pdir
        try Run('"' exeFile '" ' parts[2], pdir, "", &pid)
        catch as e {
            ; Run 启动失败抛 OSError 而不是 pid=0（1.txt#1）：必须捕获，否则用户点
            ; 「确定卸载」后状态条停在旧文案，看起来像没反应。
            gStatus.Value := "启动失败：" e.Message
            return
        }
    } else {
        try Run(full, "", "", &pid)
        catch as e {
            gStatus.Value := "启动失败：" e.Message
            return
        }
    }
    if (pid = 0) {
        gStatus.Value := "启动失败：无法运行卸载命令"
        return
    }
    job := 0
    h := DllCall("kernel32\OpenProcess", "UInt", 0x0100 | 0x0001, "Int", 0, "UInt", pid, "Ptr")
    if h {
        job := DllCall("kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
        if (job && !DllCall("kernel32\AssignProcessToJobObject", "Ptr", job, "Ptr", h, "Int")) {
            DllCall("kernel32\CloseHandle", "Ptr", job)
            job := 0
        }
        DllCall("kernel32\CloseHandle", "Ptr", h)
    }
    gUnin := {app: a, job: job, pid: pid, start: A_TickCount, gone: 0, gone2: 0}
    SetTimer(TickUninstall, 400)
    OpLog("卸载启动：" a.name " | " a.info.kind " | " full)
    gStatus.Value := "已启动卸载器，等待其退出…"
}

JobActive(job) {
    ; JOBOBJECT_BASIC_ACCOUNTING_INFORMATION（x64，48 字节）：ActiveProcesses 在偏移 40
    info := Buffer(48, 0)
    ok := DllCall("kernel32\QueryInformationJobObject", "Ptr", job, "Int", 1
        , "Ptr", info, "UInt", info.Size, "Ptr", 0, "Int")
    if !ok
        return -1
    n := NumGet(info, 40, "UInt")
    return (n <= JOB_ACTIVE_LIMIT) ? n : -1
}

TickUninstall() {
    global gUnin, gStatus
    if !IsObject(gUnin) {
        SetTimer(TickUninstall, 0)
        return
    }
    now := A_TickCount
    gone := !RegKeyExists(gUnin.app.keyPath)
    ; 进程侧退出检测三态（2.txt#1 / 3.txt Q28；ProcessExist 只是旁证——N9：UAC stub
    ; 会退出、PID 会复用，都不能单独当完成证据）。
    active := -2
    if gUnin.job {
        n := JobActive(gUnin.job)
        if (n >= 0)
            active := n
    } else if (gUnin.pid && ProcessExist(gUnin.pid)) {
        active := 1                  ; 进程仍活着（UAC stub 会活着等提权子进程）
    } else if gUnin.pid {
        active := 0                  ; 进程已退出（无 Job 兜底通道）
    }
    ; Q15（4.txt）：gone 分支不得短路进程三态——键消失满宽限且进程侧也给出完成
    ; 证据（active=0 或三态未知）才收工；进程仍活着就继续等并如实提示。
    if (gone) {
        if (gUnin.gone = 0) {
            gUnin.gone := now
        } else if (now - gUnin.gone >= GRACE_MS) {
            ; F1（4.txt，投产前必修）：active>1 表示 Job 里还有清理子进程在跑，键先删
            ; 不等于卸完；active=-2 三态未知按注释方向安全继续等。只在 active<=0（无进程）
            ; 才收工，否则继续等待并如实提示后台活动。
            if (active <= 0) {
                FinishUninstall(true)
                return
            }
            gStatus.Value := "键已消失，检测到后台仍在活动 · 继续等待…"
        }
    } else
        gUnin.gone := 0
    ; 进程退出但键仍在（UAC stub 退出、提权子进程收尾中，2.txt A2）：60 秒宽限，
    ; 不再用 4 秒——否则未提权卸 HKLM 时会把刚开始的真卸载误报成失败。
    if (active = 0) {
        if (gUnin.gone2 = 0) {
            gUnin.gone2 := now
        } else if (now - gUnin.gone2 >= 2000) {
            gStatus.Value := "卸载器已退出，等待条目消失（可能后台收尾）…"
        }
        if (now - gUnin.gone2 >= GRACE_EXIT_MS) {
            FinishUninstall(gone)
            return
        }
    } else
        gUnin.gone2 := 0
    if (now - gUnin.start > WAIT_TIMEOUT_MS) {
        FinishUninstall(gone, true)
        return
    }
    ; N7（1.txt）：active=0（进程已退但键仍在）时上面已写"卸载器已退出，等待条目消失"，
    ; 不该再被"卸载中 · N 秒"覆盖。
    if ((!gone || now - gUnin.gone < GRACE_MS) && active != 0)
        gStatus.Value := "卸载中 · " ((now - gUnin.start) // 1000) " 秒"
}

FinishUninstall(gone, timedOut := false) {
    global gUnin, gApps, gStatus, gMode
    SetTimer(TickUninstall, 0)
    if IsObject(gUnin) && gUnin.job
        DllCall("kernel32\CloseHandle", "Ptr", gUnin.job)
    a := gUnin.app
    gUnin := 0
    OpLog("卸载结束：" a.name " | 键消失=" (gone ? "是" : "否") (timedOut ? " | 超时" : ""))
    gApps := ScanInstalled()
    BuildView()
    if (gone) {
        if (gMode = "installed") {
            ; 用户仍在安装清单视图时才自动切残留（1.txt#17：等待期间用户可能点了
            ; 「重新扫描」或正选中别的行，强制切视图会打断操作）。
            gStatus.Value := "已卸载：" a.name " · 正在扫描残留…"
            ShowLeftoversFor(a, false)
        } else {
            gStatus.Value := "已卸载：" a.name
        }
    } else {
        gStatus.Value := (timedOut ? "等待超时（10 分钟），卸载器可能仍在运行" : "卸载器已退出")
            . "，注册表条目仍在：" a.name
    }
}

; ═════════════════════════════════════════════════════════════════════
;  残留扫描（uproot 启发式）
; ═════════════════════════════════════════════════════════════════════

CollectLeftovers(a, others, aStillInstalled) {
    out := []
    strong := StrongNames(a)
    if (strong.Length = 0)
        return out
    pub := PubNorm(a)
    locs := []
    otherNames := Map()
    for o in others {
        l := RTrim(o.location, "\")
        if (l != "")
            locs.Push(StrLower(l))
        n := Norm(CleanName(o.name))
        if (n != "")
            otherNames[n] := 1
        t := Norm(PathLeaf(RTrim(o.location, "\")))
        if (StrLen(t) >= 3)
            otherNames[t] := 1
    }
    seen := Map()
    tails := []
    aLoc := RTrim(a.location, "\")
    if (aLoc != "") {
        at := Norm(PathLeaf(aLoc))
        ; M1（2.txt/3.txt）：tails 阈值原为 >=3，但 N5 的 2 字符共现门要求 InArray(tails,n)，
        ; 于是 QQ/微信这类 2 字符名的注册表残留永远扫不到——降阈值让安装目录尾段能自证。
        if (StrLen(at) >= 2 && !IsGenericNorm(at))
            tails.Push(at)
    }
    ScanLeftoverFolders(a, strong, pub, locs, otherNames, seen, out)
    ScanLeftoverRegistry(strong, tails, pub, otherNames, seen, out)
    ; 自身 Uninstall 键：只有应用确实已卸载（键是残留）才列出（4.txt N6——gone 路径
    ; 下程序仍安装着，卸载条目不是残留，默认勾选会让用户删出「幽灵安装」）。
    if (!aStillInstalled && RegKeyExists(a.keyPath)) {
        lc := StrLower(a.keyPath)
        if !seen.Has(lc) {
            seen[lc] := 1
            out.Push({path: a.keyPath, isReg: true, kind: "注册表键"
                , bytes: 0, note: "卸载条目残留", checked: true})
        }
    }
    return out
}

; 与仍安装应用互相包含 → 跳过（防误删共享目录）。返回残留项对象或 0。
BuildFolderItem(cand, locs, seen) {
    lc := StrLower(RTrim(cand, "\"))
    if seen.Has(lc)
        return 0
    for loc in locs
        if (Within(lc, loc) || Within(loc, lc))
            return 0
    if (SubStr(cand, 1, 2) = "\\")
        return 0                       ; 网络路径不动
    seen[lc] := 1
    it := {path: cand, isReg: false, kind: "文件夹", bytes: 0, note: "可进回收站", checked: true}
    a := DllCall("kernel32\GetFileAttributesW", "Str", cand, "UInt")
    if (a != 0xFFFFFFFF && (a & FILE_ATTRIBUTE_REPARSE_POINT)) {
        it.bytes := -2
        it.note := "链接（只删链接本身）"
        return it
    }
    n := FolderSize(cand)
    if (n < 0) {
        it.bytes := -1
        it.checked := false
        it.note := "过大（默认不勾选）"
    } else {
        it.bytes := n
        if (n >= BIG_FOLDER) {
            it.checked := false
            it.note := "过大（默认不勾选）"
        }
    }
    return it
}

ScanLeftoverFolders(a, strong, pub, locs, otherNames, seen, out) {
    la := EnvGet("LocalAppData")           ; AHK v2 无 A_AppDataLocal，本地 AppData 走环境变量
    roots := [A_ProgramFiles, EnvGet("ProgramFiles(x86)"), EnvGet("ProgramData")
        , A_AppData, la, la "\Programs"]
    for root in roots {
        if (root = "" || !DirExist(root))
            continue
        Loop Files, root "\*", "D" {
            outerPath := A_LoopFilePath
            ; ★ 嵌套 Loop 会覆盖 A_LoopFilePath（1.txt#9）：外层路径先落局部变量，
            ;   内层结束后一律用 outerPath 拼接，不再读回 A_LoopFilePath。
            n := Norm(A_LoopFileName)
            cand := ""
            if (n != "" && !IsGenericNorm(n) && InArray(strong, n))
                cand := outerPath
            else if (pub != "" && n = pub) {
                ; 发行者目录：下钻一层找应用名
                Loop Files, outerPath "\*", "D" {
                    sn := Norm(A_LoopFileName)
                    if (sn != "" && InArray(strong, sn)) {
                        cand := outerPath "\" A_LoopFileName
                        break
                    }
                }
            }
            if (cand = "")
                continue
            it := BuildFolderItem(cand, locs, seen)
            if IsObject(it)
                out.Push(it)
        }
    }
    ; 安装目录本身：仅当尾段命中强名（2.txt#4：删除 BackslashCount>=2 的 OR 分支——
    ; 否则 InstallLocation 写成 C:\Program Files\Common Files 时整个共享目录会被
    ; 送进回收站；C:\Windows\System32 这类深度路径同样满足旧条件）。
    loc := RTrim(a.location, "\")
    if (loc != "" && DirExist(loc) && InStr(loc, ":") = 2) {
        tail := Norm(PathLeaf(loc))
        if (InArray(strong, tail) && !IsGenericNorm(tail) && !otherNames.Has(tail)) {
            it := BuildFolderItem(loc, locs, seen)
            if IsObject(it)
                out.Push(it)
        }
    }
}

ScanLeftoverRegistry(strong, tails, pub, otherNames, seen, out) {
    srcs := ["HKCU\Software", "HKLM\SOFTWARE", "HKLM\SOFTWARE\WOW6432Node"]
    for src in srcs {
        Loop Reg, src, "K" {
            nm := A_LoopRegName
            n := Norm(nm)
            ; ★ 泛用名黑名单对注册表分支同样生效（2.txt#3：DisplayName 恰为
            ;   Update/Launcher/Config 的 OEM 软件会把 HKCU\Software\Update 整键送删）。
            if (n = "" || otherNames.Has(n) || IsGenericNorm(n))
                continue
            ; N5/M1（2.txt/3.txt）：2 字符强名短键碰撞风险高——纯 ASCII 2 字符（qq/ai/wp）
            ; 必须命中安装目录尾段共现才匹配；2 字中文名（微信/钉钉）碰撞率低，直接放行。
            shortAscii := (StrLen(n) = 2 && RegExMatch(n, "^[0-9a-z]{2}$"))
            if (InArray(strong, n) && (!shortAscii || InArray(tails, n))) {
                lc := StrLower(src "\" nm)
                if !seen.Has(lc) {
                    seen[lc] := 1
                    out.Push({path: src "\" nm, isReg: true, kind: "注册表键"
                        , bytes: 0, note: "先备份再删除（命中 " n "）", checked: true})
                }
                continue
            }
            if (pub != "" && n = pub) {
                Loop Reg, src "\" nm, "K" {
                    sn := Norm(A_LoopRegName)
                    if (sn = "" || otherNames.Has(sn) || IsGenericNorm(sn) || !InArray(strong, sn))
                        continue
                    shortAsciiSn := (StrLen(sn) = 2 && RegExMatch(sn, "^[0-9a-z]{2}$"))
                    if (shortAsciiSn && !InArray(tails, sn))
                        continue          ; 2 字符 ASCII 子键要求尾段共现；中文名放行
                    lc := StrLower(src "\" nm "\" A_LoopRegName)
                    if !seen.Has(lc) {
                        seen[lc] := 1
                        out.Push({path: src "\" nm "\" A_LoopRegName, isReg: true, kind: "注册表键"
                            , bytes: 0, note: "先备份再删除（命中 " pub "\" sn "）", checked: true})
                    }
                }
            }
        }
    }
}

; 文件夹大小（reparse 不进入、文件计数超上限返回 -1 = "过大"）
; ★ A_LoopFileAttrib 是属性字符串（如 "RAH"）不是位掩码：判目录用 InStr("D")、
;   判 reparse 用 InStr("L")——按位与数字会抛 Expected a Number（error.log 实录）。
FolderSize(root) {
    total := 0, files := 0
    stack := [root]
    while (stack.Length) {
        d := stack.Pop()
        Loop Files, d "\*", "DF" {
            att := A_LoopFileAttrib
            if InStr(att, "L")
                continue
            if InStr(att, "D")
                stack.Push(A_LoopFilePath)
            else {
                total += A_LoopFileSize
                files++
                if (files >= FOLDER_SIZE_CAP)
                    return -1
            }
        }
    }
    return total
}

FormatSize(n) {
    if (n >= 1073741824)
        return Round(n / 1073741824, 1) " GB"
    if (n >= 1048576)
        return Round(n / 1048576, 1) " MB"
    if (n >= 1024)
        return Round(n / 1024, 1) " KB"
    return n " B"
}

; 扫残留入口：切到残留模式并填充列表。aStillInstalled=false 表示本体已卸载
; （FinishUninstall 成功路径）；true 表示程序还在（gone 路径，自身键不列为残留）。
ShowLeftoversFor(a, aStillInstalled) {
    global gApps, gLeft, gStatus
    others := []
    for o in gApps
        if (o.keyPath != a.keyPath)
            others.Push(o)
    gLeft := CollectLeftovers(a, others, aStillInstalled)
    if !gLeft.Length {
        ; L2（2.txt/3.txt）：gone 路径（aStillInstalled=true）根本没执行卸载，
        ; 空残留不能说"已卸载"。
        gStatus.Value := (aStillInstalled ? "未执行卸载：" : "已卸载：") a.name " · 未发现残留"
        return
    }
    SwitchMode("leftover")
    BuildView()
    nf := 0, nr := 0
    for it in gLeft {
        if it.isReg
            nr++
        else
            nf++
    }
    gStatus.Value := "发现 " gLeft.Length " 项残留（文件夹 " nf " · 注册表键 " nr "）"
        . (A_IsAdmin ? "" : " · 未提权：HKLM 项清理会失败")
}

; ═════════════════════════════════════════════════════════════════════
;  残留清理（文件夹 → 回收站；注册表 → 先备份再删）
; ═════════════════════════════════════════════════════════════════════

CleanLeftovers() {
    global gList, gLeft, gView, gStatus, gMode
    if (gMode != "leftover")
        return
    rows := []
    r := gList.GetNext(0, "C")
    while r {
        rows.Push(r)
        r := gList.GetNext(r, "C")
    }
    if !rows.Length {
        gStatus.Value := "未勾选残留项"
        return
    }
    ; 行号是「显示视图 gView」的下标（可能已被搜索过滤 / 排序），不是 gLeft 下标。
    ; 用对象身份映射：gView 的元素与 gLeft 是同一引用，按对象而非位置取，过滤/排序都不串。
    checkedItems := Map()
    nf := 0, nr := 0
    for r2 in rows {
        if (r2 < 1 || r2 > gView.Length)
            continue
        it := gView[r2]
        checkedItems[it] := 1
        if it.isReg
            nr++
        else
            nf++
    }
    tip := "将清理勾选的 " rows.Length " 项：`n  · 文件夹 " nf " 项 → 尝试移入回收站"
        . "`n  · 注册表键 " nr " 项 → 先导出 .reg 备份再删除`n  · 链接/挂载点 → 只删链接本身"
        . "`n`n（网络盘等场景可能不支持回收站，失败会如实报错）`n`n确定继续？"
    if MsgBox(tip, "软件卸载 · 确认清理", 0x4 | 0x30) != "Yes" {
        gStatus.Value := "已取消"
        return
    }
    backupDir := A_ScriptDir "\软件卸载\backup\" FormatTime(A_Now, "yyyyMMdd-HHmmss")
    if !DirExist(backupDir)
        try DirCreate backupDir
    if !DirExist(backupDir)
        backupDir := A_Temp "\软件卸载\backup\" FormatTime(A_Now, "yyyyMMdd-HHmmss")   ; 只读目录回退（3.txt Q27）
    if !DirExist(backupDir)
        try DirCreate backupDir
    if !DirExist(backupDir) {
        gStatus.Value := "清理取消：备份目录创建失败（脚本目录与 %TEMP% 均不可写）"
        return
    }
    okF := 0, okK := 0, fail := 0, detail := ""
    seq := 0
    cleaned := Map()
    for it in gView {
        if !checkedItems.Has(it) {
            it.checked := false       ; 未勾选：同步回 false，避免刷新时恢复（1.txt#12）
            continue
        }
        if (it.isReg) {
            seq++
            res := BackupAndDeleteKey(it.path, backupDir, seq)
            if res[1]
                okK++, cleaned[it] := 1
            else {
                fail++
                detail .= "`n" it.path "（" res[2] "）"
            }
        } else if (it.bytes = -2) {
            ; reparse point：只删链接本身，不走 SHFileOperationW（1.txt#11）
            res := DeleteReparseOnly(it.path)
            if res[1]
                okF++, cleaned[it] := 1
            else {
                fail++
                detail .= "`n" PathLeaf(it.path) "（" res[2] "）"
            }
        } else {
            res := RecyclePath(it.path)
            if res[1] {
                okF++
                cleaned[it] := 1
                TryRemoveEmptyParent(it.path)
            } else {
                fail++
                detail .= "`n" PathLeaf(it.path) "（" res[2] "）"
            }
        }
    }
    ; 重建 gLeft：移除成功清理的项；被搜索过滤隐藏（不在 gView）的项 checked 归 false。
    inView := Map()
    for it in gView
        inView[it] := 1
    keep := []
    for it in gLeft {
        if cleaned.Has(it)
            continue
        if !inView.Has(it)
            it.checked := false
        keep.Push(it)
    }
    gLeft := keep
    BuildView()
    OpLog("残留清理：文件夹 " okF " 项 · 注册表键 " okK " 项 · 失败 " fail " 项")
    txt := "清理完成 · 文件夹 " okF " 项 · 注册表键 " okK " 项"
    if fail
        txt .= " · 失败 " fail detail
    gStatus.Value := txt
}

; 注册表键：先 reg export 备份，备份成功才删（SHDeleteKeyW 递归删整棵）
BackupAndDeleteKey(k, backupDir, seq) {
    regFile := backupDir "\" seq " " SafeKeyFile(k) ".reg"
    rc := RunWait('reg.exe export "' k '" "' regFile '" /y', , "Hide")
    if (rc != 0 || !FileExist(regFile))
        return [false, "备份失败 rc=" rc]
    parts := RegSplit(k)
    r := DllCall("shlwapi\SHDeleteKeyW", "Ptr", parts[1], "Str", parts[2], "Int")
    if (r != 0)
        return [false, "删除失败 rc=" r]
    if RegKeyExists(k)
        return [false, "删除后仍存在"]
    return [true, ""]
}

RegSplit(k) {
    p := InStr(k, "\")
    root := SubStr(k, 1, p - 1)
    sub := SubStr(k, p + 1)
    rid := (root = "HKLM" || root = "HKEY_LOCAL_MACHINE") ? 0x80000002
        : (root = "HKCU" || root = "HKEY_CURRENT_USER") ? 0x80000001
        : (root = "HKCR" || root = "HKEY_CLASSES_ROOT") ? 0x80000000
        : (root = "HKU" || root = "HKEY_USERS") ? 0x80000003 : 0
    return [rid, sub]
}

RegKeyExists(k) {
    parts := RegSplit(k)
    if (parts[1] = 0)
        return false
    h := 0
    rc := DllCall("advapi32\RegOpenKeyExW", "Ptr", parts[1], "Str", parts[2]
        , "UInt", 0, "UInt", 0x20019, "Ptr*", &h, "Int")
    if (rc = 0) {
        DllCall("advapi32\RegCloseKey", "Ptr", h)
        return true
    }
    return false
}

SafeKeyFile(k) {
    s := StrReplace(k, "\", "_")
    return StrReplace(s, ":", "-")
}

; 刚清空的文件夹，父目录若已空（且不是六大根、不是盘根）顺带删掉（uproot 同款）
TryRemoveEmptyParent(path) {
    parent := ""
    SplitPath path, , &pdir
    parent := RTrim(pdir, "\")
    if (parent = "" || BackslashCount(parent) < 2)
        return                          ; 盘根/一级目录不动
    la := EnvGet("LocalAppData")
    ; ★ 六大根全列（2.txt B1：原来漏 LocalAppData\Programs——残留清在 …\Programs\AppName
    ;   时，空了的 Programs 会被连壳永久删）
    for root in [A_ProgramFiles, EnvGet("ProgramFiles(x86)"), EnvGet("ProgramData")
        , A_AppData, la, la "\Programs"] {
        if (root != "" && StrLower(RTrim(root, "\")) = StrLower(parent))
            return                      ; 六大根本身不删
    }
    empty := true
    Loop Files, parent "\*", "DF"
        empty := false
    if empty
        try DirDelete(parent)      ; 非递归（3.txt Q29：递归删空目录与「绝不悄悄永久删除」
                                   ; 承诺冲突，且检查与删除之间可能被其它进程写入——
                                   ; 非递归在非空时天然失败，放弃即安全）
}

; 操作审计（2.txt C8）：卸载/清理各落一行，与 error.log 同目录同回退策略
OpLog(s) {
    dir := A_ScriptDir "\软件卸载"
    if !DirExist(dir)
        try DirCreate dir
    if !DirExist(dir)
        dir := A_Temp
    try FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " s "`n", dir "\operations.log", "UTF-8"
}

; ── 放进回收站：SHFileOperationW(FO_DELETE + FOF_ALLOWUNDO) ───────────
; 不用 \\?\ 前缀（Shell 不认）；目录整棵进回收站，还原时也是整棵回来。
; 失败时不悄悄改成永久删除——宁可报错，也不让用户以为还能还原。
RecyclePath(path) {
    a := DllCall("kernel32\GetFileAttributesW", "Str", path, "UInt")
    if (a = 0xFFFFFFFF) {
        ; INVALID ≠ 已删除（3.txt Q30）：长路径、权限、网络不可达都落到这里。
        ; 只有明确的不存在错误码才算「卸载器已删掉，无需处理」，其余如实报失败，
        ; 杜绝把没删掉的目录当成功移出列表（误报成功会关闭重试入口）。
        e := DllCall("kernel32\GetLastError", "UInt")
        if (e = 2 || e = 3)          ; ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND
            return [true, ""]
        return [false, "路径不可读 err=" e]
    }
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
    if (!rc && !aborted && DllCall("kernel32\GetFileAttributesW", "Str", path, "UInt") = 0xFFFFFFFF)
        return [true, ""]
    if (!rc && !aborted)
        return [false, "回收站未生效"]
    if (aborted)
        return [false, "回收站操作被中止"]
    return [false, "回收站失败：" RecycleErrText(rc)]
}

; SHFileOperation 的 DE_* 码按真实语义（2.txt B3：旧映射把 0x7C/0x7D/0x7E/0x74 全写错了）
RecycleErrText(rc) {
    if (rc = 0x78 || rc = 5)
        return "源访问被拒（权限或 ACL）"
    if (rc = 0x79)
        return "路径过深（超出 MAX_PATH）"        ; DE_PATHTOODEEP（4.txt F4：旧写成"目标访问被拒"是错的）
    if (rc = 32 || rc = 33)
        return "文件正被占用"
    if (rc = 0x7C)
        return "文件名不合法"                ; DE_INVALIDFILES
    if (rc = 0x7D)
        return "源与目标在同一目录树"        ; DE_DESTSAMETREE
    if (rc = 0x7E)
        return "目标是已存在的文件，不是文件夹"  ; DE_FLDDESTISFILE（4.txt F4：旧方向写反了）
    if (rc = 0x74)
        return "不允许操作盘根"              ; DE_ROOTDIR
    if (rc = 0x10003)
        return "路径不存在"                  ; ERRORONDEST + ERROR_PATH_NOT_FOUND
    if (rc = 0x10004)
        return "目标端打开文件过多"          ; ERRORONDEST + ERROR_TOO_MANY_OPEN_FILES（4.txt F4：旧误作"路径不存在"）
    return "err=" rc
}

; junction/symlink 删除：目录链接 → RemoveDirectoryW，文件链接 → DeleteFileW，
; 只删链接本身（1.txt#11：SHFileOperationW 对 junction 的契约不稳定，可能进目标
; 删内容，与 BuildFolderItem 标注的「只删链接」语义不符）。
; ── \\?\ 直通路径（幂等；来自《文件解锁》范本）────────────────────────
NtPath(path) {
    if (SubStr(path, 1, 4) = "\\?\")
        return path
    if (SubStr(path, 1, 2) = "\\")
        return "\\?\UNC\" SubStr(path, 3)
    return "\\?\" StrReplace(path, "/", "\")
}

DeleteReparseOnly(path) {
    np := NtPath(path)
    a := DllCall("kernel32\GetFileAttributesW", "Str", np, "UInt")
    if (a = 0xFFFFFFFF) {
        ; Q30 同类问题（4.txt N4）：INVALID ≠ 已删除——长路径/ACL/网络不可达都落到
        ; 这里，只有明确的不存在错误码才算「已删」，否则如实报失败。
        e := DllCall("kernel32\GetLastError", "UInt")
        if (e = 2 || e = 3)
            return [true, ""]
        return [false, "路径不可读 err=" e]
    }
    ; 注：不做 SetFileAttributesW——FILE_ATTRIBUTE_REPARSE_POINT 本就不能用它清除
    ; （4.txt 引 Microsoft 文档），原调用无效。
    if (a & 0x10) {            ; 目录链接（junction / 目录符号链接）
        if DllCall("kernel32\RemoveDirectoryW", "Str", np, "Int")
            return [true, ""]
        return [false, "RemoveDirectory err=" DllCall("kernel32\GetLastError", "UInt")]
    }
    if DllCall("kernel32\DeleteFileW", "Str", np, "Int")
        return [true, ""]      ; 文件符号链接
    return [false, "DeleteFile err=" DllCall("kernel32\GetLastError", "UInt")]
}

; ── UI 工具（§10.8：工具函数按控件命名，复制时保持同名）────────────────

; DWM caption 染色（令牌色，照范本）
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

; 1px 描边按钮（范本同名函数）。返回 {outer, inner, w, h} 以便模式切换换文字/搬移。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return {outer: f, inner: b, w: w, h: h}
}

MoveBtn(btn, x, y) {
    btn.outer.Move(x, y, btn.w, btn.h)
    btn.inner.Move(x + 1, y + 1, btn.w - 2, btn.h - 2)
}

SwitchButton(btn, text) {
    btn.w := MeasureTextWidth(text) + 2 * BTN_PAD
    btn.inner.Text := text
}

; 量文字实际宽（GDI，s10 Microsoft YaHei UI）
; UI规范 §10.3.1-2：按钮宽 = 文字实际宽 + 2×BTN_PAD，禁止为了铺满撑宽（K25）。
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

; 输入框真正垂直居中：EM_SETRECT(0xB3) 对单行无效，配 Multi 凑 ES_MULTILINE 后设 top=2。
SetEditRect(hwnd, left, top, right, bottom) {
    rc := Buffer(16, 0)
    NumPut("Int", left, rc, 0)
    NumPut("Int", top, rc, 4)
    NumPut("Int", right, rc, 8)
    NumPut("Int", bottom, rc, 12)
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0xB3, "Ptr", 0, "Ptr", rc, "Ptr")
}

; ── 搜索过滤 + 列排序：源数据(gApps/gLeft) → gView → 列表 ──────────────
; 搜索框防抖回调；改文本后重建视图。
ApplySearch() {
    global gSearch, gSearchText
    gSearchText := Trim(gSearch.Value)
    BuildView()
}

; 按当前模式取源数据，过滤 + 排序得到 gView，再重填列表。
BuildView() {
    global gMode, gApps, gLeft, gView, gSearchText, gSortCol, gSortDesc
    src := (gMode = "installed") ? gApps : gLeft
    gView := FilterSortRows(src, gMode, gSearchText, gSortCol, gSortDesc)
    RefreshList()
    UpdateSummary()
}

; 纯函数：按模式过滤 + 排序，返回有序数组。不读全局，便于 selftest 直接覆盖。
FilterSortRows(src, mode, q, sortCol, desc) {
    q := StrLower(q)
    if (q = "")
        view := src.Clone()
    else {
        view := []
        for e in src
            if RowMatches(e, mode, q)
                view.Push(e)
    }
    if (sortCol)
        view := SortRows(view, mode, sortCol, desc)
    return view
}

RowMatches(e, mode, q) {
    if (mode = "installed")
        return InStr(StrLower(e.name), q) || InStr(StrLower(e.publisher), q) || InStr(StrLower(e.version), q)
    return InStr(StrLower(e.path), q) || InStr(StrLower(e.note), q)
}

; 排序键：按模式与列号取该行的可比较文本。安装时间已存成 "YYYY-MM-DD"，字典序即时间序。
SortKey(e, mode, sortCol) {
    if (mode = "installed") {
        if (sortCol = 4)
            return e.instDate
        return sortCol = 1 ? e.name : sortCol = 2 ? e.version
            : sortCol = 3 ? e.publisher : StatusText(e)
    }
    return sortCol = 1 ? e.path : sortCol = 2 ? e.kind : e.note
}

; 用「键+制表符+原下标」拼串后整体 Sort，再按下标取回，避免自造比较器；降序加 R。
; 长度对不上（异常）保持原序，绝不丢行。
SortRows(view, mode, sortCol, desc) {
    buf := ""
    for i, e in view
        buf .= StrLower(SortKey(e, mode, sortCol)) "`t" i "`n"
    buf := Sort(buf, desc ? "R" : "")
    out := []
    for line in StrSplit(buf, "`n") {
        if (line = "")
            continue
        p := InStr(line, "`t")
        if p
            out.Push(view[Integer(SubStr(line, p + 1))])
    }
    return (out.Length = view.Length) ? out : view
}

; 列头点击：同列切升降序，异列设为该列升序；刷新箭头并重排。返回闭包供 OnEvent。
HeaderClick(i) {
    return (*) => OnHdrClick(i)
}
OnHdrClick(i) {
    global gSortCol, gSortDesc
    if (i = gSortCol)
        gSortDesc := !gSortDesc
    else
        gSortCol := i, gSortDesc := false
    UpdateHeaderArrows()
    BuildView()
}

; 列头文字后跟 ↑/↓ 表示当前排序列与方向（沿用 右键菜单整理 的现成约定：列名 + 两空格 + ↑/↓）。
UpdateHeaderArrows() {
    global gHdr1, gHdr2, gHdr3, gHdr4, gHdr5, gSortCol, gSortDesc, gMode
    mark := (gSortDesc ? "  ↓" : "  ↑")
    base := (gMode = "installed") ? ["名称", "版本", "发行者", "安装时间", "状态"]
        : ["路径", "类型", "大小", "说明", ""]
    hs := [gHdr1, gHdr2, gHdr3, gHdr4, gHdr5]
    for i, h in hs
        h.Value := (i = gSortCol && base[i] != "") ? base[i] mark : base[i]
}

; ── GUI ────────────────────────────────────────────────────────────────
; 版式照 UI规范 §10.3：默认客户区 672×352。垂直节奏 列表区(12) → BLOCK_GAP(6)
; → 操作行(28) → BLOCK_GAP(6) → 状态条(30) → 贴窗口底。
; 启动扫描延后单次定时器跑（K38：长任务期间定时器不来，先让窗口画完首帧）。
BuildGui() {
    global gGui, gList, gStatus, gInfo, gScroll, gApps
    global gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt, gLvNcProc
    global gBand, gHdr1, gHdr2, gHdr3, gHdr4, gHdr5, gStBand, gBtnMain, gBtnSub
    global gSearchFrame, gSearch, gSearchLabel
    global EDGE, ROW_W, H_HEADER, H_ACTION, H_STATUS
    gGui := Gui("+Resize +0x02000000", "软件卸载")
    ; WS_CLIPCHILDREN(0x02000000)：父窗口别刷在子控件上
    ; WS_SYSMENU(0x00080000) 同时掌管「系统菜单（右键标题栏/Alt+Space）」和「Min/Max/Close 三个按钮」。
    ; 不能用 -SysMenu —— 会把三个按钮一起干掉。Show 后用 SetWindowLongW 单独清掉 0x00080000
    ; 就只去菜单、保留按钮（0x00020000 Min / 0x00040000 Max / 0x00C00000 Close 是独立位）。
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    ; 自绘滚动条定时器必须先停，否则关窗后还会有一拍访问已销毁的列表（K21）；
    ; 卸载等待定时器与 Job 句柄一并收掉（不留句柄泄漏）。
    gGui.OnEvent("Close", OnGuiClose)
    gGui.OnEvent("Size", OnSize)

    ; 搜索行（y12 h28）：标签 + 输入框吃满行宽（§10.3.3 输入行：label + 弹性 Edit）。
    gSearchLabel := gGui.Add("Text", "x" EDGE " y12 w32 h" H_ACTION " BackgroundF7F9FC c202B3A +0x200", "搜索")
    ; -0x100 = 去掉 SS_NOTIFY：框线不再抢命中，落在 1px 边上的点击直接给输入框。
    gSearchFrame := gGui.Add("Text", "x56 y12 w" (ROW_W - 40) " h" H_ACTION " BackgroundB7C8E0 -0x100")
    gSearch := gGui.Add("Edit", "x57 y13 w" (ROW_W - 42) " h" (H_ACTION - 2)
        . " -E0x200 Multi -VScroll -WantReturn -Wrap BackgroundFFFFFF c202B3A", "")
    SetEditRect(gSearch.Hwnd, 8, 2, ROW_W - 50, 26)
    gSearch.OnEvent("Change", (*) => SetTimer(ApplySearch, -250))

    ; 列表区（y46 起）：白底块 + 四边各一条 1px FRAME 线（§10.4 / K42）。
    ; ★必须先铺白底块 gLvWhite：ShowScrollBar(FALSE) 只摘原生条样式位，ListView 不会接管那
    ; 10px 竖槽区域的重绘；那块露出来的会是窗口底色 B7C8E0（浅米色），跟列表白不一致，滚一下
    ; 就看到一道竖条——这就是用户说的「旧滚动条」。白底块盖在最底层，原生条位置露出来的永远是
    ; 白色，与列表同色看不见。先用 SetWindowPos(flag=1=HWND_BOTTOM) 把它压到底层，不依赖 AHK
    ; Gui 对不同控件类型的隐式 z 序处理；ListView 最后建、本来就在上面。
    gLvWhite := gGui.Add("Text", "x" (EDGE + 1) " y47 w" (ROW_W - 2) " h" (270 - 2 - H_HEADER)
        . " BackgroundFFFFFF -0x100")
    DllCall("user32\SetWindowPos", "Ptr", gLvWhite.Hwnd, "Ptr", 1, "Ptr", 0, "Ptr", 0, "Ptr", 0
        , "Ptr", 0, "UInt", 0x0007)   ; HWND_BOTTOM | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    gLineTop := gGui.Add("Text", "x" EDGE " y46 w" ROW_W " h1 BackgroundB7C8E0 -0x100")
    gLineBot := gGui.Add("Text", "x" EDGE " y315 w" ROW_W " h1 BackgroundB7C8E0 -0x100")
    gLineLft := gGui.Add("Text", "x" EDGE " y46 w1 h270 BackgroundB7C8E0 -0x100")
    gLineRgt := gGui.Add("Text", "x" (EDGE + ROW_W - 1) " y46 w1 h270 BackgroundB7C8E0 -0x100")

    gBand := gGui.Add("Text", "x" (EDGE + 1) " y47 w" (ROW_W - 2) " h" H_HEADER " BackgroundDCE8F7 -0x100")
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gHdr1 := gGui.Add("Text", "x" (EDGE + 7) " y47 w300 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "名称")
    gHdr2 := gGui.Add("Text", "x327 y47 w78 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "版本")
    gHdr3 := gGui.Add("Text", "x409 y47 w128 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "发行者")
    gHdr4 := gGui.Add("Text", "x541 y47 w96 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "安装时间")
    gHdr5 := gGui.Add("Text", "x637 y47 w116 h" H_HEADER " BackgroundDCE8F7 c202B3A +0x200", "状态")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")
    for i, h in [gHdr1, gHdr2, gHdr3, gHdr4, gHdr5]
        h.OnEvent("Click", HeaderClick(i))
    gList := gGui.Add("ListView", "x" (EDGE + 1) " y" (47 + H_HEADER) " w" (ROW_W - 2)
        . " h" (270 - 2 - H_HEADER) " -Hdr -Multi -E0x200 BackgroundFFFFFF c202B3A"
        , ["名称", "版本", "发行者", "安装时间", "状态"])
    ; LVS_EX_DOUBLEBUFFER：滚动重绘走后台缓冲，避免整块重画闪一下（K44）。
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)
    ; ★1.0.22 根治原生条残影：挂 WM_NCCALCSIZE 子类（见 LvNcCalcSize 上方注释）。
    ; 必须在第一次 Layout / 填表 / 滚动之前挂上，从第一帧起原生条就无空间可用。
    ; 回调句柄存进全局 gLvNcProc 保命（脚本退出前始终有效），OnGuiClose 里显式摘除。
    gLvNcProc := CallbackCreate(LvNcCalcSize)
    DllCall("comctl32\SetWindowSubclass", "Ptr", gList.Hwnd, "Ptr", gLvNcProc, "Ptr", 1, "Ptr", 0)

    gInfo := gGui.Add("Text", "x" EDGE " y322 w400 h" H_ACTION " BackgroundF7F9FC c202B3A +0x200", "")
    gBtnMain := FlatButton(gGui, 0, 322, MeasureTextWidth("卸载") + 2 * BTN_PAD, H_ACTION
        , "卸载", "EBF2FB", "B7C8E0", OnBtnMain)
    gBtnSub := FlatButton(gGui, 0, 322, MeasureTextWidth("重新扫描") + 2 * BTN_PAD, H_ACTION
        , "重新扫描", "EBF2FB", "B7C8E0", OnBtnSub)

    ; 状态条：贴窗口底
    gStBand := gGui.Add("Text", "x0 y356 w672 h" H_STATUS " BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y356 w648 h" H_STATUS " BackgroundDCE8F7 c202B3A +0x200"
        , "正在扫描安装清单…")

    gGui.Show("w672 h386 Center")
    PaintCaption()
    ; 标题栏按钮与系统菜单挂在同一个 WS_SYSMENU 位上，清样式位会把 Min/Max/Close 一起
    ; 干掉（1.0.8 实测翻车）。正确做法：保留 WS_SYSMENU，用 GetSystemMenu 把英文项删光、
    ; 只补「移动」+「退出」两条。★SC_MOVE(0xF010) 不能删——Windows 拖动标题栏走的正是
    ; SC_MOVE 链路，1.0.9 删光菜单项后窗口拖不动（实测）。SC_CLOSE(0xF060) 点击仍走
    ; 关闭链路 → OnGuiClose → ExitApp。
    try {
        hSys := DllCall("user32\GetSystemMenu", "Ptr", gGui.Hwnd, "Int", 0, "Ptr")
        if (hSys) {
            n := DllCall("user32\GetMenuItemCount", "Ptr", hSys, "Int")
            loop Max(0, n)
                DllCall("user32\DeleteMenu", "Ptr", hSys, "UInt", 0, "UInt", 0x400)  ; MF_BYPOSITION
            DllCall("user32\AppendMenuW", "Ptr", hSys, "UInt", 0, "Ptr", 0xF010
                , "Str", "移动")   ; MF_STRING, SC_MOVE
            DllCall("user32\AppendMenuW", "Ptr", hSys, "UInt", 0, "Ptr", 0xF060
                , "Str", "退出")   ; MF_STRING, SC_CLOSE
        }
    }

    ; 自绘滚动条：后四个数 = 列表可用内空（x/y/w/h），Show 后建、再 Layout。
    gScroll := FlatScroll(gGui, gList, EDGE + 1, 47 + H_HEADER, ROW_W - 2, 270 - 2 - H_HEADER)
    HookBarInput()
    HookListHover()
    SetTimer(gScroll.fnSync, 60)
    Layout(672, 386)

    ; 启动扫描延后：窗口先画完首帧再跑（K38），填表走 RefreshList。
    SetTimer(StartupScan, -120)
}

; 启动扫描（单次定时器回调；SetTimer 负周期只触发一次）
StartupScan() {
    global gApps, gStatus
    gApps := ScanInstalled()
    BuildView()
    v := ScriptVersion()
    gStatus.Value := "已扫描 " gApps.Length " 项安装记录" (v ? " · " v : "")
        (A_IsAdmin ? "" : " · 未提权")
}

OnGuiClose(*) {
    global gScroll, gUnin, gList, gLvNcProc
    ; 销毁窗口前先摘 WM_NCCALCSIZE 子类：窗口销毁过程中还会有非客户区计算消息到达，
    ; 回调必须全程有效（CallbackCreate 的句柄到脚本退出才失效，这里显式摘除是双保险，
    ; 也避免 ExitApp 析构顺序极端情形下的悬空调用）。
    if (IsObject(gList) && gList.Hwnd && gLvNcProc)
        try DllCall("comctl32\RemoveWindowSubclass", "Ptr", gList.Hwnd, "Ptr", gLvNcProc, "Ptr", 1)
    if IsObject(gScroll)
        gScroll.Stop()
    if IsObject(gUnin) {
        SetTimer(TickUninstall, 0)
        if gUnin.job
            DllCall("kernel32\CloseHandle", "Ptr", gUnin.job)
        gUnin := 0
    }
    ExitApp()
}

OnBtnMain(*) {
    global gMode
    if (gMode = "installed")
        UninstallSelected()
    else
        CleanLeftovers()
}

OnBtnSub(*) {
    global gMode, gApps, gStatus
    if (gMode != "installed") {
        SwitchMode("installed")
        BuildView()
        gStatus.Value := "已返回安装清单"
        return
    }
    RescanAll()
}

RescanAll() {
    global gApps, gStatus
    gStatus.Value := "正在重新扫描…"
    gApps := ScanInstalled()
    BuildView()
    gStatus.Value := "已扫描 " gApps.Length " 项安装记录"
}

OnSize(guiObj, minMax, width, height) {
    global gCW, gCH
    if (minMax = -1 || width < 1 || height < 1 || !IsObject(gScroll))
        return
    gCW := width, gCH := height
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
    global gBand, gList, gScroll, gInfo
    global gStBand, gStatus, gBtnMain, gBtnSub
    global gSearchLabel, gSearchFrame, gSearch
    RIGHT := cw - EDGE
    rowW := cw - 2 * EDGE
    LIST_Y := 46                       ; 搜索行(12..40) + BLOCK_GAP(6) 之下
    ST_Y := ch - H_STATUS
    ACT_Y := ST_Y - BLOCK_GAP - H_ACTION
    LIST_H := ACT_Y - BLOCK_GAP - LIST_Y
    if (LIST_H < 60)
        LIST_H := 60

    ; 搜索行：标签固定，输入框吃满行宽（右侧贴内容右缘）。
    gSearchLabel.Move(EDGE, 12, 32, H_ACTION)
    gSearchFrame.Move(56, 12, rowW - 40, H_ACTION)
    gSearch.Move(57, 13, rowW - 42, H_ACTION - 2)
    SetEditRect(gSearch.Hwnd, 8, 2, rowW - 50, 26)

    ; 四条 1px 线围边 + 白底垫块（BuildGui 注释解释为什么必须）。
    gLvWhite.Move(EDGE + 1, LIST_Y + 1 + H_HEADER, rowW - 2, LIST_H - 2 - H_HEADER)
    gLineTop.Move(EDGE, LIST_Y, rowW, 1)
    gLineBot.Move(EDGE, LIST_Y + LIST_H - 1, rowW, 1)
    gLineLft.Move(EDGE, LIST_Y, 1, LIST_H)
    gLineRgt.Move(EDGE + rowW - 1, LIST_Y, 1, LIST_H)
    gBand.Move(EDGE + 1, LIST_Y + 1, rowW - 2, H_HEADER)

    ; 列表几何交给 gScroll：它按内容超出与否决定给竖条留 10px，再 Move 列表（K43）。
    gScroll.x := EDGE + 1, gScroll.y := LIST_Y + 1 + H_HEADER
    gScroll.w := rowW - 2, gScroll.h := LIST_H - 2 - H_HEADER
    gScroll.Layout()
    FixCols()

    ; 静态色块失效：★只改几何不会触发重画，但**背景块绝不能单独失效**——
    ; AHK 的 Text 背景块是兄弟窗口且 z 序在内容控件之上，单独重画它会把内容整块盖成
    ; 纯色（实测：搜索框被 B7C8E0 盖成一块纯色）。顺序统一「背景块 → 它的内容控件」，
    ; 两者都失效，内容才会在背景之后画回来（K47 的整窗 Redraw 仍要避免，会闪）。
    for c in [gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt, gBand
        , gHdr1, gHdr2, gHdr3, gHdr4, gHdr5
        , gSearchFrame, gSearchLabel, gSearch]
        DllCall("user32\InvalidateRect", "Ptr", c.Hwnd, "Ptr", 0, "Int", 1)

    xSub := RIGHT - gBtnSub.w
    xMain := xSub - INLINE_GAP - gBtnMain.w
    MoveBtn(gBtnMain, xMain, ACT_Y)
    MoveBtn(gBtnSub, xSub, ACT_Y)
    ; ★ 按钮是两层 Text（外框 + 内层）：Move 后必须两层都失效擦背景，
    ;   否则 Windows 把旧位图搬到新位置，堆成竖条纹（用户截图实证）。
    for b in [gBtnMain, gBtnSub] {
        DllCall("user32\InvalidateRect", "Ptr", b.outer.Hwnd, "Ptr", 0, "Int", 1)
        DllCall("user32\InvalidateRect", "Ptr", b.inner.Hwnd, "Ptr", 0, "Int", 1)
    }
    gInfo.Move(EDGE, ACT_Y, xMain - EDGE - INLINE_GAP, H_ACTION)

    gStBand.Move(0, ST_Y, cw, H_STATUS)
    gStatus.Move(12, ST_Y, cw - 24, H_STATUS)
    for c in [gStBand, gStatus, gInfo]
        DllCall("user32\InvalidateRect", "Ptr", c.Hwnd, "Ptr", 0, "Int", 1)
}

; 列宽按「可视宽」分配：出现竖条时可视宽少 10px，首列跟着收，否则长路径被裁。
; 横向条撤掉，列宽做进视口（K30）。列宽和 = 列表可视宽，不留死区（§10.3.3）。
; 改列宽后必须整表 Redraw（K31：行底色停在旧列宽），再补摘一次原生条（K34）。
; 安装模式 5 列（名称/版本/发行者/安装时间/状态），残留模式第 5 列宽 0（只用前 4 列）。
ColWidths(w) {
    global gMode
    if (gMode = "installed") {
        ; 安装时间留 112：日期 "2026-07-29" 加左右内边距在雅黑 10pt 下正好放得下；
        ; 96 会截成省略号（1.0.5 实测截图）。
        c1 := Max(160, w - 440)          ; 78+128+112+122 = 440
        return [c1, 78, 128, 112, 122]
    }
    c1 := Max(160, w - 328)              ; 78+128+122 = 328，第 5 列收为 0
    return [c1, 78, 128, 122, 0]
}

FixCols() {
    global gList, gScroll
    w := gScroll ? gScroll.ClientW() : 0
    if (w <= 0)
        return
    for i, c in ColWidths(w)
        gList.ModifyCol(i, c)
    AlignHeaders(w)
    ; 顺序照《打开方式清理》1.5.x：ModifyCol 会把原生条样式位重新置回，comctl32 随后
    ; 连非客户区一起把灰条画出来。必须先摘条、重画自绘条，最后才整表重绘；反过来
    ; （先 Redraw 再 HideNative）等于把灰条先画到屏幕上、再只摘样式位，那 16px 灰条
    ; 会一直留在列表右侧——用户看到的「滚动时旧的滚动条」。
    if IsObject(gScroll) {
        gScroll.HideNative()
        gScroll.Paint()           ; 列宽/视口可能已变，滑块按最新几何重画
    }
    try gList.Redraw()
}

; 列头文字块 x = 列表左缘(EDGE+1) + 列起点 + CELL_PAD（§10.3.3），随竖条显隐同步移动。
; 第 5 列宽 0 时（残留模式）把该列头收掉，避免在带尾留一段空文字块。
AlignHeaders(listW) {
    global gHdr1, gHdr2, gHdr3, gHdr4, gHdr5, CELL_PAD, H_HEADER
    cw := ColWidths(listW)
    hs := [gHdr1, gHdr2, gHdr3, gHdr4, gHdr5]
    hx := EDGE + 1
    for i, c in cw {
        if (c <= 0)
            hs[i].Move(0, 47, 0, H_HEADER)
        else
            hs[i].Move(hx + CELL_PAD, 47, c - 12, H_HEADER)
        hx += c
    }
    for h in hs
        DllCall("user32\InvalidateRect", "Ptr", h.Hwnd, "Ptr", 0, "Int", 1)
}

; ── 模式切换：installed（名称/版本/发行者/安装时间/状态）↔ leftover（路径/类型/大小/说明）
SwitchMode(m) {
    global gMode, gList, gBtnMain, gBtnSub, gSortCol, gSortDesc, gSearch, gSearchText
    gMode := m
    gSortCol := 0, gSortDesc := false    ; 列含义随模式变，切模式重置排序
    gSearchText := ""                     ; 切视图清空搜索，避免过滤串到另一列表
    if IsObject(gSearch)
        gSearch.Value := ""
    if (m = "installed") {
        ; 摘掉复选框扩展样式（保留双缓冲位）
        DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10004, "Ptr", 0x10000)
        SwitchButton(gBtnMain, "卸载")
        SwitchButton(gBtnSub, "重新扫描")
    } else {
        ; LVS_EX_CHECKBOXES：残留清理按勾选行执行
        DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10004, "Ptr", 0x10004)
        SwitchButton(gBtnMain, "清理残留")
        SwitchButton(gBtnSub, "返回列表")
    }
    UpdateHeaderArrows()
    FixCols()
    Layout(gCW, gCH)
}

; 1.0.14 起按 K36 配方填表，与《打开方式清理》FillList 完全同款（顺序不能动）：
; SW_HIDE → WM_SETREDRAW 0 → Delete/Add → HideNative → SETREDRAW 1 → SW_SHOW
; → 补焦点 → Layout/FixCols。
; ★1.0.13 及以前刻意不藏表，理由是「SW_SHOW 会把原生灰条画到屏上」——那是顺序错：
;   摘条（HideNative）必须放在 SETREDRAW 1 / SW_SHOW **之前**。放在之后就是「先把灰条
;   画上、再只摘样式位」，像素擦不掉，于是「滚一下/一过滤就冒出老式滚动条」。
;   WM_SETREDRAW 只压得住客户区绘制，压不住非客户区；藏起来的窗口一个像素都不画，
;   这才是唯一能保证填表期灰条不出现的做法（UI规范 L274 / UI组件手册 §4.3）。
; 数据源是 gView（已搜索过滤 + 排序），不是 gApps/gLeft 本身。
RefreshList() {
    global gMode, gList, gView, gScroll, gLvTipKey, gGui
    if (!IsObject(gList) || !gList.Hwnd)
        return
    hadFocus := gGui.FocusedCtrl && gGui.FocusedCtrl.Hwnd = gList.Hwnd
    DllCall("user32\ShowWindow", "Ptr", gList.Hwnd, "Int", 0)          ; SW_HIDE
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x000B, "Ptr", 0, "Ptr", 0, "Ptr")  ; WM_SETREDRAW FALSE
    gList.Delete()
    if (gMode = "installed") {
        for a in gView
            gList.Add("", a.name, a.version, a.publisher, a.instDate, StatusText(a))
    } else {
        for it in gView {
            sizeTxt := "—"
            if (!it.isReg) {
                if (it.bytes = -1)
                    sizeTxt := "文件过多"          ; 数量超上限放弃统计，不是体积超限（1.txt#18）
                else if (it.bytes >= BIG_FOLDER)
                    sizeTxt := "> 2 GB"
                else if (it.bytes = -2)
                    sizeTxt := "链接"
                else
                    sizeTxt := FormatSize(it.bytes)
            }
            row := gList.Add("", it.path, it.kind, sizeTxt, it.note, "")
            if (it.checked)
                gList.Modify(row, "Check")
        }
    }
    ; 摘条要在恢复重绘/显示之前：显示之后 ListView 会连非客户区一起重刷，
    ; 样式位还在就等于把灰条画到屏幕上（顺序不能动）。
    if IsObject(gScroll)
        gScroll.HideNative()
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x000B, "Ptr", 1, "Ptr", 0, "Ptr")  ; WM_SETREDRAW TRUE
    ; SW_SHOWNA(8) 而不是 SW_SHOW(5)：后者会把列表提到 z 序最顶，自绘条与原生条遮罩
    ; 就全被压在列表下面（实测：遮罩块掉到 z 序最底，原生条照样露出来）。
    DllCall("user32\ShowWindow", "Ptr", gList.Hwnd, "Int", 8)          ; SW_SHOWNA
    ; 藏过一次会丢焦点，补回来（K39）；焦点本来在搜索框时不动它。
    if (hadFocus || !gGui.FocusedCtrl)
        gList.Focus()
    if IsObject(gScroll) {
        gScroll.Layout()                                            ; 重算占位 + 画自绘条
        FixCols()
    }
    ToolTip()                                                       ; 行变了，清掉旧的悬停提示
    gLvTipKey := ""
}

UpdateSummary() {
    global gMode, gApps, gLeft, gView, gInfo
    if (gMode = "installed") {
        ok := 0, miss := 0
        for a in gApps {
            k := a.info.kind
            if (k = "gone" || k = "none")
                miss++
            else
                ok++
        }
        txt := "安装记录 " gApps.Length " 项 · 可卸载 " ok " 项"
        if miss
            txt .= " · 异常 " miss " 项"
        if (gView.Length != gApps.Length)
            txt .= " · 显示 " gView.Length " 项"
        gInfo.Value := txt
    } else {
        nf := 0, nr := 0, big := 0
        for it in gLeft {
            if it.isReg
                nr++
            else
                nf++
            if (!it.isReg && it.bytes >= BIG_FOLDER)
                big++
        }
        txt := "残留 " gLeft.Length " 项（文件夹 " nf " · 注册表键 " nr "）"
        if big
            txt .= " · 过大 " big " 项"
        if (gView.Length != gLeft.Length)
            txt .= " · 显示 " gView.Length " 项"
        gInfo.Value := txt
    }
}

; ═════════════════════════════════════════════════════════════════════
;  无 GUI 分支：--selftest [输出路径] / --report [输出路径]
; ═════════════════════════════════════════════════════════════════════
; 位数守卫挡在所有分支之前（4.txt N3：--selftest/--report 也扫注册表，32 位下结果失真）。
; N6：各分支先算好结果文件路径，再以无 GUI 模式守卫——32 位下写 FAIL + ExitApp(1)，
; 不弹框、不产生"rc=0 + 无文件"假通过。
if (A_Args.Length >= 1 && A_Args[1] = "--selftest") {
    selftestPath := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\软件卸载\selftest-result.txt"
    CheckRuntime(false, selftestPath)
    RunSelfTest(selftestPath)
}
if (A_Args.Length >= 1 && A_Args[1] = "--report") {
    reportPath := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\软件卸载\report.txt"
    CheckRuntime(false, reportPath)
    RunReport(reportPath)
}
CheckRuntime()    ; GUI 路径位数守卫（BuildGui 内不再调用）

RunSelfTest(path) {
    global gSelfTestPath
    gSelfTestPath := path
    out := ""
    Emit(s) => out .= s "`n"
    uid := "AHKDeckSelfTestFoo"
    myPid := DllCall("kernel32\GetCurrentProcessId", "UInt")   ; AHK v2 无 A_PID

    ; 1. 名称清洗与归一
    Emit((CleanName("Foo Bar 2.1.0 (x64)") = "Foo Bar" ? "PASS " : "FAIL ") "CleanName 去括注与版本号")
    Emit((CleanName("Fallout 4") = "Fallout 4" ? "PASS " : "FAIL ") "CleanName 保留单个数字（Fallout 4）")
    Emit((CleanName("  Foo Bar  ") = "Foo Bar" ? "PASS " : "FAIL ") "CleanName 去首尾空白")
    Emit((Norm("Foo-Bar_v2") = "foobarv2" ? "PASS " : "FAIL ") "Norm 去分隔符")
    Emit((Norm("微信测试") = "微信测试" ? "PASS " : "FAIL ") "Norm 保留常用汉字")

    ; 2. 泛用名黑名单
    Emit((IsGenericNorm("data") ? "PASS " : "FAIL ") "泛用名 data 被拦")
    Emit((IsGenericNorm("microsoft") ? "PASS " : "FAIL ") "泛用名 microsoft 被拦")
    Emit((!IsGenericNorm("fallout4") ? "PASS " : "FAIL ") "普通名不误拦")

    ; 3. MSI 产品码
    g := ExtractMsiGuid("MsiExec.exe /I{12345678-1234-1234-1234-123456789ABC}")
    Emit((g = "{12345678-1234-1234-1234-123456789ABC}" ? "PASS " : "FAIL ") "ExtractMsiGuid 取 /I{GUID}")
    Emit((ExtractMsiGuid('"C:\x\unins000.exe"') = "" ? "PASS " : "FAIL ") "ExtractMsiGuid 无 GUID 返回空")
    Emit((BuildMsiCommand("{AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111}")
        = "msiexec.exe /X{AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111} /qn /norestart" ? "PASS " : "FAIL ")
        "BuildMsiCommand 生成静默串")

    ; 4. 卸载串解析（三形态）
    p := SplitCommand('"C:\Program Files\X\unins000.exe" /x')
    Emit((p[1] = "C:\Program Files\X\unins000.exe" && p[2] = "/x" ? "PASS " : "FAIL ") "SplitCommand 带引号")
    p := SplitCommand("MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}")
    Emit((p[1] = "MsiExec.exe" && InStr(p[2], "/X") = 1 ? "PASS " : "FAIL ") "SplitCommand 裸命令")
    ; 无引号含空格：造真实文件验证"最长存在的 .exe 前缀"
    tmp := A_Temp "\ahkdeck-unin-selftest-" myPid
    try DirDelete(tmp, 1)
    try DirCreate(tmp "\X Y")
    try FileAppend("x", tmp "\X Y\uninst.exe")
    p := SplitCommand(tmp "\X Y\uninst.exe /S")
    Emit((p[1] = tmp "\X Y\uninst.exe" && p[2] = "/S" ? "PASS " : "FAIL ") "SplitCommand 无引号含空格路径")
    ; Q6：.exe 后紧跟制表符不再落到按空格切分的错误分支
    p := SplitCommand(tmp "\X Y\uninst.exe`t/S")
    Emit((p[1] = tmp "\X Y\uninst.exe" && p[2] = "/S" ? "PASS " : "FAIL ") "SplitCommand 制表符分隔")
    try DirDelete(tmp, 1)

    ; 5. 家族判定
    try DirCreate(tmp)
    try FileAppend("x", tmp "\unins000.exe")
    try FileAppend("y", tmp "\unins000.dat")
    Emit((DetectFamily(tmp "\unins000.exe") = "Inno" ? "PASS " : "FAIL ") "家族判定 Inno（unins000+dat）")
    try FileDelete(tmp "\unins000.dat")
    Emit((DetectFamily(tmp "\unins000.exe") != "Inno" ? "PASS " : "FAIL ") "Inno 判定必须有 .dat 日志")
    try FileDelete(tmp "\unins000.exe")
    try FileAppend("x", tmp "\update.exe")
    Emit((DetectFamily(tmp "\update.exe") = "Squirrel" ? "PASS " : "FAIL ") "家族判定 Squirrel（update.exe）")
    ; Q10：update.exe 不在应用安装目录内 → 无归属证据，不判 Squirrel
    Emit((!SquirrelOwned(tmp "\update.exe", {name: "X", publisher: "", location: ""})
        ? "PASS " : "FAIL ") "Squirrel 无归属证据（location 空）不成立")
    Emit((SquirrelOwned(tmp "\update.exe", {name: "X", publisher: "", location: tmp})
        ? "PASS " : "FAIL ") "Squirrel 归属成立（update.exe 在安装目录内）")
    try FileDelete(tmp "\update.exe")
    try FileAppend("Nullsoft Install System v3.0", tmp "\uninst.exe")
    Emit((DetectFamily(tmp "\uninst.exe") = "NSIS" ? "PASS " : "FAIL ") "家族判定 NSIS（内容扫 Nullsoft）")
    try DirDelete(tmp, 1)

    ; 5b. quiet 串校验：指向不存在文件时回落常规链（1.txt#3 / 3.txt Q3）
    try DirCreate(tmp)
    try FileAppend("x", tmp "\real.exe")
    fq := {quiet: '"C:\nonexistent-probe\uninst.exe" /S', msi: "", uninstall: tmp "\real.exe", location: ""}
    Emit((DecideCommand(fq).kind != "quiet" ? "PASS " : "FAIL ") "quiet 串文件缺失时回落常规链")
    Emit((QuietUnsafe("http://example.com/uninstall.htm") ? "PASS " : "FAIL ") "QuietUnsafe 拦网页 URL")
    Emit((!QuietUnsafe(tmp "\real.exe") ? "PASS " : "FAIL ") "QuietUnsafe 放行本地 exe")
    try DirDelete(tmp, 1)

    ; 6. 决策链优先级
    fa := {quiet: "msiexec /qn", msi: "{AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111}", uninstall: "x.exe", location: ""}
    Emit((DecideCommand(fa).kind = "quiet" ? "PASS " : "FAIL ") "决策链 QuietUninstallString 优先（白名单宿主）")
    ; 4.txt Q3：裸名不在宿主白名单 → 不得静默执行，回落常规链
    fb0 := {quiet: "quiet-cmd", msi: "", uninstall: "", winInstaller: "0", location: ""}
    Emit((DecideCommand(fb0).kind != "quiet" ? "PASS " : "FAIL ") "Quiet 裸名不在白名单 → 回落（不再无条件执行）")
    fb := {quiet: "", msi: "{AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111}", uninstall: "x.exe", location: ""}
    r := DecideCommand(fb)
    Emit((r.kind = "msi" && InStr(r.cmd, "/X{AAAABBBB") && InStr(r.cmd, "/qn /norestart")
        ? "PASS " : "FAIL ") "决策链 MSI 改写 /X /qn /norestart")
    fc := {quiet: "", msi: "", uninstall: "", winInstaller: "0", location: ""}
    Emit((DecideCommand(fc).kind = "none" ? "PASS " : "FAIL ") "决策链 无卸载器 → none")

    ; 7. Within 包含判定
    Emit((Within("c:\pf\x", "c:\pf") && !Within("c:\pf", "c:\pf\x") ? "PASS " : "FAIL ") "Within 方向性")
    Emit((Within("c:\pf\x", "c:\pf\x") ? "PASS " : "FAIL ") "Within 相等算包含")
    Emit((!Within("c:\pfxy", "c:\pf") ? "PASS " : "FAIL ") "Within 不做前缀误判（pfxy 不在 pf 内）")

    ; 7b. 阈值与黑名单扩展
    wechat := {name: "微信", publisher: "", location: "C:\Program Files\Tencent\WeChat"}
    ws := StrongNames(wechat)
    Emit((InArray(ws, "微信") ? "PASS " : "FAIL ") "StrongNames 2 字符中文名（微信）不被排除")
    Emit((InArray(ws, "wechat") ? "PASS " : "FAIL ") "StrongNames 目录尾段阈值降到 3（WeChat）")
    Emit((IsGenericNorm("数据") && IsGenericNorm("缓存") ? "PASS " : "FAIL ") "中文泛用名进黑名单")
    lt := Trim(' "C:\MyApp\" ', ' "')
    Emit((RTrim(lt, "\") = "C:\MyApp" ? "PASS " : "FAIL ") "location 只 Trim 引号空格、反斜杠单独 RTrim")

    ; 8. 注册表：键存在判定 + 残留匹配 + 备份后删除（自建自清）
    kp := "HKCU\Software\" uid
    RegWrite("x", "REG_SZ", kp)
    Emit((RegKeyExists(kp) ? "PASS " : "FAIL ") "RegKeyExists 自建键判定")
    ; 安装时间兜底：键最后写入时间是可用的日期
    Emit((RegKeyDate(kp) ~= "^\d{4}-\d{2}-\d{2}$" ? "PASS " : "FAIL ") "RegKeyDate 取登记键写入日期")
    Emit((PathDate(A_Temp) ~= "^\d{4}-\d{2}-\d{2}$" ? "PASS " : "FAIL ") "PathDate 取目录创建日期")
    Emit((FormatInstallDate("20240305") = "2024-03-05" && FormatInstallDate("2024") = ""
        ? "PASS " : "FAIL ") "FormatInstallDate 8 位数字转日期")
    ; 悬停提示判据：只有量宽超过列宽才算截断
    Emit((CellTip("A", 78) = "" && CellTip("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 40) != ""
        ? "PASS " : "FAIL ") "CellTip 只有超宽才给提示")
    app := {name: "AHKDeck SelfTest Foo", publisher: "", location: ""}
    strong := StrongNames(app)
    Emit((InArray(strong, Norm(uid)) ? "PASS " : "FAIL ") "StrongNames 取清洗后名")
    found := []
    ScanLeftoverRegistry(strong, [], "", Map(), Map(), found)
    hit := false
    for it in found
        if (it.path = kp)
            hit := true
    Emit((hit ? "PASS " : "FAIL ") "残留扫描找出自建键")
    others := [{name: "AHKDeck SelfTest Foo", version: "", publisher: "", location: "", msi: "", quiet: "", uninstall: "", winInstaller: "", info: 0}]
    found2 := []
    ScanLeftoverRegistry(strong, [], "", OthersNormNames(others), Map(), found2)
    hit2 := false
    for it in found2
        if (it.path = kp)
            hit2 := true
    Emit((!hit2 ? "PASS " : "FAIL ") "交叉引用排除（仍安装同名应用时不匹配）")
    bd := A_Temp "\ahkdeck-unin-selftest-reg-" myPid
    if !DirExist(bd)
        try DirCreate bd
    res := BackupAndDeleteKey(kp, bd, 1)
    regFile := bd "\1 " SafeKeyFile(kp) ".reg"
    Emit((res[1] && !RegKeyExists(kp) ? "PASS " : "FAIL ") "备份后删除注册表键")
    Emit((FileExist(regFile) ? "PASS " : "FAIL ") ".reg 备份文件已生成")
    try DirDelete(bd, 1)

    ; 9. 大小阈值 + MSI 门控（2.txt A3 回归：非 msiexec 串带 GUID 不判 MSI）
    Emit((BIG_FOLDER = 2147483648 ? "PASS " : "FAIL ") "大文件夹阈值 2GB")
    Emit((ExtractMsiGuid('"C:\x\uninst.exe" {AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}') = ""
        ? "PASS " : "FAIL ") "非 msiexec 串带 GUID 不判 MSI（门控）")

    ; 10. junction 契约（2.txt 建议的安全回归）：删链接后目标内容仍在
    jt := A_Temp "\ahkdeck-unin-selftest-junction-" myPid
    tg := A_Temp "\ahkdeck-unin-selftest-jtarget-" myPid
    try DirDelete(jt, 1)
    try DirDelete(tg, 1)
    try DirCreate(tg)
    try FileAppend("keepme", tg "\keep.txt")
    RunWait('cmd /c mklink /J "' jt '" "' tg '"', , "Hide")
    if DirExist(jt) {
        jres := DeleteReparseOnly(jt)
        Emit((jres[1] && !DirExist(jt) ? "PASS " : "FAIL ") "junction 删除：链接本身被删")
        Emit((FileExist(tg "\keep.txt") ? "PASS " : "FAIL ") "junction 删除后目标内容仍在（安全契约）")
    } else {
        Emit("SKIP  mklink /J 不可用（环境限制）")
    }
    try DirDelete(jt, 1)
    try DirDelete(tg, 1)

    ; 搜索过滤 + 列排序（纯函数 FilterSortRows，不依赖 GUI）
    fa := [{name: "Bravo", version: "2", publisher: "Acme", instDate: "2024-01-01", info: {kind: "raw"}}
        , {name: "alpha", version: "1", publisher: "Zeta", instDate: "2025-06-02", info: {kind: "msi"}}
        , {name: "Charlie", version: "3", publisher: "acme", instDate: "2023-12-31", info: {kind: "quiet"}}]
    Emit((FilterSortRows(fa, "installed", "a", 0, false).Length = 3 ? "PASS " : "FAIL ") "过滤 含 a 命中全部")
    Emit((FilterSortRows(fa, "installed", "bravo", 0, false).Length = 1 ? "PASS " : "FAIL ") "过滤 bravo 命中 1")
    Emit((FilterSortRows(fa, "installed", "ACME", 0, false).Length = 2 ? "PASS " : "FAIL ") "过滤发行者大小写不敏感命中 2")
    s1 := FilterSortRows(fa, "installed", "", 1, false)
    Emit((s1[1].name = "alpha" && s1[3].name = "Charlie" ? "PASS " : "FAIL ") "名称升序 alpha 最先（大小写不敏感）")
    s1d := FilterSortRows(fa, "installed", "", 1, true)
    Emit((s1d[1].name = "Charlie" ? "PASS " : "FAIL ") "名称降序 Charlie 最先")
    sd := FilterSortRows(fa, "installed", "", 4, false)
    Emit((sd[1].instDate = "2023-12-31" && sd[3].instDate = "2025-06-02" ? "PASS " : "FAIL ") "安装时间升序 最早在前")
    Emit((FilterSortRows(fa, "installed", "zzz", 0, false).Length = 0 ? "PASS " : "FAIL ") "过滤无命中返回空")

    fails := 0
    for line in StrSplit(out, "`n")
        if SubStr(line, 1, 5) = "FAIL "
            fails++
    Emit("fails=" fails)
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

; 仍安装应用集合的归一名（交叉引用排除用）
OthersNormNames(others) {
    m := Map()
    for o in others {
        n := Norm(CleanName(o.name))
        if (n != "")
            m[n] := 1
        t := Norm(PathLeaf(RTrim(o.location, "\")))
        if (StrLen(t) >= 3)
            m[t] := 1
    }
    return m
}

; ── --report：只读取证（扫描分步行数/耗时，定位慢在哪一段）─────────────
RunReport(path) {
    global gSelfTestPath
    gSelfTestPath := path
    out := ""
    sources := ["HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        , "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        , "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall"]
    t0 := A_TickCount
    for src in sources {
        t := A_TickCount
        n := 0
        Loop Reg, src, "K"
            n++
        out .= "step" A_Index " keys_raw=" n " ms=" (A_TickCount - t) " src=" src "`n"
    }
    t := A_TickCount
    apps := ScanInstalled()
    out .= "step4 scan_rows=" apps.Length " ms=" (A_TickCount - t) "`n"
    t := A_TickCount
    quiet := 0, msi := 0, fam := 0, raw := 0, gone := 0, none := 0
    for a in apps {
        k := a.info.kind
        if (k = "quiet")
            quiet++
        else if (k = "msi")
            msi++
        else if (k = "inno" || k = "nsis" || k = "squirrel")
            fam++
        else if (k = "raw")
            raw++
        else if (k = "gone")
            gone++
        else
            none++
    }
    out .= "step5 classify quiet=" quiet " msi=" msi " family=" fam " raw=" raw
        . " gone=" gone " none=" none " ms=" (A_TickCount - t) "`n"
    out .= "rows_total=" apps.Length " scan_ms=" (A_TickCount - t0) "`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(0)
}

BuildGui()
