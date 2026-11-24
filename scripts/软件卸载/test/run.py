# -*- coding: utf-8 -*-
"""软件卸载 的实机回归（只跑本脚本自己，AGENTS.md 第 12 条）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/软件卸载/test/run.py

断言层：
  1. --selftest 纯逻辑（56 项，fails=0，抽查关键词）；
  2. 启动几何：客户区 672×386、五列头（名称/版本/发行者/安装时间/状态）、两按钮（卸载/重新扫描）、
     状态条含「已扫描」；
  3. 启动填表（延迟单次定时器）：列表 ≥100 行（真实安装清单）；
  4. 安装时间不再缺失、也不带 "~" 前缀：每行第 4 列都非空且为纯日期；
  5. 原生滚动条不回位（K36/K34 终态回归）：LV 样式位 & 0x00300000 == 0；
  6. 列头对齐（§10.3.3）：列头文字块 x = 列表左缘(17) + 列起点 + CELL_PAD(6)，容差 ±2px。
     红臂：旧版列头是写死的固定 x，与新算法（按 ColWidths 累加、随竖条显隐变化）差 ≥4px，
     本断言对旧代码会红；
  7. 源码顺序回归：FixCols 必须先 HideNative 再 Redraw（否则灰条留在屏上）；
  8. 填表必须走 K36 藏表配方，且摘条（HideNative）排在 SETREDRAW 1 / SW_SHOW 之前
     （1.0.14 翻案：之前不藏表，灰条留在屏上）；Sync 抓回被置回的原生条要擦像素，
     交给 ListView 的键/点击要有一次性 QueueRepair 兜底；
  10. 白底块存在：gLvWhite 覆盖原生条区域，滚动时不露窗口底色（1.0.7 补回）；
 11. 停止即退出：stop_script 后会话 finished，会话输出无内核报错。

只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。
"""
import json
import re
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]      # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP                        # noqa: E402

NAME = "软件卸载"
OUT = Path(__file__).resolve().parent / "selftest-result.txt"
LV_STYLE_NATIVE_MASK = 0x00300000                # WS_VSCROLL | WS_HSCROLL
ALIGN_TOL = 2                                    # 列头对齐容差 px
COL_FIXED = {"版本": 78, "发行者": 128, "安装时间": 112, "状态": 122}   # 首列吸收余量；固定列宽合计 440


def find_script_id(m):
    listed = m.call("list_scripts")
    for s in listed.get("scripts", []):
        if NAME in s.get("name", ""):
            return s.get("id") or s.get("name")
    raise AssertionError("脚本未出现在 list_scripts：先复制到 .build/Scripts")


def func_body(name):
    """取顶层函数体原文（"name(参数) {" 到行首 "}"）。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    m = re.search(rf"\n{name}\([^)]*\) \{{", src)
    assert m, f"源码里找不到函数 {name}"
    return src[m.start():src.index("\n}", m.start())]


def method_body(name):
    """取类方法体原文（缩进 4 空格的 "name(参数) {" 到同缩进的 "}"）。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    m = re.search(rf"\n    {name}\([^)]*\) \{{", src)
    assert m, f"源码里找不到方法 {name}"
    return src[m.start():src.index("\n    }", m.start())]


def strip_comments(text):
    """去掉 AHK 的 ; 行注释（双引号内的 ; 不裁）。"""
    out = []
    for line in text.splitlines():
        in_str = False
        cut = len(line)
        for i, ch in enumerate(line):
            if ch == '"':
                in_str = not in_str
            elif ch == ";" and not in_str:
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def test_selftest(m, sid):
    OUT.unlink(missing_ok=True)
    run = m.call("run_script", {"script": sid, "args": ["--selftest", str(OUT)]})
    assert run.get("ok") and run.get("rc") == 0, f"selftest 运行失败: {run}"
    deadline = time.time() + 30
    while not OUT.exists() and time.time() < deadline:
        time.sleep(0.3)
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("CleanName 去括注与版本号", "SplitCommand 无引号含空格路径",
               "决策链 MSI 改写 /X /qn /norestart", "备份后删除注册表键"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/9] selftest 全绿（决策链/解析三形态/家族判定/自建自清注册表）")


