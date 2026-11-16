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
import subprocess
import sys
import urllib.parse
from pathlib import Path

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
    notes = re.sub(r"[A-Za-z]:\\\\[^\s`\"'）)]+", "[path]", notes)  # Windows 路径
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


def api_gitee(token: str, owner: str, repo: str, tag: str, name: str, body: str,
              branch: str, apply: bool) -> int:
    base = f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases"
    payload = {"access_token": token, "tag_name": tag, "name": name,
               "target_commitish": branch, "body": body, "prerelease": False}
    if not apply:
        print(f"[dry] Gitee POST {base} tag={tag} (body {len(body)} chars)")
        return -1
    import urllib.request
    req = urllib.request.Request(base, data=ascii_json(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        rel = json.loads(resp.read().decode("utf-8", "replace"))
    print(f"Gitee release created: {rel.get('id')}")
    return int(rel["id"])


def attach_gitee(token: str, owner: str, repo: str, rel_id: int, asset: Path, apply: bool) -> None:
    url = f"https://gitee.com/api/v5/repos/{owner}/{repo}/releases/{rel_id}/attach_files"
    if not apply:
        print(f"[dry] Gitee attach_files {asset.name}")
        return
    # token 只进 stdin 配置，不进 argv；用 curl.exe（不是 curl，后者是 PS 别名——Python 里无此问题，但保持一致）
    cfg = (f'url = "{url}"\n'
           f'header = "Authorization: Bearer {token}"\n'
           f'form = "file=@{asset.as_posix()}"\n')
    p = subprocess.run(["curl.exe", "-s", "-K", "-"], input=cfg, text=True,
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
    run(["gh", "release", "create", tag, "--repo", f"{owner}/{repo}",
         "--title", name, "--notes-file", str(notes_path)])
    token = subprocess.run(["gh", "auth", "token"], capture_output=True,
                           text=True, encoding="utf-8", check=True).stdout.strip()
    rel_id = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/releases/tags/{tag}", "--jq", ".id"],
        capture_output=True, text=True, encoding="utf-8",
        check=True).stdout.strip()
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

    # 附件：优先 zip（有附属文件时由 pack_script.py 预生成），否则单 .ahk
    zip_path = ROOT / "dist" / (args.script + ".zip")
    asset = zip_path if zip_path.is_file() else ahk
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
            attach_gitee(token, owner, repo, rel_id, asset, True)
    if args.Only != "gitee":
        release_github(gh_owner, repo, tag, f"{args.script} {ver}", notes_path, asset,
                       f"{ident}{asset.suffix}", args.Apply)

    # 更新 history/<id>.json：追加/替换该版本一条（dry-run 不落盘）
    hist_file = HISTORY_DIR / (ident + ".json")
    if args.Apply:
        doc = json.loads(hist_file.read_text(encoding="utf-8")) if hist_file.is_file() else {
            "name": args.script, "id": ident, "versions": []}
        versions = [v for v in doc["versions"] if v["version"] != ver]
        entry = {
            "version": ver, "date": fields["date"],
            "gitee": f"https://gitee.com/{owner}/{repo}/releases/download/{tag}/{urllib.parse.quote(asset.name, safe='.')}",
            # GitHub rejects URL-encoded Chinese asset names (stores default.ahk),
            # so its asset is named <id><suffix>; Gitee keeps the Chinese name.
            "github": f"https://github.com/{gh_owner}/{repo}/releases/download/{tag}/{ident}{asset.suffix}",
            "sizeKb": round(len(asset.read_bytes().replace(b"\r\n", b"\n")) / 1024, 1),
        }
        versions.append(entry)
        versions.sort(key=lambda v: [int(x) for x in v["version"].split(".")])
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
