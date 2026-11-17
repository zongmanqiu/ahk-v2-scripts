# 右键复制路径 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.0.0（2026-11-17）

首个正式版。按场景给资源管理器右键加固定动作「复制完整路径」，只写 HKCU、随时可撤销。全程不改宿主，MCP 实机闭环。

**功能**
- 四场景独立开关：文件 / 文件夹空白处 / 文件夹 / 驱动器；勾选后点「应用」，点「撤销」全清。
- 菜单项显示中文「复制完整路径」，点击把 `%1` 写进剪贴板，无窗口；重开窗口按注册表回填勾选。
- 写完广播 `SHChangeNotify(0x08000000)`，免重启资源管理器即时生效。

**关键实现**
- `CopyVerb()` 固定 ASCII `AHKDeckCopyFullPath`；`SceneRoots()` 封闭四场景，不做开放集合。
- `BuildCommand()` 按解释器文件名分流：宿主 `AHKDeck.exe` 必须插 `--run <脚本>`；独立 `AutoHotkey64.exe` 直接跟脚本路径。每段路径都带引号，中文空格路径不散。
- GUI 客户区 420×228：四层 `FlatCheck` + 两层 `FlatButton` + 色块状态条，八色封版、无系统控件。

**坑（本轮实证）**
- 本内核 `RegWrite` 签名是 `(Value, ValueType, KeyName, ValueName)`，不是现代 AHK v2 顺序——写反报 `Parameter #2 invalid`。
- `RegDelete` 只删值；删菜单项必须用 `RegDeleteKey`（先 `\command` 再父键）。Python 侧清理跨视图要用 `DeleteKeyEx`。
- 菜单命令漏 `--run` 时 `AHKDeck.exe` 只打印 usage、剪贴板不变——**假成功**，必须实机读剪贴板验证。
- 自绘勾选方块由注册表回填初值；测试必须先清注册表再启动 GUI，否则点击是在旧状态上翻转，净结果错乱。

**验收**：`--validate` rc=0；`--selftest` 8 项全绿；`ui_static.py 右键复制路径` 10/10；五层实机回归 ALL PASS（selftest / GUI 几何 / 勾选两场景后注册表恰好两处 / 命令行格式与中文显示名 / 撤销后清零）；菜单命令实机点击后剪贴板 = `C:\Users\user\Desktop\测试 文件.txt`（含中文与空格）。
