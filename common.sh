#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"
CONFIG_FILE="$MODDIR/config.conf"
STATE_DIR="/data/adb/pffm20_fulltempspoof"
FAKE_ROOT="/dev/pffm20_fulltempspoof"
THERM_FAKE_ROOT="$FAKE_ROOT/sysfs_therm"
BATTERY_SUPPLY_FAKE_ROOT="$FAKE_ROOT/sysfs_battery_supply"
BATTERY_INFO_FAKE_ROOT="$FAKE_ROOT/sysfs_batteryinfo"
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

rotate_log() {
    local size
    [ -f "$LOG_FILE" ] || return 0
    size="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -ge 1048576 ]; then
        rm -f "$LOG_FILE.1" 2>/dev/null
        mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || return 1
    fi
    return 0
}

rotate_log 2>/dev/null || true

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
    VENDOR_THERMAL_HAL_MODE=restart
    THERMAL_CORE_MODE=keep
    CONFLICT_CHECK=1
    VERIFY_AFTER_APPLY=1
    ADB_WIFI_ENABLE=1
    ADB_WIFI_PORT=5555

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
        CONFLICT_CHECK VERIFY_AFTER_APPLY ADB_WIFI_ENABLE; do
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
    case "$VENDOR_THERMAL_HAL_MODE" in stop|keep|restart) ;; *) log ERROR "VENDOR_THERMAL_HAL_MODE 只能为 stop/keep/restart"; return 1 ;; esac
    case "$THERMAL_CORE_MODE" in stop|keep) ;; *) log ERROR "THERMAL_CORE_MODE 只能为 stop/keep"; return 1 ;; esac
    is_uint_range "$WAIT_TIMEOUT_SEC" 1 600 || {
        log ERROR "WAIT_TIMEOUT_SEC 必须是 1～600 的整数"
        return 1
    }
    is_uint_range "$EXPECTED_MIN_THERMAL_ZONES" 1 256 || {
        log ERROR "EXPECTED_MIN_THERMAL_ZONES 必须是 1～256 的整数"
        return 1
    }
    if [ "$ADB_WIFI_ENABLE" = 1 ]; then
        is_uint_range "$ADB_WIFI_PORT" 1024 65535 || {
            log ERROR "ADB_WIFI_PORT 必须是 1024～65535 的整数，当前为 $ADB_WIFI_PORT"
            return 1
        }
    fi
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

unmount_exact() {
    local target="$1"
    LAST_UNMOUNT_LAZY=0
    is_exact_mountpoint "$target" || return 0
    if umount "$target" 2>/dev/null; then
        ! is_exact_mountpoint "$target"
        return $?
    fi
    umount -l "$target" 2>/dev/null || return 1
    LAST_UNMOUNT_LAZY=1
    RESTORE_MOUNTS_LAZY_USED=1
    ! is_exact_mountpoint "$target"
}

get_selinux_context() {
    ls -Zd "$1" 2>/dev/null | awk '{print $1}'
}

mount_context_tmpfs() {
    local dir="$1" context="$2" actual
    mkdir -p "$dir" 2>/dev/null || return 1
    mount -t tmpfs -o "size=1m,mode=0700,context=$context" tmpfs "$dir" 2>/dev/null || {
        log ERROR "创建 SELinux context tmpfs 失败：$dir context=$context"
        return 1
    }
    actual="$(get_selinux_context "$dir")"
    [ "$actual" = "$context" ] || {
        log ERROR "context tmpfs 标签不一致：$dir expected=$context actual=$actual"
        umount "$dir" 2>/dev/null
        return 1
    }
    return 0
}

restore_fake_roots() {
    local dir result=0
    for dir in "$BATTERY_INFO_FAKE_ROOT" "$BATTERY_SUPPLY_FAKE_ROOT" "$THERM_FAKE_ROOT"; do
        unmount_exact "$dir" || result=1
    done
    [ "$result" -eq 0 ] && rm -rf "$FAKE_ROOT" 2>/dev/null
    return "$result"
}

