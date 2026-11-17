# 文件解锁 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.3.1（2026-11-17）

按反馈修列表 UI：缩放闪烁、滚动条不合规。MCP 实测定位，全程不改宿主。

**改进**
- **列表改自绘滚动条**：整段移植《硬件信息》2.3.4 的 `class FlatScroll`（只竖轴版），
  含 `HookBarInput` 三个消息回调（滚轮/翻页键/拖滑块）。原生条用 `ShowScrollBar(FALSE)` 摘掉，
  `Move`/`Add`/`Delete`/`ModifyCol` 后会置回样式位，故每个动作后补一刀 + `Sync` 60ms 兜底。
  **横向条撤掉**（横向 `LVM_SCROLL` 实测不生效，K30），列宽做进视口：出现竖条时可视宽少
  10px，路径列跟着收，改列宽后 `gList.Redraw()`（K31 行底色停在旧列宽）。
- **列表外框改白底块 + 四边各 1px 线**（§10.4 / K42），不再整块 `B7C8E0` 打底——
  原生条被摘掉后那块区域不重绘，整块底色会从缝里露出 16px 竖条。
- **去掉缩放闪烁**：删掉 1.3.0 的 `ForceRepaint`（`RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW`
  ——`RDW_ERASE` 先擦白底再画，正是闪烁源，K44）。改为静态色块逐个
  `InvalidateRect(hwnd,0,0)`（第三参 0=不擦背景，K47），列表开 `LVS_EX_DOUBLEBUFFER`。

**坑**
- 1.3.0 写进开发指南的「缩放必须 `RedrawWindow(RDW_ERASE|ALLCHILDREN|UPDATENOW)` 强制重画」
  是**错的方向**，被实测推翻（RDW_ERASE 就是闪烁根因），已在指南 §4 更正。
- AHK v2 单行里两个语句必须分行或加分号，`if (x) { a()  return 1 }` 报 `Unexpected "{"`。

**验收**：MCP 数值读图——修复前列表右侧每行 16px `F0F0F0` 原生条 + 底部横条，修复后
`F0F0F0`=0、只剩自绘蓝色滑块；控件树 ListView 样式位 `0x5031400D`→`0x5001400D`
（`0x300000` 横竖条位摘除）；放大到 900×520 后列头/按钮/状态条全跟随、无残影、滚轮生效；
仓库回归六层 ALL PASS。

## 1.3.0（2026-11-17）

按反馈改两处：删除改走回收站（可还原），缩放时重绘不及时。

**改进**
- **删除 → 回收站**：`SHFileOperationW(FO_DELETE | FOF_ALLOWUNDO | FOF_SILENT | FOF_NOCONFIRMATION
  | FOF_NOERRORUI)`，目录整棵进回收站、还原时整棵回来。核心原则：**回收站失败就如实报错，
  绝不悄悄改成永久删除**，否则用户以为还能还原。被占用的项先按保护名单解占用再搬。
  Windows 保留名（nul/con/aux/prn/com1-9/lpt1-9，带扩展名也算）回收站不收 → 仍走永久删，
  确认框与状态条分开计数写明（「回收站 N 项 · 永久删除 M 项」）。
  状态条不再有 `成功/失败` 的模糊说法。
- **缩放重绘**：`WS_CLIPCHILDREN` 防父窗口刷到子控件上；每次 `Size` 重排后
  `RedrawWindow(RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_UPDATENOW)` 强制整窗同步重画，
  不再等下一轮消息（原先拖边框会看到旧痕迹）。

