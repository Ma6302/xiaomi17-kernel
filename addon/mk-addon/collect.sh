#!/system/bin/sh
# collect.sh - dump a research snapshot (kernel + zram + mem + mi_sched)
# output: $COLLECT_DIR/snapshot-<ts>.txt

MODDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$MODDIR/lib/common.sh"
load_conf 2>/dev/null

CD="$(cfg_get COLLECT_DIR /data/local/mk-data)"
KEEP="$(cfg_get KEEP_SNAPSHOTS 60)"
mkdir -p "$CD" 2>/dev/null

TS="$(date '+%Y%m%d-%H%M%S')"
OUT="$CD/snapshot-$TS.txt"

{
  echo "############################################################"
  echo "# MK-Addon snapshot  $TS"
  echo "# device: $(getprop ro.product.device) / $(getprop ro.product.board)"
  echo "############################################################"

  echo; echo "== 1. kernel =="
  uname -a
  echo "--- /proc/version ---"
  cat /proc/version 2>/dev/null
  echo "--- boot_id / uptime ---"
  cat /proc/sys/kernel/random/boot_id 2>/dev/null
  cat /proc/uptime 2>/dev/null

  echo; echo "== 2. modules =="
  echo "loaded module count: $(lsmod 2>/dev/null | wc -l)"
  echo "KernelSU present: $(grep -cE 'kernelsu|KernelSU' /proc/modules 2>/dev/null)"
  echo "zram module: $(grep -w zram /proc/modules 2>/dev/null | head -1)"
  echo "zsmalloc: $(grep -w zsmalloc /proc/modules 2>/dev/null | head -1)"

  echo; echo "== 3. ABI key symbols (presence check) =="
  if [ -r /proc/kallsyms ]; then
    for s in kobject_uevent_env crypto_comp_compress crypto_comp_decompress \
             mi_sched_ext_register_krn_ops register_mi_scx_disp_zone \
             mi_get_scx_cpu_masks mqhd_select_cpu; do
      if grep -qw "$s" /proc/kallsyms 2>/dev/null; then
        echo "  $s: present"
      else
        echo "  $s: ABSENT"
      fi
    done
  else
    echo "  /proc/kallsyms not readable"
  fi

  echo; echo "== 4. zram =="
  echo "--- /sys/block/zram0/comp_algorithm ---"
  cat /sys/block/zram0/comp_algorithm 2>/dev/null
  echo "--- disksize ---";      cat /sys/block/zram0/disksize 2>/dev/null
  echo "--- mem_limit ---";     cat /sys/block/zram0/mem_limit 2>/dev/null
  echo "--- mm_stat ---";       cat /sys/block/zram0/mm_stat 2>/dev/null
  echo "--- zgroup_enable ---"; cat /sys/block/zram0/zgroup_enable 2>/dev/null

  echo; echo "== 5. swap =="
  cat /proc/swaps 2>/dev/null

  echo; echo "== 6. memory =="
  cat /proc/meminfo 2>/dev/null | grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Cached|Buffers'
  echo "--- /proc/pressure/memory ---"
  cat /proc/pressure/memory 2>/dev/null

  echo; echo "== 7. mi_sched / sched_ext =="
  for f in /sys/kernel/sched_ext/*; do
    [ -f "$f" ] || continue
    echo "  $(basename $f) = $(cat $f 2>/dev/null)"
  done
  echo "--- vm.swappiness ---"; cat /proc/sys/vm/swappiness 2>/dev/null

  echo; echo "== 8. Xiaomi zgroup / xswapd / mctrl =="
  for f in /dev/memcg/memory.xswapd.enable /dev/memcg/memory.xswapd.quota \
           /dev/memcg/memory.xswapd.umrenable /dev/memcg/memory.xswapd.stop_swap \
           /dev/memcg/memory.mctrl.level /dev/memcg/memory.mctrl.comp_ratio \
           /dev/memcg/memory.mctrl.wb_ratio; do
    [ -f "$f" ] && echo "  $(basename $f) = $(cat $f 2>/dev/null)"
  done
  echo "--- xswapd.stat ---"
  cat /dev/memcg/memory.xswapd.stat 2>/dev/null

  echo; echo "== 9. config in effect =="
  sed -n 's/^\([A-Z_]*\)=.*/  \1=.../p' "$CONF" 2>/dev/null | head -40
  echo "--- effective values ---"
  for k in ZRAM_ALGO ZRAM_DISKSIZE_GB XSWAPD_ENABLE MCTRL_COMP_RATIO MCTRL_WB_RATIO \
           SWAPPINESS IO_SCHEDULER READ_AHEAD_KB NET_TUNE; do
    eval "v=\${$k}"; echo "  $k=${v:-<unset>}"
  done

  echo; echo "== 10. snapshot end =="
} > "$OUT" 2>&1

# prune old snapshots
n=$(ls -1 "$CD"/snapshot-*.txt 2>/dev/null | wc -l)
if [ "$n" -gt "$KEEP" ]; then
    ls -1t "$CD"/snapshot-*.txt 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
        rm -f "$f"
    done
fi

echo "snapshot written: $OUT"
log "collect: $OUT"