#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""m221: 发布某个官方脚本的某个版本到 Gitee/GitHub release。

流程（默认 dry-run，-Apply 才真发）：
  1. 读 scripts/<名>/<名>.ahk 头部，校验必填（含 @id）；
  2. 核对 @version 与 info/HISTORY.md 顶部小节一致；
  3. 准备附件：单文件 = <名>.ahk；多文件 = pack_script.py 打出的 <名>.zip（有附属文件时）；
  4. 建 tag <id>-<版本> → 建 release（说明取 HISTORY 对应版本小节，脱敏）→ 传附件；
  5. 更新 history/<id>.json（追加该版本一条）；重生成 scripts.json。

安全：dry-run 默认、-Apply 才发；凭据走 git credential fill / gh auth，
token 不进代码/.temp/git config/argv/日志；无凭据开网页让用户授权后重试。
Gitee API 正文用 Latin-1 解码 → 非 ASCII 转 \\uXXXX（照 .main/build/7_release.ps1）。

用法：
  python tools/publish_version.py <脚本名>                 # dry-run：只打印将做什么
  python tools/publish_version.py <脚本名> -Apply          # 两端都发
  python tools/publish_version.py <脚本名> -Apply -Only gitee
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

# 同目录工具模块：附件形态判据与「从当前源码现打包」能力
from pack_script import build, has_attachments, read_entry_version

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
HISTORY_DIR = ROOT / "history"
GITHUB_OWNER = {"qiuzongman": "zongmanqiu"}
REQUIRED = ("name", "id", "namespace", "version", "description", "author", "date",
            "license", "homepageURL", "requires", "host", "entry")
ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
VER_RE = re.compile(r"^[0-9]+(\.[0-9]+)*$")


def run(cmd: list[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=ROOT, text=True, encoding="utf-8", errors="replace",
                          capture_output=capture, check=check)


def parse_header(text: str) -> dict[str, str]:
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if l.strip() == "; ==UserScript=="), None)
    if start is None:
        raise ValueError("缺 ; ==UserScript== 起始行")
    fields: dict[str, str] = {}
    for line in lines[start + 1:]:
        s = line.strip()
        if s == "; ==/UserScript==":
            return fields
        if s.startswith(";"):
            tok = s[1:].strip()
            if tok.startswith("@"):
                parts = tok[1:].split(None, 1)
                if parts:
                    fields[parts[0]] = parts[1].strip() if len(parts) > 1 else ""
    raise ValueError("缺 ; ==/UserScript== 结束行")


def split_namespace(ns: str) -> tuple[str, str]:
    u = ns.strip().rstrip("/")
    if "://" in u:
        u = u.split("://", 1)[1]
    parts = u.split("/")
    if len(parts) < 3:
        raise ValueError(f"@namespace 形状不对：{ns!r}")
    return parts[1], parts[2]


def history_notes(history_path: Path, version: str) -> str:
    """取 HISTORY.md 的 ## <版本>（日期）小节，脱敏本机路径与邮箱。"""
    text = history_path.read_text(encoding="utf-8-sig")
    pattern = re.compile(r"(?ms)^## " + re.escape(version) + r"[（(].*?(?=^## |\Z)")
    m = pattern.search(text)
    if not m:
        raise ValueError(f"HISTORY.md 没有 {version} 小节")
    notes = m.group(0).strip()
    notes = re.sub(r"[A-Za-z]:\\[^\s`\"'）)]*", "[path]", notes)  # Windows 路径（单反斜杠，覆盖 C:\Users\...）
    notes = re.sub(r"[\w.+-]+@[\w.-]+\.\w+", "[email]", notes)
    return notes


def ascii_json(obj: dict) -> str:
    """Gitee 按 Latin-1 解码正文：非 ASCII 转义成 \\uXXXX（照 7_release.ps1）。"""
    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return "".join(ch if ord(ch) < 128 else f"\\u{ord(ch):04X}" for ch in raw)


def git_credential(host: str) -> tuple[str, str]:
    data = f"protocol=https\nhost={host}\n\n"
    p = subprocess.run(["git", "credential", "fill"], input=data, text=True,
                       capture_output=True, cwd=ROOT)
    user = password = ""
    for line in (p.stdout or "").splitlines():
        if line.startswith("username="):
            user = line.split("=", 1)[1]
        elif line.startswith("password="):
            password = line.split("=", 1)[1]
    return user, password


def ensure_gitee_auth(owner: str) -> str:
    _, token = git_credential("gitee.com")
    if token:
        return token
    print("Gitee 未授权：打开 https://gitee.com/profile/personal_access_tokens 申请 token，")
    print("用 `git credential approve` 存入系统凭据管理器后重试。")
    raise SystemExit(3)


