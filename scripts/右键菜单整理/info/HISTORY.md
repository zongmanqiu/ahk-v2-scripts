# 右键菜单整理 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

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
