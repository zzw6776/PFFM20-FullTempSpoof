#!/system/bin/sh

MODDIR="${0%/*}"
STATE_DIR="/data/adb/pffm20_fulltempspoof"
FAKE_ROOT="/dev/pffm20_fulltempspoof"
result=0
used_common=0

if [ -r "$MODDIR/common.sh" ]; then
    . "$MODDIR/common.sh"
    used_common=1
    if acquire_lock; then
        trap 'release_lock' EXIT
        restore_runtime || result=1
        disable_adb_wifi || result=1
    else
        log ERROR "卸载时无法获取运行锁，保留运行时状态供重试"
        result=1
    fi
else
    # Fallback：common.sh 不可读时，仍按固定路径清理所有运行时资源。
    MOUNTS_FILE="$STATE_DIR/mounts.tsv"
    ORIGINAL_RUNTIME_FILE="$STATE_DIR/original-runtime.conf"
    TAB="$(printf '\t')"
    LAZY_UNMOUNT_USED=0

    is_exact_mountpoint_fallback() {
        awk -v target="$1" '$5 == target { found=1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
    }

    unmount_exact_fallback() {
        target="$1"
        is_exact_mountpoint_fallback "$target" || return 0
        if umount "$target" 2>/dev/null; then
            ! is_exact_mountpoint_fallback "$target"
            return $?
        fi
        umount -l "$target" 2>/dev/null || return 1
        LAZY_UNMOUNT_USED=1
        ! is_exact_mountpoint_fallback "$target"
    }

    stop_service_fallback() {
        service="$1"
        tries=0
        setprop ctl.stop "$service" 2>/dev/null || return 1
        while [ "$tries" -lt 5 ]; do
            sleep 1
            [ "$(getprop init.svc."$service" 2>/dev/null)" = stopped ] && return 0
            tries=$((tries + 1))
        done
        return 1
    }

    start_service_fallback() {
        service="$1"
        tries=0
        setprop ctl.start "$service" 2>/dev/null || return 1
        while [ "$tries" -lt 5 ]; do
            sleep 1
            [ "$(getprop init.svc."$service" 2>/dev/null)" = running ] && return 0
            tries=$((tries + 1))
        done
        return 1
    }

    restart_service_fallback() {
        service="$1"
        before_pid="$(getprop init.svc_debug_pid."$service" 2>/dev/null)"
        tries=0
        setprop ctl.restart "$service" 2>/dev/null || return 1
        while [ "$tries" -lt 5 ]; do
            sleep 1
            after_pid="$(getprop init.svc_debug_pid."$service" 2>/dev/null)"
            if [ "$(getprop init.svc."$service" 2>/dev/null)" = running ] && \
                [ -n "$after_pid" ] && { [ -z "$before_pid" ] || [ "$after_pid" != "$before_pid" ]; }; then
                return 0
            fi
            tries=$((tries + 1))
        done
        return 1
    }

    restore_service_state_fallback() {
        service="$1"
        state="$2"
        case "$state" in
            running)
                if [ "$LAZY_UNMOUNT_USED" = 1 ]; then
                    restart_service_fallback "$service"
                else
                    start_service_fallback "$service"
                fi
                ;;
            stopped) stop_service_fallback "$service" ;;
            '') return 0 ;;
            *) return 1 ;;
        esac
    }

    restore_runtime_services_fallback() {
        [ -r "$ORIGINAL_RUNTIME_FILE" ] || return 0
        delimiter="$TAB"
        grep -q "$TAB" "$ORIGINAL_RUNTIME_FILE" 2>/dev/null || delimiter="="
        HORAE_PROP_PRESENT=
        HORAE_PROP=
        HORAE_STATE=
        THERMAL_HAL_STATE=
        THERMAL_CORE_STATE=
        while IFS="$delimiter" read -r key value; do
            case "$key" in
                HORAE_PROP_PRESENT) HORAE_PROP_PRESENT="$value" ;;
                HORAE_PROP) HORAE_PROP="$value" ;;
                HORAE_STATE) HORAE_STATE="$value" ;;
                THERMAL_HAL_STATE) THERMAL_HAL_STATE="$value" ;;
                THERMAL_CORE_STATE) THERMAL_CORE_STATE="$value" ;;
            esac
        done < "$ORIGINAL_RUNTIME_FILE"

        if [ -z "$HORAE_PROP_PRESENT" ]; then
            [ -n "$HORAE_PROP" ] && HORAE_PROP_PRESENT=1 || HORAE_PROP_PRESENT=0
        fi
        case "$HORAE_PROP_PRESENT" in 0|1) ;; *) return 1 ;; esac
        for state in "$HORAE_STATE" "$THERMAL_HAL_STATE" "$THERMAL_CORE_STATE"; do
            case "$state" in ''|running|stopped) ;; *) return 1 ;; esac
        done

        service_result=0
        if command -v resetprop >/dev/null 2>&1; then
            if [ "$HORAE_PROP_PRESENT" = 1 ]; then
                resetprop -n persist.sys.horae.enable "$HORAE_PROP" 2>/dev/null || service_result=1
            else
                resetprop --delete persist.sys.horae.enable 2>/dev/null || service_result=1
            fi
        else
            service_result=1
        fi
        restore_service_state_fallback horae "$HORAE_STATE" || service_result=1
        restore_service_state_fallback vendor.thermal-hal-2-0.mtk "$THERMAL_HAL_STATE" || service_result=1
        restore_service_state_fallback thermal_core "$THERMAL_CORE_STATE" || service_result=1
        [ "$service_result" -eq 0 ] && rm -f "$ORIGINAL_RUNTIME_FILE"
        return "$service_result"
    }

    if [ -f "$MOUNTS_FILE" ]; then
        while IFS="$TAB" read -r target source; do
            [ -n "$target" ] && [ -n "$source" ] || {
                result=1
                continue
            }
            unmount_exact_fallback "$target" || result=1
        done < "$MOUNTS_FILE"
        [ "$result" -ne 0 ] || rm -f "$MOUNTS_FILE"
    fi

    for dir in \
        "$FAKE_ROOT/sysfs_batteryinfo" \
        "$FAKE_ROOT/sysfs_battery_supply" \
        "$FAKE_ROOT/sysfs_therm"; do
        if ! unmount_exact_fallback "$dir"; then
            result=1
        fi
    done

    if [ -w /proc/shell-temp ]; then
        i=0
        while [ "$i" -le 7 ]; do
            printf '%s %s\n' "$i" 0 > /proc/shell-temp 2>/dev/null || result=1
            i=$((i + 1))
        done
    fi

    if command -v resetprop >/dev/null 2>&1; then
        resetprop --delete service.adb.tcp.port 2>/dev/null || {
            [ -z "$(getprop service.adb.tcp.port)" ] || result=1
        }
        setprop ctl.stop adbd 2>/dev/null || result=1
        sleep 1
        setprop ctl.start adbd 2>/dev/null || result=1
        sleep 1
        [ -z "$(getprop service.adb.tcp.port)" ] || result=1
    else
        result=1
    fi

    restore_runtime_services_fallback || result=1
fi

if [ "$result" -eq 0 ]; then
    rm -rf "$FAKE_ROOT" 2>/dev/null
    rm -rf "$STATE_DIR" 2>/dev/null
    exit 0
fi

if [ "$used_common" -eq 1 ]; then
    log ERROR "卸载清理未完成，已保留状态文件以便重试或重启后检查"
fi
exit 1
