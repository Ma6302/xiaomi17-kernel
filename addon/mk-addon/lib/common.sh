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