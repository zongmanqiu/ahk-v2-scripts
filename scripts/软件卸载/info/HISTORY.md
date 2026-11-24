# 软件卸载 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.0.22（2026-11-24）

**真正根因：原生滚动条画在非客户区，`InvalidateRect` 永远擦不到——改用 `WM_NCCALCSIZE` 子类根治**

- 用户找了五位外部师傅会诊，根因结论一致，也判明我 1.0.17–1.0.21 五轮**方向全错**：
  - 原生滚动条是 ListView **非客户区（NC）** 的一部分。`ShowScrollBar(FALSE)` 只摘样式位、不擦已画进
    NC 的灰像素；`InvalidateRect(lv, NULL, FALSE)` 的 `NULL` 只作废**客户区**，NC 那 17px 永远碰不到。
  - comctl32 每次重算滚动范围（Move/Add/Delete/ModifyCol/LVM_ENSUREVISIBLE/滚轮）都把 `WS_VSCROLL`
    置回并重画 NC 灰条——「出现后再藏再擦」永远差一拍，这就是十版补刀断不干净的根因。
  - 我前几轮全在**客户区**里折腾（Flush 提交方式、FRAMECHANGED、trackBg 底衬），客户区本来就没问题；
    而且 `trackBg` 画在 ListView 右侧**外**（x645–655），原生条在 ListView 右缘**内侧**，两块根本不重叠，
    底衬盖不到原生条。师傅4 点破了这一点。
- 根治（师傅3 方案，Win32 标准技法「hide scrollbar but keep scrolling」）：给 ListView 挂 `WM_NCCALCSIZE`
  子类 `LvNcCalcSize`——非客户区空间计算到达时临时摘掉 `WS_VSCROLL|WS_HSCROLL`（0x00300000）再走默认
  计算、算完恢复。原生条从此分不到一寸 NC 空间、一个像素都画不出来；comctl32 之后爱怎么置回样式位都
  无所谓。滚动功能不受影响（滚动位置走 `SetScrollInfo`，与滚动条视觉是两套机制，`LVM_ENSUREVISIBLE` 照常）。
- 落点：① 全局 `gLvNcProc`；② 顶层函数 `LvNcCalcSize`；③ `BuildGui` 里双缓冲之后、第一次 Layout 之前
  `SetWindowSubclass` 挂上；④ `OnGuiClose` 里 `RemoveWindowSubclass` 摘除（K21：回调须全程有效）。
- 旧的 `HideNative/Repair/QueueRepair/trackBg` 体系原样保留作保险丝——从此没有像素可擦，最多空转。
- 验证：宿主 MCP `run_script` rc=0 无内核报错、滚轮正常；门禁新增 `test_nc_subclass` 断言子类函数/安装/
  摘除齐全，全绿。
- 待实机确认：原生条既已「物理画不出」，右缘任何一帧都不该再有 `F0F0F0`/`#808080`。请实机快速滚动、
  拖滑块、键盘翻页、切模式、改列宽、搜索过滤逐一验。

## 1.0.21（2026-11-24）

**真正的元凶：滚动条槽底下是 gLvWhite 纯白——补一条静止浅蓝底衬 trackBg（K33 正解①）**

- 用户实机：v1.0.20 仍有旧滚动条残留，且**滑块背后冒出白色块**。
- 反思：1.0.17–1.0.20 四轮全错方向（提交方式、FRAMECHANGED），因为「白色块」这个新线索才指向真因——
  软件卸载滚动条槽底下铺的是 `gLvWhite`（line 1998，`BackgroundFFFFFF` 纯白）。
- 机制：滑块 `thumbV` 移到新位、轨道段还没补上的那一瞬，新位底下露的就是这块**纯白**；白与深蓝滑块、
  浅蓝轨道对比极强 → 你看到的「滑块背后白块」与「旧滚动条」。`ui_pixel` 实测稳态滚动条列全浅蓝/深蓝
  （缝 `DCE8F7`、滑块 `6E9BD4`、滑块下方 `DCE8F7`），证实白块是中间帧露出的 gLvWhite。
- 为什么打开方式清理没有：它**没有** gLvWhite 白底衬，槽底下是窗口米色 `B7C8E0`，和轨道浅蓝接近，
  露出来不显眼。软件卸载独有的纯白底衬才是把中间帧放大成「白块」的原因。
- 修法（K33 正解①，前几轮只做了②）：新增一条**静止**的浅蓝底衬 `trackBg`，`BackgroundDCE8F7`，
  在 `__New` 里**先于 vUp 创建**（靠创建顺序天然压在色块下层），`Layout` 里 `exV` 时 `Move` 铺满整条槽
  （含滑块位）。色块都在它上面，滑块怎么移，露出的永远是这条静止浅蓝，不再露白。
- 实测（宿主 MCP）：运行 rc=0 无报错；`inspect_ui` 确认 trackBg 控件 x645 y73 w10 h242 铺满整条槽；
  滑块中心 `(1272,446)`=`6E9BD4` 深蓝（trackBg 在滑块之下、没反过来盖住滑块）；滑块旧路径 `(1272,415)`=`DCE8F7`。
- 新门禁 `test_track_underlay`：断言 trackBg 用浅蓝创建、先于 vUp、Layout 铺满并显示。
  **红证已做**：把 trackBg 挪到 vUp 之后（z 序放反）→ 门禁 `rc=1` 判红；恢复 md5 一致。
- 待实机确认：拖影/白块是中间帧，工具复现不了。请实机快速滚动看右缘。trackBg 静止铺满整条槽后，
  中间帧露出的应是浅蓝而非白——若白块消失、拖影仍在，则残留另有来源，下一步逐字 diff ScrollToRow/Paint。

## 1.0.20（2026-11-24）

**拖影元凶定位到软件卸载独有的 `HideNative`（FRAMECHANGED+CoverNative），撤掉对齐无残留参照**

- 用户实机：v1.0.19 仍有滚动条残留，并质问「为什么《打开方式清理》没有」。
- 反思：1.0.17/18/19 三轮都在改 `Flush` 提交方式，但《打开方式清理》用纯 `Defer`、连补擦都没有
  却不残留——若根因真是色块中间帧，参照同样该有。说明真正差异在软件卸载**独有**的代码。
- 逐字对比两脚本滚动路径，唯一有效差异在 `HideNative`：
  - 参照：`ShowScrollBar(竖,0)` + `ShowScrollBar(横,0)` 两行，灰条靠 `ScrollToRow` 里的
    `InvalidateRect(lv,NULL,FALSE)+UpdateWindow(lv)` 整块重绘盖掉。
  - 本脚本：多出 `SetWindowPos(...,0x0037)`（SWP_FRAMECHANGED）+ `CoverNative()`。
- 定性：① `CoverNative` 在本窗口 ListView 上是**空操作**——`inspect_ui` 实测 lv `style=0x5001400D`
  无 `WS_BORDER`、`exstyle=0`，故 `GetClientRect==GetWindowRect`，`cw>=ww` 直接 return，一个像素没刷。
  ② `SWP_FRAMECHANGED` 每次滚动都强制 ListView 重算非客户区、重新评估滚动条，反而让原生条闪现。
  这两处是 1.0.14/1.0.16 为治灰条加的，却被门禁 `test_native_cover`/`test_sync_repair` 钉成「必须」，
  导致后续迭代不敢动、久拖未解。
- 修法：`HideNative` 撤掉 `FRAMECHANGED` 与 `CoverNative`，对齐参照（纯 `ShowScrollBar`×2）；删除
  `CoverNative` 方法。灰条改由 `ScrollToRow`/`Sync`/`Repair` 已有的 `UpdateWindow(lv)` 整块重绘盖。
- 门禁：`test_native_cover` 重写为断言 `HideNative` **不含** `0x0037`/`FRAMECHANGED`/`CoverNative()`、
  且 `CoverNative` 方法整体删除；`test_sync_repair` 去掉对 `FRAMECHANGED` 的强制。
  **红证已做**：把 `FRAMECHANGED` 加回 `HideNative` → 门禁 `rc=1` 判红；恢复 md5 一致。
- 实测（宿主 MCP）：运行无内核报错（rc=0）；滚轮后采滚动条列 `(1270,430)`、`(1270,510)` 均浅蓝
  `DCE8F7`、无 `F0F0F0`——撤掉 FRAMECHANGED 后稳态没冒出原生灰条。
- 待实机确认：拖影是中间帧、工具复现不了。请实机快速滚动看右缘是否还有残影。若这次参照对齐仍不消，
  说明差异在 `HideNative` 之外，下一步逐字 diff `ScrollToRow`/`Paint`/lv 创建找剩余偏离。

## 1.0.19（2026-11-24）

**拖影根因深化到「重画时机不受控」：原子提交后逐块 UpdateWindow 同步重画**

- 用户实机：v1.0.18 白块消失，但滚动条拖影仍在。
- 重连宿主 MCP 实测：滚轮后采旧滑块位（screen 1272,415）= 浅蓝 `DCE8F7`、过滤到 39 项后采滑块
  下缘（1272,461）= 深蓝 `6E9BD4`——**稳态无残留**，证实拖影是滚动那一瞬的中间帧。
