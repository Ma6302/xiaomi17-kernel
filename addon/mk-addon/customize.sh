#!/system/bin/sh
# customize.sh - Magisk-compatible install entry (also works for KernelSU)
# Magisk injects: MODPATH, ZIPFILE, TMPDIR, and helper fns (ui_print, set_perm*)

SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

print_modname() {
  ui_print "*******************************"
  ui_print "  Ma6302 Kernel Addon (MK)"
  ui_print "  参数调节 / zram / 数据收集"
  ui_print " By Ma6302"
  ui_print "*******************************"
}

# 方案C：用户配置放在 /data/adb/mk-addon/config.conf（持久），刷机不覆盖
EXT_CONF="/data/adb/mk-addon/config.conf"

on_install() {
  ui_print "- 安装 MK-Addon 模块"
  unzip -o "$ZIPFILE" 'lib/*' -d "$MODPATH" >&2
  unzip -o -j "$ZIPFILE" config.conf module.prop apply.sh service.sh collect.sh uninstall.sh -d "$MODPATH" >&2

  mkdir -p /data/adb/mk-addon 2>/dev/null
  if [ -f "$EXT_CONF" ]; then
    ui_print "- 保留现有用户配置: $EXT_CONF"
  else
    cp -f "$MODPATH/config.conf" "$EXT_CONF" 2>/dev/null
    ui_print "- 已播种默认配置: $EXT_CONF"
  fi
  ui_print "- 编辑配置: $EXT_CONF"
  ui_print "- 改完重启，或执行 apply.sh 立即生效"
}

set_permissions() {
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/apply.sh"   0 0 0755
  set_perm "$MODPATH/collect.sh" 0 0 0755
  set_perm "$MODPATH/uninstall.sh" 0 0 0755 2>/dev/null
  set_perm "$MODPATH/lib/common.sh" 0 0 0644
  set_perm "$MODPATH/lib/tune.sh"   0 0 0644
  set_perm "$MODPATH/lib/zram.sh"   0 0 0644
  set_perm "$MODPATH/lib/sampler.sh" 0 0 0644
}

# === entry (Magisk runs customize.sh directly) ===
print_modname
on_install
set_permissions
ui_print "- 完成"