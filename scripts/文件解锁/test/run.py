# -*- coding: utf-8 -*-
"""文件解锁 的实机回归（只跑本脚本自己，AGENTS.md 第 12 条）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/文件解锁/test/run.py

五层断言：
  1. --selftest 纯逻辑（NtPath / FPIF 找占用者 / 占用检测 / 删除保留名文件）；
  2. inspect_ui 几何：窗口 672×352 + 列表/两按钮/状态条齐全，按钮宽≈文字宽+32（K25）；
     以及缩放/最大化后各块跟随（列表吸收纵向余量、路径列吸收横向余量、状态条贴底）；
  3. 拖入即检测端到端（WM_DROPFILES 注入）：
     - nul 保留名文件 → 状态「无占用」（不误报进程）；
     - holder 占用的文件 → 状态列直接显示进程名。
  4. 解除占用全链路：点按钮 → 确认框出现 → 向 #32770 投 WM_COMMAND(IDYES=6)
     → 状态「解除完成」且行状态翻回「无占用」。

确认框注入口径：AHK v2 的 MsgBox 返回的是按钮**字符串**（"Yes"），不是 6；
比较写成 `!= 6` 会恒真、每次都当作用户取消（1.1.2 的真 bug）。
只起本脚本自己的 MCP 临时实例 + holder 子进程，不动用户手开的主程序。
"""
import ctypes
from ctypes import wintypes
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]      # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP                        # noqa: E402

NAME = "文件解锁"
BUILD = ROOT.parent / ".build"                    # 仓库根的兄弟目录 .build
OUT = Path(__file__).resolve().parent / "selftest-result.txt"
HOLDER = Path(__file__).resolve().parent / "holder.ahk"
HOLDER_OUT = Path(__file__).resolve().parent / "holder-out.txt"

_user32 = ctypes.windll.user32
_kernel32 = ctypes.windll.kernel32
_kernel32.GlobalAlloc.restype = ctypes.c_void_p
_kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
_kernel32.GlobalLock.restype = ctypes.c_void_p
_kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
_kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
_user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
_user32.FindWindowW.restype = wintypes.HWND
_user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
_kernel32.CreateFileW.restype = wintypes.HANDLE
_kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
_kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def find_script_id(m):
    listed = m.call("list_scripts")
    for s in listed.get("scripts", []):
        if NAME in s.get("name", ""):
            return s.get("id") or s.get("name")
    raise AssertionError("脚本未出现在 list_scripts：先复制到 .build/Scripts")


def test_selftest(m, sid):
    OUT.unlink(missing_ok=True)
    run = m.call("run_script", {"script": sid, "args": ["--selftest", str(OUT)]})
    assert run.get("ok") and run.get("rc") == 0, f"selftest 运行失败: {run}"
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("NtPath 盘符前缀", "NtPath UNC 前缀", "FPIF 找出占用本文件的进程 PID",
               "删除保留名文件 con"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/5] selftest 全绿（NtPath / FPIF / 占用检测 / 删保留名）")


def read_ui(m, sess):
    return m.call("inspect_ui", {"session": sess, "items": True, "rows": 30})


def test_geometry(m, sess):
    ins = read_ui(m, sess)
    wins = ins.get("windows", [])
    assert wins, "inspect_ui 没找到窗口"
    w = wins[0]
    c = w.get("client", {})
    assert c.get("w") == 672 and c.get("h") == 352, f"窗口尺寸错: {c}"
    texts = " ".join((x.get("text", "") or "") for x in w.get("controls", []))
    assert "把文件或文件夹拖进列表" not in texts, "顶部说明行应已移除"
    assert "解除占用" in texts and "删除" in texts, "缺操作按钮"
    classes = [x.get("class", "") for x in w.get("controls", [])]
    assert any("ListView" in k for k in classes), "缺列表"
    assert "Edit" not in classes, "新形态不应有输入框"
    # 按钮宽 ≈ 文字宽 + 32（K25）：解除占用 84、删除 58（dpi=96）
    def cw(c):
        return (c.get("client") or {}).get("w")
    def cy(c):
        return (c.get("client") or {}).get("y")
    widths = {x.get("text"): cw(x) for x in w.get("controls", [])
              if x.get("text") in ("解除占用", "删除")}
    assert widths.get("解除占用", 0) in range(80, 92), f"解除占用按钮宽应≈84: {widths}"
    assert widths.get("删除", 0) in range(54, 66), f"删除按钮宽应≈58: {widths}"
    # 垂直节奏（§10.3.1-3）：操作行 288 → 状态条 322（BLOCK_GAP=6）→ 贴窗口底 352
    btn_y = [cy(x) for x in w.get("controls", []) if x.get("text") in ("解除占用", "删除")]
    assert btn_y and min(btn_y) in (288, 289), f"操作行 y 应≈288: {btn_y}"
    # 状态条在 y322；窗口高 352 = 322 + 30，无多余底部空白
    assert c.get("h") == 352, f"窗口高应=352（状态条贴底）: {c}"
    print("  [2/5] GUI 几何 672×352 + 列表/解除占用/删除按钮齐全（无输入框、无顶部说明行）")