def read_ui(m, sess):
    return m.call("inspect_ui", {"session": sess, "items": True, "rows": 200})


def wait_filled(m, sess, min_rows=100, timeout=45):
    """等启动扫描（延迟单次定时器 + 可能有 AV 首扫延迟）把列表填出来。"""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        ins = read_ui(m, sess)
        wins = ins.get("windows", [])
        if wins:
            for c in wins[0].get("controls", []):
                if c.get("class") == "SysListView32":
                    n = (c.get("items") or {}).get("count", 0)
                    last = n
                    if n >= min_rows:
                        return ins
        time.sleep(1.0)
    raise AssertionError(f"启动填表超时：列表最后只有 {last} 行（≥{min_rows}）")


def pick(w, pred):
    return [c for c in w.get("controls", []) if pred(c)]


def test_gui(m, sid):
    run = m.call("run_script", {"script": sid})
    assert run.get("ok"), f"GUI 启动失败: {run}"
    sess = run.get("session")
    assert run.get("state") == "running", f"GUI 未常驻: {run}"
    return sess


def test_geometry(ins):
    wins = ins.get("windows", [])
    assert wins, "inspect_ui 没找到窗口"
    w = wins[0]
    c = w.get("client", {})
    assert c.get("w") == 672 and c.get("h") == 386, f"窗口客户区错: {c}"
    hdrs = {x.get("text"): x for x in pick(w, lambda x: x.get("text") in ("名称", "版本", "发行者", "安装时间", "状态"))}
    for t in ("名称", "版本", "发行者", "安装时间", "状态"):
        assert t in hdrs, f"缺列头: {t}"
    btns = {x.get("text") for x in pick(w, lambda x: x.get("text") in ("卸载", "重新扫描"))}
    assert {"卸载", "重新扫描"} <= btns, f"缺按钮: {btns}"
    status = [x for x in pick(w, lambda x: (x.get("text") or "").startswith("已扫描"))]
    assert status, "状态条没有走到「已扫描」"
    print("  [2/9] 启动几何：672×386 + 五列头 + 两按钮 + 状态条已扫描")


def test_fill_and_native_bar(ins):
    w = ins.get("windows", [])[0]
    lvs = pick(w, lambda x: x.get("class") == "SysListView32")
    assert lvs, "没找到列表"
    lv = lvs[0]
    items = lv.get("items") or {}
    assert items.get("count", 0) >= 100, f"启动填表不足: {items.get('count')}"
    style = int(lv.get("style", "0"), 16)
    assert style & LV_STYLE_NATIVE_MASK == 0, \
        f"原生滚动条样式位置回（K36 回归）: style={lv.get('style')}"
    print(f"  [3/9] 启动填表 {items.get('count')} 行")
    print("  [4/9] 原生滚动条样式位干净（K36/K34 终态断言）")
    return w, lv


def test_installed_dates(lv):
    """安装时间不许有空列、也不许带「约」前缀：四档兜底后每行都是纯 YYYY-MM-DD。"""
    rows = (lv.get("items") or {}).get("rows") or []
    assert rows, "列表行内容为空"
    blank = [r for r in rows if len(r) < 5 or not str(r[3]).strip()]
    assert not blank, f"安装时间缺失 {len(blank)}/{len(rows)} 行，例：{blank[:3]}"
    pref = [r for r in rows if str(r[3]).startswith("~")]
    assert not pref, f"安装时间仍有 ~ 前缀 {len(pref)}/{len(rows)} 行，例：{pref[:3]}"
    print(f"  [4b] 安装时间全有值且无前缀（{len(rows)} 行）")


