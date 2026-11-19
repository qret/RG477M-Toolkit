#!/system/bin/sh
model=$(getprop ro.product.model)
ui_print "- Device model: $model"
if [ "$model" != "RG477M" ]; then
    abort "! This module is strictly for Anbernic RG477M (MT6897)."
fi

ui_print "- Setting executable permissions..."
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/rg477m_perf_daemon.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
