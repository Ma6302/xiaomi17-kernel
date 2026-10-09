#!/system/bin/sh
# apply.sh - apply config now (no reboot needed)
# usage: su -c /data/adb/modules/mk-addon/apply.sh [--only zram|vm|io|net|mctrl]

MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$MODDIR/lib/common.sh"
. "$MODDIR/lib/tune.sh"
. "$MODDIR/lib/zram.sh"

ONLY=""
case "$1" in
    --only) ONLY="$2" ;;
esac

log "================ apply.sh start (only='${ONLY:-all}') ================"

if [ -z "$ONLY" ]; then
    load_conf || { log "no config.conf, abort"; exit 1; }
    me="$(cfg_get MASTER_ENABLE 1)"
    if [ "$me" != "1" ]; then
        log "MASTER_ENABLE != 1, nothing to do"
        exit 0
    fi
fi

run_all() {
    tune_vm
    tune_io
    tune_net
    zram_apply
    mctrl_apply
}

case "$ONLY" in
    zram)  load_conf; zram_apply ;;
    mctrl) load_conf; mctrl_apply ;;
    vm)    load_conf; tune_vm ;;
    io)    load_conf; tune_io ;;
    net)   load_conf; tune_net ;;
    "")    run_all ;;
    *)     log "unknown --only '$ONLY'"; run_all ;;
esac

log "================ apply.sh done ================"
echo "mk-addon: applied. log -> $LOG"