def find_gui_hwnd():
    found = []

    def cb(h, l):
        n = _user32.GetWindowTextLengthW(h)
        if n:
            b = ctypes.create_unicode_buffer(n + 1)
            _user32.GetWindowTextW(h, b, n + 1)
            if b.value == NAME:
                found.append(h)
        return True

    PROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    _user32.EnumWindows(PROC(cb), 0)
    return found[0] if found else 0


def drop_files(hwnd, path):
    wide = (path + "\x00\x00").encode("utf-16-le")
    hg = _kernel32.GlobalAlloc(2, 20 + len(wide))
    ptr = _kernel32.GlobalLock(hg)
    header = (20).to_bytes(4, "little") + (0).to_bytes(4, "little") * 3 + (1).to_bytes(4, "little")
    ctypes.memmove(ptr, header, 20)
    ctypes.memmove(ptr + 20, wide, len(wide))
    _kernel32.GlobalUnlock(hg)
    assert _user32.PostMessageW(hwnd, 0x233, hg, 0), "WM_DROPFILES 投递失败"


def list_rows(m, sess):
    ins = read_ui(m, sess)
    for w in ins.get("windows", []):
        for ctl in w.get("controls", []):
            if "ListView" in ctl.get("class", ""):
                return ctl.get("items", {}).get("rows", [])
    return []


def test_drop_detect(m, sess):
    d = tempfile.mkdtemp(prefix="ahkdeck_unlock_test_")
    try:
        # nul 保留名文件：必须用 \\?\ 前缀经 CreateFileW 创建（普通 API 会解析成设备）
        nul = os.path.join(d, "nul")
        nt_nul = "\\\\?\\" + nul.replace("/", "\\")
        h = _kernel32.CreateFileW(nt_nul, 0x40000000, 0, None, 2, 0x80, None)
        assert h and h != ctypes.c_void_p(-1).value, "造 nul 样本失败"
        _kernel32.CloseHandle(h)

        hwnd = find_gui_hwnd()
        assert hwnd, "找不到文件解锁窗口"
        drop_files(hwnd, nul)
        time.sleep(1.5)
        rows = list_rows(m, sess)
        assert rows and any("nul" in str(r) and "无占用" in str(r) for r in rows), \
            f"nul 未显示无占用（可能误报占用进程）: {rows}"
        print("  [3/5] 拖入即检测：nul 保留名文件正确显示「无占用」")

        # holder 占用的普通文件
        demo = os.path.join(d, "locked.txt")
        with open(demo, "w", encoding="utf-8") as f:
            f.write("locked")
        HOLDER_OUT.unlink(missing_ok=True)
        holder = subprocess.Popen([str(BUILD / "AutoHotkey64.exe"), str(HOLDER), demo])
        try:
            time.sleep(1)
            drop_files(hwnd, demo)
            time.sleep(1.5)
            rows2 = list_rows(m, sess)
            assert rows2 and any("locked.txt" in str(r) and "AutoHotkey64.exe" in str(r)
                                 for r in rows2), f"占用文件未显示占用程序名: {rows2}"
            print("        占用项状态列直接显示占用程序名 AutoHotkey64.exe")
        finally:
            holder.terminate()
            try:
                holder.wait(timeout=3)
            except Exception:
                pass
            HOLDER_OUT.unlink(missing_ok=True)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_resize(m, sess):
    """缩放/最大化：列表吸收余量、路径列变宽、状态条贴底、按钮不被拉伸。"""
    _user32.MoveWindow.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_int, ctypes.c_int, wintypes.BOOL]
    hwnd = find_gui_hwnd()
    assert hwnd, "找不到文件解锁窗口"

    _user32.MoveWindow(hwnd, 80, 80, 920, 560, True)
    time.sleep(0.8)
    w = read_ui(m, sess)["windows"][0]
    c = w["client"]
    assert c["w"] > 800 and c["h"] > 480, f"放大未生效: {c}"
    ctrls = w.get("controls", [])
    lv = [x for x in ctrls if "ListView" in x.get("class", "")][0]
    assert lv["client"]["w"] > 750, f"列表未随宽度拉伸: {lv['client']}"

    def bottom_bar(controls, ch):
        # 状态条=贴底那一行中带文字的最宽控件（文案随流程变化，不能按内容找）
        cand = [x for x in controls
                if (x.get("text") or "").strip()
                and abs(x["client"]["y"] + x["client"]["h"] - ch) <= 1]
        return max(cand, key=lambda x: x["client"]["w"])["client"] if cand else None

    st = bottom_bar(ctrls, c["h"])
    assert st and abs(st["y"] + st["h"] - c["h"]) <= 1, f"状态条未贴底: {st} vs {c}"
    widths = {x.get("text"): (x.get("client") or {}).get("w") for x in ctrls
              if x.get("text") in ("解除占用", "删除")}
    assert widths.get("解除占用") in range(80, 92) and widths.get("删除") in range(54, 66), \
        f"缩放后按钮被拉伸: {widths}"

    _user32.ShowWindow(hwnd, 3)                 # SW_MAXIMIZE
    time.sleep(0.9)
    cm = read_ui(m, sess)["windows"][0]["client"]
    assert cm["w"] >= 900 and cm["h"] >= 560, f"最大化未生效: {cm}"
    ctrls_m = read_ui(m, sess)["windows"][0].get("controls", [])
    stm = [x for x in ctrls_m
           if (x.get("text") or "").strip()
           and abs(x["client"]["y"] + x["client"]["h"] - cm["h"]) <= 1]
    assert stm, f"最大化后找不到贴底状态条: {cm}"
    lv_m = [x for x in ctrls_m if "ListView" in x.get("class", "")][0]
    assert lv_m["client"]["w"] > 900, f"最大化后列表未拉伸: {lv_m['client']}"
    _user32.ShowWindow(hwnd, 9)                 # SW_RESTORE
    time.sleep(0.6)
    cr = read_ui(m, sess)["windows"][0]["client"]
    assert abs(cr["h"] - c["h"]) <= 2 and abs(cr["w"] - c["w"]) <= 2, f"还原尺寸不对: {cr} vs {c}"
    print("  [4/5] 缩放/最大化：列表吸收余量、状态条贴底、按钮不被拉伸")


