#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
parse-module-versions.py — 解析 ELF64 .ko 的 __versions 段，输出符号 CRC 要求

用法:
    python3 parse-module-versions.py <module.ko> [> out.txt]

输出格式（每行一条，便于 diff）:
    <symbol_name> 0x<crc32>

用途:
    从设备真实模块提取 ABI 要求，作为校验外部基准。
    例: msm_drm.ko 提取出 851 条。

背景:
    CONFIG_MODVERSIONS 下，每个导出符号的内核侧 CRC 记录在内核的
    Module.symvers；模块侧记录在 .ko 的 __versions 节。

    struct modversion_info {
        unsigned long crc;              /* 8 bytes */
        char name[MODULE_NAME_LEN];     /* 56 bytes */
    };                                  /* 记录 = 64 bytes */
"""

import os
import struct
import sys

REC_SIZE = 64      # 8 + 56
NAME_LEN = 56
CRC_OFF = 0
NAME_OFF = 8


def parse(ko_path):
    with open(ko_path, "rb") as f:
        d = f.read()

    if d[:4] != b"\x7fELF":
        raise ValueError("不是 ELF 文件")
    if d[4] != 2:
        raise ValueError("不是 ELF64（本脚本只处理 64 位）")

    e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", d, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", d, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", d, 0x3E)[0]

    def section(i):
        o = e_shoff + i * e_shentsize
        name_off = struct.unpack_from("<I", d, o)[0]
        off, size = struct.unpack_from("<QQ", d, o + 0x18)
        return name_off, off, size

    # section 名字表
    _, shstr_off, shstr_sz = section(e_shstrndx)
    shstr = d[shstr_off:shstr_off + shstr_sz]

    def sec_name(nm_off):
        end = shstr.find(b"\0", nm_off)
        return shstr[nm_off:end].decode("utf-8", "replace")

    target = None
    for i in range(e_shnum):
        nm_off, off, size = section(i)
        if sec_name(nm_off) == "__versions":
            target = (off, size)
            break

    if target is None:
        raise ValueError("未找到 __versions 节（模块可能未启用 MODVERSIONS）")

    off, size = target
    blob = d[off:off + size]
    count = len(blob) // REC_SIZE

    pairs = []
    bad = 0
    for i in range(count):
        rec = blob[i * REC_SIZE:(i + 1) * REC_SIZE]
        crc = struct.unpack_from("<Q", rec, CRC_OFF)[0]
        raw = rec[NAME_OFF:NAME_OFF + NAME_LEN]
        nul = raw.find(b"\0")
        name = (raw[:nul] if nul >= 0 else raw).decode("utf-8", "replace")
        if not name or not all(32 <= ord(c) < 127 for c in name):
            bad += 1
            continue
        pairs.append((name, crc))

    return pairs, bad, size, count


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    ko = sys.argv[1]
    if not os.path.exists(ko):
        print("ERROR: 文件不存在: %s" % ko, file=sys.stderr)
        return 1

    try:
        pairs, bad, size, count = parse(ko)
    except Exception as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1

    # 摘要走 stderr，数据走 stdout（便于重定向）
    print("[%s]" % os.path.basename(ko), file=sys.stderr)
    print("  __versions 节大小 : %d 字节" % size, file=sys.stderr)
    print("  记录数            : %d" % count, file=sys.stderr)
    print("  解析成功          : %d" % len(pairs), file=sys.stderr)
    print("  跳过（非法名）    : %d" % bad, file=sys.stderr)

    for name, crc in pairs:
        print("%s 0x%08x" % (name, crc))

    return 0


if __name__ == "__main__":
    sys.exit(main())