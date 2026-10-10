#!/system/bin/sh
# lib/recorder.sh — 内核日常记录仪（MK-Addon 内置）
#
# 设计目标（2026-10-10 用户需求）
#   1. 充电中  → 不记录（"插上充电器"本身是归档触发点）
#   2. 游戏中  → 不记录（游戏性能数据由用户主动用 Scene 采集）
#   3. 非充电+非游戏 → 持续记录
#   4. 插充电器 → 把【刚结束的那段】归档到工作区，然后停止记录
#   5. 拔充电器 → 重新开始一段新记录
#   6. 省电优先：
#        - sysfs 全部用 shell 内建 read（避免 fork，实测快 41 倍）
#        - 段数据写 /data/local（ext4），仅归档时才复制到 sdcard
#        - 归档 = 文件直接复制（不摘取），下次记录重新生成
#
# 状态机
#   CHARGING  ──(拔)──►  RECORDING ──(插)──►  ARCHIVE ──► CHARGING
#                          │  ▲
#                       (游戏开始) │ (游戏结束)
#                          ▼  │
#                       PAUSED
#
# 开关（config.conf）：
#   RECORDER_ENABLE=1      总开关
#   RECORDER_INTERVAL=60   采样间隔（秒）
#   RECORDER_NICE=1        降优先级（nice 19 + ionice idle）
#   RECORDER_GAME_LIST=... 游戏包名（逗号分隔）
#   RECORDER_ARCH_DIR=...  归档目录（工作区）
#   RECORDER_KEEP_SEG=20   本地保留段数（超出删最旧）
#
# 手动用法（source 后）：
#   recorder_ctl {start|stop|status|once|archive|game <pkg>|chg}

# ---------- 自身定位 + 依赖 ----------
# 本文件既会被 service.sh 用 `.` 加载（此时 MODDIR/CONF 已由 common.sh 设定），
# 也会被 nohup 以 `sh recorder.sh _bg` 独立启动（此时没有 common.sh 环境）。
# 这里做双向兜底。
if [ -z "$MODDIR" ]; then
    _selfdir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    MODDIR="$(dirname "$_selfdir")"
fi
[ -n "$CONF" ] || [ -f "$MODDIR/lib/common.sh" ] && \
    [ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh" 2>/dev/null

# 配置读取兜底
# ⚠️ 不能用 cfg_get：它依赖 load_conf 已经把 KEY=VALUE 载入当前 shell 变量，
#    而本文件也会以 `sh recorder.sh _bg` 独立启动（此时从没跑过 load_conf），
#    会导致所有配置读成默认值 —— 实测踩过一次（RECORDER_ENABLE 读成 0）。
#    这里直接读配置文件，与 shell 变量状态无关。
REC_CFGF="${CONF:-/data/adb/mk-addon/config.conf}"
rec_cfg() {
    v="$(sed -n "s/^$1=//p" "$REC_CFGF" 2>/dev/null | head -1)"
    if [ -z "$v" ] && [ "$REC_CFGF" != "/data/adb/mk-addon/config.conf" ]; then
        v="$(sed -n "s/^$1=//p" /data/adb/mk-addon/config.conf 2>/dev/null | head -1)"
    fi
    [ -z "$v" ] && v="$2"
    echo "$v"
}

# rec_cfg_all KEY —— 读 KEY 的【所有】行。
# 用途：用户自定义追加项（如自己在配置文件里多行添加游戏包名）。
# 1.2.1 新增：支持 `RECORDER_GAME_EXTRA=` 重复出现多次，逐行累加。
rec_cfg_all() {
    sed -n "s/^$1=//p" "$REC_CFGF" 2>/dev/null
    if [ "$REC_CFGF" != "/data/adb/mk-addon/config.conf" ]; then
        sed -n "s/^$1=//p" /data/adb/mk-addon/config.conf 2>/dev/null
    fi
}

# ---------- 内核归属兜底 ----------
rec_kernel_is_ours() {
    if command -v kernel_is_ours >/dev/null 2>&1 && [ -n "$MASTER_ENABLE" ]; then
        kernel_is_ours
        return $?
    fi
    want="$(rec_cfg EXPECTED_KERNEL_TAG Ma6302)"
    [ -z "$want" ] && return 0
    case "$(uname -r 2>/dev/null)" in
        *"$want"*) return 0 ;;
    esac
    return 1
}

