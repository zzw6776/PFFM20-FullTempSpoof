#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"
CONFIG_FILE="$MODDIR/config.conf"
STATE_DIR="/data/adb/pffm20_fulltempspoof"
FAKE_ROOT="/dev/pffm20_fulltempspoof"
LOG_FILE="$STATE_DIR/module.log"
MOUNTS_FILE="$STATE_DIR/mounts.tsv"
MAP_FILE="$STATE_DIR/thermal-map.tsv"
ACTIVE_FILE="$STATE_DIR/active"
DISABLED_FILE="$STATE_DIR/user_disabled"
LOCK_DIR="$STATE_DIR/lock"
ORIGINAL_RUNTIME_FILE="$STATE_DIR/original-runtime.conf"
TAB="$(printf '\t')"

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 0700 "$STATE_DIR" 2>/dev/null

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

load_config() {
    MASTER_ENABLE=1
    STRICT_DEVICE_CHECK=1
    EXPECTED_MODEL=PFFM20
    EXPECTED_PLATFORM=mt6983
    EXPECTED_ANDROID=12
    EXPECTED_KERNEL_PREFIX=5.10.66
    WAIT_TIMEOUT_SEC=120
    EXPECTED_MIN_THERMAL_ZONES=51

    CPU_ENABLE=1; CPU_TEMP_C=40
    GPU_ENABLE=1; GPU_TEMP_C=40
    APU_NPU_ENABLE=1; APU_NPU_TEMP_C=40
    MEMORY_ENABLE=1; MEMORY_TEMP_C=40
    SOC_ENABLE=1; SOC_TEMP_C=40
    SHELL_SKIN_ENABLE=1; SHELL_SKIN_TEMP_C=36
    BATTERY_ENABLE=1; BATTERY_TEMP_C=30
    CHARGER_ENABLE=1; CHARGER_TEMP_C=35
    PMIC_ENABLE=1; PMIC_TEMP_C=40
    MODEM_RF_ENABLE=1; MODEM_RF_TEMP_C=40
    CONNECTIVITY_ENABLE=1; CONNECTIVITY_TEMP_C=40
    NTC_AMBIENT_ENABLE=1; NTC_AMBIENT_TEMP_C=36
    UNKNOWN_ENABLE=1; UNKNOWN_TEMP_C=40

    POWER_SUPPLY_BATTERY_ENABLE=1
    PROC_SHELL_TEMP_ENABLE=1
    HORAE_MODE=stop
    VENDOR_THERMAL_HAL_MODE=stop
    THERMAL_CORE_MODE=keep
    CONFLICT_CHECK=1
    VERIFY_AFTER_APPLY=1

    [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

is_bool() {
    [ "$1" = 0 ] || [ "$1" = 1 ]
}

is_temp() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] && [ "$1" -le 150 ]
}

is_uint_range() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

