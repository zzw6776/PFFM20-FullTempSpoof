#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/shell-bootstrap.sh" || exit 1
STATE_DIR="/data/adb/coloros_fulltempspoof"
FAKE_ROOT="/dev/coloros_fulltempspoof"
result=0
used_common=0
lock_acquired=0

if [ -r "$MODDIR/common.sh" ]; then
    . "$MODDIR/common.sh"
    used_common=1
    if acquire_lock; then
        lock_acquired=1
        install_lock_signal_traps
        restore_runtime || result=1
    else
        log ERROR "卸载时无法获取运行锁，保留运行时状态供重试"
        result=1
    fi
else
    # Fallback：common.sh 不可读时，仍按固定路径清理所有运行时资源。
    MOUNTS_FILE="$STATE_DIR/mounts.tsv"
    ORIGINAL_RUNTIME_FILE="$STATE_DIR/original-runtime.conf"
    TEMP_FD_CONSUMERS_FILE="$STATE_DIR/temp-fd-consumers.tsv"
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

    runtime_mountpoints_fallback() {
        awk -v prefix="$FAKE_ROOT/" '
            {
                device[NR] = $3
                target[NR] = $5
                if (index($5, prefix) == 1) {
                    fake_device[$3] = 1
                    fake_root[$5] = 1
                }
            }
            END {
                count = 0
                for (i = 1; i <= NR; i++) {
                    if ((device[i] in fake_device) && !(target[i] in fake_root)) {
                        candidate[++count] = target[i]
                    }
                }
                for (i = 1; i <= count; i++) {
                    for (j = i + 1; j <= count; j++) {
                        if (length(candidate[j]) > length(candidate[i])) {
                            swap = candidate[i]
                            candidate[i] = candidate[j]
                            candidate[j] = swap
                        }
                    }
                }
                for (i = 1; i <= count; i++) print candidate[i]
            }
        ' /proc/self/mountinfo 2>/dev/null
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

    restore_temp_fd_consumers_fallback() {
        [ -s "$TEMP_FD_CONSUMERS_FILE" ] || return 0

        current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')"
        [ -n "$current_boot" ] || return 1

        restore_thermal_engine=0
        restore_qti_thermal_engine=0
        while IFS="$TAB" read -r service recorded_boot extra; do
            [ -z "$extra" ] || return 1
            case "$service" in
                thermal-engine)
                    [ -n "$recorded_boot" ] || return 1
                    [ "$recorded_boot" = "$current_boot" ] && restore_thermal_engine=1
                    ;;
                qti.thermal-engine)
                    [ -n "$recorded_boot" ] || return 1
                    [ "$recorded_boot" = "$current_boot" ] && restore_qti_thermal_engine=1
                    ;;
                *) return 1 ;;
            esac
        done < "$TEMP_FD_CONSUMERS_FILE"

        consumer_result=0
        for service in thermal-engine qti.thermal-engine; do
            case "$service" in
                thermal-engine) [ "$restore_thermal_engine" = 1 ] || continue ;;
                qti.thermal-engine) [ "$restore_qti_thermal_engine" = 1 ] || continue ;;
            esac
            state="$(getprop init.svc."$service" 2>/dev/null)"
            case "$state" in
                running) restart_service_fallback "$service" || consumer_result=1 ;;
                stopped|'') ;;
                *) consumer_result=1 ;;
            esac
        done

        [ "$consumer_result" -eq 0 ] && rm -f "$TEMP_FD_CONSUMERS_FILE"
        return "$consumer_result"
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
        DYNAMIC_SERVICE_FOUND=0
        while IFS="$delimiter" read -r key value extra; do
            case "$key" in
                HORAE_PROP_PRESENT) HORAE_PROP_PRESENT="$value" ;;
                HORAE_PROP) HORAE_PROP="$value" ;;
                HORAE_STATE) HORAE_STATE="$value" ;;
                THERMAL_HAL_STATE) THERMAL_HAL_STATE="$value" ;;
                THERMAL_CORE_STATE) THERMAL_CORE_STATE="$value" ;;
                SERVICE_STATE)
                    DYNAMIC_SERVICE_FOUND=1
                    case "$value" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
                    case "$extra" in running|stopped) ;; *) return 1 ;; esac
                    ;;
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
        if [ "$DYNAMIC_SERVICE_FOUND" = 1 ]; then
            while IFS="$delimiter" read -r key value extra; do
                [ "$key" = SERVICE_STATE ] || continue
                restore_service_state_fallback "$value" "$extra" || service_result=1
            done < "$ORIGINAL_RUNTIME_FILE"
        else
            restore_service_state_fallback horae "$HORAE_STATE" || service_result=1
            restore_service_state_fallback vendor.thermal-hal-2-0.mtk "$THERMAL_HAL_STATE" || service_result=1
            restore_service_state_fallback thermal_core "$THERMAL_CORE_STATE" || service_result=1
        fi
        [ "$service_result" -eq 0 ] && rm -f "$ORIGINAL_RUNTIME_FILE"
        return "$service_result"
    }

    mount_result=0
    if [ -f "$MOUNTS_FILE" ]; then
        while IFS="$TAB" read -r target source; do
            [ -n "$target" ] && [ -n "$source" ] || {
                mount_result=1
                continue
            }
            unmount_exact_fallback "$target" || mount_result=1
        done < "$MOUNTS_FILE"
    fi

    residual_list="$STATE_DIR/uninstall-residual-mounts.$$"
    runtime_mountpoints_fallback > "$residual_list" 2>/dev/null
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        unmount_exact_fallback "$target" || mount_result=1
    done < "$residual_list"
    rm -f "$residual_list" 2>/dev/null
    runtime_mountpoints_fallback | awk 'NF { found=1; exit } END { exit !found }' && mount_result=1
    [ "$mount_result" -ne 0 ] || rm -f "$MOUNTS_FILE"
    [ "$mount_result" -eq 0 ] || result=1

    for dir in "$FAKE_ROOT"/*; do
        [ -d "$dir" ] || continue
        if ! unmount_exact_fallback "$dir"; then
            mount_result=1
            result=1
        fi
    done

    if [ "$mount_result" -eq 0 ]; then
        restore_temp_fd_consumers_fallback || result=1
    else
        result=1
    fi

    # common.sh 缺失时也不得将 Horae 温度发布槽清零；未知同名驱动同样不试写。
    if [ -w /proc/shell-temp ] && [ ! -d /sys/module/horae_shell_temp ]; then
        i=0
        while [ "$i" -le 7 ]; do
            printf '%s %s\n' "$i" 0 > /proc/shell-temp 2>/dev/null || result=1
            i=$((i + 1))
        done
    fi

    restore_runtime_services_fallback || result=1
fi

# DTBO 是持久修改：逐槽位恢复所有仍由本模块持有的镜像；任何槽位无法确认时都保留救援目录。
if [ "$lock_acquired" -ne 1 ]; then
    if [ "$used_common" -eq 1 ]; then
        log ERROR "卸载时未持有运行锁，跳过 DTBO 恢复并保留救援目录"
    else
        echo "卸载时无法建立可靠运行锁，跳过 DTBO 恢复并保留救援目录" >&2
    fi
    result=1
elif [ -r "$MODDIR/charging_dtbo.sh" ]; then
    CHARGING_MODDIR="$MODDIR"
    . "$MODDIR/charging_dtbo.sh"
    if charging_restore_all_owned; then
        if charging_has_unresolved_rescue_artifacts; then
            log ERROR "卸载后仍存在未解决的 DTBO 准备/回滚文件，保留整个救援目录"
            result=1
        fi
    else
        result=1
    fi
else
    for rescue_file in "$MODDIR/original_dtbo.img" "$MODDIR/charging_state.conf" \
        "$STATE_DIR/dtbo-rescue" "$STATE_DIR/dtbo-rescue"/*; do
        [ -e "$rescue_file" ] || continue
        [ "$used_common" -eq 1 ] && log ERROR "charging_dtbo.sh 缺失，无法安全恢复 DTBO"
        result=1
        break
    done
fi

if [ "$result" -eq 0 ]; then
    rm -rf "$FAKE_ROOT" 2>/dev/null
    # flock 锁住的是 inode，持锁时删除 lock.v2 或兼容期旧 lock 文件会允许
    # 其他进程在同一路径创建新 inode。因此保留锁文件，只清理其余模块状态；
    # EXIT trap 最后关闭 FD，由内核释放锁。
    for state_item in "$STATE_DIR"/*; do
        [ -e "$state_item" ] || continue
        case "$state_item" in
            "$LOCK_FILE"|"$LOCK_OWNER_FILE"|"$LEGACY_LOCK_PATH"|"$LEGACY_LOCK_OWNER_FILE"|\
            "$PFFM_LEGACY_DIR_TARGET") continue ;;
        esac
        rm -rf "$state_item" 2>/dev/null || result=1
    done
fi

if [ "$result" -eq 0 ]; then
    exit 0
fi

if [ "$used_common" -eq 1 ]; then
    log ERROR "卸载清理未完成，已保留状态文件以便重试或重启后检查"
fi
exit 1
