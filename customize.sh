#!/system/bin/sh

ui_print "*******************************"
ui_print " PFFM20 Full Temperature Spoof "
ui_print "*******************************"
ui_print "仅支持 PFFM20 / MT6983 / Android 12 / 5.10.66"
ui_print "默认分类伪装全部 thermal zone"
ui_print "不会修改 XML、thermal.conf、CPU频率或cooling device"
ui_print "配置文件：config.conf"
ui_print "警告：依赖内核 soc_max 116.5°C 最终保护，属于激进配置"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/config.conf" 0 0 0644