validate_config() {
    local key value
    for key in MASTER_ENABLE STRICT_DEVICE_CHECK CPU_ENABLE GPU_ENABLE \
        APU_NPU_ENABLE MEMORY_ENABLE SOC_ENABLE SHELL_SKIN_ENABLE \
        BATTERY_ENABLE CHARGER_ENABLE PMIC_ENABLE MODEM_RF_ENABLE \
        CONNECTIVITY_ENABLE NTC_AMBIENT_ENABLE UNKNOWN_ENABLE \
        POWER_SUPPLY_BATTERY_ENABLE PROC_SHELL_TEMP_ENABLE \
        CONFLICT_CHECK VERIFY_AFTER_APPLY; do
        eval "value=\${$key}"
        is_bool "$value" || {
            log ERROR "配置错误：$key 必须为 0 或 1，当前为 $value"
            return 1
        }
    done

    for key in CPU_TEMP_C GPU_TEMP_C APU_NPU_TEMP_C MEMORY_TEMP_C \
        SOC_TEMP_C SHELL_SKIN_TEMP_C BATTERY_TEMP_C CHARGER_TEMP_C \
        PMIC_TEMP_C MODEM_RF_TEMP_C CONNECTIVITY_TEMP_C \
        NTC_AMBIENT_TEMP_C UNKNOWN_TEMP_C; do
        eval "value=\${$key}"
        is_temp "$value" || {
            log ERROR "配置错误：$key 必须是 0～150 的整数，当前为 $value"
            return 1
        }
    done

    case "$HORAE_MODE" in stop|keep) ;; *) log ERROR "HORAE_MODE 只能为 stop/keep"; return 1 ;; esac
    case "$VENDOR_THERMAL_HAL_MODE" in stop|keep) ;; *) log ERROR "VENDOR_THERMAL_HAL_MODE 只能为 stop/keep"; return 1 ;; esac
    case "$THERMAL_CORE_MODE" in stop|keep) ;; *) log ERROR "THERMAL_CORE_MODE 只能为 stop/keep"; return 1 ;; esac
    is_uint_range "$WAIT_TIMEOUT_SEC" 1 600 || {
        log ERROR "WAIT_TIMEOUT_SEC 必须是 1～600 的整数"
        return 1
    }
    is_uint_range "$EXPECTED_MIN_THERMAL_ZONES" 1 256 || {
        log ERROR "EXPECTED_MIN_THERMAL_ZONES 必须是 1～256 的整数"
        return 1
    }
    return 0
}

device_guard() {
    [ "$STRICT_DEVICE_CHECK" = 1 ] || return 0

    local model platform android kernel
    model="$(getprop ro.product.model)"
    platform="$(getprop ro.board.platform)"
    [ -n "$platform" ] || platform="$(getprop ro.hardware)"
    android="$(getprop ro.build.version.release)"
    kernel="$(uname -r)"

    [ "$model" = "$EXPECTED_MODEL" ] || {
        log ERROR "设备不匹配：model=$model，期望 $EXPECTED_MODEL"
        return 1
    }
    [ "$platform" = "$EXPECTED_PLATFORM" ] || {
        log ERROR "平台不匹配：platform=$platform，期望 $EXPECTED_PLATFORM"
        return 1
    }
    [ "$android" = "$EXPECTED_ANDROID" ] || {
        log ERROR "Android 不匹配：release=$android，期望 $EXPECTED_ANDROID"
        return 1
    }
    case "$kernel" in
        "$EXPECTED_KERNEL_PREFIX"*) ;;
        *) log ERROR "内核不匹配：kernel=$kernel，期望前缀 $EXPECTED_KERNEL_PREFIX"; return 1 ;;
    esac

    log INFO "设备校验通过：$model / $platform / Android $android / $kernel"
    return 0
}

module_is_active() {
    local dir="$1"
    [ -d "$dir" ] && [ ! -e "$dir/disable" ] && [ ! -e "$dir/remove" ]
}

