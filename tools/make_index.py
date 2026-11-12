#!/usr/bin/env python3
"""生成 scripts.json —— 宿主以后做「官方脚本下载」读的那份机器清单。

形状照 rupix decoders.json/plugins.json：顶层数组、一项一脚本，无 id 包裹层、无 sha256。
关键差异：我们是单个 .ahk 文本（不是 zip 包），下载地址用 raw 文本地址，按脚本名自动推导，
钉里程碑 tag（不建 release）。字段 = 头部 11 必填的直接投影 + path/size_kb/gitee/github 四个计算字段。

用法：
    python tools/make_index.py            # 扫脚本头部 → 写 scripts.json
    python tools/make_index.py --check    # 只校验 + 与现清单比对，漂移/缺字段 exit 1（门禁用）
    python tools/make_index.py --audit    # 仓库准入体检：布局/info/#Requires/全局热键/README/清单
    python tools/make_index.py --selftest # 自证钉子（含 audit 的违规检出）

清单是生成物，手改无意义：要改信息去改脚本头部。契约详见 开发指南.md §7.1。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import tempfile
from urllib.parse import quote

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts"
OUT = ROOT / "scripts.json"

# 官方脚本头部必填 11 项（可增不可缺，生成器逐项校验非空）。
REQUIRED = ("name", "namespace", "version", "description", "author", "date",
            "license", "homepageURL", "requires", "host", "entry")
# 清单字段顺序 = 契约，改顺序会让 git diff 难读。
FIELDS = ("name", "version", "date", "description", "author", "license",
          "requires", "host", "entry", "path", "size_kb", "gitee", "github")
# gitee owner → github owner：照 rupix，主机名和 owner 一起换（只换主机名会 404）。
GITHUB_OWNER = {"qiuzongman": "zongmanqiu"}
TAG = "2026-11-12-2"  # raw 地址钉里程碑 tag。同日多次发版加 -N 后缀（开发指南 §7.1）；每次重要更新换新 tag

# 行首热键/热字串定义。字符类不含 ':'，所以 ::hotstring:: 不会命中；
# #HotIf 上下文块内的按键（列表 UI 的 Delete:: 等）由 lint_script 单独放行。
GLOBAL_HOTKEY = re.compile(r"^\s*[~*$<>^!+#\w]+::")
# README 脚本列表行：| [名称](scripts/…/<名>.ahk) | 版本 | 日期 | 简介 |
README_ROW = re.compile(
    r"^\|\s*\[([^\]]+)\]\((scripts/[^)]+\.ahk)\)\s*\|\s*([0-9][0-9.]*)\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|",
    re.M)


class HeaderError(ValueError):
    pass


def parse_header(text: str) -> dict:
    """取 ; ==UserScript== … ; ==/UserScript== 块里的 @key 值。"""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if l.strip() == "; ==UserScript=="), None)
    if start is None:
        raise HeaderError("缺 ; ==UserScript== 起始行")
    fields: dict[str, str] = {}
    for l in lines[start + 1:]:
        s = l.strip()
        if s == "; ==/UserScript==":
            return fields
        if s.startswith(";"):
            tok = s[1:].strip()
            if tok.startswith("@"):
                parts = tok[1:].split(None, 1)
                if parts:
                    fields[parts[0]] = parts[1].strip() if len(parts) > 1 else ""
    raise HeaderError("头部块缺 ; ==/UserScript== 结束行")


def validate(fields: dict, expect_name: str) -> None:
    missing = [k for k in REQUIRED if not fields.get(k, "").strip()]
    if missing:
        raise HeaderError("缺必填字段：" + ", ".join("@" + m for m in missing))
    if fields["name"] != expect_name:
        raise HeaderError(f"@name {fields['name']!r} 与文件夹/文件名 {expect_name!r} 不一致")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", fields["version"]):
        raise HeaderError(f"@version 形状不对：{fields['version']!r}")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", fields["date"]):
        raise HeaderError(f"@date 应为 YYYY-MM-DD：{fields['date']!r}")


def split_namespace(ns: str) -> tuple[str, str]:
    """https://gitee.com/<owner>/<repo>[/…] → (owner, repo)。"""
    u = ns.strip().rstrip("/")
    if "://" in u:
        u = u.split("://", 1)[1]
    parts = u.split("/")
    if len(parts) < 3 or not parts[1] or not parts[2]:
        raise HeaderError(f"@namespace 形状不对（应含 owner/repo）：{ns!r}")
    return parts[1], parts[2]


