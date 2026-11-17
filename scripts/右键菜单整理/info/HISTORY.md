# 右键菜单整理 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.5.0（2026-11-18）

用户按 1.4.0 的实机体验提了 4 点。这一版的关键词是「别再骗人」：看不见的反馈、列了不存在的项、
只展开一个子菜单，都是界面跟事实对不上。

**1）点「上移/下移」根本没反应 —— 三个原因叠在一起。**
- **状态条被刷新盖掉**：`MoveVerb` 先写「已上移一位」，紧接着 `RefreshItems()` 把状态条改回
  「显示 N 项（verb…）」。用户看到的是统计数字，等于零反馈。现在 `RefreshItems(keepMsg)`
  支持保留操作结果，上移/下移后状态条写「「X」已上移一位，现在第 N 位 · 关掉再打开右键菜单即可看到」。
- **选中行可能滚出视口**：刷新后重新选中原来那一行，但没把它滚进来，长列表里看着像没动。
  补 `LVM_ENSUREVISIBLE`。
- **接管会把菜单搞坏**：1.4.0 把整根静态 verb 全复制成 `p000N#<verb>`，包含 `open`。
  shell 的内建显示名绑在键名上，副本认不出 `open`，菜单第一项直接变成字面的 `&p0001#open`
  （本轮真机复现，`--probe real` 抓到）。现在加闸门 `CanReplicate()`：**只有自带 MUIVerb/MuiVerb
  的 verb 才允许改名接管**；`open` / `cmd` / `Powershell` 这类显示名由 Windows 硬编码的项一律原地不动，
  点上下移会明确提示「是系统内建项……只能由系统固定位置」，而不是装作做成了。
- 「能不能调」也如实体现在反馈里：COM 扩展提示位置由 DLL 决定，二级项提示只读。

**2）删掉「位置」列。** 有了「顺序」列（1..N 真实位次），「默认/置顶/置底」既没有按钮可写、
也不再是用户关心的东西，纯噪音。四列改为「顺序 / 菜单项 / 来源 / 状态」，列宽
52 + 352 + 96 + 120 = 620 仍等于列表内宽，不出原生横条。

**3）二级菜单只展开了「包含到库中」。** 真因是插入循环里的 `break`：插完第一组子项就跳出，
后面「发送到」「新建」的子项全被吞掉。改成按累计偏移量逐组插入。现在拖入文件夹能看到
「包含到库中」7 项 + 「发送到」8 项都挂在各自父项下面。

**4）列出了菜单里根本不存在的项（Safe360Ext 等）。** 注册表里有 ≠ 菜单里显示——COM 扩展的 DLL
可以在 `QueryContextMenu` 里当场决定这次不出项。本机实测这几项都是这种：`Safe360Ext`（360）、
`加密`（EFS，非加密卷不出）、`Offline Files`、`工作文件夹`、`ModernSharing`。
1.5.0 直接用 `IShellFolder::GetUIObjectOf` + `IContextMenu::QueryContextMenu` 问 shell 要一次**真实菜单**，
拿它渲染出的文字当白名单；对不上的一律标成新状态 **「菜单外」**，默认被「隐藏不可见项」滤掉，
取消勾选仍能看到（不会悄悄消失）。真机验收：拖入 `.ex\右键菜单` 时，
Safe360Ext / 加密 / Offline Files / 工作文件夹 / ModernSharing 五项判为「菜单外」，
7-Zip / 授予访问权限 / 包含到库中 / 发送到 / 复制文件地址 / 还原以前的版本 / 上传至ima知识库 保留。
- 只有「拖入对象」场景有确定路径、能拿到真菜单；桌面/文件夹空白场景没有具体对象，跳过校验（宁可多列不误删）。
- 坑：`SHParseDisplayName` 只吃反斜杠路径，传 `E:/a/b` 直接回 `0x80070057`，表现成「拿不到菜单」；
  Map 没有 `.Length`，写成 `words.Length` 会抛异常被 catch 吞成「返回 0」。

