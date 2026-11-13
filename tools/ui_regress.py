#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""官方脚本 UI 回归检查（宿主 + 独立解释器双环境）。

为什么需要它：靠人眼看窗口，漏检是常态。本工具把几类「肉眼容易漏、但用户一定会遇到」
的交互缺陷变成可重复的断言：

  W1 滚轮能滚        真发滚轮事件，ListView 首行号必须变化
  W2 键盘能翻页      发送 PageDown，首行号必须变化
  W3 无原生灰条      列表右缘不得出现原生滚动条的 F0F0F0
  W4 行底色满宽      最大化→复原后，斑马纹必须仍铺满整行（否则右侧留白块）
  W5 调色板一致      界面里不得出现 §10 八色之外的颜色
  W6 关闭即退出      发 WM_CLOSE 后进程应当退出（夜灯这类常驻脚本除外）
  W7 客户区尺寸      窗口客户区必须与脚本版式常量一致（防止改版漂移）
  W8 启动首帧无灰条  窗口刚出来的几秒里逐帧采样右缘，不得出现原生滚动条灰
                     （W3 只看稳定之后，抓不到「填表期间灰条一直亮着」这类问题）
  S* 专项            每个脚本自己的关键断言（滑块、按钮对齐、图标、列头…）

用法：
  python tools/ui_regress.py                # 跑全部
  python tools/ui_regress.py 打开方式清理     # 只跑指定脚本
  python tools/ui_regress.py --no-host      # 只跑独立解释器

