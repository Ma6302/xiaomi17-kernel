#!/system/bin/sh
# =============================================================
# uninstall.sh — MK-Addon 卸载脚本（零残余）
#
# 由 Magisk/KernelSU 在「模块被删除后」自动执行。
# 目标：清掉本模块在系统上产生的一切痕迹，且**不碰**其他模块/系统文件。
#
# 清理清单（依据 2026-10-10 全面调查）：
#   1. 采样器后台进程
#   2. /data/local/mk-data/         （快照 + sampler 数据）
#   3. /data/local/mk-addon.log     （运行日志）
#   4. /data/local/mk-sampler/      （早期独立采样器残留）
#
# 保留（重要）：
#   /data/adb/mk-addon/config.conf  ← 用户配置【默认保留】
#     理由：用户可能只是「先卸载、稍后重装」，配置不该丢。
#     若要彻底删除（真正零残余），设 KEEP_CONFIG=0。
# =============================================================

LOG=/data/local/mk-addon-uninstall.log
KEEP_CONFIG="${KEEP_CONFIG:-1}"
MODDIR="${0%/*}"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

echo "=== MK-Addon uninstall start $(date) ===" >> "$LOG"

# ---------- 1. 停采样器 ----------
# 注意：采样器主循环在 `sleep $INTERVAL` 中，SIGTERM 可能被 sleep 吞掉或延迟生效，
# 因此必须用 SIGKILL(-9) 并做二次确认。实测（2026-10-10）SIGTERM 会留下残余进程。
kill_sampler() {
    for pat in 'mk-addon/lib/sampler.sh' 'sampler.sh _bg'; do
        for p in $(pgrep -f "$pat" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            kill -9 "$p" 2>/dev/null && log "killed sampler pid=$p (SIGKILL, pat=$pat)"
        done
    done
}

# pid 文件优先（最精确）
PIDF=/data/local/mk-data/sampler/sampler.pid
if [ -f "$PIDF" ]; then
    pid="$(cat "$PIDF" 2>/dev/null)"
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null && log "killed sampler pid=$pid (from pidfile)"
fi
kill_sampler
sleep 1
# 二次确认：仍存在则再杀一轮
kill_sampler
sleep 1

# ---------- 1b. 停记录仪 ----------
RECPIDF=/data/local/mk-rec/recorder.pid
if [ -f "$RECPIDF" ]; then
    rpid="$(cat "$RECPIDF" 2>/dev/null)"
    [ -n "$rpid" ] && kill -9 "$rpid" 2>/dev/null && log "killed recorder pid=$rpid (from pidfile)"
fi
for p in $(pgrep -f 'mk-addon/lib/recorder.sh' 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    kill -9 "$p" 2>/dev/null && log "killed recorder pid=$p (SIGKILL)"
done

# ---------- 2. 数据目录 ----------
if [ -d /data/local/mk-data ]; then
    rm -rf /data/local/mk-data 2>/dev/null \
        && log "removed /data/local/mk-data" \
        || log "FAIL removing /data/local/mk-data"
fi

# ---------- 2b. 日常记录仪数据 ----------
# 注意：记录仪也会把段归档到工作区（sdcard），那里是**用户可见的数据**，
#      卸载时【不删除】（与配置同理：用户可能只是想重装）。
if [ -d /data/local/mk-rec ]; then
    rm -rf /data/local/mk-rec 2>/dev/null \
        && log "removed /data/local/mk-rec" \
        || log "FAIL removing /data/local/mk-rec"
fi

# ---------- 3. 早期独立采样器残留 ----------
if [ -d /data/local/mk-sampler ]; then
    rm -rf /data/local/mk-sampler 2>/dev/null \
        && log "removed /data/local/mk-sampler" \
        || log "FAIL removing /data/local/mk-sampler"
fi

# ---------- 4. 日志 ----------
[ -f /data/local/mk-addon.log ] && rm -f /data/local/mk-addon.log 2>/dev/null && log "removed mk-addon.log"

# ---------- 5. 配置（默认保留）----------
if [ "$KEEP_CONFIG" = "1" ]; then
    if [ -f /data/adb/mk-addon/config.conf ]; then
        log "KEPT config: /data/adb/mk-addon/config.conf"
        # 留一个说明文件，防止用户困惑
        cat > /data/adb/mk-addon/README-已卸载.txt <<'EOF'
MK-Addon 模块已卸载。

此目录保留了你的配置文件 config.conf：
  - 重新安装 MK-Addon 时会自动沿用（开关设置不丢）
  - 若要彻底清除全部残余，删除本目录即可：
      rm -rf /data/adb/mk-addon

模块产生的运行时数据（/data/local/mk-data、mk-addon.log 等）已全部清理。
EOF
    fi
else
    rm -rf /data/adb/mk-addon 2>/dev/null && log "removed /data/adb/mk-addon (KEEP_CONFIG=0)"
fi

# ---------- 6. 验证 ----------
{
    echo "--- 残余检查 ---"
    for p in /data/local/mk-data /data/local/mk-sampler /data/local/mk-addon.log; do
        [ -e "$p" ] && echo "  STILL EXISTS: $p" || echo "  clean: $p"
    done
    if [ "$KEEP_CONFIG" = "1" ]; then
        [ -f /data/adb/mk-addon/config.conf ] && echo "  kept: /data/adb/mk-addon/config.conf (by design)" || echo "  no config to keep"
    fi
    echo "--- 残余进程 ---"
    # 排除自身与本次诊断的子 shell（$$ 及其子进程会匹配到自己）
    mypid=$$
    resid=0
    for p in $(pgrep -f 'mk-addon/lib/sampler.sh' 2>/dev/null); do
        [ "$p" = "$mypid" ] && continue
        echo "  STILL RUNNING: pid=$p"
        resid=1
    done
    [ "$resid" = "0" ] && echo "  clean: 无残余进程"
} >> "$LOG" 2>&1

echo "=== MK-Addon uninstall done ===" >> "$LOG"

# 卸载后把日志也搬走（在 /data/adb 之外留一份给用户看，可选）
# 这里直接把日志留在原位，便于排查；如需可手动删。
exit 0