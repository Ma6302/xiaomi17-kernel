#!/system/bin/sh
# ============================================================
# mk-verify.sh — MK-Addon 交付链路校验（四层验证自动化）
#
# 用法（proot 终端）: sh mk-verify.sh
# 用法（Android root）: su -c sh /path/mk-verify.sh
#
# 依据：交接-MK-Addon模块回归事故-20261010.md
# 目的：防止「源码升级了但交付物还是旧的」
# ============================================================

SRC="/sdcard/Download/Operit/kernel-dev/mk-addon"
PKG="$SRC/mk-addon-1.2.2.zip"
AK3DIR="/sdcard/Download/pudding-kernel/01-自编内核包"
AK3="$AK3DIR/pudding-cctv18-20261010-v3.zip"
AK3B="/sdcard/Download/pudding-kernel/05-归档/pudding-cctv18-20261010-mqhd-pathC.zip"
DEPLOY="/data/adb/modules/mk-addon"
EXT_CONF="/data/adb/mk-addon/config.conf"
W="/sdcard/Download/Operit/kernel-dev/ak3-fix-20261010/verify-tmp"
mkdir -p "$W" 2>/dev/null

PASS=0
FAIL=0

chk() {
    # chk "描述" "实际值" "期望值"
    if [ "$2" = "$3" ]; then
        printf '  [OK]   %-46s %s\n' "$1" "$2"
        PASS=$((PASS+1))
    else
        printf '  [FAIL] %-46s got=%s want=%s\n' "$1" "$2" "$3"
        FAIL=$((FAIL+1))
    fi
}

echo "============================================================"
echo "  MK-Addon 交付链路校验  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ---------- 第 1 层：源码 ----------
echo
echo "【第 1 层】权威源码  $SRC"
if [ -d "$SRC" ]; then
    chk "common.sh 守卫函数数"  "$(grep -cE 'kernel_is_ours|guard_check' "$SRC/lib/common.sh" 2>/dev/null)"  "3"
    chk "service.sh 调用守卫"    "$(grep -c 'guard_check' "$SRC/service.sh" 2>/dev/null)"  "1"
    chk "config.conf ZRAM_ALGO"  "$(sed -n 's/^ZRAM_ALGO=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "lz4"
    chk "config.conf READ_AHEAD" "$(sed -n 's/^READ_AHEAD_KB=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "0"
    chk "config.conf KERNEL_GUARD" "$(sed -n 's/^KERNEL_GUARD=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "1"
    chk "collect.sh 快照标记"    "$(grep -c 'kernel_is_ours' "$SRC/collect.sh" 2>/dev/null)"  "1"
    chk "apply.sh 参数扫描"      "$(grep -cE 'GUARD_FORCE|--force' "$SRC/apply.sh" 2>/dev/null)"  "5"
    # 方案C / 零残余（1.1.0）
    chk "common.sh EXT_CONF"     "$(grep -c 'EXT_CONF=' "$SRC/lib/common.sh" 2>/dev/null)"  "1"
    chk "common.sh seed_conf"    "$(grep -c 'seed_conf' "$SRC/lib/common.sh" 2>/dev/null)"  "1"
    chk "install.sh 配置保护"     "$(grep -c 'EXT_CONF' "$SRC/install.sh" 2>/dev/null)"  "6"
    chk "uninstall.sh 存在"      "$([ -f "$SRC/uninstall.sh" ] && echo 1 || echo 0)"  "1"
    chk "sampler 有 trap 退出"    "$(grep -c 'trap ' "$SRC/lib/sampler.sh" 2>/dev/null)"  "1"
    # 1.2.0 记录仪
    chk "recorder.sh 存在"       "$([ -f "$SRC/lib/recorder.sh" ] && echo 1 || echo 0)"  "1"
    # 说明：以下用非零判据，避免改代码后计数漂移误报
    chk_nz() {
        if [ -n "$2" ] && [ "$2" != "0" ]; then
            printf '  [OK]   %-46s %s\n' "$1" "$2"; PASS=$((PASS+1))
        else
            printf '  [FAIL] %-46s got=%s want=非0\n' "$1" "$2"; FAIL=$((FAIL+1))
        fi
    }
    chk_nz "recorder 充电检测"    "$(grep -c 'rec_is_charging' "$SRC/lib/recorder.sh" 2>/dev/null)"
    chk_nz "recorder 游戏名单(王者)" "$(grep -c 'sgame' "$SRC/config.conf" 2>/dev/null)"
    chk "config 采样器已关"       "$(sed -n 's/^SAMPLER_ENABLE=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "0"
    chk "service 调记录仪"        "$(grep -c 'recorder_boot_start' "$SRC/service.sh" 2>/dev/null)"  "1"
    chk "版本号 1.2.1"           "$(sed -n 's/^version=//p' "$SRC/module.prop" 2>/dev/null)"  "1.2.2"
    # 1.2.1 新增
    chk_nz "config GAME_EXTRA"    "$(grep -c 'RECORDER_GAME_EXTRA' "$SRC/config.conf" 2>/dev/null)"
    chk   "config MIN_ROWS"       "$(sed -n 's/^RECORDER_MIN_ROWS=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "3"
    chk   "recorder 多行配置函数"  "$(grep -c '^rec_cfg_all()' "$SRC/lib/recorder.sh" 2>/dev/null)"  "1"
    chk   "recorder 建段写 .boot" "$(grep -c '^rec_capture_boot_id()' "$SRC/lib/recorder.sh" 2>/dev/null)"  "1"
    chk   "recorder pid 校验"     "$(grep -c '^rec_read_pid()' "$SRC/lib/recorder.sh" 2>/dev/null)"  "1"
    chk   "recorder 脏段阈值"     "$(grep -c 'RECORDER_MIN_ROWS' "$SRC/lib/recorder.sh" 2>/dev/null | awk '{print ($1>0)?1:0}')"  "1"
    chk   "recorder 同秒去重"     "$(grep -c 'ts1="\${ts0}s"' "$SRC/lib/recorder.sh" 2>/dev/null)"  "1"
    # 1.2.2 游戏检测周期
    chk   "版本号 1.2.2"         "$(sed -n 's/^version=//p' "$SRC/module.prop" 2>/dev/null)"  "1.2.2"
    chk   "config 检测周期"       "$(sed -n 's/^RECORDER_GAME_CHECK_SEC=//p' "$SRC/config.conf" 2>/dev/null | head -1)"  "180"
    chk   "recorder 按秒检测"     "$(grep -c 'RECORDER_GAME_CHECK_SEC' "$SRC/lib/recorder.sh" 2>/dev/null)"  "3"
    chk   "recorder 无轮询计数"   "$(grep -c 'counter % 5' "$SRC/lib/recorder.sh" 2>/dev/null)"  "0"
