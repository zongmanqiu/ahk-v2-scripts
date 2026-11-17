# 文件解锁 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.1.0（2026-11-17）

按用户反馈重做产品形态：从「选路径 → 检测 → 列进程 → 结束进程」改为 DeadLock 式的
「拖入即检测 → 解除占用 / 删除」纯粹工具。用户核心诉求是**能删掉删不掉的文件**
（典型：`E:\tmp\AI.Agent\TinySoftware\Textus\nul` 在资源管理器里误报「需要管理员权限」）。

**功能变化**
- 界面精简：去掉选择路径按钮、输入框、检测按钮；顶部一句话说明 + 大列表（路径/类型/状态）+「解除占用」「删除」两按钮 + 状态条。
- 拖入文件/文件夹即加入列表并自动检测；状态列显示「未占用」或「被占用 · 进程名列表」。
- 新增「删除」：永久删除（不进回收站），先清只读/隐藏/系统属性，占用则先解锁，再删。
  文件用 `DeleteFileW`、目录自底向上 `RemoveDirectoryW`；reparse point 只删链接本身。
- **保留名文件删除**：一律用 `\\?\` 直通路径（UNC 用 `\\?\UNC\`），绕过 Win32 对 `nul`/`con` 等
  保留设备名的解析。实测：普通 `DeleteFileW(...\nul)` 返回 0/err=5（就是用户看到的「需要管理员权限」假象），
  `\\?\` 前缀版本返回 1 且文件确实消失。这是本版解决用户痛点的关键。

**关键 bug 修复（本轮实测发现）**
- `nul`/`con` 用普通路径探测开/FPIF 会被 Win32 当设备，误报几十个无关占用进程（node/explorer 等），
  删除时会误杀。改为 `IsLocked`/`FindOwners` 一律用 `\\?\` 路径打开后，nul 正确显示「未占用」。
- `gItems.Delete(i)` 在遍历中删数组元素会留 AHK 数组空洞，导致 `RefreshList` 报「Item has no value」。
  改为先记录删除下标、最后重建数组，运行时错误消失。

**验收证据**
- `--validate` rc=0；`--selftest` 9 项全绿（含 NtPath 盘符/UNC 前缀、FPIF 找 PID、删除保留名 con）。
- MCP 端到端（确认框在测试副本里临时短路，验证后已恢复真源）：
  - 拖入 nul → 列表显示「未占用」→ 删除 → bash 确认文件真消失、列表 count 1→0、无运行时错误。
  - holder 占用普通文件 → 拖入显示「被占用 · AutoHotkey64.exe」→ 解除占用 → 状态变「未占用」、
    holder 进程确实被结束（ALIVE=False）、无错误。
- `ui_static.py 文件解锁` 10/10；独立运行 + 宿主 `--run` 双截图对齐。

## 1.0.0（2026-11-17）

首个正式版。选择/拖入文件或文件夹 → 检测占用 → 列出占用进程 → 手动确认后结束进程解锁。

**功能**
- 占用检测：`CreateFileW(DELETE=0x10000, share=7)` 试探开，返回 INVALID_HANDLE_VALUE + err32/33 即被占用。
- 找占用者：`NtQueryInformationFile(FileProcessIdsUsingFileInformation=47)` 一次调用返回占用该文件的 PID 列表。
- 解锁：`TerminateProcess` 仅对用户在列表勾选的进程、二次确认后执行；系统关键进程保护名单拦截；结束成功自动复查。
- 文件夹递归扫描（深度上限 32）；报告被占用文件数、识别到的进程数。

**技术取舍（实测，Win11 build 26200 + AHK v2）**
- 找占用者试过三条路，均已证伪，最终采用 FPIF：
  1. Restart Manager：本机 `RmStartSession` rc=0 但 session 句柄恒 0，`RmRegisterResources(0)`→rc=6，
     `RmGetList` 挂起（AHK + Python ctypes 双证）。调研报告"RM 第一梯队完全可行"是基于 C# 的推断，本机不成立。
  2. 全系统句柄枚举 + 逐个 `DuplicateHandle`/`GetFinalPathNameByHandle`：约 18 万句柄，按 PID 分组优化后仍 90s+ 超时。
  3. 句柄表 `Object` 字段比对（零 syscall 理想方案）：Win8+ 起该字段被安全加固恒为 0x0，无法比对。
  FPIF 一次调用、瞬间完成、无需提权、无需外部 exe，是正解。
- 参考来源：`E:\tmp\AI.Agent\TinySoftware\AHKDeck\.ex\文件解锁\文件解锁项目原理调研报告.md`（十条开源项目调研）

**验收证据**
- `--validate` rc=0；`ui_static.py 文件解锁` 10/10；`--selftest` 6 项全绿（含 FPIF 找出占用本文件 PID）。
- MCP 闭环端到端：holder 进程占用临时文件 → GUI 检测 → 列表正确显示 `AutoHotkey64.exe / PID / 文件名`，
  列出的 PID 与 holder 实际 PID 逐位一致；独立运行 + 宿主 `--run` 双截图对齐，无内核报错。
