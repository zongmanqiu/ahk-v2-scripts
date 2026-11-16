; ==UserScript==
; @name         硬件信息
; @id           hardware-info
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      2.3.3
; @description  左侧导航分页查看 CPU/主板/内存/显卡/磁盘/网卡/显示器/系统，逐项列出详细规格
; @author       邱宗满
; @date         2026-11-16
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（包模式需 0.3.6 起；亦可独立运行）
; @entry        主窗口左侧八页导航（选中项高亮），窗口可缩放/最大化；列表右键复制本行/本页、Ctrl+C、F5 重采；--selftest 为无 GUI 分支
; ==/UserScript==
;
; 硬件信息：一屏按硬件分页，每页把该硬件的属性逐行列出。
; 数据全部来自 WMI（root\cimv2 与 root\wmi），另用 SMBIOS 原始表补 Rank——都不需要管理员、
; 不装驱动、不联网、不触碰硬件总线。
; 页面与来源：
;   CPU   Win32_Processor                     主板 Win32_BaseBoard + Win32_BIOS
;   内存  Win32_PhysicalMemory/Array + SMBIOS 显卡 Win32_VideoController
;   磁盘  Win32_DiskDrive + Win32_LogicalDisk 网卡 Win32_NetworkAdapter(物理)
;   显示器 root\wmi WmiMonitorID/BasicParams  系统 Win32_OperatingSystem + ComputerSystem
; 只列规格，不列仪表：CPU 当前频率/负载、可用内存这类每秒钟都在变的瞬时值一律不显示
; （那是任务管理器的活），窗口里每一行读出来都是稳定的硬件事实。
; 明确不做（能做到才写，做不到就说做不到）：
;   内存时序/DRAM 颗粒厂/XMP/EXPO/SPD 温度（只在 SPD EEPROM，需签名内核驱动）；
;   硬盘 S.M.A.R.T. 健康度（需 DeviceIoControl 直读，且各厂字段不一，留给专门工具）；
;   显卡温度/功耗/风扇（需厂商 SDK 或驱动接口）。
; 已知字段局限（如实展示，不修饰）：
;   Win32_VideoController.AdapterRAM 是 32 位，显存 ≥4GB 会显示为 4095MB 上限，故只作参考；
;   部分模组不写 PartNumber（实测金百达），空值显示「未提供」。
; 本项目独立实现，未复刻任何第三方源码；许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ══════════════════════════════════════════════════════════════════════════
; UI 组件区：本脚本所有界面元素都从这一区取，改样式只动这一区。
; 基准 = 开发指南 §10（八色令牌 / 字号 / 尺寸令牌 / 标准片段 K19 K22 K27 K24）。
; 滚动条与《文件时间修改》2.4.6 的 class FlatScroll 同源，改这里要同步那份。
; 注意：§10.1 禁止抽公共 #Include UI 库（多一个文件就破坏单文件分发模型），
; 跨脚本「统一」只能靠「同一份实现 + 逐字同步」，不是靠共享文件。
; ══════════════════════════════════════════════════════════════════════════

; ── 码表 ─────────────────────────────────────────────────────────────
; 内存类型用 SMBIOS 7.18.2 的码（WMI 的 SMBIOSMemoryType 就是这套）。注意它和
; WMI 另一个属性 MemoryType 不是一套码：DDR5 在这里是 0x22，在 MemoryType 里是 0x18。
; 整套表以 dmidecode 上游 dmi_memory_device_type() 为准，别自己按"顺序推"。
TYPE_NAME := Map(0x01, "其他", 0x02, "未知", 0x03, "DRAM", 0x04, "EDRAM", 0x05, "VRAM",
                 0x06, "SRAM", 0x07, "RAM", 0x08, "ROM", 0x09, "Flash", 0x0A, "EEPROM",
                 0x0B, "FEPROM", 0x0C, "EPROM", 0x0D, "CDRAM", 0x0E, "3DRAM", 0x0F, "SDRAM",
                 0x10, "SGRAM", 0x11, "RDRAM", 0x12, "DDR", 0x13, "DDR2", 0x14, "DDR2 FB-DIMM",
                 0x18, "DDR3", 0x19, "FBD2", 0x1A, "DDR4", 0x1B, "LPDDR", 0x1C, "LPDDR2",
                 0x1D, "LPDDR3", 0x1E, "LPDDR4", 0x1F, "逻辑非易失设备", 0x20, "HBM",
                 0x21, "HBM2", 0x22, "DDR5", 0x23, "LPDDR5", 0x24, "HBM3")
ECC_NAME := Map(1, "其他", 2, "未知", 3, "无", 4, "Parity", 5, "单比特 ECC", 6, "多比特 ECC", 7, "CRC")
; 封装用 WMI 的 FormFactor，那是 CIM 自己的枚举（8=DIMM、12=SODIMM），
; 和 SMBIOS 7.18.1 的 FormFactor（9=DIMM、13=SODIMM）差一位，两者不能混用。
FORM_NAME := Map(0, "未知", 1, "其他", 2, "SIP", 3, "DIP", 4, "ZIP", 5, "SOJ", 6, "专用",
                 7, "SIMM", 8, "DIMM", 9, "TSOP", 10, "PGA", 11, "RIMM", 12, "SODIMM",
                 13, "SRIMM", 14, "SMD", 15, "SSMP", 16, "QFP", 17, "TQFP", 18, "SOIC",
                 19, "LCC", 20, "PLCC", 21, "BGA", 22, "FPBGA", 23, "LGA")
; SMBIOS 7.18 Type 17 offset 0x1B 的 Attributes：bit3:0 是 Rank 数，0 表示主板没填。
; （dmidecode 上游取 data[0x1B] & 0x0F；早先这里写成 bit3:4 是错的，单 Rank 条
; 恰好也算出 0 才没在实机上露馅。）索引就是 Rank 数，没有 0 这一档。
RANK_NAME := Map(1, "1R", 2, "2R", 3, "3R", 4, "4R")
ARCH_NAME := Map(0, "x86", 1, "MIPS", 2, "Alpha", 3, "PowerPC", 5, "ARM", 6, "Itanium",
                 9, "x64", 12, "ARM64")
; 机箱类型同为 SMBIOS 7.4.1 码（dmidecode dmi_chassis_type），17 之后别按字面猜。
CHASSIS_NAME := Map(1, "其他", 2, "未知", 3, "台式机", 4, "低矮台式机", 5, "薄型台式机",
                    6, "迷你塔式", 7, "塔式", 8, "便携式", 9, "笔记本", 10, "笔记本",
                    11, "手持设备", 12, "坞站", 13, "一体机", 14, "子笔记本", 15, "空间节省型",
                    16, "午餐盒式", 17, "主服务器机箱", 18, "扩展机箱", 19, "子机箱",
                    20, "总线扩展机箱", 21, "外设机箱", 22, "RAID 机箱", 23, "机架式",
                    24, "密封机箱", 25, "多系统机箱", 26, "CompactPCI", 27, "AdvancedTCA",
                    28, "刀片", 29, "刀片机箱", 30, "平板", 31, "可翻转", 32, "可拆卸",
                    33, "IoT 网关", 34, "嵌入式 PC", 35, "迷你主机", 36, "U 盘式 PC")
; 显示器接口：VideoOutputTechnology 枚举（WmiMonitorConnectionParams）。
CONN_NAME := Map(0, "VGA（模拟）", 1, "S-Video", 2, "复合视频", 3, "分量视频", 4, "DVI", 5, "HDMI"
               , 6, "LVDS（内置屏）", 8, "D-Terminal", 9, "SDI", 10, "DisplayPort", 11, "DisplayPort（内置）"
               , 12, "UDI", 13, "UDI（内置）", 14, "SDTV", 15, "Miracast（无线）"
               , 2147483648, "内置")
NETSTATUS_NAME := Map(0, "未连接", 1, "正在连接", 2, "已连接", 7, "媒体断开",
                      8, "正在验证", 9, "验证成功", 10, "验证失败", 11, "地址无效", 12, "需要凭据")
; 显示器厂商码是 EDID 里的 3 字母 PnP ID（小米＝XMI、联想＝LEN）。原样输出，不做翻译：
; 系统给什么就显示什么，品牌归属由使用者自己判断，脚本不替它下结论。

; §10 八色令牌
C_WHITE := "FFFFFF"
C_BG := "F7F9FC"
C_SOFT := "EBF2FB"
C_BAND := "DCE8F7"
C_FRAME := "B7C8E0"
C_TEXT := "202B3A"
C_ACCENT_SOFT := "BFD5F0"
C_ACCENT := "6E9BD4"

NAV_W := 76
NAV_ITEM_H := 28
NAV_GAP := 4
NAV_X := 16
COL_NAME_W := 138

; 窗口几何：无标题行、无状态条，列表紧贴顶边
WIN_W := 672
WIN_H := 520
PAD := 12
LIST_X := NAV_X + NAV_W + 12
LIST_W := WIN_W - LIST_X - PAD
LIST_TOP := PAD
HEAD_H := 26
LIST_H := WIN_H - LIST_TOP - HEAD_H - PAD

gGui := 0, gList := 0, gNavBtns := [], gScroll := 0
gPages := [], gCurPage := 1, gData := 0

; ── 格式化 ───────────────────────────────────────────────────────────
FmtBytes(b) {
    if (b <= 0)
        return "—"
    gib := b / 1073741824
    if (Abs(gib - Round(gib)) < 0.05)
        return Round(gib) " GB"
    return Format("{:.1f} GB", gib)
}

