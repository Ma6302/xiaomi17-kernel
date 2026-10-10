#!/system/bin/sh
# ============================================================
# MK-Addon 打包脚本（含交付链路自检）
# 用法: sh pack.sh
#   依赖 zip（Android shell 无 zip，请用 proot 终端跑）
#
# 2026-10-10 事故后加固：
#   - 打包后立即自检包内关键功能点
#   - 生成 SOURCE-STAMP 记录源码指纹与产物 md5
#   - 提示下一层（AK3）需要对比的 md5
# ============================================================

SRC="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC"

VER="$(sed -n 's/^version=//p' module.prop)"
# 1.2.1：记录仪三项修复（段归属快照 / pid 复用 / 脏段阈值）+ 自定义游戏包名
OUT="$SRC/mk-addon-${VER}.zip"
STAMP="$SRC/SOURCE-STAMP"

command -v zip >/dev/null 2>&1 || {
    echo "错误: 找不到 zip 命令。Android shell 无 zip，请在 proot 终端里运行本脚本。"
    exit 1
}

echo "=== 1. 打包 ==="
rm -f "$OUT"
zip -r "$OUT" \
    module.prop \
    install.sh \
    customize.sh \
    uninstall.sh \
    config.conf \
    service.sh \
    apply.sh \
    collect.sh \
    lib/ \
    -x '*.md' -x 'SOURCE-STAMP' -x 'mk-verify.sh' >/dev/null

[ -f "$OUT" ] || { echo "错误: 打包失败"; exit 1; }
OUT_MD5="$(md5sum "$OUT" | cut -d' ' -f1)"
echo "  产物: $OUT"
echo "  md5 : $OUT_MD5"

echo
echo "=== 2. 包内自检（第 2 层验证）==="
PASS=0; FAIL=0
chk() {
    if [ "$2" = "$3" ]; then
        printf '  [OK]   %-38s %s\n' "$1" "$2"; PASS=$((PASS+1))
    else
        printf '  [FAIL] %-38s got=%s want=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
    fi
}
chk "守卫函数数"    "$(unzip -p "$OUT" lib/common.sh | grep -cE 'kernel_is_ours|guard_check')" "3"
chk "service.sh 调守卫" "$(unzip -p "$OUT" service.sh | grep -c 'guard_check')" "1"
chk "ZRAM_ALGO"     "$(unzip -p "$OUT" config.conf | sed -n 's/^ZRAM_ALGO=//p' | head -1)" "lz4"
chk "READ_AHEAD_KB" "$(unzip -p "$OUT" config.conf | sed -n 's/^READ_AHEAD_KB=//p' | head -1)" "0"
chk "KERNEL_GUARD"  "$(unzip -p "$OUT" config.conf | sed -n 's/^KERNEL_GUARD=//p' | head -1)" "1"
chk "collect 快照标记" "$(unzip -p "$OUT" collect.sh | grep -c 'kernel_is_ours')" "1"
chk "apply 参数扫描"  "$(unzip -p "$OUT" apply.sh | grep -cE 'GUARD_FORCE|--force')" "5"

# ---- 方案C / 零残余 新增自检（2026-10-10）----
chk "common.sh 外部配置(EXT_CONF)" "$(unzip -p "$OUT" lib/common.sh | grep -c 'EXT_CONF=' )" "1"
chk "common.sh seed_conf 函数"     "$(unzip -p "$OUT" lib/common.sh | grep -c 'seed_conf')" "1"
chk "service.sh 调 seed_conf"      "$(unzip -p "$OUT" service.sh | grep -c 'seed_conf')" "1"
chk "apply.sh 调 seed_conf"        "$(unzip -p "$OUT" apply.sh | grep -c 'seed_conf')" "1"
chk "install.sh 有配置保护"         "$(unzip -p "$OUT" install.sh | grep -c 'EXT_CONF')" "6"
chk "含 uninstall.sh"              "$(unzip -l "$OUT" | grep -c 'uninstall.sh')" "1"
chk "uninstall 清 mk-data 目录"     "$(unzip -p "$OUT" uninstall.sh | grep -c 'rm -rf /data/local/mk-data')" "1"
chk "uninstall 停采样进程"          "$(unzip -p "$OUT" uninstall.sh | grep -c 'pgrep -f')" "3"

