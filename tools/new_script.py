#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""新脚本骨架生成器（m213）。

用法：
  python tools/new_script.py <脚本名> "<一句话功能>"

输出 scripts/<名>/ 的完整骨架：<名>.ahk（§10 原生 UI 标准）、info/{README,HISTORY}.md、
test/run.py（MCP 闭环冒烟入口）。只生成，不登记 scripts.json、不编译、不发版——
后续按 开发指南 §8 的 9 步流程走。

生成物是「能跑的 80 分起点」，不是成品：业务逻辑在 OnAction() 里替换 TODO。
"""
from __future__ import annotations

import datetime as _dt
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
NAME_RE = re.compile(r"^[\w\u4e00-\u9fff-]{1,40}$")

AHK = r"""; ==UserScript==
; @name         @@NAME@@
; @namespace    https://gitee.com/qiuzongman/ahk-v2-scripts
; @version      1.0.0
; @description  @@DESC@@
; @author       作者名（待填）
; @date         @@DATE@@
; @license      AGPL-3.0
; @homepageURL  https://gitee.com/qiuzongman/ahk-v2-scripts
; @requires     AutoHotkey v2.0
; @host         AHKDeck 0.3.6+（亦可独立运行）
; @entry        主窗口；--selftest 为无 GUI 分支
; ==/UserScript==
;
; @@NAME@@：@@DESC@@
; 骨架由 tools/new_script.py 生成（m213）：§10 八色令牌、字号、1px 描边按钮、自绘状态条。
; 业务逻辑替换 OnAction() 的 TODO；颜色必须内联字面量（§10.2.1），不许自造色值。
; 本脚本为独立实现，未复刻第三方源码。许可证 AGPL-3.0，全文见脚本仓库根目录 LICENSE。

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

gGui := 0, gInput := 0, gStatus := 0

; DWM 属性 35/36/34 只写不读，验证只能看截图像素；COLORREF 是 0x00BBGGRR：
; #DCE8F7 → 0x00F7E8DC、#202B3A → 0x3A2B20，与状态条同色。
PaintCaption() {
    global gGui
    c := Buffer(4, 0)
    NumPut("UInt", 0x00F7E8DC, c)
    t := Buffer(4, 0)
    NumPut("UInt", 0x3A2B20, t)
    try {
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 35, "Ptr", c, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 36, "Ptr", t, "UInt", 4)
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", gGui.Hwnd, "UInt", 34, "Ptr", c, "UInt", 4)
    }
}

; 浅色底 + 近黑字，按钮靠 1px 描边立形，不分主次：外块铺边框色、内块缩进 1px 铺底色。
; 两块都挂 Click —— 否则点在 1px 边上没反应，手感像坏了。不用系统 Button（经典 3D 凸起）。
FlatButton(g, x, y, w, h, text, fill, edge, cb) {
    f := g.Add("Text", "x" x " y" y " w" w " h" h " Background" edge)
    b := g.Add("Text", "x" (x + 1) " y" (y + 1) " w" (w - 2) " h" (h - 2)
        " Background" fill " c202B3A +0x200 Center", text)
    f.OnEvent("Click", (*) => cb())
    b.OnEvent("Click", (*) => cb())
    return b
}

BuildGui() {
    global gGui, gInput, gStatus
    gGui := Gui("", "@@NAME@@")
    gGui.BackColor := "F7F9FC"
    gGui.SetFont("s10", "Microsoft YaHei UI")
    gGui.OnEvent("Close", (*) => ExitApp())

    ; 客户区 520×116；内容行 x16 w488（520−16×2），行内加和精确等于 488。
    gGui.Add("Text", "x16 y12 w488 h28 BackgroundB7C8E0")
    gInput := gGui.Add("Edit", "x17 y13 w486 h26 -E0x200 BackgroundFFFFFF c202B3A", "")

    FlatButton(gGui, 16, 48, 96, 28, "执行", "EBF2FB", "B7C8E0", OnAction)

    ; 状态条自己铺底块；文字只写事实句，不写指令句、不写内部术语。
    gGui.Add("Text", "x0 y86 w520 h30 BackgroundDCE8F7")
    gStatus := gGui.Add("Text", "x12 y86 w496 h30 BackgroundDCE8F7 c202B3A +0x200", "就绪")

    gGui.Show("w520 h116 Center")
    PaintCaption()
}