**坑**
- `SHFileOperationW` 的 `pFrom` 必须是**双 null 结尾**的绝对路径，且**不能带 `\\?\`**
  （Shell 不认直通前缀）。结构体 x64 布局 56 字节：hwnd@0 / wFunc@8 / pFrom@16 / pTo@24 /
  fFlags@32(WORD) / fAnyOperationsAborted@36 / hNameMappings@40 / lpszProgressTitle@48。

**验收**：selftest 15 项全绿（新增 4 条保留名识别）；回归六层 ALL PASS（新增「删除进回收站」
——用 `SHQueryRecycleBin` 断言盘上回收站项数 +1，证明真能还原）；连续三档缩放后**立刻**截图无残留。

## 1.2.0（2026-11-17）

用户实测「解除占用成功、但删除失败」，又提了两点体验要求。这一版修掉两个真 bug，
并按需求把状态列改成「占用程序」、窗口改成可缩放。

**修复**
- **`\\?\` 前缀被加两次 → 一律 err=53**：`Loop Files` 枚举出来的路径已经带 `\\?\`，
  再进 `NtPath()` 时先命中了 UNC 分支（`SubStr(path,1,2)="\\"`），拼成
  `\\?\UNC\?\E:\...`，`DeleteFileW` 直接回 53(BAD_NETPATH)。**表现为"解除占用成功但删不掉"**。
  `NtPath()` 改为先判 `\\?\` 前缀、幂等返回。
- **删除目录只清顶层文件**：子目录里的文件从未被删，`RemoveDirectoryW` 得 145(目录非空)，
  整棵树删不掉（`5-文件夹`、`6-深层目录` 都会中招）。改为逐层掏空：按深度降序，
  每个子目录先删光自己的直接文件再 `RemoveDirectoryW`；并收集失败项写进提示，
  不再把所有子错误一笔勾掉。

**改进**
- **状态列改名「占用程序」**：有占用直接显示进程名（多进程逗号分隔、同名只写一次），
  无占用显示「无占用」，ACL 拒绝显示「无权限」。汇总行改用 `it.occ` 机器码统计，不再字符串匹配。
- **窗口可缩放 / 可最大化**：`+Resize` + `Size` 事件重算布局——列表吸收纵向余量、
  路径列吸收横向余量、状态条永远贴底、按钮宽度恒定（K25，不被拉伸）。
  拖拽下限 560×340（`WM_GETMINMAXINFO`）。

**坑**
- `WM_GETMINMAXINFO` 在 `Gui()` 构造期间就会到达，此时 `gGui` 还没赋值 → 必须 `IsSet` 判空，
  否则每次启动抛一次运行时错误（测试用 `get_session_output.errors` 才抓到）。

**验收**：selftest 11 项全绿（新增 NtPath 幂等、删含子目录的文件夹）；回归五层 ALL PASS
（新增缩放/最大化几何断言层）；实机 1000×600 截图确认列头与列对齐、无横向滚动条、状态条贴底。

## 1.1.3（2026-11-17）

用户实测点「解除占用」→ 确认框 → 点「是」，状态条却回「已取消」。查到根因，属真 bug。

**修复**
- **MsgBox 返回值是字符串不是数字**：AHK v2 的 `MsgBox()` 返回按钮**名称**（`"Yes"`/`"No"`/…），
  不是 v1 的 `6`/`7`。原代码 `if MsgBox(...) != 6` 恒真 → 无论点什么都当作用户取消。
  两处（确认解除 / 确认删除）都改为 `!= "Yes"`。
  探针实证：`RESULT=[Yes] type=String`，同时 `CMP_STRING=YES`、`CMP_NUM6` 不成立。
- **解除后残留「被占用（未知进程）」**：结束进程后立刻复查，内核还没回收句柄，
  读到残留共享冲突 → 状态停在「被占用（未知进程）」。`Sleep 400` 后再复查。
- **测试补第 4 层**：确认框不再豁免——向 `#32770` 投 `WM_COMMAND(IDYES=6)` 即可点「是」，
  断言状态含「解除完成」且不含「已取消」、行状态翻回「未占用」。此前的
  "模态框无法外部注入" 结论作废（当时观察到的是同一个字符串 bug）。

**验收**：validate rc=0；selftest 9 项全绿；回归四层 ALL PASS；实机端到端
（PowerShell 占用器 → 拖入「被占用 · powershell.exe」→ 点解除 → 确认「是」→
「解除完成 · 已结束 1 个进程」→ 行变「未占用」，汇总「0 项被占用」）。

