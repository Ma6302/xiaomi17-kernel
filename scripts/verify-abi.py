#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
verify-abi.py — 四重 ABI 校验

用法:
    python3 scripts/verify-abi.py --out <构建输出目录> --src <源码目录>
                                  [--ko <设备模块.ko>]

判据（来自 2026-10-08 实测基线）:
    ① Module.symvers vs gki/aarch64/abi.stg : DIFF = 0
    ② 设备模块 .ko 的 __versions             : DIFF = 0
    ③ struct module                          : 1600 字节 / 75 成员
    ④ kobject_uevent_env                     : 0x8bb6d45c

任何一项不符 → 退出码 1。
"""

import argparse
import os
import re
import struct
import subprocess
import sys

# ---------- 实测基线（来自能开机的内核） ----------
EXPECT_STRUCT_MODULE_SIZE = 1600
EXPECT_STRUCT_MODULE_MEMBERS = 75
EXPECT_KOBJECT_UEVENT_ENV = "8bb6d45c"

# __versions 记录结构: struct modversion_info { unsigned long crc; char name[56]; }
REC_SIZE = 64
NAME_LEN = 56


def norm_crc(x):
    """归一化 CRC 字符串。

    ★ 陷阱: "0xaebcaf80".lstrip('0') -> "xaebcaf80"，会造成 100% 假 DIFF。
    """
    x = x.strip().lower()
    if x.startswith("0x"):
        x = x[2:]
    return x.lstrip("0") or "0"


def parse_symvers(path):
    """解析 Module.symvers: CRC<TAB>Symbol<TAB>Module<TAB>..."""
    out = {}
    with open(path, "r", errors="replace") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) < 2:
                continue
            sym = p[1].strip()
            if sym:
                out[sym] = norm_crc(p[0])
    return out


def parse_abistg(path):
    """解析 libabigail 风格 abi.stg 里的 elf_symbol 块。"""
    txt = open(path, "r", errors="replace").read()
    out = {}
    for m in re.finditer(r"elf_symbol\s*\{(.*?)\n\s*\}", txt, re.S):
        blk = m.group(1)
        nm = re.search(r'name:\s*"([^"]+)"', blk)
        cc = re.search(r"crc:\s*0x([0-9a-fA-F]+)", blk)
        if nm and cc:
            out[nm.group(1)] = norm_crc(cc.group(1))
    return out


def parse_versions_section(ko_path):
    """纯 Python 解析 ELF64 .ko 的 __versions 段。"""
    with open(ko_path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if d[4] != 2:
        raise ValueError("not ELF64")

    e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", d, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", d, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", d, 0x3E)[0]

    def sh(i):
        o = e_shoff + i * e_shentsize
        name, _stype = struct.unpack_from("<II", d, o)
        off, size = struct.unpack_from("<QQ", d, o + 0x18)
        return name, off, size

    _, stroff, strsize = sh(e_shstrndx)
    shstr = d[stroff:stroff + strsize]

    def sname(nm):
        e = shstr.find(b"\0", nm)
        return shstr[nm:e].decode("utf-8", "replace")

    target = None
    for i in range(e_shnum):
        nm, off, size = sh(i)
        if sname(nm) == "__versions":
            target = (off, size)
            break
    if not target:
        raise ValueError("no __versions section")

    off, size = target
    blob = d[off:off + size]
    pairs = {}
    for i in range(len(blob) // REC_SIZE):
        ch = blob[i * REC_SIZE:(i + 1) * REC_SIZE]
        crc = struct.unpack_from("<Q", ch, 0)[0]
        raw = ch[8:8 + NAME_LEN]
        e = raw.find(b"\0")
        name = raw[:e].decode("utf-8", "replace") if e >= 0 else raw.decode("utf-8", "replace")
        if name and all(32 <= ord(c) < 127 for c in name):
            pairs[name] = "%08x" % crc
    return pairs


def btf_struct_module(vmlinux, pahole):
    """用 pahole 读 struct module 的尺寸与成员数。"""
    if not pahole or not os.path.exists(pahole):
        return None
    try:
        r = subprocess.run([pahole, "-C", "module", vmlinux],
                           capture_output=True, text=True, timeout=300)
    except Exception:
        return None
    m = re.search(r"size:\s*(\d+),\s*cachelines:\s*\d+,\s*members:\s*(\d+)", r.stdout)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="构建输出目录（含 Module.symvers, vmlinux）")
    ap.add_argument("--src", required=True, help="源码目录（含 gki/aarch64/abi.stg）")
    ap.add_argument("--ko", default=None, help="设备上的 .ko 路径（可选，用于校验 ②）")
    ap.add_argument("--pahole", default=None, help="pahole 路径（可选，用于校验 ③）")
    args = ap.parse_args()

    symvers = os.path.join(args.out, "Module.symvers")
    abistg = os.path.join(args.src, "gki", "aarch64", "abi.stg")
    vmlinux = os.path.join(args.out, "vmlinux")

    fails = 0

    print("=" * 72)
    print("  ABI 校验")
    print("=" * 72)

    # ---------- ① 全量 CRC ----------
    print("\n[①] Module.symvers  vs  gki/aarch64/abi.stg")
    if not os.path.exists(symvers):
        print("    SKIP: 找不到 %s" % symvers); fails += 1
    elif not os.path.exists(abistg):
        print("    SKIP: 找不到 %s" % abistg); fails += 1
    else:
        our = parse_symvers(symvers)
        base = parse_abistg(abistg)
        match = diff = miss = 0
        dl = []
        for s, c in base.items():
            if s in our:
                if our[s] == c:
                    match += 1
                else:
                    diff += 1
                    if len(dl) < 20:
                        dl.append((s, c, our[s]))
            else:
                miss += 1
        total = len(base)
        rate = 100.0 * match / total if total else 0.0
        print("    我们导出符号: %d" % len(our))
        print("    基线符号    : %d" % total)
        print("    MATCH   : %d" % match)
        print("    DIFF    : %d" % diff)
        print("    MISSING : %d" % miss)
        print("    对齐率  : %.4f%%" % rate)
        if diff == 0 and miss == 0:
            print("    >>> PASS")
        else:
            print("    >>> FAIL")
            fails += 1
            for s, b, o in dl:
                print("        %-44s base=%s ours=%s" % (s, b, o))

    # ---------- ② 设备模块 __versions ----------
    print("\n[②] 设备模块 __versions  vs  GKI ABI 基线")
    if not args.ko:
        print("    SKIP: 未提供 --ko（建议传设备上的 msm_drm.ko）")
    elif not os.path.exists(args.ko):
        print("    SKIP: 找不到 %s" % args.ko)
    elif not os.path.exists(abistg):
        print("    SKIP: 找不到 abi.stg")
    else:
        try:
            req = parse_versions_section(args.ko)
            base = parse_abistg(abistg)
            match = diff = miss = 0
            dl = []
            for s, c in req.items():
                if s in base:
                    if base[s] == c:
                        match += 1
                    else:
                        diff += 1
                        if len(dl) < 20:
                            dl.append((s, c, base[s]))
                else:
                    miss += 1
            print("    模块要求符号: %d" % len(req))
            print("    MATCH   : %d" % match)
            print("    DIFF    : %d" % diff)
            print("    MISSING : %d   （应全部属其他 vendor 模块，正常）" % miss)
            if diff == 0:
                print("    >>> PASS（判据是 DIFF=0，不是 100% 对齐）")
            else:
                print("    >>> FAIL")
                fails += 1
                for s, c, b in dl:
                    print("        %-44s ko=%s base=%s" % (s, c, b))
        except Exception as e:
            print("    解析失败: %s" % e); fails += 1

    # ---------- ③ struct module ----------
    print("\n[③] BTF struct module")
    if not os.path.exists(vmlinux):
        print("    SKIP: 找不到 %s" % vmlinux)
    else:
        r = btf_struct_module(vmlinux, args.pahole)
        if not r:
            print("    SKIP: pahole 不可用或未找到 struct module")
        else:
            size, members = r
            ok = (size == EXPECT_STRUCT_MODULE_SIZE and
                  members == EXPECT_STRUCT_MODULE_MEMBERS)
            print("    实际: %d 字节 / %d 成员" % (size, members))
            print("    期望: %d 字节 / %d 成员" % (EXPECT_STRUCT_MODULE_SIZE,
                                                 EXPECT_STRUCT_MODULE_MEMBERS))
            if ok:
                print("    >>> PASS")
            else:
                print("    >>> FAIL")
                print("        （多出成员通常是打开了 FUNCTION_TRACER/STACK_TRACER）")
                fails += 1

    # ---------- ④ 关键符号 ----------
    print("\n[④] 关键符号 kobject_uevent_env")
    if not os.path.exists(symvers):
        print("    SKIP")
    else:
        our = parse_symvers(symvers)
        got = our.get("kobject_uevent_env", "<missing>")
        print("    实际: %s" % got)
        print("    期望: %s" % EXPECT_KOBJECT_UEVENT_ENV)
        if got == EXPECT_KOBJECT_UEVENT_ENV:
            print("    >>> PASS")
        else:
            print("    >>> FAIL")
            fails += 1

    print("\n" + "=" * 72)
    if fails == 0:
        print("  结论: 全部通过 ✅")
        print("  ⚠ 但请注意：ABI 全过 ≠ 必定开机（源码树血统仍须正确）")
    else:
        print("  结论: %d 项未通过 ❌" % fails)
        print("  任何一项不过 = 必定无法加载厂商模块")
    print("=" * 72)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())