# ---- 1.2.0 记录仪新增自检（2026-10-10）----
chk "含 recorder.sh"                "$(unzip -l "$OUT" | grep -c 'lib/recorder.sh')" "1"
chk "config 记录仪开关"             "$(unzip -p "$OUT" config.conf | sed -n 's/^RECORDER_ENABLE=//p' | head -1)" "1"
chk "config 采样器已关闭"            "$(unzip -p "$OUT" config.conf | sed -n 's/^SAMPLER_ENABLE=//p' | head -1)" "0"
chk "config 游戏名单含王者"          "$(unzip -p "$OUT" config.conf | sed -n 's/^RECORDER_GAME_LIST=//p' | grep -c 'sgame')" "1"
chk "recorder 充电检测"             "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'rec_is_charging')" "5"
chk "recorder 游戏检测"             "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'rec_is_game')" "2"
chk "recorder 归档函数"             "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'rec_archive')" "4"
chk "recorder 低功耗 read 原语"      "$(unzip -p "$OUT" lib/recorder.sh | grep -c '^r1()')" "1"
chk "recorder 持 proc 截断规避"      "$(unzip -p "$OUT" lib/recorder.sh | grep -c '^rn()')" "1"
chk "recorder 后台入口"             "$(unzip -p "$OUT" lib/recorder.sh | grep -c '_bg)')" "2"
chk "service.sh 调记录仪"           "$(unzip -p "$OUT" service.sh | grep -c 'recorder_boot_start')" "1"
chk "uninstall 停记录仪"            "$(unzip -p "$OUT" uninstall.sh | grep -c 'recorder')" "4"

# ---- 1.2.1 记录仪修复 + 自定义包名（2026-10-10）----
# 说明：这几项用「非零存在性」判据，避免写死计数后一改代码就误报 FAIL。
chk_nz() {
    if [ -n "$2" ] && [ "$2" != "0" ]; then
        printf '  [OK]   %-38s %s\n' "$1" "$2"; PASS=$((PASS+1))
    else
        printf '  [FAIL] %-38s got=%s want=非0\n' "$1" "$2"; FAIL=$((FAIL+1))
    fi
}
chk_nz "config 有 GAME_EXTRA 说明"   "$(unzip -p "$OUT" config.conf | grep -c 'RECORDER_GAME_EXTRA')"
chk    "config MIN_ROWS=3"          "$(unzip -p "$OUT" config.conf | sed -n 's/^RECORDER_MIN_ROWS=//p' | head -1)" "3"
chk    "recorder 读多行配置函数"      "$(unzip -p "$OUT" lib/recorder.sh | grep -c '^rec_cfg_all()')" "1"
chk_nz "recorder 用 GAME_EXTRA"      "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'RECORDER_GAME_EXTRA')"
chk    "recorder 建段写 .boot"       "$(unzip -p "$OUT" lib/recorder.sh | grep -c '^rec_capture_boot_id()')" "1"
chk_nz "recorder 建段调快照"          "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'rec_capture_boot_id')"
chk    "recorder meta 取 .boot"      "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'captured_at')" "1"
chk_nz "recorder 脏段阈值逻辑"        "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'RECORDER_MIN_ROWS')"
chk    "recorder pid cmdline 校验"   "$(unzip -p "$OUT" lib/recorder.sh | grep -c '^rec_read_pid()')" "1"
chk_nz "recorder 用 rec_read_pid"    "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'rec_read_pid')"
chk_nz "recorder 前缀通配代码"        "$(unzip -p "$OUT" lib/recorder.sh | grep -c '_p=\"\${g%')"
chk    "recorder 段名同秒去重"        "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'ts1=\"\${ts0}s\"')" "1"
# ---- 1.2.2 游戏检测周期（2026-10-11）----
chk    "config 检测周期项"            "$(unzip -p "$OUT" config.conf | sed -n 's/^RECORDER_GAME_CHECK_SEC=//p' | head -1)" "180"
chk    "recorder 按秒计检测"          "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'RECORDER_GAME_CHECK_SEC')" "3"
chk    "recorder 去掉轮询计数"        "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'counter % 5')" "0"
chk    "recorder 有 game_next"        "$(unzip -p "$OUT" lib/recorder.sh | grep -c 'game_next')" "3"

echo
if [ "$FAIL" != "0" ]; then
    echo "!! 包内自检未通过（FAIL=$FAIL）—— 不要分发这个包"
    exit 1
fi
echo "  包内自检全部通过（PASS=$PASS）"

echo
echo "=== 3. 写 SOURCE-STAMP ==="
{
    echo "# MK-Addon 源码指纹与产物记录"
    echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 用途: 交付链路比对（见 交付校验清单.md）"
    echo
    echo "[source_md5]"
    for f in module.prop install.sh customize.sh uninstall.sh config.conf service.sh apply.sh collect.sh lib/common.sh lib/tune.sh lib/zram.sh lib/sampler.sh lib/recorder.sh; do
        [ -f "$f" ] && printf '%-18s %s\n' "$f" "$(md5sum "$f" | cut -d' ' -f1)"
    done
    echo
    echo "[artifact]"
    echo "file    $OUT"
    echo "md5     $OUT_MD5"
    echo "size    $(stat -c %s "$OUT" 2>/dev/null || wc -c < "$OUT")"
} > "$STAMP"
echo "  已写: $STAMP"

echo
echo "=== 4. 下一层（AK3）需要做的 ==="
echo "  把本包换进 AK3 后，核对："
echo "    AK3 内嵌 mk-addon.zip 的 md5 == ${OUT_MD5}"
echo "  然后用 mk-verify.sh 跑四层校验。"
echo
echo "完成: $OUT  ($OUT_MD5)"