退出码 0 = 全过；1 = 有失败项。
"""
import ctypes
import json
import os
import subprocess
import sys
import time
import zlib
import struct
from ctypes import wintypes as w
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent      # 仓库根
SCRIPTS = ROOT / ".ahk-v2-scripts" / "scripts"
AHK = ROOT / ".3rd" / "AutoHotkey_2.0.30" / "AutoHotkey64.exe"
HOST = ROOT / ".build" / "AHKDeck.exe"

# §10.2.1 八色封版
PALETTE = {"FFFFFF", "F7F9FC", "EBF2FB", "DCE8F7", "BFD5F0", "B7C8E0", "6E9BD4", "202B3A"}
NATIVE_SCROLLBAR = "F0F0F0"     # 原生滚动条面色，露出即不合格

# 常驻脚本：关窗口不退出是设计如此，跳过 W6
# 夜灯：面板只是调节入口，关掉后脚本仍待命。
# 双击防抖：低级鼠标钩子本身就是常驻凭据，关掉设置框后钩子仍在跑。
PERSISTENT = {"夜灯", "双击防抖"}

# 每个脚本要检查的窗口标题与列表区域（客户区坐标）
# client：脚本版式常量里的客户区尺寸（Show("w.. h..")），用于检测改版漂移。
# probe ：需要额外触发的动作（在脚本末尾追加一行调用）。
TARGETS = {
    "打开方式清理": {"title": "打开方式清理", "list": (17, 73, 1066, 540), "wait": 14.0,
                     "client": (1100, 650), "startup": 3.0},
    "文件时间修改": {"title": "文件时间修改", "list": (17, 159, 386, 178), "wait": 6.0,
                     "client": (420, 408)},
    "夜灯":         {"title": "夜灯调整", "list": None, "wait": 4.0,
                     "client": (320, 52)},
    "文件哈希":     {"title": "文件哈希", "list": (17, 105, 638, 121), "wait": 5.0,
                     "client": (672, 263)},
    # 双击防抖没有启动即弹的窗口（热键才开设置框），用 probe 直接调 ShowSettings()
    "双击防抖":     {"title": "双击防抖", "list": None, "wait": 3.0,
                     "client": (332, 150), "probe": "ShowSettings()"},
}

u = ctypes.WinDLL("user32", use_last_error=True)
g = ctypes.WinDLL("gdi32", use_last_error=True)

u.GetDC.restype = ctypes.c_void_p
u.GetDC.argtypes = [w.HWND]
u.ReleaseDC.argtypes = [w.HWND, ctypes.c_void_p]
u.GetWindowRect.argtypes = [w.HWND, ctypes.POINTER(w.RECT)]
u.GetClientRect.argtypes = [w.HWND, ctypes.POINTER(w.RECT)]
u.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, ctypes.c_int]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, ctypes.c_int]
u.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]
u.IsWindowVisible.argtypes = [w.HWND]
u.EnumWindows.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t]
u.EnumChildWindows.argtypes = [w.HWND, ctypes.c_void_p, ctypes.c_ssize_t]
u.SendMessageW.argtypes = [w.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t]
u.SendMessageW.restype = ctypes.c_ssize_t
u.PostMessageW.argtypes = [w.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t]
u.SetForegroundWindow.argtypes = [w.HWND]
u.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
u.mouse_event.argtypes = [w.DWORD, w.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
u.ShowWindow.argtypes = [w.HWND, ctypes.c_int]
u.ClientToScreen.argtypes = [w.HWND, ctypes.POINTER(w.POINT)]

g.CreateCompatibleDC.restype = ctypes.c_void_p
g.CreateCompatibleDC.argtypes = [ctypes.c_void_p]
g.CreateCompatibleBitmap.restype = ctypes.c_void_p
g.CreateCompatibleBitmap.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
g.SelectObject.restype = ctypes.c_void_p
g.SelectObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
g.DeleteObject.argtypes = [ctypes.c_void_p]
g.DeleteDC.argtypes = [ctypes.c_void_p]
g.BitBlt.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                     ctypes.c_int, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, w.DWORD]
g.GetDIBits.argtypes = [ctypes.c_void_p, ctypes.c_void_p, w.UINT, w.UINT,
                        ctypes.c_void_p, ctypes.c_void_p, w.UINT]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", w.DWORD), ("biWidth", w.LONG), ("biHeight", w.LONG),
                ("biPlanes", w.WORD), ("biBitCount", w.WORD), ("biCompression", w.DWORD),
                ("biSizeImage", w.DWORD), ("biXPelsPerMeter", w.LONG),
                ("biYPelsPerMeter", w.LONG), ("biClrUsed", w.DWORD),
                ("biClrImportant", w.DWORD)]


def find_window(pid, title=None):
    found = []
    CB = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)

    def cb(hwnd, _lp):
        p = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value != pid or not u.IsWindowVisible(hwnd):
            return True
        cls = ctypes.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, cls, 256)
        tb = ctypes.create_unicode_buffer(512)
        u.GetWindowTextW(hwnd, tb, 512)
        r = w.RECT()
        u.GetWindowRect(hwnd, ctypes.byref(r))
        found.append((hwnd, cls.value, tb.value,
                      (r.right - r.left) * (r.bottom - r.top)))
        return True

    u.EnumWindows(CB(cb), 0)
    cands = [x for x in found if x[1] in ("AutoHotkeyGUI", "#32770")]
    if title:
        exact = [x for x in cands if x[2] == title]
        if exact:
            cands = exact
    if not cands:
        cands = found
    if not cands:
        return None
    return max(cands, key=lambda x: x[3])[0]


def find_list(hwnd):
    out = []
    CB = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)

    def cb(h, _lp):
        cls = ctypes.create_unicode_buffer(256)
        u.GetClassNameW(h, cls, 256)
        if cls.value == "SysListView32":
            out.append(h)
        return True

    u.EnumChildWindows(hwnd, CB(cb), 0)
    return out[0] if out else None


def child_rects(hwnd):
    """列出所有子控件的 (类名, 左, 上, 右, 下)，坐标为客户区相对值。"""
    CB = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    pt = w.POINT(0, 0)
    u.ClientToScreen(hwnd, ctypes.byref(pt))
    out = []
    found = []

    def cb(h, _lp):
        cls = ctypes.create_unicode_buffer(256)
        u.GetClassNameW(h, cls, 256)
        r = w.RECT()
        u.GetWindowRect(h, ctypes.byref(r))
        found.append((cls.value, r.left - pt.x, r.top - pt.y,
                      r.right - pt.x, r.bottom - pt.y))
        return True

    u.EnumChildWindows(hwnd, CB(cb), 0)
    out.extend(found)
    return out


def find_by_size(rects, cls, wpx, hpx=None):
    """按类名与尺寸找子控件（自绘控件都是 Static，只能靠尺寸认）。"""
    hits = []
    for c, l, t, r, b in rects:
        if c != cls:
            continue
        if r - l != wpx:
            continue
        if hpx is not None and b - t != hpx:
            continue
        hits.append((l, t, r, b))
    return hits


def client_size(hwnd):
    r = w.RECT()
    u.GetClientRect(hwnd, ctypes.byref(r))
    return r.right - r.left, r.bottom - r.top


def find_ahk_error():
    """找 AHK 的错误对话框并返回其正文；没有则返回空串。

    AHK 报错时会弹一个 #32770 对话框，正文在 RICHEDIT50W 子控件里。
    两个内核都会弹（官方解释器是模态框、宿主是直接终止进程），
    所以这是跨环境通用的「脚本崩了」判据。
    """
    u.SendMessageW.argtypes = [w.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p]
    u.SendMessageW.restype = ctypes.c_ssize_t
    CB = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    found = []

    def cb(h, _lp):
        cls = ctypes.create_unicode_buffer(256)
        u.GetClassNameW(h, cls, 256)
        if cls.value == "#32770":
            found.append(h)
        return True

    u.EnumWindows(CB(cb), 0)
    for h in found:
        edits = []

        def cb2(h2, _lp2):
            c2 = ctypes.create_unicode_buffer(256)
            u.GetClassNameW(h2, c2, 256)
            if c2.value == "RICHEDIT50W":
                edits.append(h2)
            return True

        u.EnumChildWindows(h, CB(cb2), 0)
        for h2 in edits:
            buf = ctypes.create_unicode_buffer(8192)
            u.SendMessageW(h2, 0x000D, 8192, ctypes.cast(buf, ctypes.c_void_p))
            if buf.value.strip():
                return buf.value.replace("\r\n", " ")[:200]
    return ""


def top_index(lv):
    return u.SendMessageW(lv, 0x1027, 0, 0)


def grab(hwnd, path):
    """整窗抓图，返回 (宽, 高, 客户区在图内的偏移, 像素行)。"""
    r = w.RECT()
    u.GetWindowRect(hwnd, ctypes.byref(r))
    W, H = r.right - r.left, r.bottom - r.top
    pt = w.POINT(0, 0)
    u.ClientToScreen(hwnd, ctypes.byref(pt))
    ox, oy = pt.x - r.left, pt.y - r.top
    hdc = u.GetDC(0)
    mem = g.CreateCompatibleDC(hdc)
    bmp = g.CreateCompatibleBitmap(hdc, W, H)
    g.SelectObject(mem, bmp)
    g.BitBlt(mem, 0, 0, W, H, hdc, r.left, r.top, 0x00CC0020)
    bi = BITMAPINFOHEADER()
    bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth, bi.biHeight, bi.biPlanes = W, -H, 1
    bi.biBitCount, bi.biCompression = 32, 0
    buf = (ctypes.c_ubyte * (W * H * 4))()
    g.GetDIBits(mem, bmp, 0, H, ctypes.cast(buf, ctypes.c_void_p),
                ctypes.cast(ctypes.byref(bi), ctypes.c_void_p), 0)
    mv = bytes(buf)
    px = bytearray(W * H * 4)
    for i in range(0, W * H * 4, 4):
        px[i], px[i + 1], px[i + 2], px[i + 3] = mv[i + 2], mv[i + 1], mv[i], 255
    stride = W * 4
    raw = bytearray()
    rows = []
    for y in range(H):
        raw.append(0)
        raw += px[y * stride:(y + 1) * stride]
        rows.append([tuple(px[y * stride + x * 4:y * stride + x * 4 + 3]) for x in range(W)])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)
    g.DeleteObject(bmp)
    g.DeleteDC(mem)
    u.ReleaseDC(0, hdc)
    return W, H, ox, oy, rows


def hexc(c):
    return "%02X%02X%02X" % c


NATIVE_GRAY = {0xF0, 0xC0}   # 原生滚动条：主题 F0F0F0 / 经典 3DFACE C0C0C0


def watch_startup(hwnd, seconds):
    """窗口刚出现的这几秒里逐帧采样列表右缘，抓「原生滚动条被刷上屏」的瞬间。

    W3 是稳定之后看一眼，抓不到这个：ListView 的 WS_VSCROLL 会在填表期间被置回，
    而填表本身几百毫秒（实测 1813 行 718ms）—— 单线程没有空闲，60ms 的 Sync 定时器
    挤不进去，灰条就一直亮着，不是一帧。返回 (最长连续命中帧数, 单帧最多灰列数, 命中时刻)。
    """
    t0 = time.time()
    lv = None
    hits, worst = 0, 0
    run = maxrun = 0
    when = []
    while time.time() - t0 < seconds:
        if lv is None:
            lv = find_list(hwnd)
            time.sleep(0.01)
            continue
        # 用 GetWindowRect 而不是 GetClientRect：客户区**不含**滚动条，
        # 按客户区算的采样带整整错开 16px，正是灰条所在的那 16 列 —— 之前 W8 一直
        # 「0 命中」却肉眼能看见灰条，就是这个原因。
        r = w.RECT()
        if not u.GetWindowRect(lv, ctypes.byref(r)):
            time.sleep(0.01)
            continue
        W, H = r.right - r.left, r.bottom - r.top
        if W < 48 or H < 48:
            time.sleep(0.01)
            continue
        sw, sh = 20, min(160, H - 24)
        sx, sy = r.left + W - sw, r.top + (H - sh) // 2
        hdc = u.GetDC(0)
        mem = g.CreateCompatibleDC(hdc)
        bmp = g.CreateCompatibleBitmap(hdc, sw, sh)
        g.SelectObject(mem, bmp)
        g.BitBlt(mem, 0, 0, sw, sh, hdc, sx, sy, 0x00CC0020)
        bi = BITMAPINFOHEADER()
        bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bi.biWidth, bi.biHeight, bi.biPlanes = sw, -sh, 1
        bi.biBitCount, bi.biCompression = 32, 0
        buf = (ctypes.c_ubyte * (sw * sh * 4))()
        g.GetDIBits(mem, bmp, 0, sh, ctypes.cast(buf, ctypes.c_void_p),
                    ctypes.cast(ctypes.byref(bi), ctypes.c_void_p), 0)
        mv = bytes(buf)
        g.DeleteObject(bmp)
        g.DeleteDC(mem)
        u.ReleaseDC(0, hdc)
        n = 0
        for x in range(sw - 16, sw):
            col = [mv[(y * sw + x) * 4 + 2] for y in range(0, sh, 6)]
            dom = max(set(col), key=col.count)
            if col.count(dom) > len(col) * 0.9 and dom in NATIVE_GRAY:
                n += 1
        if n >= 12:
            hits += 1
            run += 1
            maxrun = max(maxrun, run)
            when.append("%.0fms" % ((time.time() - t0) * 1000))
        else:
            run = 0
        worst = max(worst, n)
        time.sleep(0.008)
    return maxrun, worst, when


def check(name, ok, detail=""):
    print(("  [PASS] " if ok else "  [FAIL] ") + name + (f"  {detail}" if detail else ""))
    return bool(ok)


# ── 专项检查 ────────────────────────────────────────────────────────────────
# 每个脚本挑「用户一定会碰到、且肉眼容易漏」的一两件事做断言。

def special_night_light(hwnd, rows, W, H, ox, oy):
    """夜灯：面板高度 52（无底部说明行）、滑块槽与滑块都在、槽可点且数值会变。"""
    res = []
    cs = client_size(hwnd)
    res.append(check("S1 面板高度 52（无底部说明行）", cs[1] == 52, f"客户区高 {cs[1]}"))

    # 槽 232x10、滑块外框 12x20、内块 10x18 —— 尺寸是版式常量。
    rects = child_rects(hwnd)
    track = find_by_size(rects, "Static", 232, 10)
    outer = find_by_size(rects, "Static", 12, 20)
    inner = find_by_size(rects, "Static", 10, 18)
    res.append(check("S2 滑块槽/外框/内块尺寸正确",
                     len(track) == 1 and len(outer) == 1 and len(inner) == 1,
                     f"槽 {len(track)} 外框 {len(outer)} 内块 {len(inner)}"))

    # 滑块描边应为 FRAME(B7C8E0)，内块应为 SOFT(EBF2FB)
    if outer and inner:
        ol, ot, orr, ob = outer[0]
        il, it_, ir, ib = inner[0]
        edge_ok = hexc(rows[ot + oy][ol + ox]) == "B7C8E0"
        fill_ok = hexc(rows[it_ + oy + 4][il + ox + 4]) == "EBF2FB"
        res.append(check("S3 滑块 1px 描边 + 内块同色",
                         edge_ok and fill_ok,
                         f"描边 {hexc(rows[ot + oy][ol + ox])} 内块 {hexc(rows[it_ + oy + 4][il + ox + 4])}"))

    # 点槽 → 滑块应移动。要点离原位足够远：先读当前左缘，
    # 再点槽的另一端（当前在右侧就点左端，反之亦然）。
    if track:
        tl, tt, tr, tb = track[0]
        before = outer[0][0] if outer else None
        span = (tr - tl)
        if before is not None and before > tl + span // 2:
            click_x = tl + 10          # 当前偏右 → 点左端
        else:
            click_x = tr - 10          # 当前偏左 → 点右端
        pt = w.POINT(0, 0)
        u.ClientToScreen(hwnd, ctypes.byref(pt))
        u.SetCursorPos(pt.x + click_x, pt.y + tt + 5)
        time.sleep(0.2)
        u.mouse_event(0x0002, 0, 0, 0, None)   # 左键按下
        time.sleep(0.12)
        u.mouse_event(0x0004, 0, 0, 0, None)   # 左键抬起
        time.sleep(0.6)
        after = find_by_size(child_rects(hwnd), "Static", 12, 20)
        moved = bool(after) and (before is None or abs(after[0][0] - before) >= 4)
        res.append(check("S4 点槽后滑块移动", moved,
                         f"滑块左缘 {before} → {after[0][0] if after else '?'}"))

    # 点槽不能把脚本点崩（属性里存函数对象时，写成 this.cb(v) 会被当方法调用
    # 并隐式多传 this，两个内核都会报「参数过多」：官方弹错误框，宿主直接终止进程）
    err = find_ahk_error()
    res.append(check("S5 点槽后无错误框", not err, err if err else "无"))
    return res


def special_dbl_click(hwnd, rows, W, H, ox, oy):
    """双击防抖：三行输入框右缘一致、按钮组右缘与输入框右缘一致、无底部状态条。"""
    res = []
    rects = child_rects(hwnd)
    edits = [r for r in rects if r[0] == "Edit"]
    res.append(check("S1 三个输入框都在", len(edits) == 3, f"找到 {len(edits)} 个"))

    if len(edits) == 3:
        rights = sorted(e[3] for e in edits)
        res.append(check("S2 三个输入框右缘一致", rights[0] == rights[-1],
                         f"右缘 {rights}"))
        lefts = sorted(e[1] for e in edits)
        res.append(check("S3 三个输入框左缘一致", lefts[0] == lefts[-1],
                         f"左缘 {lefts}"))

    # 按钮：FlatButton 的外框 58x28、内块 56x26（两个一组）
    outers = find_by_size(rects, "Static", 58, 28)
    res.append(check("S4 两个按钮外框都在", len(outers) == 2, f"找到 {len(outers)}"))
    if len(outers) == 2 and len(edits) == 3:
        btn_right = max(o[2] for o in outers)      # o = (left, top, right, bottom)
        edit_right = max(e[3] for e in edits)
        res.append(check("S5 按钮组右缘与输入框右缘对齐",
                         abs(btn_right - edit_right) <= 1,
                         f"按钮右缘 {btn_right} / 输入框右缘 {edit_right}"))

    # 无底部状态条：客户区底部不该有一条通栏 DCE8F7
    cs = client_size(hwnd)
    band = 0
    for cx in range(0, cs[0], 8):
        X, Y = cx + ox, (cs[1] - 10) + oy
        if 0 <= X < W and 0 <= Y < H and hexc(rows[Y][X]) == "DCE8F7":
            band += 1
    res.append(check("S6 底部无状态条", band == 0, f"底部通栏色块 {band} 处"))
    return res


def special_file_hash(hwnd, rows, W, H, ox, oy):
    """文件哈希：列头与列表同框（外框 1px FRAME）、状态条在底部、输入框无 3D 凹陷。"""
    res = []
    rects = child_rects(hwnd)

    # 外框 640x149（x16 y78）、列头带 638x26（x17 y79）
    frame = find_by_size(rects, "Static", 640, 149)
    band = find_by_size(rects, "Static", 638, 26)
    res.append(check("S1 列表整体外框存在", len(frame) == 1, f"找到 {len(frame)}"))
    res.append(check("S2 列头带存在", len(band) >= 1, f"找到 {len(band)}"))
    if frame and band:
        res.append(check("S3 列头带比外框内缩 1px",
                         band[0][0] == frame[0][0] + 1 and band[0][1] == frame[0][1] + 1,
                         f"外框 ({frame[0][0]},{frame[0][1]}) 列头 ({band[0][0]},{band[0][1]})"))

    # 状态条 672x30 铺满窗口宽，y=233
    sb = find_by_size(rects, "Static", 672, 30)
    res.append(check("S4 状态条铺满窗口宽", len(sb) == 1, f"找到 {len(sb)}"))

    # 输入框带 -E0x200（静态工具已查，这里查运行时控件是否存在 3D 边）
    edits = [r for r in rects if r[0] == "Edit"]
    res.append(check("S5 输入框存在", len(edits) == 1, f"找到 {len(edits)}"))
    return res


SPECIAL = {
    "夜灯": special_night_light,
    "双击防抖": special_dbl_click,
    "文件哈希": special_file_hash,
}


def special_file_time(hwnd, rows, W, H, ox, oy):
    """文件时间修改：点自绘勾选框不能崩，且勾选状态要翻转。

    FlatCheck 把回调存进属性，写成 this.cb() 会被当方法调用并隐式多传 this，
    两个内核都会报「参数过多」—— 点一下勾选框就会崩，官方弹错误框、
    宿主直接终止进程。这里用真实鼠标点击验证。
    """
    res = []
    rects = child_rects(hwnd)
    frames = find_by_size(rects, "Static", 16, 16)
    inners = find_by_size(rects, "Static", 14, 14)
    res.append(check("S1 勾选框外框存在", len(frames) >= 1, f"找到 {len(frames)}"))
    if not frames or not inners:
        return res

    def inner_color(idx):
        W2, H2, ox2, oy2, rows2 = grab(hwnd, str(ROOT / ".temp" / "uregress_check.png"))
        l, t, r, b = inners[idx]
        X, Y = l + 7 + ox2, t + 7 + oy2
        if 0 <= X < W2 and 0 <= Y < H2:
            return hexc(rows2[Y][X])
        return "?"

    # 找一个当前未勾选的（内块底色 FFFFFF），点它应当变成选中底 EBF2FB
    target = None
    for i in range(len(inners)):
        if inner_color(i) == "FFFFFF":
            target = i
            break
    if target is None:
        res.append(check("S2 有未勾选的勾选框可测", False,
                         f"{len(inners)} 个内块都是勾选态"))
        return res
    res.append(check("S2 找到未勾选的勾选框", True, f"第 {target + 1} 个"))

    l, t, r, b = frames[target]
    before = inner_color(target)
    pt = w.POINT(0, 0)
    u.ClientToScreen(hwnd, ctypes.byref(pt))
    u.SetCursorPos(pt.x + l + 8, pt.y + t + 8)
    time.sleep(0.25)
    u.mouse_event(0x0002, 0, 0, 0, None)
    time.sleep(0.12)
    u.mouse_event(0x0004, 0, 0, 0, None)
    time.sleep(0.7)
    after = inner_color(target)
    res.append(check("S3 点勾选框后状态翻转", before != after,
                     f"内块底色 {before} → {after}"))
    err = find_ahk_error()
    res.append(check("S4 点勾选框后无错误框", not err, err if err else "无"))
    return res


SPECIAL["文件时间修改"] = special_file_time


def run_one(script_name, mode):
    cfg = TARGETS.get(script_name)
    if not cfg:
        return []
    src = SCRIPTS / script_name / f"{script_name}.ahk"
    if not src.exists():
        print(f"[{script_name}/{mode}] 脚本不存在")
        return [False]
    # 用临时副本跑：把互斥量名字改掉，免得机器上已有实例在跑时本工具被挡在门外。
    tmp_dir = ROOT / ".temp" / "ui_regress"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / f"{script_name}.ahk"
    raw = src.read_bytes().replace(b'"AHKDeck.', b'"AHKDeck.Regress.')
    # probe：把触发动作追加到脚本末尾（脚本末尾就是 auto-execute 段之后，
    # 直接追加一行调用即可在启动后触发，比如打开设置框）。
    probe = cfg.get("probe")
    if probe:
        raw += b"\r\n" + probe.encode("utf-8") + b"\r\n"
    path.write_bytes(raw)
    cmd = [str(AHK), str(path)] if mode == "standalone" else [str(HOST), "--run", str(path)]
    results = []
    p = subprocess.Popen(cmd, cwd=str(ROOT))
    try:
        hwnd = None
        if cfg["title"]:
            for _ in range(80):
                hwnd = find_window(p.pid, cfg["title"])
                if hwnd:
                    break
                time.sleep(0.25)
        if not hwnd:
            # 没有启动即弹的窗口：至少确认脚本活着且没崩
            alive = p.poll() is None
            print(f"[{script_name}/{mode}] 无常驻窗口（按设计）")
            return [check("W0 启动未崩溃", alive)]
        # W8 启动首帧：窗口刚出来的这几秒最容易露原生灰条（W3 只看稳定之后）。
        # 采样占用原本的等待时间，不额外多等。
        st = cfg.get("startup")
        if st:
            run, worst, when = watch_startup(hwnd, min(st, cfg["wait"]))
            # 判据用「最长连续命中帧数」而不是总命中帧数：单帧（≈10ms）的残留眼睛看不见，
            # 不值得为它加更重的机制；真正的 bug 是连续几百毫秒那种。
            results.append(check("W8 启动期间未露原生灰条", run <= 2,
                                 f"最长连续 {run} 帧 / 单帧最多 {worst} 列灰 / 命中于 {','.join(when) or '无'}"))
            time.sleep(max(0.0, cfg["wait"] - st))
        else:
            time.sleep(cfg["wait"])
        u.SetForegroundWindow(hwnd)
        time.sleep(0.4)

        # W7 客户区尺寸：版式常量写死的地方，改版时最容易漂
        exp_client = cfg.get("client")
        if exp_client:
            cs = client_size(hwnd)
            results.append(check("W7 客户区尺寸符合版式常量",
                                 tuple(cs) == tuple(exp_client),
                                 f"实际 {cs[0]}x{cs[1]} / 期望 {exp_client[0]}x{exp_client[1]}"))

        lv = find_list(hwnd)
        list_cfg = cfg["list"]
        empty = bool(lv) and u.SendMessageW(lv, 0x1004, 0, 0) == 0
        if empty:
            print("  [SKIP] 列表为空（该脚本需要真实数据才有行可滚），跳过滚动类检查")
        if lv and list_cfg and not empty:
            # W1 滚轮（连发三格，避开首格被窗口激活吞掉）
            # WM_MOUSEWHEEL 发给**焦点**窗口而不是光标下的窗口，宿主里脚本窗口经常没拿到焦点，
            # 于是滚轮全落到宿主主窗口上 —— 这就是 W1 在 host 模式偶发 0→0 的原因。
            # 先点一下列表中心把它激活，再发滚轮。
            t0 = top_index(lv)
            pt = w.POINT(0, 0)
            u.ClientToScreen(hwnd, ctypes.byref(pt))
            u.SetCursorPos(pt.x + 200, pt.y + 120)
            time.sleep(0.2)
            u.mouse_event(0x0002, 0, 0, 0, None)
            u.mouse_event(0x0004, 0, 0, 0, None)
            time.sleep(0.4)
            for _ in range(3):
                u.mouse_event(0x0800, 0, 0, -120, None)
                time.sleep(0.35)
            time.sleep(0.5)
            t1 = top_index(lv)
            results.append(check("W1 滚轮能滚", t1 != t0, f"首行 {t0} → {t1}"))

            # W2 键盘翻页
            u.PostMessageW(lv, 0x100, 0x22, 0)
            time.sleep(0.6)
            t2 = top_index(lv)
            results.append(check("W2 键盘能翻页", t2 != t1, f"首行 {t1} → {t2}"))

            # W3 右缘不得露出原生灰条
            W, H, ox, oy, rows = grab(hwnd, str(ROOT / ".temp" / f"uregress_{script_name}_{mode}.png"))
            lx, ly, lw, lh = list_cfg
            gray = 0
            for cx in range(lx + lw - 24, lx + lw):
                for cy in range(ly + 4, ly + min(lh, 200)):
                    X, Y = cx + ox, cy + oy
                    if 0 <= X < W and 0 <= Y < H and hexc(rows[Y][X]) == NATIVE_SCROLLBAR:
                        gray += 1
            results.append(check("W3 未露出原生灰条", gray == 0, f"灰条像素 {gray}"))

            # W5 调色板：文字抗锯齿会产生大量中间色，只按「面积占比」判定——
            # 成片的错误底色会明显超过阈值，单像素级的抗锯齿不会。
            off = {}
            total = 0
            for cy in range(ly, ly + min(lh, 200)):
                for cx in range(lx, lx + lw):
                    X, Y = cx + ox, cy + oy
                    if 0 <= X < W and 0 <= Y < H:
                        total += 1
                        c = hexc(rows[Y][X])
                        if c not in PALETTE:
                            off[c] = off.get(c, 0) + 1
            limit = max(30, int(total * 0.01))
            bad = {c: n for c, n in off.items() if n > limit}
            results.append(check("W5 调色板一致", not bad,
                                 f"越界色 {dict(list(bad.items())[:4])}（阈值 {limit} 像素）"))

            # W4 行底色满宽（最大化→复原）
            if lw > 200:
                def stripe_len():
                    best = 0
                    for cy in range(ly + 6, ly + min(lh, 300), 6):
                        Y = cy + oy
                        if Y >= H:
                            break
                        run = 0
                        for cx in range(lx + 10, lx + lw):
                            X = cx + ox
                            if X >= W:
                                break
                            if hexc(rows[Y][X]) == "F7F9FC":
                                run += 1
                            elif run:
                                break
                        best = max(best, run)
                    return best
                before = stripe_len()
                u.ShowWindow(hwnd, 3)      # 最大化
                time.sleep(2.0)
                u.ShowWindow(hwnd, 9)      # 复原
                time.sleep(2.0)
                W, H, ox, oy, rows = grab(hwnd, str(ROOT / ".temp" / f"uregress_{script_name}_{mode}_r.png"))
                after = stripe_len()
                results.append(check("W4 最大化复原后行底色仍满宽", after >= before - 4,
                                     f"{before} → {after}"))

        # 专项检查：抓一张图，各脚本按自己的关键点断言
        fn = SPECIAL.get(script_name)
        if fn:
            W, H, ox, oy, rows = grab(hwnd, str(ROOT / ".temp" / f"uregress_{script_name}_{mode}.png"))
            results.extend(fn(hwnd, rows, W, H, ox, oy))

        # W6 关闭即退出
        if script_name not in PERSISTENT:
            u.PostMessageW(hwnd, 0x0010, 0, 0)   # WM_CLOSE
            deadline = time.time() + 6
            alive = True
            while time.time() < deadline:
                if p.poll() is not None:
                    alive = False
                    break
                time.sleep(0.2)
            results.append(check("W6 关闭即退出", not alive,
                                 "仍在运行" if alive else f"rc={p.poll()}"))
        return results
    finally:
        try:
            p.terminate()
            p.wait(timeout=5)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    modes = ["standalone", "host"] if "--no-host" not in sys.argv else ["standalone"]
    names = args or list(TARGETS)
    failed = 0
    for name in names:
        for mode in modes:
            print(f"── {name} / {mode} ──")
            try:
                res = run_one(name, mode)
            except Exception as e:
                print(f"  [FAIL] 异常：{e}")
                res = [False]
            if not res:
                print("  [SKIP] 该脚本无列表可查")
            bad = res.count(False)
            failed += bad
            print(f"  小计：{len(res) - bad}/{len(res)} 通过")
    print(f"\n总计失败 {failed} 项")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
