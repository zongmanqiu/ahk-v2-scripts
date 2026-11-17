# -*- coding: utf-8 -*-
"""右键菜单整理 的实机回归（一次只跑本脚本）。

前置：把 <名>.ahk 复制进 .build/Scripts 平铺目录，再运行：
  python scripts/右键菜单整理/test/run.py

只起本脚本自己的 MCP 临时实例，不动用户手开的主程序。分六层：
  1. --selftest 纯函数断言（隐藏标记/位置/影子键/保护动词/扩展名/共享CLSID/COM显示名）
  2. GUI 几何：客户区 820×450、8 导航（含按扩展名）、四列列表、6 按钮、状态条
  3. 列表读真实 HKCR：非空的 verb+COM 两类、来源/状态三态/位置列
  4. L1 隐藏/恢复：影子键写 ProgrammaticAccessOnly、HKLM 原键不变
  5. L1 位置三档：Position 值正确、HKLM 不变
  6. L2 COM 隐藏/恢复：Blocked 键按 CLSID 增删、CLSID 原键与 HKLM 不变
     结束清理所有本测试写下的 HKCU 键，恢复原状
"""
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]  # scripts/<名>/test/run.py → 仓库根
sys.path.insert(0, str(ROOT / "tools"))
from mcp_client import MCP  # noqa: E402

NAME = "右键菜单整理"
OUT = Path(__file__).resolve().parent / "selftest-result.txt"

# L1 测试影子键：文件场景的一个 verb（不真存在，纯 HKCU 侧验证）
TEST_ROOT = r"*"          # --probe verb 传的是位置根 suffix（不含 \shell）
TEST_VERB = "pintohomefile"
SHADOW = "Software\\Classes\\*\\shell\\" + TEST_VERB

# L2 测试 CLSID：7-Zip（非系统共享，安全）；Blocked 键按 CLSID 增删
TEST_CLSID = "{23170F69-40C1-278A-1000-000100020000}"
BLOCKED = r"Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
CLSID_HKCR = "CLSID\\" + TEST_CLSID          # HKCR 读取不带 Software\Classes 前缀
CLSID_HKLM = "Software\\Classes\\CLSID\\" + TEST_CLSID


def find_sid(m):
    listed = m.call("list_scripts")
    for s in listed.get("scripts", []):
        if s["name"] == NAME + ".ahk":
            return s["id"]
    return None


def probe(m, sid, *args):
    """用脚本自己的 --probe 分支驱动写函数（与按钮共用同一套逻辑）。"""
    r = m.call("run_script", {"script": sid, "args": ["--probe", *args]})
    assert r.get("ok"), f"probe {args} 失败: {r}"
    assert not r.get("errors"), f"probe {args} 运行错误: {r.get('errors')}"
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


def set_val(path, name, value, root=None):
    import winreg
    root = root if root is not None else winreg.HKEY_CURRENT_USER
    k = winreg.CreateKeyEx(root, path, 0, winreg.KEY_SET_VALUE | winreg.KEY_WOW64_64KEY)
    try:
        winreg.SetValueEx(k, name, 0, winreg.REG_SZ, value)
    finally:
        winreg.CloseKey(k)


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


def clean_shadow():
    """清掉 L1 测试影子键的值与空键，绝不误删其它值。"""
    import winreg
    for name in ("ProgrammaticAccessOnly", "Position"):
        del_val(SHADOW, name, winreg.HKEY_CURRENT_USER)
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
    assert run.get("ok"), f"selftest 启动失败: {run}"
    for _ in range(30):
        if OUT.exists():
            break
        time.sleep(0.1)
    assert OUT.exists(), "--selftest 未写出结果文件"
    text = OUT.read_text(encoding="utf-8-sig")
    assert "fails=0" in text, f"自测有失败项:\n{text}"
    for kw in ("七个位置 + 按扩展名", "扩展名归一", "四种隐藏标记都认",
               "影子键只落在 HKCU", "保护 open/edit 动词",
               "系统共享 CLSID 识别、7-Zip 不误判", "COM 泛显示名回退注册名"):
        assert kw in text, f"自测断言缺失: {kw}"
    print("  [1/6] selftest 11 项全绿（含扩展名/共享CLSID/COM显示名）")