check_conflicts() {
    [ "$CONFLICT_CHECK" = 1 ] || return 0

    local dir id name
    for dir in /data/adb/modules/*; do
        [ -f "$dir/module.prop" ] || continue
        [ "$dir" = "$MODDIR" ] && continue
        module_is_active "$dir" || continue
        id="$(grep -m1 '^id=' "$dir/module.prop" 2>/dev/null | cut -d= -f2-)"
        name="$(grep -m1 '^name=' "$dir/module.prop" 2>/dev/null | cut -d= -f2-)"
        case "$id|$name" in
            *AAaTempSpoof*|*AaTempSpoof*|*ColorOs解除温控限制*|*ColorOS解除温控限制*)
                log ERROR "检测到冲突模块：$dir ($id / $name)"
                return 1
                ;;
        esac
    done

    if awk '$5 ~ /\/thermal_zone[0-9]+\/temp$/ { found=1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null; then
        log ERROR "检测到已有 thermal_zone/temp 文件挂载；为避免叠加挂载，本次拒绝应用"
        return 1
    fi
    return 0
}

wait_for_thermal_zones() {
    local elapsed=0 count=0
    while [ "$elapsed" -lt "$WAIT_TIMEOUT_SEC" ]; do
        count=0
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -e "$zone/temp" ] && count=$((count + 1))
        done
        [ -n "$count" ] || count=0
        if [ "$count" -ge "$EXPECTED_MIN_THERMAL_ZONES" ]; then
            log INFO "thermal zone 已就绪：$count 个"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log ERROR "等待 thermal zone 超时：仅发现 $count 个，期望至少 $EXPECTED_MIN_THERMAL_ZONES 个"
    return 1
}

classify_zone() {
    local type
    type="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$type" in
        soc_max|soc_top|soc_mm|soc*) echo SOC ;;
        cpu*) echo CPU ;;
        gpu*) echo GPU ;;
        apu*|npu*) echo APU_NPU ;;
        dram*|ddr*|llcc*|mem*|iommu*) echo MEMORY ;;
        shell*|skin*) echo SHELL_SKIN ;;
        *battery*|batt*|bms*) echo BATTERY ;;
        *charger*|usb-therm*|vbat*|ibat*) echo CHARGER ;;
        pmic*|pm8*|xo|xo-*|pa-therm*) echo PMIC ;;
        md[0-9]*|*ltepa*|*nrpa*|*antenna*|*sub6*|*rfc*|*rf-*|*mmw*|*qtm*|*nss*|*wcn*) echo MODEM_RF ;;
        consys*|wlan*|wifi*|wcss*) echo CONNECTIVITY ;;
        *ntc*|ambient*|board*|quiet*|rear*|cam*) echo NTC_AMBIENT ;;
        *) echo UNKNOWN ;;
    esac
}

category_enabled() {
    case "$1" in
        CPU) [ "$CPU_ENABLE" = 1 ] ;;
        GPU) [ "$GPU_ENABLE" = 1 ] ;;
        APU_NPU) [ "$APU_NPU_ENABLE" = 1 ] ;;
        MEMORY) [ "$MEMORY_ENABLE" = 1 ] ;;
        SOC) [ "$SOC_ENABLE" = 1 ] ;;
        SHELL_SKIN) [ "$SHELL_SKIN_ENABLE" = 1 ] ;;
        BATTERY) [ "$BATTERY_ENABLE" = 1 ] ;;
        CHARGER) [ "$CHARGER_ENABLE" = 1 ] ;;
        PMIC) [ "$PMIC_ENABLE" = 1 ] ;;
        MODEM_RF) [ "$MODEM_RF_ENABLE" = 1 ] ;;
        CONNECTIVITY) [ "$CONNECTIVITY_ENABLE" = 1 ] ;;
        NTC_AMBIENT) [ "$NTC_AMBIENT_ENABLE" = 1 ] ;;
        UNKNOWN) [ "$UNKNOWN_ENABLE" = 1 ] ;;
        *) return 1 ;;
    esac
}

category_temp_c() {
    case "$1" in
        CPU) echo "$CPU_TEMP_C" ;;
        GPU) echo "$GPU_TEMP_C" ;;
        APU_NPU) echo "$APU_NPU_TEMP_C" ;;
        MEMORY) echo "$MEMORY_TEMP_C" ;;
        SOC) echo "$SOC_TEMP_C" ;;
        SHELL_SKIN) echo "$SHELL_SKIN_TEMP_C" ;;
        BATTERY) echo "$BATTERY_TEMP_C" ;;
        CHARGER) echo "$CHARGER_TEMP_C" ;;
        PMIC) echo "$PMIC_TEMP_C" ;;
        MODEM_RF) echo "$MODEM_RF_TEMP_C" ;;
        CONNECTIVITY) echo "$CONNECTIVITY_TEMP_C" ;;
        NTC_AMBIENT) echo "$NTC_AMBIENT_TEMP_C" ;;
        UNKNOWN) echo "$UNKNOWN_TEMP_C" ;;
    esac
}

is_exact_mountpoint() {
    awk -v target="$1" '$5 == target { found=1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

runtime_mounts_present() {
    local target source
    [ -s "$MOUNTS_FILE" ] || return 1
    while IFS="$TAB" read -r target source; do
        [ -n "$target" ] || continue
        is_exact_mountpoint "$target" && return 0
    done < "$MOUNTS_FILE"
    return 1
}

reconcile_runtime_state() {
    [ -e "$ACTIVE_FILE" ] || return 0
    runtime_mounts_present && return 0

    # bind mount 会在重启后自动消失；清除外置状态目录里的陈旧标记。
    rm -f "$ACTIVE_FILE" "$MOUNTS_FILE" 2>/dev/null
    rm -rf "$FAKE_ROOT" 2>/dev/null
    log INFO "检测到重启后的陈旧 active 标记，已清理"
}

copy_selinux_context() {
    local target="$1" source="$2" context
    context="$(ls -Zd "$target" 2>/dev/null | awk '{print $1}')"
    [ -n "$context" ] && chcon "$context" "$source" 2>/dev/null
    return 0
}

bind_fake_value() {
    local target="$1" source_name="$2" value="$3" real source readback
    [ -e "$target" ] || return 1
    real="$(readlink -f "$target" 2>/dev/null)"
    [ -n "$real" ] || real="$target"

    if is_exact_mountpoint "$real"; then
        log ERROR "目标已是独立挂载点，拒绝叠加：$real"
        return 1
    fi

    mkdir -p "$FAKE_ROOT" 2>/dev/null
    source="$FAKE_ROOT/$source_name"
    printf '%s\n' "$value" > "$source" || return 1
    chown 0:0 "$source" 2>/dev/null
    chmod 0444 "$source" 2>/dev/null
    copy_selinux_context "$target" "$source"

    mount --bind "$source" "$real" 2>/dev/null || mount -o bind "$source" "$real" 2>/dev/null || {
        log ERROR "bind mount 失败：$source -> $real"
        rm -f "$source"
        return 1
    }

    printf '%s\t%s\n' "$real" "$source" >> "$MOUNTS_FILE"
    readback="$(cat "$target" 2>/dev/null | tr -d ' \r\n')"
    [ "$readback" = "$value" ] || {
        log ERROR "挂载后读回不一致：$target expected=$value actual=$readback"
        return 1
    }
    return 0
}

apply_thermal_zones() {
    local zone name type category temp_c temp_milli before mode result mounted=0 skipped=0 failed=0
    : > "$MOUNTS_FILE"
    printf 'zone\ttype\tcategory\tbefore\tfake\tmode\tresult\n' > "$MAP_FILE"

    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/temp" ] || continue
        name="${zone##*/}"
        type="$(cat "$zone/type" 2>/dev/null | tr -d '\r\n')"
        before="$(cat "$zone/temp" 2>/dev/null | tr -d ' \r\n')"
        mode="$(cat "$zone/mode" 2>/dev/null | tr -d ' \r\n')"
        [ -n "$type" ] || type=unknown
        [ -n "$before" ] || before=-
        [ -n "$mode" ] || mode=-
        category="$(classify_zone "$type")"

        if ! category_enabled "$category"; then
            printf '%s\t%s\t%s\t%s\t-\t%s\tdisabled-by-config\n' "$name" "$type" "$category" "$before" "$mode" >> "$MAP_FILE"
            skipped=$((skipped + 1))
            continue
        fi

        temp_c="$(category_temp_c "$category")"
        temp_milli=$((temp_c * 1000))
        if bind_fake_value "$zone/temp" "${name}_temp" "$temp_milli"; then
            result=mounted
            mounted=$((mounted + 1))
        else
            result=failed
            failed=$((failed + 1))
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$type" "$category" "$before" "$temp_milli" "$mode" "$result" >> "$MAP_FILE"
    done

    log INFO "thermal zone 应用完成：mounted=$mounted skipped=$skipped failed=$failed"
    [ "$failed" -eq 0 ]
}

