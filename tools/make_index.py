#!/usr/bin/env python3
"""生成 scripts.json —— 宿主以后做「官方脚本下载」读的那份机器清单。

形状照 rupix decoders.json/plugins.json：顶层数组、一项一脚本，无 id 包裹层、无 sha256。
关键差异：我们是单个 .ahk 文本（不是 zip 包），下载地址用 raw 文本地址，按脚本名自动推导，
钉里程碑 tag（不建 release）。字段 = 头部 11 必填的直接投影 + path/size_kb/gitee/github 四个计算字段。

用法：
    python tools/make_index.py            # 扫脚本头部 → 写 scripts.json

只有这一个动作。**不要**给生成器加「全仓体检 / 全量自测」一类的子命令：
改 A 脚本就只测 A 脚本，跑全量会把 B 脚本的问题砸到 A 的改动头上（AGENTS.md 第 12 条）。
单脚本静态检查用 `python tools/ui_static.py <脚本名>`。

清单是生成物，手改无意义：要改信息去改脚本头部。契约详见 开发指南.md §7.1。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
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
# m185: the official manifest names itself. The host reads this instead of
# hard-coding a label, so every source (official or subscribed) follows
# the same rule: the name comes from the json it was fetched from.
MANIFEST_NAME = "AHKDeck"
TAG = "2026-11-15"  # raw 地址钉里程碑 tag。同日多次发版加 -N 后缀（开发指南 §7.1）；每次重要更新换新 tag


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
    # Object form carries the manifest name; ParseScriptCatalog also
    # accepts the old bare array, so pre-m185 manifests stay valid.
    return json.dumps({"name": MANIFEST_NAME, "scripts": entries},
                     indent=2, ensure_ascii=False) + "\n"

def main(argv=None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="生成 scripts.json（宿主官方脚本下载清单）")
    ap.add_argument("--out", default=OUT, help="输出路径（默认 <repo>/scripts.json）")
    args = ap.parse_args(argv)

    out = pathlib.Path(args.out)

    try:
        entries = scan(SCRIPTS_DIR)
    except HeaderError as e:
        print(f"错误：{e}", file=sys.stderr)
        return 1
    text = render(entries)

    out.write_text(text, encoding="utf-8", newline="\n")
    print(f"写入 {out}（{len(entries)} 个脚本，{len(text.encode('utf-8'))} B）")
    for e in entries:
        print(f"  {e['name']}  {e['version']}  {e['date']}  {e['size_kb']} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
