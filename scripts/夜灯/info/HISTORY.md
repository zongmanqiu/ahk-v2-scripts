# 夜灯 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.2.2（2026-11-13）

- **修复：拖动滑块时留残影**。滑块高 20、槽高 10，滑块上下各溢出 5px；它移开后
  腾出的那两条 5px 属于「窗口背景」而不是任何控件，宿主不重绘这块区域，
  旧位置的滑块像素就留在屏幕上。
  修法两层：① 在滑块下方先铺一条与滑块同高的同色底衬（`BackgroundF7F9FC`），
  腾出的像素归属这个会正常重绘的控件；② `Paint()` 改用
  `BeginDeferWindowPos`/`DeferWindowPos`/`EndDeferWindowPos` 一次性提交外框与内块，
  消掉「外框已到、内块还在旧位」的中间帧（K24 同型坑）。
- 验证：模拟真实拖动（按下 → 分 8 段移动 → 抬起），抓图采样原滑块路径上 15 个点，
  越界色 0 个；双环境一致。

## 1.2.1（2026-11-13）

- **修复：点滑块会直接崩掉脚本**。`FlatTrack` 把回调存进对象属性后写成 `this.cb(v)`
  调用，AHK v2 会把它当成「方法」调用并隐式多传一个 `this`，于是报
  「Too many parameters passed to function」——官方解释器弹错误框，宿主内核直接
  终止整个进程。改成显式 `this.cb.Call(v)`，两个内核都正确。
  这个问题从 1.2.0 引入自绘滑块起就存在，此前只验过「能打开、能显示」，
  没验过「点了会怎样」。
- 验证：`tools/ui_regress.py` 新增 S4「点槽后滑块移动」与 S5「点槽后无错误框」，
  独立解释器与宿主双环境通过（滑块左缘 223 → 20 / 20 → 232）。

## 1.2.0（2026-11-13）

- **去掉底部那一行说明**（1.1.0 加的 `强度 N% · 色温 NK` 状态条）：滑块右侧已有百分比，
  整行属冗余。客户区 `320×76 → 320×52`（顶 12 + 行高 28 + 底 12 = 52），
  槽 `x16 y21 w232 h10` + 百分比 `x256 y12 w48 h28`，行宽仍是 `232+8+48=288`。
- **滑块自绘**（1.1.0 登记的系统 Slider 例外此轮收掉）：`class FlatTrack`，
  只用 §10 封版令牌与已验证配方，不新增色值/字号 —— 槽 `BAND DCE8F7`，滑块是
  `FRAME B7C8E0` 外框 + 缩进 1px 的 `SOFT EBF2FB` 内块（与 `FlatButton` 同一套 1px 描边）。
  交互：`+0x100 (SS_NOTIFY)` + `OnMessage(0x201)` + 20ms 轮询 `GetCursorPos`/`GetKeyState`
  （`FlatScroll` 的 `BeginDrag` 同型做法，Text 控件拿不到中途 MOUSEMOVE）；键盘
  `←/→ ±1`、`PgUp/PgDn ±10`、`Home/End 0/100` 走 `OnMessage(0x100)`。
  `OnPanelClose` 先 `gTrack.Stop()` 停轮询定时器再销毁面板（K21 同型坑）。
- **图标恢复 AHK 默认**：1.1.0 之前用 `LoadIconW(0, 32512)` + 两条 `WM_SETICON`
  把标题栏图标设成 `IDI_APPLICATION`，与其它官方窗口的 AHK 绿图标不一致；删掉这三行。
  `WM_CHANGEUISTATE(0x127)` 只隐藏焦点框，保留。
- 行为零改动：GammaRamp 色温应用、注册表夜间模式与 400ms debounce、托盘菜单、
  `Persistent(true)`、`--selftest`、退出不还原显示设置全不动；关面板仍只关面板。

## 1.1.0（2026-11-13）

- 按 `.ahk-v2-scripts/开发指南.md` §10「官方原生 UI 标准」做视觉迁移，只改外观与文案，行为零改动：
  GammaRamp 色温应用、注册表夜间模式读写与 400ms debounce、托盘菜单（夜灯调整/还原冷色/退出）、
  `OnSliderChange` / `UpdatePct` / `ResetToCool` / `OnPanelClose` / `OnScriptExit`、`Persistent(true)`、
  `--selftest` 无 GUI 分支、退出不还原用户已生效的显示设置，全部保持原样。
- 令牌归一：`BackColor := "F7F9FC"`；全窗唯一 `SetFont("s10", "Microsoft YaHei UI")`；所有文字
  `c202B3A`。只用 §10.2.1 八色令牌（本窗实际用到 F7F9FC / DCE8F7 / 202B3A），无第九色、
  无新增字号档、不以 Bold 表达重要。
- 版式按 §10.3.1 五条规则重排：去掉 `AutoSize` + `MarginX/MarginY` 的自动撑高，改固定客户区
  **320×76**。坐标等式（W = 客户区宽 320，行宽 R = W - 32 = 288）：
  - 滑块行：x16 + Slider w232 + INLINE_GAP 8 + 百分比 w48 = 288，右缘 16+288 = 304 = 320-16（EDGE=16）；
    Slider 与百分比同 y12 同 h28，文字块固定高 + `+0x200` 垂直居中并 `Right` 右对齐。
  - 垂直节奏：TOP 12 + 滑块行 h28 = 40；换语义区块 BLOCK_GAP 6 → 状态条 y46；状态条 h30 → 底边
    76 = 窗口高（窗口高 = 状态条 y + H_STATUS = 46+30）。
  - 状态条：底块 `x0 y46 w320 h30 BackgroundDCE8F7`，文字块 `x12 y46 w296 h30`（左右各
    STATUS_PAD 12，12+296+12=320），`BackgroundDCE8F7 c202B3A +0x200`。
