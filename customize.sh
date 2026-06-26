#!/system/bin/sh

ui_print "*******************************"
ui_print " PFFM20 Full Temperature Spoof "
ui_print "*******************************"
ui_print "基准设备：PFFM20 / MT6983，当前版本使用动态兼容模式"
ui_print "不限制机型、Android 版本或内核版本；发现什么节点就处理什么节点"
ui_print "运行时按 config.conf 分类伪装 thermal / power_supply 温度读数"
ui_print "不修改 XML、thermal.conf、CPU 频率、cooling device 或 live sepolicy"
ui_print "不支持的节点、标签或服务会自动跳过，并记录到 module.log"
ui_print "配置文件：config.conf；日志目录：/data/adb/pffm20_fulltempspoof"
ui_print "注意：本模块只改变用户空间读数，内核 critical 保护仍由系统负责"

load_install_config() {
    POWER_SUPPLY_BATTERY_ENABLE=1
    CHARGER_ENABLE=1
    PROC_SHELL_TEMP_ENABLE=1
    THERMAL_VALUE_FILTER_ENABLE=1
    THERMAL_VALID_MIN_MILLI_C=10000
    THERMAL_VALID_MAX_MILLI_C=130000
    THERMAL_SERVICES_MODE=stop_then_restart
    [ -r "$MODPATH/config.conf" ] && . "$MODPATH/config.conf"
}

install_context_supported() {
    case "$1" in
        u:object_r:sysfs_therm:s0|\
        u:object_r:sysfs_battery_supply:s0|\
        u:object_r:sysfs_batteryinfo:s0|\
        u:object_r:sysfs_thermal:s0|\
        u:object_r:vendor_sysfs_battery_supply:s0|\
        u:object_r:vendor_sysfs_usb_supply:s0) return 0 ;;
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

install_power_target_enabled() {
    local path="$1" supply
    supply="${path#/sys/class/power_supply/}"
    supply="${supply%%/*}"
    case "$supply" in
        *battery*|*gauge*) [ "$POWER_SUPPLY_BATTERY_ENABLE" = 1 ] ;;
        *) [ "$CHARGER_ENABLE" = 1 ] ;;
    esac
}

install_signed_int() {
    local value="$1" abs
    case "$value" in
        '') return 1 ;;
        -*)
            abs="${value#-}"
            case "$abs" in ''|*[!0-9]*) return 1 ;; esac
            ;;
        *[!0-9]*) return 1 ;;
    esac
    return 0
}

install_valid_min_c() {
    printf '%s\n' $(((THERMAL_VALID_MIN_MILLI_C + 999) / 1000))
}

install_valid_max_c() {
    printf '%s\n' $((THERMAL_VALID_MAX_MILLI_C / 1000))
}

install_valid_min_deci_c() {
    printf '%s\n' $(((THERMAL_VALID_MIN_MILLI_C + 99) / 100))
}

install_valid_max_deci_c() {
    printf '%s\n' $((THERMAL_VALID_MAX_MILLI_C / 100))
}

install_thermal_value_valid() {
    local value="$1"
    [ "${THERMAL_VALUE_FILTER_ENABLE:-1}" = 1 ] || return 0
    install_signed_int "$value" || return 1
    [ "$value" -ge "$THERMAL_VALID_MIN_MILLI_C" ] && \
        [ "$value" -le "$THERMAL_VALID_MAX_MILLI_C" ]
}