# ---------- 路径 ----------
REC_DIR="${REC_DIR:-/data/local/mk-rec}"
REC_CUR="$REC_DIR/current"                  # 当前段（正在写）
REC_SEGS="$REC_DIR/segments"                # 已完成但未归档的段
REC_ARCH="${RECORDER_ARCH_DIR:-/storage/emulated/0/Operit AI/小米17/6.12内核/内核日常记录}"
REC_LOGF="$REC_DIR/recorder.log"
REC_PIDF="$REC_DIR/recorder.pid"
REC_STATEF="$REC_DIR/state"                # 当前状态：charging|recording|paused|foreign

# 游戏包名默认表（用户 2026-10-10 指定）
REC_GAMES_DEFAULT="com.kurogame.mingchao,com.tencent.tmgp.dfm,com.tencent.tmgp.osgame,com.tencent.tmgp.sgame,com.playdigious.deadcells.epic"

# ---------- 日志（不依赖 common.sh，独立子进程也能用）----------
rec_log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$REC_LOGF"
}

# ---------- 低开销读取原语 ----------
# 全部优先用 shell 内建 read：不 fork 进程。实测比 `cat` 快 9~41 倍。
r1() {  # 读一行到 REPLY（适用于 /sys/ 与 /proc/ 下的字符串文件）
    REPLY=""
    [ -f "$1" ] && read REPLY < "$1" 2>/dev/null
    [ -z "$REPLY" ] && REPLY="-"
}

