#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官方脚本打成发行 zip 包（多文件脚本包，宿主 m211 支持直接安装）。

包契约（宿主 .main/core/ScriptCatalog.cpp 与 docs/UI规范 无关，见脚本仓库《开发指南》
「多文件脚本包」一节）：
  * zip 根目录 = `<名>/`，入口 = `<名>/<名>.ahk`；
  * @name = 目录名 = zip 名，三者必须一致（宿主安装时逐项校验）；
  * info/ 与 test/ 是仓库资料，**不进包**；其余子目录/文件原样进包（运行时
    同名文件夹规则：脚本产物本来就写在 `A_ScriptDir\\<脚本名>\\`）。

用法：
    python tools/pack_script.py <脚本名>            # 输出到 dist/<名>.zip
    python tools/pack_script.py <脚本名> --out X:\\  # 输出到指定目录
    python tools/pack_script.py <脚本名> --list     # 只列出会打进包的内容

压缩器优先用 7-Zip（`7z a -tzip -mx=9`，Deflate 极限压缩，包更小）；找不到 7z 时
退回 Python zipfile（同为 Deflate，格式完全一致，体积略大）。**产物永远是标准
zip**——宿主用系统自带能力解压（资源管理器同一套代码），Win10/11 资源管理器
也能直接打开。
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# 不进发行包的目录/文件：
#   info/ test/       仓库资料；
#   AGENTS.md         目录级开发准则（2026-11-23 软件卸载起引入），同为仓库资料；
#   <名>/             运行时产物区（自测结果、history 等）——随包发行的附属文件
#                     （DLL、数据表）应放在 scripts/<名>/ 根，与 .ahk 同级。
EXCLUDE_DIRS = {"info", "test", "AGENTS.md"}


def find_7z() -> str | None:
    """常见的 7-Zip 位置，按优先级探测。"""
    candidates = [
        "7z",
        r"C:\Program Files\7-Zip\7z.exe",
        r"C:\Program Files (x86)\7-Zip\7z.exe",
        str(REPO.parent / ".3rd" / "7z" / "7z.exe"),
    ]
    for c in candidates:
        found = shutil.which(c) or (Path(c) if Path(c).is_file() else None)
        if found:
            return str(found)
    return None


def collect(src: Path, name: str) -> list[Path]:
    """会进包的相对路径（相对 zip 根 = `<名>/`）。"""
    files: list[Path] = []
    if not (src / f"{name}.ahk").is_file():
        raise SystemExit(f"错误：{src}\\{name}.ahk 不存在——先确认脚本目录结构")
    exclude = EXCLUDE_DIRS | {name}
    for p in sorted(src.rglob("*")):
        rel = p.relative_to(src)
        if rel.parts[0] in exclude:
            continue
        if p.is_file():
            files.append(rel)
    if not any(str(f) == f"{name}.ahk" for f in files):
        raise SystemExit("错误：入口脚本不在包内容清单里")
    return files


def stage(src: Path, files: list[Path], staging: Path, name: str) -> Path:
    """把要打包的内容复制成 `<staging>\\<名>\\...` 的干净布局。"""
    if staging.exists():
        shutil.rmtree(staging)
    root = staging / name
    root.mkdir(parents=True)
    for rel in files:
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src / rel, dst)
    return root


def pack_with_7z(seven_zip: str, staging_root: Path, out_zip: Path) -> None:
    # 7z a 是「追加」：不清旧包会把已删除的条目留在 zip 里，与 Python 回退
    # 分支的 "w"（覆盖）行为不一致。先删再打，两个后端语义统一。
    if out_zip.exists():
        out_zip.unlink()
    # -mx=9：Deflate 极限；-tzip：标准 zip（不是 7z 格式，宿主与资源管理器都能解）
    subprocess.run(
        [seven_zip, "a", "-tzip", "-mx=9", str(out_zip), "."],
        cwd=staging_root, check=True, capture_output=True,
    )


def pack_with_python(files: list[Path], src: Path, out_zip: Path, name: str) -> None:
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in files:
            z.write(src / rel, f"{name}/{rel.as_posix()}")