- 根因：1.0.18 的 `Flush` 在 Defer 原子定位后只 `InvalidateRect(...,1)` 标记重画，没强制同步。
  色块移走后腾出的旧滑块位显示的是屏幕上原来的深蓝像素，重画要等宿主空闲的 `WM_PAINT`；
  连续滚动时主线程忙、`WM_PAINT` 挤不进来（同 K36「长任务期间定时器挤不进来」），旧深蓝停在屏上。
  用户直觉的「代码顺序」即此：重画落到 `WM_PAINT` 队列后顺序不受控。
- 修法：每块 `InvalidateRect` 后紧跟 `UpdateWindow`，强制按 `ops` 顺序同步重画——`ops` 是
  vUp/vDn 浅蓝轨道在前、thumbV 深蓝滑块最后，于是旧滑块位先被浅蓝轨道盖掉、滑块再画到新位，
  不留深蓝残影。回退分支同样补 `UpdateWindow`。
- 验证：① 实机白块不回归（滑块加高下缘实测深蓝 `6E9BD4`）；② 门禁 `test_flush_atomic_regen`
  升级，断言 Defer 分支 `return` 前同时含 `InvalidateRect` 与 `UpdateWindow`；**红证已做**
  （临时删 UpdateWindow 回到 1.0.18 形态 → 门禁 `rc=1` 判红；恢复 md5 一致）。
- 待实机确认：拖影是中间帧、工具复现不了，请实机快速滚动看右缘是否还有暗色残影。
  若仍在，下一步转 K33 正解①——整条轨道铺一条不移动的浅蓝底衬，滑块深蓝叠其上，移动路径像素
  永远归属静止底衬，从根上消除「旧深蓝像素停留」。

## 1.0.18（2026-11-24）

**1.0.17 原子提交治了拖影却复发白块；补回逐块重绘，二者兼得**

- 用户实机：v1.0.17 滚动条拖影没消，滑块还冒出**白色色块**——这是 1.0.12 早已修过的老 bug。
- 失误定性：1.0.17 把逐个 `SetWindowPos` 换成 `DeferWindowPos` 原子提交时，连带删掉了每块
  `InvalidateRect(...,1)`。而那一步正是 1.0.12 治白块的修法——`SWP_SHOWWINDOW` 不保证重绘滑块
  加高后的新增区，下缘露白底。诊断对了一半（逐个提交确有中间帧拖影），却把防白块的机制拆了。
- 修法：`Flush` 在 `EndDeferWindowPos` 原子定位**成功后、`return` 之前**补回逐块
  `InvalidateRect(...,1)`。位置已原子到位（无「滑块移走、轨道没补」的中间帧），再补颜色重绘
  （无露白）。批量真失败仍回退逐个 + 逐块重绘。
- 新门禁 `test_flush_atomic_regen`：断言 `Flush` 的 Defer 成功分支 `return` 之前必须有
  `InvalidateRect`。**红证已做**：把真源临时改回 1.0.17 形态（删该补重绘）跑门禁 → `rc=1` 判红；
  恢复后 md5 一致。这条专门拦「下次重构又把防白块那行删掉」。
- 仍未实机确认：白块是稳态现象、本可 `ui_pixel` 测，但本轮宿主 MCP 断开，未能实测；拖影是中间帧、
  工具本也复现不了。请实机跑 v1.0.18：① 滑块加高（搜 `Microsoft` 等过滤到行数少）下缘是否还白；
  ② 快速滚动是否还有拖影。若白块已消而拖影仍在，转 K33 正解①（滑块下方铺同色底衬）再补。

## 1.0.17（2026-11-24）

**滚动条拖影根因定位到 `Flush` 逐个提交，改回 `DeferWindowPos` 原子提交**

- 用户实机：滚动时滚动条旧位置留下擦除残影（截图右缘中部一道暗块），迭代十几个版本未解。
- 取证：宿主 `capture_ui`（PrintWindow）滚动前后各截一帧，滑块旧位置都显示为轨道浅蓝
  `DCE8F7`、无暗色——说明 PrintWindow 让控件自绘、**把中间帧残影盖掉了**，截图不可作残留证据。
  改用 `ui_pixel` 真实屏幕单点取色：滑块新位置 `6E9BD4`、旧位置 `DCE8F7`，稳态正确，
  坐实残留是**滚动过程中的中间帧拖影**，不是稳态错色。
- 根因：逐字 diff 三个同族脚本的 `FlatScroll`。《硬件信息》《打开方式清理》的 `ScrollToRow`
  与本脚本几乎一致，唯一关键差异在 `Flush()`：参照用 `BeginDeferWindowPos`/`DeferWindowPos`/
  `EndDeferWindowPos` **一次性原子提交**全部色块；本脚本 1.0.11 起退化成**逐个 `SetWindowPos`
  + 每块 `InvalidateRect(...,1)`**。逐个提交时滑块先移走、轨道段后补上，中间那一帧旧像素归属
  窗口背景、宿主不重绘——正是 UI踩坑 K33 描述的「外框已到、内块还在旧位」拖影。
  当初退化成逐个是为绕开「列表刚 Move 完 Defer 整批失败返回 NULL → 切页后滚动条不出现」。
- 修法：`Flush` 优先 `DeferWindowPos` 原子提交，**仅当批量真失败才回退逐个**（回退分支保留
  原逐块 `InvalidateRect` 兜新增区露白）。原子提交消除中间帧，回退兜住老回归。
- 验证（宿主 MCP，session 实测）：① `run_script` 起来无内核报错；② 滚轮后 5 块色块几何正确、
  滑块与轨道同帧到位；③ 搜索框输入 `Microsoft` 触发过滤重填（列表刚 Move 完）后滚动条 5 块
  仍全部 `visible=true`——老回归未破。`python scripts/软件卸载/test/run.py` ALL PASS。
- 待实机确认：中间帧拖影只有人眼在真机连续滚动时能最终判定，工具无法稳定复现中间帧。
  请实机快速滚动列表，看右缘滚动条旧位置是否还有暗色拖影。

## 1.0.16（2026-11-24）

**1.0.15 的遮罩方案把列表裁成空白，撤销；改成直接刷非客户区**

- 用户实机：状态条已是 `v1.0.15`，但**列表内容一片空白**。宿主 MCP `capture_ui`
  （PrintWindow，不受遮挡）复现：表头、状态条、自绘轨道都在，行区全白。
- 根因：1.0.15 给 ListView 加了 `WS_CLIPSIBLINGS`，目的是让列表绘制被上层遮罩裁掉。
  但本窗口里还有其他全尺寸的兄弟窗口，`WS_CLIPSIBLINGS` 把**整个客户区都裁掉了**——
  列表一个像素都不画。去掉该样式后列表立刻恢复（同环境 capture_ui 对照确认）。
- 教训：**列表不能加 `WS_CLIPSIBLINGS`**；「用兄弟色块盖住列表」这条路在本窗口不可行
  （z 序默认压不住，加了裁切样式又会把整表裁空）。1.0.15 的遮罩块、`NativeScrollW()`、
  列宽让位（状态 122→104）全部撤销，列宽回到 122。
- 新修法 `FlatScroll.CoverNative()`：原生条占的是窗口**非客户区**，客户区重画
  （`InvalidateRect`）永远碰不到它；`ShowScrollBar(FALSE)` 又只摘样式位、不擦像素。
  所以直接 `GetWindowDC` + `FillRect`，把「客户区之外的右条/底条」刷成列表白
  （矩形由 `GetClientRect` 与 `GetWindowRect` 之差算出，没有条时两矩形相等、直接返回）。
  挂在 `HideNative()` 末尾——所有摘条点（Layout / ScrollToRow / Repair / Sync / FixCols）
  自动覆盖；不依赖 z 序、不依赖重绘时机。
- 保留 1.0.15 的有效部分：`SW_SHOWNA(8)`、状态条版本号、1.0.14 的 FRAMECHANGED 与
  `QueueRepair`。

**验收**：宿主 `capture_ui` 截图列表有行（136 项）、右缘无灰条；`test/run.py` 断言
`HideNative` 必须调 `CoverNative`、源码不许再出现 `+0x04000000`；`ui_static` 10/10。

## 1.0.15（2026-11-24）

**右缘加原生条遮罩：从「事后擦」改成「物理盖住」，并抓到了 z 序这个真凶**

1.0.14 之后用户仍报「滚动时依然有旧滚动条」。本轮改为在宿主里取证（截图 + 逐像素 +
PrintWindow），定位到两点：

- **真凶一：AHK 建的 ListView 在 z 序上比后建的 Text 更靠顶**。实测子窗口 z 序
  （`GetWindow(parent, GW_CHILD)` 往回走）最上面永远是列表，`SW_SHOW` 与
  `SW_SHOWNA` 都一样。所以任何「用兄弟色块盖住列表边缘」的写法默认都是盖不住的；
  `SetWindowPos(块, HWND_TOP)` 实测有效（复查 z 序已翻转），必须在 Layout 里显式抬。
- **真凶二：擦像素这条路本身不可靠**。样式位采样全程 `0x0`（原生条从不常驻），
  但最大化/复原、连续滚轮那一拍 comctl32 仍会把灰条画进非客户区；`InvalidateRect`
  整块重画之后仍可能被下一拍重新画上。实测：最大化后静置 `灰=15`、滚 8 格 `灰=47`。

