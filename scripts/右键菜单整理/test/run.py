# -*- coding: utf-8 -*-
"""右键菜单整理 的实机回归（一次只跑本脚本）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/右键菜单整理/test/run.py

只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。分六层：
  1. --selftest 纯函数断言（三场景/来源展开/状态位置合并/隐藏标记/共享CLSID/COM显示名）
  2. --probe roots 实测三场景位置根：桌面=背景+个性化、文件夹空白=背景、拖入文件/文件夹各自展开
  3. GUI 几何：客户区 820×450、3 入口、拖入区、四列列表、6 按钮、状态条
  4. 场景切换：点桌面空白/文件夹空白，列表随 HKCR 真实来源变化（桌面多个性化项）
  5. L1 隐藏/恢复 + 位置三档：影子键按根写、HKLM 原键不变（--probe verb 多根）
  6. L2 COM 隐藏/恢复：Blocked 按 CLSID 增删、CLSID 显示名与 HKLM 原键不变
     结束清理所有本测试写下的 HKCU 键，恢复原状
"""
from pathlib import Path
import sys
import time

REPO = Path(__file__).resolve().parents[3]   # scripts/<名>/test/run.py → .ahk-v2-scripts 仓库根
HOST = REPO.parent                            # AHKDeck 宿主根（.ex 在这里）
sys.path.insert(0, str(REPO / "tools"))
from mcp_client import MCP  # noqa: E402

NAME = "右键菜单整理"
OUT = Path(__file__).resolve().parent / "selftest-result.txt"
# 运行时产物写进脚本同名文件夹（.gitignore 已忽略 scripts/*/*/）
ROOTS_OUT = Path(__file__).resolve().parents[1] / "右键菜单整理" / "roots-probe.txt"

TEST_ROOT = r"*"
TEST_VERB = "pintohomefile"
SHADOW = "Software\\Classes\\*\\shell\\" + TEST_VERB

TEST_CLSID = "{23170F69-40C1-278A-1000-000100020000}"
BLOCKED = r"Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
CLSID_HKCR = "CLSID\\" + TEST_CLSID
CLSID_HKLM = "Software\\Classes\\CLSID\\" + TEST_CLSID


def find_sid(m):
    for s in m.call("list_scripts").get("scripts", []):
        if s["name"] == NAME + ".ahk":
            return s["id"]
    return None


def probe(m, sid, *args):
    r = m.call("run_script", {"script": sid, "args": ["--probe", *args]})
    assert r.get("ok"), f"probe {args} 失败: {r}"
    assert r.get("rc") == 0, f"probe {args} rc={r.get('rc')} errors={r.get('errors')}"
    time.sleep(0.15)


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


def del_val(path, name, root=None):
    import winreg
    root = root if root is not None else winreg.HKEY_CURRENT_USER
    try:
        k = winreg.OpenKey(root, path, 0, winreg.KEY_SET_VALUE | winreg.KEY_WOW64_64KEY)
        try:
            winreg.DeleteValue(k, name)
        finally:
            winreg.CloseKey(k)
    except OSError:
        pass


def set_val(path, name, value, root=None):
    import winreg
    root = root if root is not None else winreg.HKEY_CURRENT_USER
    k = winreg.CreateKeyEx(root, path, 0, winreg.KEY_SET_VALUE | winreg.KEY_WOW64_64KEY)
    try:
        winreg.SetValueEx(k, name, 0, winreg.REG_SZ, value)
    finally:
        winreg.CloseKey(k)


def clean_shadow():
    import winreg
    for name in ("ProgrammaticAccessOnly", "Position"):
        del_val(SHADOW, name)
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
    r = m.call("run_script", {"script": sid,
                              "args": ["--selftest", str(OUT.resolve()).replace("\\", "/")]})
    assert r.get("ok"), f"selftest 启动失败: {r}"
    for _ in range(30):
        if OUT.exists():
            break
        time.sleep(0.1)
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8-sig")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("三场景", "桌面空白=背景+个性化", "文件对象展开四类来源",
               "文件夹对象展开三类来源", "多来源状态合并", "多来源位置合并",
               "四种隐藏标记都认", "系统共享 CLSID 识别"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/6] selftest 14 项全绿（三场景/来源合并/共享CLSID）")


def test_roots(m, sid):
    md = HOST / ".ex" / "右键菜单" / "右键菜单项目原理调研报告.md"
    folder = HOST / ".ex" / "右键菜单"
    cases = [
        ("deskbg", "", ["Directory\\Background", "DesktopBackground"]),
        ("dirbg", "", ["Directory\\Background"]),
        ("obj", str(md), ["*", "AllFilesystemObjects", "SystemFileAssociations\\.md"]),
        ("obj", str(folder), ["Directory", "Folder", "AllFilesystemObjects"]),
    ]
    for key, path, expect in cases:
        ROOTS_OUT.unlink(missing_ok=True)
        args = ["--probe", "roots", key, str(ROOTS_OUT.resolve()).replace("\\", "/")]
        if path:
            args.append(path)
        probe(m, sid, *args[1:])  # probe() 自己补 --probe
        assert ROOTS_OUT.exists(), f"roots 探针未写文件: {key}"
        got = ROOTS_OUT.read_text(encoding="utf-8-sig").split(",")
        assert got == expect, f"{key} 展开错: 期望 {expect} 实际 {got}"
    print("  [2/6] 三场景位置根实测正确（桌面多个性化、文件/文件夹各自展开）")


