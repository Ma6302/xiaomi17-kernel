#!/system/bin/sh
# lib/sampler.sh — A/B 测试数据自动采样（MK-Addon 内置，受守卫与开关控制）
# 用途：为 sched_entity_freq / MQHD / zram 算法等开关的 A/B 测试积累数据
# 数据：$COLLECT_DIR/sampler/samples.tsv（13 列 TSV，带内核版本串归属断言）
# 开关（config.conf）：SAMPLER_ENABLE / SAMPLER_INTERVAL / SAMPLER_KEEP_DAYS
# 手动用法（source 本文件后）：sampler_ctl start|stop|once|mark <label>|status
# 注意：_bg 分支在独立子进程运行，不得依赖 common.sh 的函数/变量 —— 全部自带兜底。

# 兜底：独立子进程（_bg）没有 common.sh 环境
SAMPLER_DIR="${COLLECT_DIR:-/data/local/mk-data}/sampler"
S_LOG="$SAMPLER_DIR/samples.tsv"
S_MARKS="$SAMPLER_DIR/marks.tsv"
S_PIDF="$SAMPLER_DIR/sampler.pid"

# ---------- 单次采样：一行 TSV ----------
sampler_sample_once() {
    ts=$(date +%s)
    ktag=$(uname -r)
    # 电池（注意：充电状态下 current 不可用于功耗比较，仅记录）
    bi=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
    bv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
    bt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    # zram
    za=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\[[a-z0-9-]*\]' | tr -d '[]')
    # mi_sched / sched_ext
    men=$(cat /sys/kernel/mi_sched/enable 2>/dev/null)
    mst=$(cat /sys/kernel/mi_sched/state 2>/dev/null)
    sst=$(cat /sys/kernel/sched_ext/state 2>/dev/null)
    # sched_entity_freq
    sen=$(cat /sys/devices/system/cpu/dcvs_arbi/sched_entity_freq1/enable 2>/dev/null)
    # qos_sched
    qos=$(cat /sys/kernel/qos_sched/sched_enable 2>/dev/null | tr -d '\n\t' | tr ':' '=')
    # 负载
    load=$(cat /proc/loadavg | cut -d' ' -f1-3 | tr ' ' ',')
    up=$(cut -d. -f1 /proc/uptime)

    echo -e "$ts\t$ktag\t$bi\t$bv\t$bt\t$za\t$men\t$mst\t$sst\t$sen\t$qos\t$load\t$up" >> "$S_LOG"

    # 快照型数据单独存（行太长）
    cat /sys/block/zram0/mm_stat 2>/dev/null | tr ' ' ',' > "$SAMPLER_DIR/zram-mm-last.tsv"
    cat /dev/memcg/memory.xswapd.stat 2>/dev/null | tr '\n' ';' > "$SAMPLER_DIR/xswapd-last.tsv"
    cat /sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state 2>/dev/null | tr '\n' ';' | tr ' ' ',' > "$SAMPLER_DIR/tis-policy0-last.tsv"
    cat /sys/devices/system/cpu/cpufreq/policy6/stats/time_in_state 2>/dev/null | tr '\n' ';' | tr ' ' ',' > "$SAMPLER_DIR/tis-policy6-last.tsv"
}

# ---------- 后台循环（独立子进程） ----------
sampler_loop() {
    interval="${1:-60}"
    echo $$ > "$S_PIDF"
    # 收到 SIGTERM/SIGINT 立即清理并退出（否则会留在 sleep 60 里不响应）
    trap 'rm -f "$S_PIDF"; exit 0' TERM INT HUP
    while [ -f "$S_PIDF" ]; do
        sampler_sample_once
        # sleep 拆成 1s 小步，便于及时响应停止信号与 pid 文件消失
        i=0
        while [ $i -lt "$interval" ]; do
            [ -f "$S_PIDF" ] || { rm -f "$S_PIDF"; exit 0; }
            sleep 1
            i=$((i + 1))
        done
    done
    rm -f "$S_PIDF"
}

# ---------- 控制入口 ----------
# cmd: start|stop|once|mark|status|_bg ；_bg 的间隔从 $2 取（子进程无 cfg_get）
sampler_ctl() {
    cmd="${1:-status}"
    interval="${2:-60}"

    mkdir -p "$SAMPLER_DIR" 2>/dev/null

    case "$cmd" in
        _bg)
            # 独立子进程入口
            sampler_loop "$interval"
            ;;
        start)
            if [ -f "$S_PIDF" ] && [ -d "/proc/$(cat $S_PIDF 2>/dev/null)" ]; then
                echo "sampler already running (pid $(cat $S_PIDF))"
                return 0
            fi
            # 有 cfg_get（service/手动上下文）则读配置
            if command -v cfg_get >/dev/null 2>&1; then
                interval=$(cfg_get SAMPLER_INTERVAL 60)
            fi
            # 归档上一段
            [ -f "$S_LOG" ] && mv "$S_LOG" "$SAMPLER_DIR/samples-$(date +%Y%m%d-%H%M%S).tsv"
            echo -e "ts\tkernel\tbatt_uA\tbatt_uV\tbatt_T\tzram_algo\tmi_enable\tmi_state\tscx_state\tsef_enable\tqos\tload\tuptime" > "$SAMPLER_DIR/header.tsv"
            nohup sh "${MODDIR:-/data/adb/modules/mk-addon}/lib/sampler.sh" _bg "$interval" >/dev/null 2>&1 &
            echo "sampler started: interval=${interval}s pid=$!"
            ;;
        stop)
            if [ -f "$S_PIDF" ]; then
                kill "$(cat $S_PIDF)" 2>/dev/null
                rm -f "$S_PIDF"
                echo "sampler stopped"
            else
                echo "sampler not running"
            fi
            ;;
        once)
            sampler_sample_once
            echo "sampled -> $S_LOG"
            ;;
        mark)
            [ -n "$2" ] || { echo "usage: sampler_ctl mark <label>"; return 1; }
            echo -e "$(date +%s)\t$2\t$(uname -r)" >> "$S_MARKS"
            echo "mark '$2' recorded"
            ;;
        status)
            if [ -s "$S_PIDF" ] && [ -d "/proc/$(cat $S_PIDF 2>/dev/null)" ]; then
                echo "running (pid $(cat $S_PIDF))"
            else
                echo "stopped"
            fi
            echo "samples: $(wc -l < "$S_LOG" 2>/dev/null || echo 0) rows"
            ;;
        *)
            echo "usage: sampler_ctl {start|stop|once|mark <label>|status}"
            return 1
            ;;
    esac
}

# service.sh 调用入口：守卫已在 service.sh 拦过，这里只管开关
sampler_boot_start() {
    if [ "$(cfg_get SAMPLER_ENABLE 0)" != "1" ]; then
        log "sampler: SAMPLER_ENABLE != 1 -> skip"
        return 0
    fi
    log "sampler: $(sampler_ctl start)"
}

# ---- 顶层 dispatch：作为脚本直接执行时生效（nohup 后台子进程用）----
case "$1" in
    _bg) sampler_loop "${2:-60}" ;;
esac