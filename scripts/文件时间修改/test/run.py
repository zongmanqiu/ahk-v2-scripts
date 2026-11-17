"""文件时间修改 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/文件时间修改/test/run.py

覆盖：
1. 内核语法校验零错误（本脚本没有 `--selftest` 分支：它只改真实文件的三个时间戳，
   没有"只动自建对象"的算法可测，所以实机 GUI 就是它的验收面）；
2. 首屏几何：窗口标题、客户区 420×408、三行时间类型、三个自绘勾选、两枚按钮、
   单列列表、状态条「拖入 0 个路径」；
3. 交互一：空表点「更新时间」→ 状态条「列表为空，请先拖入文件或文件夹」；
4. 交互二：把三个时间类型勾选全部点掉，再点「更新时间」→ 状态条「请至少勾选一种时间」
   （这条同时证明自绘勾选真的能切换 Value，不是只会画画）；
5. 停掉自己拉起的会话。

全程不碰用户文件：只点按钮、不拖入路径，列表始终为空。
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "文件时间修改.ahk")
TYPES = ["修改时间", "创建时间", "访问时间"]
BUTTONS = ["更新时间", "清空列表"]
# 坐标照源码：FlatCheck(16, 42/72/102, 100, 26)、FlatButton(228/320, 344, 84, 28)
CHECK_PTS = [(66, 55), (66, 85), (66, 115)]
BTN_APPLY = (270, 358)

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


def texts_of(nodes):
    return [n.get("text") or "" for n in nodes if n.get("class") == "Static"]


def wait_status(m, sid, needle, timeout=5.0):
    deadline = time.time() + timeout
    st = ""
    while time.time() < deadline:
        time.sleep(0.3)
        _, nodes = grab(m, sid)
        st = " ".join(texts_of(nodes))
        if needle in st:
            break
    return st


def main():
    src = open(SCRIPT, encoding="utf-8").read()

    m = MCP(timeout=120)
    sid = None
    try:
        m.initialize()
        m.call("edit_editor", {"content": src})

        v = m.call("validate_editor", {})
        check("内核语法校验 rc=0", v.get("rc") == 0, text_of(v)[:300])

        r = m.call("run_editor", {"timeout_ms": 8000})
        check("GUI 常驻", r.get("verdict") == "resident", text_of(r)[:300])
        sid = r.get("session")

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

        check("窗口标题=文件时间修改", w.get("text") == "文件时间修改", repr(w.get("text")))
        c = w.get("client") or {}
        check("客户区 420x408", (c.get("w"), c.get("h")) == (420, 408), str(c))

        texts = texts_of(nodes)
        missing = [t for t in TYPES if t not in texts]
        check("三个时间类型齐全", not missing, "缺: " + ",".join(missing))
        missing = [t for t in BUTTONS if t not in texts]
        check("两枚按钮齐全", not missing, "缺: " + ",".join(missing))
        check("含「包含子文件（夹）」勾选", "包含子文件（夹）" in texts, str(texts))
        check("状态条首屏=拖入 0 个路径", "拖入 0 个路径" in " ".join(texts), str(texts))

        lv = next((n for n in nodes if n.get("class") == "SysListView32"), None)
        check("列表存在", lv is not None)
        if lv:
            items = lv.get("items", {})
            check("列表单列", items.get("columns") == 1, str(items.get("columns")))
            check("初始零行", items.get("count") == 0, str(items.get("count")))

        # 交互一：空表点「更新时间」。
        m.call("send_input", {"session": sid, "action": "click",
                              "x": BTN_APPLY[0], "y": BTN_APPLY[1]})
        st = wait_status(m, sid, "列表为空")
        check("空表更新时间→列表为空提示", "列表为空，请先拖入文件或文件夹" in st, st[:240])

        # 交互二：三个勾选全点掉，再点「更新时间」。
        for (x, y) in CHECK_PTS:
            m.call("send_input", {"session": sid, "action": "click", "x": x, "y": y})
            time.sleep(0.2)
        m.call("send_input", {"session": sid, "action": "click",
                              "x": BTN_APPLY[0], "y": BTN_APPLY[1]})
        st = wait_status(m, sid, "请至少勾选")
        check("全取消勾选→请至少勾选一种时间", "请至少勾选一种时间" in st, st[:240])

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
