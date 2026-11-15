#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""码表静态门禁（只读源码，不运行脚本）——**一次只查一个脚本**。

为什么需要它：码表错一位不会报错、不会崩、不会少画一个控件，只会安静地把
DDR5 显示成 HBM3。2026-11-15 就是这么漏掉三处的——本机 DDR4(0x1A)、单 Rank
(attr=0x01)、台式机(3)，三处恰好都落在全表里唯一正确的格子上，33 项自测全绿。
**单机型单样本的"跑通"只能证明代码不崩，证明不了码表对。**

检查项：
  C1 覆盖完整   权威表里"必须有的码位"，AHK 表一个都不能缺
  C2 无越界     表里不许出现权威表之外、又不是标注为可选的码位
  C3 值对得上   每项文案必须等于权威英文名或约定的中文译名
  C4 关键码位   DDR5=0x22 / DDR=0x12 / HBM=0x20 / DIMM=8 / SODIMM=12 显式断言
  C5 权威表自证 用 --from-dmidecode 把内置表与上游 C 源码逐项核对

权威表出处（内置表是这几处的转录，--from-dmidecode 可当场验证）：
  TYPE_NAME/CHASSIS_NAME/ECC_NAME  dmidecode 的 dmi_memory_device_type()
                                   / dmi_chassis_type() / dmi_memory_array_ec_type()
  FORM_NAME                        WMI Win32_PhysicalMemory.FormFactor（CIM 枚举，
                                   8=DIMM、12=SODIMM；**与 SMBIOS 的 9/13 不是一套码**）
  CONN_NAME                        wingdi.h DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY
  RANK_NAME                        SMBIOS 7.18 Type17 Attributes 的 bit3:0

用法：
  python tools/check_codes.py 硬件信息
  python tools/check_codes.py 硬件信息 --from-dmidecode ../.ex/硬件检测/_src_dmidecode_main/dmidecode.c

**不接受「不带名字跑全部」**：改 A 脚本时把 B 脚本的旧账一起翻出来，只会让人去动
不该动的文件（AGENTS.md 第 12 条）。

退出码 0 = 全过；1 = 有失败项；2 = 用法错误。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"

# ── 权威码表：code -> (英文规范名, 约定中文译名 or None) ────────────────────
# None 表示"本该就是英文，没有译名"。

TYPE_NAME = {
    0x01: ("Other", "其他"), 0x02: ("Unknown", "未知"), 0x03: ("DRAM", None),
    0x04: ("EDRAM", None), 0x05: ("VRAM", None), 0x06: ("SRAM", None),
    0x07: ("RAM", None), 0x08: ("ROM", None), 0x09: ("Flash", None),
    0x0A: ("EEPROM", None), 0x0B: ("FEPROM", None), 0x0C: ("EPROM", None),
    0x0D: ("CDRAM", None), 0x0E: ("3DRAM", None), 0x0F: ("SDRAM", None),
    0x10: ("SGRAM", None), 0x11: ("RDRAM", None), 0x12: ("DDR", None),
    0x13: ("DDR2", None), 0x14: ("DDR2 FB-DIMM", None),
    0x18: ("DDR3", None), 0x19: ("FBD2", None), 0x1A: ("DDR4", None),
    0x1B: ("LPDDR", None), 0x1C: ("LPDDR2", None), 0x1D: ("LPDDR3", None),
    0x1E: ("LPDDR4", None),
    0x1F: ("Logical non-volatile device", "逻辑非易失设备"),
    0x20: ("HBM", None), 0x21: ("HBM2", None), 0x22: ("DDR5", None),
    0x23: ("LPDDR5", None), 0x24: ("HBM3", None),
}

CHASSIS_NAME = {
    0x01: ("Other", "其他"), 0x02: ("Unknown", "未知"), 0x03: ("Desktop", "台式机"),
    0x04: ("Low Profile Desktop", "低矮台式机"), 0x05: ("Pizza Box", "薄型台式机"),
    0x06: ("Mini Tower", "迷你塔式"), 0x07: ("Tower", "塔式"),
    0x08: ("Portable", "便携式"), 0x09: ("Laptop", "笔记本"), 0x0A: ("Notebook", "笔记本"),
    0x0B: ("Hand Held", "手持设备"), 0x0C: ("Docking Station", "坞站"),
    0x0D: ("All In One", "一体机"), 0x0E: ("Sub Notebook", "子笔记本"),
    0x0F: ("Space-saving", "空间节省型"), 0x10: ("Lunch Box", "午餐盒式"),
    0x11: ("Main Server Chassis", "主服务器机箱"), 0x12: ("Expansion Chassis", "扩展机箱"),
    0x13: ("Sub Chassis", "子机箱"), 0x14: ("Bus Expansion Chassis", "总线扩展机箱"),
    0x15: ("Peripheral Chassis", "外设机箱"), 0x16: ("RAID Chassis", "RAID 机箱"),
    0x17: ("Rack Mount Chassis", "机架式"), 0x18: ("Sealed-case PC", "密封机箱"),
    0x19: ("Multi-system", "多系统机箱"), 0x1A: ("CompactPCI", None),
    0x1B: ("AdvancedTCA", None), 0x1C: ("Blade", "刀片"),
    0x1D: ("Blade Enclosing", "刀片机箱"), 0x1E: ("Tablet", "平板"),
    0x1F: ("Convertible", "可翻转"), 0x20: ("Detachable", "可拆卸"),
    0x21: ("IoT Gateway", "IoT 网关"), 0x22: ("Embedded PC", "嵌入式 PC"),
    0x23: ("Mini PC", "迷你主机"), 0x24: ("Stick PC", "U 盘式 PC"),
}