def build_entry(ahk: pathlib.Path, fields: dict, base: pathlib.Path) -> dict:
    rel = ahk.relative_to(base).as_posix()
    owner, repo = split_namespace(fields["namespace"])
    gh_owner = GITHUB_OWNER.get(owner, owner)
    enc = quote(rel, safe="/")  # 中文路径 percent-encode，斜杠保留
    entry = {
        "name": fields["name"],
        "version": fields["version"],
        "date": fields["date"],
        "description": fields["description"],
        "author": fields["author"],
        "license": fields["license"],
        "requires": fields["requires"],
        "host": fields["host"],
        "entry": fields["entry"],
        "path": rel,
        # size 量 LF blob（git 存储/下载的字节），不量 CRLF 工作副本——后者随平台漂移、比下载内容大
        "size_kb": round(len(ahk.read_bytes().replace(b"\r\n", b"\n")) / 1024, 1),
        "gitee": f"https://gitee.com/{owner}/{repo}/raw/{TAG}/{enc}",
        "github": f"https://raw.githubusercontent.com/{gh_owner}/{repo}/{TAG}/{enc}",
    }
    return {k: entry[k] for k in FIELDS}


def scan(scripts_dir: pathlib.Path) -> list[dict]:
    if not scripts_dir.is_dir():
        raise HeaderError(f"脚本目录不存在：{scripts_dir}")
    base = scripts_dir.parent
    entries: list[dict] = []
    for sub in sorted(scripts_dir.iterdir()):
        if not sub.is_dir():
            # 散落的 .ahk 原先被静默跳过：清单里没有它，也不报错（新脚本放错位置查不出来）。
            if sub.suffix.lower() == ".ahk":
                raise HeaderError(f"scripts/ 下不允许散落 .ahk：{sub.name}（应放 <名>/<名>.ahk）")
            continue
        ahk = sub / (sub.name + ".ahk")
        if not ahk.is_file():
            raise HeaderError(f"{sub.name}/ 下没有同名 {sub.name}.ahk")
        fields = parse_header(ahk.read_text(encoding="utf-8-sig"))
        validate(fields, sub.name)
        entries.append(build_entry(ahk, fields, base))
    if not entries:
        raise HeaderError("扫到 0 个脚本（scripts/ 下没有任何 <名>/<名>.ahk）")
    entries.sort(key=lambda e: e["name"])
    return entries


def render(entries: list[dict]) -> str:
    return json.dumps(entries, indent=2, ensure_ascii=False) + "\n"


def lint_layout(scripts_dir: pathlib.Path) -> list[str]:
    """仓库布局：一脚本一文件夹、info/ 两件式。对应 开发指南 §1 / §8。"""
    problems: list[str] = []
    if not scripts_dir.is_dir():
        return [f"缺 scripts/ 目录：{scripts_dir}"]
    for sub in sorted(scripts_dir.iterdir()):
        if not sub.is_dir():
            if sub.suffix.lower() == ".ahk":
                problems.append(f"scripts/ 下不允许散落 .ahk：{sub.name}（应放 <名>/<名>.ahk）")
            continue
        if not (sub / (sub.name + ".ahk")).is_file():
            problems.append(f"{sub.name}/ 缺同名 {sub.name}.ahk")
        for doc in ("README.md", "HISTORY.md"):
            if not (sub / "info" / doc).is_file():
                problems.append(f"{sub.name}/info/ 缺 {doc}")
    return problems