apply_power_supply_battery() {
    [ "$POWER_SUPPLY_BATTERY_ENABLE" = 1 ] || return 0
    local target=/sys/class/power_supply/battery/temp value
    [ -e "$target" ] || {
        log WARN "电池 power_supply temp 节点不存在"
        return 0
    }
    value=$((BATTERY_TEMP_C * 10))
    bind_fake_value "$target" power_supply_battery_temp "$value" && \
        log INFO "power_supply battery temp 已伪装为 ${BATTERY_TEMP_C}°C"
}

write_shell_temp() {
    local value="$1" i=0
    [ -w /proc/shell-temp ] || return 1
    while [ "$i" -le 7 ]; do
        if [ "$i" -eq 0 ]; then
            printf '%s %s\n' "$i" "$value" > /proc/shell-temp 2>/dev/null
        else
            printf '%s %s\n' "$i" "$value" >> /proc/shell-temp 2>/dev/null
        fi
        i=$((i + 1))
    done
}

apply_proc_shell_temp() {
    [ "$PROC_SHELL_TEMP_ENABLE" = 1 ] || return 0
    local value=$((SHELL_SKIN_TEMP_C * 1000))
    if write_shell_temp "$value"; then
        log INFO "/proc/shell-temp 0～7 已设置为 ${SHELL_SKIN_TEMP_C}°C"
    else
        log WARN "/proc/shell-temp 不可写，已跳过"
    fi
}

