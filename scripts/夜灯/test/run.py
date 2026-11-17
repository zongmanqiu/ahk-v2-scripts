"""夜灯 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/夜灯/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 无 GUI 自测（--selftest）全绿：varint 往返、模板解析、截断/伪造 count 不越界、
   强度↔色温往返、自建注册表键的二进制值读写；
3. 面板几何：客户区 320×52、标题、百分比读数形如 `N%`；
4. 停掉自己拉起的会话。

**测试怎么造出面板**：本脚本唯一入口是托盘菜单「夜灯调整」，而 MCP 没有触发托盘菜单的
工具，所以真源后面追加一行 `ShowPanel()` 当驱动——跑的是真源本身，没改一个字符。

副作用：面板只是 Show 出来，不动滑块就不调 ApplyRamp；启动路径会把「读到的当前色温」
原样写回一次（等于没变）。自测分支只动自建键 `HKCU\\Software\\AHKDeck\\NightLightSelfTest`。
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "夜灯.ahk")
OUT = os.path.join(os.environ.get("TEMP", "."), "ahkdeck-nightlight-selftest.txt")
ANCHORS = ["强度↔色温往返误差 ≤1", "伪造超大 count 不崩溃", "截断模板逐前缀解析不越界",
           "二进制值读回逐字节相等", "模板解析回温度 3400"]
PCT = re.compile(r"^\d{1,3}%$")

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


def walk_all(node, out):
    out.append(node)
    for c in node.get("controls", []):
        walk_all(c, out)


def main():
    src = open(SCRIPT, encoding="utf-8").read()

    m = MCP(timeout=120)
    sid = None
    try:
        m.initialize()
        m.call("edit_editor", {"content": src})

        v = m.call("validate_editor", {})
        check("内核语法校验 rc=0", v.get("rc") == 0, text_of(v)[:300])

        r = m.call("run_editor", {"args": ["--selftest", OUT], "timeout_ms": 30000})
        check("--selftest rc=0", r.get("rc") == 0, text_of(r)[:300])
        text = ""
        try:
            text = open(OUT, encoding="utf-8-sig").read()
        except OSError:
            pass
        check("自测 fails=0", "fails=0" in text, text[-400:])
        check("自测无 FAIL 行", "FAIL " not in text, text)
        for a in ANCHORS:
            check("自测含锚点「" + a + "」", ("PASS " + a) in text, text)

        # 第二轮：真源 + 一行驱动，把托盘入口背后的面板顶出来做几何断言。
        m.call("edit_editor", {"content": src + "\nShowPanel()\n"})
        r2 = m.call("run_editor", {"timeout_ms": 8000})
        check("GUI 常驻", r2.get("verdict") == "resident", text_of(r2)[:300])
        sid = r2.get("session")

        w, nodes = None, []
        deadline = time.time() + 10
        while time.time() < deadline:
            time.sleep(0.3)
            ui = m.call("inspect_ui", {"session": sid, "wait_ms": 2000})
            wins = ui.get("windows", [])
            if wins:
                w = wins[0]
                nodes = []
                walk_all(w, nodes)
                break
        check("面板出现", w is not None)
        if w is None:
            return 1

        check("窗口标题=夜灯调整", w.get("text") == "夜灯调整", repr(w.get("text")))
        c = w.get("client") or {}
        check("客户区 320x52", (c.get("w"), c.get("h")) == (320, 52), str(c))

        texts = [n.get("text") or "" for n in nodes if n.get("class") == "Static"]
        pct = [t for t in texts if PCT.match(t.strip())]
        check("百分比读数形如 N%", bool(pct), str(texts))

        # 面板是自绘的：轨道命中区 232×20、轨道本体 232×10（y+5）、圆点外框 12×20、
        # 读数 48×28 靠右。坐标照 §10 的 320 版式（行宽 288 = 232 + 8 + 48）。
        rects = [((n.get("client") or {}).get("x"), (n.get("client") or {}).get("y"),
                  (n.get("client") or {}).get("w"), (n.get("client") or {}).get("h"))
                 for n in nodes if n.get("class") == "Static"]
        check("轨道本体 232x10 @(16,21)", (16, 21, 232, 10) in rects, str(rects))
        check("轨道命中区 232x20 @(16,16)", (16, 16, 232, 20) in rects, str(rects))
        check("滑块圆点 12x20 @(16,16)", (16, 16, 12, 20) in rects, str(rects))
        check("读数 48x28 @(256,12)", (256, 12, 48, 28) in rects, str(rects))

        if sid:
            m.call("stop_script", {"session": sid})
            sid = None
    finally:
        if sid:
            try:
                m.call("stop_script", {"session": sid})
            except Exception:
                pass
        m.close()

    print("FAILED:", len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
