#!/system/bin/sh
# lib/common.sh - shared helpers for MK-Addon

MODDIR="${MODDIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}"
LOG="${LOG:-/data/local/mk-addon.log}"
CONF="${CONF:-$MODDIR/config.conf}"

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