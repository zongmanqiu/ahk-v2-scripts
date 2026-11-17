"""防休眠 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/防休眠/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 无 GUI 自测（--selftest）全绿：四组开关位的纯计算、真实
   `SetThreadExecutionState` 的全开 → 清回往返；
3. 常驻确认（本脚本只有托盘菜单、没有可见窗口，所以这一条就是它的"界面"上限）；
4. 停掉自己拉起的会话。

自测只动本线程的执行状态，结束即清回 ES_CONTINUOUS：不写注册表、不碰电源计划。
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "防休眠.ahk")
OUT = os.path.join(os.environ.get("TEMP", "."), "ahkdeck-nosleep-selftest.txt")
ANCHORS = ["全关＝仅 ES_CONTINUOUS（释放信号）", "仅阻止休眠档位无杂位",
           "仅阻止息屏档位无杂位", "双开三位齐全", "API 清回被受理"]

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


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

        r2 = m.call("run_editor", {"timeout_ms": 6000})
        check("常驻（托盘入口脚本）", r2.get("verdict") == "resident", text_of(r2)[:300])
        sid = r2.get("session")

        # 没有窗口是预期结果：面板/主窗一个都不该冒出来。
        time.sleep(1.0)
        ui = m.call("inspect_ui", {"session": sid, "wait_ms": 1000})
        check("无可见窗口", not ui.get("windows"), str(ui.get("windows"))[:200])

        m.call("stop_script", {"session": sid})
        sid = None
        s = m.call("list_sessions", {})
        check("停止后会话已消失", not [x for x in (s.get("sessions") or [])
                                       if x.get("id") == r2.get("session")],
              text_of(s)[:300])
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
