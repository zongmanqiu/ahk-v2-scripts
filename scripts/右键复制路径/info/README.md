# 右键复制路径

给资源管理器右键菜单加一项固定动作「复制完整路径」：文件、文件夹空白处、文件夹、驱动器四个场景可分别开关，只写当前用户（HKCU），随时可撤销。

## 功能

- 主窗口勾选要启用的场景，点「应用」即刻生效；点「撤销」清除本脚本写入的全部菜单项。
- 重开窗口会读取注册表，回填当前已启用的场景，不会把旧状态冲掉。
- 在已启用的场景右键，点「复制完整路径」即把选中项的完整路径写进剪贴板，不弹窗、不等确认。
- 路径含空格、中文均可正确复制（命令行里 `%1` 带引号）。
- 只往右键菜单追加一个自定义动词，不改默认打开方式，也不碰 open/edit 激活动词。

## 入口

- 主窗口：勾选场景 →「应用」/「撤销」；窗口关闭即退出，不自设热键。
- `--copy-path "<路径>"`：菜单调用的静默分支，写剪贴板后立即退出，不建窗口。
- `--selftest [输出路径]`：无 GUI 分支，默认写 `右键复制路径\selftest-result.txt`。

## 写入位置

只写 HKCU，零提权；每个启用的场景写一个 `AHKDeckCopyFullPath` 子键：

- `HKCU\Software\Classes\*\shell\AHKDeckCopyFullPath`（文件）
- `HKCU\Software\Classes\Directory\Background\shell\AHKDeckCopyFullPath`（文件夹空白处）
- `HKCU\Software\Classes\Directory\shell\AHKDeckCopyFullPath`（文件夹）
- `HKCU\Software\Classes\Drive\shell\AHKDeckCopyFullPath`（驱动器）

每个子键下写 `MUIVerb = 复制完整路径` 与
`command\默认 = "<解释器>" [--run] "<脚本>" --copy-path "%1"`。
撤销时删掉这四个子键（先 `\command` 再父键）。写完广播
`SHChangeNotify(SHCNE_ASSOCCHANGED)`，一般免重启资源管理器即时生效。

- `--selftest` 的结果写 `scripts/右键复制路径/右键复制路径/selftest-result.txt`（同名文件夹，运行时自建，不进仓库）。
- 菜单被点击时写入**剪贴板**（覆盖原内容）。

## 风险与不做

- **会覆盖剪贴板**：这是本脚本的用途，点菜单前请留意原剪贴板内容。
- **菜单引用脚本自身路径**：移动/改名/删除脚本后菜单会断链；须重开窗口点「应用」刷新，或点「撤销」清除。
- 只写 HKCU，不动 HKLM、不改 `UserChoice`、不改文件关联、不写 `CommandFlags`、不碰 open/edit 激活动词。
- 不做按后缀名增删、按软件切换、任意命令编辑——那是被否决的通用菜单管理器形态。
- 不联网、不提权、不携带外部 exe。