def lint_script(ahk: pathlib.Path) -> list[str]:
    """单个脚本的硬规矩：#Requires 与「不自设全局热键」。对应 开发指南 §2 / §4。"""
    problems: list[str] = []
    text = ahk.read_text(encoding="utf-8-sig")
    if not re.search(r"(?mi)^\s*#Requires\s+AutoHotkey\s+v2", text):
        problems.append(f"{ahk.name} 缺 #Requires AutoHotkey v2.0")
    in_context = False
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s == "#HotIf":
            in_context = False
        elif s.startswith("#HotIf "):
            in_context = True
        elif (not in_context and s and not s.startswith(";")
              and GLOBAL_HOTKEY.match(line)):
            problems.append(f"{ahk.name}:{n} 疑似全局热键（§2 不自设全局热键）：{s[:60]}")
    return problems


def lint_readme(root: pathlib.Path, entries: list[dict]) -> list[str]:
    """README 脚本列表的 名称/版本/日期 必须与清单一致——手工维护最容易漂移。"""
    p = root / "README.md"
    if not p.is_file():
        return ["缺 README.md"]
    rows = README_ROW.findall(p.read_text(encoding="utf-8-sig"))
    got = {(n, v, d) for n, _path, v, d in rows}
    want = {(e["name"], e["version"], e["date"]) for e in entries}
    problems = []
    for n, v, d in sorted(want - got):
        problems.append(f"README 脚本列表缺项或版本/日期漂移：{n} {v} {d}")
    for n, v, d in sorted(got - want):
        problems.append(f"README 脚本列表有清单外的项：{n} {v} {d}")
    return problems


def audit(root: pathlib.Path, out: pathlib.Path) -> tuple[list[str], int]:
    """仓库准入体检：把开发指南的硬规矩变成一条命令。返回 (问题清单, 脚本数)。"""
    scripts_dir = root / "scripts"
    problems = lint_layout(scripts_dir)
    try:
        entries = scan(scripts_dir)
    except HeaderError as e:
        # 散落 .ahk 已在 lint_layout 报过，避免同一问题打印两遍。
        if not any("散落" in x for x in problems):
            problems.append(f"头部/清单：{e}")
        return problems, 0
    for e in entries:
        problems += lint_script(root / e["path"])
    problems += lint_readme(root, entries)
    if not out.is_file():
        problems.append("缺 scripts.json（跑 python tools/make_index.py 重生成）")
    elif out.read_text(encoding="utf-8-sig") != render(entries):
        problems.append("scripts.json 与脚本头部漂移（跑 python tools/make_index.py 重生成）")
    return problems, len(entries)


def fixture_header(**over) -> str:
    base = {
        "name": "双击防抖", "namespace": "https://gitee.com/qiuzongman/ahk-v2-scripts",
        "version": "1.0.0", "description": "一句话", "author": "邱宗满", "date": "2026-11-11",
        "license": "AGPL-3.0", "homepageURL": "https://gitee.com/qiuzongman/ahk-v2-scripts",
        "requires": "AutoHotkey v2.0", "host": "AHKDeck 0.2.2+（亦可独立运行）", "entry": "托盘菜单「设置」",
    }
    lines = ["; ==UserScript=="]
    for k in REQUIRED:
        if k in over and over[k] is None:
            continue
        v = over.get(k, base[k])
        lines.append((f"; @{k:<12} {v}").rstrip() if v else f"; @{k}")
    lines.append("; ==/UserScript==")
    return "\n".join(lines) + "\n"


def fixture_repo(root: pathlib.Path, *, extra: str = "", header: str | None = None,
                 no_requires: bool = False, drop_history: bool = False,
                 readme_version: str = "1.0.0", stray: bool = False) -> None:
    """造一个最小合规仓库；各开关用来把某条规矩弄红，证明 audit 能检出。"""
    sd = root / "scripts"
    d = sd / "双击防抖"
    (d / "info").mkdir(parents=True)
    h = header if header is not None else fixture_header()
    body = ("" if no_requires else "#Requires AutoHotkey v2.0\n") + h + extra
    (d / "双击防抖.ahk").write_text(body, encoding="utf-8")
    (d / "info" / "README.md").write_text("# 双击防抖\n", encoding="utf-8")
    if not drop_history:
        (d / "info" / "HISTORY.md").write_text("# 历史\n", encoding="utf-8")
    (root / "README.md").write_text(
        "# 脚本仓库\n\n| 名称 | 版本 | 时间 | 简介 |\n|---|---:|---|---|\n"
        f"| [双击防抖](scripts/双击防抖/双击防抖.ahk) | {readme_version} | 2026-11-11 | 一句话 |\n",
        encoding="utf-8")
    (root / "scripts.json").write_text(render(scan(sd)), encoding="utf-8", newline="\n")
    if stray:
        (sd / "散落.ahk").write_text("x", encoding="utf-8")