- **真凶三：列表没有 `WS_CLIPSIBLINGS`，z 序再高也压不住**。`GetWindowLong(-16)` 实测
  AHK 建的列表样式是 `0x5001400D`，没有 `0x04000000`。Windows 的规则：子窗口不声明
  `WS_CLIPSIBLINGS` 时**不按 z 序裁兄弟窗口**，自己该怎么画就怎么画——所以遮罩即使
  被抬到 `HWND_TOP`，原生条仍会画在遮罩上面（这就是 UI踩坑 K20「SetWindowPos 抬到
  HWND_TOP 也压不住」的真正机理）。给列表补 `+0x04000000` 之后，绘制才被上层遮罩裁掉。

修法（只加一个控件 + 一个样式位，不改任何已有配方）：

- `FlatScroll` 新增 `this.shield`：白底 `Text`、`-0x100`（去掉 `SS_NOTIFY` → 点击穿透
  到列表）、宽 = `NativeScrollW()`（`GetSystemMetrics(SM_CXVSCROLL)+1`，100% 下 18px）。
  `Paint()` 里摆在 `bx - sw`（正好盖住列表右缘的原生条区）；`Layout()` 收尾
  `SetWindowPos(shield, HWND_TOP)` 把它抬到列表之上。
- `ColWidths()` 末列让出同样宽度（状态 122→122−sw），内容不会被遮罩裁掉；
  列宽和 = 列表宽 − sw。
- ListView 创建样式补 `+0x04000000`（`WS_CLIPSIBLINGS`），让列表的绘制被上层遮罩裁掉。
- `RefreshList` 的显示改 `SW_SHOWNA(8)`（不激活、无副作用；z 序仍靠上面那步显式抬）。
- 状态条补版本号（`ScriptVersion()` 读自身 `@version`）：用户一眼能确认宿主里跑的
  是哪一版，避免「改了还复现」其实是旧进程。

**实测**：宿主 `--run`，窗口置顶，最大化 + 连续滚轮 + 复原 + 滚到中间再过滤：
右缘 4 个采样列在四个状态下**全部为 0 灰**（修前：最大化静置 15、滚 8 格 47、复原 227）；
`PrintWindow` 抓列表整幅，右缘是一条 18px 白条、无任何灰阶。z 序复查：遮罩在列表之上。

**门禁**：`test/run.py` 新增遮罩断言（建/摆/让宽/置顶）；`ui_static.py 软件卸载` 10/10。

## 1.0.14（2026-11-24）

**旧滚动条残迹：查清「为什么只有我们有」，按 K36 把填表路径改对，并堵死两条旁路**

用户要求横向读 docs 与其它列表脚本后再动手。逐行比对 `打开方式清理` / `右键菜单整理` /
`硬件信息` / `文件解锁` 四份 `class FlatScroll` 与各自填表路径，结论如下。

- **滚动配方四份脚本其实是同款**（`LVM_ENSUREVISIBLE` 或 `LVM_SCROLL` → `HideNative`
  → 整块 `InvalidateRect(NULL,FALSE)`+`UpdateWindow`），所以差异不在「怎么滚」，而在
  「滚之前谁把原生条点亮了、点亮之后谁负责擦像素」。本脚本有三处漏点：
  1. **填表路径不藏表**（1.0.13 及以前刻意不 `SW_HIDE`，注释还写「那套是冒灰条的根因」）。
     `Add()` 到超出页高时 comctl32 会当场把 17px 原生条画进非客户区；`WM_SETREDRAW`
     压不住非客户区（UI规范 L274），`ShowScrollBar(FALSE)` 只摘样式位、不擦像素。
     我们随后只做了 `Layout`+`FixCols`，而 `FixCols` 里的 `gList.Redraw()` 走的是 AHK
     的 `GuiControl.Redraw`——它作废的是**父窗口**在该控件矩形上的区域（`script_gui.cpp`
     `GuiControlType::Redraw`），本窗口还带 `WS_CLIPCHILDREN(+0x02000000)`，被剪掉，
     等于什么都没擦。灰条因此留到下一次整表重绘。**《打开方式清理》FillList 把摘条放在
     `SETREDRAW 1`/`SW_SHOW` 之前**，所以它从不会在填表期画出灰条；它的填表也是过滤
     每次按键都跑——和我们完全一样的调用频率，差别只在顺序与藏表。
  2. **两条旁路没人擦**：① ↑/↓ 由 ListView 自己滚（本脚本 `OnKey` 只接管 PgUp/PgDn/
     Home/End），② 点击行时 comctl32 为露出选中行自己滚一下。这两种滚动不经过
     `ScrollToRow`，`Sync` 的 `EnsureHidden()` 只摘样式位不擦像素，灰条会一直留到下次
     整表重绘——1.0.13 的探针日志里 `AFTER_HIDE px=F0F0F0` 与 `SYNC paint px=F0F0F0`
     就是这两个时刻。
  3. **擦的那一下本身被裁掉了 17px**（本轮实测才发现）：`ShowScrollBar(FALSE)` 之后
     comctl32 缓存的客户区矩形还没更新，紧跟的 `InvalidateRect(NULL)`+`UpdateWindow`
     仍按旧矩形画，灰条正好在新客户区、旧矩形之外，等于没擦。所以即使走的是标准
     `ScrollToRow`，连续滚轮时也会整列挂着灰条——这是「配方和别人一样却只有我们明显」的
     直接原因（本脚本过滤每按键重填 + 三条滚动通路，暴露面最大）。
- 修法（四处，均不改版式、不加控件）：
  1. `RefreshList` 改成 K36 原文顺序：`SW_HIDE` → `WM_SETREDRAW 0` → Delete/Add →
     `HideNative` → `WM_SETREDRAW 1` → `SW_SHOW` → 补焦点（K39）→ `Layout`/`FixCols`。
     1.0.13 的注释把失败归咎于「SW_SHOW 会画灰条」，实际是当年前后顺序反了：摘条必须在
     恢复重绘与显示**之前**。
  2. **`HideNative` 补 `SetWindowPos(..., SWP_FRAMECHANGED)`（0x0037）**——这是本轮的
     关键定位：摘样式位只改非客户区，comctl32 缓存的客户区矩形要等下一次 `WM_NCCALCSIZE`
     才更新；中间那一拍整块重画仍按旧矩形裁，**17px 灰条正好落在「新客户区、旧矩形之外」，
     擦不到**。强制重算客户区后，灰条随即被整块重画画成白色。
  3. 新增 `FlatScroll.Repair()`：`HideNative` + `InvalidateRect(NULL,FALSE)` +
     `UpdateWindow` + 首行号变了就对齐滑块。`Sync()` 一旦发现 `EnsureHidden()` 真的摘到
     了被置回的样式位（说明列表在本脚本滚动通路之外动过），当场 `Repair` 擦像素。
  4. `OnBarWheel`/`OnBarKey`/`OnBarDown` 各挂一次 `QueueRepair()`（一次性
     `SetTimer(-1)`）：OnMessage 回调跑在 ListView 处理之前，用负周期定时器等它滚完再擦。
- **实测（独立解释器，48 点整列扫描 GetPixel）**：
  - 修前：启动填表后 0 灰；**连续 20 格滚轮有 9 格整列灰（46/48 点 F0F0F0，约 350ms 持续）**；
    方向键 0；过滤 0。→ 用户看到的「滚动时旧的滚动条」就是这个。
  - 修后：启动填表 0；滚轮 20 格 **0**（原 372 个灰样本）；方向键整列只在按键后 1ms 内
    出现一次单帧（5 点）后即消失；过滤 3 字 + 清空 0。
- 没动的：`ScrollToRow` 保持 1.0.13 的 ENSUREVISIBLE 配方（`S2R_DONE` 恒白，说明收尾本来
  就擦得净，漏的是「旧矩形裁掉 17px」）；`Layout()` 的收尾 `Repaint`+`Paint` 保持；
  未采用「17px 遮罩块」方案——那会吃掉状态列/选中高亮右缘 17px，本修法在四条通路都擦得到。

**门禁**：`python scripts/软件卸载/test/run.py` 全绿（第 8 项断言由「不许藏表」翻成
「必须藏表且摘条在 SETREDRAW 1/SW_SHOW 之前」）；`ui_static.py 软件卸载` 10/10。

## 1.0.13（2026-11-24）

**滚动时旧滚动条残迹：换《打开方式清理》1.5.x 配方（用户截图实锤）**

- 用户截图：滚动时列表右缘中部留一截灰色原生滑块。LVM_SCROLL 前后双压拦不住滚动那一拍——
  `SendMessage(LVM_SCROLL)` 时 comctl32 把 `WS_VSCROLL` 置回并当场画条，摘除只清样式位不擦
  像素。《硬件信息》列表行少几乎不滚动所以从不触发；《打开方式清理》1.5.x 当年已踩过同坑
  （其 HISTORY K29/K34/K50）并给出成熟配方。
- 修法：`ScrollToRow` 整体改抄《打开方式清理》1.5.x 原文——`LVM_ENSUREVISIBLE(0x1013)`
  滚动（向下滚 ENSURE 视区末行、向上滚 ENSURE 目标行，摘样式位后仍精确到位）→ 当场
  `HideNative()` → `InvalidateRect(NULL, FALSE)` + `UpdateWindow` 整块重画消位块拷贝残影。
- 像素复测（独立运行，连续 5 格滚轮 + 0.4s 后采样轨道竖列 dx=27..19）：整列只有
  DCE8F7 轨道 / 6E9BD4 滑块，**无白色夹层、无灰阶原生条**；1.0.12 的 Flush InvalidateRect
  保留（白带不复发）。

