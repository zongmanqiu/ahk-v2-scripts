"""硬件信息 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/硬件信息/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 无 GUI 自测（--selftest）全绿；
3. GUI 实机：窗口 672x520、八页导航（CPU/主板/内存/显卡/磁盘/网卡/显示器/系统）、
   顶部无标题行与按钮、无状态条、点导航能切页、需要时出现自绘滚动条、不需要时不出现。

只读本机硬件、不改任何文件；结束即停掉自己拉起的会话。
"""
import ctypes
import os
import sys
import time
from ctypes import wintypes

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "硬件信息.ahk")
OUT = os.path.join(os.environ.get("TEMP", "."), "ahkdeck-hw-selftest.txt")
USER32 = ctypes.windll.user32
KERNEL32 = ctypes.windll.kernel32

NAVS = ["CPU", "主板", "内存", "显卡", "磁盘", "网卡", "显示器", "系统"]

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


def walk_all(node, out):
    out.append(node)
    for c in node.get("controls", []):
        walk_all(c, out)


def click(hwnd_str):
    h = int(hwnd_str, 16)
    lp = (5 << 16) | 5
    USER32.PostMessageW(h, 0x201, 1, lp)   # WM_LBUTTONDOWN
    USER32.PostMessageW(h, 0x202, 0, lp)   # WM_LBUTTONUP


def click_and_wait(m, sid, hwnd_str, expect, timeout=3.0):
    """点导航后轮询到目标页出现：固定 sleep 在机器忙时会读到上一页，造成偶发误判。"""
    click(hwnd_str)
    deadline = time.time() + timeout
    names, bar = [], 0
    while time.time() < deadline:
        time.sleep(0.2)
        _, _, lv, b = grab(m, sid)
        rows = lv.get("items", {}).get("rows", []) if lv else []
        names = [r[0] for r in rows]
        bar = b
        if expect in names:
            return True, names, bar
    return False, names, bar


def geo(n):
    """节点几何：inspect_ui 给 client（相对父）与 screen（屏幕坐标），没有 rect。"""
    return n.get("client") or n.get("screen") or {}


_ENUM = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def popup_menu():
    """找系统弹出菜单窗口（类名 #32768）；右键菜单是独立 popup，不在主窗口里。"""
    found = []

    def cb(hwnd, _lp):
        cls = ctypes.create_unicode_buffer(64)
        USER32.GetClassNameW(hwnd, cls, 64)
        if cls.value == "#32768" and USER32.IsWindowVisible(hwnd):
            r = wintypes.RECT()
            USER32.GetWindowRect(hwnd, ctypes.byref(r))
            found.append((r.left, r.top))
        return True

    USER32.EnumWindows(_ENUM(cb), 0)
    return found


def clipboard():
    KERNEL32.GlobalLock.restype = ctypes.c_void_p
    KERNEL32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    KERNEL32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    USER32.GetClipboardData.restype = wintypes.HANDLE
    USER32.GetClipboardData.argtypes = [wintypes.UINT]
    for _ in range(20):
        if USER32.OpenClipboard(0):
            break
        time.sleep(0.05)
    else:
        return None
    try:
        h = USER32.GetClipboardData(13)          # CF_UNICODETEXT
        if not h:
            return None
        p = KERNEL32.GlobalLock(h)
        if not p:
            return None
        try:
            return ctypes.wstring_at(p)
        finally:
            KERNEL32.GlobalUnlock(h)
    finally:
        USER32.CloseClipboard()


def grab(m, sid):
    """取当前窗口、全部控件、属性列表、以及自绘滚动条的竖条高度。"""
    ui = m.call("inspect_ui", {"session": sid, "items": True, "rows": 80})
    wins = ui.get("windows", [])
    if not wins:
        return None, [], None, 0
    w = wins[0]
    nodes = []
    walk_all(w, nodes)
    lv = next((n for n in nodes if n.get("class") == "SysListView32"), None)
    # 自绘滚动条的槽/滑块宽 3~10px 且高；ShowWindow(0) 不改几何，必须看 visible。
    # 下限取 3：列表左右边框是 1px 的竖线，高 497，用 w<=10 会把它误判成滚动条。
    bar = 0
    for n in nodes:
        r = geo(n)
        if (n.get("class") == "Static" and n.get("visible")
                and 3 <= r.get("w", 0) <= 10 and r.get("h", 0) >= 100):
            bar = max(bar, r["h"])
    return w, nodes, lv, bar