prepare_fake_roots() {
    mkdir -p "$FAKE_ROOT" 2>/dev/null || return 1
    chown 0:0 "$FAKE_ROOT" 2>/dev/null
    chmod 0700 "$FAKE_ROOT" 2>/dev/null

    mount_context_tmpfs "$THERM_FAKE_ROOT" "u:object_r:sysfs_therm:s0" || {
        restore_fake_roots
        return 1
    }
    mount_context_tmpfs "$BATTERY_SUPPLY_FAKE_ROOT" "u:object_r:sysfs_battery_supply:s0" || {
        restore_fake_roots
        return 1
    }
    mount_context_tmpfs "$BATTERY_INFO_FAKE_ROOT" "u:object_r:sysfs_batteryinfo:s0" || {
        restore_fake_roots
        return 1
    }
    log INFO "已创建三个固定 SELinux context tmpfs，无需修改 live sepolicy"
    return 0
}

fake_root_for_context() {
    case "$1" in
        u:object_r:sysfs_therm:s0) echo "$THERM_FAKE_ROOT" ;;
        u:object_r:sysfs_battery_supply:s0) echo "$BATTERY_SUPPLY_FAKE_ROOT" ;;
        u:object_r:sysfs_batteryinfo:s0) echo "$BATTERY_INFO_FAKE_ROOT" ;;
        *) return 1 ;;
    esac
}

runtime_mounts_any_present() {
    local target source
    [ -s "$MOUNTS_FILE" ] || return 1
    while IFS="$TAB" read -r target source; do
        [ -n "$target" ] || continue
        is_exact_mountpoint "$target" && return 0
    done < "$MOUNTS_FILE"
    return 1
}

expected_runtime_targets() {
    local zone type category target suffix
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/temp" ] || continue
        type="$(cat "$zone/type" 2>/dev/null | tr -d '\r\n')"
        [ -n "$type" ] || type=unknown
        category="$(classify_zone "$type")"
        category_enabled "$category" || continue
        target="$(readlink -f "$zone/temp" 2>/dev/null)"
        [ -n "$target" ] || target="$zone/temp"
        printf '%s\n' "$target"
    done

    if [ "$POWER_SUPPLY_BATTERY_ENABLE" = 1 ]; then
        for target in \
            /sys/class/power_supply/battery/temp \
            /sys/class/power_supply/mtk-battery/temp \
            /sys/class/power_supply/mtk-battery/temperature; do
            [ -e "$target" ] || continue
            target="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
            [ -n "$target" ] && printf '%s\n' "$target"
        done
    fi

    if [ "${CHARGER_ENABLE:-1}" = 1 ]; then
        for suffix in master-charger mst-div-charger slave-charger slv-div-charger; do
            target="/sys/class/power_supply/mtk-$suffix/temp"
            [ -e "$target" ] || continue
            target="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
            [ -n "$target" ] && printf '%s\n' "$target"
        done
    fi
}

mount_record_has_target() {
    local expected="$1" target source
    [ -s "$MOUNTS_FILE" ] || return 1
    while IFS="$TAB" read -r target source; do
        [ "$target" = "$expected" ] && [ -n "$source" ] && return 0
    done < "$MOUNTS_FILE"
    return 1
}

runtime_tracked_mountpoints() {
    awk '$5 ~ /\/thermal_zone[0-9]+\/temp$/ || $5 ~ /\/power_supply\/.*\/temp$/ || $5 ~ /\/power_supply\/.*\/temperature$/ { print $5 }' /proc/self/mountinfo 2>/dev/null
}