def selftest() -> int:
    fails: list[str] = []

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    def raises(fn, msg):
        try:
            fn()
        except HeaderError:
            return
        fails.append(msg)

    good = fixture_header()
    fields = parse_header(good)
    check(all(fields.get(k) for k in REQUIRED), "T1 完整头部应解析出 11 必填")
    validate(fields, "双击防抖")

    exp_gitee = (f"https://gitee.com/qiuzongman/ahk-v2-scripts/raw/{TAG}/scripts/"
                 "%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96/%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96.ahk")
    exp_github = (f"https://raw.githubusercontent.com/zongmanqiu/ahk-v2-scripts/{TAG}/scripts/"
                  "%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96/%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96.ahk")
    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td)
        sd = base / "scripts"
        (sd / "双击防抖").mkdir(parents=True)
        ahk = sd / "双击防抖" / "双击防抖.ahk"
        ahk.write_text(good, encoding="utf-8")
        e = build_entry(ahk, fields, base)
        check(e["gitee"] == exp_gitee, f"T2 gitee raw 地址不符：{e['gitee']}")
        check(e["github"] == exp_github, f"T3 github raw 地址不符（owner 未换？）：{e['github']}")
        check(e["path"] == "scripts/双击防抖/双击防抖.ahk", "T4 path 形状不对")

    raises(lambda: validate(parse_header(fixture_header(author=None)), "双击防抖"),
           "T5 缺 @author 应报错却通过")
    raises(lambda: validate(parse_header(fixture_header(description="")), "双击防抖"),
           "T6 空 @description 应报错却通过")
    raises(lambda: validate(parse_header(good), "别的名字"),
           "T7 @name 与文件夹不符应报错却通过")
    raises(lambda: validate(parse_header(fixture_header(date="2026/11/11")), "双击防抖"),
           "T8 @date 形状错应报错却通过")

    with tempfile.TemporaryDirectory() as td:
        sd = pathlib.Path(td) / "scripts"
        sd.mkdir()
        raises(lambda: scan(sd), "T9 扫 0 个脚本应报错却通过")

    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td)
        sd = base / "scripts"
        (sd / "双击防抖").mkdir(parents=True)
        (sd / "双击防抖" / "双击防抖.ahk").write_text(good, encoding="utf-8")
        text = render(scan(sd))
        out = base / "scripts.json"
        out.write_text(text, encoding="utf-8", newline="\n")
        check(out.read_text(encoding="utf-8-sig") == text, "T10 一致清单 --check 应通过")
        out.write_text(text.replace('"version": "1.0.0"', '"version": "9.9.9"'),
                       encoding="utf-8", newline="\n")
        check(out.read_text(encoding="utf-8-sig") != render(scan(sd)), "T10 漂移清单应被检出")

    check(GITHUB_OWNER.get("qiuzongman") == "zongmanqiu", "T11 owner 映射 qiuzongman→zongmanqiu")

    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td)
        sd = base / "scripts"
        (sd / "双击防抖").mkdir(parents=True)
        ahk = sd / "双击防抖" / "双击防抖.ahk"
        ahk.write_bytes(b"x" * 2048)  # 2.0 KB
        e = build_entry(ahk, fields, base)
        check(e.get("size_kb") == 2.0, f"T12 2048 B 应换算为 2.0 KB，实得 {e.get('size_kb')!r}")

    # 里程碑 tag 是日期 YYYY-MM-DD；同日多次发版按开发指南 §7.1 加 -N 后缀，
    # 两种形状都合法，分支名（master/main）一律拒绝。
    check(bool(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[0-9]+)?", TAG)),
          f"T13 TAG 应为里程碑日期 YYYY-MM-DD[-N]（不是分支名）：{TAG!r}")
    check(bool(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[0-9]+)?", "2026-11-12-2")),
          "T22 同日第二个 tag（2026-11-12-2）应被接受")
    check(not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[0-9]+)?", "master"),
          "T22 分支名 master 不应被当成里程碑 tag")

    with tempfile.TemporaryDirectory() as td:
        base = pathlib.Path(td)
        sd = base / "scripts"
        (sd / "双击防抖").mkdir(parents=True)
        ahk = sd / "双击防抖" / "双击防抖.ahk"
        ahk.write_bytes(b"x\r\n" * 512)  # 1536 B CRLF → 1024 B LF
        e = build_entry(ahk, fields, base)
        check(e.get("size_kb") == 1.0,
              f"T14 size 应量 LF blob（1536 CRLF→1024 LF=1.0 KB），实得 {e.get('size_kb')!r}")

    # --- audit 钉子：合规仓库全绿，逐项弄红都要被检出 ---
    def audited(**kw):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            fixture_repo(root, **kw)
            probs, n = audit(root, root / "scripts.json")
            return probs, n

    p, n = audited()
    check(p == [] and n == 1, f"T15 合规仓库 audit 应全绿，实得 n={n} probs={p}")

    p, _ = audited(stray=True)
    check(any("散落" in x for x in p), f"T16 散落 .ahk 应被检出，实得 {p}")

    p, _ = audited(drop_history=True)
    check(any("HISTORY" in x for x in p), f"T17 缺 info/HISTORY.md 应被检出，实得 {p}")

    p, _ = audited(no_requires=True)
    check(any("#Requires" in x for x in p), f"T18 缺 #Requires 应被检出，实得 {p}")

    p, _ = audited(extra="\nF6::MsgBox('x')\n")
    check(any("全局热键" in x for x in p), f"T19 全局热键应被检出，实得 {p}")

    # #HotIf 上下文块内的按键是正常列表 UI，不算全局热键（§2 明确放行）。
    p, _ = audited(extra=("\n#HotIf WinActive('A')\nDelete::DeleteChecked()\n#HotIf\n"))
    check(not any("全局热键" in x for x in p), f"T20 #HotIf 上下文按键不应误报，实得 {p}")

    p, _ = audited(readme_version="9.9.9")
    check(any("README" in x for x in p), f"T21 README 版本漂移应被检出，实得 {p}")

    if fails:
        print("SELFTEST FAIL：")
        for f in fails:
            print("  - " + f)
        return 1
    print("SELFTEST PASS（22 组钉子全绿）")
    return 0


