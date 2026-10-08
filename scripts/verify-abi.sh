#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# verify-abi.sh — verify-abi.py 的薄包装（自动探测路径）
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SRC="${SRC:-$ROOT/src}"
OUT="${OUT:-$ROOT/out}"
KO="${KO:-}"

# 探测工具链里的 pahole
PAHOLE="${PAHOLE:-}"
if [ -z "$PAHOLE" ]; then
  for c in "$ROOT/toolchain" /root/pudding-kernel/toolchain; do
    [ -d "$c" ] || continue
    PAHOLE=$(find "$c" -name pahole -type f 2>/dev/null | head -1)
    [ -n "$PAHOLE" ] && break
  done
fi

ARGS=(--out "$OUT" --src "$SRC")
[ -n "$KO" ] && ARGS+=(--ko "$KO")
[ -n "$PAHOLE" ] && ARGS+=(--pahole "$PAHOLE")

echo "SRC    = $SRC"
echo "OUT    = $OUT"
echo "KO     = ${KO:-<未提供，将跳过校验②>}"
echo "PAHOLE = ${PAHOLE:-<未找到>}"
echo ""

# 提示：校验②需要设备上的真实模块
if [ -z "$KO" ]; then
  echo "提示: 拉一个设备模块可获得最硬的外部基准："
  echo "  adb pull /vendor_dlkm/lib/modules/msm_drm.ko"
  echo "  KO=/path/to/msm_drm.ko ./scripts/verify-abi.sh"
  echo ""
fi

exec python3 "$HERE/verify-abi.py" "${ARGS[@]}"