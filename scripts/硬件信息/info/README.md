# 硬件信息

按硬件分页查看这台机器的规格：左侧八页导航，右侧把该硬件的每项属性逐行列出。
数据只读本地，不联网、不要管理员、不装驱动。

## 功能

左侧八页，点击切换（当前页以浅蓝底高亮）：

| 页 | 内容 |
|---|---|
| **CPU** | 型号、厂商、核心/线程、基准频率、外频、L2/L3 缓存、插槽、架构与总线宽度、硬件虚拟化、SLAT、固件虚拟化、处理器 ID、**家族/型号/步进**、**指令集**（MMX~AVX2、RDRAND、RDTSCP、XSAVE） |
| **主板** | 主板厂商/型号/版本/序列号、BIOS 厂商/版本/日期、SMBIOS 版本、整机型号、机箱类型 |
| **内存** | 总量、类型、插槽占用、主板最大支持、ECC；随后逐槽列出容量、频率（标称与实际）、模组厂、型号、序列号、Rank、电压、规格（DDR4/DDR5 · DIMM/SODIMM · 位宽） |
| **显卡** | 名称、厂商、**显存（驱动登记的精确字节数）**、芯片、**vBIOS 版本**、驱动版本与日期、输出分辨率、刷新率、视频处理器、设备 ID |
| **磁盘** | 每块硬盘的型号/容量/**总线**（NVMe/SATA/USB）/介质/固件/序列号/分区数；每个分区的容量、可用、已用百分比、文件系统 |
| **网卡** | 每块**物理网卡**的名称、适配器类型（以太网/无线）、MAC、连接速率、连接状态 |
| **显示器** | 显示器名称、厂商代码（EDID 的 3 字母 PnP ID，原样输出，如小米 `XMI`、联想 `LEN`）、产品代码、序列号、生产年周、对角线尺寸、**接口**（HDMI / DisplayPort / DVI…） |
| **系统** | 操作系统/版本/Build/架构、安装与启动时间、计算机名、当前用户、系统类型、物理内存总量、系统序列号、时区、音频设备 |

- 窗口只有一块列表：没有标题行、没有按钮、没有状态条。内容多时右侧出现自绘滚动条
  （浅蓝槽 + 深蓝滑块，与左侧导航同一套配色），可用滚轮、拖动滑块、点击槽翻页、
  PgUp/PgDn/Home/End 翻动。
- 窗口**可缩放、可最大化**（最小 560×400）。值列里有长文本（显卡设备 ID、网卡名称），
  拉宽窗口即可看全，列表与列头带一起跟随。
- **复制**：列表上点右键 →「复制此行」或「复制本页全部」；也可选中一行后按 `Ctrl+C`。
  复制内容是 `属性<TAB>值`，粘到 Excel 里正好是两列。
- `F5` 重新采集一遍（窗口处于激活状态时）。

## 多硬件

一块硬件一条记录，不是「只显示第一块」：

| 类别 | 多件时怎么显示 | 口径与边界 |
|---|---|---|
| CPU | 双路主板每颗一块「── 处理器 N ──」 | 只有插了 CPU 的插槽才报 |
| 内存 | 按槽位逐条（A1/A2/B1/B2），每条独立 Capacity/频率/厂商/Rank/电压 | 空槽不列；槽位名由 `DeviceLocator` 推导 |
| 显卡 | 每块适配器一块「── 适配器 N ──」 | 含核显（BIOS 里关掉的不会出现） |
| 硬盘 | 每块物理盘一块「── 硬盘 N ──」，分区单独一块 | U 盘/移动硬盘也会列出 |
| 网卡 | 每块物理网卡一块「── 网卡 N ──」 | 只列 `PhysicalAdapter=True`，虚拟网卡（VMware/Hyper-V/TAP）不列 |
| 显示器 | 每台一块「── 显示器 N ──」，尺寸按 `InstanceName` 各自配对 | `WmiMonitorID` 只报**当前活动**的显示器：接了但被禁用、或处于「仅在 1 上显示」时可能不出现；虚拟显示器不报 |
| 音频设备 | 逐个列出名称与厂商 | — |

> 多显示器的「尺寸配对」在 2.2.1 修过：旧逻辑按顺序硬配，两台以上会串台。

## 只列规格，不列仪表

CPU 当前频率与负载、可用内存这类每秒都在变的瞬时值一律不显示——那是任务管理器的活。
窗口里每一行读出来都是稳定的硬件事实，不会看着看着数字跳。

## 入口

- 主窗口即唯一入口：标题栏关闭按钮直接退出进程（不驻留）。
- 命令行分支（无 GUI）：
  - `--selftest [输出路径]`：断言码表、日期格式、四类槽位形态、八页均可生成、
    显卡/硬盘/OS 非空、SMBIOS Rank 值域、多显示器/多网卡各自成块，`rc=0` 全绿。
  - `--dump [输出路径]`：把八页导成纯文本，便于留档或贴给他人。

## 数据来源

| 数据 | 来源 | 需驱动 |
|---|---|---|
| CPU、主板、BIOS、整机、操作系统 | `Win32_Processor` / `Win32_BaseBoard` / `Win32_BIOS` / `Win32_ComputerSystem` / `Win32_OperatingSystem` | 否 |
| 机箱类型、时区 | `Win32_SystemEnclosure` / `Win32_TimeZone` | 否 |
| 内存容量/频率/厂商/型号/序列号/电压/类型 | `Win32_PhysicalMemory` / `Win32_PhysicalMemoryArray` | 否 |
| **内存 Rank** | SMBIOS 原始表 `GetSystemFirmwareTable("RSMB")` 解析 Type 17 | 否 |
| 显卡基本信息（名称/厂商/驱动/分辨率/设备 ID） | `Win32_VideoController` | 否 |
| **显卡显存、vBIOS、芯片** | 注册表 `Class\{4d36e968-…}\000X` 的 `HardwareInformation.qwMemorySize` / `BiosString` / `ChipType`（显卡驱动登记，按 `MatchingDeviceId` 配对） | 否 |
| **CPU 家族/型号/步进** | `Win32_Processor.ProcessorId` 末 8 位（CPUID 叶 1 的 EAX）解码 | 否 |
| **指令集** | `kernel32!IsProcessorFeaturePresent`（与 CPUID 同源，不必执行机器码） | 否 |
| 硬盘与分区 | `Win32_DiskDrive` / `Win32_LogicalDisk`（总线由 `PNPDeviceID` 判 NVMe/USB） | 否 |
| 网卡（型号/MAC/类型/速率/状态） | `Win32_NetworkAdapter`（`PhysicalAdapter=True`） | 否 |
| 显示器（型号/序列号/尺寸/接口） | `root\wmi` 的 `WmiMonitorID` / `WmiMonitorBasicDisplayParams` / `WmiMonitorConnectionParams` | 否 |
| 音频设备 | `Win32_SoundDevice` | 否 |

## 写入位置

- 无：不写注册表、不写配置；`--selftest` / `--dump` 的输出路径由命令行指定（默认脚本旁）。

## 已知局限（如实标注，不修饰）

- **显存**：优先读显卡驱动登记的 `qwMemorySize`（REG_QWORD，精确到字节，本机 6 GB 即
  6442450944）。驱动没登记时退回 `AdapterRAM`——那是有符号 32 位，≥4GB 会把值顶在
  4095 MB 附近，此时显示「4 GB 以上（取不到准确值）」而不是硬编一个数。
- **硬盘总线**：WMI 的 `InterfaceType` 常把 NVMe 报成 `SCSI`（固件层枚举方式），
  故总线取自 `PNPDeviceID` 里的 `VEN_NVME` / `USBSTOR`。
- **指令集**：来自内核判定，不含 HWiNFO 那类靠 CPUID 逐位展开的完整列表（如 AVX-512
  子集）；本机 i5-12400F 只列到 AVX2，与 CPU 实际能力一致。
- **型号空白**：部分内存模组（实测金百达）不写 PartNumber，显示「未提供」。
- **笔记本内屏**：部分机器不在 `WmiMonitorID` 里报内屏，显示器页会提示「未检测到」。
- **码表口径**：内存类型、Rank、封装、机箱类型、ECC 这几张码表都按 SMBIOS 规范逐项对齐，
  以 dmidecode 上游实现（`dmi_memory_device_type()`、`dmi_chassis_type()`）为准。
  两点容易被搞混：内存类型取的是 WMI 的 `SMBIOSMemoryType`（SMBIOS 码，**DDR5 = 0x22**），
  封装取的是 `FormFactor`（CIM 码，**DIMM = 8**）——两套码不同源，不能互相套用；
  Rank 读的是 Type 17 `Attributes` 的低四位，`0` 表示主板没填，显示为「未填」。

## 不做（及原因）

- **内存时序 tCL/tRCD/tRP/tRAS、DRAM 颗粒厂、XMP/EXPO、SPD 温度**：只在 SPD EEPROM，
  读它必须签名内核驱动（PawnIO 一类），纯脚本无解。
- **硬盘 S.M.A.R.T. 健康度/通电时长**：需 `DeviceIoControl` 直读且各厂字段不一，留给专门工具。
- **显卡温度/功耗/风扇**：需厂商 SDK（NVAPI/ADL）或驱动接口。
- **当前负载/当前频率/可用内存**：瞬时值，属任务管理器的职责，本脚本只报规格。
- **IP 地址 / 默认网关 / DHCP**：属系统网络配置（`ipconfig` 的职责），不是硬件规格，故不显示。
- 不做跑分、不做温度监控、不下「健康/故障」结论——只陈述读数。

## 界面实现

- 界面统一按 `开发指南.md` §10 落地（八色令牌、字号、尺寸令牌、K19/K22/K24/K27）。
- 脚本内所有界面元素都集中在文件顶部的**「UI 组件区」**，改样式只动那一区。
- 滚动条与《文件时间修改》2.4.6 的 `class FlatScroll` 同源。按 §10.1，**不抽公共
  `#Include` UI 库**（会破坏单文件分发模型），跨脚本统一靠「同一份实现 + 逐字同步」。
- 与通用配方有三处有意差异（都是本脚本实测出来的，注释写在类上方）：逐块 `SetWindowPos`
  代替批量 `DeferWindowPos`、`LVM_SCROLL` 代替 `LVM_ENSUREVISIBLE`、`LVM_GETCOUNTPERPAGE`
  代替 `lvH/itemH` 估算。
- 列表区用**白底块 + 四边各一条 1px `FRAME` 线**，不铺一整块 `FRAME`（同《打开方式清理》
  1.4.0 的结论）：原生 ListView 在列宽之外与空白行不保证重绘，铺底色会漏出一整块。
- 窗口可缩放：`OnSize` 里按客户区重排色块与列表，列宽按**可视宽**（已扣滚动条）分配。

## 来源与许可

- 独立实现，未复刻任何第三方源码。字段口径参考 SMBIOS 规范（DMTF）与 WMI 类文档。
- 滚动条沿用本仓库《文件时间修改》的 `FlatScroll` 实现（自绘槽/滑块，同一套 §10 色令牌）。
- 许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。