def test_fixcols_order():
    """源码顺序回归：FixCols 里必须「先 HideNative、再 Redraw」。
    ModifyCol 会把原生条样式位置回并让 comctl32 连非客户区一起画出来；先 Redraw 就等于
    把 16px 灰条画到屏幕上，之后再 HideNative 只摘样式位、不擦像素——这就是「滚动时
    旧的滚动条」。这条断言对旧顺序会红。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    start = src.index("\nFixCols() {")
    body = src[start:src.index("\n}", start)]
    code = "\n".join(ln.split(";")[0] for ln in body.splitlines())   # 去掉注释再比顺序
    assert "HideNative" in code and "Redraw" in code, "FixCols 结构变了，请复核本断言"
    assert code.index("HideNative") < code.index("Redraw"), "FixCols 顺序反了：先 Redraw 后 HideNative"
    print("  [6/9] FixCols 先摘原生条再重绘（旧的滚动条根因）")


def test_header_align(w, lv):
    lv_c = lv.get("client", {})
    list_w = lv_c.get("w", 0)
    c1 = max(160, list_w - 440)
    lv_x = lv_c.get("x", 17)
    expect = {
        "版本": lv_x + c1 + 6,
        "发行者": lv_x + c1 + 78 + 6,
        "安装时间": lv_x + c1 + 78 + 128 + 6,
        "状态": lv_x + c1 + 78 + 128 + 112 + 6,
    }
    hdrs = {x.get("text"): x.get("client", {}).get("x")
            for x in pick(w, lambda x: x.get("text") in expect)}
    for t, ex in expect.items():
        got = hdrs.get(t)
        assert got is not None, f"缺列头 {t}"
        assert abs(got - ex) <= ALIGN_TOL, f"列头 {t} 对齐偏差 {got} vs {ex}（±{ALIGN_TOL}）"
    print(f"  [5/9] 列头对齐（列表宽 {list_w}，首列 {c1}，CELL_PAD=6，±{ALIGN_TOL}px）")


def test_refresh_recipe():
    """RefreshList 必须走 K36 藏表配方，且摘条排在恢复重绘/显示之前（1.0.14 翻案）。

    1.0.13 及以前不藏表，理由是「SW_SHOW 会把原生灰条画到屏上」——那是顺序错：
    摘条（HideNative）必须在 SETREDRAW 1 / SW_SHOW **之前**。放在之后等于先把灰条
    画上、再只摘样式位，像素擦不掉（用户报的「滚一下/一过滤就冒出老式滚动条」）。
    本断言对 1.0.13 的代码会红（它根本没有 ShowWindow）。"""
    code = strip_comments(func_body("RefreshList"))
    assert "ShowWindow" in code, "RefreshList 又丢了 SW_HIDE/SW_SHOW 藏表"
    assert "0x000B" in code or "WM_SETREDRAW" in code.upper(), "RefreshList 必须冻结重绘"
    i_hide = code.find("HideNative")
    assert i_hide >= 0, "RefreshList 里没有 HideNative（摘条）"
    # SETREDRAW TRUE 与 SW_SHOW 必须排在 HideNative 之后（1.0.13 的失效顺序）
    i_true = code.find('0x000B, "Ptr", 1')
    assert i_true >= 0, "找不到 WM_SETREDRAW TRUE"
    assert i_hide < i_true, "摘条必须在 WM_SETREDRAW TRUE 之前"
    i_show = code.find('Int", 8')
    assert i_show >= 0, "找不到 SW_SHOWNA(8)"
    assert i_hide < i_show, "摘条必须在 SW_SHOWNA 之前"
    assert "gScroll.Layout()" in code and "FixCols()" in code, "RefreshList 收口步骤丢了"
    print("  [7/9] 填表藏表 + 摘条先于恢复重绘/显示（K36 顺序）")


def test_native_cover():
    """HideNative 纯摘样式位（1.0.20 对齐无残留参照《打开方式清理》）。

    1.0.14/1.0.16 给 HideNative 加了 SWP_FRAMECHANGED + CoverNative 治原生灰条，门禁把它们钉成
    「必须」。但《打开方式清理》用纯 ShowScrollBar 同样无残留：① CoverNative 在本窗口无边框
    ListView 上是空操作（客户区=窗口矩形，cw>=ww 直接 return）；② SWP_FRAMECHANGED 每次滚动强制
    ListView 重算非客户区、重新评估滚动条，反而让原生条闪现——这正是拖影久拖未解、且门禁一直绿
    却拦不住的根因。1.0.20 撤掉两处，断言它们不许被加回。"""
    hid = strip_comments(method_body("HideNative"))
    assert "ShowScrollBar" in hid, "HideNative 必须摘原生条样式位"
    assert "0x0037" not in hid and "FRAMECHANGED" not in hid, "HideNative 不许再用 SWP_FRAMECHANGED（每次滚动闪现原生条）"
    assert "CoverNative" not in hid, "HideNative 不许再调 CoverNative（无边框 ListView 上是空操作）"
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    assert "CoverNative()" not in src, "CoverNative 方法/调用应整体删除（注释提词不算）"
    assert "+0x04000000" not in src, "WS_CLIPSIBLINGS 会把列表裁成空白，不许再加回来"
    print("  [7c] HideNative 纯摘样式位（对齐参照，无 FRAMECHANGED/CoverNative）")


def test_sync_repair():
    """旁路滚动的擦像素兜底（1.0.14；1.0.20 撤掉 HideNative 的 FRAMECHANGED）。

    - Sync 发现样式位被置回时要整块作废重画；滚轮/键/点击三条通路都要排一次性擦像素。
      原生条灰条就靠这些 UpdateWindow(lv) 整块重绘盖掉，不再依赖 SWP_FRAMECHANGED
      （1.0.20：去掉后稳态采滚动条列无 F0F0F0，且参照《打开方式清理》本就不用它）。"""
    code = strip_comments(method_body("Sync"))
    assert "EnsureHidden()" in code and "InvalidateRect" in code and "UpdateWindow" in code, \
        "Sync 抓回原生条后必须整块作废重画"
    key = strip_comments(func_body("OnBarKey"))
    assert "QueueRepair" in key, "交给 ListView 自己滚的键必须挂一次性擦像素"
    down = strip_comments(func_body("OnBarDown"))
    assert "QueueRepair" in down, "点在列表上的自动滚动必须挂一次性擦像素"
    wheel = strip_comments(func_body("OnBarWheel"))
    assert "QueueRepair" in wheel, "滚轮滚完必须再排一次擦像素（comctl32 会延后补画）"
    print("  [7b] 旁路滚动有擦像素兜底 + HideNative 强制重算客户区")


def test_invalidate_order():
    """Layout 的失效顺序：背景块之后必须紧跟它的内容控件。

    单独 InvalidateRect 背景块（Text 兄弟窗口、z 序在内容之上）会把内容整块盖成纯色；
    实测搜索框被 B7C8E0 盖死。断言 gBand 在 gHdr1 之前、gSearchFrame 在 gSearch 之前，
    且两者都在同一个失效数组里。"""
    body = strip_comments(func_body("Layout"))
    m = re.search(r"for c in \[(.*?)\]", body, re.S)
    assert m, "Layout 找不到失效控件数组"
    arr = [s.strip() for s in m.group(1).replace("\n", " ").split(",")]
    assert "gSearchFrame" in arr and "gSearch" in arr, "搜索框的内容控件没进失效数组"
    assert arr.index("gSearchFrame") < arr.index("gSearch"), "先失效内容再失效框，框会盖住输入框"
    assert "gBand" in arr and "gHdr1" in arr and arr.index("gBand") < arr.index("gHdr1"), \
        "列头带必须排在列头文字之前失效"
    print("  [8/9] 失效顺序：背景块先、内容控件后（色块根因）")


def test_hover_decode():
    """悬停命中解析：LVM_SUBITEMHITTEST 返回值是行号，列号在 LVHITTESTINFO.iSubItem(16)。

    本机实测：点 (306,11) 落在第 1 行发行者列时返回 0、iSubItem=2。旧代码按「返回值=列号、
    offset 8=iItem」解析，取到的是 flags 与错行——提示永远指向别的格子。"""
    code = strip_comments(func_body("OnLvHover"))
    assert "row := sub + 1" in code, "行号应取 LVM_SUBITEMHITTEST 的返回值"
    assert "NumGet(info, 16, \"Int\") + 1" in code, "列号应取 LVHITTESTINFO.iSubItem(offset 16)"
    assert "NumGet(info, 8, \"Int\") + 1" not in code, "又按 flags(offset 8) 取行号了"
    print("  [8b] 悬停命中：返回值=行号、offset16=列号")


def test_white_underlay():
    """gLvWhite 白底块必须存在（1.0.7 补回）。

    ShowScrollBar(FALSE) 只摘原生条样式位，ListView 不接管那 10px 竖槽区域的重绘；
    露出的会是窗口底色 B7C8E0（浅米色），跟列表白不一致——这就是「旧滚动条」。
    白底块先建（z 序最底），ListView 最后建（z 序最顶），正常时被列表挡住；
    原生条位置露出来的永远是白色，与列表同色看不见。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    assert "gLvWhite := gGui.Add(\"Text\"" in src, "BuildGui 里必须先铺白底块（滚动条 BUG 根因）"
    layout = strip_comments(func_body("Layout"))
    assert "gLvWhite.Move" in layout, "Layout 必须 Move 白底块到列表位置"
    assert "gLvWhite" in re.search(r"for c in \[(.*?)\]", layout, re.S).group(1), \
        "失效数组必须包含 gLvWhite（背景块先、内容控件后）"
    print("  [9/10] 白底块 gLvWhite 覆盖原生条区域")