def click_control(m, sess, text):
    """按控件文字点一下（inspect_ui 的 client 口径坐标）。"""
    ins = read_ui(m, sess)
    for w in ins.get("windows", []):
        for c in w.get("controls", []):
            if c.get("text") == text:
                cd = c["client"]
                return m.call("send_input", {"session": sess, "action": "click",
                                             "x": cd["x"] + cd["w"] // 2,
                                             "y": cd["y"] + cd["h"] // 2})
    raise AssertionError(f"找不到控件：{text}")


def test_unlock_flow(m, sess):
    """解除占用全链路：确认框投 IDYES，验证状态与列表翻新。"""
    d = tempfile.mkdtemp(prefix="ahkdeck_unlock_flow_")
    holder = None
    try:
        demo = os.path.join(d, "flow.txt")
        with open(demo, "w", encoding="utf-8") as f:
            f.write("flow")
        HOLDER_OUT.unlink(missing_ok=True)
        holder = subprocess.Popen([str(BUILD / "AutoHotkey64.exe"), str(HOLDER), demo])
        time.sleep(1)
        hwnd = find_gui_hwnd()
        drop_files(hwnd, demo)
        time.sleep(1.5)
        rows = list_rows(m, sess)
        assert any("flow.txt" in str(r) and "AutoHotkey64.exe" in str(r) for r in rows), \
            f"占用文件未显示占用程序名: {rows}"

        click_control(m, sess, "解除占用")
        time.sleep(1.2)
        dlg = _user32.FindWindowW("#32770", "文件解锁 · 确认解除")
        assert dlg, "确认框未出现（解除占用按钮回调没走到 MsgBox）"
        _user32.PostMessageW(wintypes.HWND(dlg), 0x111, 6, 0)   # WM_COMMAND IDYES
        time.sleep(2.0)

        rows = list_rows(m, sess)
        row = [r for r in rows if "flow.txt" in str(r)]
        assert row and "无占用" in str(row[0]), f"解除后仍显示占用: {row}"
        texts = [c.get("text", "") for w in read_ui(m, sess).get("windows", [])
                 for c in w.get("controls", [])]
        joined = " | ".join(t for t in texts if t)
        assert "解除完成" in joined, f"状态条未显示解除完成（可能又被当成取消）: {joined}"
        assert "已取消" not in joined, f"确认框的「是」被误判为取消: {joined}"
        print("  [5/5] 解除占用全链路：确认「是」→ 结束后状态翻回「无占用」")
    finally:
        if holder is not None and holder.poll() is None:
            holder.terminate()
        HOLDER_OUT.unlink(missing_ok=True)
        shutil.rmtree(d, ignore_errors=True)


def main():
    m = MCP()
    sess = None
    try:
        m.initialize()
        sid = find_script_id(m)
        test_selftest(m, sid)

        run = m.call("run_script", {"script": sid, "args": []})
        assert run.get("ok"), f"GUI 启动失败: {run}"
        sess = run.get("session")
        time.sleep(1)
        test_geometry(m, sess)
        test_drop_detect(m, sess)
        test_resize(m, sess)
        test_unlock_flow(m, sess)

        out = m.call("get_session_output", {"session": sess})
        assert not out.get("errors"), f"GUI 有运行时错误: {out.get('errors')}"
        print("ALL PASS")
        return 0
    finally:
        if sess:
            m.call("stop_script", {"session": sess})
        m.call("stop_all")
        m.close()


if __name__ == "__main__":
    sys.exit(main())