FmtMB(b) {
    if (b <= 0)
        return "—"
    if (b >= 1024)
        return Format("{:.1f} GB", b / 1024)
    return b " MB"
}

FmtMts(cur, conf) {
    if (cur <= 0 && conf <= 0)
        return "—"
    if (conf <= 0 || conf = cur)
        return cur " MT/s"
    return cur "→" conf " MT/s"
}

; 主板最大支持容量（Win32_PhysicalMemoryArray.MaxCapacity，单位 KB）。
; 0x80000000 是 SMBIOS 的"转义值"，真值在 Type 16 扩展字段里，按 KB 直接除会谎报 2048 GB。
MaxCapText(kb) {
    if (!kb)
        return "—"
    if (kb = 0x80000000)
        return "未知（主板用扩展容量字段，WMI 未给出）"
    return Round(kb / 1048576) " GB"
}

TypeName(code) {
    global TYPE_NAME
    return TYPE_NAME.Has(code) ? TYPE_NAME[code] : (code ? "未知(" code ")" : "—")
}

EccName(code) {
    global ECC_NAME
    return ECC_NAME.Has(code) ? ECC_NAME[code] : (code ? "未知(" code ")" : "—")
}

RankName(r) {
    global RANK_NAME
    if (r = "")
        return "—"
    if (r = 0)
        return "未填"
    return RANK_NAME.Has(r) ? RANK_NAME[r] : "未知(" r ")"
}

ArchName(a) {
    global ARCH_NAME
    return ARCH_NAME.Has(a) ? ARCH_NAME[a] : (a ? "未知(" a ")" : "—")
}

ConnName(v) {
    global CONN_NAME
    if (v = "" || v < 0)
        return "—"
    return CONN_NAME.Has(v) ? CONN_NAME[v] : "未知(" v ")"
}

; 硬盘总线：WMI 的 InterfaceType 对 NVMe 盘一律报 "SCSI"（实测 KINGBANK KP230 Pro 就是），
; 真正可靠的线索在 PNPDeviceID 里（SCSI\DISK&VEN_NVME&PROD_...）。
BusName(dk) {
    p := StrUpper(dk.Has("pnpid") ? dk["pnpid"] : "")
    if InStr(p, "VEN_NVME")
        return "NVMe"
    if InStr(p, "USBSTOR")
        return "USB"
    return (dk["iface"] != "") ? dk["iface"] : "—"
}

Dash(v, def := "未提供") {
    s := Trim("" v)
    return s = "" ? def : s
}

; WmiMonitorID 的字段是 byte 数组（ASCII 码点、尾部补零），转字符串。
WmiBytes(v) {
    if !IsObject(v)
        return ""
    s := ""
    try {
        n := v.MaxIndex()
        if (n = "")
            return ""
        loop n + 1 {
            b := v[A_Index - 1]
            if (b = "" || b = 0)
                break
            s .= Chr(b)
        }
    } catch
        return ""
    return s
}

Prop(obj, name, def := "") {
    try {
        v := obj.%name%
    } catch
        return def
    if (v = "" || v = 0)
        return def
    return v
}

NumOf(v) {
    try
        return Integer(v)
    return 0
}

; ── WMI 采集 ─────────────────────────────────────────────────────────
; ── 注册表 / CPUID：WMI 给不全的两类静态信息 ─────────────────────────
; RegRead 读不了 REG_QWORD（实测报 1630「这个类型的数据不受支持」），只能自己调 API。
RegQword(sub, name) {
    h := 0
    if (DllCall("advapi32\RegOpenKeyExW", "Ptr", 0x80000002, "WStr", sub
        , "UInt", 0, "UInt", 0x20019, "Ptr*", &h, "Int") != 0)
        return -1
    buf := Buffer(8, 0), sz := 8, typ := 0
    rc := DllCall("advapi32\RegQueryValueExW", "Ptr", h, "WStr", name, "Ptr", 0
        , "UInt*", &typ, "Ptr", buf, "UInt*", &sz, "Int")
    DllCall("advapi32\RegCloseKey", "Ptr", h)
    return (rc = 0 && typ = 11 && sz = 8) ? NumGet(buf, 0, "Int64") : -1
}

