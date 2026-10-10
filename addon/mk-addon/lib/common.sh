#!/system/bin/sh
# lib/common.sh - shared helpers for MK-Addon

MODDIR="${MODDIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}"
LOG="${LOG:-/data/local/mk-addon.log}"

# ---------- 配置来源（方案C：外部持久路径，刷机不丢）----------
# 优先级：
#   1. 环境变量 CONF（测试/高级用法）
#   2. /data/adb/mk-addon/config.conf  （用户配置，**持久**，刷机/重装模块都不覆盖）
#   3. $MODDIR/config.conf             （包内默认，仅首次安装时用作种子）
#
# 为什么这样设计：
#   旧版 config.conf 在模块目录内，刷 AK3 时 ksud module install 会用
#   包内默认值 unzip -o 覆盖，导致用户开关被重置（2026-10-10 二次事故）。
#   把「用户配置」放到 /data/adb/mk-addon/ 后，刷机彻底不影响它。
EXT_CONF="/data/adb/mk-addon/config.conf"

# 选定生效配置：外部优先，回退包内
if [ -n "$CONF" ]; then
    :                                   # 环境变量显式指定，尊重之
elif [ -f "$EXT_CONF" ]; then
    CONF="$EXT_CONF"
else
    CONF="$MODDIR/config.conf"
fi

# 首次运行时，把包内默认配置播种到外部持久路径
seed_conf() {
    [ -f "$EXT_CONF" ] && return 0
    [ -f "$MODDIR/config.conf" ] || return 1
    mkdir -p "$(dirname "$EXT_CONF")" 2>/dev/null
    cp -f "$MODDIR/config.conf" "$EXT_CONF" 2>/dev/null && {
        log "conf: seeded $EXT_CONF (from module default)"
        CONF="$EXT_CONF"
        return 0
    }
    return 1
}

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# load config as KEY=VALUE (skip comments/blank)
load_conf() {
    [ -f "$CONF" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        # trim CR / trailing spaces / trailing comments after value
        val="${val%$'\r'}"
        case "$key" in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        eval "$key=\$val"
    done < "$CONF"
}

# cfg_get KEY DEFAULT
cfg_get() {
    k="$1"; d="$2"
    eval "v=\${$k}"
    [ -z "$v" ] && v="$d"
    echo "$v"
}

# write_val VALUE GLOB_PATHS...  (only writes if path exists; logs old+new)
write_val() {
    val="$1"; shift
    for pat in "$@"; do
        for f in $pat; do
            [ -f "$f" ] || continue
            [ -w "$f" ] || { log "  RO skip $f"; continue; }
            old="$(cat "$f" 2>/dev/null)"
            echo "$val" > "$f" 2>/dev/null && log "  set $f : '$old' -> '$val'" \
                                         || log "  FAIL $f (val=$val)"
        done
    done
}

# write_val_forcedir VALUE DIR FILENAMES...  (find files under dir)
write_val_in_path() {
    val="$1"; dir="$2"; shift 2
    if [ "$#" = "1" ]; then
        find "$dir" -name "$1" -type f 2>/dev/null | while read -r f; do
            write_val "$val" "$f"
        done
    else
        find "$dir" -path "*$1*" -name "$2" -type f 2>/dev/null | while read -r f; do
            write_val "$val" "$f"
        done
    fi
}

# node_read PATH  -> value or "-"
node_read() {
    [ -f "$1" ] && cat "$1" 2>/dev/null || echo "-"
}

# ---------- kernel identity guard ----------
# 目的：刷回原厂/别家内核后，本模块必须【自动停止工作】，
#       不能继续改 VM/IO 参数或切换 zram 压缩算法。
kernel_release() {
    uname -r 2>/dev/null
}

# 运行内核是否为本项目构建的内核（署名匹配）
# 返回 0 = 是（或未配置 tag，不拦截）；1 = 不是
kernel_is_ours() {
    want="$(cfg_get EXPECTED_KERNEL_TAG Ma6302)"
    [ -z "$want" ] && return 0
    rel="$(kernel_release)"
    [ -z "$rel" ] && return 1
    case "$rel" in
        *"$want"*) return 0 ;;
    esac
    return 1
}

# 守卫总检查；返回 0 = 允许继续，1 = 应停止
# GUARD_FORCE=1 可强制跳过（仅 apply.sh --force 使用）
guard_check() {
    [ "$GUARD_FORCE" = "1" ] && { log "GUARD: forced (GUARD_FORCE=1)"; return 0; }
    [ "$(cfg_get KERNEL_GUARD 1)" = "1" ] || { log "GUARD: disabled in config"; return 0; }
    if kernel_is_ours; then
        log "GUARD: kernel OK ($(kernel_release))"
        return 0
    fi
    log "GUARD: 运行内核不是本项目内核 —— 停止一切调参/切换"
    log "GUARD:   running = $(kernel_release)"
    log "GUARD:   expect  = *$(cfg_get EXPECTED_KERNEL_TAG Ma6302)*"
    return 1
}