ECC_NAME = {
    0x01: ("Other", "其他"), 0x02: ("Unknown", "未知"), 0x03: ("None", "无"),
    0x04: ("Parity", None), 0x05: ("Single-bit ECC", "单比特 ECC"),
    0x06: ("Multi-bit ECC", "多比特 ECC"), 0x07: ("CRC", None),
}

# CIM 枚举（WMI），与 SMBIOS 的 FormFactor 差一位，别混
FORM_NAME = {
    0x00: ("Unknown", "未知"), 0x01: ("Other", "其他"), 0x02: ("SIP", None),
    0x03: ("DIP", None), 0x04: ("ZIP", None), 0x05: ("SOJ", None),
    0x06: ("Proprietary", "专用"), 0x07: ("SIMM", None), 0x08: ("DIMM", None),
    0x09: ("TSOP", None), 0x0A: ("PGA", None), 0x0B: ("RIMM", None),
    0x0C: ("SODIMM", None), 0x0D: ("SRIMM", None), 0x0E: ("SMD", None),
    0x0F: ("SSMP", None), 0x10: ("QFP", None), 0x11: ("TQFP", None),
    0x12: ("SOIC", None), 0x13: ("LCC", None), 0x14: ("PLCC", None),
    0x15: ("BGA", None), 0x16: ("FPBGA", None), 0x17: ("LGA", None),
}

# wingdi.h DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY；7 是空洞，16/17 为可选
CONN_NAME = {
    0x00: ("HD15", "VGA（模拟）"), 0x01: ("SVIDEO", "S-Video"),
    0x02: ("COMPOSITE_VIDEO", "复合视频"), 0x03: ("COMPONENT_VIDEO", "分量视频"),
    0x04: ("DVI", None), 0x05: ("HDMI", None), 0x06: ("LVDS", "LVDS（内置屏）"),
    0x08: ("D_JPN", "D-Terminal"), 0x09: ("SDI", None),
    0x0A: ("DISPLAYPORT_EXTERNAL", "DisplayPort"),
    0x0B: ("DISPLAYPORT_EMBEDDED", "DisplayPort（内置）"),
    0x0C: ("UDI_EXTERNAL", "UDI"), 0x0D: ("UDI_EMBEDDED", "UDI（内置）"),
    0x0E: ("SDTVDONGLE", "SDTV"), 0x0F: ("MIRACAST", "Miracast（无线）"),
    0x80000000: ("INTERNAL", "内置"),
}
CONN_OPTIONAL = {0x10, 0x11}  # INDIRECT_WIRED / INDIRECT_VIRTUAL，虚拟机用，可缺

# SMBIOS 7.18 Type17 Attributes bit3:0 是 Rank 数；0 = 主板未填
RANK_NAME = {1: ("1R", None), 2: ("2R", None), 3: ("3R", None), 4: ("4R", None)}

TABLES = {
    "TYPE_NAME": (TYPE_NAME, set()),
    "CHASSIS_NAME": (CHASSIS_NAME, set()),
    "ECC_NAME": (ECC_NAME, set()),
    "FORM_NAME": (FORM_NAME, set()),
    "CONN_NAME": (CONN_NAME, CONN_OPTIONAL),
    "RANK_NAME": (RANK_NAME, set()),
}

# C4 关键码位：这几个错一次就会误导整台机器的判断
SPOT_CHECKS = [
    ("TYPE_NAME", 0x22, "DDR5"),
    ("TYPE_NAME", 0x12, "DDR"),
    ("TYPE_NAME", 0x20, "HBM"),
    ("TYPE_NAME", 0x1A, "DDR4"),
    ("FORM_NAME", 0x08, "DIMM"),
    ("FORM_NAME", 0x0C, "SODIMM"),
    ("CONN_NAME", 0x05, "HDMI"),
    ("RANK_NAME", 2, "2R"),
]

PAIR = re.compile(r'(0x[0-9A-Fa-f]+|\d+)\s*,\s*"([^"]*)"')


def parse_ahk_maps(src):
    """把脚本里 `NAME := Map(...)` 解析成 {name: {code: text}}，跨行、含注释都能吃。"""
    out = {}
    for m in re.finditer(r'([A-Z][A-Z0-9_]*)\s*:=\s*Map\s*\(', src):
        name = m.group(1)
        if name not in TABLES:
            continue
        i = m.end() - 1
        depth = 0
        in_str = False
        while i < len(src):
            ch = src[i]
            if in_str:
                if ch == '"':
                    if i + 1 < len(src) and src[i + 1] == '"':
                        i += 1
                    else:
                        in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = src[m.end():i]
        out[name] = {int(k, 0): v for k, v in PAIR.findall(body)}
    return out