else
    echo "  [FAIL] 源码目录不存在"
    FAIL=$((FAIL+1))
fi

# ---------- 第 2 层：包内 ----------
echo
echo "【第 2 层】打包产物  mk-addon-1.2.2.zip"
if [ -f "$PKG" ]; then
    printf '  [i]    包 md5: %s\n' "$(md5sum "$PKG" | cut -c1-16)"
    chk "包内 common.sh 守卫函数" "$(unzip -p "$PKG" lib/common.sh 2>/dev/null | grep -cE 'kernel_is_ours|guard_check')" "3"
    chk "包内 config.conf ZRAM_ALGO" "$(unzip -p "$PKG" config.conf 2>/dev/null | sed -n 's/^ZRAM_ALGO=//p' | head -1)" "lz4"
    chk "包内 config.conf READ_AHEAD" "$(unzip -p "$PKG" config.conf 2>/dev/null | sed -n 's/^READ_AHEAD_KB=//p' | head -1)" "0"
    # 包内 md5 与源码比
    S1=$(md5sum "$SRC/lib/common.sh" 2>/dev/null | cut -c1-8)
    S2=$(unzip -p "$PKG" lib/common.sh 2>/dev/null | md5sum | cut -c1-8)
    chk "包内 common.sh == 源码" "$S2" "$S1"
else
    echo "  [FAIL] 包不存在"
    FAIL=$((FAIL+1))
fi

# ---------- 第 3 层：AK3 内嵌件 ----------
echo
echo "【第 3 层】AK3 内嵌件  $(basename "$AK3")"
if [ -f "$AK3" ]; then
    rm -f "$W/mk-addon.zip" 2>/dev/null
    if unzip -o "$AK3" mk-addon.zip -d "$W" >/dev/null 2>&1; then
        A3=$(md5sum "$W/mk-addon.zip" | cut -c1-8)
        P2=$(md5sum "$PKG" | cut -c1-8)
        chk "AK3内嵌件 == 正确包" "$A3" "$P2"
        chk "AK3内嵌件 守卫函数" "$(unzip -p "$W/mk-addon.zip" lib/common.sh 2>/dev/null | grep -cE 'kernel_is_ours|guard_check')" "3"
        chk "AK3内嵌件 ZRAM_ALGO" "$(unzip -p "$W/mk-addon.zip" config.conf 2>/dev/null | sed -n 's/^ZRAM_ALGO=//p' | head -1)" "lz4"
        echo "  [i]    内嵌件 md5: $A3   （旧版为 d92dfca2，见到即事故）"
    else
        echo "  [i]    此包无内嵌 mk-addon.zip（不算失败）"
    fi
else
    echo "  [FAIL] AK3 包不存在: $AK3"
    FAIL=$((FAIL+1))
fi

# ---------- 第 3b 层：另一个 AK3 包 ----------
echo
echo "【第 3b 层】另一个 AK3  $(basename "$AK3B")"
if [ -f "$AK3B" ]; then
    rm -f "$W/mk-addon.zip" 2>/dev/null
    if unzip -o "$AK3B" mk-addon.zip -d "$W" >/dev/null 2>&1; then
        B3=$(md5sum "$W/mk-addon.zip" | cut -c1-8)
        chk "pathC 内嵌件 == 正确包" "$B3" "$(md5sum "$PKG" | cut -c1-8)"
    else
        echo "  [i]    此包无内嵌 mk-addon.zip"
    fi
else
    echo "  [i]    包不存在（可忽略）"
fi

# ---------- 第 4 层：设备上 ----------
echo
echo "【第 4 层】设备部署  $DEPLOY"
if [ -d "$DEPLOY" ]; then
    chk "设备 common.sh 守卫函数" "$(grep -cE 'kernel_is_ours|guard_check' "$DEPLOY/lib/common.sh" 2>/dev/null)" "3"
    chk "设备 ZRAM_ALGO"  "$(sed -n 's/^ZRAM_ALGO=//p' "$DEPLOY/config.conf" 2>/dev/null | head -1)" "lz4"
    chk "设备 READ_AHEAD" "$(sed -n 's/^READ_AHEAD_KB=//p' "$DEPLOY/config.conf" 2>/dev/null | head -1)" "0"
else
    echo "  [i]    设备目录不可读（proot 下正常，需 root）"
fi

# ---------- 汇总 ----------
echo
echo "============================================================"
echo "  结果: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = "0" ]; then
    echo "  ✅ 交付链路一致"
else
    echo "  ❌ 存在不一致 —— 按 交付校验清单.md 第 4 节排查"
fi
echo "============================================================"
rm -rf "$W" 2>/dev/null