# rn()：读「纯数字」文件到 REPLY。
# ⚠️ 实测发现（2026-10-10，mksh 9.x / Android 17）：
#   对 /proc/sys/ 下的纯数字文件，`read X < f` 会**丢掉最后一个字符**
#     /proc/sys/vm/swappiness   内容 "100" → read 得 "1"
#     /proc/sys/kernel/panic    内容 "-1"  → read 得 "-"
#   /sys/ 下的数字文件不受影响（read 得 "100" 正常）。
#   因此 /proc/sys/ 数字一律走 cat（fork 开销可忽略：每段每条只读 1~2 个）。
rn() {
    REPLY="-"
    if [ -r "$1" ]; then
        case "$1" in
            /proc/sys/*) REPLY="$(cat "$1" 2>/dev/null)" ;;   # 规避 read 截断
            *)           read REPLY < "$1" 2>/dev/null ;;
        esac
    fi
    [ -z "$REPLY" ] && REPLY="-"
}

# 读多行文件，把换行压成 ';'（用于 time_in_state 等）
rall() {
    REPLY=""
    [ -f "$1" ] || { REPLY="-"; return; }
    while IFS= read -r l; do
        REPLY="${REPLY}${REPLY:+;}$l"
    done < "$1"
    [ -z "$REPLY" ] && REPLY="-"
}

# ---------- 充电状态 ----------
rec_is_charging() {
    r1 /sys/class/power_supply/usb/online
    [ "$REPLY" = "1" ] && return 0
    r1 /sys/class/power_supply/battery/status
    case "$REPLY" in
        Charging|Full|Not\ charging) [ "$REPLY" = "Not charging" ] && return 1; return 0 ;;
    esac
    return 1
}

# ---------- 前台包名（轻量：单次 dumpsys，纯 shell 解析，不 fork grep）----------
# 注意：dumpsys 的输出用管道喂给 while 时，while 在 subshell 里执行；
# 因此不能靠 while 内的变量赋值传出结果 —— 必须让 subshell 自己写出文件。
rec_foreground_pkg() {
    REPLY="-"
    [ -d "$REC_DIR" ] || mkdir -p "$REC_DIR" 2>/dev/null
    dumpsys activity activities 2>/dev/null \
        | while IFS= read -r _l; do
              case "$_l" in
                  *topResumedActivity*)
                      _rest="${_l#* u0 }"
                      printf '%s' "${_rest%%/*}"
                      break
                      ;;
              esac
          done > "$REC_DIR/.fg" 2>/dev/null
    read REPLY < "$REC_DIR/.fg" 2>/dev/null
    [ -z "$REPLY" ] && REPLY="-"
    return 0
}

# ---------- 游戏检测 ----------
# 名单来源（1.2.1）：
#   1. RECORDER_GAME_LIST   —— 主名单（逗号分隔）
#   2. RECORDER_GAME_EXTRA  —— 用户追加，**可重复多行**，每行一个包名（也兼容逗号分隔）
#      这样用户想加游戏时，只要在配置文件末尾加一行：
#          RECORDER_GAME_EXTRA=com.xxx.yyy
#      不需要动主名单，升级/重装也不会丢（外部配置持久）。
# 匹配规则：前台包名与名单项【完全相等】。也支持前缀通配 `com.foo.*`。
rec_is_game() {
    rec_foreground_pkg
    fg="$REPLY"
    [ "$fg" = "-" ] && return 1

    games="$(rec_cfg RECORDER_GAME_LIST "$REC_GAMES_DEFAULT")"
    [ -z "$games" ] && games="$REC_GAMES_DEFAULT"
    extra="$(rec_cfg_all RECORDER_GAME_EXTRA | tr '\n' ',')"

    old_ifs="$IFS"
    IFS=','
    for g in $games $extra; do
        IFS="$old_ifs"
        # 去掉可能的首尾空白（用户手写时容易带空格）
        g="$(printf '%s' "$g" | tr -d ' \t\r')"
        [ -z "$g" ] && { IFS=','; continue; }
        case "$g" in
            *'*')  # 前缀通配：com.foo.* 命中 com.foo.bar
                _p="${g%\*}"
                case "$fg" in "$_p"*) IFS="$old_ifs"; return 0 ;; esac
                ;;
            *)  [ "$fg" = "$g" ] && { IFS="$old_ifs"; return 0; } ;;
        esac
        IFS=','
    done
    IFS="$old_ifs"
    return 1
}

# ---------- 生成 meta（内核版本 + 参数）----------
# 写进段目录，随归档一起复制
rec_write_meta() {
    d="$1"
    [ -d "$d" ] || return 1
    # 确保配置已载入（独立子进程路径下 common.sh 可能只 load 了函数、没 load 值）
    if command -v load_conf >/dev/null 2>&1; then
        [ -n "$MASTER_ENABLE" ] || load_conf 2>/dev/null
    fi
    # 兜底：直接从配置文件解析（load_conf 不可用时）
    _mcfg() {
        v="$(sed -n "s/^$1=//p" "${CONF:-/data/adb/mk-addon/config.conf}" 2>/dev/null | head -1)"
        [ -z "$v" ] && v="$(sed -n "s/^$1=//p" /data/adb/mk-addon/config.conf 2>/dev/null | head -1)"
        echo "$v"
    }
    {
        echo "# MK-Addon 内核日常记录 — 段元数据"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        # ---- B1：内核归属（优先取建段时固化的快照）----
        if [ -f "$d/.boot" ]; then
            bi="$(sed -n 's/^boot_index=//p' "$d/.boot" | head -1)"
            bm="$(sed -n 's/^boot_a_md5=//p' "$d/.boot" | head -1)"
            bid="$(sed -n 's/^boot_id=//p' "$d/.boot" | head -1)"
            ur="$(sed -n 's/^uname_r=//p' "$d/.boot" | head -1)"
            cap="$(sed -n 's/^captured=//p' "$d/.boot" | head -1)"
            echo "[内核]（本段建段时快照，非归档时读数）"
            echo "uname_r      = $ur"
            echo "boot_index   = $bi"
            echo "boot_a_md5   = $bm"
            echo "boot_id      = $bid"
            echo "captured_at  = $cap"
            # 归档时若已跨重启，标注出来
            cur_bi="$(grep -oE 'boot_index=[0-9]+' /proc/cmdline 2>/dev/null | head -1 | cut -d= -f2)"
            if [ -n "$cur_bi" ] && [ "$cur_bi" != "$bi" ]; then
                echo "note         = 本段跨重启：建段 boot_index=$bi，归档时=$cur_bi"
            fi
        else
            echo "[内核]（无建段快照 .boot，为归档时现读）"
            echo "uname_r      = $(uname -r)"
            echo "boot_index   = $(grep -oE 'boot_index=[0-9]+' /proc/cmdline 2>/dev/null | head -1 | cut -d= -f2)"
            echo "boot_a_md5   = $(md5sum /dev/block/by-name/boot_a 2>/dev/null | cut -d' ' -f1)"
        fi
        echo "kernel_ours  = $(rec_kernel_is_ours 2>/dev/null && echo yes || echo no)"
        echo
        echo "[设备]"
        r1 /proc/sys/kernel/osrelease; echo "osrelease    = $REPLY"
        echo "device       = $(getprop ro.product.device 2>/dev/null)"
        echo "rom          = $(getprop ro.build.display.id 2>/dev/null)"
        echo "android      = $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
        echo
        echo "[MK-Addon 参数（生效值）]"
        echo "conf_path    = ${CONF:-/data/adb/mk-addon/config.conf}"
        for k in MASTER_ENABLE KERNEL_GUARD GUARD_COLLECT_ON_FOREIGN \
                 ZRAM_ENABLE ZRAM_ALGO ZRAM_DISKSIZE_GB \
                 XSWAPD_ENABLE MCTRL_COMP_RATIO MCTRL_WB_RATIO \
                 SWAPPINESS VFS_CACHE_PRESSURE COMPACTION_PROACTIVENESS \
                 WATERMARK_BOOST_FACTOR EXTFRAG_THRESHOLD DIRTY_RATIO \
                 IO_SCHEDULER READ_AHEAD_KB \
                 NET_TUNE TCP_CC WALT_TUNE WALT_SCHED_LIB \
                 CPUSET_TUNE CPUSET_BACKGROUND_CPUS \
                 RECORDER_ENABLE RECORDER_INTERVAL RECORDER_NICE; do
            eval "v=\${$k}"
            [ -z "$v" ] && v="$(_mcfg "$k")"
            echo "$k = $v"
        done
        echo
        echo "[记录仪]（游戏名单：主名单 + 用户追加）"
        echo "GAME_LIST    = $(rec_cfg RECORDER_GAME_LIST "$REC_GAMES_DEFAULT")"
        _ex="$(rec_cfg_all RECORDER_GAME_EXTRA | tr '\n' ',' | sed 's/,$//')"
        echo "GAME_EXTRA   = ${_ex:-(空)}"
        echo "GAME_EXTRA_N = $(rec_cfg_all RECORDER_GAME_EXTRA | grep -c .)"
        echo "GAME_CHECK_SEC = $(rec_cfg RECORDER_GAME_CHECK_SEC 180)"
        echo "MIN_ROWS     = $(rec_cfg RECORDER_MIN_ROWS 3)"
        echo "ARCH_DIR     = $(rec_cfg RECORDER_ARCH_DIR /storage/emulated/0/Operit\\ AI/小米17/6.12内核/内核日常记录)"
        echo
        echo "[运行态实测]"
        r1 /sys/block/zram0/comp_algorithm; echo "zram_algo    = $REPLY"
        r1 /sys/kernel/mi_sched/enable;     echo "mi_sched_enable = $REPLY"
        r1 /sys/kernel/mi_sched/state;      echo "mi_sched_state  = $REPLY"
        r1 /sys/kernel/sched_ext/state;     echo "sched_ext_state = $REPLY"
        rn /proc/sys/vm/swappiness;         echo "vm_swappiness   = $REPLY"
        r1 /proc/sys/net/ipv4/tcp_congestion_control; echo "tcp_cc = $REPLY"
        r1 /proc/sys/walt/sched_lib_name;   echo "walt_sched_lib_name = $REPLY"
        echo
        echo "[其他模块]"
        for m in asoul_affinity_opt bootlog_harvester; do
            if [ -d "/data/adb/modules/$m" ]; then
                echo "$m = $(sed -n 's/^version=//p' /data/adb/modules/$m/module.prop 2>/dev/null | head -1)"
            fi
        done
    } > "$d/meta.txt" 2>/dev/null
}

# ---------- 单次采样 ----------
rec_sample_once() {
    d="$REC_CUR"
    [ -d "$d" ] || return 1

    ts=$(date +%s)

    # --- 电池 ---
    r1 /sys/class/power_supply/battery/current_now;  bi="$REPLY"
    r1 /sys/class/power_supply/battery/voltage_now;  bv="$REPLY"
    r1 /sys/class/power_supply/battery/temp;         bt="$REPLY"
    r1 /sys/class/power_supply/battery/capacity;     bc="$REPLY"

    # --- 内存 / zram ---
    r1 /sys/block/zram0/comp_algorithm
    za="${REPLY##*[}"; za="${za%%]*}"
    r1 /proc/loadavg;    ld="${REPLY%% *}"
    r1 /proc/uptime;     up="${REPLY%%.*}"

    # --- 调度开关 ---
    r1 /sys/kernel/mi_sched/enable;  men="$REPLY"
    r1 /sys/kernel/mi_sched/state;   mst="$REPLY"
    r1 /sys/kernel/sched_ext/state;  sst="$REPLY"
    r1 /sys/kernel/qos_sched/sched_enable; qs="$REPLY"
    # 该节点格式为 "QS_ENABLE:<TAB>1"，需把冒号与制表符都归一成 '=' 才能进 TSV
    qs="$(printf '%s' "$qs" | tr ':\t' '==')"

    # --- 当前状态 ---
    st="recording"
    [ "$(cat "$REC_STATEF" 2>/dev/null)" = "paused" ] && st="paused"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$st" "$bi" "$bv" "$bt" "$bc" "$za" "$men" "$mst" "$sst" "$qs" "$ld" "$up" \
        >> "$d/samples.tsv"

    # --- 快照（低频：按间隔计数的每 5 次写一次，减少 IO）---
    n=$(cat "$REC_DIR/.cnt" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$REC_DIR/.cnt"
    if [ $((n % 5)) = 1 ]; then
        rall /sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state; echo "$REPLY" > "$d/tis-policy0.tsv"
        rall /sys/devices/system/cpu/cpufreq/policy6/stats/time_in_state; echo "$REPLY" > "$d/tis-policy6.tsv"
        r1 /sys/block/zram0/mm_stat;  echo "$REPLY" > "$d/zram-mm.tsv"
        r1 /dev/memcg/memory.xswapd.stat; echo "$REPLY" > "$d/xswapd.tsv"
    fi
}

# ---------- 段管理 ----------
# 捕获「本段所属内核」的身份快照（B1 修复，1.2.1）
# 背景：段可能跨重启延续（如 21:32 建段 → 21:47 重启 → 23:31 归档）。
#       若归档时才现读内核身份，会把「重启后」的 boot_index 写成整段的归属，
#       导致记录归属错误（违反「取证归属判定」原则）。
#       因此建段时就把身份固化到 .boot，meta 优先取它。
rec_capture_boot_id() {
    printf 'uname_r=%s\nboot_index=%s\nboot_a_md5=%s\nboot_id=%s\ncaptured=%s\n' \
        "$(uname -r 2>/dev/null)" \
        "$(grep -oE 'boot_index=[0-9]+' /proc/cmdline 2>/dev/null | head -1 | cut -d= -f2)" \
        "$(md5sum /dev/block/by-name/boot_a 2>/dev/null | cut -d' ' -f1)" \
        "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" \
        "$(date '+%Y-%m-%d %H:%M:%S')"
}

# 读取段目录记录的内核身份；无 .boot 时回落到现读
rec_seg_boot_id() {
    d="$1"
    if [ -f "$d/.boot" ]; then
        sed -n 's/^boot_index=//p' "$d/.boot" 2>/dev/null | head -1
    else
        grep -oE 'boot_index=[0-9]+' /proc/cmdline 2>/dev/null | head -1 | cut -d= -f2
    fi
}

rec_new_segment() {
    ts0=$(date '+%Y%m%d-%H%M%S')
    rm -rf "$REC_CUR" 2>/dev/null
    mkdir -p "$REC_CUR" 2>/dev/null
    echo "$ts0" > "$REC_CUR/.start"
    # ★ B1：固化本段的内核身份（跨重启时 meta 仍写「建段时」的归属）
    rec_capture_boot_id > "$REC_CUR/.boot" 2>/dev/null
    printf 'ts\tstate\tcur_uA\tvolt_uV\ttemp\tcapacity\tzram_algo\tmi_en\tmi_state\tscx\tqos\tload1\tuptime\n' \
        > "$REC_CUR/samples.tsv"
    echo 0 > "$REC_DIR/.cnt"
    rec_log "new segment started: $ts0 (boot_index=$(sed -n 's/^boot_index=//p' "$REC_CUR/.boot" 2>/dev/null))"
}

# 把当前段「结束」并移入 segments/（返回段名）
# B3 修复（1.2.1）：样本数 < RECORDER_MIN_ROWS（默认 3）视为脏段，直接丢弃不入库
rec_end_segment() {
    [ -d "$REC_CUR" ] || return 1
    [ -s "$REC_CUR/samples.tsv" ] || { rm -rf "$REC_CUR"; return 1; }
    rows=$(( $(wc -l < "$REC_CUR/samples.tsv" 2>/dev/null) - 1 ))
    minrows="${RECORDER_MIN_ROWS:-3}"
    case "$minrows" in ''|*[!0-9]*) minrows=3 ;; esac
    if [ "$rows" -lt "$minrows" ]; then
        rec_log "segment discarded: $rows row(s) < min $minrows (dirty/deploy residue)"
        rm -rf "$REC_CUR" 2>/dev/null
        return 1
    fi
    ts0=$(cat "$REC_CUR/.start" 2>/dev/null || echo "unknown")
    ts1=$(date '+%Y%m%d-%H%M%S')
    # 若起止秒相同（同秒结束），加序号后缀避免 X_to_X 重名
    [ "$ts1" = "$ts0" ] && ts1="${ts0}s"
    name="${ts0}_to_${ts1}"
    d="$REC_SEGS/$name"
    mkdir -p "$REC_SEGS" 2>/dev/null
    rm -rf "$d" 2>/dev/null
    mv "$REC_CUR" "$d" 2>/dev/null || return 1
    echo "$name" > "$REC_DIR/.last_seg"
    rec_log "segment ended: $name ($(wc -l < "$d/samples.tsv" 2>/dev/null) rows)"
    echo "$name"
}

# ---------- 归档 ----------
# 把 segments/ 下所有未归档段复制到工作区（文件直接复制，不摘取）
rec_archive() {
    [ -d "$REC_SEGS" ] || { rec_log "archive: no segments dir"; return 1; }
    mkdir -p "$REC_ARCH" 2>/dev/null
    n=0
    for d in "$REC_SEGS"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        tgt="$REC_ARCH/$name"
        if [ -d "$tgt" ]; then
            rec_log "archive: skip $name (already archived)"
            continue
        fi
        # 补一份 meta（含内核版本 + 参数）
        rec_write_meta "$d"
        mkdir -p "$tgt" 2>/dev/null
        cp -rf "$d/." "$tgt/" 2>/dev/null
        if [ -f "$tgt/samples.tsv" ]; then
            n=$((n + 1))
            rec_log "archived: $name -> $tgt"
        else
            rec_log "archive FAILED: $name"
        fi
    done
    rec_update_readme
    rec_log "archive done: $n segment(s)"
    echo "$n"
}

# 更新归档目录的 README（索引 + 格式说明）
rec_update_readme() {
    r="$REC_ARCH/README.md"
    {
        echo "# 内核日常记录"
        echo
        echo "> MK-Addon 记录仪自动生成。**每段 = 一次「非充电、非游戏」时段**。"
        echo "> 触发方式：插上充电器时，把刚结束的那段归档到这里；拔下充电器后开始新的一段。"
        echo
        echo "## 段清单"
        echo
        echo "| 段目录 | 样本数 | 时长 | 起始电量→结束 | boot_index | 内核 |"
        echo "|---|---|---|---|---|---|"
        for d in "$REC_ARCH"/*/; do
            [ -d "$d" ] || continue
            b="$(basename "$d")"
            [ -f "$d/samples.tsv" ] || continue
            rows=$(( $(wc -l < "$d/samples.tsv" 2>/dev/null) - 1 ))
            first=$(sed -n '2p' "$d/samples.tsv" 2>/dev/null | cut -f6)
            last=$(tail -1 "$d/samples.tsv" 2>/dev/null | cut -f6)
            kr=$(sed -n 's/^uname_r *= *//p' "$d/meta.txt" 2>/dev/null | head -1)
            # B1：优先取建段快照的 boot_index
            if [ -f "$d/.boot" ]; then
                bi="$(sed -n 's/^boot_index=//p' "$d/.boot" 2>/dev/null | head -1)"
            else
                bi="$(sed -n 's/^boot_index *= *//p' "$d/meta.txt" 2>/dev/null | head -1)"
            fi
            [ -z "$bi" ] && bi="-"
            echo "| $b | $rows | $((rows * ${RECORDER_INTERVAL:-60} ))s | ${first}%→${last}% | $bi | $kr |"
        done
        echo
        echo "## 每段内容"
        echo
        echo '```'
        echo "<段目录>/"
        echo "  meta.txt            内核版本 + 全部 MK-Addon 参数（自动生成）"
        echo "  .boot               建段时的内核身份快照（boot_index/md5/boot_id）"
        echo "  samples.tsv         采样数据（TSV，13 列）"
        echo "  tis-policy0.tsv     小核频率驻留快照"
        echo "  tis-policy6.tsv     大核频率驻留快照"
        echo "  zram-mm.tsv         zram 压缩统计快照"
        echo "  xswapd.tsv          内存回写统计快照"
        echo '```'
        echo
        echo "## samples.tsv 列说明"
        echo
        echo "| # | 列 | 说明 |"
        echo "|---|---|---|"
        echo "| 1 | ts | epoch 秒 |"
        echo "| 2 | state | recording / paused |"
        echo "| 3 | cur_uA | 电池电流（µA） |"
        echo "| 4 | volt_uV | 电池电压（µV） |"
        echo "| 5 | temp | 电池温度（0.1°C） |"
        echo "| 6 | capacity | 电量 % |"
        echo "| 7 | zram_algo | 当前压缩算法 |"
        echo "| 8 | mi_en | mi_sched enable |"
        echo "| 9 | mi_state | mi_sched state |"
        echo "| 10 | scx | sched_ext state |"
        echo "| 11 | qos | qos_sched enable |"
        echo "| 12 | load1 | 1 分钟负载 |"
        echo "| 13 | uptime | 开机秒数 |"
        echo
        echo "---"
        echo
        echo "*由 MK-Addon lib/recorder.sh 自动生成。请勿手工编辑。*"
    } > "$r" 2>/dev/null
}

