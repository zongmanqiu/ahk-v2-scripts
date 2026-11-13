#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""官方脚本 UI 静态门禁（只读源码，不运行脚本）。

为什么需要它：视觉回归工具（ui_regress.py）要拉起窗口、跑几分钟，很多问题
在「代码还没跑起来」时就能一眼看出来 —— 比如写错了色值、忘了同步版本号、
引入了第二套字号。这类问题不必等实机复现才拦。

检查项：
  S1 头部元数据齐全    @name/@version/@description/@author/@license/@date 等
  S2 版本号已提升      与 HISTORY 首段、README 表格、scripts.json 一致
  S3 调色板不越界      只允许 §10.2.1 八色；不得出现自造色
  S4 字号不越档        只允许 s9/s10/s11/s12，且 s11 只给勾形、s12 只给大窗标题
  S5 字体唯一          SetFont 必须带 "Microsoft YaHei UI"
  S6 无系统控件残留    不得出现系统 Button / StatusBar / Slider / CheckBox
  S7 无 3D 凹陷        ListView/Edit 必须带 -E0x200
  S8 换行不混用      同一文件内不得 CRLF 与 LF 混写（跨文件可不同，git 提交时统一转 LF）
  S9 无旧版残留      不得出现已废弃的写法（-VScroll 隐藏滚动条等）
  S10 出货件一致     .build/Scripts/<名>.ahk 必须与仓库件逐字节相同

用法：
  python tools/ui_static.py                 # 跑全部
  python tools/ui_static.py 夜灯 双击防抖    # 只跑指定脚本

退出码 0 = 全过；1 = 有失败项。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPTS = ROOT / ".ahk-v2-scripts" / "scripts"
REPO = ROOT / ".ahk-v2-scripts"

# §10.2.1 八色封版
PALETTE = {"FFFFFF", "F7F9FC", "EBF2FB", "DCE8F7", "BFD5F0", "B7C8E0", "6E9BD4", "202B3A"}
# 允许出现在代码里的其它字面 6 位色：仅 DWM 的 COLORREF 常量与 Windows 系统色名
ALLOWED_EXCEPTIONS = {
    "00F7E8DC",   # #DCE8F7 的 COLORREF（0x00BBGGRR）
    "3A2B20",     # #202B3A 的 COLORREF
}

# 字号档位：s10 基准、s9 辅助、s11 只给勾形 ✓、s12 只给 672+ 大窗区块标题
ALLOWED_FONTS = {"s9", "s10", "s11", "s12"}

# 头部必须存在的字段
REQUIRED_KEYS = ["@name", "@version", "@description", "@author", "@date", "@license"]

# 禁止出现的系统控件（§10.5：全部改自绘）
FORBIDDEN_CTRL = [
    (r'\.Add\(\s*"Button"', "系统 Button 未换成 FlatButton"),
    (r'\.Add\(\s*"StatusBar"', "系统 StatusBar 未换成色块状态条"),
    (r'\.Add\(\s*"Slider"', "系统 Slider 未换成自绘 FlatTrack"),
    (r'\.Add\(\s*"CheckBox"', "系统 CheckBox 未换成自绘 FlatCheck"),
]

# 禁止出现的旧写法
FORBIDDEN_PATTERNS = [
    (r'\bMarginX\b|\bMarginY\b', "MarginX/MarginY 自动撑高（§10.3 要求固定客户区）"),
    (r'\bAutoSize\b', "AutoSize 自动撑高（§10.3 要求固定客户区）"),
    (r'ShowScrollBar\s*\([^)]*,\s*(TRUE|1)\s*\)', "重新显示原生滚动条"),
    (r'SetWindowTheme', "SetWindowTheme 假装扁平（K2 已证无效）"),
]

# 纯托盘脚本（无可见 GUI）允许 Persistent(true)；有可见 GUI 的脚本不允许
# —— 那种情况应当「关窗即退出」，靠窗口本身维持存活（§4 关闭口径）。
TRAY_ONLY = {"防休眠", "夜灯"}


def script_path(name):
    return SCRIPTS / name / f"{name}.ahk"


def read_head_block(text):
    """取 ==UserScript== 块。"""
    m = re.search(r";\s*==UserScript==(.*?);\s*==/UserScript==", text, re.S)
    return m.group(1) if m else ""


def check(name, ok, detail=""):
    print(("  [PASS] " if ok else "  [FAIL] ") + name + (f"  {detail}" if detail else ""))
    return bool(ok)


def collect_colors(text):
    """扫出所有 6 位十六进制色字面量（含 Background/c 参数与引号内字符串）。"""
    found = {}
    # Background 后紧跟的色
    for m in re.finditer(r'Background([0-9A-Fa-f]{6})', text):
        found[m.group(1).upper()] = found.get(m.group(1).upper(), 0) + 1
    # c 前置色（c202B3A 形式）
    for m in re.finditer(r'\bc([0-9A-Fa-f]{6})\b', text):
        found[m.group(1).upper()] = found.get(m.group(1).upper(), 0) + 1
    # 引号内的六位色
    for m in re.finditer(r'"([0-9A-Fa-f]{6})"', text):
        found[m.group(1).upper()] = found.get(m.group(1).upper(), 0) + 1
    return found