**门禁**：回归全绿；`ui_static.py 软件卸载` 10/10。

## 1.0.12（2026-11-24）

**滚动条白色色块：像素实锤定位 + 修复**

- 方法：独立运行脚本（脱离宿主），用 `GetClientRect+ClientToScreen` 把客户区坐标换算成屏幕
  坐标，滚动 5 格后逐像素采样自绘轨道竖列（`GetPixel`，步长 3px）。
- 实测（1.0.11）：轨道 DCE8F7 正常、滑块 6E9BD4 正常，但**滑块下缘紧贴一条 6-9px 的白色带
  （FFFFFF），夹在滑块与下段轨道之间**——用户报的「滚动条白色」就是它。
- 根因：`Flush()` 里 `SetWindowPos` 改变 Text 块尺寸后，**新增区域不保证重画背景**
  （WM_CTLCOLORSTATIC 只覆盖 WM_PAINT 已有区域）。滑块加高/移动后，块内多出的区域露出
  白底垫块 gLvWhite。《硬件信息》等列表行少、滑块不触发 Min(24) 下限，几乎不出现，本脚本
  135 行滚动频繁必现。
- 修法：`Flush()` 对每个 on 块在 `SetWindowPos` 之后补一条 `InvalidateRect(hwnd, NULL, 1)`
  强制整块重画。修复后复测：滑块 102-123 连续、轨道 126 起连续，**轨道列无任何白色**。
- 说明：这是对《硬件信息》原文 FlatScroll 的唯一一处修改（1 行），原因与证据如上；类内
  其余仍与原文逐字一致。

**门禁**：回归全绿；`ui_static.py 软件卸载` 10/10。

## 1.0.11（2026-11-24）

滚动条问题久拖不决，用户拍板：**整类照抄《硬件信息》v2.3.4 的 FlatScroll，不再手工缝补**。

- 做法：`class FlatScroll` + `HookBarInput` + `OnBarDown/OnBarWheel/OnBarKey` 整段替换为
  《硬件信息》原文（含注释），类内不再有任何本脚本自己的变体——1.0.9 的 RDW_FRAME、
  1.0.10 的 vTrack 轨道垫块与 LVM_ENSUREVISIBLE 配方全部撤掉，回到 LVM_SCROLL 前后双压 +
  Repaint 0x0101 的原始配方。差异仅两处：
  ① `OnBarWheel` 滚动后收掉悬停提示（本脚本 1.0.6 新增的列表悬停功能需要），并补
  《硬件信息》原有的 `hwnd = gGui.Hwnd ||` 分支（窗口空白处滚轮不动）；
  ② `OnBarKey` 不带 Ctrl+C 复制（本脚本无复制功能分支）。
- 同一宿主里《硬件信息》滚动从无白块/残迹/闪条，逐字复制后任何残余差异即为环境或
  调用侧问题，不再改类。

**门禁**：`python scripts/软件卸载/test/run.py` 全绿；`ui_static.py 软件卸载` 10/10。

## 1.0.10（2026-11-24）

用户实测 1.0.9 报三条：标题栏拖不动、垂直滚动条上有白色色块、滚动时仍闪过旧条（附截图）。

**① 标题栏拖不动（1.0.9 翻车修正）**
- 1.0.9 把系统菜单项删光只留「退出」——Windows 拖动标题栏走的正是 **SC_MOVE(0xF010)**
  链路，菜单里没有它窗口就拖不动（实测）。
- 修法：菜单补回两条——「移动」（SC_MOVE=0xF010）+「退出」（SC_CLOSE=0xF060）。
  Min/Max/Close 按钮不受菜单内容影响，照常显示。

**② 垂直滚动条上的白色色块（截图实证）**
- 根因：轨道各段（vUp/vDn/缝/滑块）逐块 `SetWindowPos` 挪位，挪动间隙里垫在轨道列底下的
  **白底块 gLvWhite（FFFFFF）露出来**，视觉就是滑块槽上的白色色块/滚动时闪白。
- 修法：`__New` 里最先创建整长轨道垫块 `vTrack`（DCE8F7，贯穿整列，z 序在轨道各段之下），
  `Paint()` 在 exV 时先铺满整列（bx, y, t, lvH）、否则随其它段一起隐藏。任何瞬间露出的
  都是轨道色，不再露白。

**③ 滚动时闪过旧滚动条（根因换成实锤配方）**
- 旧配方（LVM_SCROLL 前后双压）`SendMessage(LVM_SCROLL)` 那一拍 comctl32 会把 `WS_VSCROLL`
  置回并当场把原生灰条画出来，摘除只清样式位不擦像素——闪现不可避免。
- 修法：`ScrollToRow` 整体改抄《打开方式清理》1.5.x 的成熟配方——`LVM_ENSUREVISIBLE(0x1013)`
  （向下滚 ENSURE 视区末行、向上滚 ENSURE 目标行）→ 当场 `HideNative()` →
  `InvalidateRect(NULL, FALSE)` + `UpdateWindow` 整块重画消位块拷贝残影。摘样式位后
  ENSURE 仍精确到位。

**门禁**：`python scripts/软件卸载/test/run.py` 全绿；`ui_static.py 软件卸载` 10/10。

## 1.0.9（2026-11-24）

用户截图实证 1.0.8 两个残留问题，都是上一轮修错了方向：

**① 标题栏按钮恢复（1.0.8 翻车修正）**
- 1.0.8 用 `SetWindowLongW` 清 `WS_SYSMENU(0x00080000)` 只去系统菜单——实测把 Min/Max/Close
  三个按钮一起干掉了：**按钮本来就挂在 WS_SYSMENU 上，无法只清菜单保按钮**。
- 正确做法：保留 `WS_SYSMENU`，`GetSystemMenu` 拿菜单句柄，`DeleteMenu`（MF_BYPOSITION）
  删光英文项，`AppendMenuW` 补一条中文「退出」（ID 用 `SC_CLOSE=0xF060`，点击仍走关闭链路
  → OnGuiClose → ExitApp）。右键标题栏/Alt+Space 只弹「退出」，按钮照常显示。

**② 滚动条残迹（用户截图：滚动后条位置留灰色小块）**
- 根因：原生条在**非客户区**。`LVM_SCROLL` 会把 `WS_VSCROLL` 样式位置回、comctl32 当场把条
  画出来；随后 `ShowScrollBar(FALSE)` 只摘样式位、**不擦非客户区像素**。收尾的 `Repaint` 用
  `RedrawWindow(0x0101)`——不带 `RDW_FRAME(0x400)` 的重绘永远碰不到非客户区，残迹留下。
- 修法：`Repaint` 改 `0x401 = RDW_INVALIDATE | RDW_FRAME`。带 FRAME 走 `WM_NCPAINT` 重画
  非客户区，样式位已摘、什么都不画，残迹消失；**不带 ERASE**（K44 教训：ERASE 每次滚轮
  先擦父底色再画，闪白）。

**门禁**：`python scripts/软件卸载/test/run.py` 全绿；`ui_static.py 软件卸载` 10/10。

## 1.0.8（2026-11-24）

用户复跑又报两条 BUG：「右键为什么还是一堆英文菜单」和「顶部关闭/最小化/最大化按钮全没了」。都是 1.0.7 里引入的。另外两条（滑块白色、滚动条左侧旧滚动条）FlatScroll 类代码与文件解锁逐行一致、白底块也铺了，待用户确认是宿主特有还是独立运行也复现。

**① SysMenu 与按钮分离（我引入的 Bug）**
- 1.0.7 在 Gui() 参数里加了 `-SysMenu`，本意是干掉标题栏右键弹的英文系统菜单。但 Windows 里 `WS_SYSMENU(0x00080000)` 这个样式位**同时掌管**「系统菜单（右键标题栏/Alt+Space/左上角图标）」和「Min/Max/Close 三个按钮」，不是分开的——AHK 的 `-SysMenu` 一把梭全部干掉。
- 修法：Gui() 参数还原成 `+Resize +0x02000000`。`Show` 之后用 `SetWindowLongW(GWL_STYLE, style & ~0x00080000)` 只清 WS_SYSMENU 这一位，然后 `SetWindowPos` + `SWP_FRAMECHANGED(0x0027)` 让 Windows 重算非客户区，Min/Max/Close 三个按钮位（0x00020000/0x00040000/0x00C00000）独立保留。

**② 关于滑块白色 / 滚动条左侧旧滚动条**
- FlatScroll 类 __New/Put/Flush/Paint/Measure/ScrollToRow/Layout、白底块 gLvWhite 的创建和 Layout 几何——全部与文件解锁（v1.3.2）逐行一致。白底块先建、FlatScroll 后建（z 序最顶），原生条槽区域 10px 完全在白底块覆盖范围内。
- 像素探针（独立运行 AutoHotkey64.exe）因 RunWait 非阻塞 AHK Gui 无法拿到窗口而中断，暂未有像素实锤。等用户确认：这两个 BUG 是在**宿主 AHKDeck 内运行**时看到、还是**独立 AutoHotkey64.exe 运行**也复现。独立运行不复现 = 宿主环境差异（DWM 34/35/36 属性、manifest、parent 窗口）需要单独查；独立运行也复现 = FlatScroll 某处漏了与成熟脚本的真正差异。