def main(argv=None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="生成 scripts.json（宿主官方脚本下载清单）")
    ap.add_argument("--check", action="store_true", help="只校验 + 与现清单比对，漂移 exit 1")
    ap.add_argument("--audit", action="store_true", help="仓库准入体检（布局/info/#Requires/全局热键/README/清单）")
    ap.add_argument("--selftest", action="store_true", help="跑自证钉子")
    ap.add_argument("--out", default=OUT, help="输出路径（默认 <repo>/scripts.json）")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    out = pathlib.Path(args.out)

    if args.audit:
        problems, n = audit(ROOT, out)
        if problems:
            print("AUDIT FAIL：")
            for p in problems:
                print("  - " + p)
            return 1
        print(f"AUDIT PASS（{n} 个脚本：布局 / info 两件式 / #Requires / 全局热键 / README / 清单一致）")
        return 0

    try:
        entries = scan(SCRIPTS_DIR)
    except HeaderError as e:
        print(f"错误：{e}", file=sys.stderr)
        return 1
    text = render(entries)

    if args.check:
        if not out.is_file():
            print(f"错误：清单不存在 {out}（先跑 python tools/make_index.py）", file=sys.stderr)
            return 1
        if out.read_text(encoding="utf-8-sig") != text:
            print("错误：scripts.json 与脚本头部漂移，跑 python tools/make_index.py 重生成",
                  file=sys.stderr)
            return 1
        print(f"--check 一致（{len(entries)} 个脚本）")
        return 0

    out.write_text(text, encoding="utf-8", newline="\n")
    print(f"写入 {out}（{len(entries)} 个脚本，{len(text.encode('utf-8'))} B）")
    for e in entries:
        print(f"  {e['name']}  {e['version']}  {e['date']}  {e['size_kb']} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
