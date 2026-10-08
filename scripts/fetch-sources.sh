#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ============================================================
#  fetch-sources.sh — 按 versions.lock 取上游源码并断言 SHA
#
#  用法:  ./scripts/fetch-sources.sh [目标目录]
#  默认目标目录: ./src
#
#  为什么必须断言 SHA：
#    分支名是会动的指针，不可复现。上游 push 一个新 commit，
#    同样的命令就会编出不同的东西 —— 而失败现场无法复原。
# ============================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOCK="$ROOT/versions.lock"
DEST="${1:-$ROOT/src}"

[ -f "$LOCK" ] || { echo "ERROR: 找不到 $LOCK"; exit 1; }

# ---------- 从 versions.lock 读关键字段 ----------
lock_get() {
  # 只取 [section] 下第一个 "key = value"，忽略注释与空行
  awk -v sect="[$1]" -v key="$2" '
    /^\[/ { cur=$0; next }
    cur==sect && $0 ~ "^"key"[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*", ""); print; exit
    }
  ' "$LOCK"
}

UP_NAME=$(lock_get upstream name)
UP_URL=$(lock_get upstream url)
UP_BRANCH=$(lock_get upstream branch)
UP_COMMIT=$(lock_get upstream commit)

echo "============================================"
echo "  上游:   $UP_NAME"
echo "  分支:   $UP_BRANCH"
echo "  期望 SHA: $UP_COMMIT"
echo "  目标目录: $DEST"
echo "============================================"

for v in UP_URL UP_BRANCH UP_COMMIT; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "ERROR: versions.lock 缺字段 ($v)"; exit 1; }
done

# ---------- 0. 在线核对：分支当前指向的 SHA ----------
echo ""
echo "[0/3] 在线核对上游分支指向"
REMOTE_SHA=$(git ls-remote "$UP_URL" "refs/heads/$UP_BRANCH" | awk '{print $1}')
if [ -z "$REMOTE_SHA" ]; then
  echo "  WARN: 无法读取远端（网络问题？）"
else
  echo "  远端 $UP_BRANCH = $REMOTE_SHA"
  if [ "$REMOTE_SHA" = "$UP_COMMIT" ]; then
    echo "  ^ 与 versions.lock 一致"
  else
    echo "  ! 远端已移动。versions.lock 里的是 $UP_COMMIT"
    echo "    （这不是错误 —— 我们 pin 的是历史 commit，仍可复现）"
  fi
fi

# ---------- 1. 克隆 ----------
echo ""
echo "[1/3] 克隆"
if [ -d "$DEST/.git" ]; then
  echo "  已存在，跳过（如需重来请先删除 $DEST）"
else
  # 注意：不要用 --filter=blob:none 之后再检出整个工作区
  #       73k 文件会退化成逐 blob 懒加载，且与 --3way 不兼容
  git clone --depth=1 --branch "$UP_BRANCH" "$UP_URL" "$DEST"
fi

# ---------- 2. 断言 SHA ----------
echo ""
echo "[2/3] 断言 SHA"
ACTUAL=$(git -C "$DEST" rev-parse HEAD)
echo "  实际 HEAD = $ACTUAL"

if [ "$ACTUAL" = "$UP_COMMIT" ]; then
  echo "  OK 与 versions.lock 一致"
else
  echo "  ! HEAD 不是 pin 的 commit，按 SHA 精确检出"
  git -C "$DEST" fetch --depth=1 origin "$UP_COMMIT"
  git -C "$DEST" checkout --detach FETCH_HEAD
  ACTUAL=$(git -C "$DEST" rev-parse HEAD)
  if [ "$ACTUAL" = "$UP_COMMIT" ]; then
    echo "  OK 已检出 $ACTUAL"
  else
    echo "  ERROR: SHA 不匹配！expect=$UP_COMMIT got=$ACTUAL"
    exit 1
  fi
fi

# ---------- 3. 完整性自检 ----------
echo ""
echo "[3/3] 完整性自检"

echo "  -- Makefile --"
sed -n '1,6p' "$DEST/Makefile"

EXPECT_SUB=$(lock_get tree sublevel)
ACTUAL_SUB=$(awk '/^SUBLEVEL/{print $3}' "$DEST/Makefile")
echo "  SUBLEVEL: expect=$EXPECT_SUB actual=$ACTUAL_SUB"
if [ -n "$EXPECT_SUB" ] && [ "$EXPECT_SUB" != "$ACTUAL_SUB" ]; then
  echo "  ERROR: SUBLEVEL 不符（versions.lock 该更新了吗？）"
  exit 1
fi

echo "  -- gki_defconfig 首行 --"
head -1 "$DEST/arch/arm64/configs/gki_defconfig"

echo "  -- 关键文件存在性 --"
MISS=0
for f in \
  arch/arm64/configs/gki_defconfig \
  kernel/sched/fair.c \
  mm/memory.c \
  init/main.c \
  include/linux/module.h \
  kernel/trace/Kconfig \
  _setup_env.sh \
  gki/aarch64/abi.stg \
  build.config.gki \
  build.config.constants ; do
  if [ -e "$DEST/$f" ]; then
    echo "    OK   $f"
  else
    echo "    MISS $f"
    MISS=$((MISS+1))
  fi
done
[ "$MISS" -eq 0 ] || { echo "ERROR: 缺 $MISS 个关键文件，树不完整"; exit 1; }

echo "  -- 路径数 --"
N=$(find "$DEST" -path "$DEST/.git" -prune -o -type f -print | wc -l)
echo "    $N 个文件"

echo "  -- 厂商适配标志（确认血统正确）--"
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GCMA RT_SOFTIRQ_AWARE_SCHED; do
  grep -m1 "$k" "$DEST/arch/arm64/configs/gki_defconfig" || echo "    ! 未找到 $k（血统可疑！）"
done

echo ""
echo "OK 源码就绪: $DEST"
echo ""
echo "下一步: ./scripts/build.sh"