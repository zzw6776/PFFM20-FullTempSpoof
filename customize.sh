#!/system/bin/sh

ui_print "*******************************"
ui_print " PFFM20 Full Temperature Spoof "
ui_print "*******************************"
ui_print "默认配置基于 PFFM20 / MT6983 / Android 12 / 5.10.66"
ui_print "安装和启动均不校验机型、Android 版本或内核版本"
ui_print "跨设备使用时：不支持的节点/服务会跳过，详情看 module.log"
ui_print "默认分类伪装匹配到的 thermal zone"
ui_print "不会修改 XML、thermal.conf、CPU频率或cooling device"
ui_print "配置文件：config.conf"
ui_print "警告：依赖内核 soc_max 116.5°C 最终保护，属于激进配置"

load_install_config() {
    EXPECTED_MIN_THERMAL_ZONES=51
    POWER_SUPPLY_BATTERY_ENABLE=1
    CHARGER_ENABLE=1
    PROC_SHELL_TEMP_ENABLE=1
    HORAE_MODE=stop
    VENDOR_THERMAL_HAL_MODE=restart
    THERMAL_CORE_MODE=keep
    [ -r "$MODPATH/config.conf" ] && . "$MODPATH/config.conf"
}

install_context_supported() {
    case "$1" in
        u:object_r:sysfs_therm:s0|u:object_r:sysfs_battery_supply:s0|u:object_r:sysfs_batteryinfo:s0) return 0 ;;
        *) return 1 ;;
    esac
}

install_print_skip() {
    INSTALL_SKIP_COUNT=$((INSTALL_SKIP_COUNT + 1))
    ui_print "  - $*"
}

install_check_file_target() {
    local path="$1" label="$2" context real
    [ -e "$path" ] || {
        install_print_skip "$label：节点不存在 ($path)"
        return 0
    }
    real="$(readlink -f "$path" 2>/dev/null)"
    [ -n "$real" ] || real="$path"
    context="$(ls -Zd "$real" 2>/dev/null | awk '{print $1}')"
    install_context_supported "$context" || \
        install_print_skip "$label：SELinux 标签未适配 (${context:-unknown})"
}

install_check_service() {
    local service="$1" label="$2" state
    state="$(getprop init.svc."$service" 2>/dev/null)"
    [ -n "$state" ] || install_print_skip "$label：服务不存在 ($service)"
}

install_preflight() {
    local zone count=0 unsupported=0 context type real
    INSTALL_SKIP_COUNT=0
    load_install_config

    ui_print "安装预检查："
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/temp" ] || continue
        count=$((count + 1))
        real="$(readlink -f "$zone/temp" 2>/dev/null)"
        [ -n "$real" ] || real="$zone/temp"
        context="$(ls -Zd "$real" 2>/dev/null | awk '{print $1}')"
        if ! install_context_supported "$context"; then
            unsupported=$((unsupported + 1))
            if [ "$unsupported" -le 5 ]; then
                type="$(cat "$zone/type" 2>/dev/null | tr -d '\r\n')"
                install_print_skip "${zone##*/} ${type:-unknown}：SELinux 标签未适配 (${context:-unknown})"
            fi
        fi
    done
    if [ "$count" -eq 0 ]; then
        install_print_skip "thermal zone：安装环境当前未发现 /sys/class/thermal/thermal_zone*/temp"
    elif [ "$count" -lt "$EXPECTED_MIN_THERMAL_ZONES" ]; then
        install_print_skip "thermal zone 数量少于配置：当前 $count，配置 $EXPECTED_MIN_THERMAL_ZONES；运行时会按已发现节点继续"
    fi
    [ "$unsupported" -gt 5 ] && install_print_skip "另有 $((unsupported - 5)) 个 thermal zone 标签未适配，详见运行日志"

    if [ "$POWER_SUPPLY_BATTERY_ENABLE" = 1 ]; then
        install_check_file_target /sys/class/power_supply/battery/temp "power_supply battery/temp"
        install_check_file_target /sys/class/power_supply/mtk-battery/temp "power_supply mtk-battery/temp"
        install_check_file_target /sys/class/power_supply/mtk-battery/temperature "power_supply mtk-battery/temperature"
    fi

    if [ "$CHARGER_ENABLE" = 1 ]; then
        install_check_file_target /sys/class/power_supply/mtk-master-charger/temp "power_supply mtk-master-charger/temp"
        install_check_file_target /sys/class/power_supply/mtk-mst-div-charger/temp "power_supply mtk-mst-div-charger/temp"
        install_check_file_target /sys/class/power_supply/mtk-slave-charger/temp "power_supply mtk-slave-charger/temp"
        install_check_file_target /sys/class/power_supply/mtk-slv-div-charger/temp "power_supply mtk-slv-div-charger/temp"
    fi

    if [ "$PROC_SHELL_TEMP_ENABLE" = 1 ] && [ ! -w /proc/shell-temp ]; then
        install_print_skip "/proc/shell-temp：不存在或不可写"
    fi

    [ "$HORAE_MODE" = stop ] && install_check_service horae "Horae"
    case "$VENDOR_THERMAL_HAL_MODE" in
        stop|restart) install_check_service vendor.thermal-hal-2-0.mtk "MTK Vendor Thermal HAL" ;;
    esac
    [ "$THERMAL_CORE_MODE" = stop ] && install_check_service thermal_core "thermal_core"

    if [ "$INSTALL_SKIP_COUNT" -eq 0 ]; then
        ui_print "  未发现预计跳过项"
    else
        ui_print "  以上项目安装后运行时会跳过；最终结果以 module.log 为准"
    fi
}

install_preflight

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0755
set_perm "$MODPATH/config.conf" 0 0 0644
