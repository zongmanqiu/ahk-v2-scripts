# -*- coding: utf-8 -*-
"""右键菜单整理 的实机回归（一次只跑本脚本）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/右键菜单整理/test/run.py

只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。分五层：
  1. --selftest 纯函数断言（隐藏标记/位置/影子键/保护动词）
  2. GUI 几何：客户区 720×420、7 导航、列表三列、6 按钮、状态条
  3. 列表读真实 HKCR 菜单项：非空、显示名解析、状态三态
  4. 隐藏/恢复：选中一项点「隐藏」→ HKCU 影子键写 ProgrammaticAccessOnly、
     HKLM 原键不变；点「显示」→ 标记删除、HKLM 仍不变
  5. 位置三档：置顶/置底/恢复 → HKCU 影子键 Position 值正确、HKLM 不变
     结束清理所有本测试写下的 HKCU 影子键，恢复原状
"""
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]  # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP  # noqa: E402

NAME = "右键菜单整理"
VERB = "PintohomeFileTestProbe"  # 测试影子键用的 verb（不真实存在，纯 HKCU 侧验证）
OUT = Path(__file__).resolve().parent / "selftest-result.txt"

# 测试用真实菜单项：文件场景的一个 HKLM verb（用它的影子键读写，绝不改 HKLM 原键）
TEST_SUFFIX = r"Software\Classes\*\shell"
TEST_VERB = "pintohomefile"
SHADOW = TEST_SUFFIX + "\\" + TEST_VERB


def find_sid(m):
    listed = m.call("list_scripts")
    for s in listed.get("scripts", []):
        if s["name"] == NAME + ".ahk":
            return s["id"]
    return None


def probe(m, sid, action):
    """用脚本自己的 --probe 分支驱动写函数（与按钮共用同一套逻辑）。"""
    r = m.call("run_script", {"script": sid,
                              "args": ["--probe", r"*\shell", TEST_VERB, action]})
    assert r.get("ok"), f"probe {action} 失败: {r}"
    assert not r.get("errors"), f"probe {action} 运行错误: {r.get('errors')}"
    time.sleep(0.15)


def status(m, sess):
    ui = m.call("inspect_ui", {"session": sess})
    for c in ui["windows"][0]["controls"]:
        if c.get("client", {}).get("y") == 386 and c.get("text"):
            return c["text"]
    return ""


def winreg_val(path, name, root=None):
    import winreg
    root = root if root is not None else winreg.HKEY_CURRENT_USER
    try:
        k = winreg.OpenKey(root, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
        try:
            return winreg.QueryValueEx(k, name)[0]
        finally:
            winreg.CloseKey(k)
    except OSError:
        return None


def clean_shadow():
    import winreg
    for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
        for name in ("ProgrammaticAccessOnly", "Position"):
            try:
                k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, SHADOW, 0,
                                   winreg.KEY_SET_VALUE | view)
                try:
                    winreg.DeleteValue(k, name)
                except OSError:
                    pass
                finally:
                    winreg.CloseKey(k)
            except OSError:
                pass
    # 空影子键删掉（若还含其它值则保留，绝不误删用户数据）
    try:
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, SHADOW, 0,
                           winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
        n = winreg.QueryInfoKey(k)[1]
        winreg.CloseKey(k)
        if n == 0:
            winreg.DeleteKeyEx(winreg.HKEY_CURRENT_USER, SHADOW,
                               winreg.KEY_WOW64_64KEY, 0)
    except OSError:
        pass


def test_selftest(m, sid):
    OUT.unlink(missing_ok=True)
    out_path = str(OUT.resolve()).replace("\\", "/")
    run = m.call("run_script", {"script": sid, "args": ["--selftest", out_path]})
    for _ in range(30):
        if OUT.exists():
            break
        time.sleep(0.1)
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8-sig")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("四种隐藏标记都认", "影子键只落在 HKCU", "保护 open/edit 动词"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/5] selftest 全绿")


def test_geometry(m, sess):
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    w = ui["windows"][0]
    c = w["client"]
    assert c["w"] == 720 and c["h"] == 420, f"客户区错: {c}"
    texts = [x.get("text", "") for x in w["controls"]]
    for name in ("文件", "文件夹", "文件夹空白处", "驱动器", "文件夹对象", "所有对象", "桌面背景"):
        assert name in texts, f"缺导航 {name}"
    for name in ("隐藏", "显示", "置顶", "置底", "恢复位置", "刷新"):
        assert name in texts, f"缺按钮 {name}"
    assert "菜单项" in texts and "状态" in texts, "缺列表表头"
    lv = [x for x in w["controls"] if x.get("class") == "SysListView32"]
    assert lv and lv[0]["items"]["columns"] == 3, "列表应三列"
    print("  [2/5] GUI 几何 720×420 + 7 导航 + 三列列表 + 6 按钮 + 状态条")


def test_list(m, sess):
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    lv = [x for x in ui["windows"][0]["controls"] if x.get("class") == "SysListView32"][0]
    rows = lv["items"]["rows"]
    assert len(rows) >= 3, f"文件场景应列出多个真实菜单项，实际 {len(rows)}"
    states = {r[1] for r in rows}
    assert states & {"显示", "已隐藏", "系统隐藏"}, f"状态分类不对: {states}"
    assert all(r[2] in ("默认", "置顶", "置底") for r in rows), "位置列取值错"
    print(f"  [3/5] 列出真实菜单项 {len(rows)} 个 · 显示名/状态({len(states)}态)/位置列正确")


def test_hide_show(m, sid):
    import winreg
    clean_shadow()
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "前置清理失败"
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)

    probe(m, sid, "hide")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") == "", \
        f"隐藏应写 ProgrammaticAccessOnly=''，实际 {winreg_val(SHADOW, 'ProgrammaticAccessOnly')!r}"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"

    probe(m, sid, "show")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "恢复后标记应删除"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    print("  [4/5] 隐藏/恢复 → HKCU 影子键标记增删、HKLM 原键不变")


def test_position(m, sid):
    import winreg
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)
    probe(m, sid, "top")
    assert winreg_val(SHADOW, "Position") == "top", f"置顶错: {winreg_val(SHADOW, 'Position')!r}"
    probe(m, sid, "bottom")
    assert winreg_val(SHADOW, "Position") == "bottom", f"置底错: {winreg_val(SHADOW, 'Position')!r}"
    probe(m, sid, "default")
    assert winreg_val(SHADOW, "Position") is None, "恢复位置后应无 Position 值"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    clean_shadow()
    print("  [5/5] 位置三档 → HKCU Position 值正确、HKLM 原键不变、清理干净")


def main():
    m = MCP()
    try:
        m.initialize()
        sid = find_sid(m)
        assert sid, "脚本未出现在 list_scripts：先复制到 .build/Scripts"
        test_selftest(m, sid)

        clean_shadow()
        run = m.call("run_script", {"script": sid, "timeout_ms": 3000})
        assert run.get("ok"), f"run_script 失败: {run}"
        assert not run.get("errors"), f"启动有运行时错误: {run.get('errors')}"
        sess = run["session"]
        time.sleep(0.6)
        test_geometry(m, sess)
        test_list(m, sess)
        test_hide_show(m, sid)
        test_position(m, sid)

        out = m.call("get_session_output", {"session": sess})
        assert out.get("ok") and not out.get("fatal"), f"运行期致命错误: {out}"
        print("ALL PASS")
    finally:
        clean_shadow()
        m.call("stop_all")
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