install_power_value_valid() {
    local path="$1" value="$2" min max
    [ "${THERMAL_VALUE_FILTER_ENABLE:-1}" = 1 ] || return 0
    install_signed_int "$value" || return 1
    case "${path#/sys/class/power_supply/}" in
        mtk-battery/temperature)
            min="$(install_valid_min_c)"
            max="$(install_valid_max_c)"
            ;;
        *)
            min="$(install_valid_min_deci_c)"
            max="$(install_valid_max_deci_c)"
            ;;
    esac
    [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

install_thermal_service_candidates() {
    printf '%s\n' \
        horae \
        vendor.thermal-hal-2-0.mtk \
        thermal_core \
        thermal-engine \
        qti.thermal-engine \
        vendor.thermal-hal \
        vendor.thermal-hal-aidl \
        vendor.thermal-hal-2-0
}

install_preflight() {
    local zone count=0 unsupported=0 supported=0 invalid=0 context type real raw p service found_service=0
    local min_c max_c
    INSTALL_SKIP_COUNT=0
    load_install_config

    ui_print "安装预检查（仅提示兼容性，不阻止安装）："
    if [ "$THERMAL_VALUE_FILTER_ENABLE" = 1 ]; then
        min_c="$(install_valid_min_c)"
        max_c="$(install_valid_max_c)"
        ui_print "  数值过滤：仅处理约 ${min_c}°C～${max_c}°C 范围内的温度节点"
    else
        ui_print "  数值过滤：已关闭，匹配到的温度节点都会尝试处理"
    fi
    ui_print "  服务模式：${THERMAL_SERVICES_MODE}"
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/temp" ] || continue
        count=$((count + 1))
        real="$(readlink -f "$zone/temp" 2>/dev/null)"
        [ -n "$real" ] || real="$zone/temp"
        context="$(ls -Zd "$real" 2>/dev/null | awk '{print $1}')"
        type="$(cat "$zone/type" 2>/dev/null | tr -d '\r\n')"
        [ -n "$type" ] || type=unknown
        raw="$(cat "$zone/temp" 2>/dev/null | tr -d ' \r\n')"
        if ! install_context_supported "$context"; then
            unsupported=$((unsupported + 1))
            if [ "$unsupported" -le 5 ]; then
                install_print_skip "${zone##*/} $type：SELinux 标签未适配 (${context:-unknown})"
            fi
        elif ! install_thermal_value_valid "$raw"; then
            invalid=$((invalid + 1))
            if [ "$invalid" -le 5 ]; then
                install_print_skip "${zone##*/} $type：当前值 $raw 超出过滤范围，运行时跳过"
            fi
        else
            supported=$((supported + 1))
        fi
    done
    if [ "$count" -eq 0 ]; then
        install_print_skip "thermal zone：当前环境未发现 /sys/class/thermal/thermal_zone*/temp"
    elif [ "$supported" -eq 0 ]; then
        if [ "$unsupported" -eq 0 ] && [ "$invalid" -gt 0 ]; then
            install_print_skip "thermal zone：当前 $count 个节点均超出过滤范围，核心伪装不会生效"
        elif [ "$unsupported" -gt 0 ] && [ "$invalid" -gt 0 ]; then
            install_print_skip "thermal zone：当前 $count 个节点均因 SELinux 标签或数值过滤跳过，核心伪装不会生效"
        else
            install_print_skip "thermal zone：当前 $count 个节点的 SELinux 标签均未适配，核心伪装不会生效"
        fi
    else
        ui_print "  thermal zone：发现 $count 个，可处理 $supported 个，过滤跳过 $invalid 个"
    fi
    [ "$unsupported" -gt 5 ] && install_print_skip "另有 $((unsupported - 5)) 个 thermal zone 标签未适配，详见运行日志"
    [ "$invalid" -gt 5 ] && install_print_skip "另有 $((invalid - 5)) 个 thermal zone 当前值超出过滤范围，运行时跳过"

    for p in /sys/class/power_supply/*/temp /sys/class/power_supply/*/temperature; do
        [ -e "$p" ] || continue
        install_power_target_enabled "$p" || continue
        raw="$(cat "$p" 2>/dev/null | tr -d ' \r\n')"
        if ! install_power_value_valid "$p" "$raw"; then
            install_print_skip "power_supply ${p#/sys/class/power_supply/}：当前值 $raw 超出过滤范围，运行时跳过"
            continue
        fi
        install_check_file_target "$p" "power_supply ${p#/sys/class/power_supply/}"
    done

    if [ "$PROC_SHELL_TEMP_ENABLE" = 1 ] && [ ! -w /proc/shell-temp ]; then
        install_print_skip "/proc/shell-temp：不存在或不可写"
    fi

    if [ "$THERMAL_SERVICES_MODE" != keep ]; then
        for service in $(install_thermal_service_candidates); do
            if [ -n "$(getprop init.svc."$service" 2>/dev/null)" ]; then
                found_service=1
                ui_print "  温控服务：发现 $service，将按 ${THERMAL_SERVICES_MODE} 处理"
            fi
        done
        [ "$found_service" -eq 1 ] || install_print_skip "温控服务：未发现候选服务，运行时跳过服务处理"
    fi

    if [ "$INSTALL_SKIP_COUNT" -eq 0 ]; then
        ui_print "  预检查结果：未发现预计跳过项"
    else
        ui_print "  预检查结果：以上项目安装后运行时会跳过；最终结果以 module.log 为准"
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
