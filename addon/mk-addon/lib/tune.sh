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
    # 拥塞控制（bbr 需内核支持；不可用则保持原值）
    cc="$(cfg_get TCP_CC keep)"
    if [ "$cc" != "keep" ]; then
        if grep -qw "$cc" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            write_val "$cc" /proc/sys/net/ipv4/tcp_congestion_control
        else
            log "  tcp_cc '$cc' 不可用，跳过"
        fi
    fi
    log "net: done"
}

# ---- WALT 调度库标记（游戏/Flutter 应用负载追踪优化）----
tune_walt() {
    [ "$(cfg_get WALT_TUNE 0)" = "1" ] || { log "walt: disabled"; return 0; }
    log "walt: start"
    libs="$(cfg_get WALT_SCHED_LIB 0)"
    [ "$libs" != "0" ] && write_val "$libs" /proc/sys/walt/sched_lib_name
    log "walt: done ($libs)"
}

# ---- cpuset 亲和（后台省电 / 前台全开）----
tune_cpuset() {
    [ "$(cfg_get CPUSET_TUNE 0)" = "1" ] || { log "cpuset: disabled"; return 0; }
    log "cpuset: start"
    # 小核列表（自动探测，默认 0-5）
    LITTLE="$(cfg_get CPUSET_BACKGROUND_CPUS auto)"
    if [ "$LITTLE" = "auto" ]; then
        LITTLE="$(cat /sys/devices/system/cpu/cpu0/topology/cluster_cpus_list 2>/dev/null || echo 0-5)"
    fi
    ALL="$(cat /sys/devices/system/cpu/present 2>/dev/null || echo 0-7)"
    write_val "$LITTLE" /dev/cpuset/background/cpus
    sb="$(cfg_get CPUSET_SYSTEM_BG_CPUS auto)"
    [ "$sb" = "auto" ] && sb="$ALL"
    write_val "$sb" /dev/cpuset/system-background/cpus
    write_val "$ALL" /dev/cpuset/foreground/cpus
    write_val "$ALL" /dev/cpuset/top-app/cpus
    log "cpuset: done (bg=$LITTLE sysbg=$sb)"
}