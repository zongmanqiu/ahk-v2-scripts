"""打开方式清理 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/打开方式清理/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 无 GUI 自测（--selftest）全绿（备份/还原、子键整棵树、原地摘行与排序）；
3. GUI 实机：窗口标题、客户区尺寸、工具条六个按钮、扫描结束后列表有行、状态条给读数；
4. 停掉自己拉起的会话。

只读本机注册表；自测只动自建的 AHKDeckOwcSelfTest 键，结束即清理。
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "打开方式清理.ahk")
OUT = os.path.join(os.environ.get("TEMP", "."), "ahkdeck-owc-selftest.txt")
BUTTONS = ["刷新", "全选", "删除失效项", "复制路径", "删除选中", "历史记录"]

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


def walk_all(node, out):
    out.append(node)
    for c in node.get("controls", []):
        walk_all(c, out)


def grab(m, sid):
    ui = m.call("inspect_ui", {"session": sid, "items": True, "rows": 40})
    wins = ui.get("windows", [])
    if not wins:
        return None, []
    nodes = []
    walk_all(wins[0], nodes)
    return wins[0], nodes


def status_text(nodes):
    """状态条是两枚 Text 色块（底 + 文字），文字那个带 +0x200 与顶对齐；取最长的一条。"""
    cand = [n.get("text") or "" for n in nodes if n.get("class") == "Static"]
    long = [t for t in cand if "条目" in t or "扫描" in t or "就绪" in t]
    return long[0] if long else ""


def main():
    src = open(SCRIPT, encoding="utf-8").read()
    m = MCP(timeout=120)
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
        # 这几条是 1.6.0 的回归锚点：备份丢了明细行、或恢复只写 REG_SZ，它们会红。
        for anchor in ("恢复子键树里的值", "恢复第二层嵌套键的值", "恢复 REG_DWORD 类型与数据",
                       "读不到目标时备份返回 false"):
            check("自测含锚点「" + anchor + "」", ("PASS " + anchor) in text, text)

        r2 = m.call("run_editor", {"timeout_ms": 8000})
        check("GUI 常驻", r2.get("verdict") == "resident", text_of(r2)[:300])
        sid = r2.get("session")

        # 扫描是 15 步 1ms 定时器推的，轮询到出现读数为止（固定 sleep 在慢机器上会读到空表）。
        w, nodes, lv, st = None, [], None, ""
        deadline = time.time() + 12
        while time.time() < deadline:
            time.sleep(0.4)
            w, nodes = grab(m, sid)
            lv = next((n for n in nodes if n.get("class") == "SysListView32"), None)
            st = status_text(nodes)
            if lv and "个条目" in st:
                break
        check("有窗口", w is not None)
        if not w:
            return 1
        check("窗口标题=打开方式清理", w.get("text") == "打开方式清理", repr(w.get("text")))
        c = w.get("client") or {}
        check("客户区 1100x650", (c.get("w"), c.get("h")) == (1100, 650), str(c))

        texts = [n.get("text") or "" for n in nodes if n.get("class") == "Static"]
        missing = [b for b in BUTTONS if b not in texts]
        check("工具条六个按钮齐全", not missing, "缺: " + ",".join(missing))

        check("找到条目列表", lv is not None)
        if lv:
            items = lv.get("items", {})
            check("列表六列", items.get("columns") == 6, str(items.get("columns")))
            check("扫描出条目", items.get("count", 0) > 0, str(items.get("count")))
            check("每行六格", all(len(row) == 6 for row in items.get("rows", [])),
                  str(items.get("rows", [])[:2]))
        check("状态条给出条目数与扩展名数", "种扩展名" in st, st)

        m.call("stop_script", {"session": sid})
    finally:
        m.close()

    print("FAILED:", len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
