# -*- coding: utf-8 -*-
"""右键复制路径 的实机回归（一次只跑本脚本）。

先按 开发指南 §8 步骤 5 把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/右键复制路径/test/run.py

只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。分五层：
  1. --selftest 纯函数断言（verb/场景/命令行/避坑）
  2. GUI 几何：客户区 420×228、四个勾选、两按钮、状态条
  3. 勾选 + 应用：勾「文件」「文件夹空白处」→ 状态条 → winreg 读 HKCU 恰好两处
  4. 菜单命令格式：含 --run / --copy-path / %1 + 中文显示名
  5. 撤销：状态条 → winreg 读四处全清
"""
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]  # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP  # noqa: E402

NAME = "右键复制路径"
VERB = "AHKDeckCopyFullPath"
OUT = Path(__file__).resolve().parent / "selftest-result.txt"
BASES = {
    "file": r"Software\Classes\*\shell",
    "bg": r"Software\Classes\Directory\Background\shell",
    "dir": r"Software\Classes\Directory\shell",
    "drive": r"Software\Classes\Drive\shell",
}


def find_script_id(m):
    listed = m.call("list_scripts")
    ids = {s["name"]: s["id"] for s in listed.get("scripts", [])}
    return ids.get(NAME + ".ahk") or ids.get(NAME)


def test_selftest(m, sid):
    OUT.unlink(missing_ok=True)
    run = m.call("run_script", {"script": sid, "args": ["--selftest", str(OUT)]})
    assert run.get("ok") and run.get("rc") == 0, f"selftest 运行失败: {run}"
    for _ in range(30):
        if OUT.exists():
            break
        time.sleep(0.1)
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("verb 名固定", "四个固定场景", "宿主内核形态加 --run", "不碰 CommandFlags"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/5] selftest 全绿")


def test_geometry(m, sess):
    ui = m.call("inspect_ui", {"session": sess})
    wins = ui.get("windows", [])
    assert wins, "inspect_ui 没找到窗口"
    c = wins[0]["client"]
    assert c.get("w") == 420 and c.get("h") == 228, f"客户区应为 420×228: {c}"
    texts = [x.get("text", "") for x in wins[0].get("controls", [])]
    for label in ("文件", "文件夹空白处", "文件夹", "驱动器", "应用", "撤销"):
        assert label in texts, f"缺控件文字: {label}"
    fills = [x for x in wins[0]["controls"] if x["client"].get("w") == 14]
    assert len(fills) == 4, f"应有四个自绘勾选方块: {len(fills)}"
    print("  [2/5] GUI 几何 420×228 + 四勾选 + 两按钮 + 状态条")


def click(m, sess, x, y, label):
    r = m.call("send_input", {"session": sess, "action": "click", "x": x, "y": y})
    assert r.get("ok"), f"点击 {label} 失败: {r}"


def status_text(m, sess):
    ui = m.call("inspect_ui", {"session": sess})
    for x in ui["windows"][0].get("controls", []):
        if x["client"].get("y") == 198 and x.get("text"):
            return x["text"]
    return ""


def key_count():
    import winreg
    n = 0
    for base in BASES.values():
        try:
            winreg.OpenKey(winreg.HKEY_CURRENT_USER, base + "\\" + VERB,
                           0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
            n += 1
        except OSError:
            pass
    return n


def clear_all():
    import winreg
    for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
        for base in BASES.values():
            for sub in (r"\command", ""):
                try:
                    winreg.DeleteKeyEx(winreg.HKEY_CURRENT_USER,
                                       base + "\\" + VERB + sub, view, 0)
                except OSError:
                    pass


def check_state(m, sess, row_y):
    """读自绘勾选方块当前是否打勾（fill 控件 y = 行的 y + 5）。"""
    ui = m.call("inspect_ui", {"session": sess})
    for x in ui["windows"][0].get("controls", []):
        c = x["client"]
        if c.get("w") == 14 and c.get("y") == row_y + 5:
            return x.get("text", "") == "✓"
    return None


def test_apply(m, sess):
    assert key_count() == 0, "前置清理失败（main 应先 clear_all）"
    for label, cx, cy, row_y in (("文件", 100, 55, 42), ("文件夹空白处", 120, 85, 72)):
        if not check_state(m, sess, row_y):
            click(m, sess, cx, cy, label)
        time.sleep(0.25)
    click(m, sess, 277, 177, "应用")
    time.sleep(0.5)
    assert "已启用 2 个场景" in status_text(m, sess), f"应用状态条错: {status_text(m, sess)}"
    assert key_count() == 2, f"应恰好写入 2 处，实际 {key_count()}"
    # 未勾选的两处必须不存在
    import winreg
    for k in ("dir", "drive"):
        try:
            winreg.OpenKey(winreg.HKEY_CURRENT_USER, BASES[k] + "\\" + VERB,
                           0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
            raise AssertionError(f"未勾选的 {k} 不应写入")
        except OSError:
            pass
    print("  [3/5] 勾选两场景 + 应用 → 注册表恰好两处")


def test_command():
    import winreg
    h = winreg.OpenKey(winreg.HKEY_CURRENT_USER, BASES["file"] + "\\" + VERB + r"\command",
                       0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
    cmd = winreg.QueryValueEx(h, "")[0]
    assert "--run" in cmd and "--copy-path" in cmd and "%1" in cmd, f"命令行格式错: {cmd}"
    vk = winreg.OpenKey(winreg.HKEY_CURRENT_USER, BASES["file"] + "\\" + VERB,
                        0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
    assert winreg.QueryValueEx(vk, "MUIVerb")[0] == "复制完整路径", "中文显示名错"
    print("  [4/5] 菜单命令格式（--run / --copy-path / %1）与中文显示名")


def test_revoke(m, sess):
    click(m, sess, 343, 177, "撤销")
    time.sleep(0.5)
    assert "已撤销全部" in status_text(m, sess), f"撤销状态条错: {status_text(m, sess)}"
    assert key_count() == 0, f"撤销后应清零，实际 {key_count()}"
    print("  [5/5] 撤销 → 注册表四处清零")


def main():
    m = MCP()
    try:
        m.initialize()
        sid = find_script_id(m)
        assert sid, "脚本未出现在 list_scripts：先复制到 .build/Scripts"
        test_selftest(m, sid)

        # 必须在启动 GUI 前清注册表：窗口初始化时会读 IsSceneOn() 回填勾选，
        # 若清理晚于建窗，点击就是在旧状态上再翻转，导致净结果错乱。
        clear_all()
        assert key_count() == 0, "GUI 启动前注册表未清干净"

        run = m.call("run_script", {"script": sid, "timeout_ms": 3000})
        assert run.get("ok"), f"run_script 失败: {run}"
        sess = run["session"]
        time.sleep(0.5)
        test_geometry(m, sess)
        test_apply(m, sess)
        test_command()
        test_revoke(m, sess)
        print("ALL PASS")
    finally:
        m.call("stop_all")
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