backup_runtime_state() {
    [ -f "$ORIGINAL_RUNTIME_FILE" ] && return 0
    {
        printf 'HORAE_PROP=%s\n' "$(getprop persist.sys.horae.enable)"
        printf 'HORAE_STATE=%s\n' "$(getprop init.svc.horae)"
        printf 'THERMAL_HAL_STATE=%s\n' "$(getprop init.svc.vendor.thermal-hal-2-0.mtk)"
        printf 'THERMAL_CORE_STATE=%s\n' "$(getprop init.svc.thermal_core)"
    } > "$ORIGINAL_RUNTIME_FILE"
    chmod 0600 "$ORIGINAL_RUNTIME_FILE" 2>/dev/null
}

stop_init_service() {
    local service="$1" state tries=0
    setprop ctl.stop "$service" 2>/dev/null
    while [ "$tries" -lt 5 ]; do
        sleep 1
        state="$(getprop init.svc."$service")"
        [ "$state" = stopped ] && {
            log INFO "服务 $service 已停止"
            return 0
        }
        tries=$((tries + 1))
    done
    log ERROR "服务 $service 未能停止，当前状态：$state"
    return 1
}

start_init_service() {
    local service="$1" state tries=0
    setprop ctl.start "$service" 2>/dev/null
    while [ "$tries" -lt 5 ]; do
        sleep 1
        state="$(getprop init.svc."$service")"
        [ "$state" = running ] && {
            log INFO "服务 $service 已启动"
            return 0
        }
        tries=$((tries + 1))
    done
    log ERROR "服务 $service 未能启动，当前状态：$state"
    return 1
}

apply_private_services() {
    local result=0
    backup_runtime_state

    if [ "$HORAE_MODE" = stop ]; then
        if command -v resetprop >/dev/null 2>&1; then
            resetprop -n persist.sys.horae.enable 0 2>/dev/null
        fi
        stop_init_service horae || result=1
    fi

    if [ "$VENDOR_THERMAL_HAL_MODE" = stop ]; then
        stop_init_service vendor.thermal-hal-2-0.mtk || result=1
    fi
    if [ "$THERMAL_CORE_MODE" = stop ]; then
        stop_init_service thermal_core || result=1
    fi
    return "$result"
}

verify_runtime() {
    [ "$VERIFY_AFTER_APPLY" = 1 ] || return 0
    local expected=0 good=0 bad=0 line zone type category before fake mode result current
    while IFS="$TAB" read -r zone type category before fake mode result; do
        [ "$zone" = zone ] && continue
        [ "$result" = mounted ] || continue
        expected=$((expected + 1))
        current="$(cat "/sys/class/thermal/$zone/temp" 2>/dev/null | tr -d ' \r\n')"
        if [ "$current" = "$fake" ]; then
            good=$((good + 1))
        else
            bad=$((bad + 1))
            log ERROR "验证失败：$zone/$type expected=$fake actual=$current"
        fi
    done < "$MAP_FILE"
    log INFO "验证完成：expected=$expected good=$good bad=$bad"
    [ "$bad" -eq 0 ]
}

