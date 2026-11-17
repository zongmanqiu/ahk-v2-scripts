"""双击防抖 实机闭环测试。

跑法（工作目录随意，脚本用绝对路径找真源）：
    python .ahk-v2-scripts/scripts/双击防抖/test/run.py

覆盖：
1. 内核语法校验零错误；
2. 1.2.1 的 ini 迁移：旧位置平铺的 `双击防抖.ini`（含 `Settings.Interval=80`）
   应被整份复制到同名文件夹、展开成三键（Left=80 / Right=0 / Middle=0）、
   旧键 `Interval` 删除——这条是 1.2.x 最容易回退的一步；
3. 设置窗几何：客户区 332×150、三行标签、两个按钮、三个输入框；
4. 停掉自己拉起的会话。

**测试怎么造出设置窗**：本脚本唯一入口是托盘菜单「设置」，而 MCP 没有触发托盘菜单的
工具，所以真源后面追加一行 `ShowSettings()` 当驱动——跑的是真源本身，没改一个字符。
同理 ini 迁移发生在自动执行段的 `LoadConfig()`，与这行驱动无关，一次运行同时验两件事。
"""
import configparser
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from mcp_client import MCP, text_of  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "双击防抖.ahk")
# run_editor 把内容写进 <exe>\temp\work\ai-editor.ahk，A_ScriptDir 因此是那一层。
WORK = os.path.abspath(os.path.join(ROOT, "..", ".build", "temp", "work"))
NEW_INI = os.path.join(WORK, "双击防抖", "双击防抖.ini")
OLD_INI = os.path.join(WORK, "双击防抖.ini")
LABELS = ["左键最小间隔（ms）", "右键最小间隔（ms）", "中键最小间隔（ms）"]
BUTTONS = ["取消", "保存"]

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(name)


def walk_all(node, out):
    out.append(node)
    for c in node.get("controls", []):
        walk_all(c, out)


def read_ini(path):
    cp = configparser.ConfigParser()
    cp.optionxform = str  # 键名大小写原样：Left/Right/Middle
    with open(path, "rb") as f:
        bom = f.read(2)
    # AHK v2 的 IniWrite 新建文件写 UTF-16 LE（实测 BOM = FF FE），别按 UTF-8 读。
    enc = "utf-16" if bom in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
    with open(path, encoding=enc) as f:
        cp.read_file(f)
    return cp


def main():
    src = open(SCRIPT, encoding="utf-8").read()

    # 干净起点：新位置整份删掉，旧位置写一份 1.1.0 形态的 ini。
    shutil.rmtree(os.path.join(WORK, "双击防抖"), ignore_errors=True)
    if os.path.exists(OLD_INI):
        os.remove(OLD_INI)
    os.makedirs(WORK, exist_ok=True)
    # 1.1.0 的 ini 是 AHK 自己 IniWrite 出来的，编码为 UTF-16 LE；照原样造才叫同一个场景。
    with open(OLD_INI, "w", encoding="utf-16", newline="\r\n") as f:
        f.write("[Settings]\r\nInterval=80\r\n")

    m = MCP(timeout=120)
    sid = None
    try:
        m.initialize()
        m.call("edit_editor", {"content": src + "\nShowSettings()\n"})

        v = m.call("validate_editor", {})
        check("内核语法校验 rc=0", v.get("rc") == 0, text_of(v)[:300])

        r = m.call("run_editor", {"timeout_ms": 8000})
        check("GUI 常驻", r.get("verdict") == "resident", text_of(r)[:300])
        sid = r.get("session")

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
        check("设置窗出现", w is not None)
        if w is None:
            return 1

        check("窗口标题=双击防抖", w.get("text") == "双击防抖", repr(w.get("text")))
        c = w.get("client") or {}
        check("客户区 332x150", (c.get("w"), c.get("h")) == (332, 150), str(c))

        texts = [n.get("text") or "" for n in nodes if n.get("class") == "Static"]
        missing = [t for t in LABELS if t not in texts]
        check("三行标签齐全", not missing, "缺: " + ",".join(missing))
        missing = [t for t in BUTTONS if t not in texts]
        check("两个按钮齐全", not missing, "缺: " + ",".join(missing))
        edits = [n for n in nodes if n.get("class") == "Edit"]
        check("三个输入框", len(edits) == 3, str(len(edits)))
        vals = [e.get("text") or "" for e in edits]
        check("输入框读到迁移后的间隔", vals[:3] == ["80", "0", "0"], str(vals))

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

    # 迁移结果在进程退出后才稳定（IniWrite 是同步的，但留一拍给文件系统）。
    time.sleep(0.3)
    check("新位置 ini 已生成", os.path.isfile(NEW_INI), NEW_INI)
    if os.path.isfile(NEW_INI):
        cp = read_ini(NEW_INI)
        sec = cp["Settings"] if cp.has_section("Settings") else {}
        check("Left 迁移为 80", sec.get("Left") == "80", str(dict(sec)))
        check("Right 默认为 0", sec.get("Right") == "0", str(dict(sec)))
        check("Middle 默认为 0", sec.get("Middle") == "0", str(dict(sec)))
        check("旧键 Interval 已删除", "Interval" not in sec, str(dict(sec)))
    check("旧位置 ini 保留不动", os.path.isfile(OLD_INI), OLD_INI)

    print("FAILED:", len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