**门禁**：`python scripts/软件卸载/test/run.py` 十一项 ALL PASS。`ui_static.py 软件卸载` 10/10，出货件逐字节一致。

## 1.0.7（2026-11-24）

用户复跑后报两条：「滚动条 BUG 依然有」和「右键菜单太复杂还都是英文」。两条都是 1.0.6 里遗漏的。

**① 滚动条 BUG：缺白底块 gLvWhite（根因）**
- 1.0.6 的 BuildGui 里自作聪明写了一段注释：「ListView 自带白底，不需要额外白底块」，删掉了
  文件解锁/硬件信息同款的 `gLvWhite` 白底块。这是错的——ListView 的白色只覆盖**列表内容区**，
  ShowScrollBar(FALSE) 摘掉原生条样式位后，右边 10px 竖槽那块**原生条原来的地盘** ListView
  不再负责重绘，露出来的就是窗口底色 B7C8E0（浅米色），跟列表白不一致——这就是滚一下就冒
  出来的那道竖条。成熟脚本都靠这块白底块盖在最底层兜底。
- 修法：补回 `gLvWhite`，并加 `SetWindowPos(HWND_BOTTOM, flag=0x0007)` 强制压到底层（不依赖
  AHK Gui 对不同控件类型的隐式 z 序处理）。BuildGui 里同步加 `global gLvWhite`——AHK v2
  函数内对未声明 global 的变量赋值会自动创建 local，global 永远是 0，Layout 里 `gLvWhite.Move`
  抛空对象异常，整个 BuildGui 在 `SetTimer(StartupScan)` 之前崩掉，列表永远 0 行。这次
  加了 global 后 Warning 也消了、列表正常填表。
- 新增门禁：`test_white_underlay()` 断言 BuildGui 有 `gLvWhite := gGui.Add("Text"...`、
  Layout 有 `gLvWhite.Move`、失效数组包含 gLvWhite。

**② 右键系统菜单（SysMenu）简化**
- AHK Gui 默认给系统菜单——左上角图标右键/标题栏空白处右键都弹，全英文 Restore/Move/Size/
  Minimize/Maximize/Close。用户只需要「关闭」。修法：`Gui()` 参数加 `-SysMenu` 一次性干掉
  所有入口；右上角 X 关闭按钮保留，OnGuiClose 直接 ExitApp。

**③ 提权**
- 给用户说明现状后等决策：宿主 AHKDeck.exe 无 requireAdministrator manifest，脚本继承宿主
  权限（普通用户）。普通用户**可以读** HKLM（所以扫得到 135 行），但**不能删** HKLM 注册
  表键或 Program Files 下的文件。卸载器自己（unins.exe）遇到需要提权的 HKLM 项会走 Windows
  的 ShellExecute runas 链路，脚本已经在 Job Object 等待 + 注册表键消失兜底里考虑了这种
  stub 提前退出、提权子进程后启动的场景（GRACE_EXIT_MS=60s 就是给这个）。真正受影响的是
  **清理残留阶段脚本自己删 HKLM 键/文件**，状态条已经提示「未提权，HKLM 项清理会失败」。
- 三个候选方案：A 宿主改 manifest 为 requireAdministrator（改宿主，冻结期不可）；B 脚本
  自己 `Run *RunAs` 提权重启（脱离宿主 MCP 托管，独立进程）；C 卸载器本身的 stub 自提权
  链路已经覆盖了卸载环节，真正需要时再做 C——卸载器删 HKLM 键/文件时 ShellExecute runas
  拉起提权实例，Job 等待 + 注册表消失兜底。

**门禁**：`python scripts/软件卸载/test/run.py` 十一项 ALL PASS（新增第 9 层 `[9/10] 白底块`；
填表 135 行）。`ui_static.py 软件卸载` 10/10，出货件与仓库件逐字节一致。

## 1.0.6（2026-11-24）

用户复核四条，全部落地。前三条都是「其它成熟脚本没有、这个脚本却犯」的回归，根因都是
自作聪明多做了动作；第四条是补功能。

**① 安装时间去掉「约」前缀**
- 1.0.5 给推算值加 `~` 区分精确/推算，用户不要这个记号。删掉 `SortKey` 的前缀剥离，
  四档取值口径不变，显示统一 `YYYY-MM-DD`。
- `test_installed_dates` 反向加严：第 4 列每行非空，且不得以 `~` 开头。

**② 滚动时又冒出旧滚动条（第二次）**
- 根因不在 `FixCols` 顺序，而在 `RefreshList` 还留着「SW_HIDE → WM_SETREDRAW 0 → 填 →
  SETREDRAW 1 → SW_SHOW → 抢焦点」这套 K36 老配方：`SETREDRAW(1)` 与 `SW_SHOW` 会让
  comctl32 连非客户区一起重算并当场把 16px 原生灰条画到屏上；之后 `ShowScrollBar(FALSE)`
  只摘样式位、擦不掉已经画上的像素。
- 修法：与《文件解锁》逐字对齐——只留 `Delete()` → `Add()` → `gScroll.Layout()` →
  `FixCols()`，全在同一个消息处理里完成，不等重绘就没有中间帧；`SW_HIDE` / `WM_SETREDRAW` /
  `Focus()` 全删。

**③ 搜索过滤框的色块**
- 根因：AHK 的 `Text` 背景块与它的内容控件是兄弟窗口，背景块 z 序更靠上（实测
  `GetWindow(GW_HWNDPREV)`：先建的框 `prev=0`）。正常重绘时内容后画所以看得见；但 `Layout()`
  单独 `InvalidateRect(gSearchFrame, 1)`，只重画背景块、不重画 Edit，整块 128×28 就被
  `B7C8E0` 盖死（真屏 `GetPixel` 实测：期望白框的位置取到 `0x00E0C8B7`）。
- 修法：失效数组改成「背景块 → 它的内容控件」相邻成对（`gSearchFrame` 紧接 `gSearch`，
  `gBand` 紧跟五个列头），`Layout` 注释写死「背景块绝不能单独失效」；外框补 `-0x100` 去掉
  `SS_NOTIFY`，输入区域不再被静态控件抢命中。

**④ 列宽固定后看全内容：悬停浮出完整文本**
- 列宽按令牌固定（版本 78 / 发行者 128 / 安装时间 112 / 状态 122），长文本被省略号截掉。
  新增 `HookListHover()`：`WM_MOUSEMOVE`(0x200) → `LVM_SUBITEMHITTEST`(0x1039) 定格子 →
  `LVM_GETCOLUMNWIDTH`(0x101D) 取列宽 → `CellTip()` 用 `MeasureTextWidth` 实量，只有
  「文本宽 > 列宽 − 12」才 `ToolTip(原文)`；换格才重设，`WM_MOUSELEAVE`(0x2A3)、滚轮滚动、
  重新填表时收掉。
- ★坑：`LVM_SUBITEMHITTEST` 的**返回值是 0 基行号，不是列号**（MSDN 文案有歧义）。本机实测
  点 (306,11) 落在第 1 行发行者列时返回 0、`iSubItem=2`。列号必须从 `LVHITTESTINFO.iSubItem`
  （offset 16）取；`iItem` 在 offset 12，offset 8 是 `flags`。旧写法按「返回值=列号、
  offset 8=iItem」解析，取到 flags 与错行，提示永远指错格。返回类型还必须用 `"Int"`，
  用 `"Ptr"` 接 `-1` 会变成无符号大数。

**门禁**：`--selftest` 56 项 fails=0（`SortKey 去前缀` 那项换成 `CellTip 只有超宽才给提示`）；
`test/run.py` 新增 `[4b]` 安装时间无前缀、`[7/9]` 填表不藏表/不冻结重绘、`[8/9]` 失效顺序、
`[8b]` 悬停命中解析，连同原有几何/填表/原生条/列头/停止共十一项 ALL PASS（填表 135 行）。
进程内探针实证悬停链路：`sub=0`、`iSubItem=2`、`colW=128`、`measure=142` → `CellTip` 返回
`VALINET Solutions SRL`。


## 1.0.5（2026-11-24）

用户复核后指出两条「其它成熟脚本都没有」的毛病：安装时间大量缺失、滚动时出现旧的滚动条。
本轮不新造做法，把《打开方式清理》1.5.x 的现成配方按原样搬到位。

**安装时间缺失**
- 根因：只读 `InstallDate`，本机 136 条可卸载项里 78 条根本没写这个值。
- 修法：四档取值——`InstallDate` → 卸载登记键最后写入时间（`RegQueryInfoKeyW` 的
  `lpftLastWriteTime`，本机 136/136 都有）→ 安装目录创建时间 → 卸载器 exe 创建时间。
  FILETIME 先 `FileTimeToLocalFileTime` 再取年月日（否则东八区凌晨装的会差一天）。
- 后三档是推算值，显示加 `~` 前缀（安装时间列变成 `~2026-11-07`）；排序键去掉前缀，
  仍按日期本体排。实测 135 行全部有值：精确 58 行、推算 77 行。

**滚动时旧的滚动条**
- 根因：`FixCols()` 里 `ModifyCol` 会把 `WS_VSCROLL` 置回，comctl32 接着连非客户区一起把
  16px 原生灰条画出来；旧顺序是「先 `Redraw()` 后 `HideNative()`」——灰条已经画到屏幕上，
  再摘样式位擦不掉像素，那一条就一直留在列表右侧。