def verify(out_zip: Path, name: str) -> None:
    with zipfile.ZipFile(out_zip) as z:
        names = z.namelist()
        entry = f"{name}/{name}.ahk"
        assert entry in names, f"包里没有入口 {entry}"
        assert not any(n.startswith(("info/", "test/")) for n in names), \
            "info/ 或 test/ 混进了包"
        with z.open(entry) as f:
            head = f.read(4096).decode("utf-8", "replace")
        assert f"@name" in head and name in head, "入口脚本 @name 与包名不一致"


def read_entry_version(out_zip: Path, name: str) -> str:
    """读包内入口 <名>/<名>.ahk 的 @version。

    发版侧用它校验「包是从当前源码打的」：包内 @version 必须与目标版本一致，
    否则说明打的是残留旧包，拒绝发布（2026-11-17 隐患的正解）。
    """
    with zipfile.ZipFile(out_zip) as z:
        entry = f"{name}/{name}.ahk"
        with z.open(entry) as f:
            head = f.read(4096).decode("utf-8", "replace")
    m = re.search(r"^;\s*@version\s+(\S+)", head, re.MULTILINE)
    if not m:
        raise SystemExit(f"包内入口没有 @version：{out_zip}")
    return m.group(1)


def has_attachments(src: Path, name: str) -> bool:
    """脚本是否有附属文件（要进包、除入口 .ahk 外的文件）。

    附件形态（zip 包 vs 单 .ahk）的**唯一判据**：有附属文件才用 zip。判据来自
    脚本目录结构，**不**看 dist/ 里有没有残留的旧包——残留旧包会让「重发」把
    上一版内容传上去（2026-11-17 实测隐患：dist/<名>.zip 决定形态且不校验
    包内 @version，传了旧内容）。
    """
    files = collect(src, name)
    return any(f.as_posix() != f"{name}.ahk" for f in files)


def build(name: str, out_dir: str | Path | None = None) -> Path:
    """从**当前源码**打发行包 zip（每次现打，覆盖任何残留旧包），返回 zip 路径。

    包内容的唯一真源是 scripts/<名>/ 目录，杜绝「残留 dist/<名>.zip 传旧内容」。
    调用方（publish_version.py / make_index.py）据此拿到一个始终与当前源码一致的包。
    """
    src = REPO / "scripts" / name
    if not src.is_dir():
        raise SystemExit(f"错误：scripts\\{name}\\ 不存在")
    files = collect(src, name)
    out_dir = Path(out_dir) if out_dir is not None else REPO / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_zip = out_dir / f"{name}.zip"

    staging = REPO.parent / ".temp" / "pack" / name
    staging_root = stage(src, files, staging, name)

    seven_zip = find_7z()
    if seven_zip:
        pack_with_7z(seven_zip, staging_root, out_zip)
        tool = f"7-Zip（{seven_zip}）"
    else:
        pack_with_python(files, src, out_zip, name)
        tool = "Python zipfile（未找到 7z，同为 Deflate 标准 zip）"

    shutil.rmtree(staging, ignore_errors=True)
    verify(out_zip, name)

    size = out_zip.stat().st_size
    print(f"OK  {out_zip}")
    print(f"    压缩器：{tool}")
    print(f"    大小：{size / 1024:.1f} KB，{len(files)} 个文件")
    print("    入口：<名>/<名>.ahk 已通过包契约校验（root/@name/禁带 info、test）")
    return out_zip


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="脚本名（scripts/<名>/ 目录）")
    ap.add_argument("--out", default=str(REPO / "dist"), help="输出目录")
    ap.add_argument("--list", action="store_true", help="只列出包内容")
    args = ap.parse_args()

    name = args.name
    src = REPO / "scripts" / name
    if not src.is_dir():
        raise SystemExit(f"错误：scripts\\{name}\\ 不存在")

    files = collect(src, name)
    if args.list:
        print(f"{name} 将打进包的内容（相对 zip 根 {name}/）：")
        for f in files:
            print("  ", f.as_posix())
        return 0

    build(name, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
