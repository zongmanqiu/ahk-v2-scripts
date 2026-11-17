# 右键菜单整理 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.2.1（2026-11-18）

用户实测反馈三类问题，全部修掉：

**滚轮失效（真 BUG，根因一行）**：`BuildGui()` 的 `global` 声明漏了 `gScroll`，`gScroll := FlatScroll(...)` 赋进了局部变量，全局恒为 0；`OnBarWheel` 检查 `gScroll` 直接 return——而 `SetTimer(gScroll.fnSync, 60)` 用的恰是局部变量，滑块照常绘制，唯独滚轮全灭。补上声明即愈。实机验证（20 个临时 HKCU verb 造 35 行 + PrintWindow 截图扫 ACCENT 滑块）：滑块 y289→148→82，每次滚轮稳定位移。

**显示名与顺序对不上真实菜单**：注册表探针（用完即删）核对真实数据后——
- `NormalizePos` 改大小写不敏感：注册表实际存 `Position="Bottom"`（大写 B），旧代码 `==` 比较把它归一成"默认"，与 shell 行为不符。
- 新增 `FriendlyClsids()` 友好名映射：CLSID 默认值全是英文泛名（"Microsoft SendTo Service"），用户看到的是"发送到/新建/打开方式/授予访问权限/NVIDIA 控制面板"等；显示优先级 友好名 > 系统共享名 > 泛名。
- 新增 `BuiltinVerbNames()` 内建 verb 名兜底：`open` 键值全空，真实菜单显示"打开"是 shell 内建的，只能映射（打开/编辑/重命名/删除/剪切/复制/粘贴/属性/以管理员身份运行/打印/查找）。
- 列表排序改 shell 真实顺序：置顶 → 默认（注册枚举序）→ 置底，分桶拼接即稳定。

**UI 按 §10 规范修正**：状态条贴底（STATUS_Y 418→420，底边 450 齐窗）；按钮与状态条之间留 BLOCK_GAP=6（BTN_Y 388→384，列表底相应 374→378）；删除左侧"当前： xxx"标签（140px 窄栏显示不全，拖入状态看列表即可）；拖入区提示文字从 ACCENT 色改回 TEXT 色（ACCENT 只许给滚动条滑块）。

**验收**：`--selftest` 16 项全绿（新增内建名/友好名/大小写不敏感断言）；`ui_static 右键菜单整理` 10/10；六层 MCP 回归 ALL PASS（几何层新增贴底/间隔/标签删除断言）；滚轮实机截图三连验证滑块位移。

## 1.2.0（2026-11-17）

按用户"做太麻烦"的反馈，把交互从 8 导航 + 扩展名输入砍成**3 种日常场景**：拖入文件/文件夹、桌面空白处、文件夹空白处。读取引擎仍是注册表来源表（见下方"为什么不是直接读菜单"）。

**为什么不是"直接读取右键菜单"**：用户提议拖入后直接读这个对象的真实右键菜单。一次性探针（用完即删）实测 IContextMenu：`.md` 文件返回 11 项、显示名所见即所得（打开/管理/7-Zip/剪切/…），但 `7-Zip`、"包含到库中"这类 COM 项是 OWNERDRAW（`id=ffffffff`），**连 verb 都取不到**；静态项只有 verb（open/cut/copy），**不告诉你来自 `*` 还是扩展名还是 ProgID**。真实菜单是"渲染结果"，隐藏要的是"渲染来源"，缺这条映射就退化成只读查看器，正好丢掉用户要的隐藏+位置。故保留注册表读取，按对象类型合并展开。

**3 场景的位置根（实测，见 `.temp/probe_scenes.py` 探针，用完即删）**
- 桌面空白处 = `Directory\Background`（AnyCode/cmd/Powershell/New/N 卡/共享/WorkFolders）+ `DesktopBackground`（.Spotlight*/显示设置/EditStickers/个性化/UWTSettings），本机 15 项。
- 文件夹空白处 = `Directory\Background`，本机 9 项。
- 拖入文件 = `*` + `AllFilesystemObjects` + `SystemFileAssociations\<ext>` + ProgID（`HKCR\.<ext>` 默认值）；本机 .md 无 ProgID，实际是前三个。
- 拖入文件夹 = `Directory` + `Folder` + `AllFilesystemObjects`。

