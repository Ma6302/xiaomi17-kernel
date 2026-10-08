#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ============================================================
#  build.sh — 编译小米 17 GKI 内核
#
#  用法:  ./scripts/build.sh
#
#  环境变量（可选）:
#    TC        工具链根目录（默认自动探测 ./toolchain 或 /root/pudding-kernel/toolchain）
#    SRC       源码目录（默认 ./src）
#    OUT       输出目录（默认 ./out）
#    JOBS      并行度（默认 nproc）
#
#  ★ 本脚本刻意不设 set -u
#    _setup_env.sh 引用多个可能未定义的变量
#    （_SETUP_ENV_SH_INCLUDED / KLEAF_INTERNAL_NO_BUILD_CONFIG /
#      BUILD_CONFIG_FRAGMENTS），在 set -u 下会立即 abort。
# ============================================================
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOCK="$ROOT/versions.lock"

# ---------- 探测路径 ----------
if [ -z "${TC:-}" ]; then
  for c in "$ROOT/toolchain" /root/pudding-kernel/toolchain; do
    [ -d "$c" ] && { TC="$c"; break; }
  done
fi
SRC="${SRC:-$ROOT/src}"
OUT="${OUT:-$ROOT/out}"
JOBS="${JOBS:-$(nproc)}"
LOG="$ROOT/build.log"

[ -d "$TC" ] || { echo "ERROR: 找不到工具链。请设 TC=<path>"; exit 1; }
[ -d "$SRC" ] || { echo "ERROR: 找不到源码。先跑 ./scripts/fetch-sources.sh"; exit 1; }

# ---------- 从 versions.lock 读署名与 clang 版本 ----------
lock_get() {
  awk -v sect="[$1]" -v key="$2" '
    /^\[/ { cur=$0; next }
    cur==sect && $0 ~ "^"key"[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*", ""); print; exit
    }
  ' "$LOCK"
}