**5）补了「恢复」按钮。** 顺序接管是写进 HKCU 的持久改动，1.4.0 的 `RestoreOrder()` 居然没有入口
（死代码），用户调乱了没有退路。现在五个按钮等宽同距：隐藏 / 上移 / 下移 / 恢复 / 刷新。

**仍然做不到、写进 README 的**：7-Zip、授予访问权限、上传至ima知识库 的子菜单由各自扩展在菜单
弹出时当场生成（7-Zip 的内容还依赖选中的文件名），`QueryContextMenu` 那一刻它们还不是 popup，
`IContextMenu2::HandleMenuMsg(WM_INITMENUPOPUP)` 也建不出来（本轮实测），所以拿不到子项列表。

**验收**：selftest 31 项全绿（新增接管闸门、真菜单文字归一化、白名单宽松匹配、菜单外档位）；
ui_static 10/10；八层 MCP 回归 ALL PASS（几何断言改成四列 + 5 等宽按钮 + 表头默认顺序↑）；
真实鼠标实测「管理员取得所有权限」上移/下移后副本编号变化、状态条给出「现在第 N 位」，
接管后 `--probe real` 确认菜单仍显示中文名且无重复项；测试写下的 HKCU 副本与标记已全部还原。

## 1.4.0（2026-11-18）

用户按 1.3.0 的实际使用提了 7 点，这一版把「顺序」这件事真正做实。

**1）二级内容不止「发送到」。** 1.3.0 只展开了 SendTo 文件夹，其实还有两处天然有数据源，一并接上：
- **新建**：扫 `HKCR\*\ShellNew`（本机 13 项）。显示名优先 `MenuText`（`@shell32.dll,-30313` 这类间接串走 SHLoadIndirectString），其次 `ItemName`，最后用 `SHGetFileInfoW + SHGFI_TYPENAME` 拿资源管理器「类型」列的同一份本地化名称（"TXT 文件 / 压缩(zipped)文件夹 / 快捷方式"）。**踩坑**：直接读注册表 ProgID 默认值会踩到软件写坏的 UTF-8，实测读回乱码「鏂囨湰鏂囦欢」；SHGetFileInfo 不需要文件真的存在，也不会拿到乱码。`ShellNewHandler` 是「从新建菜单里删掉」的反向标记，必须跳过。
- **包含到库中**：`%APPDATA%\Microsoft\Windows\Libraries\*.library-ms`，一个文件一项。
- 仍然列不出来的：7-Zip、授予访问权限、上传至 ima 的子菜单由各自 DLL 在 QueryContextMenu 里动态生成，注册表里没有任何子项数据。
- 二级项在「顺序」列留空（它们没有独立位置），缩进与圆点只出现在菜单项列，避免出现「·  · 文件夹」两粒点。

**2）上移/下移改成「逐位交换一位」。** 1.3.0 写的是 `Position=top|bottom`——那是**置顶/置底**，不是上移一步，用户指出的完全正确。现在上移只和上一项交换、下移只和下一项交换，到头了就不动。