; 显卡驱动把「真实显存」和 vBIOS 写在显示适配器类键下，一个适配器一个 000X 子键。
; MatchingDeviceId 形如 pci\ven_10de&dev_21c4，正好是 PNPDeviceID 的前缀，用它配对。
ReadGpuReg(pnpid) {
    base := "SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    out := Map("ram", -1, "bios", "", "chip", "")
    pnp := StrUpper(Trim("" pnpid))
    if (pnp = "")
        return out
    loop 16 {
        sub := base "\" Format("{:04}", A_Index - 1)
        match := ""
        try match := Trim(RegRead("HKLM\" sub, "MatchingDeviceId"))
        catch
            continue
        if (match = "" || !InStr(pnp, StrUpper(match)))
            continue
        out["ram"] := RegQword(sub, "HardwareInformation.qwMemorySize")
        try out["bios"] := Trim(RegRead("HKLM\" sub, "HardwareInformation.BiosString"))
        try out["chip"] := Trim(RegRead("HKLM\" sub, "HardwareInformation.ChipType"))
        break
    }
    return out
}

; WMI ProcessorId 的后 8 位十六进制是 CPUID 叶 1 的 EAX，含家族/型号/步进。
; 本机 BFEBFBFF00090672 → 0x00090672 → 家族 6 / 型号 151 / 步进 2。
CpuSig(pid) {
    s := Trim("" pid)
    if (StrLen(s) < 8)
        return ""
    eax := 0
    try eax := Integer("0x" SubStr(s, StrLen(s) - 7))
    catch
        return ""
    stepping := eax & 0xF
    baseModel := (eax >> 4) & 0xF
    baseFamily := (eax >> 8) & 0xF
    extModel := (eax >> 16) & 0xF
    extFamily := (eax >> 20) & 0xFF
    family := (baseFamily = 0xF) ? baseFamily + extFamily : baseFamily
    model := (baseFamily = 0x6 || baseFamily = 0xF) ? (extModel << 4) + baseModel : baseModel
    return family " / " model " / " stepping
}

; IsProcessorFeaturePresent 拿到的是内核自己的判定，和 CPUID 一致且不用写机器码。
; 序号取自 winnt.h 的 PF_*（32 位以上那批是 Win10 新增的 SSSE3 之后的指令集）。
CPU_FEATURE := [[3, "MMX"], [6, "SSE"], [10, "SSE2"], [13, "SSE3"], [36, "SSSE3"]
              , [37, "SSE4.1"], [38, "SSE4.2"], [39, "AVX"], [40, "AVX2"], [41, "AVX-512F"]
              , [28, "RDRAND"], [32, "RDTSCP"], [17, "XSAVE"], [20, "SLAT"]]

FeatureList() {
    global CPU_FEATURE
    s := ""
    for f in CPU_FEATURE {
        try {
            if (DllCall("kernel32\IsProcessorFeaturePresent", "UInt", f[1], "Int"))
                s .= (s = "" ? "" : " / ") f[2]
        }
    }
    return s = "" ? "—" : s
}

Collect() {
    d := Map("cpu", Map(), "cpus", [], "board", Map(), "bios", Map(), "cs", Map(), "os", Map(),
             "array", Map(), "sticks", [], "gpus", [], "disks", [], "volumes", [],
             "nets", [], "monitors", [], "sounds", [], "chassis", 0, "tz", "",
             "error", "")
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")

        ; 双路主板会有两条（每插槽一条）：全收，别 break 只留第一颗。
        for o in wmi.ExecQuery("SELECT * FROM Win32_Processor") {
            d["cpus"].Push(Map(
                "name", Trim(Prop(o, "Name")),
                "mfr", Trim(Prop(o, "Manufacturer")),
                "caption", Trim(Prop(o, "Caption")),
                "socket", Trim(Prop(o, "SocketDesignation")),
                "cores", NumOf(Prop(o, "NumberOfCores", 0)),
                "threads", NumOf(Prop(o, "NumberOfLogicalProcessors", 0)),
                "maxMhz", NumOf(Prop(o, "MaxClockSpeed", 0)),
                "extMhz", NumOf(Prop(o, "ExtClock", 0)),
                "l2", NumOf(Prop(o, "L2CacheSize", 0)),
                "l3", NumOf(Prop(o, "L3CacheSize", 0)),
                "addr", NumOf(Prop(o, "AddressWidth", 0)),
                "data", NumOf(Prop(o, "DataWidth", 0)),
                "arch", NumOf(Prop(o, "Architecture", 0)),
                "pid", Trim(Prop(o, "ProcessorId")),
                "vmx", Prop(o, "VMMonitorModeExtensions", ""),
                "slat", Prop(o, "SecondLevelAddressTranslationExtensions", ""),
                "vfw", Prop(o, "VirtualizationFirmwareEnabled", "")))
        }
        if (d["cpus"].Length)
            d["cpu"] := d["cpus"][1]
        for o in wmi.ExecQuery("SELECT * FROM Win32_BaseBoard") {
            d["board"] := Map(
                "mfr", Trim(Prop(o, "Manufacturer")),
                "product", Trim(Prop(o, "Product")),
                "version", Trim(Prop(o, "Version")),
                "serial", Trim(Prop(o, "SerialNumber")))
            break
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_BIOS") {
            d["bios"] := Map(
                "mfr", Trim(Prop(o, "Manufacturer")),
                "ver", Trim(Prop(o, "SMBIOSBIOSVersion")),
                "date", Trim(Prop(o, "ReleaseDate")),
                "major", NumOf(Prop(o, "SMBIOSMajorVersion", 0)),
                "minor", NumOf(Prop(o, "SMBIOSMinorVersion", 0)))
            break
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_ComputerSystem") {
            d["cs"] := Map(
                "mfr", Trim(Prop(o, "Manufacturer")),
                "model", Trim(Prop(o, "Model")),
                "total", NumOf(Prop(o, "TotalPhysicalMemory", 0)),
                "name", Trim(Prop(o, "Name")),
                "sysType", Trim(Prop(o, "SystemType")),
                "user", Trim(Prop(o, "UserName")))
            break
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_OperatingSystem") {
            d["os"] := Map(
                "caption", Trim(Prop(o, "Caption")),
                "version", Trim(Prop(o, "Version")),
                "build", Trim(Prop(o, "BuildNumber")),
                "arch", Trim(Prop(o, "OSArchitecture")),
                "install", Trim(Prop(o, "InstallDate")),
                "boot", Trim(Prop(o, "LastBootUpTime")),
                "visibleKB", NumOf(Prop(o, "TotalVisibleMemorySize", 0)),
                "freeKB", NumOf(Prop(o, "FreePhysicalMemory", 0)),
                "serial", Trim(Prop(o, "SerialNumber")))
            break
        }
        for a in wmi.ExecQuery("SELECT * FROM Win32_PhysicalMemoryArray") {
            d["array"] := Map(
                "maxKB", NumOf(Prop(a, "MaxCapacity", 0)),
                "slots", NumOf(Prop(a, "MemoryDevices", 0)),
                "ecc", NumOf(Prop(a, "MemoryErrorCorrection", 0)))
            break
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_PhysicalMemory")
            d["sticks"].Push(Map(
                "locator", Prop(o, "DeviceLocator"),
                "bank", Prop(o, "BankLabel"),
                "vendor", Trim(Prop(o, "Manufacturer")),
                "part", Trim(Prop(o, "PartNumber")),
                "serial", Trim(Prop(o, "SerialNumber")),
                "capacity", NumOf(Prop(o, "Capacity", 0)),
                "speed", NumOf(Prop(o, "Speed", 0)),
                "confSpeed", NumOf(Prop(o, "ConfiguredClockSpeed", 0)),
                "voltage", NumOf(Prop(o, "ConfiguredVoltage", 0)),
                "type", NumOf(Prop(o, "SMBIOSMemoryType", 0)),
                "form", NumOf(Prop(o, "FormFactor", 0)),
                "width", NumOf(Prop(o, "DataWidth", 0))))
        for o in wmi.ExecQuery("SELECT * FROM Win32_VideoController")
            d["gpus"].Push(Map(
                "name", Trim(Prop(o, "Name")),
                "vendor", Trim(Prop(o, "AdapterCompatibility")),
                "ram", NumOf(Prop(o, "AdapterRAM", 0)),
                "driver", Trim(Prop(o, "DriverVersion")),
                "driverDate", Trim(Prop(o, "DriverDate")),
                "w", NumOf(Prop(o, "CurrentHorizontalResolution", 0)),
                "h", NumOf(Prop(o, "CurrentVerticalResolution", 0)),
                "hz", NumOf(Prop(o, "CurrentRefreshRate", 0)),
                "pnpid", Trim(Prop(o, "PNPDeviceID")),
                "videoproc", Trim(Prop(o, "VideoProcessor")),
                "modedesc", Trim(Prop(o, "VideoModeDescription")),
                "status", Trim(Prop(o, "Status"))))
        ; 显存补第二来源：WMI 的 AdapterRAM 是 32 位（≥4GB 顶格/变负），拿不到真实值。
        ; 显卡驱动会把真实显存写成 REG_QWORD 放在 Class 键的 HardwareInformation.qwMemorySize，
        ; 按 MatchingDeviceId（PNPDeviceID 的前缀）对上适配器即取（实测 GTX 1660 SUPER = 6442450944）。
        for g in d["gpus"] {
            g["vram"] := -1, g["vbios"] := "", g["chip"] := ""
            r := ReadGpuReg(g["pnpid"])
            if (r["ram"] > 0)
                g["vram"] := r["ram"]
            g["vbios"] := r["bios"], g["chip"] := r["chip"]
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_DiskDrive")
            d["disks"].Push(Map(
                "model", Trim(Prop(o, "Model")),
                "size", NumOf(Prop(o, "Size", 0)),
                "iface", Trim(Prop(o, "InterfaceType")),
                "pnpid", Trim(Prop(o, "PNPDeviceID")),
                "media", Trim(Prop(o, "MediaType")),
                "serial", Trim(Prop(o, "SerialNumber")),
                "firmware", Trim(Prop(o, "FirmwareRevision")),
                "parts", NumOf(Prop(o, "Partitions", 0))))
        for o in wmi.ExecQuery("SELECT * FROM Win32_LogicalDisk WHERE DriveType=3")
            d["volumes"].Push(Map(
                "id", Trim(Prop(o, "DeviceID")),
                "label", Trim(Prop(o, "VolumeName")),
                "fs", Trim(Prop(o, "FileSystem")),
                "size", NumOf(Prop(o, "Size", 0)),
                "free", NumOf(Prop(o, "FreeSpace", 0))))
        ; 网卡走硬件视角：直接遍历物理适配器（PhysicalAdapter=True），不筛 IPEnabled。
        ; 筛 IP 是「网络配置」视角，没配 IP 的网卡会整个消失；IP/网关/DHCP 属于系统
        ; 配置而非硬件规格，本脚本不显示（那是 ipconfig 的活）。
        try {
            for o in wmi.ExecQuery("SELECT * FROM Win32_NetworkAdapter WHERE PhysicalAdapter=True")
                d["nets"].Push(Map(
                    "desc", Trim(Prop(o, "Name")),
                    "mac", Trim(Prop(o, "MACAddress")),
                    "speed", NumOf(Prop(o, "Speed", 0)),
                    "status", NumOf(Prop(o, "NetConnectionStatus", 0)),
                    "type", Trim(Prop(o, "AdapterType"))))
        }
        for o in wmi.ExecQuery("SELECT * FROM Win32_SoundDevice")
            d["sounds"].Push(Map("name", Trim(Prop(o, "Name")), "mfr", Trim(Prop(o, "Manufacturer"))))
        try {
            for o in wmi.ExecQuery("SELECT * FROM Win32_SystemEnclosure") {
                ct := Prop(o, "ChassisTypes", 0)
                if IsObject(ct) {
                    if (ct.MaxIndex() >= 0)
                        d["chassis"] := NumOf(ct[0])
                } else
                    d["chassis"] := NumOf(ct)
                break
            }
        }
        try {
            for o in wmi.ExecQuery("SELECT * FROM Win32_TimeZone") {
                d["tz"] := Trim(Prop(o, "Caption"))
                break
            }
        }
    } catch as e {
        d["error"] := e.Message
    }

    ; 显示器：root\wmi（WmiMonitorID 的名/序列号是 byte 数组）
    try {
        wmi2 := ComObjGet("winmgmts:\\.\root\wmi")
        for o in wmi2.ExecQuery("SELECT * FROM WmiMonitorID") {
            name := WmiBytes(Prop(o, "UserFriendlyName", ""))
            if (name = "")
                name := WmiBytes(Prop(o, "ProductCodeID", ""))
            d["monitors"].Push(Map(
                "inst", Trim(Prop(o, "InstanceName")),
                "name", name,
                "mfr", WmiBytes(Prop(o, "ManufacturerName", "")),
                "product", WmiBytes(Prop(o, "ProductCodeID", "")),
                "serial", WmiBytes(Prop(o, "SerialNumberID", "")),
                "year", NumOf(Prop(o, "YearOfManufacture", 0)),
                "week", NumOf(Prop(o, "WeekOfManufacture", 0))))
        }
        ; 尺寸来自另一个类。两类的 InstanceName 完全相同（实测都是
        ; DISPLAY\XMI23C3\5&c58316c&0&UID4353_0），按实例名配对才准。
        ; 早期按「第一个还没有尺寸的显示器」顺序配，多显示器时会把第二台的尺寸
        ; 塞给第一台（或第一台没报尺寸时整列错开一位）。
        ; 变量名不能叫 sizeOf：那是 AutoHotkey_H 的专有内建，官方内核没有，
        ; 名字撞上会被内核隔离门禁判为「依赖 AHK_H」（.main/test/kernel_gate）。
        sizeByInst := Map()
        for o in wmi2.ExecQuery("SELECT * FROM WmiMonitorBasicDisplayParams") {
            hcm := NumOf(Prop(o, "MaxHorizontalImageSize", 0))
            vcm := NumOf(Prop(o, "MaxVerticalImageSize", 0))
            if (hcm > 0 && vcm > 0)
                sizeByInst[Trim(Prop(o, "InstanceName"))] := Format("{:.1f}", Sqrt(hcm * hcm + vcm * vcm) / 2.54)
        }
        for m in d["monitors"] {
            if (sizeByInst.Has(m["inst"]))
                m["inch"] := sizeByInst[m["inst"]]
        }
        ; 接口类型（HDMI / DisplayPort / DVI…）在第三类里，同样按 InstanceName 配对。
        connOf := Map()
        try {
            for o in wmi2.ExecQuery("SELECT * FROM WmiMonitorConnectionParams")
                connOf[Trim(Prop(o, "InstanceName"))] := NumOf(Prop(o, "VideoOutputTechnology", -1))
        }
        for m in d["monitors"] {
            if (connOf.Has(m["inst"]))
                m["conn"] := connOf[m["inst"]]
        }
    } catch {
        ; 无 root\wmi 或类不存在时静默跳过，页面显示「未检测到」
    }
    return d
}

; ── SMBIOS Rank ──────────────────────────────────────────────────────
SmbiosString(structPtr, structLen, idx) {
    if (idx = 0)
        return ""
    q := structPtr + structLen
    n := 1
    while (n < idx) {
        while (NumGet(q, 0, "uchar") != 0)
            q++
        q++
        n++
    }
    s := ""
    while (NumGet(q, 0, "uchar") != 0) {
        s .= Chr(NumGet(q, 0, "uchar"))
        q++
    }
    return s
}

ReadSmbiosRank() {
    ranks := Map()
    size := DllCall("GetSystemFirmwareTable", "uint", 0x52534D42, "uint", 0, "ptr", 0, "uint", 0, "uint")
    if (size <= 8)
        return ranks
    buf := Buffer(size, 0)
    if !DllCall("GetSystemFirmwareTable", "uint", 0x52534D42, "uint", 0, "ptr", buf, "uint", size, "uint")
        return ranks
    len := NumGet(buf, 4, "uint")
    p := buf.Ptr + 8
    end := p + len
    while (p + 4 <= end) {
        t := NumGet(p, 0, "uchar")
        l := NumGet(p, 1, "uchar")
        if (l < 4)
            break
        if (t = 17) {
            locIdx := (l > 0x10) ? NumGet(p, 0x10, "uchar") : 0
            sz := (l > 0x0D) ? NumGet(p, 0x0C, "ushort") : 0
            attr := (l > 0x1B) ? NumGet(p, 0x1B, "uchar") : 0
            loc := SmbiosString(p, l, locIdx)
            ; Rank 在 Attributes 的低四位（不是 bit3:4）。Size=0 是空槽，
            ; 空槽的 attr 也是 0，记进去会把它当成"主板没填"。
            if (loc != "" && sz != 0)
                ranks[loc] := attr & 0x0F
        }
        q := p + l
        while (q + 1 < end && !(NumGet(q, 0, "uchar") = 0 && NumGet(q, 1, "uchar") = 0))
            q++
        p := q + 2
    }
    return ranks
}

SlotLabels(sticks) {
    ctrls := Map()
    for st in sticks {
        if RegExMatch(st["locator"], "Controller\s*(\d+)", &m)
            ctrls[Integer(m[1])] := true
    }
    multi := ctrls.Count > 1
    out := [], seen := Map()
    for st in sticks {
        loc := st["locator"], ctrl := 0, chan := "A", slot := 0, ok := false
        if RegExMatch(loc, "Controller\s*(\d+)", &m)
            ctrl := Integer(m[1]), ok := true
        if RegExMatch(loc, "Channel\s*([A-Za-z])", &m)
            chan := StrUpper(m[1]), ok := true
        if RegExMatch(loc, "DIMM\s*(\d+)", &m)
            slot := Integer(m[1]), ok := true
        label := ""
        if ok {
            if multi
                chan := Chr(Ord("A") + ctrl)
            label := chan (slot + 1)
        } else if (st["bank"] != "")
            label := st["bank"]
        else
            label := SubStr(loc, 1, 14)
        if seen.Has(label) {
            seen[label]++
            label := label "(" seen[label] ")"
        } else
            seen[label] := 1
        out.Push(label)
    }
    return out
}

; ── 各页属性行 ───────────────────────────────────────────────────────
CpuRows(d) {
    r := []
    if (d["cpus"].Length = 0)
        return [["状态", "未检测到处理器"]]
    i := 0
    for c in d["cpus"] {
        i++
        ; 双路主板：每颗 CPU 各自成块，行不混在一起。
        if (i > 1) {
            r.Push(["", ""])
            r.Push(["── 处理器 " i " ──", ""])
        }
        r.Push(["型号", Dash(c["name"])])
        r.Push(["厂商", Dash(c["mfr"])])
        r.Push(["核心 / 线程", c["cores"] " 核 / " c["threads"] " 线程"])
        r.Push(["基准频率", c["maxMhz"] ? c["maxMhz"] " MHz" : "—"])
        r.Push(["外频", c["extMhz"] ? c["extMhz"] " MHz" : "—"])
        r.Push(["L2 缓存", c["l2"] ? c["l2"] " KB" : "—"])
        r.Push(["L3 缓存", c["l3"] ? c["l3"] " KB" : "—"])
        r.Push(["插槽", Dash(c["socket"])])
        r.Push(["架构", Dash(c["caption"]) " · " ArchName(c["arch"])])
        r.Push(["总线宽度", c["addr"] " 位地址 / " c["data"] " 位数据"])
        r.Push(["硬件虚拟化", c["vmx"] = 1 || c["vmx"] = true ? "支持" : "不支持或未开启"])
        r.Push(["二级地址转换 SLAT", c["slat"] = 1 || c["slat"] = true ? "支持" : "不支持"])
        r.Push(["固件虚拟化", c["vfw"] = 1 || c["vfw"] = true ? "已开启" : "未开启"])
        r.Push(["处理器 ID", Dash(c["pid"])])
        sig := CpuSig(c["pid"])
        if (sig != "")
            r.Push(["家族 / 型号 / 步进", sig])
        r.Push(["指令集", FeatureList()])
    }
    return r
}

BoardRows(d) {
    global CHASSIS_NAME
    b := d["board"], o := d["bios"]
    r := []
    r.Push(["主板厂商", Dash(b.Has("mfr") ? b["mfr"] : "")])
    r.Push(["主板型号", Dash(b.Has("product") ? b["product"] : "")])
    r.Push(["主板版本", Dash(b.Has("version") ? b["version"] : "")])
    r.Push(["主板序列号", Dash(b.Has("serial") ? b["serial"] : "")])
    r.Push(["", ""])
    r.Push(["BIOS 厂商", Dash(o.Has("mfr") ? o["mfr"] : "")])
    r.Push(["BIOS 版本", Dash(o.Has("ver") ? o["ver"] : "")])
    r.Push(["BIOS 日期", FmtCimDate(o.Has("date") ? o["date"] : "")])
    r.Push(["SMBIOS 版本", (o.Has("major") && o["major"]) ? o["major"] "." o["minor"] : "—"])
    r.Push(["", ""])
    r.Push(["整机厂商", Dash(d["cs"].Has("mfr") ? d["cs"]["mfr"] : "")])
    r.Push(["整机型号", Dash(d["cs"].Has("model") ? d["cs"]["model"] : "")])
    if (d["chassis"] > 0)
        r.Push(["机箱类型", CHASSIS_NAME.Has(d["chassis"]) ? CHASSIS_NAME[d["chassis"]] : "未知(" d["chassis"] ")"])
    return r
}

MemRows(d) {
    a := d["array"], sticks := d["sticks"], ranks := ReadSmbiosRank()
    labels := SlotLabels(sticks)
    r := []
    total := 0
    for st in sticks
        total += st["capacity"]
    firstType := sticks.Length ? sticks[1]["type"] : 0
    r.Push(["总容量（已安装）", FmtBytes(total)])
    r.Push(["内存类型", TypeName(firstType)])
    r.Push(["插槽占用", sticks.Length "/" (a.Has("slots") && a["slots"] ? a["slots"] : sticks.Length)])
    ; MaxCapacity 是 32 位 KB 字段。SMBIOS 规定值为 0x80000000 时表示"真值在 Type 16
    ; 的扩展容量字段（QWORD 字节）里"，此时直接换算会得到假的 2048 GB，故如实标注。
    r.Push(["主板最大支持", MaxCapText(a.Has("maxKB") ? a["maxKB"] : 0)])
    r.Push(["ECC", EccName(a.Has("ecc") ? a["ecc"] : 0)])
    if (sticks.Length = 0) {
        r.Push(["", ""])
        r.Push(["状态", "未检测到已安装的内存条"])
        return r
    }
    i := 0
    for st in sticks {
        i++
        r.Push(["", ""])
        r.Push(["── " labels[i] " 槽 ──", ""])
        r.Push(["容量", FmtBytes(st["capacity"])])
        r.Push(["频率", FmtMts(st["speed"], st["confSpeed"])])
        r.Push(["厂商（模组）", Dash(st["vendor"])])
        r.Push(["型号", Dash(st["part"])])
        r.Push(["序列号", Dash(st["serial"])])
        r.Push(["Rank", RankName(ranks.Has(st["locator"]) ? ranks[st["locator"]] : "")])
        r.Push(["电压", st["voltage"] ? st["voltage"] " mV" : "—"])
        r.Push(["规格", TypeName(st["type"]) " · " (FORM_NAME.Has(st["form"]) ? FORM_NAME[st["form"]] : "—")
            . " · " st["width"] " 位"])
    }
    return r
}

GpuRows(d) {
    r := []
    if (d["gpus"].Length = 0)
        return [["状态", "未检测到显示适配器"]]
    i := 0
    for g in d["gpus"] {
        i++
        if (i > 1) {
            r.Push(["", ""])
            r.Push(["── 适配器 " i " ──", ""])
        }
        r.Push(["名称", Dash(g["name"])])
        r.Push(["厂商", Dash(g["vendor"])])
        ; 显存优先取驱动注册表的 REG_QWORD（qwMemorySize，实测 6GB 精确到字节）；
        ; 拿不到才退回 32 位的 AdapterRAM —— 那是 ≥4GB 顶格/变负的半残值，只能当参考。
        ram := g["ram"]
        if (ram < 0)
            ram += 4294967296
        vram := g.Has("vram") ? g["vram"] : -1
        ramText := ""
        if (vram > 0)
            ramText := FmtBytes(vram)
        else if (ram <= 0)
            ramText := "—"
        else if (ram >= 4293918720)
            ramText := "4 GB 以上（WMI 32 位字段上限，取不到准确值）"
        else
            ramText := FmtMB(Round(ram / 1048576))
        r.Push(["显存", ramText])
        if (g.Has("chip") && g["chip"] != "" && g["chip"] != g["name"])
            r.Push(["芯片", g["chip"]])
        if (g.Has("vbios") && g["vbios"] != "")
            r.Push(["vBIOS 版本", g["vbios"]])
        r.Push(["驱动版本", Dash(g["driver"])])
        r.Push(["驱动日期", FmtCimDate(g["driverDate"])])
        r.Push(["输出分辨率", (g["w"] && g["h"]) ? g["w"] " × " g["h"] : "—"])
        r.Push(["刷新率", g["hz"] ? g["hz"] " Hz" : "—"])
        r.Push(["视频处理器", Dash(g["videoproc"])])
        r.Push(["设备 ID", Dash(g["pnpid"])])
    }
    return r
}

DiskRows(d) {
    r := []
    if (d["disks"].Length = 0)
        return [["状态", "未检测到硬盘"]]
    i := 0
    for dk in d["disks"] {
        i++
        if (i > 1) {
            r.Push(["", ""])
            r.Push(["── 硬盘 " i " ──", ""])
        }
        r.Push(["型号", Dash(dk["model"])])
        r.Push(["容量", FmtBytes(dk["size"])])
        r.Push(["总线", BusName(dk)])
        r.Push(["介质类型", Dash(dk["media"])])
        r.Push(["固件版本", Dash(dk["firmware"])])
        r.Push(["序列号", Dash(dk["serial"])])
        r.Push(["分区数", dk["parts"]])
    }
    if (d["volumes"].Length) {
        r.Push(["", ""])
        r.Push(["── 分区 ──", ""])
        for v in d["volumes"] {
            used := v["size"] > 0 ? Round((v["size"] - v["free"]) / v["size"] * 100) : 0
            r.Push([v["id"] (v["label"] != "" ? " " v["label"] : ""),
                FmtBytes(v["size"]) " 可用 " FmtBytes(v["free"]) "（已用 " used "%）· " Dash(v["fs"], "")])
        }
    }
    return r
}

NetRows(d) {
    global NETSTATUS_NAME
    r := []
    if (d["nets"].Length = 0)
        return [["状态", "未检测到物理网卡"]]
    i := 0
    for n in d["nets"] {
        i++
        if (i > 1) {
            r.Push(["", ""])
            r.Push(["── 网卡 " i " ──", ""])
        }
        r.Push(["名称", Dash(n["desc"])])
        if (n["type"] != "")
            r.Push(["适配器类型", NetTypeName(n["type"])])
        r.Push(["MAC 地址", Dash(n["mac"])])
        if (n["speed"] > 0)
            r.Push(["连接速率", (n["speed"] >= 1000000000)
                ? Format("{:.1f} Gbps", n["speed"] / 1000000000)
                : Format("{:.0f} Mbps", n["speed"] / 1000000)])
        else
            r.Push(["连接速率", "—"])
        r.Push(["连接状态", NETSTATUS_NAME.Has(n["status"]) ? NETSTATUS_NAME[n["status"]] : "未知(" n["status"] ")"])
    }
    return r
}

; WMI 的 AdapterType 是英文枚举，按关键词折成中文；认不出就原样显示，不猜。
NetTypeName(s) {
    if InStr(s, "Wireless") || InStr(s, "Wi-Fi") || InStr(s, "WiFi")
        return "无线 · " s
    if InStr(s, "Ethernet")
        return "以太网 · " s
    return s
}

MonitorRows(d) {
    r := []
    if (d["monitors"].Length = 0)
        return [["状态", "未检测到显示器（笔记本内屏可能不报）"]]
    i := 0
    for m in d["monitors"] {
        i++
        if (i > 1) {
            r.Push(["", ""])
            r.Push(["── 显示器 " i " ──", ""])
        }
        r.Push(["名称", Dash(m["name"])])
        r.Push(["厂商代码", Dash(m["mfr"])])
        r.Push(["产品代码", Dash(m["product"])])
        r.Push(["序列号", Dash(m["serial"])])
        r.Push(["生产日期", (m["year"] ? m["year"] " 年" (m["week"] ? " 第 " m["week"] " 周" : "") : "未提供")])
        r.Push(["屏幕尺寸", m.Has("inch") ? m["inch"] " 英寸（对角线）" : "未提供"])
        if (m.Has("conn"))
            r.Push(["接口", ConnName(m["conn"])])
    }
    return r
}

SysRows(d) {
    o := d["os"], cs := d["cs"]
    r := []
    r.Push(["操作系统", Dash(o.Has("caption") ? o["caption"] : "")])
    r.Push(["版本", (o.Has("version") ? o["version"] : "—") "（Build " Dash(o.Has("build") ? o["build"] : "", "—") "）"])
    r.Push(["架构", Dash(o.Has("arch") ? o["arch"] : "")])
    r.Push(["安装日期", FmtCimDate(o.Has("install") ? o["install"] : "")])
    r.Push(["上次启动", FmtCimDate(o.Has("boot") ? o["boot"] : "")])
    r.Push(["", ""])
    r.Push(["计算机名", Dash(cs.Has("name") ? cs["name"] : "")])
    r.Push(["当前用户", Dash(cs.Has("user") ? cs["user"] : "")])
    r.Push(["系统类型", Dash(cs.Has("sysType") ? cs["sysType"] : "")])
    r.Push(["", ""])
    r.Push(["物理内存总量", FmtBytes(cs.Has("total") ? cs["total"] : 0)])
    r.Push(["系统序列号", Dash(o.Has("serial") ? o["serial"] : "")])
    if (d["tz"] != "")
        r.Push(["时区", d["tz"]])
    if (d["sounds"].Length) {
        r.Push(["", ""])
        r.Push(["── 音频设备 ──", ""])
        for s in d["sounds"]
            r.Push([Dash(s["mfr"], "音频"), Dash(s["name"])])
    }
    return r
}

; CIM 日期 20221021080000.000000+000 → 2022-10-21
FmtCimDate(s) {
    s := Trim("" s)
    if (StrLen(s) < 8)
        return "—"
    return SubStr(s, 1, 4) "-" SubStr(s, 5, 2) "-" SubStr(s, 7, 2)
}

; ── UI ───────────────────────────────────────────────────────────────
PaintCaption() {
    global gGui, C_BAND, C_TEXT
    c := Buffer(4, 0), t := Buffer(4, 0)
    NumPut("UInt", 0x00F7E8DC, c)
    NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; 原生 ListView 的滚动条由 comctl32 主题引擎绘制，脚本层拿不到颜色：WM_CTLCOLORSCROLLBAR
; 实测一次都不触发，SetWindowTheme 也只给浅/深两套外观 —— 和左侧自绘导航摆在一起就不统一。
; 所以隐藏原生条、用色块自绘：槽 #DCE8F7、滑块 #6E9BD4，与整体八色令牌同一套。
; 隐藏用 ShowScrollBar(FALSE) 而不是 -VScroll：去掉样式后控件不再维护滚动范围，只隐藏则范围还在。
; 本脚本列宽按视口自适应，不需要横向条，故只实现竖轴。
; 与配方（开发指南 §10.4 / 文件时间修改 2.4.6）的三处有意差异，都是实测出来的：
;   ① 提交用逐块 SetWindowPos，不用 DeferWindowPos 批量 —— 批量在「列表刚 Move 完」
;      那一拍会整批失败返回 NULL，色块集体保持隐藏（表现为切页后滚动条不出现）；
;   ② 滚动用 LVM_SCROLL 像素增量、不用 LVM_ENSUREVISIBLE —— 后者在原生条隐藏后会滚过头；
;   ③ 每页行数取 LVM_GETCOUNTPERPAGE，不按 lvH/itemH 估算（估少一行，末行差一截到底）。
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
        ; +0x100 是 SS_NOTIFY：不加的静态控件对命中测试返回 HTTRANSPARENT，点击会穿透到父窗口，
        ; 自绘条就永远收不到 WM_LBUTTONDOWN。轨道拆成「滑块前」「滑块后」两段，与滑块永不重叠
        ; —— 叠放时谁在上由 z 序决定，宿主里实测抬到 HWND_TOP 也压不住，索性别让它重叠。
        this.vUp := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vDn := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        ; 滑块两侧各留一条同色细缝，轨道才是连续的一条浅蓝槽（缝与滑块沿轴相邻、几何不重叠）。
        this.vGapL := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.vGapR := g.Add("Text", "x" x " y" y " w0 h0 +0x100 BackgroundDCE8F7")
        this.thumbV := g.Add("Text", "x" x " y" y " w0 h0 +0x100 Background6E9BD4")
        for c in [this.vUp, this.vDn, this.vGapL, this.vGapR, this.thumbV]
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
        for o in ops {
            if (o.on) {
                ; SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW
                DllCall("user32\SetWindowPos", "Ptr", o.c, "Ptr", 0, "Int", o.x, "Int", o.y
                    , "Int", o.w, "Int", o.h, "UInt", 0x0054, "Ptr")
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

    ; 用 LVM_SCROLL 按像素滚：实测 LVM_ENSUREVISIBLE 在原生条被隐藏后会滚过头
    ; （把末行直接顶成首行，列表下沿露白、滑块跑出可视区），而 LVM_SCROLL 会按
    ; 真实范围自己夹住，首行号回读与预期一致。
    ScrollToRow(target) {
        if (!this.lv.Hwnd)
            return
        ; 这里不能重新 Measure：LVM_GETCOUNTPERPAGE 在「列表刚 Move 完」那一拍会回一个
        ; 过期的每页行数（实测 468 高的列表回 25），exV 被判成假，滚动条当场被抹掉。
        ; 行数与可视行数统一由 Layout 维护，切页/填表都先走 Layout 再进来。
        target := Max(0, Min(this.maxTop, target))
        dy := (target - this.top) * this.itemH
        ; 没有可滚内容（或已在端点）时彻底不碰列表：以前这里照样 Repaint 一次，
        ; 空页面上滚轮也会让整个列表闪一下。
        if (dy = 0) {
            this.Paint()
            return
        }
        ; K22：LVM_SCROLL 会把 WS_VSCROLL 置回来。滚动前先压一次、滚完再压一次，
        ; 否则滚动那一瞬原生灰条会和自绘条同时出现（实测就是「滚一下冒出老式滑块」）。
        this.HideNative()
        DllCall("user32\SendMessageW", "Ptr", this.lv.Hwnd, "UInt", 0x1014, "Ptr", 0, "Ptr", dy, "Ptr")
        this.top := this.ReadTop()
        this.HideNative()
        this.Repaint()
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

    ; 定时器会让脚本在窗口关闭后继续存活，必须显式停掉。
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
    OnMessage(0x204, OnBarRDown)
}

; ── 复制：右键菜单 / Ctrl+C ──────────────────────────────────────────
; ListView 没有右键事件，只能自己接 WM_RBUTTONUP。右键时先把鼠标下那一行选中
; —— 原生 ListView 右键不改选中，不选中的话用户不知道即将复制哪一行。
RowAt(hwnd, x, y) {
    h := Buffer(24, 0)
    NumPut("Int", x, h, 0)
    NumPut("Int", y, h, 4)
    i := DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0x1012, "Ptr", 0, "Ptr", h, "Ptr")
    return (i < 0 || i > 0x7FFFFFFF) ? -1 : i
}

SelectRow(hwnd, i) {
    if (i < 0)
        return
    lv := Buffer(88, 0)
    NumPut("UInt", 0x2, lv, 12)          ; state     = LVIS_SELECTED
    NumPut("UInt", 0x3, lv, 16)          ; stateMask = LVIS_SELECTED | LVIS_FOCUSED
    DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0x102B, "Ptr", i, "Ptr", lv, "Ptr")
}

SelectedRow(hwnd) {
    i := DllCall("user32\SendMessageW", "Ptr", hwnd, "UInt", 0x100C, "Ptr", -1, "Ptr", 2, "Ptr")
    return (i < 0 || i > 0x7FFFFFFF) ? -1 : i
}

PageRows() {
    global gPages, gCurPage
    if (!gPages || gPages.Length = 0)
        return []
    return gPages[gCurPage]["rows"]
}

; 属性与值之间用制表符：粘到 Excel/记事本里正好是两列，也不会破坏中文对齐。
RowLine(r) {
    if (r[1] = "" && r[2] = "")
        return ""
    if (r[2] = "")
        return r[1]
    return r[1] "`t" r[2]
}

CopyRow(idx := -1, *) {
    global gList
    if (idx < 0)
        idx := SelectedRow(gList.Hwnd)
    rows := PageRows()
    if (idx < 0 || idx >= rows.Length) {
        Tip("先点一行再复制")
        return
    }
    A_Clipboard := RowLine(rows[idx + 1])
    Tip("已复制此行")
}

CopyPage(*) {
    rows := PageRows()
    if (rows.Length = 0)
        return
    text := ""
    for r in rows
        text .= RowLine(r) "`n"
    A_Clipboard := RTrim(text, "`n")
    Tip("已复制本页 · " rows.Length " 行")
}

; 复制没有状态条可报，用 1.2 秒的浮动提示代替。
Tip(s) {
    ToolTip(s)
    SetTimer(() => ToolTip(), -1200)
}

; AHK v2 的 Menu.Show 签名是 Show([Callback, X, Y]) —— 第一个参数是回调，不是坐标。
; 之前按 v1 的习惯写 Show(x, y)，x 被当成 Callback、y 被当成 X，菜单就跑到屏幕右下角去了。
; 不传参数时它自动在鼠标位置弹出，正是要的效果。
ShowCopyMenu(row) {
    ctx := Menu()
    ctx.Add("复制此行", (*) => CopyRow(row))
    ctx.Add("复制本页全部", CopyPage)
    ctx.Show()
}

; 挂在 WM_RBUTTONDOWN 而不是 WM_RBUTTONUP：ListView 收到右键按下后会去做
; DragDetect（内部自建消息循环等鼠标释放），抬起消息被它自己消化，脚本的
; OnMessage 根本收不到（实测 0x205 一次都没到）。所以按下就弹菜单，并吃掉该消息。
OnBarRDown(wp, lp, msg, hwnd) {
    global gList
    if (!gList || hwnd != gList.Hwnd)
        return
    ; lParam 低字 x、高字 y（相对列表客户区）
    row := RowAt(gList.Hwnd, lp & 0xFFFF, (lp >> 16) & 0xFFFF)
    SelectRow(gList.Hwnd, row)
    ; 菜单是模态的：直接 Show 会把当前这轮消息卡在这里，主窗口来不及重画，
    ; 菜单背后的列表会停在半画状态（实测只画出前几行）。挪到定时器里弹，
    ; 先让本条消息返回、窗口画完。位置由 Menu.Show() 自己取光标坐标。
    SetTimer(() => ShowCopyMenu(row), -30)
    return 1
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
    ; 原生条被摘掉后 ListView 自己不再处理滚轮，落在窗口任意位置都转给列表。
    ; 注意 IsChild(parent, parent) 返回假：鼠标压在窗口空白处（导航区、列表外）时
    ; 消息的 hwnd 就是主窗口本身，漏掉这一支那一片区域就滚不动。
    if (gGui.Hwnd && (hwnd = gGui.Hwnd || DllCall("user32\IsChild", "Ptr", gGui.Hwnd, "Ptr", hwnd))) {
        gScroll.OnWheelDelta(delta)
        return 1
    }
}

; 键盘翻页：只在列表控件上接管，别的控件保持原生行为。
OnBarKey(wp, lp, msg, hwnd) {
    global gScroll, gList
    if (!gScroll || gScroll.dead || !gList || hwnd != gList.Hwnd)
        return
    if (wp = 0x43 && GetKeyState("Ctrl", "P")) {     ; Ctrl+C 复制选中行
        CopyRow()
        return 1
    }
    if (gScroll.OnKey(wp))
        return 1
}

BuildGui() {
    global gGui, gList, gNavBtns, gScroll
    global gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt, gHdrBand, gHdrName, gHdrVal
    global C_BG, C_BAND, C_FRAME, C_TEXT, C_WHITE, C_ACCENT_SOFT
    global NAV_X, NAV_W, NAV_ITEM_H, NAV_GAP, COL_NAME_W
    global WIN_W, WIN_H, LIST_X, LIST_W, LIST_TOP, HEAD_H, LIST_H, PAD

    ; +Resize +MinSize：值列里有长文本（显卡设备 ID、网卡名称），窗口能拉宽/最大化才看得全。
    gGui := Gui("+Resize +MinSize560x400", "硬件信息")
    gGui.BackColor := C_BG
    gGui.SetFont("s10", "Microsoft YaHei UI")
    ; 自绘滚动条的定时器必须先停，否则窗口销毁后还会有一拍去访问已销毁的列表控件。
    gGui.OnEvent("Close", (*) => (gScroll ? gScroll.Stop() : 0, ExitApp()))

    ; 左侧导航：不带框线，选中项整块换成 ACCENT_SOFT（比 BG 深两档），
    ; 一眼就能看出当前停在哪一页；未选中与窗口底色同色，视觉上退到背景里。
    navs := ["CPU", "主板", "内存", "显卡", "磁盘", "网卡", "显示器", "系统"]
    gNavBtns := []
    y := PAD
    for i, nm in navs {
        b := gGui.Add("Text", "x" NAV_X " y" y " w" NAV_W " h" NAV_ITEM_H
            " Background" (i = 1 ? C_ACCENT_SOFT : C_BG) " c" C_TEXT " +0x200 Center", nm)
        b.OnEvent("Click", NavClick.Bind(i))
        gNavBtns.Push(b)
        y += NAV_ITEM_H + NAV_GAP
    }

    ; 列表区：白底块 + 四边各一条 1px FRAME 线（§10.4「色块当线」）。
    ; ★不能用一整块 FRAME 打底：《打开方式清理》1.4.0 已踩过这个坑 —— 原生 ListView 在
    ; 列宽之外与空白行不保证重绘，漏出来的就是那一整块底色。本脚本的表现是列表右侧
    ; 17px 竖条 + 底部 17px 横带（正是被摘掉的原生滚动条留出的未绘区域，实测截图里
    ; 是一片灰蓝）。改白底块后，漏出来的地方和列表本身同色，看不见。
    gLvWhite := gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_TOP + 1)
        " w" (LIST_W - 2) " h" (HEAD_H + LIST_H - 1) " Background" C_WHITE)
    gLineTop := gGui.Add("Text", "x" LIST_X " y" LIST_TOP " w" LIST_W " h1 Background" C_FRAME)
    gLineBot := gGui.Add("Text", "x" LIST_X " y" (LIST_TOP + HEAD_H + LIST_H) " w" LIST_W " h1 Background" C_FRAME)
    gLineLft := gGui.Add("Text", "x" LIST_X " y" LIST_TOP " w1 h" (HEAD_H + LIST_H + 1) " Background" C_FRAME)
    gLineRgt := gGui.Add("Text", "x" (LIST_X + LIST_W - 1) " y" LIST_TOP " w1 h" (HEAD_H + LIST_H + 1) " Background" C_FRAME)

    gHdrBand := gGui.Add("Text", "x" (LIST_X + 1) " y" (LIST_TOP + 1) " w" (LIST_W - 2) " h" HEAD_H " Background" C_BAND)
    gGui.SetFont("s10 Bold", "Microsoft YaHei UI")
    gHdrName := gGui.Add("Text", "x" (LIST_X + 7) " y" (LIST_TOP + 1) " w" (COL_NAME_W - 6) " h" HEAD_H
        " Background" C_BAND " c" C_TEXT " +0x200", "属性")
    gHdrVal := gGui.Add("Text", "x" (LIST_X + 1 + COL_NAME_W + 6) " y" (LIST_TOP + 1) " w" (LIST_W - COL_NAME_W - 10) " h" HEAD_H
        " Background" C_BAND " c" C_TEXT " +0x200", "值")
    gGui.SetFont("s10 Norm", "Microsoft YaHei UI")

    ; 列表高度扣掉 1px：列表若与外框同底，最后一像素会把外框下边线整条盖掉
    ; （实测滚到底时看起来「没有底框」）。让出 1px，底线才露得出来。
    gList := gGui.Add("ListView", "x" (LIST_X + 1) " y" (LIST_TOP + HEAD_H + 1) " w" (LIST_W - 2) " h" (LIST_H - 1)
        " -Hdr -Multi -E0x200 Background" C_WHITE " c" C_TEXT, ["属性", "值"])
    gList.ModifyCol(1, COL_NAME_W)
    gList.ModifyCol(2, LIST_W - COL_NAME_W - 4)
    ; LVS_EX_DOUBLEBUFFER：滚动重绘走后台缓冲，避免整块重画时闪一下。
    DllCall("user32\SendMessageW", "Ptr", gList.Hwnd, "UInt", 0x1036, "Ptr", 0x10000, "Ptr", 0x10000)

    gGui.OnEvent("Size", OnSize)

    gGui.Show("w" WIN_W " h" WIN_H " Center")
    PaintCaption()

    ; 原生滚动条由 comctl32 主题引擎绘制、脚本拿不到颜色，和左侧自绘导航放一起就不统一；
    ; 整段复用已验证的 FlatScroll（槽 BAND / 滑块 ACCENT）。
    gScroll := FlatScroll(gGui, gList, LIST_X + 1, LIST_TOP + HEAD_H + 1, LIST_W - 2, LIST_H - 1)
    HookBarInput()
    SetTimer(ObjBindMethod(gScroll, "Sync"), 60)

    ; F5 重新采集（窗口激活时）。
    try {
        HotIfWinActive("ahk_pid " DllCall("GetCurrentProcessId"))
        Hotkey("F5", Refresh)
        HotIfWinActive()
    }
}

; 窗口可缩放：左侧导航固定宽度，右侧列表区吃掉余量。顺序不能乱 ——
; 先排白底块/四条线/列头带，再定列表尺寸，最后按「可视宽」分配列宽（列宽按窗口宽
; 算，出现竖条时会多出 10px 溢出），改完列宽必须重新 Redraw（K31：行底色会停在旧列宽）。
OnSize(g, minMax, w, h) {
    global gList, gScroll, gLvWhite, gLineTop, gLineBot, gLineLft, gLineRgt
    global gHdrBand, gHdrName, gHdrVal, COL_NAME_W, LIST_X, LIST_TOP, HEAD_H, PAD
    if (minMax = -1 || !gList || !gScroll)
        return
    fw := w - LIST_X - PAD
    fh := h - LIST_TOP - PAD
    if (fw < 240 || fh < 160)
        return
    gLvWhite.Move(LIST_X + 1, LIST_TOP + 1, fw - 2, fh - 2)
    gLineTop.Move(LIST_X, LIST_TOP, fw, 1)
    gLineBot.Move(LIST_X, LIST_TOP + fh - 1, fw, 1)
    gLineLft.Move(LIST_X, LIST_TOP, 1, fh)
    gLineRgt.Move(LIST_X + fw - 1, LIST_TOP, 1, fh)
    gHdrBand.Move(LIST_X + 1, LIST_TOP + 1, fw - 2, HEAD_H)
    gHdrName.Move(LIST_X + 7, LIST_TOP + 1, COL_NAME_W - 6, HEAD_H)
    gHdrVal.Move(LIST_X + 1 + COL_NAME_W + 6, LIST_TOP + 1
        , Max(40, fw - COL_NAME_W - 10), HEAD_H)
    ; 静态色块的背景色走 WM_CTLCOLORSTATIC：只改几何不会重画，实测最大化后列头带
    ; 仍停在旧宽度（右侧露出白底）。逐个 InvalidateRect，别整窗 Redraw —— 那个在
    ; 拖边框时会整屏闪。
    for c in [gLvWhite, gHdrBand, gHdrName, gHdrVal, gLineTop, gLineBot, gLineLft, gLineRgt]
        DllCall("user32\InvalidateRect", "Ptr", c.Hwnd, "Ptr", 0, "Int", 1)
    gScroll.x := LIST_X + 1, gScroll.y := LIST_TOP + HEAD_H + 1
    gScroll.w := fw - 2, gScroll.h := fh - HEAD_H - 2
    gScroll.Layout()
    FixCols()
}

; 列表可滚（出现竖条）后可视宽少 10px，第二列跟着收，否则长值会被裁掉。
FixCols() {
    global gList, gScroll, COL_NAME_W
    w := gScroll ? gScroll.ClientW() : 0
    if (w <= 0)
        return
    gList.ModifyCol(2, Max(160, w - COL_NAME_W - 2))
    ; K31：改列宽后行底色范围会停在旧列宽的位置，必须整表重绘一次。
    try gList.Redraw()
}

NavClick(idx, *) {
    ShowPage(idx)
}

ShowPage(idx) {
    global gList, gNavBtns, gPages, gCurPage, C_ACCENT_SOFT, C_BG, gScroll
    if (idx < 1 || idx > gPages.Length)
        return
    gCurPage := idx
    ; 选中态换底色后必须让控件重画一遍：Background 走 WM_CTLCOLORSTATIC，
    ; 不主动 Invalidate 会留着旧底色，切换看起来像没反应。
    for i, b in gNavBtns {
        b.Opt("Background" (i = idx ? C_ACCENT_SOFT : C_BG))
        DllCall("user32\InvalidateRect", "Ptr", b.Hwnd, "Ptr", 0, "Int", 1)
    }
    p := gPages[idx]
    gList.Delete()
    for r in p["rows"]
        gList.Add("", r[1], r[2])
    ; 行数变了，滚动范围跟着重算；切页一律回到顶部。
    if (gScroll) {
        gScroll.Layout()
        gScroll.ScrollToRow(0)
    }
    FixCols()
    try gList.Focus()
}

BuildPages(d) {
    return [
        Map("name", "CPU", "rows", CpuRows(d)),
        Map("name", "主板", "rows", BoardRows(d)),
        Map("name", "内存", "rows", MemRows(d)),
        Map("name", "显卡", "rows", GpuRows(d)),
        Map("name", "磁盘", "rows", DiskRows(d)),
        Map("name", "网卡", "rows", NetRows(d)),
        Map("name", "显示器", "rows", MonitorRows(d)),
        Map("name", "系统", "rows", SysRows(d))
    ]
}

Refresh(*) {
    global gData, gPages, gCurPage, gList, gScroll
    d := Collect()
    if (d["error"] != "") {
        ; 没有状态条，失败就直接在列表上说清楚。
        if (gList) {
            gList.Delete()
            gList.Add("", "读取失败", d["error"])
            if (gScroll)
                gScroll.Layout()
        }
        return
    }
    gData := d
    gPages := BuildPages(d)
    ShowPage(gCurPage)
}

; ── 无 GUI 自测：--selftest [输出路径] ───────────────────────────────
if (A_Args.Length >= 1 && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\硬件信息\selftest-result.txt")

RunSelfTest(path) {
    out := ""
    Emit(s) => out .= s "`n"

    ; 1. 格式化与码表
    Emit((FmtBytes(8589934592) = "8 GB" ? "PASS " : "FAIL ") "8 GiB → 8 GB")
    Emit((FmtBytes(0) = "—" ? "PASS " : "FAIL ") "零容量 → 破折号")
    Emit((FmtMts(2667, 2667) = "2667 MT/s" ? "PASS " : "FAIL ") "标称=实际只写一值")
    Emit((FmtMts(3200, 2667) = "3200→2667 MT/s" ? "PASS " : "FAIL ") "降频写箭头")
    Emit((MaxCapText(134217728) = "128 GB" && MaxCapText(0) = "—"
        && MaxCapText(0x80000000) = "未知（主板用扩展容量字段，WMI 未给出）"
        ? "PASS " : "FAIL ") "最大容量换算与 0x80000000 转义值")
    ; 0x1A=DDR4、0x22=DDR5；0x20 是 HBM 不是 DDR5。旧表按"顺序"排，
    ; 本机 DDR4(0x1A) 恰好对，换成 DDR5 就会显示成 HBM3。
    Emit((TypeName(0x1A) = "DDR4" && TypeName(0x22) = "DDR5" && TypeName(0x20) = "HBM"
        && TypeName(0x12) = "DDR" ? "PASS " : "FAIL ") "内存类型码")
    Emit((EccName(3) = "无" ? "PASS " : "FAIL ") "ECC 码")
    ; Rank 取 Attributes 低四位：1→1R、2→2R、0→未填（旧代码取 bit3:4，双 Rank 会显示成 1R）
    Emit((RankName(1) = "1R" && RankName(2) = "2R" && RankName(0) = "未填" ? "PASS " : "FAIL ") "Rank 码")
    Emit((ArchName(9) = "x64" ? "PASS " : "FAIL ") "架构码 9 = x64")
    Emit((CpuSig("BFEBFBFF00090672") = "6 / 151 / 2" ? "PASS " : "FAIL ") "ProcessorId → 家族/型号/步进")
    Emit((CpuSig("") = "" ? "PASS " : "FAIL ") "无 ProcessorId 时不硬编")
    Emit((FmtBytes(6442450944) = "6 GB" ? "PASS " : "FAIL ") "REG_QWORD 显存 → 6 GB")
    Emit((ConnName(5) = "HDMI" && ConnName(10) = "DisplayPort" ? "PASS " : "FAIL ") "显示器接口码")
    Emit((InStr(FeatureList(), "SSE2") ? "PASS " : "FAIL ") "指令集含 SSE2")
    Emit((BusName(Map("iface", "SCSI", "pnpid", "SCSI\DISK&VEN_NVME&PROD_X\5&1")) = "NVMe"
        && BusName(Map("iface", "IDE", "pnpid", "IDE\DISKSCSI\5&1")) = "IDE" ? "PASS " : "FAIL ") "NVMe 盘不按 WMI 的 SCSI 论")
    Emit((FmtCimDate("20221021080000.000000+000") = "2022-10-21" ? "PASS " : "FAIL ") "CIM 日期格式化")
    ; 复制格式（右键菜单 / Ctrl+C 都走这一条）
    Emit((RowLine(["容量", "8 GB"]) = "容量`t8 GB" ? "PASS " : "FAIL ") "复制行用制表符分隔属性与值")
    Emit((RowLine(["", ""]) = "" ? "PASS " : "FAIL ") "空行复制为空串")
    Emit((RowLine(["── A1 槽 ──", ""]) = "── A1 槽 ──" ? "PASS " : "FAIL ") "只有属性没有值时只输出属性")

    ; 2. 槽位名四种固件形态
    mk(loc) => Map("locator", loc, "bank", "")
    L1 := SlotLabels([mk("Controller0-ChannelA-DIMM0"), mk("Controller1-ChannelA-DIMM0")])
    Emit((L1[1] = "A1" && L1[2] = "B1" ? "PASS " : "FAIL ") "双控制器同 ChannelA → A1/B1")
    L2 := SlotLabels([mk("Controller0-ChannelA-DIMM0"), mk("Controller0-ChannelB-DIMM0")])
    Emit((L2[1] = "A1" && L2[2] = "B1" ? "PASS " : "FAIL ") "单控制器双通道 → A1/B1")
    L3 := SlotLabels([mk("Controller0-ChannelA-DIMM0"), mk("Controller0-ChannelA-DIMM1")
                    , mk("Controller1-ChannelA-DIMM0"), mk("Controller1-ChannelA-DIMM1")])
    Emit((L3[1] = "A1" && L3[2] = "A2" && L3[3] = "B1" && L3[4] = "B2" ? "PASS " : "FAIL ") "四槽双控 → A1/A2/B1/B2")
    L4 := SlotLabels([mk("BANK 0"), mk("BANK 0")])
    Emit((L4[1] = "BANK 0" && L4[2] = "BANK 0(2)" ? "PASS " : "FAIL ") "无通道信息退回 Bank 并去重")

    ; 3. 多硬件：每一类都逐项列出，不是只取第一条
    fake := Map(
        "monitors", [Map("name", "M1", "mfr", "XMI", "product", "P1", "serial", "S1"
                        , "year", 2021, "week", 39, "inch", "23.8")
                    , Map("name", "M2", "mfr", "DEL", "product", "P2", "serial", "S2"
                        , "year", 2020, "week", 10, "inch", "27.0")],
        "nets", [Map("desc", "NIC-A", "mac", "AA-BB", "speed", 1000000000, "status", 2, "type", "Ethernet 802.3")
                , Map("desc", "NIC-B", "mac", "CC-DD", "speed", 0, "status", 7, "type", "Ethernet 802.3")])
    mSplit := mSecond := false
    for r in MonitorRows(fake) {
        if (r[1] = "── 显示器 2 ──")
            mSplit := true
        if (r[2] = "27.0 英寸（对角线）")
            mSecond := true
    }
    Emit((mSplit && mSecond ? "PASS " : "FAIL ") "两台显示器各自成块、尺寸不串台")
    nSplit := nSecond := false
    for r in NetRows(fake) {
        if (r[1] = "── 网卡 2 ──")
            nSplit := true
        if (r[2] = "CC-DD")
            nSecond := true
    }
    Emit((nSplit && nSecond ? "PASS " : "FAIL ") "两块网卡各自成块")
    fakeCpu := Map("cpus", [Map("name", "CPU-A", "mfr", "Intel", "caption", "Intel64 Family 6"
                              , "socket", "LGA1700", "cores", 6, "threads", 12, "maxMhz", 2500
                              , "extMhz", 100, "l2", 7680, "l3", 18432, "addr", 64, "data", 64
                              , "arch", 9, "pid", "P1", "vmx", 1, "slat", 1, "vfw", 0)
                            , Map("name", "CPU-B", "mfr", "Intel", "caption", "Intel64 Family 6"
                              , "socket", "LGA1700", "cores", 8, "threads", 16, "maxMhz", 3000
                              , "extMhz", 100, "l2", 8192, "l3", 24576, "addr", 64, "data", 64
                              , "arch", 9, "pid", "P2", "vmx", 1, "slat", 1, "vfw", 0)])
    cSplit := cSecond := false
    for r in CpuRows(fakeCpu) {
        if (r[1] = "── 处理器 2 ──")
            cSplit := true
        if (r[2] = "CPU-B")
            cSecond := true
    }
    Emit((cSplit && cSecond ? "PASS " : "FAIL ") "双路 CPU 各自成块")

    ; 4. 真实采集：八页都要能生成，不得抛错
    d := Collect()
    if (d["error"] != "") {
        Emit("FAIL 采集失败：" d["error"])
    } else {
        pages := BuildPages(d)
        Emit((pages.Length = 8 ? "PASS " : "FAIL ") "生成 8 个页面")
        emptyPages := 0
        for p in pages {
            rows := p["rows"]
            if (!IsObject(rows) || rows.Length = 0)
                emptyPages++
            ; 每行必须两格
            for r in rows
                if (r.Length != 2)
                    emptyPages++
        }
        Emit((emptyPages = 0 ? "PASS " : "FAIL ") "每页都有内容且每行两格")
        Emit((d["sticks"].Length > 0 ? "PASS " : "FAIL ") "内存条数 > 0")
        Emit((d["gpus"].Length > 0 ? "PASS " : "FAIL ") "显卡数 > 0")
        Emit((d["disks"].Length > 0 ? "PASS " : "FAIL ") "硬盘数 > 0")
        Emit((d["os"].Count > 0 ? "PASS " : "FAIL ") "操作系统信息非空")
    }

    ; 5. SMBIOS Rank：Type 17 Attributes 的 bit3:0 是 Rank 数（dmidecode 取 data[0x1B] & 0x0F）
    ranks := ReadSmbiosRank()
    bad := 0
    got := 0
    for loc, r in ranks {
        if (r < 0 || r > 15)
            bad++
        if (r > 0)
            got++
    }
    Emit((bad = 0 ? "PASS " : "FAIL ") "Rank 值全部落在 0..15")
    Emit((ranks.Count = 0 || got > 0 ? "PASS " : "FAIL ") "实机内存条读到了非零 Rank")

    fails := 0
    for ln in StrSplit(out, "`n")
        if (SubStr(ln, 1, 5) = "FAIL ")
            fails++
    Emit("fails=" fails)
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(fails ? 1 : 0)
}

; ── 纯文本导出：--dump [输出路径] ─────────────────────────────────────
; 与 GUI 同源同页，便于把全部信息贴给他人或留档。
if (A_Args.Length >= 1 && A_Args[1] = "--dump")
    RunDump(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\硬件信息\硬件信息.txt")

RunDump(path) {
    d := Collect()
    pages := BuildPages(d)
    out := ""
    for p in pages {
        out .= "===== " p["name"] " =====`n"
        for r in p["rows"] {
            if (r[1] = "" && r[2] = "")
                out .= "`n"
            else if (r[2] = "")
                out .= r[1] "`n"
            else
                out .= r[1] "： " r[2] "`n"
        }
        out .= "`n"
    }
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(0)
}

BuildGui()
Refresh()