runtime_mounts_complete() {
    local target source target_value source_value target_context source_context expected mounted
    local count=0 expected_count=0 failed=0
    [ -s "$MOUNTS_FILE" ] || return 1
    is_exact_mountpoint "$THERM_FAKE_ROOT" || return 1
    is_exact_mountpoint "$BATTERY_SUPPLY_FAKE_ROOT" || return 1
    is_exact_mountpoint "$BATTERY_INFO_FAKE_ROOT" || return 1

    for expected in $(expected_runtime_targets); do
        expected_count=$((expected_count + 1))
        mount_record_has_target "$expected" || failed=1
    done

    for mounted in $(runtime_tracked_mountpoints); do
        mount_record_has_target "$mounted" || failed=1
    done

    while IFS="$TAB" read -r target source; do
        [ -n "$target" ] && [ -n "$source" ] || {
            failed=1
            continue
        }
        count=$((count + 1))
        is_exact_mountpoint "$target" || {
            failed=1
            continue
        }
        [ -f "$source" ] || {
            failed=1
            continue
        }
        target_value="$(cat "$target" 2>/dev/null | tr -d ' \r\n')"
        source_value="$(cat "$source" 2>/dev/null | tr -d ' \r\n')"
        target_context="$(get_selinux_context "$target")"
        source_context="$(get_selinux_context "$source")"
        [ "$target_value" = "$source_value" ] || failed=1
        [ -n "$source_context" ] && [ "$target_context" = "$source_context" ] || failed=1
    done < "$MOUNTS_FILE"

    [ "$count" -gt 0 ] && [ "$count" -eq "$expected_count" ] && [ "$failed" -eq 0 ]
}

