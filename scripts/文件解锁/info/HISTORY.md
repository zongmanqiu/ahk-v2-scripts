# 文件解锁 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

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