**实现要点**
- 同一菜单项常来自多处（7-Zip 在 `*` 与 `AllFilesystemObjects` 都注册），列表按 verb/CLSID 去重合并成一行，`roots[]` 记下全部来源；`WriteVerbMarks()` 对每个根都写/删影子键，否则别的来源会把菜单项重新带出来。
- 状态合并 hidden > syshidden > show；位置合并 top > bottom > default。
- 新增 `--probe roots <key> <结果文件> [路径]` 静默分支，实测三场景展开（宿主 MCP 的 send_input 命中不到被装饰色块包住的拖入区做拖放，故场景展开走探针、GUI 只测几何与两静态场景切换，K19）。
- 拖入区用 Text 色块 + `+0x200` 才收 `DropFiles`/`Click`（K19）；两行提示拆成两个 Text，避免 `Center`+换行在 132px 窄框里首尾被裁（截图实测）。

**坑（本轮踩到并修掉）**
- AHK 的 `SplitPath` 返回的扩展名**不带点**（`md` 不是 `.md`），第一次展开成 `SystemFileAssociations\md`，补点后正确。
- 多行表达式在字符串后换行会被解析成函数调用（`"」" (on ? …)` 报 "does not contain a recognized action"），改成先算局部变量再拼。
- 本内核无 `StrJoin`，`--probe roots` 改手写拼接。
- `--probe roots` 的 `FileAppend(.., "*")` 不进 stdout，改为写结果文件供测试读取。

**验收**：`--selftest` 14 项全绿；`ui_static 右键菜单整理` 10/10；六层 MCP 回归 ALL PASS（selftest / roots 三场景展开 / GUI 几何 820×450+3 入口+拖入区+四列 / 场景切换桌面 15 项>文件夹空白 9 项 / L1 多根隐藏与位置三档 / L2 Blocked 增删且 HKLM 原键不变）；截图确认三入口与拖入文字完整、15 行无重复、自绘滚动条在位、无原生灰条。

## 1.1.0（2026-11-17）

补齐 1.0.0 的两处覆盖缺口。起因：用户拿 `.ex/右键菜单/右键菜单项目原理调研报告.md` 这个文件反问"它的右键菜单怎么管理"——实测发现 1.0.0 只列了 L1 静态 verb 的一部分，既没按文件类型，也没有 COM 扩展，而这个文件上真正想关的 7-Zip / ima / 360 / Unlocker 全是 COM 扩展。

**新增**
- **L2 COM 扩展管理**：列出各位置的 `shellex\ContextMenuHandlers`，隐藏用 `HKCU\...\Shell Extensions\Blocked` 按 CLSID 写值名、删值恢复；实测 HKCU 侧 Blocked 生效、CLSID 原键与 HKLM 原值都不动。
- **按扩展名场景**：左侧第八项填 `.md` / `md` 归一为 `SystemFileAssociations\.md`，列出该类型专属菜单项。
- **来源列**：列表从三列扩为四列（菜单项 / 来源 / 状态 / 位置），静态与 COM 一眼可分；COM 项位置列显示 `—`（DLL 动态绘制，不支持置顶/置底）。
- **系统共享 CLSID 拒写**：共享 / 投射 / 还原 / 照片 / 库这类共用 CLSID 一旦 Blocked 会连带弄坏系统功能，脚本拒写并如实提示。

**机制与源码**
- COM 显示名优先取 handler 注册名（7-Zip / ImaContextMenu / Safe360Ext / UnLockerMenu 好认），CLSID 默认值次之；`ShellContextMenu Class` 这类泛名不采，回退注册名或 GUID。
- 造 `--probe verb <根> <verb> <动作>` 与 `--probe com <CLSID> <hide|show>` 两条静默分支，实机回归驱动同一套写函数（宿主 MCP 的 send_input 命中不到被装饰色块包住的 ListView，K19）。

**坑（本轮踩到并修掉）**
- `--probe verb` 的参数个数判成 `>= 6`，实际只有 5 个（`--probe` / `verb` / 根 / verb / 动作），一律报"probe 参数不对"——改 `>= 5` 后六层回归才通。这说明"新写的检查项先拿旧版本跑一次能红"的取证法也要覆盖参数个数这类边界。
- 列表协位置根不再含 `\shell`：位置定义改为 `*`、`Directory`、`Directory\Background` 这类根，枚举时再拼 `\shell` / `\shellex\ContextMenuHandlers`。
- COM 项进来后 18 行超出可视区，comctl32 把原生滚动条刷出来（灰条，违反 UI规范）；移植《文件解锁》1.3.1 的 `class FlatScroll` 自绘竖条，每次刷新列表后 `Layout()` 摘原生条 + 60ms `Sync` 兜底，列宽之和压到 614 ≤ 摘条后的内宽 620，避免横条再冒出来（K22/K29/K30/K36）。
- 第八项导航 `按扩展名` 在 y=240..268，原输入框标签画在 y=242，把导航文字盖住（截图实测，几何检查看不出来）；输入框下移到 y=292 让开。
- AHK 的 `=` 不区分大小写，`NormalizePos("Top")` 曾被误当 `top`——自测先红后改用 `==`。