thermal_target_mounts_present() {
    awk '$5 ~ /\/thermal_zone[0-9]+\/temp$/ { found=1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

reconcile_runtime_state() {
    if [ -e "$ACTIVE_FILE" ] && runtime_active_complete; then
        return 0
    fi

    if runtime_mounts_any_present; then
        log WARN "检测到不完整运行时挂载，尝试完整恢复"
        restore_runtime
        return $?
    fi
    if thermal_target_mounts_present; then
        log ERROR "检测到无法追踪的 thermal bind mount；拒绝继续，需重启设备清理"
        return 1
    fi

    if [ -e "$ACTIVE_FILE" ] || [ -e "$MOUNTS_FILE" ]; then
        # bind mount 会在重启后自动消失；清除外置状态目录里的陈旧标记。
        rm -f "$ACTIVE_FILE" "$MOUNTS_FILE" 2>/dev/null
        restore_fake_roots 2>/dev/null || true
        log INFO "检测到重启后的陈旧运行时标记，已清理"
    fi
    return 0
}

bind_fake_value() {
    local target="$1" source_name="$2" value="$3" real source readback
    local target_context source_root source_context
    [ -e "$target" ] || return 1

    case "$source_name" in
        *..* | */* ) log ERROR "非法 source_name: $source_name"; return 1 ;;
    esac

    real="$(readlink -f "$target" 2>/dev/null)"
    [ -n "$real" ] || real="$target"

    if is_exact_mountpoint "$real"; then
        log ERROR "目标已是独立挂载点，拒绝叠加：$real"
        return 1
    fi

    target_context="$(get_selinux_context "$real")"
    source_root="$(fake_root_for_context "$target_context")" || {
        log ERROR "目标 SELinux 标签不在允许清单：$real context=$target_context"
        return 1
    }
    is_exact_mountpoint "$source_root" || {
        log ERROR "伪造文件 context tmpfs 未挂载：$source_root"
        return 1
    }

    source="$source_root/$source_name"
    printf '%s\n' "$value" > "$source" || return 1
    chown 0:0 "$source" 2>/dev/null
    chmod 0444 "$source" 2>/dev/null
    source_context="$(get_selinux_context "$source")"
    [ "$source_context" = "$target_context" ] || {
        log ERROR "伪造文件标签不一致：$source expected=$target_context actual=$source_context"
        rm -f "$source"
        return 1
    }

    mount --bind "$source" "$real" 2>/dev/null || mount -o bind "$source" "$real" 2>/dev/null || {
        log ERROR "bind mount 失败：$source -> $real"
        rm -f "$source"
        return 1
    }

    printf '%s\t%s\n' "$real" "$source" >> "$MOUNTS_FILE" || {
        log ERROR "记录挂载失败，立即回滚：$source -> $real"
        umount "$real" 2>/dev/null
        rm -f "$source"
        return 1
    }
    readback="$(cat "$target" 2>/dev/null | tr -d ' \r\n')"
    [ "$readback" = "$value" ] || {
        log ERROR "挂载后读回不一致：$target expected=$value actual=$readback"
        return 1
    }
    return 0
}

apply_thermal_zones() {
    local zone name type category temp_c temp_milli before mode result mounted=0 skipped=0 failed=0
    : > "$MOUNTS_FILE" || return 1
    printf 'zone\ttype\tcategory\tbefore\tfake\tmode\tresult\n' > "$MAP_FILE" || return 1

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
    local target value res=0

    # 1. 通用电池温度节点
    target="/sys/class/power_supply/battery/temp"
    if [ -e "$target" ]; then
        value=$((BATTERY_TEMP_C * 10))
        bind_fake_value "$target" power_supply_battery_temp "$value" && \
            log INFO "power_supply battery temp 已伪装为 ${BATTERY_TEMP_C}°C" || res=1
    fi

    # 2. MTK 电池温度节点
    target="/sys/class/power_supply/mtk-battery/temp"
    if [ -e "$target" ]; then
        value=$((BATTERY_TEMP_C * 10))
        bind_fake_value "$target" mtk_battery_temp "$value" && \
            log INFO "power_supply mtk-battery temp 已伪装为 ${BATTERY_TEMP_C}°C" || res=1
    fi

    # 3. MTK 电池温度(摄氏度无倍数)节点
    target="/sys/class/power_supply/mtk-battery/temperature"
    if [ -e "$target" ]; then
        value="$BATTERY_TEMP_C"
        bind_fake_value "$target" mtk_battery_temperature "$value" && \
            log INFO "power_supply mtk-battery temperature 已伪装为 ${BATTERY_TEMP_C}°C" || res=1
    fi

    return "$res"
}

apply_power_supply_charger() {
    [ "${CHARGER_ENABLE:-1}" = 1 ] || return 0
    local target value name res=0 charger_temp_c="${CHARGER_TEMP_C:-35}"

    for suffix in master-charger mst-div-charger slave-charger slv-div-charger; do
        target="/sys/class/power_supply/mtk-$suffix/temp"
        [ -e "$target" ] || continue
        value=$((charger_temp_c * 10))
        name="mtk_$(echo "$suffix" | tr '-' '_')_temp"
        bind_fake_value "$target" "$name" "$value" && \
            log INFO "power_supply mtk-$suffix temp 已伪装为 ${charger_temp_c}°C" || res=1
    done

    return "$res"
}

write_shell_temp() {
    local value="$1" i=0
    [ -w /proc/shell-temp ] || return 1
    while [ "$i" -le 7 ]; do
        printf '%s %s\n' "$i" "$value" > /proc/shell-temp 2>/dev/null || return 1
        i=$((i + 1))
    done
    return 0
}

apply_proc_shell_temp() {
    [ "$PROC_SHELL_TEMP_ENABLE" = 1 ] || return 0
    local value=$((SHELL_SKIN_TEMP_C * 1000))
    if write_shell_temp "$value"; then
        log INFO "/proc/shell-temp 0～7 已设置为 ${SHELL_SKIN_TEMP_C}°C"
    else
        log WARN "/proc/shell-temp 不可写，已跳过"
        return 1
    fi
    return 0
}

property_exists() {
    getprop 2>/dev/null | grep -F -q "[$1]:"
}

load_runtime_state_file() {
    local file="${1:-$ORIGINAL_RUNTIME_FILE}" key value delimiter
    RUNTIME_HORAE_PROP_PRESENT=
    RUNTIME_HORAE_PROP=
    RUNTIME_HORAE_STATE=
    RUNTIME_THERMAL_HAL_STATE=
    RUNTIME_THERMAL_CORE_STATE=
    [ -r "$file" ] || return 1

    delimiter="$TAB"
    grep -q "$TAB" "$file" 2>/dev/null || delimiter="="
    while IFS="$delimiter" read -r key value; do
        case "$key" in
            HORAE_PROP_PRESENT) RUNTIME_HORAE_PROP_PRESENT="$value" ;;
            HORAE_PROP) RUNTIME_HORAE_PROP="$value" ;;
            HORAE_STATE) RUNTIME_HORAE_STATE="$value" ;;
            THERMAL_HAL_STATE) RUNTIME_THERMAL_HAL_STATE="$value" ;;
            THERMAL_CORE_STATE) RUNTIME_THERMAL_CORE_STATE="$value" ;;
        esac
    done < "$file"

    if [ -z "$RUNTIME_HORAE_PROP_PRESENT" ]; then
        [ -n "$RUNTIME_HORAE_PROP" ] && RUNTIME_HORAE_PROP_PRESENT=1 || RUNTIME_HORAE_PROP_PRESENT=0
    fi
    case "$RUNTIME_HORAE_PROP_PRESENT" in
        0|1) ;;
        *) log ERROR "Horae 属性备份格式错误"; return 1 ;;
    esac
    for value in "$RUNTIME_HORAE_STATE" "$RUNTIME_THERMAL_HAL_STATE" "$RUNTIME_THERMAL_CORE_STATE"; do
        case "$value" in
            ''|running|stopped) ;;
            *) log ERROR "服务状态备份格式错误：$value"; return 1 ;;
        esac
    done
    return 0
}

backup_runtime_state() {
    local horae_prop_present=0 tmp="$ORIGINAL_RUNTIME_FILE.tmp.$$"
    if [ -f "$ORIGINAL_RUNTIME_FILE" ]; then
        load_runtime_state_file "$ORIGINAL_RUNTIME_FILE" || {
            log ERROR "已有服务状态备份格式无效，拒绝继续覆盖运行状态"
            return 1
        }
        return 0
    fi
    property_exists persist.sys.horae.enable && horae_prop_present=1
    {
        printf 'HORAE_PROP_PRESENT\t%s\n' "$horae_prop_present"
        printf 'HORAE_PROP\t%s\n' "$(getprop persist.sys.horae.enable)"
        printf 'HORAE_STATE\t%s\n' "$(getprop init.svc.horae)"
        printf 'THERMAL_HAL_STATE\t%s\n' "$(getprop init.svc.vendor.thermal-hal-2-0.mtk)"
        printf 'THERMAL_CORE_STATE\t%s\n' "$(getprop init.svc.thermal_core)"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$ORIGINAL_RUNTIME_FILE" || {
        rm -f "$tmp"
        return 1
    }
    return 0
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

restart_init_service() {
    local service="$1" before_pid after_pid state tries=0
    before_pid="$(getprop init.svc_debug_pid."$service")"
    setprop ctl.restart "$service" 2>/dev/null || return 1
    while [ "$tries" -lt 5 ]; do
        sleep 1
        state="$(getprop init.svc."$service")"
        after_pid="$(getprop init.svc_debug_pid."$service")"
        if [ "$state" = running ] && [ -n "$after_pid" ] && \
            { [ -z "$before_pid" ] || [ "$after_pid" != "$before_pid" ]; }; then
            log INFO "服务 $service 已重启：pid $before_pid -> $after_pid"
            return 0
        fi
        tries=$((tries + 1))
    done
    log ERROR "服务 $service 未能确认重启：state=$state pid=$before_pid->$after_pid"
    return 1
}

apply_private_services() {
    local result=0
    backup_runtime_state || {
        log ERROR "备份服务运行状态失败"
        return 1
    }

    if [ "$HORAE_MODE" = stop ]; then
        if command -v resetprop >/dev/null 2>&1; then
            resetprop -n persist.sys.horae.enable 0 2>/dev/null || result=1
        else
            result=1
        fi
        stop_init_service horae || result=1
    fi

    case "$VENDOR_THERMAL_HAL_MODE" in
        stop)
            stop_init_service vendor.thermal-hal-2-0.mtk || result=1
            ;;
        restart)
            restart_init_service vendor.thermal-hal-2-0.mtk || result=1
            ;;
    esac
    if [ "$THERMAL_CORE_MODE" = stop ]; then
        stop_init_service thermal_core || result=1
    fi
    return "$result"
}

verify_runtime() {
    [ "$VERIFY_AFTER_APPLY" = 1 ] || return 0
    local count
    count="$(wc -l < "$MOUNTS_FILE" 2>/dev/null | tr -d ' ')"
    if runtime_mounts_complete; then
        log INFO "验证完成：全部 $count 个挂载点、数值与 SELinux 标签一致"
        return 0
    fi
    log ERROR "验证失败：存在缺失挂载、数值不一致或 SELinux 标签异常"
    return 1
}

service_state_is() {
    [ "$(getprop init.svc."$1" 2>/dev/null)" = "$2" ]
}

services_configured() {
    local result=0
    if [ "$HORAE_MODE" = stop ]; then
        [ "$(getprop persist.sys.horae.enable 2>/dev/null)" = 0 ] || result=1
        service_state_is horae stopped || result=1
    fi
    case "$VENDOR_THERMAL_HAL_MODE" in
        stop) service_state_is vendor.thermal-hal-2-0.mtk stopped || result=1 ;;
        restart) service_state_is vendor.thermal-hal-2-0.mtk running || result=1 ;;
    esac
    if [ "$THERMAL_CORE_MODE" = stop ]; then
        service_state_is thermal_core stopped || result=1
    fi
    return "$result"
}

restart_adbd() {
    stop_init_service adbd || return 1
    start_init_service adbd || return 1
    return 0
}

adb_port_listening() {
    local port="$1" port_hex
    is_uint_range "$port" 1 65535 || return 1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v port=":$port" '{
            for (i = 1; i <= NF; i++) {
                if ($i ~ port "$") found=1
            }
        } END { exit !found }' && return 0
    fi
    port_hex="$(awk -v port="$port" 'BEGIN { printf "%04X", port }' 2>/dev/null)"
    [ -n "$port_hex" ] || return 1
    awk -v port_hex="$port_hex" '
        $2 ~ ":" port_hex "$" && $4 == "0A" { found=1 }
        END { exit !found }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

wait_adb_port_listening() {
    local port="$1" tries=0
    while [ "$tries" -lt 5 ]; do
        adb_port_listening "$port" && return 0
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

wait_adb_port_closed() {
    local port="$1" tries=0
    while [ "$tries" -lt 5 ]; do
        adb_port_listening "$port" || return 0
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

adb_wifi_configured() {
    local port="${ADB_WIFI_PORT:-5555}"
    if [ "$ADB_WIFI_ENABLE" = 1 ]; then
        [ "$(getprop service.adb.tcp.port 2>/dev/null)" = "$port" ] || return 1
        adb_port_listening "$port" || return 1
        return 0
    fi
    [ -z "$(getprop service.adb.tcp.port 2>/dev/null)" ] || return 1
    adb_port_listening "$port" && return 1
    return 0
}

runtime_active_complete() {
    runtime_mounts_complete || return 1
    services_configured || return 1
    adb_wifi_configured || return 1
    return 0
}

enable_adb_wifi() {
    local port="${ADB_WIFI_PORT:-5555}"
    command -v resetprop >/dev/null 2>&1 || {
        log ERROR "未找到 resetprop 工具，无法开启无线调试"
        return 1
    }
    resetprop service.adb.tcp.port "$port" 2>/dev/null || return 1
    restart_adbd || return 1
    [ "$(getprop service.adb.tcp.port)" = "$port" ] || {
        log ERROR "无线调试端口设置验证失败"
        return 1
    }
    wait_adb_port_listening "$port" || {
        log ERROR "无线调试端口未监听：$port"
        return 1
    }
    log INFO "已开启无线调试端口 $port"
    return 0
}

disable_adb_wifi() {
    local port="${ADB_WIFI_PORT:-5555}" old_port
    old_port="$(getprop service.adb.tcp.port 2>/dev/null)"
    command -v resetprop >/dev/null 2>&1 || {
        log ERROR "未找到 resetprop 工具，无法关闭无线调试"
        return 1
    }
    resetprop --delete service.adb.tcp.port 2>/dev/null || {
        [ -z "$(getprop service.adb.tcp.port)" ] || return 1
    }
    restart_adbd || return 1
    [ -z "$(getprop service.adb.tcp.port)" ] || {
        log ERROR "无线调试端口清理验证失败"
        return 1
    }
    wait_adb_port_closed "$port" || {
        log ERROR "无线调试端口仍在监听：$port"
        return 1
    }
    if [ -n "$old_port" ] && [ "$old_port" != "$port" ]; then
        wait_adb_port_closed "$old_port" || {
            log ERROR "无线调试旧端口仍在监听：$old_port"
            return 1
        }
    fi
    log INFO "已关闭无线调试"
    return 0
}

apply_adb_wifi() {
    if [ "$ADB_WIFI_ENABLE" = 1 ]; then
        enable_adb_wifi
    else
        disable_adb_wifi
    fi
}

apply_runtime() {
    local result=0
    load_config
    is_bool "$MASTER_ENABLE" || {
        log ERROR "配置错误：MASTER_ENABLE 必须为 0 或 1，当前为 $MASTER_ENABLE"
        return 1
    }
    [ "$MASTER_ENABLE" = 1 ] || {
        log INFO "MASTER_ENABLE=0，不应用伪装"
        restore_runtime || result=1
        disable_adb_wifi || result=1
        return "$result"
    }
    [ ! -e "$DISABLED_FILE" ] || {
        log INFO "检测到用户运行时禁用标记，不应用伪装"
        restore_runtime || result=1
        disable_adb_wifi || result=1
        return "$result"
    }
    validate_config || return 1
    reconcile_runtime_state || return 1
    if [ -e "$ACTIVE_FILE" ] && runtime_active_complete; then
        log INFO "当前运行时挂载、服务与无线调试状态均已生效，无需重复应用"
        return 0
    fi
    device_guard || return 1
    check_conflicts || return 1
    wait_for_thermal_zones || return 1

    restore_fake_roots 2>/dev/null || true
    rm -f "$ACTIVE_FILE" "$MOUNTS_FILE" "$MAP_FILE" 2>/dev/null
    prepare_fake_roots || {
        log ERROR "伪造文件 context tmpfs 初始化失败"
        return 1
    }

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
    apply_power_supply_charger || {
        log ERROR "power_supply charger 应用失败，开始回滚"
        restore_mounts
        return 1
    }
    verify_runtime || {
        log ERROR "运行时验证失败，开始回滚"
        restore_mounts
        return 1
    }
    apply_proc_shell_temp || {
        log ERROR "/proc/shell-temp 应用失败，开始回滚"
        restore_mounts
        write_shell_temp 0 2>/dev/null || true
        return 1
    }
    apply_private_services || {
        log ERROR "厂商私有温控服务未按配置切换，开始回滚"
        restore_runtime
        return 1
    }
    apply_adb_wifi || {
        log ERROR "无线调试未达到配置状态，开始回滚"
        restore_runtime
        disable_adb_wifi 2>/dev/null || true
        return 1
    }

    if ! date '+%Y-%m-%d %H:%M:%S' > "$ACTIVE_FILE.tmp.$$" || \
        ! mv -f "$ACTIVE_FILE.tmp.$$" "$ACTIVE_FILE"; then
        rm -f "$ACTIVE_FILE.tmp.$$"
        log ERROR "写入 active 状态失败，开始回滚"
        restore_runtime
        disable_adb_wifi 2>/dev/null || true
        return 1
    fi
    log INFO "模块应用完成；本脚本为一次性执行，不驻留后台"
    return 0
}

restore_mounts() {
    local target source result=0
    RESTORE_MOUNTS_LAZY_USED=0
    if [ -f "$MOUNTS_FILE" ]; then
        while IFS="$TAB" read -r target source; do
            [ -n "$target" ] && [ -n "$source" ] || {
                result=1
                continue
            }
            if ! unmount_exact "$target"; then
                result=1
            fi
        done < "$MOUNTS_FILE"
        if [ "$result" -ne 0 ]; then
            log ERROR "部分 bind mount 卸载失败，已保留完整追踪记录"
            return 1
        fi
        rm -f "$MOUNTS_FILE"
    fi
    restore_fake_roots || {
        log ERROR "SELinux context tmpfs 卸载失败"
        return 1
    }
    return 0
}

restore_runtime_services() {
    local force_restart="${1:-0}" result=0
    [ -r "$ORIGINAL_RUNTIME_FILE" ] || return 0

    load_runtime_state_file "$ORIGINAL_RUNTIME_FILE" || return 1

    if command -v resetprop >/dev/null 2>&1; then
        if [ "$RUNTIME_HORAE_PROP_PRESENT" = 1 ]; then
            resetprop -n persist.sys.horae.enable "$RUNTIME_HORAE_PROP" 2>/dev/null || result=1
        else
            resetprop --delete persist.sys.horae.enable 2>/dev/null || result=1
        fi
    else
        result=1
    fi
    if [ "$RUNTIME_HORAE_STATE" = running ]; then
        if [ "$force_restart" = 1 ]; then restart_init_service horae || result=1; else start_init_service horae || result=1; fi
    fi
    if [ "$RUNTIME_HORAE_STATE" = stopped ]; then stop_init_service horae || result=1; fi
    if [ "$RUNTIME_THERMAL_HAL_STATE" = running ]; then
        if [ "$force_restart" = 1 ]; then restart_init_service vendor.thermal-hal-2-0.mtk || result=1; else start_init_service vendor.thermal-hal-2-0.mtk || result=1; fi
    fi
    if [ "$RUNTIME_THERMAL_HAL_STATE" = stopped ]; then stop_init_service vendor.thermal-hal-2-0.mtk || result=1; fi
    if [ "$RUNTIME_THERMAL_CORE_STATE" = running ]; then
        if [ "$force_restart" = 1 ]; then restart_init_service thermal_core || result=1; else start_init_service thermal_core || result=1; fi
    fi
    if [ "$RUNTIME_THERMAL_CORE_STATE" = stopped ]; then stop_init_service thermal_core || result=1; fi

    if [ "$result" -eq 0 ]; then
        rm -f "$ORIGINAL_RUNTIME_FILE"
    else
        log ERROR "部分服务恢复失败，保留原始状态文件以便重试"
    fi
    return "$result"
}

restore_runtime() {
    local result=0 mounts_restored=0 force_service_restart=0
    if restore_mounts; then
        mounts_restored=1
        rm -f "$ACTIVE_FILE"
        [ "${RESTORE_MOUNTS_LAZY_USED:-0}" = 1 ] && force_service_restart=1
    else
        result=1
    fi
    if [ -e /proc/shell-temp ] && ! write_shell_temp 0; then
        log ERROR "/proc/shell-temp 恢复失败"
        result=1
    fi
    restore_runtime_services "$force_service_restart" || result=1
    if [ "$result" -eq 0 ]; then
        log INFO "运行时状态已恢复"
    else
        [ "$mounts_restored" -eq 1 ] || log ERROR "运行时挂载仍有残留"
        log ERROR "运行时状态仅部分恢复，已保留失败状态供重试"
    fi
    return "$result"
}

process_start_time() {
    awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

write_lock_owner() {
    local start_time
    start_time="$(process_start_time "$$")"
    [ -n "$start_time" ] || return 1
    printf '%s\t%s\n' "$$" "$start_time" > "$LOCK_DIR/pid"
}

lock_owner_alive() {
    local owner_pid owner_start actual_start
    IFS="$TAB" read -r owner_pid owner_start < "$LOCK_DIR/pid" 2>/dev/null || return 1
    case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$owner_pid" 2>/dev/null || return 1
    # 旧版锁只有 PID；无法排除 PID 复用时保守视为仍被持有。
    [ -n "$owner_start" ] || return 0
    actual_start="$(process_start_time "$owner_pid")"
    [ -n "$actual_start" ] && [ "$actual_start" = "$owner_start" ]
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_owner || {
            rm -rf "$LOCK_DIR" 2>/dev/null
            return 1
        }
        return 0
    fi
    lock_owner_alive && return 1
    log WARN "清理已失效的陈旧锁"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    write_lock_owner || {
        rm -rf "$LOCK_DIR" 2>/dev/null
        return 1
    }
    return 0
}

release_lock() {
    local owner_pid owner_start current_start
    IFS="$TAB" read -r owner_pid owner_start < "$LOCK_DIR/pid" 2>/dev/null || return 0
    [ "$owner_pid" = "$$" ] || return 0
    current_start="$(process_start_time "$$")"
    [ -n "$owner_start" ] && [ "$owner_start" = "$current_start" ] || return 0
    rm -rf "$LOCK_DIR" 2>/dev/null
}