def test_flush_atomic_regen():
    """Flush 原子提交后必须逐块同步重画（1.0.18 防白块 + 1.0.19 防拖影）。

    1.0.17 把逐个 SetWindowPos 换成 DeferWindowPos 原子提交（治拖影），却删掉了每块
    InvalidateRect，滑块加高后下缘白底复发（1.0.12 修过的 bug）。1.0.18 补回逐块
    InvalidateRect 治了白块，但拖影仍在——只 InvalidateRect 要等宿主空闲的 WM_PAINT，
    连续滚动时主线程忙、WM_PAINT 挤不进来，旧滑块深蓝像素停在屏上。1.0.19 在每块
    InvalidateRect 后紧跟 UpdateWindow 同步重画，按 ops 顺序（轨道浅蓝先、滑块深蓝后）
    把旧滑块位先盖成浅蓝、滑块再画到新位。"""
    body = strip_comments(method_body("Flush"))
    assert "DeferWindowPos" in body, "Flush 必须用 DeferWindowPos 原子提交（治拖影）"
    seg = body.split("EndDeferWindowPos", 1)[1].split("return", 1)[0]
    assert "InvalidateRect" in seg, "Defer 成功分支 return 之前必须补逐块 InvalidateRect 重绘（防白块）"
    assert "UpdateWindow" in seg, "Defer 成功分支每块 InvalidateRect 后必须紧跟 UpdateWindow 同步重画（防拖影）"
    print("  [7d] Flush 原子提交后逐块同步重画（白块+拖影双修）")


