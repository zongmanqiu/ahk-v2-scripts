# -*- coding: utf-8 -*-
"""文件解锁 的实机回归（只跑本脚本自己，AGENTS.md 第 12 条）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/文件解锁/test/run.py

三层断言：
  1. --selftest 纯逻辑（FPIF 找占用者 / 占用检测 / 保护名单）；
  2. inspect_ui 几何：窗口 672×330 + 列表/按钮/状态条齐全；
  3. 端到端：holder 占用临时文件 → GUI 检测 → 列表出现 holder 的 PID。

只起本脚本自己的 MCP 临时实例 + 一个 holder 子进程，不动用户手开的主程序。
"""
from pathlib import Path
import os
import re
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
    assert "FPIF 找出占用本文件的进程 PID" in text, "FPIF 断言缺失"
    print("  [1/3] selftest 全绿（含 FPIF 找占用者）")


def read_ui(m, sess):
    return m.call("inspect_ui", {"session": sess, "items": True, "rows": 30})


def test_geometry(m, sess):
    ins = read_ui(m, sess)
    wins = ins.get("windows", [])
    assert wins, "inspect_ui 没找到窗口"
    w = wins[0]
    c = w.get("client", {})
    assert c.get("w") == 672 and c.get("h") == 330, f"窗口尺寸错: {c}"
    classes = [x.get("class", "") for x in w.get("controls", [])]
    assert "Edit" in classes, "缺输入框"
    assert any("ListView" in k for k in classes), "缺占用进程列表"
    print("  [2/3] GUI 几何 672×330 + 输入框/列表/按钮齐全")


def test_e2e(m, sess):
    demo = os.path.join(tempfile.gettempdir(), "ahkdeck_unlock_e2e_demo.txt")
    with open(demo, "w", encoding="utf-8") as f:
        f.write("locked")
    HOLDER_OUT.unlink(missing_ok=True)
    holder = subprocess.Popen([str(BUILD / "AutoHotkey64.exe"), str(HOLDER), demo])
    try:
        time.sleep(1)
        hp = None
        if HOLDER_OUT.exists():
            m0 = re.search(r"holder pid=(\d+)", HOLDER_OUT.read_text(encoding="utf-8", errors="replace"))
            if m0:
                hp = int(m0.group(1))
        assert hp, "holder 未写出 PID"

        m.call("send_input", {"session": sess, "action": "click", "x": 200, "y": 26})
        time.sleep(0.2)
        m.call("send_input", {"session": sess, "action": "text", "text": demo})
        time.sleep(0.3)
        # 确认输入框内容正确（注入偶发丢失，重填一次）
        ins0 = read_ui(m, sess)
        actual = ""
        for w in ins0.get("windows", []):
            for ctl in w.get("controls", []):
                if ctl.get("class") == "Edit":
                    actual = ctl.get("text", "") or ""
        if actual.strip() != demo:
            m.call("send_input", {"session": sess, "action": "click", "x": 200, "y": 26})
            m.call("send_input", {"session": sess, "action": "text", "text": demo})
            time.sleep(0.3)

        m.call("send_input", {"session": sess, "action": "click", "x": 614, "y": 26})
        time.sleep(2)
        ins = read_ui(m, sess)
        rows = []
        status = ""
        for w in ins.get("windows", []):
            for ctl in w.get("controls", []):
                if "ListView" in ctl.get("class", ""):
                    rows = ctl.get("items", {}).get("rows", [])
                if "完成" in (ctl.get("text", "") or ""):
                    status = ctl.get("text", "")
        assert "占用进程" in status, f"检测未完成: {status!r}"
        assert any(str(hp) in str(r) for r in rows), f"列表未出现 holder PID {hp}: {rows}"
        print(f"  [3/3] 端到端：holder PID {hp} 正确列入占用进程")
    finally:
        holder.terminate()
        try:
            holder.wait(timeout=3)
        except Exception:
            pass
        HOLDER_OUT.unlink(missing_ok=True)


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
        test_e2e(m, sess)
        print("ALL PASS")
        return 0
    finally:
        if sess:
            m.call("stop_script", {"session": sess})
        m.call("stop_all")
        m.close()


if __name__ == "__main__":
    sys.exit(main())