- 修法：照《打开方式清理》1.5.2 的顺序，`ModifyCol` → **先 `HideNative()` → `Paint()`
  重画滑块 → 最后 `Redraw()`**，全部在回到消息循环前完成。
- 同时把三处「自以为更好」的偏差改回成熟配方：`Measure()` 的可视行数回到
  `Floor(lvH/itemH)`（`LVM_GETCOUNTPERPAGE` 会把露半截的末行算进来，滚到底时首行号越过
  `maxTop`，滑块/列表/轨道对不上）；`ScrollToRow` 在 `target = top` 时直接返回不重画；
  `Layout()` 去掉多余的那次 `Repaint()`。

**门禁**：`--selftest` 56 项 fails=0（新增 `RegKeyDate`/`PathDate`/`FormatInstallDate`/
`SortKey` 去前缀四项）；`test/run.py` 加「安装时间逐行非空」与「FixCols 先摘条再重绘」
两条断言，八层 ALL PASS。


## 1.0.4（2026-11-24）

用户复核 1.0.3 后指出「还有很多不足，要更严格参考现成脚本，尤其排序符号现成脚本已有，别自己造」。
本轮对照 右键菜单整理（表头排序范本）/ 打开方式清理 收口。

**排序符号改用现成约定（不自造）**
- 1.0.3 我自造了列头 `▲/▼`。右键菜单整理 的现成约定是「列名 + 两空格 + ↑/↓」
  （`h.title "  " (gSortAsc ? "↑" : "↓")`）。`UpdateHeaderArrows` 改用 ↑/↓，与现成脚本一致。

**白底大块吃掉列表/列头点击（真 bug，右键菜单整理 1.2.2 同款血泪）**
- 现象：`gLvWhite`（x17 y47 w638 h268 的 BackgroundFFFFFF 大块）盖在列表与表头区上，
  实测点列表行 `selected_count=0`（选不中行 → 没法选中卸载）。
- 修复：照 右键菜单整理 的做法**删掉盖在列表上的白底大块**——ListView 自带 BackgroundFFFFFF，
  表头带用 gBand、竖条槽用滚动条静态块，整块内空已被覆盖，无需垫块。删后实测点行 `selected_count=1`
  （行高亮选中），搜索无结果显示空白列表无白缝。
- 装饰块（四条 1px 线 + gBand）一律加 `-0x100` 去 SS_NOTIFY，与 右键菜单整理 一致，杜绝拦截。

**实机验收**：滚轮内容真滚、滚动条 BAND 轨道连续无白遮挡无原生条、行可选中、搜索过滤、
信息行「显示 N 项」、`--selftest` fails=0、`ui_static` 10/10、`test/run.py` 六层 ALL PASS。

**说明**：列头排序点击沿用 右键菜单整理 同构（band -0x100 在后、列头 OnEvent 在前、AHK 正常 z 序
列头在最上层），真实鼠标可点；send_input 命中是「子控件列表序第一个匹配」启发式，会把点击投给排在
列头前的 gBand，故仍无法用它验列头点击——属测试工具局限，非产品缺陷。

## 1.0.3（2026-11-24）

用户报「UI 严重缺陷，滚动条有旧条复现 + 白色遮挡；要搜索过滤、要安装时间列、列表要升降序」，
并指出应严格参考其它成熟脚本。本轮整体对标 `打开方式清理`（唯一同时具备收口滚动条 +
搜索框 + 列排序的范本）落地四项。MCP 实机 `capture_ui` 验收 + `--selftest` 门禁。

**滚动条收口（根治旧条复现 + 白色遮挡）**
- 根因：本脚本 `class FlatScroll` 抄自《文件解锁》精简版，不是《打开方式清理》收口版。
  ① `Flush` 逐块 `SetWindowPos`，滚动/拖动时轨道与滑块分帧挪 → 中间帧漏白底（"白色遮挡"，K24）；
  ② `ScrollToRow` 走 `LVM_SCROLL`，但 `HideNative` 的 `ShowScrollBar(FALSE)` 摘掉 `WS_VSCROLL`
  后滚动范围塌成 0、内容根本不滚（滑块却随 0x1027 幻影走，"旧滚动条"症状的根源，K29/K30）。
- 修复（移植 打开方式清理 收口配方）：
  - `Flush` 改 `BeginDeferWindowPos`/`DeferWindowPos`/`EndDeferWindowPos` 一次批量提交，
    失败（列表刚 Move 那拍整批 NULL）退化逐块兜底；
  - `ScrollToRow` 改 `LVM_ENSUREVISIBLE`：向下滚 `ENSURE(target+viewRows-1)`（视区末行）、
    向上滚 `ENSURE(target)`，避免直接顶目标行的滚过头/下沿露白；滚后 `HideNative` +
    `InvalidateRect(NULL,FALSE)` + `UpdateWindow` 整块重画消除位块拷贝残影（K34/K43/K50）。
- 实机验收：滚轮/翻页内容真滚、`WS_VSCROLL` 位清、四→五列对齐、滚到底末行贴底无露白。
- 注：1.0.2 那版只换了 ScrollToRow 一个方法、未整体收口，故仍有旧条/白遮挡；本轮补全。

**搜索过滤框**
- 顶部新增搜索行（y12 h28，标签 + 弹性 Edit，§10.3.3 输入行），`OnEvent("Change")` 防抖 250ms。
- 安装模式按 名称/发行者/版本 子串过滤，残留模式按 路径/说明 过滤；信息行追加「显示 N 项」。
- 实机验收：输入 "nvidia" 列表只剩 NVIDIA 条目。

**安装时间列 + 列升降序**
- `ScanInstalled` 读注册表 `InstallDate`（"YYYYMMDD"）经 `FormatInstallDate` 转 "YYYY-MM-DD"，
  新增第 4 列「安装时间」（字典序即时间序）；列表 4→5 列（名称/版本/发行者/安装时间/状态），
  残留模式第 5 列宽 0。窗口客户区 672×352 → 672×386。
- 列头可点：同列切升/降序、异列设该列升序，列头文字后加 ▲/▼ 指示；`FilterSortRows` 纯函数
  做过滤+排序（大小写不敏感），`BuildView` 取源数据→gView→重填。
- selftest 新增 7 条 `FilterSortRows` 用例（过滤命中/大小写不敏感/名称升降序/安装时间升序/空结果），
  全 PASS、fails=0。列头点击沿用 打开方式清理 同款 OnEvent（inspect 确认列头 style 含 SS_NOTIFY、
  列头文字可见=真实 z 序在最上层，真实鼠标可点）；send_input 的命中是「列表序第一个匹配」启发式，
  会把点击投给排在列头前的 gBand，故无法用它验列头点击——属测试工具局限，非产品缺陷。

**同步**：@version/HISTORY/README 表格/scripts.json 四处对齐 1.0.3；test/run.py 几何断言改
672×386 + 五列 + 列宽和 424；出货 `.build\Scripts`。

## 1.0.2（2026-11-24）

用户报「UI 重大缺陷，滚动条有 bug」。对照 `docs\UI规范.md`/`UI踩坑.md`/`UI组件手册.md`
与收口范本 `打开方式清理`，实机定位并修复滚动条。

**滚动条不滚内容（高，实机确证）**
- 现象：滚轮 / 点轨道翻页 / 拖动后，自绘滑块随位置走，但列表内容停在首行不动
  （PrintWindow 实测：滚 30 行后首行仍是 ExplorerPatcher，滑块却下移）。
- 根因：本脚本的 `class FlatScroll` 抄自《文件解锁》旧配方，`ScrollToRow` 走
  `LVM_SCROLL(0x1014)` 像素增量。但 `HideNative` 用 `ShowScrollBar(FALSE)` 会摘掉
  `WS_VSCROLL`，摘掉后 ListView 滚动范围塌成 0，`LVM_SCROLL` 对内容无效（K29/K30）；
  而 `ReadTop` 读的 `0x1027` 是幻影偏移，滑块据此移动造成「滑块动、内容不动」。
- 修复：`ScrollToRow` 改用《打开方式清理》1.5.x 收口配方——
  ① 滚动走 `LVM_ENSUREVISIBLE(0x1013)`（摘样式位后仍精确到位）；
  ② 向下滚 `ENSURE(target+viewRows-1)`（视区末行）、向上滚 `ENSURE(target)`，
     避免直接顶目标行的「滚过头、下沿露白」（K43）；
  ③ 滚后 `HideNative` + `InvalidateRect(NULL,FALSE)` + `UpdateWindow` 整块重画，
     消除位块拷贝的半截字 / 列错位残影（K34/K50）。
- 实机验证：滚轮向下 30 行 → 内容真滚到第 29 行起、四列（名称/版本/发行者/状态）
  全部对齐无错位；滚到底末行贴底无露白；向上滚走 ENSURE(target) 分支同样正确。
- 注：`文件解锁` / `硬件信息` 仍是旧 `LVM_SCROLL` 配方（列表较短或未触发），本轮按
  第 12 条只动本脚本，未越界改它们；记入待办。

**未实测项（无法在不真卸载的前提下进入残留视图）**：残留模式（勾选框列）渲染、
窗口缩放/最大化的 K47 重排——本轮未触发，留待实机。

## 1.0.1（2026-11-24）

