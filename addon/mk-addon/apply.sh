#!/system/bin/sh
# apply.sh - apply config now (no reboot needed)
# usage: su -c /data/adb/modules/mk-addon/apply.sh [--only zram|vm|io|net|mctrl]

MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$MODDIR/lib/common.sh"
. "$MODDIR/lib/tune.sh"
. "$MODDIR/lib/zram.sh"

ONLY=""
FORCE=""
# 扫描全部参数（--only X 与 --force 可任意顺序组合）
while [ $# -gt 0 ]; do
    case "$1" in
        --only)  ONLY="$2"; shift 2 ;;
        --force) FORCE="1"; shift ;;
        *)       shift ;;
    esac
done
GUARD_FORCE="$FORCE"

log "================ apply.sh start (only='${ONLY:-all}'${FORCE:+, force}) ================"

# 方案C：确保外部持久配置存在（首次运行播种）
seed_conf
load_conf || { log "no config.conf, abort"; exit 1; }
log "apply.sh: conf = $CONF"

# ---- 内核身份守卫 ----
if ! guard_check; then
    log "apply.sh: 守卫拦截，未做任何改动。"
    log "apply.sh: 如确需在原厂/别家内核上强制执行，用 --force"
    echo "mk-addon: 当前内核 $(uname -r) 不是本项目内核，已跳过。如需强制：apply.sh --force"
    exit 2
fi

if [ -z "$ONLY" ]; then
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
    tune_walt
    tune_cpuset
    zram_apply
    mctrl_apply
}

case "$ONLY" in
    zram)  load_conf; zram_apply ;;
    mctrl) load_conf; mctrl_apply ;;
    vm)    load_conf; tune_vm ;;
    io)    load_conf; tune_io ;;
    net)   load_conf; tune_net ;;
    walt)  load_conf; tune_walt ;;
    cpuset) load_conf; tune_cpuset ;;
    "")    run_all ;;
    *)     log "unknown --only '$ONLY'"; run_all ;;
esac

log "================ apply.sh done ================"
echo "mk-addon: applied. log -> $LOG"