apply_runtime() {
    load_config
    validate_config || return 1
    reconcile_runtime_state
    [ "$MASTER_ENABLE" = 1 ] || {
        log INFO "MASTER_ENABLE=0，不应用伪装"
        restore_runtime
        return 0
    }
    [ ! -e "$DISABLED_FILE" ] || {
        log INFO "检测到用户运行时禁用标记，不应用伪装"
        return 0
    }
    if [ -e "$ACTIVE_FILE" ] && runtime_mounts_present; then
        log INFO "当前运行时挂载已生效，无需重复应用"
        return 0
    fi
    device_guard || return 1
    check_conflicts || return 1
    wait_for_thermal_zones || return 1

    rm -rf "$FAKE_ROOT" 2>/dev/null
    rm -f "$ACTIVE_FILE" "$MOUNTS_FILE" "$MAP_FILE" 2>/dev/null
    mkdir -p "$FAKE_ROOT" 2>/dev/null

    apply_thermal_zones || {
        log ERROR "thermal zone 应用存在失败，开始回滚"
        restore_mounts
        return 1
    }
    apply_power_supply_battery || {
        log ERROR "power_supply battery 应用失败，开始回滚"
        restore_mounts
        return 1
    }
    apply_proc_shell_temp
    apply_private_services || {
        log ERROR "厂商私有温控服务未按配置切换，开始回滚"
        restore_runtime
        return 1
    }
    verify_runtime || log WARN "部分用户空间验证未通过，请检查日志"

    date '+%Y-%m-%d %H:%M:%S' > "$ACTIVE_FILE"
    log INFO "模块应用完成；本脚本为一次性执行，不驻留后台"
    return 0
}

restore_mounts() {
    local target source
    [ -f "$MOUNTS_FILE" ] || return 0
    while IFS="$TAB" read -r target source; do
        [ -n "$target" ] || continue
        umount "$target" 2>/dev/null || true
    done < "$MOUNTS_FILE"
    rm -f "$MOUNTS_FILE"
    rm -rf "$FAKE_ROOT" 2>/dev/null
}

restore_runtime_services() {
    local HORAE_PROP HORAE_STATE THERMAL_HAL_STATE THERMAL_CORE_STATE result=0
    [ -r "$ORIGINAL_RUNTIME_FILE" ] || return 0
    . "$ORIGINAL_RUNTIME_FILE"

    if command -v resetprop >/dev/null 2>&1 && [ -n "$HORAE_PROP" ]; then
        resetprop -n persist.sys.horae.enable "$HORAE_PROP" 2>/dev/null
    fi
    if [ "$HORAE_STATE" = running ]; then start_init_service horae || result=1; fi
    if [ "$HORAE_STATE" = stopped ]; then stop_init_service horae || result=1; fi
    if [ "$THERMAL_HAL_STATE" = running ]; then start_init_service vendor.thermal-hal-2-0.mtk || result=1; fi
    if [ "$THERMAL_HAL_STATE" = stopped ]; then stop_init_service vendor.thermal-hal-2-0.mtk || result=1; fi
    if [ "$THERMAL_CORE_STATE" = running ]; then start_init_service thermal_core || result=1; fi
    if [ "$THERMAL_CORE_STATE" = stopped ]; then stop_init_service thermal_core || result=1; fi

    if [ "$result" -eq 0 ]; then
        rm -f "$ORIGINAL_RUNTIME_FILE"
    else
        log ERROR "部分服务恢复失败，保留原始状态文件以便重试"
    fi
    return "$result"
}

restore_runtime() {
    restore_mounts
    write_shell_temp 0 2>/dev/null || true
    restore_runtime_services || true
    rm -f "$ACTIVE_FILE"
    log INFO "运行时状态已恢复"
}

acquire_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null
}

release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}