LOCALVER=$(lock_get artifacts kernel_version_string)
# 去掉版本号前缀，只留署名部分（形如 -android16-6-4k-Ma6302）
LOCALVER_SUFFIX=$(echo "$LOCALVER" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+//')
[ -n "$LOCALVER_SUFFIX" ] || LOCALVER_SUFFIX="-android16-6-4k-Ma6302"

CLANG_VER=$(lock_get toolchain clang_version)
CLANG_DIR="$TC/${CLANG_VER:-clang-r536225}"

exec > >(tee "$LOG") 2>&1

echo "============================================"
echo "  BUILD START $(date)"
echo "  SRC   = $SRC"
echo "  OUT   = $OUT"
echo "  TC    = $TC"
echo "  CLANG = $CLANG_DIR"
echo "  JOBS  = $JOBS"
echo "  LOCALVERSION$LOCALVER_SUFFIX"
echo "============================================"

# ---------- 工具链 ----------
export PATH="$CLANG_DIR/bin:$TC/rust/bin:$TC/build-tools/build-tools/bin:$PATH"
export CC="$CLANG_DIR/bin/clang"
export LD="$CLANG_DIR/bin/ld.lld"
export AR="$CLANG_DIR/bin/llvm-ar"
export NM="$CLANG_DIR/bin/llvm-nm"
export OBJCOPY="$CLANG_DIR/bin/llvm-objcopy"
export OBJDUMP="$CLANG_DIR/bin/llvm-objdump"
export LIBCLANG_PATH="$CLANG_DIR/lib"
export RUSTC=rustc
export BINDGEN=bindgen
export LLVM=1
export LLVM_IAS=1

# ★ pahole 必须用 AOSP prebuilt
#   Ubuntu 24.04 自带 1.25 为 6.12 生成的 BTF 会被 resolve_btfids 拒收：
#     FAILED: load BTF from vmlinux: Invalid argument
PAHOLE=$(find "$TC" -name pahole -type f 2>/dev/null | head -1)
if [ -n "$PAHOLE" ]; then
  export PAHOLE
  echo "PAHOLE = $PAHOLE"
else
  echo "WARN: 未找到 AOSP prebuilt pahole，将用系统的（可能编不出 BTF）"
fi

echo "-- toolchain --"
$CC --version 2>&1 | head -2

# ---------- GKI 官方构建环境 ----------
cd "$SRC"
export ARCH=arm64
export BRANCH=android16-6.12
export KERNEL_DIR="$SRC"
export OUT_DIR="$OUT"
export BUILD_CONFIG=build.config.gki.aarch64
export SKIP_CP_KERNEL_HDR=1

echo ""
echo "[env] source _setup_env.sh"
. ./_setup_env.sh

echo "-- env check --"
echo "  KBUILD_GENDWARFKSYMS_STABLE = ${KBUILD_GENDWARFKSYMS_STABLE:-<unset!>}"
echo "  TOOL_ARGS                   = ${TOOL_ARGS:-<none>}"
echo "  KBUILD_BUILD_USER           = ${KBUILD_BUILD_USER:-<unset>}"

if [ "${KBUILD_GENDWARFKSYMS_STABLE:-}" != "1" ]; then
  echo ""
  echo "  !!! 致命: KBUILD_GENDWARFKSYMS_STABLE 未设为 1"
  echo "      缺少它 → gendwarfksyms 走 unstable 路径 → 符号 CRC 全错"
  echo "      → 厂商模块拒载 → 卡第一屏"
  exit 1
fi

# ---------- 配置 ----------
echo ""
echo "[1/4] gki_defconfig"
rm -rf "$OUT"; mkdir -p "$OUT"
make O="$OUT" ARCH=arm64 LLVM=1 gki_defconfig || { echo "DEFCONFIG_FAIL"; exit 1; }

echo ""
echo "[2/4] 设置署名"
./scripts/config --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVER_SUFFIX"
./scripts/config --file "$OUT/.config" --disable LOCALVERSION_AUTO

# 抑制 setlocalversion 的 '+'（LOCALVERSION_AUTO=n 时 short 分支会无条件输出）
SLV="$SRC/scripts/setlocalversion"
if [ -f "$SLV" ] && ! grep -q 'Ma6302-SLV-PATCHED' "$SLV"; then
  cp -f "$SLV" "$SLV.ma6302.bak"
  sed -i 's|^[[:space:]]*echo "+"[[:space:]]*$|echo ""|' "$SLV"
  sed -i '1i # Ma6302-SLV-PATCHED' "$SLV"
  echo "  setlocalversion 已打补丁"
fi

# 可选：合并 config/*.fragment（每次只加一项！）
FRAG_DIR="$ROOT/config"
FRAGS=""
for f in "$FRAG_DIR"/*.fragment; do
  [ -f "$f" ] || continue
  # 跳过空文件与只有注释的文件
  grep -qE '^(CONFIG_|# CONFIG_)' "$f" || continue
  FRAGS="$FRAGS $f"
done
if [ -n "$FRAGS" ]; then
  echo "  合并 fragment:$FRAGS"
  # shellcheck disable=SC2086
  ARCH=arm64 scripts/kconfig/merge_config.sh -O "$OUT" -m "$OUT/.config" $FRAGS >/dev/null 2>&1 \
    && echo "  fragment 已合并" || echo "  WARN: merge_config.sh 有警告"
fi

echo ""
echo "[3/4] olddefconfig x2（让 select 链收敛）"
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig || { echo "OLDDEF_FAIL"; exit 1; }
make O="$OUT" ARCH=arm64 LLVM=1 olddefconfig || { echo "OLDDEF_FAIL"; exit 1; }

echo ""
echo "-- ABI 关键配置自检 --"
ABI_BAD=0
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GENDWARFKSYMS \
         MODVERSIONS EXTENDED_MODVERSIONS CFI_CLANG SHADOW_CALL_STACK \
         MODULE_SIG_FORCE DEBUG_INFO_BTF; do
  grep -E "^(CONFIG_${k}=|# CONFIG_${k} is not set)" "$OUT/.config" || echo "  $k = <absent>"
done
# 这些必须是 n
for k in FUNCTION_TRACER STACK_TRACER FUNCTION_GRAPH_TRACER FTRACE_MCOUNT_RECORD; do
  if grep -qE "^CONFIG_${k}=y" "$OUT/.config"; then
    echo "  !!! $k = y  ← 会破坏 ABI（struct module 变 1664/77）"
    ABI_BAD=1
  else
    echo "  $k = n   OK"
  fi
done
echo "-- LOCALVERSION --"
grep -E '^CONFIG_LOCALVERSION' "$OUT/.config"

if [ "$ABI_BAD" != "0" ]; then
  echo ""
  echo "!!! 检测到 ABI 敏感项被打开。停下来修，不要继续编。"
  echo "    详见 docs/FAILURE-LOG.md 坑 2"
  exit 1
fi

# ---------- 编译 ----------
echo ""
echo "[4/4] make -j$JOBS  (start $(date +%H:%M:%S))"
START=$(date +%s)
set +e
make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS"
RC=$?
set -e
END=$(date +%s)
DUR=$((END-START))
echo ""
echo "make rc=$RC  elapsed=$((DUR/60))m$((DUR%60))s"

if [ $RC -ne 0 ]; then
  echo "==== FIRST ERROR CONTEXT ===="
  grep -n -m1 -B3 -A15 'error:' "$LOG" || true
  echo "BUILD_FAILED"
  exit 1
fi

# ---------- 校验产物 ----------
IMG="$OUT/arch/arm64/boot/Image"
echo ""
echo "==== PRODUCT ===="
if [ ! -f "$IMG" ]; then
  echo "NO_IMAGE"; ls -la "$OUT/arch/arm64/boot/" 2>/dev/null; exit 1
fi

ls -la "$IMG"
MD5=$(md5sum "$IMG" | cut -d' ' -f1)
echo "IMAGE_MD5=$MD5"

echo "-- version strings --"
strings "$IMG" | grep -m2 -E '^6\.12\.[0-9]+.*Ma6302' || true
echo "-- vermagic --"
strings "$IMG" | grep -m1 'SMP preempt' || true

echo ""
echo "BUILD_OK"
echo "NEXT: ./scripts/verify-abi.sh"
echo "==== END $(date) ===="