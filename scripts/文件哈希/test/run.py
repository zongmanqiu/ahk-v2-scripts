"""文件哈希 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/文件哈希/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 无 GUI 自测（--selftest）全绿：五个算法的黄金向量（与本机 certutil 实测同值）；
3. GUI 实机：窗口标题、客户区 672×263、路径输入框、两枚按钮、信息行、三列列表、状态条；
4. 交互：点「复制全部」→ 空表时状态条应变成「无可复制的结果」（不写剪贴板）；
5. 停掉自己拉起的会话。

零网络、零注册表；自测只建一个临时文件、结束即删。
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "文件哈希.ahk")
OUT = os.path.join(os.environ.get("TEMP", "."), "ahkdeck-hash-selftest.txt")
ANCHORS = ["黄金 MD5", "黄金 SHA1", "黄金 SHA256", "黄金 SHA384", "黄金 SHA512"]
BUTTONS = ["选择文件", "复制全部"]
# FlatButton(572, 12, 84, 28) 的中心
BTN_COPY_ALL = (614, 26)

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
    ui = m.call("inspect_ui", {"session": sid, "items": True, "rows": 10})
    wins = ui.get("windows", [])
    if not wins:
        return None, []
    nodes = []
    walk_all(wins[0], nodes)
    return wins[0], nodes


def texts_of(nodes, cls="Static"):
    return [n.get("text") or "" for n in nodes if n.get("class") == cls]


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

        r2 = m.call("run_editor", {"timeout_ms": 8000})
        check("GUI 常驻", r2.get("verdict") == "resident", text_of(r2)[:300])
        sid = r2.get("session")

        w, nodes = None, []
        deadline = time.time() + 10
        while time.time() < deadline:
            time.sleep(0.3)
            w, nodes = grab(m, sid)
            if w:
                break
        check("主窗出现", w is not None)
        if w is None:
            return 1

        check("窗口标题=文件哈希", w.get("text") == "文件哈希", repr(w.get("text")))
        c = w.get("client") or {}
        check("客户区 672x263", (c.get("w"), c.get("h")) == (672, 263), str(c))

        texts = texts_of(nodes)
        missing = [b for b in BUTTONS if b not in texts]
        check("两枚按钮齐全", not missing, "缺: " + ",".join(missing))
        check("信息行=未选择文件", "未选择文件" in texts, str(texts))
        check("列头三列文字", all(t in texts for t in ("算法", "哈希值", "状态")), str(texts))
        check("输入框存在", any(n.get("class") == "Edit" for n in nodes), "")

        lv = next((n for n in nodes if n.get("class") == "SysListView32"), None)
        check("列表存在", lv is not None)
        if lv:
            items = lv.get("items", {})
            check("列表三列", items.get("columns") == 3, str(items.get("columns")))
            check("初始零行", items.get("count") == 0, str(items.get("count")))

        check("状态条=就绪", "就绪" in texts, str(texts))

        # 交互：空表点「复制全部」，状态条应给「无可复制的结果」。
        m.call("send_input", {"session": sid, "action": "click",
                              "x": BTN_COPY_ALL[0], "y": BTN_COPY_ALL[1]})
        st = ""
        deadline = time.time() + 5
        while time.time() < deadline:
            time.sleep(0.3)
            _, nodes2 = grab(m, sid)
            st = " ".join(texts_of(nodes2))
            if "无可复制的结果" in st:
                break
        check("点复制全部后状态条变「无可复制的结果」", "无可复制的结果" in st, st[:200])

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