## 1.1.2（2026-11-17）

为手动测试造了一批顽固文件集，自检时发现两处状态误判，属真实缺陷，修掉。

**修复**
- **ACL 拒绝 ≠ 被占用**：`拒绝删除.txt`（icacls `/deny 用户:(D,WDAC)`）被 `FSState` 判为
  `denied` 后显示「无权限（需管理员）」，不再误显示「被占用」诱导用户去结束进程（那里根本没进程）。
  状态模型拆为 5 态：`""` 可删 / `locked`(32,33) / `denied`(5) / `gone` / `err<码>`。
  `PathLocked` 只在 `locked` 时为真。
- **junction 误判为文件且误报占用**：`FileExist()` 对目录链接不可靠（返回非 "D"），导致
  `指向真实目标的链接` 显示「文件 + 被占用」。改用 `GetFileAttributesW` 判断：
  `FILE_ATTRIBUTE_DIRECTORY(0x10)` 辨目录、`REPARSE_POINT(0x400)` 辨链接，类型列显示「链接」。
- **递归不再进链接目标**：`CollectFiles` / `CollectDirsOnly` 遇 reparse point 只收链接本身，
  不进目标——否则会把目标目录一堆无关文件算进来，删除时也可能误伤。
- 删除分支改由 `IsDirPath()` 决定（不再依赖缓存的 `isDir`），文件符号链接走 `DeleteFileW`。

**测试集**（`.temp/文件解锁测试/`，gitignore 内，可整目录删）
1-保留名（nul/con/aux/prn/com1）、2-属性（只读/隐藏/系统/三合一）、3-权限受限（ACL 拒绝）、
4-被占用（配 `启动占用.bat` 用 PowerShell 持句柄）、5-文件夹（含只读子文件/空夹）、
6-深层目录（6 层）、7-链接（junction）。附 `说明.txt` 写清每个的预期结果。

**验收**：validate rc=0；selftest 9 项全绿；回归三层 ALL PASS；自检 14 项状态全部正确
（保留名/属性=未占用、ACL=无权限、链接=链接·未占用）。

## 1.1.1（2026-11-17）

按用户对界面截图的四点反馈修正版式，功能不变。

**版式修正（对齐 UI规范 §10.3）**
- 删掉顶部说明行（"把文件或文件夹拖进列表…"）——功能自明，不需要。
- 按钮宽改为**按文字实际宽自适应**：`MeasureTextWidth()` 用 GDI `GetTextExtentPoint32W`
  量 s10/Microsoft YaHei UI 的文字宽，按钮宽 = 文字宽 + 2×`BTN_PAD`(16)。
  实测「解除占用」52→84、「删除」26→58。此前写死 112/120 违反 §10.3.1-2 的 K25
  「不要为了铺满把按钮撑宽」。按钮组右对齐到行右缘 656，余量留在组左侧放汇总信息。
- 去掉那条空的信息行，汇总信息（N 项 · M 项被占用）移到操作行左侧，与按钮同一行。
- 垂直节奏收紧为 §10.3.1-3：列表区顶 12、高 270（底 282）→ BLOCK_GAP 6 → 操作行 288（高 28）
  → BLOCK_GAP 6 → 状态条 322（高 30）→ 贴窗口底。窗口 672×**352**（原 428，多出 76px 空白）。
- 版式常量（EDGE/ROW_W/BTN_PAD/INLINE_GAP/BLOCK_GAP/H_ACTION/H_STATUS/H_HEADER）集中声明，
  坐标由常量算出，不再散落魔法数字。

**验收**
- `--validate` rc=0；`--selftest` 9 项全绿；回归三层 ALL PASS（新增断言：无顶部说明行、
  无输入框、按钮宽≈84/58、操作行 y≈288、窗口高=352、状态条贴底）。
- `ui_static.py 文件解锁` 10/10；截图复核：列表占满主体、按钮自适应、无多余空白。

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