外部专家四轮评估（`.build\ai\1.txt`~`4.txt` + 终局状态表）收口。本轮只改本脚本，
MCP `--selftest` 45 项全 PASS、fails=0，语法门禁通过；控制流改动属交互路径，待实机验证。

**必修（确定性缺陷）**
- **F1（4.txt 投产前唯一必修，高）**：`TickUninstall` gone 分支判定 `active != 1`
  把「Job 内还有 2+ 个清理子进程」(active=2/3) 和「三态未知」(-2) 都当成完成证据，
  键先删就误进残留扫描。收窄为 `active <= 0`——仅无进程时收工，多进程/未知继续等待。
- **N6（1.txt 发版前必修）**：`CheckRuntime()` 提到所有分支前后，32 位跑
  `--selftest/--report` 会弹 MsgBox 卡死无桌面环境，且 `ExitApp(0)` 让 CI 看到
  「rc=0 + 无结果文件」假通过。改为 `CheckRuntime(guiMode, resultPath)`：无 GUI 分支
  先算好路径，32 位下写 FAIL + `ExitApp(1)`，不弹框；GUI 分支保留弹框。入口各分支分别守卫。
- **M1 / N5 死门（2.txt/3.txt）**：残留扫描里 tails 收集阈值 `>=3`，而 N5 的 2 字符
  共现门要求 `InArray(tails, n)`——2 字符名永远进不了 tails，QQ/微信这类应用的注册表
  残留恒扫不到（注释承诺的「尾段共现即放行」从未发生，是唯一「防护逻辑互相抵消」实锤）。
  tails 阈值降为 `>=2`；门改为「纯 ASCII 2 字符（qq/ai/wp）需尾段共现、2 字中文名直接放行」，
  顶层强名分支与发行者嵌套分支两处同口径。

**体验层小修**
- **N7**：`active=0 && !gone` 时「卸载器已退出，等待条目消失」被末尾「卸载中 · N 秒」覆盖，
  末尾更新加条件 `active != 0`。
- **N9**：gone 路径确认框点「否」后状态条停在旧文案，补 `gStatus := "已取消"`。
- **L2**：gone 路径（程序仍装）扫不到残留时误报「已卸载」，按 `aStillInstalled`
  分支改「未执行卸载 / 已卸载」。
- **N8 / F5**：`kind=upd` 确认框不展示实际命令，补 `命令：<展开串>` 并明说
  「运行后可能只是启动更新器、并不会真正卸载」。
- **F4 / L1**：`RecycleErrText` 错误码按官方 DE_* 表校正——`0x79` 是 DE_PATHTOODEEP
  （旧误写「目标访问被拒」）、`0x7E` 是 DE_FLDDESTISFILE「目标是已存在的文件」（旧方向反）、
  `0x10004`（ERRORONDEST + ERROR_TOO_MANY_OPEN_FILES）从「路径不存在」单列拆出。

**记录在案未改（需产品决策或实机验证，按既定 v1.x 节奏）**
- M2（2.txt 中）：gone 路径 `others` 按 keyPath 排除自身，仍安装应用的本体目录可能被列为
  可清理残留——属「卸载器缺失≠已卸载」的语义边界，改动影响 gone 路径可用性，留待实机复核。
- Q13/Q14/Q28 完成证据链（退出码 / MsiEnumProducts / 占用检查）、Q11/Q12 Squirrel/NSIS
  参数、Q16 超时三选一、Q9 单点展开、Q23/Q24 hNameMappings、Q8/Q20 路径标准化、
  F2/F3 归属方向与 QuietUnsafe 取舍、F6 selftest junction 清理方式——均为架构级或
  待本机验证项，未触碰。
- 入口局部变量改用 `selftestPath/reportPath`，消除与 `SplitCommand` 局部 `sp` 的同名告警。

## 1.0.0（2026-11-23）

首个版本：扫描安装清单 → 静默卸载 → 残留扫描 → 回收站/备份式清理。全程 MCP 实机
闭环验收，不改宿主。首版实现后经历两轮整改（用户实测反馈一轮、外部审查一轮）。

**功能**
- 三处 Uninstall 键扫描（HKLM / Wow6432Node / HKCU），过滤 SystemComponent /
  ParentKeyName；静默卸载决策链（quiet 校验 → MSI → 家族判定带归属证据 → 原样）；
  Job Object + 键消失双宽限等待（含无 Job 的 ProcessExist 兜底）；uproot 式残留
  扫描（黑名单双分支 + 交叉引用 + 发行者嵌套 + >2GB 不勾 + reparse 直删）；
  清理 = 回收站 + reg export 先备份（TEMP 回退）。
- 强制 64 位运行（A_PtrSize 守卫）；未提权时状态条与确认框明示 HKLM 清理会失败。

**返工（2026-11-23，用户实测反馈「错误太多、滚动条有问题、顺序与文档不达」）**
- **K36 原生灰条**：136 行启动填表时 comctl32 把 WS_VSCROLL 置回并当场刷出原生条
  （竖条挤窄客户区 → 列宽溢出 → 横条跟冒，「空列表+两条原生灰条」）。RefreshList
  改走组件手册 FillList 配方：列表 SW_HIDE → WM_SETREDRAW 0 → 填 → 摘原生条 →
  WM_SETREDRAW 1 → SW_SHOW → 补焦点（K39）→ 重算占位。
- **启动冻结**：首扫 ~10s 原来在 BuildGui 里同步跑，窗口画完就冻住。改为延迟单次
  定时器（SetTimer(StartupScan, -120)），先画首帧再扫（K38：长任务期间定时器不来，
  同步块里不碰 UI）。
- **代码顺序**（UI规范 §10.8 固定顺序）：重排为 全局变量 → class FlatScroll →
  脚本侧滚动接管 → 工具函数 → GUI → 无 GUI 分支 → BuildGui() 调用。
- **列头对齐**（§10.3.3）：旧版列头固定 x327/409/541，与列起点脱节且随竖条显隐
  错位 4~14px；改为「列头文字块 x = 列表左缘 + 列起点 + CELL_PAD(6)」，列宽和
  精确等于可视宽（去掉 4px 死区），竖条显隐时与列内容保持对齐；AlignHeaders
  从 gScroll.ClientW() 取同一宽度真源。
- **文案**（§10.6 状态条不写指令句）：去掉「先在列表中选中…」「勾选后点…」
  「可继续操作卸载器窗口」类指引，只留事实。
- **FixCols 后补摘原生条**（K34：ModifyCol 会把样式位置回）。

**二轮返工（2026-11-24，外部审查三份 + 问题清单 CSV，共 30 项合并去重后修复 14 项）**

