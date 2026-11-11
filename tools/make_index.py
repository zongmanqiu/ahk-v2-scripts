#!/usr/bin/env python3
"""生成 scripts.json —— 宿主以后做「官方脚本下载」读的那份机器清单。

形状照 rupix decoders.json/plugins.json：顶层数组、一项一脚本，无 id 包裹层、无 sha256。
关键差异：我们是单个 .ahk 文本（不是 zip 包），下载地址用 raw 文本地址，按脚本名自动推导，
不建 release/tag。字段 = 头部 11 必填的直接投影 + path/size_kb/gitee/github 四个计算字段。

用法：
    python tools/make_index.py            # 扫脚本头部 → 写 scripts.json
    python tools/make_index.py --check    # 只校验 + 与现清单比对，漂移/缺字段 exit 1（门禁用）
    python tools/make_index.py --selftest # 自证钉子（缺必填必报错、raw 地址逐字符、扫 0 判失败）

清单是生成物，手改无意义：要改信息去改脚本头部。契约详见 开发指南.md §7.1。
"""

from __future__ import annotations

import argparse
import json
import pathlib
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
BRANCH = "main"  # 取最新，非版本锁定（单文本脚本不建 release/tag）


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
    import re
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
        "size_kb": round(ahk.stat().st_size / 1024, 1),
        "gitee": f"https://gitee.com/{owner}/{repo}/raw/{BRANCH}/{enc}",
        "github": f"https://raw.githubusercontent.com/{gh_owner}/{repo}/{BRANCH}/{enc}",
    }
    return {k: entry[k] for k in FIELDS}


def scan(scripts_dir: pathlib.Path) -> list[dict]:
    if not scripts_dir.is_dir():
        raise HeaderError(f"脚本目录不存在：{scripts_dir}")
    base = scripts_dir.parent
    entries: list[dict] = []
    for sub in sorted(scripts_dir.iterdir()):
        if not sub.is_dir():
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

    exp_gitee = ("https://gitee.com/qiuzongman/ahk-v2-scripts/raw/main/scripts/"
                 "%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96/%E5%8F%8C%E5%87%BB%E9%98%B2%E6%8A%96.ahk")
    exp_github = ("https://raw.githubusercontent.com/zongmanqiu/ahk-v2-scripts/main/scripts/"
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

    if fails:
        print("SELFTEST FAIL：")
        for f in fails:
            print("  - " + f)
        return 1
    print("SELFTEST PASS（12 组钉子全绿）")
    return 0


def main(argv=None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="生成 scripts.json（宿主官方脚本下载清单）")
    ap.add_argument("--check", action="store_true", help="只校验 + 与现清单比对，漂移 exit 1")
    ap.add_argument("--selftest", action="store_true", help="跑自证钉子")
    ap.add_argument("--out", default=OUT, help="输出路径（默认 <repo>/scripts.json）")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    out = pathlib.Path(args.out)
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