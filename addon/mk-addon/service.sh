#!/system/bin/sh
# service.sh - late_start service (runs at boot after system is up)
MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$MODDIR/lib/common.sh"

# wait for boot completion so nodes/memcg exist
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
    sleep 2
    i=$((i + 1))
done
# a little extra grace for /dev/memcg and zram setup to settle
sleep 5

log "================ service.sh boot apply ================"
load_conf || { log "no config.conf"; exit 0; }

# ---- 内核身份守卫：刷回原厂/别家内核后，本模块自动停止工作 ----
if ! guard_check; then
    log "service.sh: 守卫拦截，跳过全部调参"
    # 非我方内核时是否仍做「只读数据收集」（默认 0 = 完全停止工作）
    if [ "$(cfg_get GUARD_COLLECT_ON_FOREIGN 0)" = "1" ] \
       && [ "$(cfg_get COLLECT_ON_BOOT 1)" = "1" ]; then
        log "service.sh: 仅执行数据收集（快照会标记 NOT-OURS）"
        sh "$MODDIR/collect.sh" >> "$LOG" 2>&1
    else
        log "service.sh: 数据收集亦跳过（GUARD_COLLECT_ON_FOREIGN=0）"
    fi
    log "================ service.sh done (guarded, 未做任何改动) ================"
    exit 0
fi

if [ "$(cfg_get MASTER_ENABLE 1)" != "1" ]; then
    log "MASTER_ENABLE != 1 -> skip tuning"
else
    . "$MODDIR/lib/tune.sh"
    . "$MODDIR/lib/zram.sh"
    tune_vm
    tune_io
    tune_net
    zram_apply
    mctrl_apply
fi

# data collection (uses its own config read)
if [ "$(cfg_get COLLECT_ON_BOOT 1)" = "1" ]; then
    sh "$MODDIR/collect.sh" >> "$LOG" 2>&1
fi

log "================ service.sh done ================"