def main():
    src = open(SCRIPT, encoding="utf-8").read()
    m = MCP(timeout=120)
    try:
        m.initialize()
        m.call("edit_editor", {"content": src})

        v = m.call("validate_editor", {})
        check("内核语法校验 rc=0", v.get("rc") == 0, text_of(v)[:300])

        r = m.call("run_editor", {"args": ["--selftest", OUT], "timeout_ms": 20000})
        check("--selftest rc=0", r.get("rc") == 0, text_of(r)[:300])
        text = ""
        try:
            text = open(OUT, encoding="utf-8-sig").read()
        except OSError:
            pass
        check("自测 fails=0", "fails=0" in text, text[-400:])
        check("自测无 FAIL 行", "FAIL " not in text, text)

        r2 = m.call("run_editor", {"timeout_ms": 6000})
        check("GUI 常驻", r2.get("verdict") == "resident", text_of(r2)[:300])
        sid = r2.get("session")
        time.sleep(2)

        w, nodes, lv, bar = grab(m, sid)
        check("有窗口", w is not None)
        if not w:
            return 1
        check("窗口标题=硬件信息", w.get("text") == "硬件信息", repr(w.get("text")))
        check("客户区 672x520", w.get("client", {}).get("w") == 672
              and w.get("client", {}).get("h") == 520, str(w.get("client")))

        texts = [n.get("text") for n in nodes if n.get("class") == "Static"]
        missing = [n for n in NAVS if n not in texts]
        check("八个导航项齐全", not missing, "缺: " + ",".join(missing))
        check("无刷新/复制按钮", "刷新" not in texts and "复制" not in texts,
              str([t for t in texts if t in ("刷新", "复制")]))
        check("无页面标题行", not any((t or "").count("·") for t in texts), str(texts[:10]))

        check("找到属性列表", lv is not None)
        if lv:
            items = lv.get("items", {})
            check("属性表 2 列", items.get("columns") == 2, str(items.get("columns")))
            check("默认页有内容", items.get("count", 0) > 5, str(items.get("count")))
            check("每行两格", all(len(row) == 2 for row in items.get("rows", [])),
                  str(items.get("rows", [])[:3]))

        # 高度检查：列表上边距应紧贴窗口顶（无标题行占位）
        if lv:
            top = geo(lv).get("y")
            win_h = (w.get("screen") or {}).get("h")
            if top is not None and win_h:
                # 列表客户区 y 应 = 12 边距 + 26 列头 = 38；不可能是删标题行前的 74
                check("列表紧贴顶部（无标题行）", 36 <= top <= 42, "y=%s" % top)

        # 内存页：25 行，超出可视区 -> 应出现自绘滚动条
        nodes2 = nodes
        mem = next((n for n in nodes if n.get("class") == "Static" and n.get("text") == "内存"), None)
        check("找到内存导航按钮", mem is not None)
        ok, names, bar2 = False, [], 0
        if mem:
            ok, names, bar2 = click_and_wait(m, sid, mem["hwnd"], "总容量（已安装）")
        check("切到内存页", ok, str(names[:6]))
        check("内存页含槽位分隔", any("槽" in n for n in names), str(names[:12]))
        check("内存页出现滚动条", bar2 >= 100, "bar=%s" % bar2)

        if mem:
            # 右键复制本行：菜单是独立 popup 窗口，用 EnumWindows 找，再用真实鼠标点首项。
            # 此时页面在顶部，第 2 行是「内存类型 / DDR4」。
            _, _, lv3, _ = grab(m, sid)
            if lv3:
                scr = lv3.get("screen") or {}
                cx, cy = 60, 33
                USER32.SetCursorPos(scr.get("x", 0) + cx, scr.get("y", 0) + cy)
                USER32.PostMessageW(int(lv3["hwnd"], 16), 0x204, 2, (cy << 16) | cx)
                time.sleep(0.8)
                menus = popup_menu()
                check("右键弹出复制菜单", bool(menus), "menus=%s" % menus)
                if menus:
                    mx, my = menus[0]
                    USER32.SetCursorPos(mx + 40, my + 14)
                    USER32.mouse_event(0x0002, 0, 0, 0, 0)   # LEFT DOWN
                    USER32.mouse_event(0x0004, 0, 0, 0, 0)   # LEFT UP
                    time.sleep(0.9)
                    clip = clipboard() or ""
                    check("复制本行到剪贴板", "\t" in clip and "内存类型" in clip, repr(clip))
            time.sleep(1.4)                              # 等 1.2s 的浮动提示自然消失

            # 滚到底：首行应变化，且滚动条仍在
            gui_h = int(w["hwnd"], 16)
            for _ in range(6):
                USER32.PostMessageW(gui_h, 0x20A, (-120 & 0xFFFF) << 16, 0)
                time.sleep(0.08)
            time.sleep(0.6)
            _, _, _, bar3 = grab(m, sid)
            check("滚动后滚动条仍在", bar3 >= 100, "bar=%s" % bar3)

        # 显示器页：只有 6 行 -> 不应出现滚动条
        mon = next((n for n in nodes2 if n.get("class") == "Static" and n.get("text") == "显示器"), None)
        if mon:
            ok2, names2, bar4 = click_and_wait(m, sid, mon["hwnd"], "名称")
            check("切到显示器页", ok2, str(names2[:6]))
            check("显示器页无滚动条", bar4 < 100, "bar=%s" % bar4)

        # 窗口可缩放（2.2.0）：最大化后列表与列头带一起变宽，恢复后回到 672×520
        ui5 = m.call("inspect_ui", {"session": sid, "items": False})
        w5 = (ui5.get("windows") or [None])[0]
        if w5:
            hw5 = int(w5["hwnd"], 16)
            USER32.PostMessageW(hw5, 0x0112, 0xF030, 0)      # SC_MAXIMIZE
            time.sleep(1.4)
            _, nodes5, lv5, _ = grab(m, sid)
            lv_w = geo(lv5).get("w", 0) if lv5 else 0
            band = max([geo(n).get("w", 0) for n in nodes5
                        if n.get("class") == "Static" and geo(n).get("h") == 26] or [0])
            check("最大化后列表变宽", lv_w > 900, "lvW=%s" % lv_w)
            check("最大化后列头带跟随变宽", band > 900, "band=%s" % band)
            USER32.PostMessageW(hw5, 0x0112, 0xF120, 0)      # SC_RESTORE
            time.sleep(1.4)
            ui6 = m.call("inspect_ui", {"session": sid, "items": False})
            c6 = ((ui6.get("windows") or [{}])[0]).get("client") or {}
            check("恢复后回到 672×520", (c6.get("w"), c6.get("h")) == (672, 520), str(c6))

        m.call("stop_script", {"session": sid})
    finally:
        m.close()

    print("FAILED:", len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