来源：`.build\ai\`（1.txt 优先级清单 / 2.txt 逻辑漏洞 / 3.txt 30 项深度审查 + CSV）。
按共识严重度修复：

| # | 修复 | 依据 |
|---|---|---|
| F1 | Run 启动失败抛 OSError（不是 pid=0）：try/catch 捕获并写状态条——原来点「确定卸载」没反应、错误只在 error.log | 1.txt#1 |
| F2 | 卸载等待状态机三态化：Job 可用走 ActiveProcesses；Job 挂载失败（UAC 竞态/已在别的 Job）用 ProcessExist(pid) 兜底；active=0 且键未消失不再立即收工（改 6 秒宽限，与键消失宽限对称）——否则提权卸载场景监控过早结束 | 1.txt#2 / 2.txt#1 / 3.txt Q28 |
| F3 | QuietUninstallString 不再无条件信任：SplitCommand+FileExist 校验 + QuietUnsafe 拦网页/未知宿主（http/https/www/.htm）；校验失败回落常规链而非直接 gone | 1.txt#3 / 3.txt Q3 |
| F4 | WindowsInstaller=1 时不再从子键名兜底取 GUID（可能是升级码/补丁 GUID，/X 会卸错产品）——落回常规链原样运行 | 3.txt Q5 |
| F5 | Squirrel 判定加归属证据：update.exe 必须位于应用自己的 InstallLocation 内（SquirrelOwned），否则回落原样运行——防止同名误伤 | 3.txt Q10 |
| F6 | TryRemoveEmptyParent 改非递归 DirDelete（检查与删除之间被写入时天然失败），不再与「绝不悄悄永久删除」承诺冲突 | 1.txt#10 / 3.txt Q29 |
| F7 | RecyclePath 区分 GetFileAttributesW INVALID 的错误码：只有 2/3（不存在）算「卸载器已删」，长路径/权限等如实报失败——杜绝误报成功关闭重试入口 | 1.txt#10 / 3.txt Q30 |
| F8 | reparse point 清理改 DeleteReparseOnly（目录链接 RemoveDirectoryW / 文件链接 DeleteFileW，\\?\ 前缀），不再交 SHFileOperationW（junction 契约不稳定） | 1.txt#11 |
| F9 | StrongNames 阈值 3/4 → 2/3：微信/QQ/钉钉等 2 字符应用此前残留一个都扫不到 | 1.txt#5 |
| F10 | 「安装目录本身」分支收紧为强名必配（删除 BackslashCount>=2 的 OR）——否则 Common Files / System32 级共享目录可能整棵进回收站 | 2.txt#4 |
| F11 | 泛用名黑名单补注册表分支（原来只有文件夹分支有）+ 补中文泛用词（数据/缓存/日志/公共/程序/软件/工具/下载） | 2.txt#3 / 3.txt Q19 |
| F12 | CleanLeftovers 把未勾选项的 checked 同步回 false——否则刷新列表恢复勾选，二次点击误清理已取消项 | 1.txt#12 |
| F13 | location 只 Trim 引号空格、尾部反斜杠单独 RTrim（Trim 字符集含反斜杠会把 C:\ 变成 C:）；嵌套 Loop 的外层路径先落局部变量（A_LoopFilePath 被内层覆盖的脆弱点） | 1.txt#8/#9 |
| F14 | 非 MSI 按 UninstallString 原文去重（部分安装器两视图各写一条）；备份目录 TEMP 回退；-1 与 >2GB 文案分离；自动切残留视图仅在用户仍处安装视图时发生 | 1.txt#6/#17/#18 / 3.txt Q27 |

**明确不做**（3.txt 建议但本轮裁决）：MSI API 反查产品码（Q1/Q14，DllCall 改造大，v1.1）；
NSIS `_?=` 退出码（Q12，需真机验证与空格路径兼容性）；两阶段命令解析器重写
（Q6/Q7 深层部分）；Q4 /I 语义三选项。

**坑（二轮新增）**：「卸载中」状态文案带指令句的问题在首轮整改时漏改——本轮
TickUninstall 重写时才顺带修掉。教训：整改要全文 grep 状态文案，不要只改点到的行。

**坑**
- `A_AppDataLocal` 与 `A_PID` 都不是 AHK v2 内建（validate 的 #Warn 警告实抓）：
  本地 AppData 走 `EnvGet("LocalAppData")`，进程 ID 走
  `DllCall("kernel32\GetCurrentProcessId")`——与《文件解锁》的先例一致。
- **`A_LoopFileAttrib` 是属性字符串（"RAH"）不是位掩码**：残留扫描首版
  `A_LoopFileAttrib & 0x400` 抛 `Expected a Number but got a String`，定时器线程
  死亡、状态条永远停在「正在扫描残留…」——MCP 实机闭环 + error.log 调用链
  一击定位（纯静态门禁与 selftest 都抓不到，只有真数据才走到那一行）。修法：
  判目录 `InStr(att,"D")`、判 reparse `InStr(att,"L")`。
- BuildGui 里漏 `global gApps` 声明会把扫描结果写进局部变量，列表永远是空的
  （#Warn LocalSameAsGlobal 实抓，靠 MCP get_session_output 的 warnings 定位）。
- `AutoHotkey64.exe`（m191 进程外内核）CLI 启动后父进程立刻 rc=0，脚本在子进程跑：
  CLI 验证 `--selftest` 必须轮询等待结果文件，不能读 rc 就下结论。
- 首次启动扫描比 --report 慢（约 10s vs 125ms）：推测为杀软对 FileOpen 逐个卸载器
  的首扫开销，第二次起走缓存。窗口期间状态条如实显示「正在扫描…」，1.0.0 接受。

**三轮返工（2026-11-24，外部复测四份 + 复测对照表：基线 30 条逐条核对 + 新增 N1–N8）**

复测判定：首轮修复 6 项已修 / 11 项部分修 / 12 项未动；新增 N1–N8，其中 N1 为上轮漏报。
本轮修复（对照表「一」级 + 新增确定缺陷）：

| # | 修复 | 来源 |
|---|---|---|
| R1 | **A1 硬 bug：WM_SETREDRAW 常量写成 0x100B（LVM_SETCALLBACKMASK）**——K36 配方其实没生效，症状被 SW_HIDE 兜住。两处改回 0x000B | 2.txt A1 |
| R2 | **Q15 短路修复**：gone 分支不再跳过进程三态——键消失满宽限且进程侧给出完成证据（active=0 或三态未知）才收工；进程仍活着就继续等并提示「键已消失，检测到后台仍在活动」 | 4.txt Q15 |
| R3 | **A2/N9：进程退出但键仍在的宽限 4s → 60s**——未提权卸 HKLM 时 stub 退出后提权子进程才刚开始，4 秒会把刚启动的真卸载误报成失败；状态条同步「卸载器已退出，等待条目消失（可能后台收尾）…」 | 2.txt A2 / 4.txt N9 |
| R4 | **A3：MSI 门控收紧**——仅当串含 msiexec 或 WindowsInstaller=1 才提取，且 GUID 必须紧跟 /I 或 /X（路径里的 {GUID} 不再误判）；selftest 补回归 | 2.txt A3 |
| R5 | **N1：相对 exe 名按安装目录解析成绝对路径**（quiet 与常规链两处）——"Update.exe" --uninstall 不再在脚本目录/PATH 里找错程序；quiet 命中时重写为绝对路径命令 | 4.txt N1 |
| R6 | **Q3：Quiet 裸命令宿主白名单**（msiexec/rundll32/cmd/powershell/wscript/cscript/regsvr32）——白名单外的裸名降级 raw；QuietUnsafe 改扫整条命令（参数里的 URL 也拦）；确认框展示展开后命令 | 4.txt Q3 |
| R7 | **N6：gone 路径不再把仍安装应用的卸载键列为残留**——CollectLeftovers 加 aStillInstalled 参数，程序还在时自身键不进残留列表（防止删出「幽灵安装」） | 4.txt N6 |
| R8 | **N4：DeleteReparseOnly 同类复发修复**——INVALID 改 GetLastError 2/3 判定；移除无效的 SetFileAttributesW（REPARSE 属性本就不能用它清） | 4.txt N4 |
| R9 | **N2：非 MSI 去重键改 UninstallString+名称**——共用卸载器的两个不同应用不再被误合并（交叉引用排除不再丢 location） | 4.txt N2 |
| R10 | **N5：2 字符强名注册表匹配加尾段共现守卫**（qq/ai/wp 类短键必须同时命中安装目录尾段） | 4.txt N5 |
| R11 | **1.txt N1：otherNames 阈值 4→3 与 StrongNames 同步**——3 字符目录名（如另一应用的 Git）在对方未登记 location 时不再误匹配 | 1.txt N1 / 2.txt B4 |
| R12 | **N3：位数守卫提到自动执行段顶部**——--selftest/--report 也受守卫（原版无 GUI 分支绕过） | 1.txt N4 / 4.txt N3 |
| R13 | **N7：无 GUI 分支中途崩溃也落 FAIL 结果**（gSelfTestPath + LogRuntimeError 落盘 ExitApp(1)）——杜绝「无文件 + rc=0」假通过；上线当天即抓到 selftest 假对象缺 location 的崩溃（防护自证有效） | 4.txt N7 |
| R14 | **2.txt B 级**：TryRemoveEmptyParent 守卫补第六根 LocalAppData\Programs；GENERIC 补 application/applications；RecycleErrText 按 DE_* 真实语义重写（0x7C=INVALIDFILES、0x7D=DESTSAMETREE、0x7E=FLDDESTISFLD、0x74=ROOTDIR）；hadFocus 死变量按 K39 配方落实；MSI 去重键大小写归一；ReleaseType 过滤补丁条目；残留 note 带命中证据；operations.log 操作审计 | 2.txt B1–B4/C1/C4/C7/C8 |

**明确不做**（维持上轮裁决）：MSI API 反查（Q1/Q14）、NSIS `_?=`（Q12）、两阶段命令
解析器（Q6 深层/Q7/Q8）、/I 语义（Q4）、hNameMappings 逐对象报告（Q24）。

**坑（三轮新增）**
- 修 A1 时发现 RefreshList 的 hadFocus 是死变量（算了没用，无条件抢焦点）——按
  K39 配方落实为「原焦点才恢复、无焦点也顺手给列表」。
- selftest 假对象缺 location 属性导致 DecideCommand 崩溃——N7 防护当天把它抓成
  FAIL 结果而非静默假通过；教训：给被测函数加新依赖时，同步检查测试夹具的字段。

**验收**（2026-11-24 三轮整改后全部实跑）
- `--validate`：`{"ok":true,"rc":0}`（唯一警告 ROW_W 局部遮蔽随范本保留）。
- `--selftest`：**45 项全 PASS**（新增 junction 契约正反例——删链接后目标内容仍在、
  Quiet 裸名白名单回落、非 msiexec GUID 门控；FAIL 计数为 0，此前误报 1 条系
  统计正则大小写问题，精确复核排除）；fails=0。
- `python scripts/软件卸载/test/run.py` 六层 ALL PASS（填表 135 行）。
- `python tools/ui_static.py 软件卸载`：10/10（出货件哈希一致）。

**历史验收存档**（首轮/二轮，供溯源）
- `--report` 读数：三源 192+144+22=358 键 → 136 项安装记录，扫描+分类 125ms；
  分类 quiet=43 / msi=23 / family=5 / raw=63 / gone=0 / none=2。
- 合成应用端到端（零接触真实软件）：假卸载器 cmd + 假 Uninstall 键 + 残留文件夹/键
  → 实机走完「卸载确认 → Job 等待 → 键消失 → 自动切残留视图（3 项全勾选）→
  清理确认 → 回收站 1 项 + .reg 备份 2 份 + 残留全消」；卸载器缺失（gone）路径
  单独实测。探针产物已全部清理。
- 红臂记录：首轮破坏 CleanName 断言如实 FAIL；二轮列头对齐断言对旧固定坐标
  （x327/409/541 vs 新 323/401/529，差 ≥4px > 容差 ±2）必然变红。