# 本地段数上限保护
rec_prune_segments() {
    keep="${1:-20}"
    cnt=$(ls -d "$REC_SEGS"/*/ 2>/dev/null | wc -l)
    [ "$cnt" -le "$keep" ] && return 0
    ls -1dt "$REC_SEGS"/*/ 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r d; do
        rm -rf "$d" 2>/dev/null && rec_log "pruned old segment: $(basename "$d")"
    done
}

# ---------- 主循环 ----------
rec_loop() {
    interval="${1:-60}"
    echo $$ > "$REC_PIDF"
    trap 'rm -f "$REC_PIDF"; exit 0' TERM INT HUP

    # 游戏检测周期（秒），默认 180 = 3 分钟。
    # 1.2.2 起由「每 5 轮（=5×interval）」改为「按秒计」，与 interval 解耦。
    # 原因（2026-10-11 实测）：2~3 分钟的短游戏会整段落在两次检测之间 → 零命中。
    #   实例：sgame usedByUser=+3m49s，段结束 00:00:38，22 条样本全为 recording。
    # 开销实测：dumpsys activity activities = 12 ms；180s 一次 = 0.007% CPU。
    gchk="$(rec_cfg RECORDER_GAME_CHECK_SEC 180)"
    case "$gchk" in ''|*[!0-9]*) gchk=180 ;; esac
    [ "$gchk" -lt 30 ] && gchk=30
    game_next=0        # 0 = 首轮立即检测

    while [ -f "$REC_PIDF" ]; do
        # ---- 守卫：非我方内核 → 停止工作 ----
        if ! rec_kernel_is_ours 2>/dev/null; then
            echo "foreign" > "$REC_STATEF"
            rec_log "guard: foreign kernel -> recorder idle"
            rm -f "$REC_PIDF"
            exit 0
        fi

        # ---- 充电检测（每次循环都查，开销极低）----
        if rec_is_charging; then
            prev="$(cat "$REC_STATEF" 2>/dev/null)"
            if [ "$prev" != "charging" ]; then
                echo "charging" > "$REC_STATEF"
                rec_log "state: -> charging (归档刚结束的段)"
                rec_end_segment >/dev/null
                rec_archive >/dev/null
                rec_prune_segments "${RECORDER_KEEP_SEG:-20}"
            fi
            # 充电中：不采样，只等待
            sleep 30
            continue
        fi

        # ---- 非充电 ----
        if [ "$(cat "$REC_STATEF" 2>/dev/null)" = "charging" ] || [ ! -d "$REC_CUR" ]; then
            echo "recording" > "$REC_STATEF"
            rec_new_segment
        fi

        # ---- 游戏检测（按秒计周期，默认每 180s 一次）----
        now=$(date +%s)
        if [ "$now" -ge "$game_next" ]; then
            game_next=$((now + gchk))
            if rec_is_game; then
                echo "paused" > "$REC_STATEF"
                rec_log "state: -> paused (game foreground)"
            else
                [ "$(cat "$REC_STATEF" 2>/dev/null)" = "paused" ] && {
                    echo "recording" > "$REC_STATEF"
                    rec_log "state: -> recording (game left)"
                }
            fi
        fi

        # ---- 采样（paused 时跳过，但仍继续循环以便恢复）----
        if [ "$(cat "$REC_STATEF" 2>/dev/null)" != "paused" ]; then
            rec_sample_once
        fi

        # ---- 低功耗等待：1s 小步轮询，便于及时响应停止/状态变化 ----
        i=0
        while [ $i -lt "$interval" ]; do
            [ -f "$REC_PIDF" ] || { rm -f "$REC_PIDF"; exit 0; }
            sleep 1
            i=$((i + 1))
        done
    done
    rm -f "$REC_PIDF"
}

