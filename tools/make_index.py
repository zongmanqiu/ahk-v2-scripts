#!/usr/bin/env python3
"""生成 scripts.json —— 宿主做「官方脚本下载」读的那份机器清单。

形状照 rupix decoders.json/plugins.json：顶层对象 {name, scripts:[...]}，一项一脚本，无 sha256。
字段 = 头部 12 必填的直接投影 + path/size_kb/id + 双源下载地址 + 双源版本历史链接。

m221 变更：下载地址从 raw 文本改为 **release 附件地址**（tag = <英文id>-<版本>）；
新增每个脚本的英文 id 与双源 history 链接。契约详见 开发指南 §7.1。

用法：
    python tools/make_index.py            # 扫脚本头部 + history/ → 写 scripts.json

**不要**给生成器加「全仓体检 / 全量自测」一类的子命令：改 A 脚本就只测 A 脚本
（AGENTS.md 第 12 条）。单脚本静态检查用 `python tools/ui_static.py <脚本名>`。

清单是生成物，手改无意义：要改信息去改脚本头部 / history/*.json。
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
HISTORY_DIR = ROOT / "history"
OUT = ROOT / "scripts.json"

# 官方脚本头部必填 12 项（m221 加 id，可增不可缺，生成器逐项校验非空）。
REQUIRED = ("name", "id", "namespace", "version", "description", "author", "date",
            "license", "homepageURL", "requires", "host", "entry")
# 清单字段顺序 = 契约，改顺序会让 git diff 难读。
FIELDS = ("name", "id", "version", "date", "description", "author", "license",
          "requires", "host", "entry", "path", "size_kb", "gitee", "github",
          "package", "packageGithub", "history", "historyGithub")
# gitee owner → github owner：照 rupix，主机名和 owner 一起换（只换主机名会 404）。
GITHUB_OWNER = {"qiuzongman": "zongmanqiu"}
MANIFEST_NAME = "AHKDeck"
# m221: 版本历史清单钉默认分支（脚本仓库是 master），不是 tag —— 每次发版都被覆盖成最新。
HISTORY_BRANCH = "master"
ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")


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
    if not ID_RE.fullmatch(fields["id"]):
        raise HeaderError(f"@id 形状不对（小写字母开头/数字/连字符）：{fields['id']!r}")
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


def asset_url(base: str, tag_path: str, filename: str) -> str:
    """release 附件地址；tag 段与文件名段分别 percent-encode。"""
    return f"{base}/releases/download/{quote(tag_path, safe='-')}/{quote(filename, safe='.')}"


def build_entry(ahk: pathlib.Path, fields: dict, base: pathlib.Path) -> dict:
    rel = ahk.relative_to(base).as_posix()
    owner, repo = split_namespace(fields["namespace"])
    gh_owner = GITHUB_OWNER.get(owner, owner)
    ident, ver = fields["id"], fields["version"]
    tag = f"{ident}-{ver}"
    # m221: the release asset is a zip when pack_script.py produced one,
    # otherwise the single .ahk. scripts.json and history/<id>.json must name
    # the SAME asset - publish_version.py regenerates the catalog after each
    # release, and a hard-coded .ahk name would make every zip script a 404.
    asset = base / "dist" / (ahk.parent.name + ".zip")
    if not asset.is_file():
        asset = ahk
    # m221: BOTH mirrors publish the asset under the same ASCII name
    # <id>.ahk/.zip. GitHub's uploads endpoint mangles URL-encoded Chinese
    # into "default.ahk"; using ASCII for both ends keeps the two URLs
    # identical and the file name stable. The Chinese display name lives in
    # the manifest's `name` field, not in the asset file name.
    filename = f"{ident}{asset.suffix}"
    raw = asset.read_bytes()
    if asset.suffix.lower() == ".ahk":
        raw = raw.replace(b"\r\n", b"\n")  # git stores LF; size is display-only
    size_kb = round(len(raw) / 1024, 1)
    gitee_url = asset_url(f"https://gitee.com/{owner}/{repo}", tag, filename)
    github_url = asset_url(f"https://github.com/{gh_owner}/{repo}", tag,
                           filename)
    is_zip = asset.suffix.lower() == ".zip"
    entry = {
        "name": fields["name"],
        "id": ident,
        "version": ver,
        "date": fields["date"],
        "description": fields["description"],
        "author": fields["author"],
        "license": fields["license"],
        "requires": fields["requires"],
        "host": fields["host"],
        "entry": fields["entry"],
        "path": rel,
        # 量实际附件的字节数：.ahk 折成 LF 大小，zip 按原始字节。仅供显示。
        "size_kb": size_kb,
        "gitee": gitee_url,
        "github": github_url,
        # m211/m221: the host still selects package mode by these two fields.
        # A zip asset fills both with the same URLs as gitee/github; a single
        # .ahk leaves them empty so the host downloads a plain file.
        "package": gitee_url if is_zip else "",
        "packageGithub": github_url if is_zip else "",
        # Gitee raw 走直接 CDN 域名，而不是 gitee.com/.../raw/...：
        # 后者 302 到带时效签名的 raw.giteeusercontent.com?...signature=...，
        # 用户点开/书签/转存后签名过期就失效；直连 CDN 无签名、无跳转。
        "history": (f"https://raw.giteeusercontent.com/{owner}/{repo}/raw/{HISTORY_BRANCH}/"
                    f"history/{quote(ident, safe='')}.json"),
        "historyGithub": (f"https://raw.githubusercontent.com/{gh_owner}/{repo}/"
                          f"{HISTORY_BRANCH}/history/{quote(ident, safe='')}.json"),
    }
    return {k: entry[k] for k in FIELDS}


def scan(scripts_dir: pathlib.Path) -> list[dict]:
    if not scripts_dir.is_dir():
        raise HeaderError(f"脚本目录不存在：{scripts_dir}")
    base = scripts_dir.parent
    entries: list[dict] = []
    seen_ids: dict[str, str] = {}
    for sub in sorted(scripts_dir.iterdir()):
        if not sub.is_dir():
            if sub.suffix.lower() == ".ahk":
                raise HeaderError(f"scripts/ 下不允许散落 .ahk：{sub.name}（应放 <名>/<名>.ahk）")
            continue
        ahk = sub / (sub.name + ".ahk")
        if not ahk.is_file():
            raise HeaderError(f"{sub.name}/ 下没有同名 {sub.name}.ahk")
        fields = parse_header(ahk.read_text(encoding="utf-8-sig"))
        validate(fields, sub.name)
        ident = fields["id"]
        if ident in seen_ids:
            raise HeaderError(f"@id 重复：{ident}（{seen_ids[ident]} 与 {sub.name}）")
        seen_ids[ident] = sub.name
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
        print(f"  {e['name']:<8} id={e['id']:<22} v{e['version']:<8} {e['size_kb']:>5} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