**3）上移下移必须真的改到右键菜单。** 这是本版的核心。实测把 shell 的排序规则挖出来了：
- **shell 按 verb 键名的字母序排静态项，与显示名无关。** 证据：写 `0000zztestA / 0001zztestB / 0002zztestC` 三个 verb，显示名分别设 AAA / ZZZ / MMM，真实菜单出现顺序是 **AAA→ZZZ→MMM**——跟着键名走，不跟显示名走。
- `Position` 只有 `top` / `bottom` 两档，**没有「第 N 位」**，所以「移到中间某一位」在注册表里没有直接写法。
- 于是改成**顺序接管（副本）**：把该位置根下的静态 verb 全部复制成 `HKCU\Software\Classes\<根>\shell\p0001#<verb>` 形式的副本（前缀 `p` 排在 `open` 的 `o` 之后），原件的显示名与 command 都不动、只写 `ProgrammaticAccessOnly` 让位（另加 `_AhkDeckTakenOver` 区分「本脚本接管」与「用户自己要隐藏」）。改副本的编号即改真实菜单顺序，`p0001` 就是第一位。恢复 = 删副本 + 清两个标记。
- 实测验收：文件夹空白场景选中「在此处打开 Powershell 窗口」点「上移」，HKCU 下副本从 `p0002#Powershell / p0003#cmd` 变成 `p0002#cmd / p0003#Powershell`，列表顺序同步变化；再点「下移」换回来。
- **坑**：AHK 的 `RegDelete` 删不掉还带值或带子键的键（旧副本残留 → 新一轮按同号再建一份 → 菜单里出现重复项），必须调 `RegDeleteTreeW` + `RegDeleteKeyW`，且路径**不能带 `HKCU\` 前缀**（实测传了返回 2）；`RegEnumValueW` 的 LPCTSTR 参数要传 `Ptr 0`，否则永远枚举到 0 个值。

**4）四个按钮统一宽度。** BTN_W=72 / BTN_GAP=8，一律从列表左边起排（173/253/333/413），「隐藏」不再是自适应宽度。

**5）滑块重做，不再中间断开。** 1.3.x 是「轨道拆前后两段 + 中间 4px 细条」，重绘时中缝会露出一截底色，看起来像断成两截。改成**整条轨道 + 压在它上面的一整块滑块**：只有两个控件（`track` DCE8F7、`thumb` 6E9BD4），几何上永远嵌套，没有中缝可露。实机截图逐像素确认整条滑块连续。

**6）新增「顺序」列。** 列出该场景下每项的真实次序，从 1 连续编号（过滤掉的系统隐藏/Extended 项不占号，否则第一行就显示 4，像丢了东西）。

**7）表头可点击排序 + 箭头提示。** 五个表头都是可点色块，点一列按这列升序、同列再点一次反向，列名后跟 ↑ / ↓ 指明当前排序列与方向；默认按「顺序」升序（= 脚本推断的真实菜单次序）。二级项并回父项成组再排序，点表头时缩进的子项不会飞走；中文用 `StrCompare(..., "Logical")` 排。

**顺手加固**：加 `OnError` 把 GUI 事件层吞掉的异常落到 `右键菜单整理\error.log`——1.3.0 排查「按钮点了没反应」时就是被静默吞掉，白猜了半天。另外把「+0x200 = SS_NOTIFY」的错误注释改正（0x200 是 SS_CENTERIMAGE，实测三档样式位都能收到 Click）。

**验收**：selftest 28 项全绿（新增副本名可逆、副本名识别、去 & 标记、顺序列排序键补零、升/降序排组、中文排组、二级项缩进、类型名、位置/状态档位）；八层 MCP 回归 ALL PASS（几何断言改成五列 + 4 等宽按钮 + 表头默认带 ↑）；真实鼠标实测上移/下移改写注册表副本编号、滚动条连续、勾选框与按钮点击正常；测试写下的 HKCU 副本与标记已全部还原（`--probe restore` 三场景）。

## 1.3.0（2026-11-18）

用户按实际使用提了 7 点，交互与可读性做了一轮定型：

**按钮只留四件事**（用户定案）：「隐藏/显示」合成**一个切换按钮**（文案随选中项状态变）、「上移」「下移」（写 shell 的 Position=top/bottom 两档；已在同一档再点一次 = 取消回默认，因此不需要单独的「恢复位置」）、「刷新」。删除「置顶/置底/恢复位置」三个按钮。

**「隐藏不可见项」勾选框**（默认勾上）：只列真实右键菜单里会出现的项——本脚本没隐藏的、系统没打隐藏标记的、且不是 `Extended`（按住 Shift 才出现）。桌面场景 15 项 → 10 项，文件夹 31 项 → 20 项，数量级与真实菜单一致。

**「发送到」二级项缩进列出**：数据源是 `%APPDATA%\Microsoft\Windows\SendTo` 文件夹，一项一行缩进显示（只读，不可操作）。7-Zip / 包含到库中 / 授予访问权限的子菜单由各自 DLL 的 QueryContextMenu 动态生成，注册表里没有任何子项数据，列不出来——这是读取来源路线的边界。

**显示名与顺序对齐真实菜单**（用户："和实际右键的菜单还是差太多了，无法接受"）：
- ima 的 CLSID 默认值只有英文 `IMA Context Menu`，补友好名「上传至ima知识库」；
- 「打开」系内建动词（open / opennewwindow / opennewtab / explore / pintohome）提到最前，`open` 固定第一行；
- 同一功能的两代 CLSID（PintoStartScreen / StartMenuPin 都叫「固定到“开始”屏幕」）按显示名合并成一行，隐藏时逐个写 Blocked；
- 修复 `VerbLabel` 的兜底：第二个 `RegGet` 把默认值写成了 verb，导致 `open` 永远拿回 "open"、内建名兜底（打开/编辑/删除…）从未生效。
- **边界**：静态项已可按真实顺序排列，但 COM 项的先后由各 DLL 插入位决定、内建项（剪切/复制/粘贴/创建快捷方式/删除/重命名/属性）根本不在注册表，这两类对齐不了。实测文件夹场景：前 13 项与真实菜单顺序一致，多出的是 5 个「DLL 判定不显示」的扩展（加密 / Offline Files / Safe360Ext / 工作文件夹 / ModernSharing）与 opennewtab。

**两个藏得很深的 bug**：
- `gList.GetNext(0, "S")` 参数非法（AHK 的 ListView.GetNext 只认 "C"/"F"），异常被事件层吞掉 → 表现为"按钮点了没反应"。改用 `LVM_GETNEXTITEM(-1, LVNI_SELECTED)` 取选中行。
- 控件有两套顺序，混淆过一次：**绘制按 Z 序（后建在上）**、**宿主 RealChildWindowFromPoint 按创建顺序（先建先中）**。按钮 = 描边框 + 文字块，框必须先建（否则实心框把文字盖白）、两块都要挂 Click（命中按创建序先中框）。
- 过滤后 ListView 行号与 gItems 下标不再对应，补 `gRowMap` 行映射，否则选一行改的是另一行。
- 恢复操作后残留的空壳 shell 键会让 shell 多列一个空菜单项，`WriteVerbMarks` 现在顺手 `RegDelete` 掉（键非空时失败，正常）。

**验收**：selftest 18 项全绿；`ui_static 右键菜单整理` 10/10；七层 MCP 回归 ALL PASS（新增「隐藏不可见项」过滤断言、4 按钮几何断言）；实机截图确认按钮文字与勾号正常、列表渲染正确。

## 1.2.2（2026-11-18）

用户实测两个交互 bug，一起根治：

**点列表选不中**：列表区铺了一块 `BackgroundFFFFFF` 白底大块（1.1.0 引入，注释还写着"+0x100 让点击穿透"——方向写反了，`+0x100` 恰是 SS_NOTIFY、会**吃**点击）。实测 AHK 控件 Z 序与创建序相反，后建的 ListView 反在白底块之下，整个列表区的鼠标点击全被它吃掉（MCP send_input 实测 target=Static、selected_count=0；PostMessage 直达 ListView 则 selected=1，证明列表逻辑无辜）。先试 `-0x100` 去 SS_NOTIFY，但宿主 `RealChildWindowFromPoint` 不探测 HTTRANSPARENT 仍命中它；真实鼠标的穿透规则又依赖 Z 序兄弟关系，不可靠。**根治=直接删除白底大块**：它几何上被表头块+ListView 完全覆盖（ListView 自带白底），删除后点击命中 ListView 本身，实机两行选中皆 OK。列表四条边线与表头背景块同步 `-0x100`。

**拖入后列表整块发白**（滚一下滚轮才恢复）：拖入路径 Delete/Add 之后 ListView 没有同步重画，要等 LVM_SCROLL 才画。修复：RefreshItems 末尾 `RedrawWindow(gList, RDW_INVALIDATE|RDW_ALLCHILDREN|RDW_UPDATENOW)` 强制同步走 WM_PAINT；同步重画会盖掉 Z 序在下的自绘滑块，紧接 `gScroll.Paint()` 补画。白底大块的绘制遮挡同时随删除根治。

**验收**：selftest 16 项全绿；六层回归 ALL PASS；实机 MCP：点行 target=SysListView32、selected_count=1、滚轮后滑块在位、刷新后列表正常渲染。

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