# ---------- 进程存活判定（B2 修复，1.2.1）----------
# 背景：仅看 `/proc/$pid` 是否存在不够 —— 重启后 pid 文件仍在，
#       若该 pid 被别的进程复用，会误判「记录仪已在运行」而静默不自启。
#       因此必须校验该 pid 的 cmdline 里确实是我们的 recorder.sh。
rec_read_pid() {
    [ -f "$REC_PIDF" ] || return 1
    p="$(cat "$REC_PIDF" 2>/dev/null)"
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$p" ] || return 1
    # cmdline 以 NUL 分隔；tr 成空格后匹配脚本路径
    cl="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    case "$cl" in
        *recorder.sh*) echo "$p"; return 0 ;;
    esac
    return 1
}

rec_is_running() {
    rec_read_pid >/dev/null 2>&1
}

# ---------- 控制入口 ----------
recorder_ctl() {
    cmd="${1:-status}"
    mkdir -p "$REC_DIR" "$REC_SEGS" 2>/dev/null

    case "$cmd" in
        _bg)
            rec_loop "${2:-60}"
            ;;
        start)
            # B2：用 cmdline 校验，不能只看 pid 存在
            if rp="$(rec_read_pid)"; then
                echo "recorder already running (pid $rp)"
                return 0
            fi
            rm -f "$REC_PIDF" 2>/dev/null   # 清掉 stale pid 文件
            interval=$(rec_cfg RECORDER_INTERVAL 60)
            # 低功耗：降优先级
            if [ "$(rec_cfg RECORDER_NICE 1)" = "1" ] && command -v nice >/dev/null 2>&1; then
                nohup nice -n 19 ionice -c 3 sh "$MODDIR/lib/recorder.sh" _bg "$interval" \
                    >/dev/null 2>&1 &
            else
                nohup sh "$MODDIR/lib/recorder.sh" _bg "$interval" >/dev/null 2>&1 &
            fi
            echo "recorder started: interval=${interval}s pid=$!"
            rec_log "recorder started: interval=${interval}s pid=$!"
            ;;
        stop)
            rp="$(rec_read_pid 2>/dev/null)"
            if [ -n "$rp" ]; then
                kill "$rp" 2>/dev/null
                sleep 1
                kill -9 "$rp" 2>/dev/null
                rm -f "$REC_PIDF"
                echo "recorder stopped (pid $rp)"
            else
                rm -f "$REC_PIDF" 2>/dev/null
                echo "recorder not running"
            fi
            ;;
        once)
            rec_sample_once && echo "sampled -> $REC_CUR/samples.tsv"
            ;;
        archive)
            rec_end_segment >/dev/null
            echo "archived $(rec_archive) segment(s)"
            ;;
        game)
            # 调试：判定某包名是否在游戏名单里
            g="${2:-}"
            old="$REPLY"
            rec_foreground_pkg
            echo "foreach: $REPLY"
            echo "given:   $g"
            ;;
        chg)
            if rec_is_charging; then echo "charging"; else echo "not charging"; fi
            ;;
        status)
            if rp="$(rec_read_pid 2>/dev/null)"; then
                echo "running (pid $rp)"
            else
                echo "stopped"
            fi
            echo "state:    $(cat "$REC_STATEF" 2>/dev/null || echo -)"
            echo "charging: $(rec_is_charging && echo yes || echo no)"
            echo "kernel:   $(rec_kernel_is_ours 2>/dev/null && echo ours || echo FOREIGN)"
            echo "segment:  $(cat "$REC_CUR/.start" 2>/dev/null || echo none) ($(wc -l < "$REC_CUR/samples.tsv" 2>/dev/null || echo 0) rows)"
            if [ -f "$REC_CUR/.boot" ]; then
                echo "seg_boot: boot_index=$(sed -n 's/^boot_index=//p' "$REC_CUR/.boot" | head -1)"
            fi
            echo "pending:  $(ls -d "$REC_SEGS"/*/ 2>/dev/null | wc -l) segment(s) not archived"
            echo "archived: $(ls -d "$REC_ARCH"/*/ 2>/dev/null | wc -l) segment(s)"
            echo "games:    主名单 $(printf '%s' "$(rec_cfg RECORDER_GAME_LIST "$REC_GAMES_DEFAULT")" | tr ',' '\n' | grep -c .) 项 + 追加 $(rec_cfg_all RECORDER_GAME_EXTRA | grep -c .) 项"
            echo "game_chk: $(rec_cfg RECORDER_GAME_CHECK_SEC 180)s 一次"
            echo "min_rows: $(rec_cfg RECORDER_MIN_ROWS 3)"
            ;;
        *)
            echo "usage: recorder_ctl {start|stop|status|once|archive|game <pkg>|chg}"
            return 1
            ;;
    esac
}

# service.sh 调用入口
recorder_boot_start() {
    if [ "$(rec_cfg RECORDER_ENABLE 0)" != "1" ]; then
        rec_log "recorder: RECORDER_ENABLE != 1 -> skip"
        return 0
    fi
    mkdir -p "$REC_DIR" "$REC_SEGS" 2>/dev/null
    # 开机时若在充电 → 先把上一轮遗留的段归档，再进 charging 态
    if rec_is_charging; then
        echo "charging" > "$REC_STATEF"
        rec_end_segment >/dev/null
        rec_archive >/dev/null
    fi
    rec_log "recorder: $(recorder_ctl start)"
}

# ---- 顶层 dispatch（nohup 后台子进程用）----
case "$1" in
    _bg) rec_loop "${2:-60}" ;;
esac