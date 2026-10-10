#!/system/bin/sh
# lib/zram.sh - zram + compression algorithm + Xiaomi zgroup/xswapd/mctrl control

ZRAM_DEV=/sys/block/zram0

# detect current algorithm from comp_algorithm (bracketed one)
zram_cur_algo() {
    if [ -f "$ZRAM_DEV/comp_algorithm" ]; then
        sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ZRAM_DEV/comp_algorithm" 2>/dev/null
    fi
}

zram_algo_supported() {
    [ -f "$ZRAM_DEV/comp_algorithm" ] || return 1
    grep -qw "$1" "$ZRAM_DEV/comp_algorithm" 2>/dev/null
}

# find the swap file/prio currently used by zram0
zram_swap_prio() {
    awk '$1 ~ /zram0/ {print $5}' /proc/swaps 2>/dev/null | head -1
}

zram_swap_on() {
    grep -q '^/dev/block/zram0' /proc/swaps 2>/dev/null || \
    grep -qw 'zram0' /proc/swaps 2>/dev/null
}

do_swapoff() {
    if zram_swap_on; then
        log "  swapoff zram0"
        swapoff /dev/block/zram0 2>/dev/null || swapoff -a 2>/dev/null
    fi
}

do_swapon() {
    # NOTE: after zram reset the device must be mkswap'd again before swapon.
    # Toybox swapon rejects negative -p and a freshly reset device has no
    # on-disk swap signature, so we mkswap then swapon without -p
    # (ROM assigns the same default priority).
    if [ "$(cfg_get ZRAM_MKSWAP 1)" = "1" ]; then
        mkswap /dev/block/zram0 >/dev/null 2>&1
        log "  mkswap zram0"
    fi
    swapon /dev/block/zram0 2>/dev/null
    log "  swapon zram0 rc=$?"
}

# switch algorithm (DESTRUCTIVE: resets zram)
zram_set_algo() {
    want="$1"
    [ "$want" = "keep" ] && { log "  algo: keep"; return 0; }
    cur="$(zram_cur_algo)"
    if [ "$cur" = "$want" ]; then
        log "  algo already $want"
        return 0
    fi
    if ! zram_algo_supported "$want"; then
        log "  algo $want NOT supported (avail: $(cat $ZRAM_DEV/comp_algorithm 2>/dev/null))"
        return 1
    fi
    log "  switching algo $cur -> $want (swapoff/reset/on)"
    do_swapoff
    echo 1 > "$ZRAM_DEV/reset" 2>/dev/null
    echo "$want" > "$ZRAM_DEV/comp_algorithm" 2>/dev/null || {
        log "  FAIL set comp_algorithm=$want"
        return 1
    }
    # disksize must be set again after reset
    ds_gb="$(cfg_get ZRAM_DISKSIZE_GB 0)"
    if [ "$ds_gb" != "0" ]; then
        ds=$(( ds_gb * 1024 * 1024 * 1024 ))
        echo "$ds" > "$ZRAM_DEV/disksize" 2>/dev/null
        log "  disksize=$ds"
    else
        [ -n "$SAVED_DISKSIZE" ] && echo "$SAVED_DISKSIZE" > "$ZRAM_DEV/disksize" 2>/dev/null && \
            log "  disksize restored=$SAVED_DISKSIZE"
    fi
    # zgroup_enable survives reset on this device; verify and only warn if lost
    if [ -f "$ZRAM_DEV/zgroup_enable" ]; then
        zg="$(cat $ZRAM_DEV/zgroup_enable 2>/dev/null)"
        if [ "$zg" != "1" ]; then
            echo 1 > "$ZRAM_DEV/zgroup_enable" 2>/dev/null
            log "  zgroup_enable was $zg -> $(cat $ZRAM_DEV/zgroup_enable 2>/dev/null)"
        else
            log "  zgroup_enable ok (=1)"
        fi
    fi
    [ "$(cfg_get ZRAM_REMOUNT_SWAP 1)" = "1" ] && do_swapon
    log "  new algo: $(zram_cur_algo)"
}

zram_apply() {
    [ "$(cfg_get ZRAM_ENABLE 1)" = "1" ] || { log "zram: disabled in config"; return 0; }

    SAVED_DISKSIZE="$(node_read $ZRAM_DEV/disksize)"
    [ "$SAVED_DISKSIZE" = "0" ] && SAVED_DISKSIZE=""

    log "zram: start (before: algo=$(zram_cur_algo) disksize=$(node_read $ZRAM_DEV/disksize))"
    zram_set_algo "$(cfg_get ZRAM_ALGO keep)"

    ds_gb="$(cfg_get ZRAM_DISKSIZE_GB 0)"
    if [ "$ds_gb" != "0" ] && [ "$(node_read $ZRAM_DEV/disksize)" = "0" ]; then
        ds=$(( ds_gb * 1024 * 1024 * 1024 ))
        echo "$ds" > "$ZRAM_DEV/disksize" 2>/dev/null && log "  disksize set $ds"
    fi
    log "zram: done (after: algo=$(zram_cur_algo) disksize=$(node_read $ZRAM_DEV/disksize))"
}

# ---- Xiaomi zgroup / xswapd / mctrl ----
mctrl_apply() {
    log "mi-zram: start"
    xswapd="$(cfg_get XSWAPD_ENABLE 0)"
    [ "$xswapd" = "1" ] || [ "$xswapd" = "0" ] && \
        write_val "$xswapd" /dev/memcg/memory.xswapd.enable

    cr="$(cfg_get MCTRL_COMP_RATIO 0)"
    [ "$cr" != "0" ] && write_val "$cr" /dev/memcg/memory.mctrl.comp_ratio

    wr="$(cfg_get MCTRL_WB_RATIO 0)"
    [ "$wr" != "0" ] && write_val "$wr" /dev/memcg/memory.mctrl.wb_ratio

    log "mi-zram: done (xswapd.enable=$(node_read /dev/memcg/memory.xswapd.enable))"
}