- 定位逻辑保留：先 `Show("w320 h76 x-20000 y-20000")` 到屏外，`GetPos` 取实际外框 gw/gh，
  再 `Move(wr - gw - 12, wb - gh - 12)` 落到右下角工作区；右下角坐标全部由 GetPos 结果与
  `MonitorGetWorkArea` 现算，未写死任何屏幕分辨率。
- 状态条 + 标题栏：`Show()` 之后调 `PaintCaption()`（DWM 属性 35/36/34，`#DCE8F7`→`0x00F7E8DC`、
  `#202B3A`→`0x3A2B20`，写在 `try` 里只写不读、Win10 静默降级）。`UpdatePct()` 同步把状态条
  更新为事实句「强度 N% · 色温 NK」，不写指令句、不写「请拖动」；原百分比 Text 保留。
- **例外（如实登记）**：系统 `Slider` 保留，未自绘、未上色、未用 `SetWindowTheme` 假装扁平。
  理由：它承载 Change 回调、ToolTip、键盘与 Range 语义；§10.7 黑名单未列 Slider，§10 也没有
  「调节滑块」的自绘配方，换成色块会丢掉这些原生行为（K2 已证主题 API 在宿主无效）。仅把滑块周围的
  面板底色、百分比文字块、状态条、标题栏统一到同一套令牌。本窗是离屏 AlwaysOnTop 小面板，
  不套列头那套完整结构（`.plan/m166-官方原生UI标准存量迁移.md` 对夜灯的判断）。头部注释同步登记。
- 验证结论（实测）：
  - `.3rd/AutoHotkey_2.0.30/AutoHotkey64.exe /validate <脚本>`：rc=0，无输出。
    注意 Git Bash 的 MSYS 路径转换会把 `/validate` 改写成 `<PortableGit>/validate`，AHK 找不到该
    文件会弹模态框卡住；需 `MSYS_NO_PATHCONV=1`。同一命令对已知良好的 `文件时间修改 2.4.4`
    也同样卡住，确认是调用环境问题、与本脚本无关。
  - `.build/AHKDeck.exe --validate <脚本>`：`{"ok":true,"rc":0}`，rc=0。
  - 独立解释器 `--selftest`：rc=0，13 项全 PASS、fails=0。
  - grep 复核：无旧色值、无 `s9`/`s11`/`s12`、无自造 6 位十六进制颜色、无 `Bold`、
    无 `MarginX`/`MarginY`/`AutoSize` 残留（屏外定位除外）、无 `SetWindowTheme` 调用；
    所有控件色值落在 F7F9FC / DCE8F7 / 202B3A 三档令牌内。
  - `.ahk` 保持原有 CRLF：568 行、bare_LF=0；本 HISTORY.md 沿用原有 LF。
- **实机像素（主代理补做，独立 + 宿主 `--run` 各一张 PNG）**：窗口 `336×115`、客户区偏移
  `8,31`、客户区 `320×76`；状态条四点 `(0,50) / (300,70) / (250,50) / (16,46)` 在两种
  环境下均为 `DCE8F7`，**4/4 命中、逐点一致**。截图中标题栏、面板底色、百分比文字与
  状态条同属浅色方案；系统 Slider 仍是原生外观（见上方例外登记）。
- 出货件与仓库台账（根 `README.md` / `scripts.json` / TAG / `.build/Scripts/` / `.bf`）
  由本轮统一收尾同步，证据见 `.plan/m167`；宿主 `.main` 零改动、未重编。

## 1.0.2（2026-11-12）

- 修复**关闭滑块面板后脚本自行退出**：1.0.1 去掉自设热键后，脚本里再没有任何会常驻的东西
  （托盘菜单项不算常驻理由），面板窗口是唯一的"活着"凭据，窗口一关脚本就正常结束。
  现在显式 `Persistent(true)`，关面板只关面板，脚本继续待命，托盘入口随时可再打开。
- 补 `--selftest [输出路径]` 无 GUI 分支（原先缺，违反开发指南 §6「有注册表操作的脚本要自带自测」）：
  校验 varint 编解码、模板解析回温度/时间戳、坏数据被拒、强度↔色温往返、系统时间戳，
  并对 HKCU 自建键做二进制写-读-覆盖-清理往返。不写真实夜间模式值、不碰屏幕 Gamma、不改 HKLM。
  `@entry` 同步注明该分支。

## 1.0.1（2026-11-11）

- 去掉脚本自设的全局热键 `Ctrl+Alt+Shift+N`：全局热键改由 AHKDeck 统一指派，脚本只保留托盘入口。
- 头部 `@entry` 与说明注释同步去热键；其余行为与功能不变。

## 1.0.0（2026-11-11）

- 首次发布：能力移植自作者自有项目 KissLight，纯 AHK v2 实现。
- 滑块 0–100% 对应色温 6500K–1200K，实时 `SetDeviceGammaRamp`；停拖 400 ms 后把色温写进
  Windows 夜间模式 CloudStore 二进制值（只改温度字段与时间戳，保留其余字节）。
- 启动读系统当前夜间模式色温作初值；托盘「夜灯调整／还原冷色／退出」，热键 `Ctrl+Alt+Shift+N`。
- 退出不还原屏幕（屏幕当前样子即用户最后选择）；解锁 gamma 范围需管理员。
- 头部油猴式 `==UserScript==` 块；独立运行托盘可见性按 `A_AhkPath` 判定（宿主内零变化）。