def test_track_underlay():
    """静止浅蓝底衬 trackBg 覆盖整条槽（1.0.21，K33 正解①，治「滑块背后白块 / 旧滚动条」）。

    滑块移到新位、轨道段还没补上的那一瞬，底下若露 gLvWhite 纯白就形成白块/旧滚动条。trackBg
    浅蓝静止铺满整条槽、压在 vUp/vDn/滑块之下，露出的永远是浅蓝。断言：① trackBg 用浅蓝创建；
    ② 在 vUp 之前建（z 序天然在下，否则盖住深蓝滑块）；③ Layout 里 exV 时 Move 铺满整条槽并显示。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    assert "this.trackBg := g.Add" in src, "必须创建静止底衬 trackBg"
    assert src.index("this.trackBg := g.Add") < src.index("this.vUp := g.Add"), \
        "trackBg 必须在 vUp 之前创建，否则压在滑块之上会盖住深蓝"
    assert "BackgroundDCE8F7" in src[src.index("this.trackBg"):src.index("this.vUp")], \
        "trackBg 必须是轨道浅蓝 DCE8F7"
    lay = strip_comments(method_body("Layout"))
    assert "trackBg.Move" in lay and "trackBg.Visible := true" in lay, \
        "Layout 必须把 trackBg 铺满整条槽并在溢出时显示"
    print("  [7e] 静止浅蓝底衬 trackBg 覆盖整条槽（K33①，治白块/旧滚动条）")


def test_nc_subclass():
    """ListView 挂 WM_NCCALCSIZE 子类，原生条物理画不出来（1.0.22，根治残影）。

    原生灰条画在**非客户区**，InvalidateRect(lv,NULL,FALSE) 只作废客户区、永远擦不到——这是
    1.0.11~1.0.21 十版「藏完再追着擦」仍留残影的根因（自绘 trackBg 画在 ListView 右侧外、与内侧
    原生条根本不重叠，也盖不到）。正解：WM_NCCALCSIZE 到达时临时摘 WS_VSCROLL|WS_HSCROLL 再算客户区，
    原生条分不到 NC 空间、一个像素都画不出；滚动走 SetScrollInfo 不受影响。断言子类函数/安装/摘除齐全。"""
    src = (Path(__file__).resolve().parents[1] / f"{NAME}.ahk").read_text(encoding="utf-8")
    assert "LvNcCalcSize" in src, "必须有 WM_NCCALCSIZE 子类函数 LvNcCalcSize"
    proc = strip_comments(func_body("LvNcCalcSize"))
    assert "0x0083" in proc and "0x00300000" in proc, "子类必须在 WM_NCCALCSIZE 摘 WS_VSCROLL|WS_HSCROLL"
    assert "SetWindowSubclass" in src, "BuildGui 必须挂子类（第一次 Layout/填表之前）"
    assert "RemoveWindowSubclass" in src, "OnGuiClose 必须摘子类（K21：回调须全程有效）"
    print("  [7f] ListView WM_NCCALCSIZE 子类，原生条物理画不出（根治残影）")


def test_stop(m, sess):
    out = m.call("get_session_output", {"session": sess})
    errs = out.get("errors") or []
    assert not errs, f"会话有内核报错: {errs[:3]}"
    st = m.call("stop_script", {"session": sess})
    assert st.get("ok"), f"stop_script 失败: {st}"
    time.sleep(0.8)
    sessions = m.call("list_sessions")
    mine = [s for s in sessions.get("sessions", []) if s.get("session") == sess]
    assert mine and mine[0].get("state") == "finished", f"停止后会话未结束: {mine}"
    print("  [9/9] 停止即退出，会话输出无内核报错")


def main():
    OUT.unlink(missing_ok=True)
    m = MCP()
    try:
        m.initialize()
        sid = find_script_id(m)
        test_selftest(m, sid)
        sess = test_gui(m, sid)
        time.sleep(1.0)                      # 给延迟单次扫描定时器一拍
        ins = wait_filled(m, sess)
        test_geometry(ins)
        w, lv = test_fill_and_native_bar(ins)
        test_installed_dates(lv)
        test_header_align(w, lv)
        test_fixcols_order()
        test_refresh_recipe()
        test_native_cover()
        test_sync_repair()
        test_invalidate_order()
        test_flush_atomic_regen()
        test_track_underlay()
        test_nc_subclass()
        test_hover_decode()
        test_white_underlay()
        test_stop(m, sess)
        print("ALL PASS")
        return 0
    except AssertionError as e:
        print("FAIL:", e)
        return 1
    except Exception as e:
        print("ERROR:", e)
        return 2
    finally:
        try:
            m.call("stop_all")
        except Exception:
            pass
        m.close()


if __name__ == "__main__":
    sys.exit(main())