def check_table(name, got, canon, optional, fails, notes):
    missing = [c for c in canon if c not in got]
    if missing:
        fails.append(f"{name} 缺 {len(missing)} 个码位: "
                     + ", ".join(f"0x{c:02X}={canon[c][0]}" for c in sorted(missing)[:6])
                     + (" …" if len(missing) > 6 else ""))
    extra = [c for c in got if c not in canon and c not in optional]
    if extra:
        fails.append(f"{name} 有权威表之外的码位: "
                     + ", ".join(f"0x{c:02X}->{got[c]}" for c in sorted(extra)[:6]))

    for code in sorted(set(got) & set(canon)):
        en, zh = canon[code]
        val = got[code]
        if val == en or (zh is not None and val == zh):
            continue
        fails.append(f"{name}[0x{code:02X}] = {val!r}，权威为 {en!r}"
                     + (f" 或 {zh!r}" if zh else ""))
    notes.append(f"{name}: {len(got)} 项（权威 {len(canon)} 项）")


def parse_c_array(path, func):
    """从 dmidecode.c 里抽出某个函数内 `static const char *x[] = {...}` 的字符串表。"""
    src = Path(path).read_text(encoding="utf-8", errors="replace")
    i = src.find(f"static const char *{func}(")
    if i < 0:
        raise SystemExit(f"在 {path} 里找不到 {func}()")
    j = src.find("[] = {", i)
    k = src.find("};", j)
    body = src[j:k]
    # 先去掉块注释：dmi_chassis_type 里有 /* CIM_Chassis… says "Main System Chassis" */，
    # 不去掉会被当成表项，导致整表错位一位（第一版就是这样翻车的）。
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    return re.findall(r'"((?:[^"\\]|\\.)*)"', body)


def verify_canon(path, fails, notes):
    """C5：把内置权威表与上游 C 源码逐项核对，证明内置表不是凭记忆写的。"""
    pairs = [
        ("TYPE_NAME", "dmi_memory_device_type", 1),
        ("CHASSIS_NAME", "dmi_chassis_type", 1),
        ("ECC_NAME", "dmi_memory_array_ec_type", 1),
    ]
    for name, func, start in pairs:
        try:
            upstream = parse_c_array(path, func)
        except SystemExit as e:
            fails.append(str(e))
            continue
        canon = TABLES[name][0]
        # Reserved 是上游占位，本脚本按"未知(x)"处理，允许缺；但仍占一个位置，
        # 所以按 enumerate 原索引算码位，不能先压缩数组。
        valid = [(start + n, en) for n, en in enumerate(upstream) if en != "Reserved"]
        if len(valid) != len(canon):
            fails.append(f"{name} 内置 {len(canon)} 项，上游 {func}() 有 {len(valid)} 项（不含 Reserved）")
        bad = 0
        for code, en in valid:
            if code not in canon:
                fails.append(f"{name} 上游有 0x{code:02X}={en!r}，内置表没有")
                bad += 1
            elif canon[code][0] != en:
                fails.append(f"{name}[0x{code:02X}] 内置 {canon[code][0]!r} ≠ 上游 {en!r}")
                bad += 1
        if not bad:
            notes.append(f"{name} 与上游 {func}() 逐项一致（{len(valid)} 项）")


def main(argv):
    rest = argv[1:]
    dmidecode = None
    positional = []
    i = 0
    while i < len(rest):
        if rest[i] == "--from-dmidecode":
            if i + 1 >= len(rest):
                print("--from-dmidecode 后面要给 dmidecode.c 的路径")
                return 2
            dmidecode = rest[i + 1]
            i += 2
            continue
        positional.append(rest[i])
        i += 1

    if len(positional) != 1:
        print("用法: python tools/check_codes.py <脚本名> [--from-dmidecode <dmidecode.c>]")
        print("必须且只能给一个脚本名（AGENTS.md 第 12 条：不许跑全部）。")
        return 2

    name = positional[0]
    path = SCRIPTS / name / f"{name}.ahk"
    if not path.exists():
        print(f"找不到脚本: {path}")
        return 2

    src = path.read_text(encoding="utf-8", errors="replace")
    got = parse_ahk_maps(src)

    fails, notes = [], []
    if not got:
        print(f"{name}: 未发现受管的码表（{', '.join(TABLES)}），无事可做。")
        return 0

    for table, (canon, optional) in TABLES.items():
        if table in got:
            check_table(table, got[table], canon, optional, fails, notes)
        else:
            notes.append(f"{table}: 本脚本未使用")

    for table, code, want in SPOT_CHECKS:
        if table in got and got[table].get(code) != want:
            fails.append(f"关键码位 {table}[0x{code:02X}] 应为 {want!r}，实为 "
                         f"{got[table].get(code)!r}")

    if dmidecode:
        verify_canon(dmidecode, fails, notes)

    print(f"== {name} 码表门禁 ==")
    for n in notes:
        print("   " + n)
    if fails:
        print()
        for f in fails:
            print("FAIL " + f)
        print(f"\n{len(fails)} 项失败")
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
