#!/system/bin/sh
# lib/tune.sh - general parameter tuning

tune_vm() {
    log "vm: start"
    write_val "$(cfg_get SWAPPINESS 100)"          /proc/sys/vm/swappiness
    write_val "$(cfg_get VFS_CACHE_PRESSURE 100)"  /proc/sys/vm/vfs_cache_pressure
    write_val "$(cfg_get COMPACTION_PROACTIVENESS 20)" /proc/sys/vm/compaction_proactiveness
    write_val "$(cfg_get WATERMARK_BOOST_FACTOR 0)"   /proc/sys/vm/watermark_boost_factor
    write_val "$(cfg_get EXTFRAG_THRESHOLD 1000)"     /proc/sys/vm/extfrag_threshold

    dr="$(cfg_get DIRTY_RATIO 0)"
    [ "$dr" != "0" ] && write_val "$dr" /proc/sys/vm/dirty_ratio
    log "vm: done"
}

tune_io() {
    log "io: start"
    sched="$(cfg_get IO_SCHEDULER keep)"
    if [ "$sched" != "keep" ]; then
        for s in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler \
                 /sys/block/dm-*/queue/scheduler; do
            [ -f "$s" ] || continue
            grep -qw "$sched" "$s" 2>/dev/null && write_val "$sched" "$s"
        done
    else
        log "  scheduler: keep"
    fi

    ra="$(cfg_get READ_AHEAD_KB 128)"
    [ "$ra" != "0" ] && for d in /sys/block/sd* /sys/block/mmcblk*; do
        [ -d "$d/queue" ] || continue
        write_val "$ra" "$d/queue/read_ahead_kb"
    done
    log "io: done"
}

tune_net() {
    [ "$(cfg_get NET_TUNE 0)" = "1" ] || { log "net: disabled"; return 0; }
    log "net: start"
    write_val 0 /proc/sys/net/ipv4/tcp_autocorking
    write_val 5 /proc/sys/net/ipv4/tcp_fin_timeout
    write_val 1 /proc/sys/net/ipv4/tcp_tw_reuse
    write_val 1 /proc/sys/net/ipv4/tcp_shrink_window
    write_val 10 /proc/sys/net/ipv4/tcp_reordering
    write_val 1000 /proc/sys/net/ipv4/tcp_max_reordering
    write_val 1 /proc/sys/net/ipv4/tcp_thin_linear_timeouts
    write_val "65536 1048576 16777216" /proc/sys/net/ipv4/tcp_rmem
    write_val "65536 1048576 16777216" /proc/sys/net/ipv4/tcp_wmem
    write_val 0 /proc/sys/net/ipv4/tcp_slow_start_after_idle
    write_val 1 /proc/sys/net/ipv4/tcp_no_metrics_save
    write_val 3 /proc/sys/net/ipv4/tcp_retries1
    log "net: done"
}