def check_script(name):
    path = script_path(name)
    if not path.exists():
        return [check("S0 脚本存在", False, str(path))]
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    res = []

    # S1 头部元数据
    head = read_head_block(text)
    missing = [k for k in REQUIRED_KEYS if not re.search(r';\s*' + re.escape(k) + r'\s+\S', head)]
    res.append(check("S1 头部元数据齐全", head and not missing,
                     f"缺 {missing}" if missing else f"{len(REQUIRED_KEYS)} 项齐全"))

    # S2 版本号一致
    m = re.search(r';\s*@version\s+(\S+)', head)
    ver = m.group(1) if m else ""
    hist = (SCRIPTS / name / "info" / "HISTORY.md")
    hist_text = hist.read_text(encoding="utf-8") if hist.exists() else ""
    hm = re.search(r'^##\s*([0-9.]+)', hist_text, re.M)
    hist_ver = hm.group(1) if hm else ""
    readme = (REPO / "README.md")
    readme_text = readme.read_text(encoding="utf-8") if readme.exists() else ""
    rm = re.search(r'\|\s*\[' + re.escape(name) + r'\]\([^)]*\)\s*\|\s*([0-9.]+)\s*\|', readme_text)
    readme_ver = rm.group(1) if rm else ""
    idx_path = REPO / "scripts.json"
    idx_ver = ""
    if idx_path.exists():
        try:
            data = json.loads(idx_path.read_text(encoding="utf-8"))
            items = data.get("scripts", []) if isinstance(data, dict) else data
            for it in items:
                if isinstance(it, dict) and it.get("name") == name:
                    idx_ver = str(it.get("version", ""))
        except Exception:
            pass
    ok_ver = bool(ver) and ver == hist_ver and (not readme_ver or ver == readme_ver) and (not idx_ver or ver == idx_ver)
    res.append(check("S2 版本号四处一致", ok_ver,
                     f"头部={ver} HISTORY={hist_ver} README={readme_ver or '(无)'} scripts.json={idx_ver or '(无)'}"))

    # S3 调色板不越界
    colors = collect_colors(text)
    off = {c: n for c, n in colors.items()
           if c not in PALETTE and c not in ALLOWED_EXCEPTIONS}
    res.append(check("S3 调色板不越界", not off,
                     f"越界色 {off}" if off else f"{len(colors)} 种色值全在八色内"))

    # S4 字号不越档
    fonts = set()
    for mm in re.finditer(r'"(s\d+)(?:\s+\w+)?"', text):
        fonts.add(mm.group(1))
    off_f = fonts - ALLOWED_FONTS
    res.append(check("S4 字号不越档", not off_f,
                     f"越档字号 {sorted(off_f)}" if off_f else f"用到 {sorted(fonts)}"))

    # S5 字体统一：SetFont 的第二个参数是字体名。允许「只写字号」（沿用当前字体）
    # 与「字号 + Microsoft YaHei UI」两种写法；不允许出现别的字体名。
    setfonts = re.findall(r'SetFont\(\s*"([^"]*)"\s*(?:,\s*"([^"]*)")?', text)
    bad_font = []
    for size, face in setfonts:
        if face and face != "Microsoft YaHei UI":
            bad_font.append(f"{size}/{face}")
    res.append(check("S5 字体统一 Microsoft YaHei UI", not bad_font,
                     f"异常 {bad_font}" if bad_font
                     else f"{len(setfonts)} 处 SetFont（无异体字体）"))

    # S6 无系统控件残留
    hits = []
    for pat, why in FORBIDDEN_CTRL:
        for mm in re.finditer(pat, text):
            line = text[:mm.start()].count("\n") + 1
            hits.append(f"L{line} {why}")
    res.append(check("S6 无系统控件残留", not hits,
                     "; ".join(hits[:3]) if hits else "无"))

    # S7 ListView/Edit 必须去 3D 凹陷
    # 选项串常被拼成多段（"x16 y16" w " w400"），且可能跨行；
    # 做法：取该 Add 调用的完整参数区（到右括号为止），去掉所有字符串里的
    # 引号后拼起来再判。只在「可见窗口」里要求 —— --report/--selftest
    # 分支建的是隐藏的辅助列表，本来就不显示，不需要去凹陷。
    lv_detail = []
    for mm in re.finditer(r'\.Add\(\s*"(ListView|Edit)"\s*,', text):
        kind = mm.group(1)
        # 从 Add( 起扫到配对的右括号，把途经的所有字符串字面量收集起来
        i = mm.start()
        depth = 0
        seg = []
        while i < len(text):
            c = text[i]
            if c == '"':
                # 收下这一段字面量（AHK 里 "" 表示字符串内的引号）
                j = i + 1
                while j < len(text):
                    if text[j] == '"':
                        if j + 1 < len(text) and text[j + 1] == '"':
                            j += 2
                            continue
                        break
                    j += 1
                seg.append(text[i + 1:j])
                i = j + 1
                continue
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        opts = "".join(seg)
        # "-E0x200" 只可能出现在控件选项串里（类型段是 ListView / Edit），
        # 直接在拼好的字面量里判即可，不必再切逗号（分隔逗号在字符串外，
        # 上面扫描时已被跳过）。
        if "-E0x200" in opts:
            continue
        # 豁免隐藏窗口：--report / --selftest 分支建的是 Show("Hide") 的辅助
        # 列表，只做逻辑演练，从不显示，不需要去凹陷。
        ctx = text[max(0, mm.start() - 400): mm.start() + 600]
        if 'Show("Hide")' in ctx or "Show('Hide')" in ctx:
            continue
        lv_detail.append(f"{kind} 缺 -E0x200")
    res.append(check("S7 原生控件已去 3D 凹陷", not lv_detail,
                     "; ".join(lv_detail[:3]) if lv_detail else "全部带 -E0x200"))

    # S8 换行不混用：同一文件内要么全 CRLF，要么全 LF。
    # 跨文件可以不同（仓库 .gitattributes 是 eol=lf，git 提交时统一转换），
    # 但同一个文件里混着写会让 diff 出现整段空白变更，必须挡住。
    crlf = raw.count(b"\r\n")
    lf = raw.count(b"\n")
    bare_lf = lf - crlf
    mixed = crlf > 0 and bare_lf > 0
    res.append(check("S8 换行不混用", not mixed,
                     f"CRLF={crlf} 裸LF={bare_lf}（混写）" if mixed
                     else f"CRLF={crlf} 裸LF={bare_lf}"))

    # S9 无旧版残留
    stale = []
    for pat, why in FORBIDDEN_PATTERNS:
        for mm in re.finditer(pat, text):
            line = text[:mm.start()].count("\n") + 1
            ctx = text.splitlines()[line - 1].strip()
            # 注释行不算
            if ctx.startswith(";") or ctx.startswith("#"):
                continue
            stale.append(f"L{line} {why}")
    # 有可见 GUI 的脚本不得 Persistent(true)：那种情况应当「关窗即退出」，
    # 靠窗口本身维持存活；纯托盘脚本才需要显式声明常驻。
    if name not in TRAY_ONLY and re.search(r'Persistent\s*\(\s*true\s*\)', text):
        stale.append("有可见 GUI 却 Persistent(true)（应当关窗即退出）")

    # K32：属性里存了回调（函数对象）后直接调用，会被当成「方法」调用并隐式多传
    # this，一点就崩（官方弹错误框、宿主终止进程）。必须显式 .Call(...)。
    # 判定方式：找出所有「属性 := 回调形参」的位置，记下属性名，
    # 再检查该属性有没有以 this.<属性>( 直接调用（而不是 .Call(）。
    cb_props = set()
    for mm in re.finditer(r'this\.([A-Za-z_]\w*)\s*:=\s*(cb|on[A-Z]\w*|callback)\b', text):
        cb_props.add(mm.group(1))
    for mm in re.finditer(r'this\.([A-Za-z_]\w*)\s*:=\s*\w+', text):
        # 也覆盖 this.cb := someFunc 这种直接赋函数名
        rhs = text[mm.end():mm.end() + 40]
        if re.match(r'\s*[A-Z]\w*\s*$', rhs) or re.match(r'\s*\(\w*\)\s*=>', rhs):
            cb_props.add(mm.group(1))
    for prop in sorted(cb_props):
        for mm in re.finditer(r'this\.' + re.escape(prop) + r'\s*\(', text):
            line = text[:mm.start()].count("\n") + 1
            ctx = text.splitlines()[line - 1].strip()
            if ctx.startswith(";") or ctx.startswith("#"):
                continue
            stale.append(f"L{line} this.{prop}(...) 直接调用回调属性（应写 .Call(...)）")

    res.append(check("S9 无旧版残留写法", not stale,
                     "; ".join(stale[:3]) if stale else "无"))

    # S10 出货件一致
    shipped = ROOT / ".build" / "Scripts" / f"{name}.ahk"
    if shipped.exists():
        same = shipped.read_bytes() == raw
        res.append(check("S10 出货件与仓库件一致", same,
                         "逐字节相同" if same else
                         f"出货件 {len(shipped.read_bytes())} 字节 ≠ 仓库件 {len(raw)} 字节"))
    else:
        res.append(check("S10 出货件与仓库件一致", False, f"缺 {shipped}"))

    return res


def main():
    names = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not names:
        names = sorted(p.parent.name for p in SCRIPTS.glob("*/[!_]*.ahk"))
    failed = 0
    for name in names:
        print(f"── {name} ──")
        try:
            res = check_script(name)
        except Exception as e:
            print(f"  [FAIL] 异常：{e}")
            res = [False]
        bad = res.count(False)
        failed += bad
        print(f"  小计：{len(res) - bad}/{len(res)} 通过")
    print(f"\n总计失败 {failed} 项")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
