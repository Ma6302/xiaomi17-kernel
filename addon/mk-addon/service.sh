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