def test_geometry(m, sess):
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    w = ui["windows"][0]
    c = w["client"]
    assert c["w"] == 820 and c["h"] == 450, f"客户区错: {c}"
    texts = [x.get("text", "") for x in w["controls"]]
    for name in ("文件", "文件夹", "文件夹空白处", "驱动器", "文件夹对象",
                 "所有对象", "桌面背景", "按扩展名", "输入扩展名", "查询"):
        assert name in texts, f"缺导航/输入 {name}"
    for name in ("隐藏", "显示", "置顶", "置底", "恢复位置", "刷新"):
        assert name in texts, f"缺按钮 {name}"
    for name in ("菜单项", "来源", "状态", "位置"):
        assert name in texts, f"缺列表表头 {name}"
    lv = [x for x in w["controls"] if x.get("class") == "SysListView32"]
    assert lv and lv[0]["items"]["columns"] == 4, "列表应四列（菜单项/来源/状态/位置）"
    print("  [2/6] GUI 几何 820×450 + 8 导航 + 扩展名输入 + 四列列表 + 6 按钮 + 状态条")


def test_list(m, sess):
    ui = m.call("inspect_ui", {"session": sess, "items": True})
    lv = [x for x in ui["windows"][0]["controls"] if x.get("class") == "SysListView32"][0]
    rows = lv["items"]["rows"]
    assert len(rows) >= 3, f"文件场景应列出多个真实菜单项，实际 {len(rows)}"
    srcs = {r[1] for r in rows}
    assert "静态" in srcs and "COM" in srcs, f"来源列应含静态与 COM 两类: {srcs}"
    states = {r[2] for r in rows}
    assert states & {"显示", "已隐藏", "系统隐藏"}, f"状态分类不对: {states}"
    assert all(r[3] in ("默认", "置顶", "置底", "—") for r in rows), "位置列取值错（COM 应为 —）"
    com_rows = [r for r in rows if r[1] == "COM"]
    assert all(r[3] == "—" for r in com_rows), "COM 项位置列应为 —"
    print(f"  [3/6] 真实菜单项 {len(rows)} 个 · 静态+COM 两来源 · 状态{len(states)}态 · COM位置=—")


def test_hide_show(m, sid):
    import winreg
    clean_shadow()
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "前置清理失败"
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)

    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "hide")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") == "", \
        f"隐藏应写 ProgrammaticAccessOnly=''，实际 {winreg_val(SHADOW, 'ProgrammaticAccessOnly')!r}"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"

    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "show")
    assert winreg_val(SHADOW, "ProgrammaticAccessOnly") is None, "恢复后标记应删除"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    print("  [4/6] L1 隐藏/恢复 → HKCU 影子键标记增删、HKLM 原键不变")


def test_position(m, sid):
    import winreg
    lm_before = winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE)
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "top")
    assert winreg_val(SHADOW, "Position") == "top", f"置顶错: {winreg_val(SHADOW, 'Position')!r}"
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "bottom")
    assert winreg_val(SHADOW, "Position") == "bottom", f"置底错: {winreg_val(SHADOW, 'Position')!r}"
    probe(m, sid, "verb", TEST_ROOT, TEST_VERB, "default")
    assert winreg_val(SHADOW, "Position") is None, "恢复位置后应无 Position 值"
    assert winreg_val(SHADOW, "MUIVerb", winreg.HKEY_LOCAL_MACHINE) == lm_before, "HKLM 原键被改动！"
    clean_shadow()
    print("  [5/6] L1 位置三档 → HKCU Position 值正确、HKLM 原键不变、清理干净")


def test_com_block(m, sid):
    import winreg
    blocked_before = winreg_val(BLOCKED, TEST_CLSID)
    clsid_before = winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT)
    hklm_before = winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE)
    try:
        probe(m, sid, "com", TEST_CLSID, "hide")
        assert winreg_val(BLOCKED, TEST_CLSID) == "", \
            f"Blocked 应按 CLSID 写空串，实际 {winreg_val(BLOCKED, TEST_CLSID)!r}"
        assert winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT) == clsid_before, "HKCR CLSID 显示名被改动！"
        assert winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE) == hklm_before, "HKLM CLSID 原键被改动！"

        probe(m, sid, "com", TEST_CLSID, "show")
        assert winreg_val(BLOCKED, TEST_CLSID) is None, "恢复后 Blocked 值应删除"
        assert winreg_val(CLSID_HKCR, "", winreg.HKEY_CLASSES_ROOT) == clsid_before, "HKCR CLSID 显示名被改动！"
        assert winreg_val(CLSID_HKLM, "", winreg.HKEY_LOCAL_MACHINE) == hklm_before, "HKLM CLSID 原键被改动！"
        print("  [6/6] L2 隐藏/恢复 → HKCU Blocked 按 CLSID 增删、CLSID 显示名与 HKLM 原键不变")
    finally:
        # 恢复测试前原状：原本已 Blocked 就写回，否则删掉
        if blocked_before is not None:
            set_val(BLOCKED, TEST_CLSID, blocked_before, winreg.HKEY_CURRENT_USER)
        else:
            del_val(BLOCKED, TEST_CLSID, winreg.HKEY_CURRENT_USER)


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
        test_com_block(m, sid)

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
