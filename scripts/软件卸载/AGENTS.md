# 软件卸载 · 开发准则（本目录 AGENTS.md）

> 本文件管「软件卸载」这个脚本的一切开发活动。放在脚本目录内，任何 AI/维护者在
> 本目录下工作时应先读本文件。仓库级规矩见 `.ahk-v2-scripts\开发指南.md`，
> 全局硬规矩见 `AHKDeck\AGENTS.md`——本文件只做叠加与强调，不推翻它们。

---

## ★ 初始要求（用户 2026-11-23 定，不许忘）

1. **不改本体代码**：`.main\`（宿主 C++ 源码）、`.build`（发行产物）、宿主构建链
   全部冻结。本轮**只写 AHK 脚本**，改动只落在 `scripts\软件卸载\` 内
   （`.ahk`、`info\`、`test\`）与 `.build\Scripts\软件卸载.ahk` 出货件。
2. **写脚本前必须先读 `.build` 的程序与文档**：
   `docs\MCP接入.md`（20 工具全表）、`docs\脚本开发流程.md`（总循环）、
   `docs\开发指南.md`（仓库规约）、`docs\UI规范.md`（配色/版式令牌）。
3. **直接接入 `.build` 的 MCP 服务**：`AHKDeck.exe --mcp-stdio`，Loomy 侧已挂载
   （id=ahkdeck）。实机闭环是**硬门禁**：`list_scripts → run_script →
   get_session_output → stop_script`；GUI 另加 `inspect_ui / capture_ui / ui_diff /
   assert_ui`。`--validate` 与 `--selftest` 只是前置门禁，不能替代它。
4. **目标**：干净卸载——本体卸载（静默优先）+ 残留清理（文件 → 回收站、
   注册表 → 先 export 备份再删）。调研真源：
   `AHKDeck\.ex\软件干净卸载\软件干净卸载项目原理调研报告.md`（十个开源项目的
   源码级调研，含静默参数家族表、Job Object 等待、uproot 残留启发式）。
5. **适用 Win10 / Win11**：只用两版都有的 API。DwmSetWindowAttribute(34/35/36)、
   SHFileOperationW、Job Object、reg.exe export 均为 Win7+ 资产，安全；
   不引入任何 Win11-only 接口，不做 UWP/AppX 卸载（Win10/11 差异大，见「不做清单」）。

---

## 本机实测禁区（文件解锁 1.x 用血泪证伪的，别重走）

| 禁区 | 证据 |
|------|------|
| **Restart Manager**（RmStartSession/RmGetList） | 本机 `RmStartSession` rc=0 但 session 句柄恒 0，`RmGetList` 挂起（AHK + Python ctypes 双证，见 `文件解锁\info\HISTORY.md` 1.0.0 段）。调研报告里"RM 第一梯队"是 C# 推断，**本机不成立**。卸载脚本不需要 RM——卸载命令直接来自注册表 UninstallString。 |
| **全系统句柄枚举** | 逐个 DuplicateHandle 解析路径要 90s+，不可用。 |
| **句柄表 Object 字段比对** | Win8+ 起被安全加固恒为 0x0。 |
| **SHFileOperationW 的 pFrom** | 必须双 null 结尾、**不能带 `\\?\`**（Shell 不认）；结构体 x64 布局 56 字节。回收站失败就如实报错，绝不悄悄改永久删除。 |
| **占用者识别** | 已定论走 `NtQueryInformationFile(FileProcessIdsUsingFileInformation=47)`（文件解锁 1.0.0 实测：无需管理员、瞬间完成）。 |

## 本脚本的技术路线（1.0.0 定案）

1. **检测**：三处 Uninstall 键（HKLM64 / HKLM32(Wow6432Node) / HKCU）。
   过滤：`DisplayName` 为空、`SystemComponent=1`、`ParentKeyName` 非空（更新补丁）。
   MSI 产品码取 `{GUID}` 正则（`WindowsInstaller=1` 或串内含 msiexec）。
2. **静默命令决策链**：`QuietUninstallString` → MSI（`msiexec /X{GUID} /qn /norestart`）
   → 家族判定（`unins\d+\.exe`+同名 `.dat` → Inno `/VERYSILENT /SUPPRESSMSGBOXES
   /NORESTART`；`update.exe` → Squirrel `--uninstall --silent`；`uninst.exe/au_.exe`
   或文件内扫 `Nullsoft` → NSIS `/S`）→ 原始 `UninstallString` 兜底。
   解析三形态（带引号 / 裸 / 无引号含空格）用"最长存在的 .exe 前缀"规则（uproot）。
3. **等待**：Job Object（`CreateJobObject` → `AssignProcessToJobObject` →
   `QueryInformationJobObject` 的 `ActiveProcesses==0`）**叠加**"注册表键消失 +
   4 秒宽限"（UAC 提权的子进程会逃出 Job，靠键消失兜底）。SetTimer 状态机驱动，
   不阻塞 UI 线程。
4. **残留扫描**（uproot 启发式，全部移植进纯函数）：
   六大目录根（ProgramFiles / ProgramFiles(x86) / ProgramData / AppData /
   LocalAppData / LocalAppData\Programs）+ 三处 `Software\<名>`（HKCU / HKLM /
   WOW6432Node）+ 残留 Uninstall 键；
   **泛用名黑名单**（common/data/microsoft/…绝不能单独匹配）+
   **交叉引用排除**（候选与仍安装应用的 InstallLocation / 名字相交即跳过）+
   发行者嵌套（`Software\<厂商>\<应用>`）。文件夹 >2GB 默认不勾选。
5. **清理**：文件夹走回收站（可还原）；注册表先 `reg.exe export` 备份到
   `A_ScriptDir\软件卸载\backup\<时间戳>\` 再删键。备份失败就不删、如实报错。

## 版式与仓库规矩（硬）

- **UI 三份文档（UI规范 / UI组件手册 / UI踩坑）动手前必读**，本脚本首版就栽在
  只读流程文档、没读 UI 文档上。重点条款：
  - **§10.8 代码顺序固定**：全局变量 → class FlatScroll → 脚本侧滚动接管 →
    工具函数 → GUI → 无 GUI 分支 → BuildGui() 调用（类声明必须在 auto-execute
    调用之前，K18）。
  - **K36 批量填表配方**：列表 SW_HIDE → WM_SETREDRAW 0 → 填 → 摘原生条 →
    WM_SETREDRAW 1 → SW_SHOW → 补焦点（K39）→ 重算占位。136 行填充时
    comctl32 会当场刷出原生条（「空列表+两条原生灰条」），WM_SETREDRAW 单独用
    压不住非客户区（§10.7 黑名单明令）。
  - **K38 长任务期间定时器不来**：启动扫描走延迟单次定时器（SetTimer(fn,-120)），
    先画首帧再扫；同步块内不碰 UI。
  - **§10.6 状态条只写事实**：不写「先选中…」「勾选后点…」类指令句。
  - **§10.3.3 列头对齐**：列头文字块 x = 列表左缘 + 列起点 + CELL_PAD(6)；
    列宽和 = 列表可视宽，不留死区；竖条显隐时列头与列内容必须同步（AlignHeaders
    从 gScroll.ClientW() 取同一宽度真源）。
- 版式照 UI 规范令牌，范本 = `scripts\文件解锁\`（同族：列表 + 按钮 + 状态条 +
  FlatScroll + 可缩放）。不自造色值/字号；`python tools/ui_static.py 软件卸载` 过十项。
- 产物只写 `A_ScriptDir\软件卸载\`；`@id=software-uninstall` 发布后永改；
  `HISTORY.md` 只增不改；`@version` 改完当场升；不设全局热键（`@entry` 只写托盘/分支）。
- **改这个脚本只测这个脚本**（AGENTS.md 第 12 条）：`python tools/ui_static.py
  软件卸载`、`python scripts/软件卸载/test/run.py`（六层断言：selftest/几何/填表/
  原生条样式位/列头对齐/停止即退出），不跑别的脚本、不跑仓库级体检。
- 一次性探针用完即删；证据写进 `info/HISTORY.md` 或 `.plan` 文档。

## 不做清单（1.0.0 边界，想越界先改本文件）

- UWP/AppX/MSIX 卸载（另一套世界，Remove-AppxPackage 需要 powershell 子进程与
  预配包顺序处理，Win10/11 差异大）——列为 v2 候选。
- winget 通道（机器上可能没装 App Installer，引入不可控依赖）。
- 卸载前快照 / Install Monitor（USN 监听）——DeepPurge 审计证明这是高危区。
- 批量并行卸载（一次一个，串行）。
- 不杀进程、不改 ACL/所有权、不动 TrustedInstaller 键。