**验收**：`--selftest` 11 项全绿；`ui_static.py 右键菜单整理` 10/10；六层 MCP 实机回归 ALL PASS（selftest / GUI 几何 820×450 + 8 导航 + 四列 / 真实 18 项含静态+COM 两来源 / L1 隐藏恢复只改 HKCU 影子键 / L1 位置三档只改 HKCU / L2 Blocked 按 CLSID 增删且 CLSID 显示名与 HKLM 原键不变）；截图确认导航项完整、自绘滚动条在位、无原生灰条。

## 1.0.0（2026-11-17）

首个正式版。零提权的右键菜单管理器，只做隐藏/恢复菜单项与调整位置两件事。全程不改宿主，MCP 实机闭环。

**功能**
- 七个固定位置（文件/文件夹/文件夹空白处/驱动器/文件夹对象/所有对象/桌面背景），左侧导航切换。
- 右侧列出该位置 HKCR 合并视图下的全部菜单项，名称/状态/位置三列；`@shell32.dll,-n` 间接串用 `SHLoadIndirectString` 解析成人话。
- 状态三态：显示 / 已隐藏（本脚本写的）/ 系统隐藏（HKLM 自带标记，零提权删不掉）。
- 隐藏/显示、置顶/置底/恢复位置，改完 `SHChangeNotify(0x08000000)` 即时生效。

**方案出处**
- 蓝本为 `ContextMenuManager` 的 `ShellItem.cs`：`ItemVisible`（隐藏）。`ItemPosition`（位置）两段约 100 行纯注册表逻辑；本文件是独立 AHK v2 实现，未复制其代码。
- 逐项目核对 `.ex/右键菜单` 13 个源码：真正做"单 verb 隐藏 + 位置"的只有 ContextMenuManager / ContextMenuMaster / ContextMenuMgr 三个；前者最适合翻译成单文件 AHK（纯值读写、无依赖）。其余做新增/整类切换/COM 扩展，与本需求无关。
- 吸收 ContextMenuMgr 的纪律：只写一个标记、记录来源、不碰 CommandFlags、恢复时不盲删第三方标记。

**关键机制（实测 + 源码双重确认）**
- 影子键：在 `HKCU\Software\Classes\<位置>\shell\<verb>` 写 `ProgrammaticAccessOnly=""` 或 `Position=top/bottom`。
- 一次性探针（用完即删）实测：影子键的值在 HKCR 合并视图可见；HKLM 原键的默认值/command 仍照常合并出来（菜单项不被写坏）；HKLM 原值不受任何影响；删掉影子键的值后合并视图恢复原状。这解掉了开工前"HKCU 能否覆盖 HKLM"的唯一不确定点。
- 四种隐藏标记是 OR：`HideBasedOnVelocityId==0x639bc8` / `LegacyDisable` / `ProgrammaticAccessOnly` / `CommandFlags%16>=8`；判当前状态四种都看，但本脚本只写 `ProgrammaticAccessOnly`。

**坑**
- 内核无 `RegEnumKey`：用 `RegOpenKeyExW` + `RegEnumKeyExW` 枚举子键（锁 `KEY_WOW64_64KEY`）。
- AHK 的 `=` 不区分大小写，`NormalizePos("Top")` 曾被误当 `top`——自测先红后改用 `==`，这就是"新断言先能红再信绿"。
- 嵌套函数里 `global fails` 未赋值报运行时错，改 ByRef 传累加器。
- 宿主 MCP 的 `send_input` 命中不到被装饰色块包住的 ListView（K19），点击/键盘都选不中行；加静默 `--probe` 分支驱动同一套写函数验证注册表，GUI 层单独测几何与列表内容。
- `--selftest` 输出路径必须是绝对路径，相对路径会报"找不到指定的路径"。

**验收**：`--validate` rc=0；`--selftest` 11 项全绿；`ui_static.py 右键菜单整理` 10/10；五层 MCP 实机回归 ALL PASS（selftest / GUI 几何 720×420 / 列出 7 个真实菜单项且状态三态正确 / 隐藏恢复只改 HKCU 影子键 / 位置三档只改 HKCU 且 HKLM 原键不变）；测试结束影子键清理干净。