def test_geometry(m, sess):
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    w = ui["windows"][0]
    c = w["client"]
    assert c["w"] == 820 and c["h"] == 450, f"客户区错: {c}"
    texts = [x.get("text", "") for x in w["controls"]]
    for name in ("拖入文件/文件夹", "桌面空白处", "文件夹空白处", "把文件或文件夹", "拖到这里", "当前：未拖入"):
        assert name in texts, f"缺入口/拖入区 {name}"
    for name in ("隐藏", "显示", "置顶", "置底", "恢复位置", "刷新"):
        assert name in texts, f"缺按钮 {name}"
    for name in ("菜单项", "来源", "状态", "位置"):
        assert name in texts, f"缺表头 {name}"
    lv = [x for x in w["controls"] if x.get("class") == "SysListView32"]
    assert lv and lv[0]["items"]["columns"] == 4, "列表应四列"
    print("  [3/6] GUI 几何 820×450 + 3 入口 + 拖入区 + 四列 + 6 按钮")


def click_nav(m, sess, y, expect_text, fewer_than=None):
    inp = m.call("send_input", {"session": sess, "action": "click", "x": 86, "y": y})
    assert inp.get("ok"), f"点导航失败: {inp}"
    time.sleep(0.4)
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    lv = [x for x in ui["windows"][0]["controls"] if x.get("class") == "SysListView32"][0]
    rows = lv["items"]["rows"]
    st = [c.get("text", "") for c in ui["windows"][0]["controls"]
          if c.get("client", {}).get("y") == 418 and c.get("text")]
    assert st and st[0].startswith(expect_text), f"状态栏错: {st}"
    assert len(rows) >= 3, f"{expect_text} 应列出真实菜单项，实际 {len(rows)}"
    if fewer_than is not None:
        assert len(rows) < fewer_than, f"{expect_text} 项数应少于桌面: {len(rows)} vs {fewer_than}"
    return rows


def test_scenes(m, sess):
    desk = click_nav(m, sess, 62, "桌面空白处")
    folder = click_nav(m, sess, 94, "文件夹空白处", fewer_than=len(desk))
    srcs = {r[1] for r in desk}
    assert "静态" in srcs and "COM" in srcs, f"来源列应含静态+COM: {srcs}"
    print(f"  [4/6] 场景切换：桌面 {len(desk)} 项 > 文件夹空白 {len(folder)} 项（多个性化项），两来源齐")


def test_hide_show(m, sid):
    import winreg
    clean_shadow()
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "前置清理失败"
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "hide")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") == "", "隐藏应写空串"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "show")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "恢复后应删标记"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    print("  [5a/6] L1 隐藏/恢复 → HKCU 影子键增删、HKLM 原键不变")


def test_position(m, sid):
    import winreg
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "top")
    assert winreg_val(SHADOW, "Position") == "top", "置顶错"
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "bottom")
    assert winreg_val(SHADOW, "Position") == "bottom", "置底错"
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "default")
    assert winreg_val(SHADOW, "Position") is None, "恢复后应无 Position"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    clean_shadow()
    print("  [5b/6] L1 位置三档 → HKCU Position 正确、HKLM 不变、清理干净")


def test_com_block(m, sid):
    import winreg
    blocked_before = winreg_val(BLOCKED, TEST_CLSID)
    clsid_before = winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT)
    hklm_before = winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE)
    try:
        probe(m, sid, "com", TEST_CLSID, "hide")
        assert winreg_val(BLOCKED, TEST_CLSID) == "", "Blocked 应按 CLSID 写空串"
        assert winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT) == clsid_before, "HKCR CLSID 被改动！"
        assert winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE) == hklm_before, "HKLM CLSID 被改动！"
        probe(m, sid, "com", TEST_CLSID, "show")
        assert winreg_val(BLOCKED, TEST_CLSID) is None, "恢复后 Blocked 应删"
        assert winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT) == clsid_before, "HKCR CLSID 被改动！"
        assert winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE) == hklm_before, "HKLM CLSID 被改动！"
        print("  [6/6] L2 隐藏/恢复 → HKCU Blocked 按 CLSID 增删、CLSID/HKLM 原键不变")
    finally:
        if blocked_before is not None:
            set_val(BLOCKED, TEST_CLSID, blocked_before)
        else:
            del_val(BLOCKED, TEST_CLSID)


def main():
    m = MCP()
    try:
        m.initialize()
        sid = find_sid(m)
        assert sid, "脚本未出现在 list_scripts：先复制到 .build/Scripts"
        test_selftest(m, sid)
        test_roots(m, sid)
        clean_shadow()
        run = m.call("run_script", {"script": sid, "timeout_ms": 3000})
        assert run.get("ok") and not run.get("errors"), f"启动失败: {run}"
        sess = run["session"]
        time.sleep(0.8)
        test_geometry(m, sess)
        test_scenes(m, sess)
        test_hide_show(m, sid)
        test_position(m, sid)
        test_com_block(m, sid)
        out = m.call("get_session_output", {"session": sess})
        assert out.get("ok") and not out.get("fatal"), f"运行期致命错误: {out}"
        print("ALL PASS")
        return 0
    finally:
        clean_shadow()
        m.call("stop_all")
        m.close()


if __name__ == "__main__":
    sys.exit(main())
