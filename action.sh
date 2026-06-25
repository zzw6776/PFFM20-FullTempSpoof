#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

acquire_lock || {
    echo "已有实例正在执行，请稍后重试"
    exit 1
}
cleanup_lock() {
    release_lock
}

handle_int() {
    trap - EXIT INT TERM
    release_lock
    exit 130
}

handle_term() {
    trap - EXIT INT TERM
    release_lock
    exit 143
}

trap 'cleanup_lock' EXIT
trap 'handle_int' INT
trap 'handle_term' TERM

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

echo "========================================"
echo "  PFFM20 温度传感器状态"
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

    category="$(classify_zone "$type")"
    cat_cn="$(category_name_cn "$category")"

    # 真实温度：毫摄氏度 -> 摄氏度
    if [ "$temp_raw" != "-" ] && [ "$temp_raw" != "0" ] 2>/dev/null; then
        real_c="$(awk "BEGIN { printf \"%.1f\", $temp_raw / 1000 }")"
    else
        real_c="$temp_raw"
    fi

    # 伪装目标温度
    if category_enabled "$category"; then
        target_c="$(category_temp_c "$category")"
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

batt_path="/sys/class/power_supply/battery/temp"
if [ -e "$batt_path" ]; then
    batt_raw="$(cat "$batt_path" 2>/dev/null | tr -d ' \r\n')"
    if [ -n "$batt_raw" ] && [ "$batt_raw" != "0" ] 2>/dev/null; then
        batt_c="$(awk "BEGIN { printf \"%.1f\", $batt_raw / 10 }")"
    else
        batt_c="$batt_raw"
    fi
    if [ "$POWER_SUPPLY_BATTERY_ENABLE" = 1 ]; then
        echo "  电池 (power_supply): 真实 ${batt_c}°C -> 伪装 ${BATTERY_TEMP_C}°C"
    else
        echo "  电池 (power_supply): 真实 ${batt_c}°C [配置为不伪装]"
    fi
else
    echo "  电池 (power_supply): 节点不存在"
fi

if [ -r /proc/shell-temp ]; then
    if [ "$PROC_SHELL_TEMP_ENABLE" = 1 ]; then
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
horae_state="$(getprop init.svc.horae 2>/dev/null)"
thermal_hal_state="$(getprop init.svc.vendor.thermal-hal-2-0.mtk 2>/dev/null)"
thermal_core_state="$(getprop init.svc.thermal_core 2>/dev/null)"
echo "  Horae:              ${horae_state:-未知} (配置: $HORAE_MODE)"
echo "  MTK Thermal HAL:    ${thermal_hal_state:-未知} (配置: $VENDOR_THERMAL_HAL_MODE)"
echo "  thermal_core:       ${thermal_core_state:-未知} (配置: $THERMAL_CORE_MODE)"

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
