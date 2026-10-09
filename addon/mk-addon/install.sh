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

on_install() {
  ui_print "- 安装 MK-Addon 模块"
  unzip -o "$ZIPFILE" 'lib/*' -d "$MODPATH" >&2
  unzip -o -j "$ZIPFILE" config.conf module.prop apply.sh service.sh collect.sh -d "$MODPATH" >&2
  ui_print "- 配置文件: \$MODPATH/config.conf"
  ui_print "- 改完重启或执行 apply.sh 生效"
}

set_permissions() {
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/apply.sh"   0 0 0755
  set_perm "$MODPATH/collect.sh" 0 0 0755
  set_perm "$MODPATH/lib/common.sh" 0 0 0644
  set_perm "$MODPATH/lib/tune.sh"   0 0 0644
  set_perm "$MODPATH/lib/zram.sh"   0 0 0644
}