OnAction(*) {
    global gInput, gStatus
    ; TODO(@@NAME@@)：在此实现真正业务。
    ; · 写文件一律进 A_ScriptDir "\@@NAME@@\"（产物准则 §1），先 DirCreate 再 FileAppend。
    ; · 写 AHK API 前先 lookup_help，别凭记忆；跨进程读选区/文本类需求已被用户否决。
    gStatus.Value := "已执行"
}

; --selftest：无 GUI 分支，只证骨架能加载；真实断言在 test/run.py 补。
if (A_Args.Length && A_Args[1] = "--selftest")
    RunSelfTest(A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\@@NAME@@\selftest-result.txt")

RunSelfTest(path) {
    out := "PASS 骨架加载`nfails=0`n"
    if (pos := InStr(path, "\", false, -1) - 1) > 0
        try DirCreate(SubStr(path, 1, pos))
    try FileDelete(path)
    FileAppend(out, path, "UTF-8")
    ExitApp(0)
}

BuildGui()
"""

HISTORY = """# @@NAME@@ 历史

只增不改：每次发版在最上面加一段 `## <版本>（日期）`。

## 1.0.0（@@DATE@@）

- 骨架生成（m213）：§10 八色配色、1px 描边按钮、自绘状态条、`--selftest` 分支。
"""

README = """# @@NAME@@

@@DESC@@

## 功能

- TODO：逐条写清用户可见的行为，不写内部实现。

## 入口

- 主窗口；全局热键由 AHKDeck 统一指派，脚本不自设。
- `--selftest [输出路径]`：无 GUI 冒烟分支，默认写 `@@NAME@@\\selftest-result.txt`。

## 写入位置

- 全部产物进 `scripts/@@NAME@@/@@NAME@@/`（同名文件夹，运行时自建，不进仓库）。

## 风险与不做

- TODO：破坏性操作、注册表、网络、剪贴板/选区文本（已否决）逐项交代；没有就写「无」。
"""

TEST = """# -*- coding: utf-8 -*-
\"\"\"@@NAME@@ 的 MCP 闭环冒烟入口（m213 骨架）。

先按 开发指南 §8 步骤 8 把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/@@NAME@@/test/run.py
只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。
\"\"\"
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]  # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP  # noqa: E402

NAME = "@@NAME@@"
OUT = Path(__file__).resolve().parent / "selftest-result.txt"


def main():
    OUT.unlink(missing_ok=True)
    m = MCP()
    try:
        m.initialize()
        listed = m.call("list_scripts")
        print("LIST:", str(listed)[:400])
        ids = {s["name"]: s["id"] for s in listed.get("scripts", [])}
        sid = ids.get(NAME + ".ahk") or ids.get(NAME)
        assert sid, "脚本未出现在 list_scripts：先复制到 .build/Scripts"
        run = m.call("run_script", {"script": sid, "args": ["--selftest", str(OUT)]})
        print("RUN:", str(run)[:400])
        assert run.get("ok") and run.get("rc") == 0, "run_script 失败"
        out = m.call("get_session_output", {"session": run["session"]})
        print("OUTPUT:", str(out)[:800])
        assert out.get("ok"), "get_session_output 失败"
        assert OUT.exists(), "--selftest 未写出结果文件"
        assert "fails=0" in OUT.read_text(encoding="utf-8"), "自测有失败项"
        print("SMOKE OK")  # TODO：补真实业务断言（inspect_ui / send_input / capture_ui）
    finally:
        m.call("stop_all")
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
"""


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    name, desc = sys.argv[1].strip(), sys.argv[2].strip()
    if not NAME_RE.fullmatch(name) or name in {".", ".."}:
        print("脚本名只能是中文/字母/数字/下划线/连字符（1-40 字）")
        return 2
    if not desc:
        print("功能描述不能为空")
        return 2
    folder = SCRIPTS / name
    if folder.exists():
        print(f"已存在：{folder}（不覆盖）")
        return 2

    date = _dt.date.today().isoformat()
    for rel, text in {
        f"{name}.ahk": AHK,
        "info/HISTORY.md": HISTORY,
        "info/README.md": README,
        "test/run.py": TEST,
    }.items():
        path = folder / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            text.replace("@@NAME@@", name)
                .replace("@@DESC@@", desc)
                .replace("@@DATE@@", date),
            encoding="utf-8", newline="\n",
        )
    print(f"已生成：{folder}")
    print("下一步：编辑 .ahk 的 OnAction() → .build/AHKDeck.exe --validate → 开发指南 §8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