def ensure_gh_auth() -> None:
    p = run(["gh", "auth", "status"], capture=True, check=False)
    if p.returncode != 0:
        print("GitHub 未授权：运行 `gh auth login --web --git-protocol https` 后重试。")
        raise SystemExit(3)


def gitee_release_id(token: str, owner: str, repo: str, tag: str) -> int | None:
    """同版本重发：查 tag 对应的 release id，已存在返回 id，否则 None。

    token 走 header（不进 URL）——urlopen 抛错时 traceback 会带 URL，不能带凭据。
    """
    import urllib.request
    import urllib.error
    url = f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rel = json.loads(resp.read().decode("utf-8", "replace"))
        # Gitee 实测：tag 存在但还没建 release 时返回 HTTP 200 + body=`null`，
        # 不是 404。json.loads('null') -> None，必须先判空再取 id。
        if rel is None:
            return None
        return int(rel["id"])
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def api_gitee(token: str, owner: str, repo: str, tag: str, name: str, body: str,
              branch: str, apply: bool) -> int:
    base = f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases"
    payload = {"access_token": token, "tag_name": tag, "name": name,
               "target_commitish": branch, "body": body, "prerelease": False}
    if not apply:
        print(f"[dry] Gitee POST {base} tag={tag} (body {len(body)} chars)")
        return -1
    import urllib.request
    # 先查后建：同版本重发时 POST 会因 tag 已存在抛 HTTPError、rel["id"] 崩在半途。
    # 已存在就 PATCH 更新正文/标题（照 .main/build/7_release.ps1）——只复用 id 不更新，
    # 会让 HISTORY 修订后的说明发不出去。PATCH 沿用同一份 payload（含 access_token）。
    existing = gitee_release_id(token, owner, repo, tag)
    if existing is not None:
        patch_url = f"{base}/{existing}"
        req = urllib.request.Request(
            patch_url, data=ascii_json(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="PATCH")
        with urllib.request.urlopen(req, timeout=60) as resp:
            json.loads(resp.read().decode("utf-8", "replace"))
        print(f"Gitee release {tag} 已存在，PATCH 更新正文 id={existing}")
        return existing
    req = urllib.request.Request(base, data=ascii_json(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        rel = json.loads(resp.read().decode("utf-8", "replace"))
    print(f"Gitee release created: {rel.get('id')}")
    return int(rel["id"])


def drop_gitee_same_name(token: str, owner: str, repo: str, rel_id: int,
                         gitee_name: str) -> None:
    """同版本重发前先删掉同名附件。

    Gitee 的 attach_files 不做覆盖：同名再传会变成两条，而下载地址按名字解析、
    命中的仍是先传的那条（2026-11-17 实测：新包传上去，URL 下载到的还是旧文件，
    大小 25487 而不是 25517）。所以只上传不删除时「重发成功」是假的。
    """
    import urllib.request
    url = (f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases/"
           f"{rel_id}/attach_files")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        items = json.loads(resp.read().decode("utf-8", "replace"))
    for item in items:
        if item.get("name") != gitee_name:
            continue
        delete = urllib.request.Request(
            f"{url}/{int(item['id'])}",
            headers={"Authorization": f"Bearer {token}"}, method="DELETE")
        with urllib.request.urlopen(delete, timeout=60) as resp:
            resp.read()
        print(f"Gitee 同名附件 {item['id']}（{item.get('size')}B）已删除，准备重传")


def attach_gitee(token: str, owner: str, repo: str, rel_id: int, asset: Path,
                 gitee_name: str, apply: bool) -> None:
    url = f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases/{rel_id}/attach_files"
    if not apply:
        print(f"[dry] Gitee attach_files {gitee_name}")
        return
    drop_gitee_same_name(token, owner, repo, rel_id, gitee_name)
    # token 只进 stdin 配置，不进 argv；用 curl.exe（不是 curl，后者是 PS 别名——Python 里无此问题，但保持一致）
    # filename= overrides curl's default of using the local file name, so both
    # mirrors publish the same ASCII name (see make_index.py).
    cfg = (f'url = "{url}"\n'
           f'header = "Authorization: Bearer {token}"\n'
           f'form = "file=@{asset.as_posix()};filename={gitee_name}"\n')
    p = subprocess.run(["curl.exe", "-s", "-K", "-"], input=cfg, text=True,
                       encoding="utf-8", errors="replace",
                       capture_output=True, cwd=ROOT)
    m = re.search(r'"browser_download_url"\s*:\s*"([^"]+)"', p.stdout or "")
    if not m:
        raise RuntimeError(f"Gitee 附件上传失败：{(p.stdout or '')[:200]}")
    print("Gitee asset:", m.group(1))


def release_github(owner: str, repo: str, tag: str, name: str, notes_path: Path,
                   asset: Path, gh_name: str, apply: bool) -> None:
    if not apply:
        print(f"[dry] gh release create {tag} [asset {gh_name}] (notes {notes_path.name})")
        return
    # m221: create the release WITHOUT an asset, then upload via the uploads
    # endpoint with an explicit name=. Passing a Chinese path as an argv to
    # `gh release create` makes GitHub store it as "default.ahk" (Windows argv
    # mangles it), so the manifest's URL 404s. uploads + name=<quoted> keeps
    # the asset name byte-for-byte identical to scripts.json.
    # 同版本重发：create 对已存在 tag 抛 CalledProcessError，先探测再决定建不建。
    probe = subprocess.run(["gh", "release", "view", tag, "--repo", f"{owner}/{repo}"],
                           capture_output=True, text=True, encoding="utf-8", check=False)
    if probe.returncode == 0:
        print(f"GitHub release {tag} 已存在，跳过 create")
    else:
        run(["gh", "release", "create", tag, "--repo", f"{owner}/{repo}",
             "--title", name, "--notes-file", str(notes_path)])
    token = subprocess.run(["gh", "auth", "token"], capture_output=True,
                           text=True, encoding="utf-8", check=True).stdout.strip()
    rel_id = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/releases/tags/{tag}", "--jq", ".id"],
        capture_output=True, text=True, encoding="utf-8",
        check=True).stdout.strip()
    # 同名资产已存在时 uploads 会 422；重发前先删同名，再传（两端文件名一致，见 make_index）。
    old_ids = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/releases/tags/{tag}",
         "--jq", f'.assets[] | select(.name == "{gh_name}") | .id'],
        capture_output=True, text=True, encoding="utf-8", check=True).stdout.split()
    for aid in old_ids:
        subprocess.run(["gh", "api", "-X", "DELETE",
                        f"repos/{owner}/{repo}/releases/assets/{aid}"],
                       capture_output=True, check=True)
    import urllib.request
    # name= must be ASCII (see above); caller passes <id><suffix>, which is
    # exactly what scripts.json / history point at.
    url = (f"https://uploads.github.com/repos/{owner}/{repo}/releases/"
           f"{rel_id}/assets?name={gh_name}")
    req = urllib.request.Request(
        url, data=asset.read_bytes(), method="POST",
        headers={"Accept": "application/vnd.github+json",
                 "Authorization": f"Bearer {token}",
                 "Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        got = json.loads(resp.read().decode("utf-8"))
    if got.get("name") != gh_name:
        raise RuntimeError(f"GitHub asset name mismatch: {got.get('name')!r} != {gh_name!r}")
    print("GitHub asset:", got.get("browser_download_url"))


def main() -> int:
    ap = argparse.ArgumentParser(description="发布某个官方脚本版本到 Gitee/GitHub release")
    ap.add_argument("script", help="脚本中文名（scripts/<名> 目录）")
    ap.add_argument("-Apply", action="store_true", help="真正发布（默认只 dry-run）")
    ap.add_argument("-Only", choices=["gitee", "github"], help="只发一端")
    args = ap.parse_args()

    folder = SCRIPTS / args.script
    ahk = folder / (args.script + ".ahk")
    if not ahk.is_file():
        print(f"找不到脚本：{ahk}", file=sys.stderr)
        return 1
    fields = parse_header(ahk.read_text(encoding="utf-8-sig"))
    missing = [k for k in REQUIRED if not fields.get(k, "").strip()]
    if missing:
        print("缺必填字段：" + ", ".join("@" + m for m in missing), file=sys.stderr)
        return 1
    if not ID_RE.fullmatch(fields["id"]) or not VER_RE.fullmatch(fields["version"]):
        print("@id / @version 形状不对", file=sys.stderr)
        return 1

    ident, ver = fields["id"], fields["version"]
    tag = f"{ident}-{ver}"
    owner, repo = split_namespace(fields["namespace"])
    gh_owner = GITHUB_OWNER.get(owner, owner)
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture=True).stdout.strip()

    hist_md = folder / "info" / "HISTORY.md"
    notes = history_notes(hist_md, ver)
    notes_path = ROOT / ".temp" / f"script_release_notes_{ident}_{ver}.md"
    notes_path.parent.mkdir(exist_ok=True)
    notes_path.write_text(notes, encoding="utf-8", newline="\n")

    # 附件形态：唯一判据 = 脚本结构有没有附属文件（has_attachments），不看
    # dist/ 里有没有残留旧包。有附属文件 → 从当前源码现打 zip（build 覆盖残留），
    # 并校验包内入口 @version 与目标版本一致，不一致直接拒绝发布；无附属文件 →
    # 单 .ahk，dist/ 里残留的同名旧 zip 一律忽略（绝不把旧内容传上去）。
    if has_attachments(folder, args.script):
        asset = build(args.script, ROOT / "dist")
        pkg_ver = read_entry_version(asset, args.script)
        if pkg_ver != ver:
            raise SystemExit(
                f"包内 @version {pkg_ver} 与目标版本 {ver} 不一致——"
                f"{asset.name} 是残留旧包，拒绝发布（请检查 scripts/{args.script}/ 源码）")
    else:
        asset = ahk

    # curl.exe / gh 读不了中文本地路径（curl error 26：Failed to open local data）。
    # 上传前把附件复制成 ASCII 临时名（.temp 已 gitignore），两端都传这份。
    ascii_asset = ROOT / ".temp" / f"{ident}{asset.suffix}"
    ascii_asset.parent.mkdir(exist_ok=True)
    shutil.copyfile(asset, ascii_asset)
    asset = ascii_asset

    print(f"脚本={args.script} id={ident} 版本={ver} tag={tag}")
    print(f"附件={asset.relative_to(ROOT)}  分支={branch}  模式={'APPLY' if args.Apply else 'dry-run'}")
    print(f"发布说明（{len(notes)} 字符，脱敏）：\n{notes[:200]}...\n")

    token = ""
    if args.Apply and args.Only != "github":
        token = ensure_gitee_auth(owner)
    if args.Apply and args.Only != "gitee":
        ensure_gh_auth()

    if args.Apply:
        # tag：本地缺失则建，远端缺失则推
        local = run(["git", "rev-parse", "-q", "--verify", "refs/tags/" + tag],
                    capture=True, check=False).returncode == 0
        remote = run(["git", "ls-remote", "--exit-code", "origin", "refs/tags/" + tag],
                     capture=True, check=False).returncode == 0
        if not local:
            run(["git", "tag", "-a", tag, "-m", f"{args.script} {ver}"])
        if not remote:
            run(["git", "push", "origin", tag])

    if args.Only != "github":
        rel_id = api_gitee(token, owner, repo, tag, f"{args.script} {ver}", notes, branch, args.Apply)
        if args.Apply:
            attach_gitee(token, owner, repo, rel_id, asset,
                         f"{ident}{asset.suffix}", True)
    if args.Only != "gitee":
        release_github(gh_owner, repo, tag, f"{args.script} {ver}", notes_path, asset,
                       f"{ident}{asset.suffix}", args.Apply)

    # 更新 history/<id>.json：追加/替换该版本一条（dry-run 不落盘）
    hist_file = HISTORY_DIR / (ident + ".json")
    if args.Apply:
        doc = json.loads(hist_file.read_text(encoding="utf-8")) if hist_file.is_file() else {
            "name": args.script, "id": ident, "versions": []}
        versions = [v for v in doc["versions"] if v["version"] != ver]
        # sizeKb 与 make_index.py 同口径：只对 .ahk 做 CRLF→LF，zip 按原始字节，
        # 否则 history 的 sizeKb 会与 scripts.json 的 size_kb 对不上。
        asset_raw = asset.read_bytes()
        if asset.suffix.lower() == ".ahk":
            asset_raw = asset_raw.replace(b"\r\n", b"\n")
        entry = {
            "version": ver, "date": fields["date"],
            # Both mirrors publish the same ASCII name <id><suffix>; the
            # Chinese display name lives in scripts.json's `name` field.
            "gitee": f"https://gitee.com/{owner}/{repo}/releases/download/{tag}/{ident}{asset.suffix}",
            "github": f"https://github.com/{gh_owner}/{repo}/releases/download/{tag}/{ident}{asset.suffix}",
            "sizeKb": round(len(asset_raw) / 1024, 1),
        }
        versions.append(entry)
        # 降序：最新版本排第一条。与 info/HISTORY.md「新段在最上面」同序，
        # 点开 history json 的人第一眼看到的就是当前版本，将来宿主若要解析
        # 这个数组也不必自己再排一遍。
        versions.sort(key=lambda v: [int(x) for x in v["version"].split(".")], reverse=True)
        doc["versions"] = versions
        hist_file.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8", newline="\n")
        print("已更新", hist_file.name)
        run([sys.executable, str(ROOT / "tools" / "make_index.py")])
    else:
        print("[dry] 将更新 history/%s.json 并重生成 scripts.json" % ident)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
