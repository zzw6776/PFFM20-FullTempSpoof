#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/shell-bootstrap.sh" || exit 1
. "$MODDIR/common.sh"

acquire_lock || {
    echo "已有实例正在执行，请稍后重试"
    exit 1
}
install_lock_signal_traps

category_name_cn() {
    case "$1" in
        CPU)          echo "CPU 处理器" ;;
        GPU)          echo "GPU 图形处理器" ;;
        APU_NPU)      echo "APU/NPU 人工智能处理器" ;;
        MEMORY)       echo "内存 (DRAM)" ;;
        SOC)          echo "SoC 芯片" ;;
        SHELL_SKIN)   echo "外壳 / 表面温度" ;;
        BATTERY)      echo "电池" ;;
        CHARGER)      echo "充电器" ;;
        PMIC)         echo "电源管理芯片 (PMIC)" ;;
        DYNAMIC_RADIO) echo "动态射频 / 基带" ;;
        MODEM_RF)     echo "基带 / 射频" ;;
        CONNECTIVITY) echo "连接子系统 (WiFi/蓝牙)" ;;
        NTC_AMBIENT)  echo "环境 / NTC 温度" ;;
        UNKNOWN)      echo "未识别温区" ;;
        *)            echo "$1" ;;
    esac
}

load_config
validate_config || {
    echo "配置校验失败，请检查 config.conf"
    exit 1
}

CHARGING_MODDIR="$MODDIR"
. "$MODDIR/charging_dtbo.sh"
echo "========================================"
echo "  充电 DTBO 配置"
echo "========================================"
if ! charging_apply_requested; then
    echo "充电 DTBO 处理失败；温度配置未继续应用，请检查：$LOG_FILE"
    exit 1
fi
[ "$CHARGING_REBOOT_REQUIRED" = 1 ] && echo "提示：DTBO 已变化，必须重启后充电配置才会生效"
echo ""

echo "========================================"
echo "  ColorOS 温度传感器状态"
echo "========================================"
echo ""

# ---- 模块状态 ----
was_active=0
if [ -e "$ACTIVE_FILE" ]; then
    was_active=1
    echo "【模块状态】已生效 ✓"
    echo "  应用时间：$(cat "$ACTIVE_FILE" 2>/dev/null)"
else
    echo "【模块状态】未生效 ✗"
fi
echo ""

# ---- 卸载当前伪装，暴露真实温度 ----
if [ "$was_active" = 1 ]; then
    echo "正在卸载伪装以读取真实温度……"
    if ! restore_runtime; then
        echo "恢复真实温度失败，已停止重新应用；请检查日志：$LOG_FILE"
        exit 1
    fi
    echo ""
fi

# ---- 读取并显示所有真实温度 ----
echo "----------------------------------------"
echo "  Thermal Zone 温度一览"
echo "  格式：真实温度 -> 伪装目标"
echo "----------------------------------------"

last_cat=""
for zone in /sys/class/thermal/thermal_zone*; do
    [ -e "$zone/temp" ] || continue
    name="${zone##*/}"
    type="$(cat "$zone/type" 2>/dev/null | tr -d '\r\n')"
    temp_raw="$(cat "$zone/temp" 2>/dev/null | tr -d ' \r\n')"
    [ -n "$type" ] || type="unknown"
    [ -n "$temp_raw" ] || temp_raw="-"
    thermal_type_is_non_temperature "$type" && continue

    category="$(classify_zone "$type")"
    cat_cn="$(category_name_cn "$category")"

    if [ "$temp_raw" != "-" ] && [ "$temp_raw" != "0" ] 2>/dev/null; then
        real_c="$(awk "BEGIN { printf \"%.1f\", $temp_raw / 1000 }")"
    else
        real_c="$temp_raw"
    fi

    # 伪装目标温度
    if ! thermal_value_valid_for_type "$type" "$temp_raw"; then
        tag="[当前值不在正常温度范围，运行时跳过]"
    elif thermal_target_enabled_for_type "$type" "$category"; then
        target_c="$(thermal_target_temp_c_for_type "$type" "$category")"
        tag="-> 伪装 ${target_c}°C"
    else
        tag="[配置为不伪装]"
    fi

    # 按分类分组
    if [ "$category" != "$last_cat" ]; then
        echo ""
        echo "【${cat_cn}】"
        last_cat="$category"
    fi

    echo "  $name ($type): 真实 ${real_c}°C $tag"
done

# ---- 额外温度节点 ----
echo ""
echo "----------------------------------------"
echo "  额外温度节点"
echo "----------------------------------------"

found_power_supply=0
for power_path in /sys/class/power_supply/*/temp /sys/class/power_supply/*/temperature; do
    [ -e "$power_path" ] || continue
    found_power_supply=1
    power_raw="$(cat "$power_path" 2>/dev/null | tr -d ' \r\n')"
    power_fake="$(power_supply_target_value "$power_path")"
    if power_supply_uses_celsius_unit "$power_path"; then
        power_real_c="$power_raw"
        power_fake_c="$power_fake"
    else
        if [ -n "$power_raw" ] && [ "$power_raw" != "0" ] 2>/dev/null; then
            power_real_c="$(awk "BEGIN { printf \"%.1f\", $power_raw / 10 }")"
        else
            power_real_c="$power_raw"
        fi
        power_fake_c="$(awk "BEGIN { printf \"%.1f\", $power_fake / 10 }")"
    fi
    if ! power_supply_value_valid "$power_path" "$power_raw"; then
        echo "  ${power_path#/sys/class/power_supply/}: 真实 ${power_real_c}°C [当前值不在正常温度范围，运行时跳过]"
    elif power_supply_target_enabled "$power_path"; then
        echo "  ${power_path#/sys/class/power_supply/}: 真实 ${power_real_c}°C -> 伪装 ${power_fake_c}°C"
    else
        echo "  ${power_path#/sys/class/power_supply/}: 真实 ${power_real_c}°C [配置为不伪装]"
    fi
done
[ "$found_power_supply" = 1 ] || echo "  power_supply 温度节点：未发现"

if [ -r /proc/shell-temp ]; then
    if ! proc_shell_temp_supported; then
        echo "  外壳 (/proc/shell-temp): [本机不适用，已忽略；未写入或清零]"
    elif [ "$PROC_SHELL_TEMP_ENABLE" = 1 ]; then
        echo "  外壳 (/proc/shell-temp): -> 伪装 ${SHELL_SKIN_TEMP_C}°C"
    else
        echo "  外壳 (/proc/shell-temp): [配置为不伪装]"
    fi
else
    echo "  外壳 (/proc/shell-temp): 不存在或不可读"
fi

# ---- 厂商温控服务状态 ----
echo ""
echo "----------------------------------------"
echo "  厂商温控服务状态"
echo "----------------------------------------"
echo "  每个服务按 config.conf 中对应 *_SERVICE_MODE 独立处理"
for svc in $(thermal_service_candidates); do
    state="$(getprop init.svc."$svc" 2>/dev/null)"
    [ -n "$state" ] || continue
    echo "  $svc: $state，配置 $(service_mode_for "$svc")"
done

# ---- 用最新配置重新应用伪装 ----
echo ""
echo "========================================"
echo "  正在用最新配置重新应用伪装……"
echo "========================================"

rm -f "$DISABLED_FILE"
if apply_runtime; then
    echo ""
    echo "✓ 应用成功"
    echo "  映射表：$MAP_FILE"
    echo "  日志：  $LOG_FILE"
else
    echo ""
    echo "✗ 应用失败，请检查日志：$LOG_FILE"
    exit 1
fi
