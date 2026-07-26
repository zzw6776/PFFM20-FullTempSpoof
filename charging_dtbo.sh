#!/system/bin/sh

# PJZ110 Android 15 charging DTBO patcher.
# This file only defines functions; callers decide whether to apply or restore.

CHARGING_MODDIR="${CHARGING_MODDIR:-${MODPATH:-${MODDIR:-${0%/*}}}}"
CHARGING_FDTGET="${CHARGING_FDTGET:-$CHARGING_MODDIR/bin/fdtget}"
CHARGING_FDTPUT="${CHARGING_FDTPUT:-$CHARGING_MODDIR/bin/fdtput}"
CHARGING_MKDTIMG="${CHARGING_MKDTIMG:-$CHARGING_MODDIR/bin/mkdtimg}"
CHARGING_AVB_HELPER="${CHARGING_AVB_HELPER:-$CHARGING_MODDIR/avb_dtbo.sh}"
CHARGING_PPS_CELLS="${CHARGING_PPS_CELLS:-$CHARGING_MODDIR/charging/pps55.cells}"
CHARGING_PD_QC_FCC_CELLS="${CHARGING_PD_QC_FCC_CELLS:-$CHARGING_MODDIR/charging/pdqc27-fcc.cells}"
CHARGING_RESCUE_DIR="${CHARGING_RESCUE_DIR:-/data/adb/coloros_fulltempspoof/dtbo-rescue}"
# 这两个哈希来自项目内 rescue/PJZ110-A77 的实机只读备份。独立“原始备份”
# 只接受已知原厂镜像；不能仅凭“当前没有模块状态”就把任意 DTBO 定义成原始。
CHARGING_TRUSTED_ORIGINAL_A_SHA256="${CHARGING_TRUSTED_ORIGINAL_A_SHA256:-d02115e11e519a0ad1d03fdf05f491baed409a9f7a05ff83cf4907b3d1d39ec5}"
CHARGING_TRUSTED_ORIGINAL_B_SHA256="${CHARGING_TRUSTED_ORIGINAL_B_SHA256:-95aeaae03b56c171cf88753c821630a3c24f1fcf406cec3e17d56781aa3f8369}"
CHARGING_TRUSTED_ORIGINAL_SIZE="${CHARGING_TRUSTED_ORIGINAL_SIZE:-25165824}"
CHARGING_BATTERY_UNLOCKER_MODULE_DIR="${CHARGING_BATTERY_UNLOCKER_MODULE_DIR:-/data/adb/modules/battery_unlocker}"
CHARGING_BATTERY_UNLOCKER_UPDATE_DIR="${CHARGING_BATTERY_UNLOCKER_UPDATE_DIR:-/data/adb/modules_update/battery_unlocker}"
CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT="${CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT:-/data/adb/op13_battery_unlocker/dtbo-rescue}"
CHARGING_API_VERSION=3
CHARGING_CANDIDATE_VERIFICATION_SCHEME=semantic-v3
CHARGING_PREPARE_OUTCOME=
CHARGING_SELECTED_SLOT=
CHARGING_BACKUP=
CHARGING_STATE_FILE=
CHARGING_BACKUP_PENDING=
CHARGING_STATE_PENDING=
CHARGING_BACKUP_PREVIOUS=
CHARGING_STATE_PREVIOUS=
CHARGING_OPERATION_FILE=
CHARGING_RESTORE_PLAN="$CHARGING_RESCUE_DIR/restore_plan.conf"
CHARGING_PREPARED_DIR=
CHARGING_PREPARED_STATE=
CHARGING_PREPARED_BASE=
CHARGING_PREPARED_RAW=
CHARGING_PREPARED_IMAGE=
CHARGING_PREPARED_ROLLBACK=
CHARGING_REBOOT_REQUIRED=0
CHARGING_RESCUE_REQUIRED=0
CHARGING_OPERATION_PHASE=
CHARGING_OPERATION_BOOT_ID=
CHARGING_OPERATION_DETAIL=
CHARGING_OPERATION_OWNER_PID=
CHARGING_OPERATION_OWNER_START=
CHARGING_PARTITION_CRITICAL=0
CHARGING_AVB_HELPER_LOADED=0
CHARGING_STATE_FORMAT=
CHARGING_STATE_VALID=0
CHARGING_STATE_BASELINE_ONLY=0
CHARGING_STATE_PREVIOUS_PATCHED_HASH=
CHARGING_STATE_PREVIOUS_PPS55=0
CHARGING_STATE_PREVIOUS_PD_QC_27W=0
CHARGING_MATCHED_PPS55=0
CHARGING_MATCHED_PD_QC_27W=0
CHARGING_PREPARED_PRESENT=0
CHARGING_PREPARED_SAFE=0
CHARGING_PREPARED_PROBLEM=0
CHARGING_PREPARED_PROBLEM_DETAIL=
CHARGING_CANDIDATE_INTEGRITY_VALID=0
CHARGING_CANDIDATE_CONTEXT_VALID=0
CHARGING_CANDIDATE_LIVE_MATCH=0
CHARGING_CANDIDATE_READY=0
CHARGING_CANDIDATE_RELATION=unavailable
CHARGING_CANDIDATE_ISSUE_KIND=
CHARGING_PREPARED_CONFIG_HASH=
CHARGING_PREPARED_RECIPE_HASH=
CHARGING_PREPARED_FINGERPRINT_HASH=
CHARGING_PREPARED_GENERATED_AT=
CHARGING_PREPARED_VERIFICATION=
CHARGING_PREPARED_VERIFIED_HASH=
CHARGING_PREPARED_VERIFIED_AT=
CHARGING_BACKUP_SLOT_RESULT=
CHARGING_BACKUP_CREATED_SLOTS=
CHARGING_BACKUP_VERIFIED_SLOTS=
CHARGING_BACKUP_FAILED_SLOTS=

if [ -r "$CHARGING_AVB_HELPER" ] && . "$CHARGING_AVB_HELPER"; then
    CHARGING_AVB_HELPER_LOADED=1
fi

charging_msg() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$*"
    else
        printf '%s\n' "$*"
    fi
}

charging_timestamp() {
    local value
    value="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || value=
    [ -n "$value" ] || value="time-unavailable"
    printf '%s\n' "$value"
}

charging_epoch_seconds() {
    local value
    value="$(date '+%s' 2>/dev/null)" || return 1
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

charging_elapsed_seconds() {
    local started="$1" now
    case "$started" in ''|*[!0-9]*) return 1 ;; esac
    now="$(charging_epoch_seconds)" || return 1
    [ "$now" -ge "$started" ] || return 1
    printf '%s\n' "$((now - started))"
}

charging_progress() {
    local timestamp
    timestamp="$(charging_timestamp)"
    charging_msg "[$timestamp] $*"
}

charging_progress_elapsed() {
    local started="$1" elapsed
    shift
    elapsed="$(charging_elapsed_seconds "$started" 2>/dev/null)" || elapsed=
    if [ -n "$elapsed" ]; then
        charging_progress "$*（已用时 ${elapsed} 秒）"
    else
        charging_progress "$*"
    fi
}

charging_progress_checkpoint() {
    local current="$1" total="$2" interval="${3:-25}"
    case "$current:$total:$interval" in *[!0-9:]*) return 1 ;; esac
    [ "$current" -gt 0 ] && [ "$current" -le "$total" ] && [ "$interval" -gt 0 ] || return 1
    [ "$current" -eq "$total" ] || [ $((current % interval)) -eq 0 ]
}

charging_parameter_row_count() {
    awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$1" 2>/dev/null
}

charging_log() {
    local level="$1"
    shift
    if [ -n "${LOG_FILE:-}" ] && command -v log >/dev/null 2>&1; then
        log "$level" "$*"
    fi
}

charging_fail() {
    charging_msg "! $*"
    charging_log ERROR "$*"
    return 1
}

charging_is_bool() {
    [ "$1" = 0 ] || [ "$1" = 1 ]
}

charging_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

charging_stream_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

charging_config_hash() {
    [ -r "${CONFIG_FILE:-}" ] || return 1
    charging_sha256 "$CONFIG_FILE"
}

charging_system_fingerprint_hash() {
    local fingerprint
    fingerprint="$(getprop ro.build.fingerprint 2>/dev/null)"
    [ -n "$fingerprint" ] || return 1
    printf '%s' "$fingerprint" | charging_stream_sha256
}

charging_recipe_hash() {
    local path hash combined=
    for path in \
        "$CHARGING_MODDIR/charging_dtbo.sh" \
        "$CHARGING_AVB_HELPER" \
        "$CHARGING_PPS_CELLS" \
        "$CHARGING_PD_QC_FCC_CELLS" \
        "$CHARGING_FDTGET" \
        "$CHARGING_FDTPUT" \
        "$CHARGING_MKDTIMG"; do
        [ -r "$path" ] || return 1
        hash="$(charging_sha256 "$path")" || return 1
        charging_is_sha256_value "$hash" || return 1
        combined="${combined}${hash}"
    done
    printf '%s' "$combined" | charging_stream_sha256
}

charging_file_size() {
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

charging_active_slot() {
    local slot
    slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
    if [ -z "$slot" ]; then
        slot="$(getprop ro.boot.slot 2>/dev/null)"
        [ -n "$slot" ] && slot="_$slot"
    fi
    case "$slot" in
        _a|_b) printf '%s\n' "$slot" ;;
        *) return 1 ;;
    esac
}

charging_dtbo_partition() {
    local slot="$1" path
    for path in \
        "/dev/block/bootdevice/by-name/dtbo${slot}" \
        "/dev/block/by-name/dtbo${slot}"; do
        if [ -e "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

charging_select_slot_state() {
    local slot="$1" suffix
    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    [ "$CHARGING_SELECTED_SLOT" = "$slot" ] || CHARGING_STATE_VALID=0
    suffix="${slot#_}"
    CHARGING_SELECTED_SLOT="$slot"
    CHARGING_BACKUP="$CHARGING_RESCUE_DIR/original_dtbo_${suffix}.img"
    CHARGING_STATE_FILE="$CHARGING_RESCUE_DIR/charging_state_${suffix}.conf"
    CHARGING_BACKUP_PENDING="$CHARGING_BACKUP.pending"
    CHARGING_STATE_PENDING="$CHARGING_STATE_FILE.pending"
    CHARGING_BACKUP_PREVIOUS="$CHARGING_BACKUP.previous"
    CHARGING_STATE_PREVIOUS="$CHARGING_STATE_FILE.previous"
    CHARGING_OPERATION_FILE="$CHARGING_RESCUE_DIR/operation_${suffix}.conf"
    CHARGING_PREPARED_DIR="$CHARGING_RESCUE_DIR/prepared_${suffix}"
    CHARGING_PREPARED_STATE="$CHARGING_PREPARED_DIR/prepare.conf"
    CHARGING_PREPARED_BASE="$CHARGING_PREPARED_DIR/base.img"
    CHARGING_PREPARED_RAW="$CHARGING_PREPARED_DIR/raw_dtbo.img"
    CHARGING_PREPARED_IMAGE="$CHARGING_PREPARED_DIR/patched_dtbo.img"
    CHARGING_PREPARED_ROLLBACK="$CHARGING_PREPARED_DIR/current.img"
    return 0
}

charging_ensure_slot_state() {
    local slot
    if [ -n "$CHARGING_SELECTED_SLOT" ]; then
        charging_select_slot_state "$CHARGING_SELECTED_SLOT"
        return $?
    fi
    slot="$(charging_active_slot)" || return 1
    charging_select_slot_state "$slot"
}

charging_ensure_rescue_dir() {
    mkdir -p "$CHARGING_RESCUE_DIR" || return 1
    chmod 0700 "$CHARGING_RESCUE_DIR" 2>/dev/null || return 1
    return 0
}

charging_set_operation_phase() {
    local phase="$1" detail="${2:-}" tmp boot_id owner_start
    charging_ensure_slot_state || return 1
    charging_ensure_rescue_dir || return 1
    boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')"
    owner_start="$(awk '{print $22}' /proc/$$/stat 2>/dev/null)"
    case "$owner_start" in ''|*[!0-9]*) return 1 ;; esac
    tmp="$CHARGING_OPERATION_FILE.tmp.$$"
    {
        printf 'format=1\n'
        printf 'slot=%s\n' "$CHARGING_SELECTED_SLOT"
        printf 'phase=%s\n' "$phase"
        printf 'boot_id=%s\n' "$boot_id"
        printf 'owner_pid=%s\n' "$$"
        printf 'owner_start=%s\n' "$owner_start"
        printf 'detail=%s\n' "$detail"
        printf 'backup=%s\n' "$CHARGING_BACKUP"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$CHARGING_OPERATION_FILE" || {
        rm -f "$tmp"
        return 1
    }
    sync || return 1
    return 0
}

charging_operation_field() {
    local key="$1"
    sed -n "s/^${key}=//p" "$CHARGING_OPERATION_FILE" 2>/dev/null | head -n 1
}

charging_operation_load() {
    local format slot phase boot_id detail owner_pid owner_start
    charging_ensure_slot_state || return 1
    [ -r "$CHARGING_OPERATION_FILE" ] || return 1
    format="$(charging_operation_field format)"
    slot="$(charging_operation_field slot)"
    phase="$(charging_operation_field phase)"
    boot_id="$(charging_operation_field boot_id)"
    owner_pid="$(charging_operation_field owner_pid)"
    owner_start="$(charging_operation_field owner_start)"
    detail="$(charging_operation_field detail)"
    [ "$format" = 1 ] && [ "$slot" = "$CHARGING_SELECTED_SLOT" ] || return 1
    case "$phase" in
        BACKUP_DURABLE|FLASHING|RESTORING|ROLLING_BACK|REBOOT_REQUIRED|UNCHANGED|ORIGINAL|\
        FOREIGN|RESCUE_REQUIRED|RESTORED|SUCCESS) ;;
        *) return 1 ;;
    esac
    case "$boot_id" in ''|*[!0-9a-fA-F-]*) [ -z "$boot_id" ] || return 1 ;; esac
    case "$owner_pid" in ''|*[!0-9]*) [ -z "$owner_pid" ] || return 1 ;; esac
    case "$owner_start" in ''|*[!0-9]*) [ -z "$owner_start" ] || return 1 ;; esac
    if [ -n "$owner_pid" ] || [ -n "$owner_start" ]; then
        [ -n "$owner_pid" ] && [ -n "$owner_start" ] || return 1
    fi
    CHARGING_OPERATION_PHASE="$phase"
    CHARGING_OPERATION_BOOT_ID="$boot_id"
    CHARGING_OPERATION_OWNER_PID="$owner_pid"
    CHARGING_OPERATION_OWNER_START="$owner_start"
    CHARGING_OPERATION_DETAIL="$detail"
    return 0
}

charging_operation_validate_existing() {
    charging_ensure_slot_state || return 1
    [ -e "$CHARGING_OPERATION_FILE" ] || [ -L "$CHARGING_OPERATION_FILE" ] || return 0
    charging_operation_load && return 0
    # operation 文件是判断刷写/恢复是否已经跨过安全边界的唯一证据之一。
    # 即使 state 与当前分区哈希仍完整，也不能把损坏状态静默覆盖成
    # ORIGINAL/UNCHANGED，否则可能同时丢失人工救援与必须重启信息。
    CHARGING_RESCUE_REQUIRED=1
    return 1
}

charging_operation_requires_rescue() {
    local current_hash="${1:-}"
    charging_operation_load || return 1
    if [ "$CHARGING_OPERATION_PHASE" != RESCUE_REQUIRED ]; then
        [ -n "$current_hash" ] || return 1
        case "$CHARGING_OPERATION_PHASE" in
            FLASHING|RESTORING|ROLLING_BACK) ;;
            *) return 1 ;;
        esac
        if [ "$CHARGING_STATE_VALID" = 1 ] && \
            [ "$CHARGING_STATE_SLOT" = "$CHARGING_SELECTED_SLOT" ] && \
            charging_state_hash_owned "$current_hash"; then
            return 1
        fi
    fi
    CHARGING_RESCUE_REQUIRED=1
    return 0
}

charging_operation_owner_is_alive() {
    local actual_start
    [ -n "$CHARGING_OPERATION_OWNER_PID" ] && \
        [ -n "$CHARGING_OPERATION_OWNER_START" ] || return 1
    actual_start="$(awk '{print $22}' \
        "/proc/$CHARGING_OPERATION_OWNER_PID/stat" 2>/dev/null)"
    [ -n "$actual_start" ] && [ "$actual_start" = "$CHARGING_OPERATION_OWNER_START" ]
}

charging_promote_interrupted_operation_to_rescue() {
    local current_hash="$1" phase detail
    charging_operation_requires_rescue "$current_hash" || return 1
    phase="$CHARGING_OPERATION_PHASE"
    [ "$phase" != RESCUE_REQUIRED ] || return 0
    detail="检测到中断的 $phase 事务，当前 DTBO 哈希不属于原始镜像或任一已登记补丁"
    charging_set_operation_phase RESCUE_REQUIRED "$detail" || return 2
    charging_operation_load || return 2
    CHARGING_RESCUE_REQUIRED=1
    return 0
}

charging_operation_requires_reboot() {
    local current_hash="$1" current_boot_id
    charging_operation_load || return 1
    current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \r\n')"
    if [ -n "$CHARGING_OPERATION_BOOT_ID" ] && [ -n "$current_boot_id" ] && \
        [ "$CHARGING_OPERATION_BOOT_ID" != "$current_boot_id" ]; then
        return 1
    fi
    case "$CHARGING_OPERATION_PHASE" in
        FLASHING)
            [ "$current_hash" = "$CHARGING_STATE_PATCHED_HASH" ]
            ;;
        RESTORING)
            [ "$current_hash" = "$CHARGING_STATE_ORIGINAL_HASH" ]
            ;;
        REBOOT_REQUIRED)
            charging_state_hash_owned "$current_hash"
            ;;
        RESCUE_REQUIRED)
            # 分区已回到某个本模块完整持有的镜像时仍保留本次启动内的
            # 重启要求；若是未知/部分写入镜像，只报告救援并明确禁止重启。
            charging_state_hash_owned "$current_hash"
            ;;
        *) return 1 ;;
    esac
}

charging_begin_partition_critical() {
    [ "$CHARGING_PARTITION_CRITICAL" = 0 ] || return 1
    # HUP/INT/TERM are ignored by the shell and inherited by dd/sync/blockdev until
    # the write, full readback and any rollback have reached a safe boundary.
    trap '' HUP INT TERM
    CHARGING_PARTITION_CRITICAL=1
    return 0
}

charging_end_partition_critical() {
    [ "$CHARGING_PARTITION_CRITICAL" = 1 ] || return 0
    CHARGING_PARTITION_CRITICAL=0
    if command -v install_lock_signal_traps >/dev/null 2>&1; then
        install_lock_signal_traps
    else
        trap - HUP INT TERM
    fi
    return 0
}

charging_require_tools() {
    local tool
    for tool in "$CHARGING_FDTGET" "$CHARGING_FDTPUT" "$CHARGING_MKDTIMG"; do
        [ -x "$tool" ] || charging_fail "DTBO 工具不可执行：$tool" || return 1
    done
    [ -r "$CHARGING_PPS_CELLS" ] || charging_fail "PPS55 参数表不存在：$CHARGING_PPS_CELLS" || return 1
    [ -r "$CHARGING_PD_QC_FCC_CELLS" ] || charging_fail "PD/QC FCC 参数表不存在：$CHARGING_PD_QC_FCC_CELLS" || return 1
    [ "$CHARGING_AVB_HELPER_LOADED" = 1 ] || charging_fail "AVB-aware DTBO 助手加载失败：$CHARGING_AVB_HELPER" || return 1
    for tool in od stat sha256sum cmp truncate dd awk sort; do
        command -v "$tool" >/dev/null 2>&1 || {
            charging_fail "系统缺少 AVB/DTBO 容器校验命令：$tool"
            return 1
        }
    done
    return 0
}

charging_validate_request() {
    charging_is_bool "${CHARGING_DTBO_ENABLE:-0}" || \
        charging_fail "CHARGING_DTBO_ENABLE 必须为 0 或 1" || return 1
    charging_is_bool "${PPS55_ENABLE:-0}" || \
        charging_fail "PPS55_ENABLE 必须为 0 或 1" || return 1
    charging_is_bool "${PD_QC_27W_ENABLE:-0}" || \
        charging_fail "PD_QC_27W_ENABLE 必须为 0 或 1" || return 1
    return 0
}

charging_is_sha256_value() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
    return 0
}

charging_battery_unlocker_state_field() {
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

charging_check_battery_unlocker_conflict() {
    local slot="$1" part="$2" module_dir rescue_dir state_file
    local current_hash= base_hash target_hash

    for module_dir in "$CHARGING_BATTERY_UNLOCKER_MODULE_DIR" \
        "$CHARGING_BATTERY_UNLOCKER_UPDATE_DIR"; do
        [ -e "$module_dir" ] || [ -L "$module_dir" ] || continue
        charging_fail "检测到 battery_unlocker 模块仍已安装、待更新或待移除；其持久化 DTBO 不会因 disable/remove 标记立即消失。请先用原模块恢复、完成卸载并重启"
        return 1
    done

    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    rescue_dir="$CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT/${slot#_}"
    for state_file in "$rescue_dir/pending.env" "$rescue_dir/state.env"; do
        [ -e "$state_file" ] || continue
        [ -r "$state_file" ] || {
            charging_fail "battery_unlocker 的外部 DTBO 事务状态不可读，无法排除叠加修改：$state_file"
            return 1
        }
        base_hash="$(charging_battery_unlocker_state_field "$state_file" base_sha256)"
        target_hash="$(charging_battery_unlocker_state_field "$state_file" target_sha256)"
        charging_is_sha256_value "$base_hash" && \
            charging_is_sha256_value "$target_hash" || {
            charging_fail "battery_unlocker 的外部 DTBO 事务状态损坏，无法安全判断所有权：$state_file"
            return 1
        }
        [ "$base_hash" != "$target_hash" ] || continue
        if [ -z "$current_hash" ]; then
            current_hash="$(charging_sha256 "$part")" || {
                charging_fail "无法读取当前 DTBO 哈希，不能排除 battery_unlocker 持久化补丁"
                return 1
            }
        fi
        if [ "$current_hash" = "$target_hash" ]; then
            charging_fail "当前 DTBO 仍是 battery_unlocker 记录的持久化补丁；请先恢复其基线 DTBO，完成卸载并重启"
            return 1
        fi
    done
    return 0
}

charging_preflight_apply() {
    local sdk slot part
    charging_validate_request || return 1
    charging_require_tools || return 1

    sdk="$(getprop ro.build.version.sdk 2>/dev/null)"
    [ "$sdk" = 35 ] || {
        charging_fail "充电 DTBO 补丁仅允许 Android 15（SDK 35）；当前 SDK=${sdk:-unknown}"
        return 1
    }

    avb_require_unlocked_bootloader || {
        charging_fail "拒绝修改 DTBO：$AVB_ERROR"
        return 1
    }

    slot="$(charging_active_slot)" || {
        charging_fail "无法识别当前 A/B 槽位"
        return 1
    }
    part="$(charging_dtbo_partition "$slot")" || {
        charging_fail "找不到当前槽位 DTBO 分区：dtbo${slot}"
        return 1
    }
    [ -r "$part" ] && [ -w "$part" ] || {
        charging_fail "DTBO 分区不可读写：$part"
        return 1
    }
    charging_check_battery_unlocker_conflict "$slot" "$part" || return 1
    return 0
}

charging_trusted_original_hash() {
    case "$1" in
        _a) printf '%s\n' "$CHARGING_TRUSTED_ORIGINAL_A_SHA256" ;;
        _b) printf '%s\n' "$CHARGING_TRUSTED_ORIGINAL_B_SHA256" ;;
        *) return 1 ;;
    esac
}

charging_trusted_original_size() {
    case "$1" in
        _a|_b) printf '%s\n' "$CHARGING_TRUSTED_ORIGINAL_SIZE" ;;
        *) return 1 ;;
    esac
}

charging_image_has_avb_footer() {
    local image="${1:-}" image_size footer_offset footer_magic
    [ -f "$image" ] || return 1
    image_size="$(charging_file_size "$image" 2>/dev/null)" || return 1
    case "$image_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$image_size" -ge 64 ] || return 1
    footer_offset=$((image_size - 64))
    footer_magic="$(charging_read_hex "$image" "$footer_offset" 4 2>/dev/null)" || return 1
    [ "$footer_magic" = "41564266" ]
}

charging_require_backup_tools() {
    local tool
    [ "$CHARGING_AVB_HELPER_LOADED" = 1 ] || {
        charging_fail "AVB-aware DTBO 助手加载失败：$CHARGING_AVB_HELPER"
        return 1
    }
    for tool in od stat sha256sum dd awk tr wc sync; do
        command -v "$tool" >/dev/null 2>&1 || {
            charging_fail "系统缺少原始 DTBO 备份校验命令：$tool"
            return 1
        }
    done
    return 0
}

charging_preflight_backup() {
    local sdk slot
    [ "${PFFM_LOCK_HELD:-0}" = 1 ] || {
        charging_fail "未持有全局运行锁，拒绝建立原始 DTBO 备份"
        return 1
    }
    charging_require_backup_tools || return 1
    sdk="$(getprop ro.build.version.sdk 2>/dev/null)"
    [ "$sdk" = 35 ] || {
        charging_fail "原始 DTBO 自动识别仅支持 PJZ110 Android 15（SDK 35）；当前 SDK=${sdk:-unknown}"
        return 1
    }
    slot="$(charging_active_slot)" || {
        charging_fail "无法识别当前 A/B 活动槽位"
        return 1
    }
    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    return 0
}

charging_state_field() {
    local key="$1" file="${2:-$CHARGING_STATE_FILE}"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

charging_state_load_pair() {
    local file="${1:-$CHARGING_STATE_FILE}" backup="${2:-$CHARGING_BACKUP}"
    local format actual_hash actual_size combined_hashes
    CHARGING_STATE_VALID=0
    CHARGING_STATE_BASELINE_ONLY=0
    [ -r "$file" ] && [ -r "$backup" ] || return 1

    format="$(charging_state_field format "$file")"
    case "$format" in 1|2|3) ;; *) return 1 ;; esac

    CHARGING_STATE_FORMAT="$format"
    CHARGING_STATE_SLOT="$(charging_state_field slot "$file")"
    CHARGING_STATE_ORIGINAL_HASH="$(charging_state_field original_sha256 "$file")"
    CHARGING_STATE_PATCHED_HASH="$(charging_state_field patched_sha256 "$file")"
    CHARGING_STATE_IMAGE_SIZE="$(charging_state_field image_size "$file")"
    CHARGING_STATE_PPS55="$(charging_state_field pps55 "$file")"
    CHARGING_STATE_PD_QC_27W="$(charging_state_field pd_qc_27w "$file")"
    CHARGING_STATE_PREVIOUS_PATCHED_HASH=
    CHARGING_STATE_PREVIOUS_PPS55=0
    CHARGING_STATE_PREVIOUS_PD_QC_27W=0
    if [ "$format" = 2 ] || [ "$format" = 3 ]; then
        CHARGING_STATE_PREVIOUS_PATCHED_HASH="$(charging_state_field previous_patched_sha256 "$file")"
        CHARGING_STATE_PREVIOUS_PPS55="$(charging_state_field previous_pps55 "$file")"
        CHARGING_STATE_PREVIOUS_PD_QC_27W="$(charging_state_field previous_pd_qc_27w "$file")"
    fi
    if [ "$format" = 3 ]; then
        CHARGING_STATE_BASELINE_ONLY="$(charging_state_field baseline_only "$file")"
        charging_is_bool "$CHARGING_STATE_BASELINE_ONLY" || return 1
    fi

    case "$CHARGING_STATE_SLOT" in _a|_b) ;; *) return 1 ;; esac
    [ "${#CHARGING_STATE_ORIGINAL_HASH}" -eq 64 ] || return 1
    combined_hashes="$CHARGING_STATE_ORIGINAL_HASH"
    if [ "$CHARGING_STATE_BASELINE_ONLY" = 1 ]; then
        [ -z "$CHARGING_STATE_PATCHED_HASH" ] || return 1
        [ -z "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ] || return 1
        [ "$CHARGING_STATE_PPS55" = 0 ] && [ "$CHARGING_STATE_PD_QC_27W" = 0 ] || return 1
        [ "$CHARGING_STATE_PREVIOUS_PPS55" = 0 ] && \
            [ "$CHARGING_STATE_PREVIOUS_PD_QC_27W" = 0 ] || return 1
    else
        [ "${#CHARGING_STATE_PATCHED_HASH}" -eq 64 ] || return 1
        combined_hashes="$combined_hashes$CHARGING_STATE_PATCHED_HASH"
    fi
    if [ -n "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ]; then
        [ "${#CHARGING_STATE_PREVIOUS_PATCHED_HASH}" -eq 64 ] || return 1
        combined_hashes="$combined_hashes$CHARGING_STATE_PREVIOUS_PATCHED_HASH"
    fi
    case "$combined_hashes" in *[!0-9a-fA-F]*) return 1 ;; esac
    case "$CHARGING_STATE_IMAGE_SIZE" in ''|*[!0-9]*) return 1 ;; esac
    charging_is_bool "$CHARGING_STATE_PPS55" || return 1
    charging_is_bool "$CHARGING_STATE_PD_QC_27W" || return 1
    charging_is_bool "$CHARGING_STATE_PREVIOUS_PPS55" || return 1
    charging_is_bool "$CHARGING_STATE_PREVIOUS_PD_QC_27W" || return 1

    actual_hash="$(charging_sha256 "$backup")" || return 1
    actual_size="$(charging_file_size "$backup")"
    [ "$actual_hash" = "$CHARGING_STATE_ORIGINAL_HASH" ] || return 1
    [ "$actual_size" = "$CHARGING_STATE_IMAGE_SIZE" ] || return 1
    CHARGING_STATE_VALID=1
    return 0
}

charging_state_hash_owned() {
    local hash="$1"
    [ "$hash" = "$CHARGING_STATE_ORIGINAL_HASH" ] || \
        { [ -n "$CHARGING_STATE_PATCHED_HASH" ] && \
            [ "$hash" = "$CHARGING_STATE_PATCHED_HASH" ]; } || \
        { [ -n "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ] && \
            [ "$hash" = "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ]; }
}

charging_state_patch_config_for_hash() {
    local hash="$1"
    if [ -n "$CHARGING_STATE_PATCHED_HASH" ] && \
        [ "$hash" = "$CHARGING_STATE_PATCHED_HASH" ]; then
        CHARGING_MATCHED_PPS55="$CHARGING_STATE_PPS55"
        CHARGING_MATCHED_PD_QC_27W="$CHARGING_STATE_PD_QC_27W"
        return 0
    fi
    if [ -n "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ] && \
        [ "$hash" = "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" ]; then
        CHARGING_MATCHED_PPS55="$CHARGING_STATE_PREVIOUS_PPS55"
        CHARGING_MATCHED_PD_QC_27W="$CHARGING_STATE_PREVIOUS_PD_QC_27W"
        return 0
    fi
    return 1
}

charging_cleanup_state_transaction() {
    charging_ensure_slot_state || return 1
    rm -f "$CHARGING_BACKUP_PENDING" "$CHARGING_STATE_PENDING" \
        "$CHARGING_BACKUP_PREVIOUS" "$CHARGING_STATE_PREVIOUS" 2>/dev/null
}

charging_restore_previous_pair() {
    local backup_tmp="$CHARGING_BACKUP.recover.$$" state_tmp="$CHARGING_STATE_FILE.recover.$$"
    charging_state_load_pair "$CHARGING_STATE_PREVIOUS" "$CHARGING_BACKUP_PREVIOUS" || return 1
    cp -f "$CHARGING_BACKUP_PREVIOUS" "$backup_tmp" || return 1
    cp -f "$CHARGING_STATE_PREVIOUS" "$state_tmp" || {
        rm -f "$backup_tmp"
        return 1
    }
    chmod 0600 "$backup_tmp" "$state_tmp" 2>/dev/null
    charging_state_load_pair "$state_tmp" "$backup_tmp" || {
        rm -f "$backup_tmp" "$state_tmp"
        return 1
    }
    mv -f "$backup_tmp" "$CHARGING_BACKUP" || {
        rm -f "$backup_tmp" "$state_tmp"
        return 1
    }
    mv -f "$state_tmp" "$CHARGING_STATE_FILE" || {
        rm -f "$state_tmp"
        return 1
    }
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP"
}

charging_recover_state_transaction() {
    # pending 状态代表一次尚未完成的提交，必须优先于旧正式状态处理。
    # 原始备份内容通常不变，因此旧状态可能仍能与新正式备份通过校验；若先接受旧状态，
    # 随后的新镜像刷写会失去正确的 patched_sha256 所有权记录。
    if charging_state_load_pair "$CHARGING_STATE_PENDING" "$CHARGING_BACKUP"; then
        mv -f "$CHARGING_STATE_PENDING" "$CHARGING_STATE_FILE" || return 1
        charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || return 1
        sync || return 1
        charging_cleanup_state_transaction
        charging_msg "- 已完成上次中断的 DTBO 备份/状态事务"
        return 0
    fi

    # 首次提交可能在两个 pending 文件都写完、尚未切换正式文件时中断。
    if charging_state_load_pair "$CHARGING_STATE_PENDING" "$CHARGING_BACKUP_PENDING"; then
        mv -f "$CHARGING_BACKUP_PENDING" "$CHARGING_BACKUP" || return 1
        mv -f "$CHARGING_STATE_PENDING" "$CHARGING_STATE_FILE" || return 1
        charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || return 1
        sync || return 1
        charging_cleanup_state_transaction
        charging_msg "- 已完成上次中断的 DTBO 备份/状态事务"
        return 0
    fi

    if charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP"; then
        charging_cleanup_state_transaction
        return 0
    fi

    # 新事务无法完成时，previous 始终保留着一组经过哈希校验的旧文件。
    if charging_restore_previous_pair; then
        charging_cleanup_state_transaction
        charging_msg "- 已回滚上次中断的 DTBO 备份/状态事务"
        return 0
    fi
    return 1
}

charging_state_load() {
    if [ "$#" -gt 0 ]; then
        charging_state_load_pair "$@"
        return $?
    fi
    charging_ensure_slot_state || return 1
    if [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ]; then
        charging_recover_state_transaction
        return $?
    fi
    if charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP"; then
        charging_cleanup_state_transaction
        return 0
    fi
    charging_recover_state_transaction
}

charging_state_write_file() {
    local file="$1" slot="$2" original_hash="$3" patched_hash="$4" image_size="$5"
    local pps55="${6:-${PPS55_ENABLE:-0}}" pd_qc_27w="${7:-${PD_QC_27W_ENABLE:-0}}"
    local previous_hash="${8:-}" previous_pps55="${9:-0}" previous_pd_qc_27w="${10:-0}" tmp
    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    charging_is_sha256_value "$original_hash" || return 1
    charging_is_sha256_value "$patched_hash" || return 1
    case "$image_size" in ''|*[!0-9]*) return 1 ;; esac
    charging_is_bool "$pps55" && charging_is_bool "$pd_qc_27w" || return 1
    charging_is_bool "$previous_pps55" && charging_is_bool "$previous_pd_qc_27w" || return 1
    if [ -n "$previous_hash" ]; then
        [ "${#previous_hash}" -eq 64 ] || return 1
        case "$previous_hash" in *[!0-9a-fA-F]*) return 1 ;; esac
        if [ "$previous_hash" = "$original_hash" ] || [ "$previous_hash" = "$patched_hash" ]; then
            previous_hash=
            previous_pps55=0
            previous_pd_qc_27w=0
        fi
    else
        previous_pps55=0
        previous_pd_qc_27w=0
    fi
    tmp="$file.tmp.$$"
    {
        printf 'format=2\n'
        printf 'slot=%s\n' "$slot"
        printf 'original_sha256=%s\n' "$original_hash"
        printf 'patched_sha256=%s\n' "$patched_hash"
        printf 'previous_patched_sha256=%s\n' "$previous_hash"
        printf 'image_size=%s\n' "$image_size"
        printf 'pps55=%s\n' "$pps55"
        printf 'pd_qc_27w=%s\n' "$pd_qc_27w"
        printf 'previous_pps55=%s\n' "$previous_pps55"
        printf 'previous_pd_qc_27w=%s\n' "$previous_pd_qc_27w"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" || {
        rm -f "$tmp"
        return 1
    }
    return 0
}

charging_state_write_baseline_file() {
    local file="$1" slot="$2" original_hash="$3" image_size="$4" tmp
    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    charging_is_sha256_value "$original_hash" || return 1
    case "$image_size" in ''|*[!0-9]*) return 1 ;; esac
    tmp="$file.tmp.$$"
    {
        printf 'format=3\n'
        printf 'slot=%s\n' "$slot"
        printf 'baseline_only=1\n'
        printf 'original_sha256=%s\n' "$original_hash"
        printf 'patched_sha256=\n'
        printf 'previous_patched_sha256=\n'
        printf 'image_size=%s\n' "$image_size"
        printf 'pps55=0\n'
        printf 'pd_qc_27w=0\n'
        printf 'previous_pps55=0\n'
        printf 'previous_pd_qc_27w=0\n'
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$file" || {
        rm -f "$tmp"
        return 1
    }
    return 0
}

charging_commit_original_backup() {
    local source="$1" slot="$2" original_hash="$3" image_size="$4"
    [ "${PFFM_LOCK_HELD:-0}" = 1 ] || {
        charging_fail "未持有全局运行锁，拒绝提交原始 DTBO 备份"
        return 1
    }
    charging_select_slot_state "$slot" || return 1
    charging_ensure_rescue_dir || return 1
    charging_slot_has_state_artifacts && {
        charging_fail "槽位 $slot 已存在 DTBO 所有权文件；拒绝覆盖"
        return 1
    }

    cp -f "$source" "$CHARGING_BACKUP_PENDING" || return 1
    chmod 0600 "$CHARGING_BACKUP_PENDING" 2>/dev/null || return 1
    charging_state_write_baseline_file "$CHARGING_STATE_PENDING" "$slot" \
        "$original_hash" "$image_size" || return 1
    charging_state_load_pair "$CHARGING_STATE_PENDING" "$CHARGING_BACKUP_PENDING" || {
        charging_fail "槽位 $slot 的待提交原始 DTBO 备份校验失败"
        return 1
    }
    # 先把完整 pending 对持久化，再依次切换正式备份和状态；任一步中断均可由
    # charging_recover_state_transaction 使用 pending 文件前滚。
    sync || return 1
    mv -f "$CHARGING_BACKUP_PENDING" "$CHARGING_BACKUP" || return 1
    if ! mv -f "$CHARGING_STATE_PENDING" "$CHARGING_STATE_FILE"; then
        charging_recover_state_transaction || return 1
    fi
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || {
        charging_recover_state_transaction || return 1
    }
    chmod 0600 "$CHARGING_BACKUP" "$CHARGING_STATE_FILE" 2>/dev/null || return 1
    sync || return 1
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || return 1
    charging_cleanup_state_transaction
    return 0
}

charging_commit_state_transaction() {
    local work="$1" slot="$2" patched_hash="$3"
    local patched_pps55="${4:-${PPS55_ENABLE:-0}}" patched_pd_qc_27w="${5:-${PD_QC_27W_ENABLE:-0}}"
    local previous_hash="${6:-}" previous_pps55="${7:-0}" previous_pd_qc_27w="${8:-0}"

    charging_select_slot_state "$slot" || return 1
    charging_ensure_rescue_dir || return 1

    rm -f "$CHARGING_BACKUP_PENDING" "$CHARGING_STATE_PENDING" \
        "$CHARGING_BACKUP_PREVIOUS" "$CHARGING_STATE_PREVIOUS" 2>/dev/null

    cp -f "$work/base.img" "$CHARGING_BACKUP_PENDING" || return 1
    chmod 0600 "$CHARGING_BACKUP_PENDING" 2>/dev/null
    charging_state_write_file "$CHARGING_STATE_PENDING" "$slot" \
        "$CHARGING_ORIGINAL_HASH" "$patched_hash" "$CHARGING_ORIGINAL_SIZE" \
        "$patched_pps55" "$patched_pd_qc_27w" "$previous_hash" \
        "$previous_pps55" "$previous_pd_qc_27w" || return 1
    charging_state_load_pair "$CHARGING_STATE_PENDING" "$CHARGING_BACKUP_PENDING" || {
        charging_fail "待提交的 DTBO 备份/状态校验失败"
        return 1
    }

    if [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ]; then
        charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || {
            charging_fail "现有 DTBO 备份/状态在事务提交前已损坏"
            return 1
        }
        cp -f "$CHARGING_BACKUP" "$CHARGING_BACKUP_PREVIOUS" || return 1
        cp -f "$CHARGING_STATE_FILE" "$CHARGING_STATE_PREVIOUS" || return 1
        chmod 0600 "$CHARGING_BACKUP_PREVIOUS" "$CHARGING_STATE_PREVIOUS" 2>/dev/null
        charging_state_load_pair "$CHARGING_STATE_PREVIOUS" "$CHARGING_BACKUP_PREVIOUS" || return 1
    fi

    mv -f "$CHARGING_BACKUP_PENDING" "$CHARGING_BACKUP" || return 1
    if ! mv -f "$CHARGING_STATE_PENDING" "$CHARGING_STATE_FILE"; then
        charging_recover_state_transaction || return 1
    fi
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || {
        charging_recover_state_transaction || return 1
    }
    chmod 0600 "$CHARGING_BACKUP" "$CHARGING_STATE_FILE" 2>/dev/null
    # 备份和所有权状态必须先在 /data 上持久化，之后才允许触碰原始分区。
    sync || return 1
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || return 1
    charging_cleanup_state_transaction
    return 0
}

charging_migrate_legacy_state() {
    local source_dir="$1" source_backup source_state
    local slot original_hash patched_hash image_size pps55 pd_qc_27w baseline_only

    [ "${PFFM_LOCK_HELD:-0}" = 1 ] || {
        charging_fail "未持有全局运行锁，拒绝迁移旧版 DTBO 救援状态"
        return 1
    }

    source_backup="$source_dir/original_dtbo.img"
    source_state="$source_dir/charging_state.conf"
    [ -e "$source_backup" ] || [ -e "$source_state" ] || return 0
    [ -r "$source_backup" ] && [ -r "$source_state" ] || return 1
    charging_state_load_pair "$source_state" "$source_backup" || return 1

    slot="$CHARGING_STATE_SLOT"
    original_hash="$CHARGING_STATE_ORIGINAL_HASH"
    patched_hash="$CHARGING_STATE_PATCHED_HASH"
    image_size="$CHARGING_STATE_IMAGE_SIZE"
    pps55="$CHARGING_STATE_PPS55"
    pd_qc_27w="$CHARGING_STATE_PD_QC_27W"
    baseline_only="$CHARGING_STATE_BASELINE_ONLY"
    charging_select_slot_state "$slot" || return 1
    charging_ensure_rescue_dir || return 1

    if charging_slot_has_state_artifacts; then
        # 正式文件存在并不代表事务已经提交完成；pending/previous 可能是
        # 中断后唯一能恢复出一致所有权的一组文件。
        charging_state_load || return 1
        [ "$CHARGING_STATE_SLOT" = "$slot" ] && \
            [ "$CHARGING_STATE_ORIGINAL_HASH" = "$original_hash" ] || return 1
        return 0
    fi

    rm -f "$CHARGING_BACKUP_PENDING" "$CHARGING_STATE_PENDING" 2>/dev/null
    cp -f "$source_backup" "$CHARGING_BACKUP_PENDING" || return 1
    chmod 0600 "$CHARGING_BACKUP_PENDING" 2>/dev/null || return 1
    if [ "$baseline_only" = 1 ]; then
        charging_state_write_baseline_file "$CHARGING_STATE_PENDING" "$slot" \
            "$original_hash" "$image_size" || return 1
    else
        charging_state_write_file "$CHARGING_STATE_PENDING" "$slot" \
            "$original_hash" "$patched_hash" "$image_size" "$pps55" "$pd_qc_27w" || return 1
    fi
    charging_state_load_pair "$CHARGING_STATE_PENDING" "$CHARGING_BACKUP_PENDING" || return 1
    mv -f "$CHARGING_BACKUP_PENDING" "$CHARGING_BACKUP" || return 1
    mv -f "$CHARGING_STATE_PENDING" "$CHARGING_STATE_FILE" || return 1
    chmod 0600 "$CHARGING_BACKUP" "$CHARGING_STATE_FILE" 2>/dev/null || return 1
    sync || return 1
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || return 1
    charging_cleanup_state_transaction
    charging_msg "- 已把旧版原始 DTBO 迁移到槽位独立救援目录：$CHARGING_BACKUP"
    return 0
}

charging_import_previous_state() {
    local old="/data/adb/modules/ColorOSFullTempSpoof"
    [ "$old" = "$CHARGING_MODDIR" ] && return 0
    charging_migrate_legacy_state "$old"
}

charging_symbol_path() {
    "$CHARGING_FDTGET" -t s "$1" /__symbols__ "$2" 2>/dev/null
}

charging_normalize_hex_list() {
    printf '%s\n' "$1" | awk '
        {
            for (field_index = 1; field_index <= NF; field_index++) {
                value = tolower($field_index)
                sub(/^0x/, "", value)
                if (value == "" || value ~ /[^0-9a-f]/) {
                    invalid = 1
                    exit
                }
                sub(/^0+/, "", value)
                if (value == "") {
                    value = "0"
                }
                output = output (output == "" ? "" : " ") value
            }
        }
        END {
            if (invalid || output == "") {
                exit 1
            }
            print output
        }
    '
}

charging_hex_lists_equal() {
    local expected actual
    expected="$(charging_normalize_hex_list "$1")" || return 1
    actual="$(charging_normalize_hex_list "$2")" || return 1
    [ "$expected" = "$actual" ]
}

charging_compare_hex_line_files() {
    local expected_file="$1" actual_file="$2"
    awk -v expected_file="$expected_file" -v actual_file="$actual_file" '
        function normalize(line, count, fields, field_index, value, output) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") {
                invalid = 1
                return ""
            }
            count = split(line, fields, /[[:space:]]+/)
            output = ""
            for (field_index = 1; field_index <= count; field_index++) {
                value = tolower(fields[field_index])
                sub(/^0x/, "", value)
                if (value == "" || value ~ /[^0-9a-f]/) {
                    invalid = 1
                    return ""
                }
                sub(/^0+/, "", value)
                if (value == "") {
                    value = "0"
                }
                output = output (output == "" ? "" : " ") value
            }
            return output
        }
        BEGIN {
            while ((getline line < expected_file) > 0) {
                expected_count++
                expected[expected_count] = normalize(line)
            }
            close(expected_file)
            while ((getline line < actual_file) > 0) {
                actual_count++
                if (actual_count > expected_count ||
                        normalize(line) != expected[actual_count]) {
                    mismatch = 1
                }
            }
            close(actual_file)
            if (invalid || mismatch || expected_count == 0 ||
                    actual_count != expected_count) {
                exit 1
            }
        }
    '
}

charging_is_target_dtb() {
    local ids id
    ids="$("$CHARGING_FDTGET" -t x "$1" / oplus,project-id 2>/dev/null)" || return 1
    for id in $ids; do
        id="${id#0x}"
        case "$id" in
            5d0d|00005d0d|0000000000005d0d) return 0 ;;
        esac
    done
    return 1
}

charging_apply_pps_cells() {
    local dtb="$1" base rel prop values node
    local current=0 total label phase_started
    base="$(charging_symbol_path "$dtb" oplus_pps_charge)" || return 1
    case "$base" in /fragment@*/__overlay__/*) ;; *) return 1 ;; esac
    total="$(charging_parameter_row_count "$CHARGING_PPS_CELLS")" || return 1
    [ "$total" -gt 0 ] || return 1
    label="${dtb##*/}"
    phase_started="$(charging_epoch_seconds 2>/dev/null)" || phase_started=
    charging_progress_elapsed "$phase_started" "PPS 参数写入 $label：0/$total"

    while read -r rel prop values; do
        case "$rel" in ''|'#'*) continue ;; esac
        [ -n "$prop" ] && [ -n "$values" ] || return 1
        if [ "$rel" = . ]; then
            node="$base"
        else
            node="$base$rel"
        fi
        "$CHARGING_FDTGET" -t x "$dtb" "$node" "$prop" >/dev/null 2>&1 || return 1
        # values is a trusted, repository-owned list of hexadecimal cells.
        # shellcheck disable=SC2086
        "$CHARGING_FDTPUT" -t x "$dtb" "$node" "$prop" $values >/dev/null 2>&1 || return 1
        current=$((current + 1))
        if charging_progress_checkpoint "$current" "$total"; then
            charging_progress_elapsed "$phase_started" "PPS 参数写入 $label：$current/$total"
        fi
    done < "$CHARGING_PPS_CELLS"
    [ "$current" -eq "$total" ] || return 1
    return 0
}

charging_verify_pps_cells() {
    local dtb="$1" base rel prop values node work expected_file actual_file
    local current=0 total label phase_started
    base="$(charging_symbol_path "$dtb" oplus_pps_charge)" || return 1
    case "$base" in /fragment@*/__overlay__/*) ;; *) return 1 ;; esac
    total="$(charging_parameter_row_count "$CHARGING_PPS_CELLS")" || return 1
    [ "$total" -gt 0 ] || return 1
    label="${dtb##*/}"
    phase_started="$(charging_epoch_seconds 2>/dev/null)" || phase_started=
    charging_progress_elapsed "$phase_started" "PPS 参数复核 $label：0/$total"
    work="${dtb}.pps_verify.$$"
    expected_file="$work/expected.hex"
    actual_file="$work/actual.hex"
    rm -rf "$work"
    mkdir -p "$work" || return 1
    : > "$expected_file" || {
        rm -rf "$work"
        return 1
    }
    set -- "$CHARGING_FDTGET" -t x "$dtb"
    while read -r rel prop values; do
        case "$rel" in ''|'#'*) continue ;; esac
        [ -n "$prop" ] && [ -n "$values" ] || {
            rm -rf "$work"
            return 1
        }
        if [ "$rel" = . ]; then
            node="$base"
        else
            node="$base$rel"
        fi
        set -- "$@" "$node" "$prop"
        printf '%s\n' "$values" >> "$expected_file" || {
            rm -rf "$work"
            return 1
        }
        current=$((current + 1))
    done < "$CHARGING_PPS_CELLS"
    [ "$current" -eq "$total" ] || {
        rm -rf "$work"
        return 1
    }
    "$@" > "$actual_file" 2>/dev/null || {
        rm -rf "$work"
        return 1
    }
    charging_progress_elapsed "$phase_started" \
        "PPS 参数复核 $label：已批量读取 $total/$total，正在比较"
    charging_compare_hex_line_files "$expected_file" "$actual_file" || {
        rm -rf "$work"
        return 1
    }
    rm -rf "$work"
    charging_progress_elapsed "$phase_started" "PPS 参数复核 $label：$total/$total"
    return 0
}

charging_patch_protocol_list() {
    local dtb="$1" cpa values new type power found_pps=0 found_pd=0 found_qc=0
    cpa="$(charging_symbol_path "$dtb" oplus_cpa)" || return 1
    case "$cpa" in /fragment@*/__overlay__/*) ;; *) return 1 ;; esac
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$cpa" oplus,protocol_list 2>/dev/null)" || return 1
    set -- $values
    [ $(( $# % 2 )) -eq 0 ] && [ "$#" -gt 0 ] || return 1
    new=
    while [ "$#" -gt 0 ]; do
        type="$1"
        power="$2"
        shift 2
        case "${type#0x}" in
            2|02)
                found_pps=1
                [ "${PPS55_ENABLE:-0}" = 1 ] && power=37
                ;;
            1|01)
                found_pd=1
                [ "${PD_QC_27W_ENABLE:-0}" = 1 ] && power=1b
                ;;
            5|05)
                found_qc=1
                [ "${PD_QC_27W_ENABLE:-0}" = 1 ] && power=1b
                ;;
        esac
        new="$new $type $power"
    done
    [ "${PPS55_ENABLE:-0}" = 0 ] || [ "$found_pps" = 1 ] || return 1
    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        [ "$found_pd" = 1 ] && [ "$found_qc" = 1 ] || return 1
    fi
    # shellcheck disable=SC2086
    "$CHARGING_FDTPUT" -t x "$dtb" "$cpa" oplus,protocol_list $new >/dev/null 2>&1
}

charging_patch_fcc_property() {
    local dtb="$1" node="$2" prop="$3" values new value index=0
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$node" "$prop" 2>/dev/null)" || return 1
    new=
    for value in $values; do
        if [ "$index" -ge 45 ] && [ "${value#0x}" = 898 ]; then
            value=bb8
        fi
        new="$new $value"
        index=$((index + 1))
    done
    [ "$index" -eq 63 ] || return 1
    # shellcheck disable=SC2086
    "$CHARGING_FDTPUT" -t x "$dtb" "$node" "$prop" $new >/dev/null 2>&1
}

charging_patch_pdqc_cool_down_current() {
    local dtb="$1" node="$2" prop=oplus_spec,cool_down_pdqc_curr_ma
    local values
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$node" "$prop" 2>/dev/null)" || return 1
    # PJZ110 A15 的 PD/QC 表只有 1200/1500/2000mA 三级；ColorOS 常写入
    # cool_down=5/7，驱动会把超范围等级截到最后一级，因而旧补丁仍被卡在 2A。
    # 仅抬高最后一级，保留 1/2 级的 1200/1500mA 降温保护。
    charging_hex_lists_equal "4b0 5dc 7d0" "$values" ||
        charging_hex_lists_equal "4b0 5dc bb8" "$values" || return 1
    "$CHARGING_FDTPUT" -t x "$dtb" "$node" "$prop" \
        4b0 5dc bb8 >/dev/null 2>&1
}

charging_patch_wired_node() {
    local dtb="$1" node="$2" values
    "$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,pd-iclmax-ma >/dev/null 2>&1 || return 1
    "$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,qc-iclmax-ma >/dev/null 2>&1 || return 1
    "$CHARGING_FDTPUT" -t x "$dtb" "$node" oplus_spec,pd-iclmax-ma bb8 >/dev/null 2>&1 || return 1
    "$CHARGING_FDTPUT" -t x "$dtb" "$node" oplus_spec,qc-iclmax-ma bb8 >/dev/null 2>&1 || return 1

    values="$("$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,input-power-mw 2>/dev/null)" || return 1
    set -- $values
    [ "$#" -eq 7 ] || return 1
    "$CHARGING_FDTPUT" -t x "$dtb" "$node" oplus_spec,input-power-mw \
        "$1" "$2" "$3" "$4" "$5" 6978 6978 >/dev/null 2>&1 || return 1

    charging_patch_pdqc_cool_down_current "$dtb" "$node" || return 1
    charging_patch_fcc_property "$dtb" "$node" oplus_spec,fccmax-ma-lv || return 1
    charging_patch_fcc_property "$dtb" "$node" oplus_spec,fccmax-ma-hv || return 1
    return 0
}

charging_patch_wired() {
    local dtb="$1" wired
    wired="$(charging_symbol_path "$dtb" oplus_chg_wired)" || return 1
    case "$wired" in /fragment@*/__overlay__/*) ;; *) return 1 ;; esac
    charging_patch_wired_node "$dtb" "$wired" || return 1
    charging_patch_wired_node "$dtb" "$wired/silicon_p_770" || return 1
    return 0
}

charging_protocol_power_is() {
    local dtb="$1" wanted_type="$2" wanted_power="$3" cpa values type power
    cpa="$(charging_symbol_path "$dtb" oplus_cpa)" || return 1
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$cpa" oplus,protocol_list 2>/dev/null)" || return 1
    set -- $values
    while [ "$#" -ge 2 ]; do
        type="${1#0x}"
        power="${2#0x}"
        shift 2
        [ "$type" = "$wanted_type" ] && [ "$power" = "$wanted_power" ] && return 0
    done
    return 1
}

charging_expected_fcc_cells() {
    local wanted_rel="$1" wanted_prop="$2" rel prop values
    while read -r rel prop values; do
        case "$rel" in ''|'#'*) continue ;; esac
        [ "$rel" = "$wanted_rel" ] && [ "$prop" = "$wanted_prop" ] || continue
        [ -n "$values" ] || return 1
        printf '%s\n' "$values"
        return 0
    done < "$CHARGING_PD_QC_FCC_CELLS"
    return 1
}

charging_verify_fcc_property() {
    local dtb="$1" node="$2" prop="$3" rel="$4" actual expected
    actual="$("$CHARGING_FDTGET" -t x "$dtb" "$node" "$prop" 2>/dev/null)" || return 1
    expected="$(charging_expected_fcc_cells "$rel" "$prop")" || return 1
    set -- $expected
    [ "$#" -eq 63 ] || return 1
    charging_hex_lists_equal "$expected" "$actual"
}

charging_verify_wired_node() {
    local dtb="$1" node="$2" rel="$3" values
    [ "$("$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,pd-iclmax-ma 2>/dev/null)" = bb8 ] || return 1
    [ "$("$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,qc-iclmax-ma 2>/dev/null)" = bb8 ] || return 1
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,input-power-mw 2>/dev/null)" || return 1
    set -- $values
    [ "$#" -eq 7 ] && [ "$6" = 6978 ] && [ "$7" = 6978 ] || return 1
    values="$("$CHARGING_FDTGET" -t x "$dtb" "$node" oplus_spec,cool_down_pdqc_curr_ma 2>/dev/null)" || return 1
    charging_hex_lists_equal "4b0 5dc bb8" "$values" || return 1
    charging_verify_fcc_property "$dtb" "$node" oplus_spec,fccmax-ma-lv "$rel" || return 1
    charging_verify_fcc_property "$dtb" "$node" oplus_spec,fccmax-ma-hv "$rel" || return 1
    return 0
}

charging_verify_dtb() {
    local dtb="$1" pps wired
    if [ "${PPS55_ENABLE:-0}" = 1 ]; then
        charging_verify_pps_cells "$dtb" || return 1
        pps="$(charging_symbol_path "$dtb" oplus_pps_charge)" || return 1
        [ "$("$CHARGING_FDTGET" -t x "$dtb" "$pps" oplus,curr_max_ma 2>/dev/null)" = 1388 ] || return 1
        [ "$("$CHARGING_FDTGET" -t x "$dtb" "$pps/silicon_p_770" oplus,curr_max_ma 2>/dev/null)" = 1388 ] || return 1
        [ "$("$CHARGING_FDTGET" -t x "$dtb" "$pps" oplus,pps_ibat_over_oplus 2>/dev/null)" = 1900 ] || return 1
        charging_protocol_power_is "$dtb" 2 37 || return 1
    fi
    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        charging_protocol_power_is "$dtb" 1 1b || return 1
        charging_protocol_power_is "$dtb" 5 1b || return 1
        wired="$(charging_symbol_path "$dtb" oplus_chg_wired)" || return 1
        charging_verify_wired_node "$dtb" "$wired" . || return 1
        charging_verify_wired_node "$dtb" "$wired/silicon_p_770" /silicon_p_770 || return 1
    fi
    return 0
}

charging_patch_dtb() {
    local dtb="$1" label
    charging_is_target_dtb "$dtb" || return 2
    label="${dtb##*/}"
    [ "${PPS55_ENABLE:-0}" = 0 ] || charging_apply_pps_cells "$dtb" || return 1
    charging_progress "$label：正在更新协议功率声明"
    charging_patch_protocol_list "$dtb" || return 1
    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        charging_progress "$label：正在写入 PD/QC 电流、降温表与 FCC 参数"
        charging_patch_wired "$dtb" || return 1
    fi
    charging_progress "$label：正在完整复核修改结果"
    charging_verify_dtb "$dtb" || return 1
    return 0
}

charging_pad_image() {
    local image="$1" target_size="$2" current_size remain blocks tail
    current_size="$(charging_file_size "$image")"
    case "$current_size" in ''|*[!0-9]*) return 1 ;; esac
    [ "$current_size" -le "$target_size" ] || return 1
    remain=$((target_size - current_size))
    blocks=$((remain / 4096))
    tail=$((remain % 4096))
    if [ "$blocks" -gt 0 ]; then
        dd if=/dev/zero bs=4096 count="$blocks" >> "$image" 2>/dev/null || return 1
    fi
    if [ "$tail" -gt 0 ]; then
        dd if=/dev/zero bs=1 count="$tail" >> "$image" 2>/dev/null || return 1
    fi
    [ "$(charging_file_size "$image")" = "$target_size" ]
}

charging_read_hex() {
    local file="$1" offset="$2" count="$3" value expected_length
    value="$(dd if="$file" bs=1 skip="$offset" count="$count" 2>/dev/null \
        | od -An -tx1 -v 2>/dev/null | tr -d ' \r\n')"
    expected_length=$((count * 2))
    [ "${#value}" -eq "$expected_length" ] || return 1
    printf '%s\n' "$value"
}

charging_read_u32() {
    local value
    value="$(charging_read_hex "$1" "$2" 4)" || return 1
    printf '%s\n' "$((0x$value))"
}

charging_verify_container_layout() {
    local base="$1" output="$2" expected_count="$3"
    local field base_value output_value entry_size entry_count entries_offset metadata_size
    local index metadata_offset base_metadata output_metadata

    # total_size 和每个 dt_size/dt_offset 会随属性长度变化；其余容器字段必须保持一致。
    for field in 0 8 12 16 20 24 28; do
        base_value="$(charging_read_hex "$base" "$field" 4)" || return 1
        output_value="$(charging_read_hex "$output" "$field" 4)" || return 1
        [ "$base_value" = "$output_value" ] || return 1
    done

    entry_size="$(charging_read_u32 "$base" 12)" || return 1
    entry_count="$(charging_read_u32 "$base" 16)" || return 1
    entries_offset="$(charging_read_u32 "$base" 20)" || return 1
    [ "$entry_size" -ge 32 ] && [ "$entry_count" -eq "$expected_count" ] || return 1
    metadata_size=$((entry_size - 8))

    index=0
    while [ "$index" -lt "$entry_count" ]; do
        metadata_offset=$((entries_offset + index * entry_size + 8))
        base_metadata="$(charging_read_hex "$base" "$metadata_offset" "$metadata_size")" || return 1
        output_metadata="$(charging_read_hex "$output" "$metadata_offset" "$metadata_size")" || return 1
        [ "$base_metadata" = "$output_metadata" ] || return 1
        index=$((index + 1))
    done
    return 0
}

charging_verify_container() {
    local base="$1" output="$2" work="$3" expected_count="$4"
    local index before_hash after_hash verify_dir phase_started
    phase_started="$(charging_epoch_seconds 2>/dev/null)" || phase_started=
    charging_progress_elapsed "$phase_started" "容器复核：正在校验 DT table 头和条目元数据"
    charging_verify_container_layout "$base" "$output" "$expected_count" || return 1

    verify_dir="$work/verify"
    rm -rf "$verify_dir"
    mkdir -p "$verify_dir" || return 1
    charging_progress_elapsed "$phase_started" "容器复核：正在重新拆包 $expected_count 个子镜像"
    "$CHARGING_MKDTIMG" dump "$output" -b "$verify_dir/dtb" >/dev/null 2>&1 || return 1
    index=0
    while [ "$index" -lt "$expected_count" ]; do
        charging_progress_elapsed "$phase_started" \
            "容器复核：正在比较子镜像 $((index + 1))/$expected_count"
        [ -f "$work/dtb/dtb.$index" ] && [ -f "$verify_dir/dtb.$index" ] || return 1
        before_hash="$(charging_sha256 "$work/dtb/dtb.$index")" || return 1
        after_hash="$(charging_sha256 "$verify_dir/dtb.$index")" || return 1
        [ "$before_hash" = "$after_hash" ] || return 1
        index=$((index + 1))
    done
    [ ! -e "$verify_dir/dtb.$expected_count" ] || return 1
    charging_progress_elapsed "$phase_started" \
        "容器复核完成：$expected_count/$expected_count"
    return 0
}

charging_prepare_base() {
    local work slot part current base
    local current_hash state_present=0
    work="$1"
    slot="$2"
    part="$3"
    current="$work/current.img"
    base="$work/base.img"
    dd if="$part" of="$current" bs=4096 2>/dev/null || return 1
    [ -s "$current" ] || return 1
    current_hash="$(charging_sha256 "$current")" || return 1
    CHARGING_CURRENT_HASH="$current_hash"

    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；已保留原文件并拒绝生成新候选"
        return 1
    }
    if [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ] || \
        [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ] || \
        [ -e "$CHARGING_STATE_PREVIOUS" ] || [ -e "$CHARGING_BACKUP_PREVIOUS" ]; then
        state_present=1
        charging_state_load || {
            charging_fail "已有 DTBO 备份/状态损坏；为避免把已修改镜像当成原始镜像，拒绝覆盖"
            return 1
        }
    fi

    if [ "$state_present" = 1 ]; then
        [ "$CHARGING_STATE_SLOT" = "$slot" ] || {
            charging_fail "槽位状态文件内容与路径不一致；拒绝覆盖"
            return 1
        }
        if ! charging_state_hash_owned "$current_hash"; then
            if charging_operation_requires_rescue "$current_hash"; then
                charging_promote_interrupted_operation_to_rescue "$current_hash" || {
                    charging_fail "中断事务对应未知 DTBO，但无法持久化人工救援状态"
                    return 1
                }
                charging_fail "检测到中断的 DTBO 关键事务且当前分区哈希未知；已保留备份并标记为需要人工救援，请勿重启"
                return 1
            fi
            charging_fail "当前槽位 DTBO 已被 OTA 或其他工具修改；拒绝把未知镜像当成原始基线"
            return 1
        fi
        cp -f "$CHARGING_BACKUP" "$base" || return 1
        CHARGING_ORIGINAL_HASH="$CHARGING_STATE_ORIGINAL_HASH"
        CHARGING_ORIGINAL_SIZE="$CHARGING_STATE_IMAGE_SIZE"
        return 0
    fi

    if charging_operation_requires_rescue "$current_hash"; then
        charging_promote_interrupted_operation_to_rescue "$current_hash" || {
            charging_fail "未知 DTBO 对应的中断事务无法持久化为人工救援状态"
            return 1
        }
        charging_fail "当前槽位没有有效所有权状态，但存在未解决的关键 DTBO 事务；拒绝把当前镜像当成原始基线，请勿重启"
        return 1
    fi

    charging_fail "当前槽位尚未建立可信原始 DTBO 备份；拒绝在生成补丁时临时把当前分区定义成原始基线"
    return 1
}

charging_build_image() {
    local base="$1" output="$2" work="$3" raw
    local dtb result selected=0 total=0 index build_started
    raw="$work/raw_dtbo.img"
    build_started="$(charging_epoch_seconds 2>/dev/null)" || build_started=
    charging_progress_elapsed "$build_started" "正在拆分原始 DTBO 容器"
    mkdir -p "$work/dtb" || return 1
    "$CHARGING_MKDTIMG" dump "$base" -b "$work/dtb/dtb" >/dev/null 2>&1 || return 1
    while [ -f "$work/dtb/dtb.$total" ]; do
        total=$((total + 1))
    done
    [ "$total" -gt 0 ] || return 1
    charging_progress_elapsed "$build_started" "已拆分 $total 个 DTBO 子镜像，开始识别并修改目标镜像"

    index=0
    while [ "$index" -lt "$total" ]; do
        dtb="$work/dtb/dtb.$index"
        charging_progress_elapsed "$build_started" \
            "正在处理 DTBO 子镜像 $((index + 1))/$total：${dtb##*/}"
        charging_patch_dtb "$dtb"
        result=$?
        case "$result" in
            0)
                selected=$((selected + 1))
                charging_progress_elapsed "$build_started" \
                    "目标子镜像修改完成：${dtb##*/}（目标 $selected 个）"
                ;;
            2)
                charging_progress_elapsed "$build_started" \
                    "非 PJZ110 目标子镜像，已跳过：${dtb##*/}"
                ;;
            *) charging_fail "修改 DTBO 子镜像失败：${dtb##*/}"; return 1 ;;
        esac
        index=$((index + 1))
    done
    [ "$selected" -gt 0 ] || {
        charging_fail "DTBO 中没有 project-id=0x5d0d 的 PJZ110 overlay；拒绝刷写"
        return 1
    }

    rm -f "$raw" "$output"
    set --
    index=0
    while [ "$index" -lt "$total" ]; do
        set -- "$@" "$work/dtb/dtb.$index"
        index=$((index + 1))
    done
    charging_progress_elapsed "$build_started" "正在重新打包 $total 个 DTBO 子镜像"
    "$CHARGING_MKDTIMG" create "$raw" --page_size=4096 "$@" >/dev/null 2>&1 || return 1
    [ -s "$raw" ] || return 1
    charging_progress_elapsed "$build_started" "正在复核重打包容器"
    charging_verify_container "$base" "$raw" "$work" "$total" || {
        charging_fail "重打包 DTBO 的容器头、条目元数据、顺序或子镜像校验失败"
        return 1
    }
    charging_progress_elapsed "$build_started" "正在构建分区大小的 AVB 候选镜像并执行内部校验"
    avb_build_dtbo_image "$base" "$raw" "$output" || {
        charging_fail "AVB-aware DTBO 镜像构建失败：$AVB_ERROR"
        return 1
    }
    CHARGING_SELECTED_DTB_COUNT="$selected"
    CHARGING_TOTAL_DTB_COUNT="$total"
    charging_progress_elapsed "$build_started" "充电补丁镜像构建完成：目标 $selected/$total"
    return 0
}

charging_write_partition() {
    local image="$1" part="$2"
    dd if="$image" of="$part" bs=4096 2>/dev/null || return 1
    sync || return 1
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --flushbufs "$part" 2>/dev/null || return 1
    fi
    return 0
}

charging_restore_after_flash_failure() {
    local part="$1" rollback_hash="${2:-$CHARGING_PREPARED_LIVE_HASH}" resume_reboot="${3:-0}"
    local restored_hash rollback_actual failed_hash failed_pps55 failed_pd_qc_27w
    local rollback_pps55 rollback_pd_qc_27w

    [ -r "$CHARGING_PREPARED_ROLLBACK" ] || {
        charging_set_operation_phase RESCUE_REQUIRED "刷写前 DTBO 回滚镜像缺失" 2>/dev/null
        return 1
    }
    rollback_actual="$(charging_sha256 "$CHARGING_PREPARED_ROLLBACK")" || {
        charging_set_operation_phase RESCUE_REQUIRED "刷写前 DTBO 回滚镜像无法校验" 2>/dev/null
        return 1
    }
    [ "$rollback_actual" = "$rollback_hash" ] || {
        charging_set_operation_phase RESCUE_REQUIRED "刷写前 DTBO 回滚镜像哈希不一致" 2>/dev/null
        return 1
    }

    if [ "$resume_reboot" = 1 ]; then
        charging_set_operation_phase REBOOT_REQUIRED \
            "正在回滚失败刷写，并保留原有待重启状态" 2>/dev/null
    else
        charging_set_operation_phase ROLLING_BACK \
            "正在恢复刷写前 DTBO" 2>/dev/null
    fi
    charging_msg "! 刷写或校验失败，正在恢复刷写前 DTBO"
    charging_write_partition "$CHARGING_PREPARED_ROLLBACK" "$part" || {
        charging_set_operation_phase RESCUE_REQUIRED "自动恢复写入失败" 2>/dev/null
        return 1
    }
    restored_hash="$(charging_sha256 "$part")" || {
        charging_set_operation_phase RESCUE_REQUIRED "自动恢复后无法读取哈希" 2>/dev/null
        return 1
    }
    if [ "$restored_hash" != "$rollback_hash" ]; then
        charging_set_operation_phase RESCUE_REQUIRED "自动恢复哈希失败" 2>/dev/null
        return 1
    fi

    # 更新已有补丁失败时，把活动所有权状态切回刷写前补丁；失败目标仍作为
    # previous 保留，因此即使状态切换中断，两边哈希都继续属于本模块。
    if [ "$rollback_hash" != "$CHARGING_STATE_ORIGINAL_HASH" ]; then
        charging_state_patch_config_for_hash "$rollback_hash" || {
            charging_set_operation_phase RESCUE_REQUIRED "回滚镜像缺少对应的所有权配置" 2>/dev/null
            return 1
        }
        rollback_pps55="$CHARGING_MATCHED_PPS55"
        rollback_pd_qc_27w="$CHARGING_MATCHED_PD_QC_27W"
        failed_hash="$CHARGING_STATE_PATCHED_HASH"
        failed_pps55="$CHARGING_STATE_PPS55"
        failed_pd_qc_27w="$CHARGING_STATE_PD_QC_27W"
        CHARGING_ORIGINAL_HASH="$CHARGING_STATE_ORIGINAL_HASH"
        CHARGING_ORIGINAL_SIZE="$CHARGING_STATE_IMAGE_SIZE"
        charging_commit_state_transaction "$CHARGING_PREPARED_DIR" "$CHARGING_SELECTED_SLOT" \
            "$rollback_hash" "$rollback_pps55" "$rollback_pd_qc_27w" \
            "$failed_hash" "$failed_pps55" "$failed_pd_qc_27w" || {
            charging_set_operation_phase RESCUE_REQUIRED "DTBO 已回滚，但旧所有权状态恢复失败" 2>/dev/null
            return 1
        }
    fi

    if [ "$resume_reboot" = 1 ]; then
        CHARGING_REBOOT_REQUIRED=1
        charging_set_operation_phase REBOOT_REQUIRED \
            "刷写失败后已恢复刷写前 DTBO，并保留原有待重启状态" 2>/dev/null
    else
        CHARGING_REBOOT_REQUIRED=0
        charging_set_operation_phase UNCHANGED \
            "刷写失败后已恢复刷写前 DTBO；本次没有留下分区变化" 2>/dev/null
    fi
    return 0
}

charging_prepared_field() {
    local key="$1" file="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1
}

charging_prepared_load_dir() {
    local dir="$1" enforce_context="${2:-1}" verify_avb="${3:-1}"
    local file base raw image rollback
    local value actual_hash actual_size

    case "$enforce_context:$verify_avb" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac

    file="$dir/prepare.conf"
    base="$dir/base.img"
    raw="$dir/raw_dtbo.img"
    image="$dir/patched_dtbo.img"
    rollback="$dir/current.img"

    [ -r "$file" ] && [ -r "$base" ] && [ -r "$raw" ] && [ -r "$image" ] && \
        [ -r "$rollback" ] || return 1
    [ "$(charging_prepared_field format "$file")" = 2 ] || return 1

    CHARGING_PREPARED_SLOT="$(charging_prepared_field slot "$file")"
    CHARGING_PREPARED_CONFIG_HASH="$(charging_prepared_field config_sha256 "$file")"
    CHARGING_PREPARED_RECIPE_HASH="$(charging_prepared_field recipe_sha256 "$file")"
    CHARGING_PREPARED_FINGERPRINT_HASH="$(charging_prepared_field fingerprint_sha256 "$file")"
    CHARGING_PREPARED_GENERATED_AT="$(charging_prepared_field generated_at "$file")"
    CHARGING_PREPARED_LIVE_HASH="$(charging_prepared_field live_sha256 "$file")"
    CHARGING_PREPARED_ORIGINAL_HASH="$(charging_prepared_field original_sha256 "$file")"
    CHARGING_PREPARED_IMAGE_SIZE="$(charging_prepared_field image_size "$file")"
    CHARGING_PREPARED_RAW_HASH="$(charging_prepared_field raw_sha256 "$file")"
    CHARGING_PREPARED_PATCHED_HASH="$(charging_prepared_field patched_sha256 "$file")"
    CHARGING_PREPARED_PPS55="$(charging_prepared_field pps55 "$file")"
    CHARGING_PREPARED_PD_QC_27W="$(charging_prepared_field pd_qc_27w "$file")"
    CHARGING_PREPARED_SELECTED_COUNT="$(charging_prepared_field selected_dtb_count "$file")"
    CHARGING_PREPARED_TOTAL_COUNT="$(charging_prepared_field total_dtb_count "$file")"
    CHARGING_PREPARED_VERIFICATION="$(charging_prepared_field verification "$file")"
    CHARGING_PREPARED_VERIFIED_HASH="$(charging_prepared_field verified_patched_sha256 "$file")"
    CHARGING_PREPARED_VERIFIED_AT="$(charging_prepared_field verified_at "$file")"

    [ "$CHARGING_PREPARED_SLOT" = "$CHARGING_SELECTED_SLOT" ] || return 1
    for value in "$CHARGING_PREPARED_CONFIG_HASH" "$CHARGING_PREPARED_RECIPE_HASH" \
        "$CHARGING_PREPARED_FINGERPRINT_HASH" "$CHARGING_PREPARED_LIVE_HASH" \
        "$CHARGING_PREPARED_ORIGINAL_HASH" "$CHARGING_PREPARED_RAW_HASH" \
        "$CHARGING_PREPARED_PATCHED_HASH" "$CHARGING_PREPARED_VERIFIED_HASH"; do
        [ "${#value}" -eq 64 ] || return 1
        case "$value" in *[!0-9a-f]*) return 1 ;; esac
    done
    [ "$CHARGING_PREPARED_VERIFICATION" = "$CHARGING_CANDIDATE_VERIFICATION_SCHEME" ] || return 1
    [ "$CHARGING_PREPARED_VERIFIED_HASH" = "$CHARGING_PREPARED_PATCHED_HASH" ] || return 1
    case "$CHARGING_PREPARED_GENERATED_AT" in ''|*[!0-9]*) return 1 ;; esac
    case "$CHARGING_PREPARED_VERIFIED_AT" in ''|*[!0-9]*) return 1 ;; esac
    case "$CHARGING_PREPARED_IMAGE_SIZE" in ''|*[!0-9]*) return 1 ;; esac
    case "$CHARGING_PREPARED_SELECTED_COUNT" in ''|*[!0-9]*) return 1 ;; esac
    case "$CHARGING_PREPARED_TOTAL_COUNT" in ''|*[!0-9]*) return 1 ;; esac
    [ "$CHARGING_PREPARED_SELECTED_COUNT" -gt 0 ] && \
        [ "$CHARGING_PREPARED_SELECTED_COUNT" -le "$CHARGING_PREPARED_TOTAL_COUNT" ] || return 1
    charging_is_bool "$CHARGING_PREPARED_PPS55" || return 1
    charging_is_bool "$CHARGING_PREPARED_PD_QC_27W" || return 1
    if [ "$enforce_context" = 1 ]; then
        charging_prepared_context_matches || return 1
    fi

    actual_hash="$(charging_sha256 "$base")" || return 1
    [ "$actual_hash" = "$CHARGING_PREPARED_ORIGINAL_HASH" ] || return 1
    actual_size="$(charging_file_size "$base")"
    [ "$actual_size" = "$CHARGING_PREPARED_IMAGE_SIZE" ] || return 1
    actual_hash="$(charging_sha256 "$raw")" || return 1
    [ "$actual_hash" = "$CHARGING_PREPARED_RAW_HASH" ] || return 1
    actual_hash="$(charging_sha256 "$image")" || return 1
    [ "$actual_hash" = "$CHARGING_PREPARED_PATCHED_HASH" ] || return 1
    actual_size="$(charging_file_size "$image")"
    [ "$actual_size" = "$CHARGING_PREPARED_IMAGE_SIZE" ] || return 1
    actual_hash="$(charging_sha256 "$rollback")" || return 1
    [ "$actual_hash" = "$CHARGING_PREPARED_LIVE_HASH" ] || return 1
    actual_size="$(charging_file_size "$rollback")"
    [ "$actual_size" = "$CHARGING_PREPARED_IMAGE_SIZE" ] || return 1
    if [ "$verify_avb" = 1 ]; then
        avb_verify_dtbo_image "$base" "$raw" "$image" || return 1
    fi
    return 0
}

charging_prepared_context_matches() {
    local config_hash recipe_hash fingerprint_hash
    config_hash="$(charging_config_hash)" || return 1
    recipe_hash="$(charging_recipe_hash)" || return 1
    fingerprint_hash="$(charging_system_fingerprint_hash)" || return 1
    [ "$CHARGING_PREPARED_CONFIG_HASH" = "$config_hash" ] || return 1
    [ "$CHARGING_PREPARED_RECIPE_HASH" = "$recipe_hash" ] || return 1
    [ "$CHARGING_PREPARED_FINGERPRINT_HASH" = "$fingerprint_hash" ] || return 1
    [ "$CHARGING_PREPARED_PPS55" = "${PPS55_ENABLE:-0}" ] || return 1
    [ "$CHARGING_PREPARED_PD_QC_27W" = "${PD_QC_27W_ENABLE:-0}" ] || return 1
    return 0
}

charging_verify_protocol_list_delta() {
    local base="$1" candidate="$2" base_cpa candidate_cpa
    local base_values candidate_values expected= type power type_key
    local found_pps=0 found_pd=0 found_qc=0
    base_cpa="$(charging_symbol_path "$base" oplus_cpa)" || return 1
    candidate_cpa="$(charging_symbol_path "$candidate" oplus_cpa)" || return 1
    [ "$base_cpa" = "$candidate_cpa" ] || return 1
    base_values="$("$CHARGING_FDTGET" -t x "$base" "$base_cpa" \
        oplus,protocol_list 2>/dev/null)" || return 1
    candidate_values="$("$CHARGING_FDTGET" -t x "$candidate" "$candidate_cpa" \
        oplus,protocol_list 2>/dev/null)" || return 1
    set -- $base_values
    [ "$#" -gt 0 ] && [ $(( $# % 2 )) -eq 0 ] || return 1
    while [ "$#" -gt 0 ]; do
        type="$1"
        power="$2"
        shift 2
        type_key="$(charging_normalize_hex_list "$type")" || return 1
        case "$type_key" in
            2)
                found_pps=1
                [ "${PPS55_ENABLE:-0}" = 1 ] && power=37
                ;;
            1)
                found_pd=1
                [ "${PD_QC_27W_ENABLE:-0}" = 1 ] && power=1b
                ;;
            5)
                found_qc=1
                [ "${PD_QC_27W_ENABLE:-0}" = 1 ] && power=1b
                ;;
        esac
        expected="$expected $type $power"
    done
    [ "${PPS55_ENABLE:-0}" = 0 ] || [ "$found_pps" = 1 ] || return 1
    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        [ "$found_pd" = 1 ] && [ "$found_qc" = 1 ] || return 1
    fi
    charging_hex_lists_equal "${expected# }" "$candidate_values"
}

charging_verify_wired_node_delta() {
    local base="$1" candidate="$2" base_node="$3" candidate_node="$4" rel="$5"
    local values expected actual
    "$CHARGING_FDTGET" -t x "$base" "$base_node" \
        oplus_spec,pd-iclmax-ma >/dev/null 2>&1 || return 1
    "$CHARGING_FDTGET" -t x "$base" "$base_node" \
        oplus_spec,qc-iclmax-ma >/dev/null 2>&1 || return 1
    values="$("$CHARGING_FDTGET" -t x "$base" "$base_node" \
        oplus_spec,input-power-mw 2>/dev/null)" || return 1
    set -- $values
    [ "$#" -eq 7 ] || return 1
    expected="$1 $2 $3 $4 $5 6978 6978"
    actual="$("$CHARGING_FDTGET" -t x "$candidate" "$candidate_node" \
        oplus_spec,input-power-mw 2>/dev/null)" || return 1
    charging_hex_lists_equal "$expected" "$actual" || return 1
    values="$("$CHARGING_FDTGET" -t x "$base" "$base_node" \
        oplus_spec,cool_down_pdqc_curr_ma 2>/dev/null)" || return 1
    charging_hex_lists_equal "4b0 5dc 7d0" "$values" || \
        charging_hex_lists_equal "4b0 5dc bb8" "$values" || return 1
    charging_verify_wired_node "$candidate" "$candidate_node" "$rel"
}

charging_allow_property() {
    printf '%s\t%s\n' "$2" "$3" >> "$1"
}

charging_build_target_allowlist() {
    local base="$1" candidate="$2" output="$3"
    local base_cpa candidate_cpa base_pps candidate_pps base_wired candidate_wired
    local rel prop values node candidate_node
    : > "$output" || return 1

    base_cpa="$(charging_symbol_path "$base" oplus_cpa)" || return 1
    candidate_cpa="$(charging_symbol_path "$candidate" oplus_cpa)" || return 1
    [ "$base_cpa" = "$candidate_cpa" ] || return 1
    charging_allow_property "$output" "$base_cpa" oplus,protocol_list || return 1

    if [ "${PPS55_ENABLE:-0}" = 1 ]; then
        base_pps="$(charging_symbol_path "$base" oplus_pps_charge)" || return 1
        candidate_pps="$(charging_symbol_path "$candidate" oplus_pps_charge)" || return 1
        [ "$base_pps" = "$candidate_pps" ] || return 1
        while read -r rel prop values; do
            case "$rel" in ''|'#'*) continue ;; esac
            [ -n "$prop" ] && [ -n "$values" ] || return 1
            if [ "$rel" = . ]; then
                node="$base_pps"
            else
                node="$base_pps$rel"
            fi
            charging_allow_property "$output" "$node" "$prop" || return 1
        done < "$CHARGING_PPS_CELLS"
    fi

    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        base_wired="$(charging_symbol_path "$base" oplus_chg_wired)" || return 1
        candidate_wired="$(charging_symbol_path "$candidate" oplus_chg_wired)" || return 1
        [ "$base_wired" = "$candidate_wired" ] || return 1
        for rel in . /silicon_p_770; do
            if [ "$rel" = . ]; then
                node="$base_wired"
                candidate_node="$candidate_wired"
            else
                node="$base_wired$rel"
                candidate_node="$candidate_wired$rel"
            fi
            [ "$node" = "$candidate_node" ] || return 1
            for prop in \
                oplus_spec,pd-iclmax-ma \
                oplus_spec,qc-iclmax-ma \
                oplus_spec,input-power-mw \
                oplus_spec,cool_down_pdqc_curr_ma \
                oplus_spec,fccmax-ma-lv \
                oplus_spec,fccmax-ma-hv; do
                charging_allow_property "$output" "$node" "$prop" || return 1
            done
        done
    fi
    LC_ALL=C sort -u "$output" > "$output.sorted" || return 1
    mv -f "$output.sorted" "$output"
}

charging_verify_binary_allowlist_delta() {
    local base="$1" candidate="$2" allowlist="$3" work="$4" verify_started="$5"
    local normalized base_values restore_rows tab node prop property_values
    local count=0 current=0
    normalized="$work/candidate.normalized.dtb"
    base_values="$work/base-allowed.values"
    restore_rows="$work/restore.tsv"
    cp -f "$candidate" "$normalized" || {
        charging_fail "白名单复核失败：无法建立候选归一化副本"
        return 1
    }

    set -- "$CHARGING_FDTGET" -t bx "$base"
    tab="$(printf '\t')"
    while IFS="$tab" read -r node prop; do
        [ -n "$node" ] && [ -n "$prop" ] || {
            charging_fail "白名单复核失败：允许修改的属性清单格式错误"
            return 1
        }
        set -- "$@" "$node" "$prop"
        count=$((count + 1))
    done < "$allowlist"
    [ "$count" -gt 0 ] || {
        charging_fail "白名单复核失败：允许修改的属性清单为空"
        return 1
    }

    charging_progress_elapsed "$verify_started" \
        "白名单复核：正在从原始目标 DTB 批量读取 $count 个允许修改属性的原始字节"
    "$@" > "$base_values" 2>/dev/null || {
        charging_fail "白名单复核失败：无法批量读取原始属性；清单可能与基线不匹配"
        return 1
    }
    awk -F '\t' '
        NR == FNR {
            nodes[FNR] = $1
            props[FNR] = $2
            count = FNR
            next
        }
        {
            value_count++
            if (value_count <= count) {
                printf "%s\t%s\t%s\n", nodes[value_count], props[value_count], $0
            }
        }
        END {
            if (count == 0 || value_count != count) {
                exit 1
            }
        }
    ' "$allowlist" "$base_values" > "$restore_rows" || {
        charging_fail "白名单复核失败：原始属性数量与白名单不一致"
        return 1
    }

    charging_progress_elapsed "$verify_started" \
        "白名单复核：正在把候选副本反向归一化为原始属性，0/$count"
    while IFS="$tab" read -r node prop property_values; do
        [ -n "$node" ] && [ -n "$prop" ] || {
            charging_fail "白名单复核失败：反向归一化数据格式错误"
            return 1
        }
        # property_values is hexadecimal byte data emitted by the trusted fdtget binary.
        # shellcheck disable=SC2086
        "$CHARGING_FDTPUT" -t bx "$normalized" "$node" "$prop" \
            $property_values >/dev/null 2>&1 || {
            charging_fail "白名单复核失败：无法恢复 $node/$prop 的原始字节"
            return 1
        }
        current=$((current + 1))
        if charging_progress_checkpoint "$current" "$count" 25; then
            charging_progress_elapsed "$verify_started" \
                "白名单复核：候选副本反向归一化 $current/$count"
        fi
    done < "$restore_rows"
    [ "$current" -eq "$count" ] || {
        charging_fail "白名单复核失败：反向归一化属性数量不完整"
        return 1
    }

    charging_progress_elapsed "$verify_started" \
        "白名单复核：正在完整比较原始目标 DTB 与反向归一化候选"
    cmp -s "$base" "$normalized" || {
        charging_fail "白名单复核失败：候选在允许修改的属性之外仍存在二进制差异"
        return 1
    }
    charging_progress_elapsed "$verify_started" \
        "白名单复核通过：反向恢复白名单属性后，候选与原始目标 DTB 完全一致"
    return 0
}

charging_verify_target_dtb_delta() {
    local base="$1" candidate="$2" work="$3"
    local allowlist
    local base_wired candidate_wired rel base_node candidate_node verify_started
    allowlist="$work/allowed.tsv"
    verify_started="$(charging_epoch_seconds 2>/dev/null)" || verify_started=

    charging_progress_elapsed "$verify_started" \
        "白名单复核：正在确认协议、PPS 与 PD/QC 目标属性"
    charging_build_target_allowlist "$base" "$candidate" "$allowlist" || return 1
    charging_verify_protocol_list_delta "$base" "$candidate" || return 1
    charging_verify_dtb "$candidate" || return 1
    if [ "${PD_QC_27W_ENABLE:-0}" = 1 ]; then
        base_wired="$(charging_symbol_path "$base" oplus_chg_wired)" || return 1
        candidate_wired="$(charging_symbol_path "$candidate" oplus_chg_wired)" || return 1
        [ "$base_wired" = "$candidate_wired" ] || return 1
        for rel in . /silicon_p_770; do
            if [ "$rel" = . ]; then
                base_node="$base_wired"
                candidate_node="$candidate_wired"
            else
                base_node="$base_wired$rel"
                candidate_node="$candidate_wired$rel"
            fi
            charging_verify_wired_node_delta \
                "$base" "$candidate" "$base_node" "$candidate_node" "$rel" || return 1
        done
    fi
    charging_verify_binary_allowlist_delta \
        "$base" "$candidate" "$allowlist" "$work" "$verify_started"
}

charging_verify_candidate_semantics() {
    local base="$1" raw="$2" image="$3" expected_selected="$4" expected_total="$5" work="$6"
    local base_dir candidate_dir index=0 selected=0 base_total=0 candidate_total=0
    local base_dtb candidate_dtb base_target candidate_target target_work
    rm -rf "$work"
    base_dir="$work/base"
    candidate_dir="$work/candidate"
    mkdir -p "$base_dir" "$candidate_dir" || return 1
    charging_verify_container_layout "$base" "$raw" "$expected_total" || return 1
    avb_verify_dtbo_image "$base" "$raw" "$image" || return 1
    "$CHARGING_MKDTIMG" dump "$base" -b "$base_dir/dtb" >/dev/null 2>&1 || return 1
    "$CHARGING_MKDTIMG" dump "$raw" -b "$candidate_dir/dtb" >/dev/null 2>&1 || return 1
    while [ -f "$base_dir/dtb.$base_total" ]; do
        base_total=$((base_total + 1))
    done
    while [ -f "$candidate_dir/dtb.$candidate_total" ]; do
        candidate_total=$((candidate_total + 1))
    done
    [ "$base_total" -eq "$expected_total" ] && \
        [ "$candidate_total" -eq "$expected_total" ] || return 1

    while [ "$index" -lt "$expected_total" ]; do
        base_dtb="$base_dir/dtb.$index"
        candidate_dtb="$candidate_dir/dtb.$index"
        charging_progress \
            "独立语义校验：正在核对子镜像 $((index + 1))/$expected_total"
        base_target=0
        candidate_target=0
        charging_is_target_dtb "$base_dtb" && base_target=1
        charging_is_target_dtb "$candidate_dtb" && candidate_target=1
        [ "$base_target" = "$candidate_target" ] || return 1
        if [ "$base_target" = 1 ]; then
            selected=$((selected + 1))
            target_work="$work/target_$index"
            mkdir -p "$target_work" || return 1
            charging_verify_target_dtb_delta \
                "$base_dtb" "$candidate_dtb" "$target_work" || return 1
            charging_progress \
                "独立语义校验：目标子镜像 $((index + 1))/$expected_total 通过白名单复核"
        else
            cmp -s "$base_dtb" "$candidate_dtb" || {
                charging_fail "独立语义校验失败：非目标子镜像 $((index + 1))/$expected_total 发生变化"
                return 1
            }
            charging_progress \
                "独立语义校验：非目标子镜像 $((index + 1))/$expected_total 保持不变"
        fi
        index=$((index + 1))
    done
    [ "$selected" -eq "$expected_selected" ]
}

charging_verify_prepared_candidate() {
    local slot work verify_started result=1
    charging_validate_request || return 1
    slot="$(charging_active_slot)" || return 1
    charging_select_slot_state "$slot" || return 1
    charging_require_tools || return 1
    charging_prepared_load_dir "$CHARGING_PREPARED_DIR" 1 0 || {
        charging_fail "候选镜像完整性、配置、系统版本或生成规则校验失败；请重新生成"
        return 1
    }
    work="$CHARGING_RESCUE_DIR/.candidate_verify_${slot#_}.$$"
    rm -rf "$work"
    mkdir -p "$work" || return 1
    chmod 0700 "$work" 2>/dev/null || {
        rm -rf "$work"
        return 1
    }
    verify_started="$(charging_epoch_seconds 2>/dev/null)" || verify_started=
    charging_progress_elapsed "$verify_started" \
        "正在只读反向归一化候选白名单属性，并与可信基线进行完整二进制比较"
    if charging_verify_candidate_semantics \
        "$CHARGING_PREPARED_BASE" "$CHARGING_PREPARED_RAW" \
        "$CHARGING_PREPARED_IMAGE" "$CHARGING_PREPARED_SELECTED_COUNT" \
        "$CHARGING_PREPARED_TOTAL_COUNT" "$work/semantic"; then
        result=0
    fi
    rm -rf "$work"
    if [ "$result" -ne 0 ]; then
        charging_fail "候选镜像未通过独立白名单差异校验；请重新生成"
        return 1
    fi
    charging_progress_elapsed "$verify_started" \
        "候选镜像独立复核通过：仅白名单属性按期望变化，其他内容保持不变"
    return 0
}

charging_discard_prepared() {
    charging_ensure_slot_state || return 1
    case "$CHARGING_PREPARED_DIR" in
        "$CHARGING_RESCUE_DIR"/prepared_a|"$CHARGING_RESCUE_DIR"/prepared_b)
            rm -rf "$CHARGING_PREPARED_DIR"
            ;;
        *) return 1 ;;
    esac
}

charging_discard_prepared_candidate() {
    local slot
    slot="$(charging_active_slot)" || {
        charging_fail "无法识别当前 A/B 槽位，拒绝放弃候选镜像"
        return 1
    }
    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "当前槽位的 DTBO 操作状态损坏或不可读；已保留候选与回滚文件"
        return 1
    }
    if charging_slot_has_unresolved_operation; then
        charging_fail "当前槽位存在未解决的 DTBO 写入、恢复或救援事务；禁止删除候选与回滚文件"
        return 1
    fi
    charging_prepared_status_slot "$slot" || {
        charging_fail "无法核对当前槽位的候选事务；已保留全部文件"
        return 1
    }
    [ "$CHARGING_PREPARED_PRESENT" = 1 ] || {
        charging_fail "当前活动槽位没有可放弃的候选镜像"
        return 1
    }
    [ "$CHARGING_PREPARED_PROBLEM" = 0 ] && \
        [ "$CHARGING_PREPARED_SAFE" = 1 ] || {
        charging_fail "无法证明候选事务尚未影响未知 DTBO；已保留候选与 current.img"
        return 1
    }
    charging_discard_prepared || {
        charging_fail "候选目录清理失败；手机 DTBO 分区没有写入"
        return 1
    }
    sync || {
        charging_fail "候选目录已删除，但文件系统同步失败；手机 DTBO 分区没有写入"
        return 1
    }
    charging_msg "- 已放弃槽位 $slot 的候选镜像；配置、原始备份和手机 DTBO 均未改变"
    return 0
}

charging_slot_has_state_artifacts() {
    [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ] || \
        [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ] || \
        [ -e "$CHARGING_STATE_PREVIOUS" ] || [ -e "$CHARGING_BACKUP_PREVIOUS" ]
}

charging_slot_has_prepared_artifacts() {
    local slot="${1:-$CHARGING_SELECTED_SLOT}" suffix path
    case "$slot" in _a|_b) suffix="${slot#_}" ;; *) return 1 ;; esac
    for path in \
        "$CHARGING_RESCUE_DIR/prepared_${suffix}" \
        "$CHARGING_RESCUE_DIR"/.prepared_"${suffix}".* \
        "$CHARGING_RESCUE_DIR"/prepared_"${suffix}".previous.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        return 0
    done
    return 1
}

charging_slot_has_unresolved_operation() {
    charging_ensure_slot_state || return 1
    [ -e "$CHARGING_OPERATION_FILE" ] || [ -L "$CHARGING_OPERATION_FILE" ] || return 1
    # 文件存在却无法解析时无法证明事务已经安全结束，必须保守保留。
    charging_operation_load || return 0
    case "$CHARGING_OPERATION_PHASE" in
        FLASHING|RESTORING|ROLLING_BACK|RESCUE_REQUIRED) return 0 ;;
        *) return 1 ;;
    esac
}

charging_resolve_unowned_operation() {
    local slot="$1" part current_hash detail
    charging_select_slot_state "$slot" || return 1
    [ -e "$CHARGING_OPERATION_FILE" ] || [ -L "$CHARGING_OPERATION_FILE" ] || return 0
    charging_operation_load || {
        CHARGING_RESCUE_REQUIRED=1
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；已原样保留并拒绝继续"
        return 1
    }
    case "$CHARGING_OPERATION_PHASE" in
        RESCUE_REQUIRED)
            CHARGING_RESCUE_REQUIRED=1
            charging_fail "槽位 $slot 仍处于人工救援状态：${CHARGING_OPERATION_DETAIL:-原因未记录}"
            return 1
            ;;
        FLASHING|RESTORING|ROLLING_BACK) ;;
        *) return 0 ;;
    esac

    part="$(charging_dtbo_partition "$slot")" || {
        detail="中断的 $CHARGING_OPERATION_PHASE 事务缺少可识别的 DTBO 分区"
        charging_set_operation_phase RESCUE_REQUIRED "$detail" 2>/dev/null
        CHARGING_RESCUE_REQUIRED=1
        charging_fail "$detail；请勿重启"
        return 1
    }
    current_hash="$(charging_sha256 "$part")" || {
        detail="中断的 $CHARGING_OPERATION_PHASE 事务无法读取当前 DTBO 哈希"
        charging_set_operation_phase RESCUE_REQUIRED "$detail" 2>/dev/null
        CHARGING_RESCUE_REQUIRED=1
        charging_fail "$detail；请勿重启"
        return 1
    }
    # 调用方已经确认该槽位没有可验证的 state/backup，不能让内存中可能残留
    # 的上一槽位或已删除状态参与所有权判断。
    CHARGING_STATE_VALID=0
    charging_promote_interrupted_operation_to_rescue "$current_hash" || {
        charging_fail "槽位 $slot 的中断事务无法持久化为人工救援状态"
        return 1
    }
    charging_fail "槽位 $slot 存在中断的 DTBO 关键事务且正式所有权状态缺失；已标记人工救援，请勿重启"
    return 1
}

charging_prepared_status_slot() {
    local slot="$1" suffix path part current_hash
    CHARGING_PREPARED_PRESENT=0
    CHARGING_PREPARED_SAFE=0
    CHARGING_PREPARED_PROBLEM=0
    CHARGING_PREPARED_PROBLEM_DETAIL=
    CHARGING_CANDIDATE_INTEGRITY_VALID=0
    CHARGING_CANDIDATE_CONTEXT_VALID=0
    CHARGING_CANDIDATE_LIVE_MATCH=0
    CHARGING_CANDIDATE_READY=0
    CHARGING_CANDIDATE_RELATION=unavailable
    CHARGING_CANDIDATE_ISSUE_KIND=
    charging_select_slot_state "$slot" || return 1
    suffix="${slot#_}"

    for path in \
        "$CHARGING_RESCUE_DIR"/.prepared_"${suffix}".* \
        "$CHARGING_RESCUE_DIR"/prepared_"${suffix}".previous.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        CHARGING_PREPARED_PRESENT=1
        CHARGING_PREPARED_PROBLEM=1
        CHARGING_CANDIDATE_ISSUE_KIND=transaction-interrupted
        CHARGING_PREPARED_PROBLEM_DETAIL="槽位 $slot 存在未完成的准备目录交换：$path"
        return 0
    done

    [ -e "$CHARGING_PREPARED_DIR" ] || [ -L "$CHARGING_PREPARED_DIR" ] || return 0
    CHARGING_PREPARED_PRESENT=1
    if [ ! -d "$CHARGING_PREPARED_DIR" ] || [ -L "$CHARGING_PREPARED_DIR" ]; then
        CHARGING_PREPARED_PROBLEM=1
        CHARGING_CANDIDATE_ISSUE_KIND=unsafe-path
        CHARGING_PREPARED_PROBLEM_DETAIL="槽位 $slot 的准备路径不是普通目录"
        return 0
    fi
    part="$(charging_dtbo_partition "$slot")" || {
        CHARGING_PREPARED_PROBLEM=1
        CHARGING_CANDIDATE_ISSUE_KIND=missing-partition
        CHARGING_PREPARED_PROBLEM_DETAIL="找不到槽位 $slot 的 DTBO 分区，无法判断准备事务是否写入"
        return 0
    }
    current_hash="$(charging_sha256 "$part")" || {
        CHARGING_PREPARED_PROBLEM=1
        CHARGING_CANDIDATE_ISSUE_KIND=read-failed
        CHARGING_PREPARED_PROBLEM_DETAIL="无法读取槽位 $slot 的 DTBO 哈希"
        return 0
    }
    if ! charging_prepared_load_dir "$CHARGING_PREPARED_DIR" 0 0; then
        CHARGING_CANDIDATE_ISSUE_KIND=candidate-invalid
        CHARGING_PREPARED_PROBLEM_DETAIL="槽位 $slot 的候选镜像格式过旧、文件不完整或完整性校验失败"
        if charging_slot_has_state_artifacts && charging_state_load && \
            [ "$CHARGING_STATE_SLOT" = "$slot" ] && charging_state_hash_owned "$current_hash"; then
            CHARGING_PREPARED_SAFE=1
            return 0
        fi
        CHARGING_PREPARED_PROBLEM=1
        return 0
    fi
    CHARGING_CANDIDATE_INTEGRITY_VALID=1
    if [ "$current_hash" = "$CHARGING_PREPARED_PATCHED_HASH" ]; then
        CHARGING_CANDIDATE_RELATION=same
    else
        CHARGING_CANDIDATE_RELATION=different
    fi
    if [ "$current_hash" = "$CHARGING_PREPARED_LIVE_HASH" ]; then
        CHARGING_PREPARED_SAFE=1
        CHARGING_CANDIDATE_LIVE_MATCH=1
    elif charging_slot_has_state_artifacts && charging_state_load && \
        [ "$CHARGING_STATE_SLOT" = "$slot" ] && charging_state_hash_owned "$current_hash"; then
        # 正式所有权状态已经覆盖 prepared/current.img 的救援作用；恢复流程会
        # 优先按正式状态处理，成功后才删除准备目录。
        CHARGING_PREPARED_SAFE=1
    else
        CHARGING_PREPARED_PROBLEM=1
        CHARGING_CANDIDATE_ISSUE_KIND=phone-changed-unknown
        CHARGING_PREPARED_PROBLEM_DETAIL="槽位 $slot 的手机 DTBO 已偏离候选生成时镜像，且没有可验证的正式所有权状态"
        return 0
    fi

    if charging_prepared_context_matches; then
        CHARGING_CANDIDATE_CONTEXT_VALID=1
    else
        CHARGING_CANDIDATE_ISSUE_KIND=context-stale
        CHARGING_PREPARED_PROBLEM_DETAIL="候选镜像与当前配置、系统版本或模块生成规则不一致"
        return 0
    fi
    if [ "$CHARGING_CANDIDATE_LIVE_MATCH" != 1 ]; then
        CHARGING_CANDIDATE_ISSUE_KIND=phone-changed
        CHARGING_PREPARED_PROBLEM_DETAIL="手机 DTBO 在候选生成后已经变化，请重新生成候选镜像"
        return 0
    fi
    CHARGING_CANDIDATE_READY=1
    return 0
}

charging_resolve_prepared_without_state() {
    local slot="$1" detail
    charging_prepared_status_slot "$slot" || return 1
    [ "$CHARGING_PREPARED_PRESENT" = 1 ] || return 0
    if charging_slot_has_unresolved_operation; then
        charging_operation_load || {
            CHARGING_RESCUE_REQUIRED=1
            charging_fail "槽位 $slot 同时存在损坏的 DTBO 操作状态；已保留全部准备/回滚文件"
            return 1
        }
        if [ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ]; then
            CHARGING_RESCUE_REQUIRED=1
            charging_fail "槽位 $slot 仍处于人工救援状态；已保留全部准备/回滚文件"
            return 1
        fi
    fi
    if [ "$CHARGING_PREPARED_SAFE" = 1 ]; then
        charging_select_slot_state "$slot" || return 1
        if charging_operation_requires_rescue "$CHARGING_PREPARED_LIVE_HASH"; then
            charging_promote_interrupted_operation_to_rescue \
                "$CHARGING_PREPARED_LIVE_HASH" || {
                charging_fail "准备事务看似未写入分区，但无法持久化已有关键事务的救援状态"
                return 1
            }
            charging_fail "槽位 $slot 仍有未解决的关键 DTBO 事务；保留候选与 current.img，请勿重启"
            return 1
        fi
        charging_discard_prepared || return 1
        sync || return 1
        charging_set_operation_phase UNCHANGED \
            "准备事务尚未写入 DTBO，已安全清理候选镜像" 2>/dev/null || return 1
        charging_msg "- 槽位 $slot 的 DTBO 未被候选事务改动，已清理残留准备文件"
        return 0
    fi
    detail="${CHARGING_PREPARED_PROBLEM_DETAIL:-槽位 $slot 的准备事务无法安全自动处理}"
    charging_select_slot_state "$slot" || return 1
    charging_set_operation_phase RESCUE_REQUIRED "$detail" 2>/dev/null || return 1
    CHARGING_RESCUE_REQUIRED=1
    charging_fail "$detail；已保留 current.img 等救援文件，请勿重启"
    return 1
}

charging_has_unresolved_rescue_artifacts() {
    local path operation phase format slot expected_slot
    [ -d "$CHARGING_RESCUE_DIR" ] || return 1
    for path in \
        "$CHARGING_RESCUE_DIR"/prepared_a \
        "$CHARGING_RESCUE_DIR"/prepared_b \
        "$CHARGING_RESCUE_DIR"/.prepared_a.* \
        "$CHARGING_RESCUE_DIR"/.prepared_b.* \
        "$CHARGING_RESCUE_DIR"/prepared_a.previous.* \
        "$CHARGING_RESCUE_DIR"/prepared_b.previous.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        return 0
    done
    for operation in \
        "$CHARGING_RESCUE_DIR/operation_a.conf" \
        "$CHARGING_RESCUE_DIR/operation_b.conf"; do
        [ -e "$operation" ] || [ -L "$operation" ] || continue
        [ -r "$operation" ] || return 0
        case "$operation" in
            */operation_a.conf) expected_slot=_a ;;
            */operation_b.conf) expected_slot=_b ;;
        esac
        format="$(sed -n 's/^format=//p' "$operation" 2>/dev/null | head -n 1)"
        slot="$(sed -n 's/^slot=//p' "$operation" 2>/dev/null | head -n 1)"
        phase="$(sed -n 's/^phase=//p' "$operation" 2>/dev/null | head -n 1)"
        [ "$format" = 1 ] && [ "$slot" = "$expected_slot" ] || return 0
        case "$phase" in
            FLASHING|RESTORING|ROLLING_BACK|RESCUE_REQUIRED) return 0 ;;
        esac
    done
    return 1
}

charging_cleanup_stale_prepared_slot() {
    local slot="$1" suffix path pid_suffix canonical previous_dir= previous_count=0
    case "$slot" in
        _a|_b) suffix="${slot#_}" ;;
        *) return 1 ;;
    esac
    [ -d "$CHARGING_RESCUE_DIR" ] || return 0
    [ "${PFFM_LOCK_HELD:-0}" = 1 ] || {
        charging_fail "未持有全局运行锁，拒绝清理槽位 $slot 的准备临时目录"
        return 1
    }

    canonical="$CHARGING_RESCUE_DIR/prepared_${suffix}"
    for path in "$CHARGING_RESCUE_DIR"/prepared_"${suffix}".previous.*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        pid_suffix="${path##*.}"
        case "$pid_suffix" in
            ''|*[!0-9]*)
                charging_fail "准备临时目录名称异常，拒绝自动删除：$path"
                return 1
                ;;
        esac
        [ -d "$path" ] && [ ! -L "$path" ] || {
            charging_fail "准备临时路径不是普通目录，拒绝自动删除：$path"
            return 1
        }
        previous_count=$((previous_count + 1))
        previous_dir="$path"
    done

    [ "$previous_count" -le 1 ] || {
        charging_fail "发现多个待恢复的旧准备目录，拒绝自动选择：槽位 $slot"
        return 1
    }
    if [ "$previous_count" = 1 ]; then
        if [ -e "$canonical" ] || [ -L "$canonical" ]; then
            [ -d "$canonical" ] && [ ! -L "$canonical" ] || {
                charging_fail "正式准备路径不是普通目录，拒绝删除旧准备目录：$canonical"
                return 1
            }
            # 新正式目录只有在再次确认全局持久化后，才允许删除交换时保留的旧目录。
            sync || {
                charging_fail "正式准备目录尚未确认持久化，继续保留旧准备目录：$previous_dir"
                return 1
            }
            rm -rf "$previous_dir" || {
                charging_fail "无法清理已由正式目录取代的旧准备目录：$previous_dir"
                return 1
            }
            charging_log INFO "removed superseded charging prepare directory: $previous_dir"
        else
            mv "$previous_dir" "$canonical" || {
                charging_fail "无法恢复中断前的正式准备目录：$previous_dir"
                return 1
            }
            sync || {
                charging_fail "恢复后的正式准备目录无法持久化：$canonical"
                return 1
            }
            charging_msg "- 已恢复上次目录交换中断前的槽位 $slot 准备事务"
            charging_log WARN "recovered interrupted charging prepare directory: $canonical"
        fi
    fi

    for path in "$CHARGING_RESCUE_DIR"/.prepared_"${suffix}".*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        pid_suffix="${path##*.}"
        case "$pid_suffix" in
            ''|*[!0-9]*)
                charging_fail "准备临时目录名称异常，拒绝自动删除：$path"
                return 1
                ;;
        esac
        [ -d "$path" ] && [ ! -L "$path" ] || {
            charging_fail "准备临时路径不是普通目录，拒绝自动删除：$path"
            return 1
        }
        rm -rf "$path" || {
            charging_fail "无法清理中断遗留的工作目录：$path"
            return 1
        }
        charging_log INFO "removed stale charging prepare directory: $path"
    done
    return 0
}

charging_cleanup_stale_prepared_all() {
    local slot result=0
    for slot in _a _b; do
        charging_cleanup_stale_prepared_slot "$slot" || result=1
    done
    return "$result"
}

charging_cleanup_stale_prepared_all_for_slot() {
    local slot="$1"
    case "$slot" in _a|_b) ;; *) return 1 ;; esac
    charging_cleanup_stale_prepared_all || return 1
    # 上面的遍历会把 CHARGING_* 全局路径停在最后一个槽位；调用方后续
    # 生成或提交文件前必须恢复自己正在处理的槽位上下文。
    charging_select_slot_state "$slot"
}

charging_backup_original_slot() {
    local slot="$1" part capture expected_hash expected_size actual_hash actual_size suffix
    CHARGING_BACKUP_SLOT_RESULT=
    [ "${PFFM_LOCK_HELD:-0}" = 1 ] || {
        charging_fail "未持有全局运行锁，拒绝处理槽位 $slot 的原始备份"
        return 1
    }
    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；拒绝建立或覆盖备份"
        return 1
    }

    if charging_slot_has_state_artifacts; then
        charging_state_load || {
            charging_fail "槽位 $slot 已存在但无法校验的备份/状态；为保留救援证据，拒绝覆盖"
            return 1
        }
        [ "$CHARGING_STATE_SLOT" = "$slot" ] || {
            charging_fail "槽位 $slot 的备份状态内容与路径不一致；拒绝覆盖"
            return 1
        }
        CHARGING_BACKUP_SLOT_RESULT=verified
        charging_msg "- 槽位 $slot 已有有效原始 DTBO 备份，已重新校验且未覆盖"
        return 0
    fi

    if charging_slot_has_unresolved_operation; then
        charging_fail "槽位 $slot 存在未解决的 DTBO 关键事务；拒绝把当前分区登记为原始备份"
        return 1
    fi
    if charging_slot_has_prepared_artifacts "$slot"; then
        charging_prepared_status_slot "$slot" || return 1
        if [ "$CHARGING_PREPARED_PROBLEM" = 1 ] || [ "$CHARGING_PREPARED_SAFE" != 1 ]; then
            charging_fail "槽位 $slot 存在无法证明未写分区的准备事务；拒绝建立原始备份"
            return 1
        fi
    fi

    part="$(charging_dtbo_partition "$slot")" || {
        charging_fail "找不到槽位 $slot 的 DTBO 分区"
        return 1
    }
    [ -r "$part" ] || {
        charging_fail "槽位 $slot 的 DTBO 分区不可读"
        return 1
    }
    expected_hash="$(charging_trusted_original_hash "$slot")" || return 1
    expected_size="$(charging_trusted_original_size "$slot")" || return 1
    suffix="${slot#_}"
    charging_ensure_rescue_dir || return 1
    # 全局锁保证同一时刻只有一个备份进程；使用固定临时名，进程中断后下一次
    # 可以安全覆盖，不会按 PID 永久堆积 24 MiB 残留文件。
    capture="$CHARGING_RESCUE_DIR/.original_capture_${suffix}.img"
    rm -f "$capture"
    if ! dd if="$part" of="$capture" bs=4096 2>/dev/null; then
        rm -f "$capture"
        charging_fail "读取槽位 $slot 的 DTBO 分区失败"
        return 1
    fi
    chmod 0600 "$capture" 2>/dev/null || {
        rm -f "$capture"
        return 1
    }
    actual_hash="$(charging_sha256 "$capture")" || {
        rm -f "$capture"
        return 1
    }
    actual_size="$(charging_file_size "$capture")"
    if [ "$actual_hash" != "$expected_hash" ] || [ "$actual_size" != "$expected_size" ]; then
        rm -f "$capture"
        charging_fail "槽位 $slot 当前 DTBO 不匹配受信任的 PJZ110 A77 原始哈希；可能已打补丁、已 OTA 或属于未知版本，拒绝冒充原始备份"
        return 1
    fi
    if charging_image_has_avb_footer "$capture"; then
        if ! avb_parse_dtbo_image "$capture"; then
            rm -f "$capture"
            charging_fail "槽位 $slot 的镜像带有 AVB Footer，但结构校验失败：$AVB_ERROR"
            return 1
        fi
        charging_msg "- 槽位 $slot 的可信原始哈希、完整大小和 AVB Footer 均已确认"
    else
        charging_msg "- 槽位 $slot 的可信原始哈希和完整大小已确认；该原厂镜像不含 AVB Footer"
    fi
    charging_commit_original_backup "$capture" "$slot" "$actual_hash" "$actual_size" || {
        rm -f "$capture"
        return 1
    }
    rm -f "$capture"
    charging_set_operation_phase ORIGINAL \
        "已独立建立并校验原始 DTBO 备份；分区未修改" || return 1
    CHARGING_BACKUP_SLOT_RESULT=created
    charging_msg "- 槽位 $slot 的原始 DTBO 已独立备份并校验；没有写入分区"
    return 0
}

charging_backup_original_all() {
    local slot result=0
    CHARGING_BACKUP_CREATED_SLOTS=
    CHARGING_BACKUP_VERIFIED_SLOTS=
    CHARGING_BACKUP_FAILED_SLOTS=
    charging_preflight_backup || return 1
    charging_import_previous_state || {
        charging_fail "继承上一版本 DTBO 状态失败"
        return 1
    }
    for slot in _a _b; do
        if charging_backup_original_slot "$slot"; then
            case "$CHARGING_BACKUP_SLOT_RESULT" in
                created) CHARGING_BACKUP_CREATED_SLOTS="$CHARGING_BACKUP_CREATED_SLOTS $slot" ;;
                verified) CHARGING_BACKUP_VERIFIED_SLOTS="$CHARGING_BACKUP_VERIFIED_SLOTS $slot" ;;
            esac
        else
            CHARGING_BACKUP_FAILED_SLOTS="$CHARGING_BACKUP_FAILED_SLOTS $slot"
            result=1
        fi
    done
    if [ "$result" -ne 0 ]; then
        charging_fail "原始 DTBO 备份未全部完成；已成功建立或校验的槽位不会回滚，失败槽位：${CHARGING_BACKUP_FAILED_SLOTS# }"
        return 1
    fi
    charging_msg "- A/B 原始 DTBO 备份均已建立或通过校验；整个过程未写入分区"
    return 0
}

charging_restore_plan_field() {
    local key="$1"
    sed -n "s/^${key}=//p" "$CHARGING_RESTORE_PLAN" 2>/dev/null | head -n 1
}

charging_prepare_restore_requested() {
    local active_slot slot part current_hash original_hash
    local config_hash recipe_hash fingerprint_hash generated_at tmp
    local current_a= current_b= original_a= original_b=
    charging_validate_request || return 1
    [ "${CHARGING_DTBO_ENABLE:-0}" = 0 ] || {
        charging_fail "当前配置仍启用充电补丁，拒绝生成恢复计划"
        return 1
    }
    charging_require_backup_tools || return 1
    charging_import_previous_state || return 1
    active_slot="$(charging_active_slot)" || return 1
    charging_ensure_rescue_dir || return 1
    for slot in _a _b; do
        charging_select_slot_state "$slot" || return 1
        charging_operation_validate_existing || {
            charging_fail "槽位 $slot 的操作状态损坏，拒绝生成恢复计划"
            return 1
        }
        part="$(charging_dtbo_partition "$slot")" || return 1
        current_hash="$(charging_sha256 "$part")" || return 1
        original_hash=
        if charging_slot_has_state_artifacts; then
            charging_state_load || {
                charging_fail "槽位 $slot 的原始备份或所有权状态校验失败"
                return 1
            }
            [ "$CHARGING_STATE_SLOT" = "$slot" ] && \
                charging_state_hash_owned "$current_hash" || {
                charging_fail "槽位 $slot 的手机 DTBO 不属于原始镜像或本模块已登记补丁"
                return 1
            }
            original_hash="$CHARGING_STATE_ORIGINAL_HASH"
        elif charging_slot_has_prepared_artifacts "$slot" || \
            charging_slot_has_unresolved_operation; then
            charging_fail "槽位 $slot 存在未解决的候选或关键事务，拒绝生成恢复计划"
            return 1
        fi
        case "$slot" in
            _a) current_a="$current_hash"; original_a="$original_hash" ;;
            _b) current_b="$current_hash"; original_b="$original_hash" ;;
        esac
    done
    config_hash="$(charging_config_hash)" || return 1
    recipe_hash="$(charging_recipe_hash)" || return 1
    fingerprint_hash="$(charging_system_fingerprint_hash)" || return 1
    generated_at="$(charging_epoch_seconds)" || return 1
    tmp="$CHARGING_RESTORE_PLAN.tmp.$$"
    {
        printf 'format=1\n'
        printf 'active_slot=%s\n' "$active_slot"
        printf 'config_sha256=%s\n' "$config_hash"
        printf 'recipe_sha256=%s\n' "$recipe_hash"
        printf 'fingerprint_sha256=%s\n' "$fingerprint_hash"
        printf 'generated_at=%s\n' "$generated_at"
        printf 'current_a_sha256=%s\n' "$current_a"
        printf 'current_b_sha256=%s\n' "$current_b"
        printf 'original_a_sha256=%s\n' "$original_a"
        printf 'original_b_sha256=%s\n' "$original_b"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$CHARGING_RESTORE_PLAN" || {
        rm -f "$tmp"
        return 1
    }
    sync || return 1
    charging_msg "- 恢复条件已校验并持久化；尚未写入任何 DTBO 分区"
    return 0
}

charging_restore_plan_load() {
    local active_slot config_hash recipe_hash fingerprint_hash slot part current expected original
    [ -r "$CHARGING_RESTORE_PLAN" ] || return 1
    [ "$(charging_restore_plan_field format)" = 1 ] || return 1
    active_slot="$(charging_active_slot)" || return 1
    [ "$(charging_restore_plan_field active_slot)" = "$active_slot" ] || return 1
    config_hash="$(charging_config_hash)" || return 1
    recipe_hash="$(charging_recipe_hash)" || return 1
    fingerprint_hash="$(charging_system_fingerprint_hash)" || return 1
    [ "$(charging_restore_plan_field config_sha256)" = "$config_hash" ] || return 1
    [ "$(charging_restore_plan_field recipe_sha256)" = "$recipe_hash" ] || return 1
    [ "$(charging_restore_plan_field fingerprint_sha256)" = "$fingerprint_hash" ] || return 1
    for slot in _a _b; do
        charging_select_slot_state "$slot" || return 1
        part="$(charging_dtbo_partition "$slot")" || return 1
        current="$(charging_sha256 "$part")" || return 1
        expected="$(charging_restore_plan_field current_${slot#_}_sha256)"
        charging_is_sha256_value "$expected" && [ "$current" = "$expected" ] || return 1
        original="$(charging_restore_plan_field original_${slot#_}_sha256)"
        if [ -n "$original" ]; then
            charging_state_load || return 1
            [ "$CHARGING_STATE_SLOT" = "$slot" ] && \
                [ "$CHARGING_STATE_ORIGINAL_HASH" = "$original" ] && \
                charging_state_hash_owned "$current" || return 1
        fi
    done
    return 0
}

charging_commit_restore_prepared() {
    [ "${CHARGING_DTBO_ENABLE:-0}" = 0 ] || return 1
    avb_require_unlocked_bootloader || {
        charging_fail "拒绝恢复 DTBO：$AVB_ERROR"
        return 1
    }
    charging_restore_plan_load || {
        charging_fail "恢复计划与当前配置、槽位、手机 DTBO 或原始备份不再一致；请重新校验恢复条件"
        return 1
    }
    charging_restore_all_owned || return 1
    rm -f "$CHARGING_RESTORE_PLAN"
    sync || return 1
    return 0
}

charging_prepare_requested() {
    local slot part suffix work output raw patched_hash raw_hash state_file old_dir prepare_started
    local config_hash recipe_hash fingerprint_hash generated_at verified_at

    CHARGING_PREPARE_OUTCOME=
    charging_validate_request || return 1
    if [ "${CHARGING_DTBO_ENABLE:-0}" = 0 ] || \
        { [ "${PPS55_ENABLE:-0}" = 0 ] && [ "${PD_QC_27W_ENABLE:-0}" = 0 ]; }; then
        charging_fail "当前配置没有启用充电 DTBO 补丁，无需生成刷写镜像"
        return 1
    fi
    charging_preflight_apply || return 1
    charging_import_previous_state || {
        charging_fail "继承上一版本 DTBO 状态失败"
        return 1
    }
    slot="$(charging_active_slot)" || return 1
    charging_backup_original_slot "$slot" || {
        charging_fail "当前槽位没有可验证的可信原始备份；候选镜像未生成"
        return 1
    }
    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；已保留原文件并拒绝提交候选镜像"
        return 1
    }
    part="$(charging_dtbo_partition "$slot")" || return 1
    charging_ensure_rescue_dir || return 1
    suffix="${slot#_}"
    charging_cleanup_stale_prepared_all_for_slot "$slot" || return 1
    work="$CHARGING_RESCUE_DIR/.prepared_${suffix}.$$"
    output="$work/patched_dtbo.img"
    raw="$work/raw_dtbo.img"
    rm -rf "$work"
    mkdir -p "$work" || return 1
    chmod 0700 "$work" 2>/dev/null || {
        rm -rf "$work"
        return 1
    }

    prepare_started="$(charging_epoch_seconds 2>/dev/null)" || prepare_started=
    charging_progress_elapsed "$prepare_started" "- 正在读取当前槽位 DTBO：$part"
    charging_prepare_base "$work" "$slot" "$part" || {
        rm -rf "$work"
        return 1
    }
    charging_progress_elapsed "$prepare_started" \
        "- 正在离线生成并校验 PJZ110 Android 15 充电补丁（本阶段不写分区）"
    charging_build_image "$work/base.img" "$output" "$work" || {
        rm -rf "$work"
        return 1
    }
    charging_progress_elapsed "$prepare_started" "- 正在计算裸容器和候选镜像哈希"
    patched_hash="$(charging_sha256 "$output")" || {
        rm -rf "$work"
        return 1
    }
    raw_hash="$(charging_sha256 "$raw")" || {
        rm -rf "$work"
        return 1
    }
    config_hash="$(charging_config_hash)" || {
        rm -rf "$work"
        return 1
    }
    recipe_hash="$(charging_recipe_hash)" || {
        rm -rf "$work"
        return 1
    }
    fingerprint_hash="$(charging_system_fingerprint_hash)" || {
        rm -rf "$work"
        return 1
    }
    generated_at="$(charging_epoch_seconds)" || {
        rm -rf "$work"
        return 1
    }
    verified_at="$generated_at"
    state_file="$work/prepare.conf"
    {
        printf 'format=2\n'
        printf 'slot=%s\n' "$slot"
        printf 'config_sha256=%s\n' "$config_hash"
        printf 'recipe_sha256=%s\n' "$recipe_hash"
        printf 'fingerprint_sha256=%s\n' "$fingerprint_hash"
        printf 'generated_at=%s\n' "$generated_at"
        printf 'live_sha256=%s\n' "$CHARGING_CURRENT_HASH"
        printf 'original_sha256=%s\n' "$CHARGING_ORIGINAL_HASH"
        printf 'image_size=%s\n' "$CHARGING_ORIGINAL_SIZE"
        printf 'raw_sha256=%s\n' "$raw_hash"
        printf 'patched_sha256=%s\n' "$patched_hash"
        printf 'pps55=%s\n' "${PPS55_ENABLE:-0}"
        printf 'pd_qc_27w=%s\n' "${PD_QC_27W_ENABLE:-0}"
        printf 'selected_dtb_count=%s\n' "$CHARGING_SELECTED_DTB_COUNT"
        printf 'total_dtb_count=%s\n' "$CHARGING_TOTAL_DTB_COUNT"
        printf 'verification=%s\n' "$CHARGING_CANDIDATE_VERIFICATION_SCHEME"
        printf 'verified_patched_sha256=%s\n' "$patched_hash"
        printf 'verified_at=%s\n' "$verified_at"
    } > "$state_file" || {
        rm -rf "$work"
        return 1
    }
    chmod 0600 "$work/base.img" "$work/current.img" "$raw" "$output" "$state_file" 2>/dev/null || {
        rm -rf "$work"
        return 1
    }
    charging_progress_elapsed "$prepare_started" "- 正在复核临时离线准备事务"
    charging_prepared_load_dir "$work" 1 0 || {
        rm -rf "$work"
        charging_fail "离线生成的 DTBO 准备事务复核失败：${AVB_ERROR:-metadata invalid}"
        return 1
    }
    charging_progress_elapsed "$prepare_started" \
        "- 正在独立核验候选属性白名单、非目标内容、容器和 AVB"
    charging_verify_candidate_semantics \
        "$work/base.img" "$raw" "$output" "$CHARGING_PREPARED_SELECTED_COUNT" \
        "$CHARGING_PREPARED_TOTAL_COUNT" "$work/semantic" || {
        rm -rf "$work"
        charging_fail "候选镜像独立语义校验失败；未持久化候选，也未写分区"
        return 1
    }
    rm -rf "$work/dtb" "$work/verify" "$work/semantic"
    charging_progress_elapsed "$prepare_started" "- 正在同步并持久化离线准备事务"
    sync || {
        rm -rf "$work"
        charging_fail "离线 DTBO 准备事务无法持久化"
        return 1
    }

    old_dir="$CHARGING_PREPARED_DIR.previous.$$"
    rm -rf "$old_dir"
    if [ -e "$CHARGING_PREPARED_DIR" ]; then
        mv "$CHARGING_PREPARED_DIR" "$old_dir" || {
            rm -rf "$work"
            return 1
        }
    fi
    if ! mv "$work" "$CHARGING_PREPARED_DIR"; then
        [ ! -e "$old_dir" ] || mv "$old_dir" "$CHARGING_PREPARED_DIR" 2>/dev/null
        rm -rf "$work"
        return 1
    fi
    sync || {
        charging_fail "离线 DTBO 准备事务目录无法持久化"
        return 1
    }
    rm -rf "$old_dir"
    charging_progress_elapsed "$prepare_started" "- 正在复核持久化后的离线准备事务"
    charging_prepared_load_dir "$CHARGING_PREPARED_DIR" 1 0 || {
        charging_discard_prepared
        charging_fail "持久化后的 DTBO 准备事务复核失败"
        return 1
    }
    if [ "$CHARGING_PREPARED_PATCHED_HASH" = "$CHARGING_PREPARED_LIVE_HASH" ]; then
        charging_discard_prepared || {
            charging_fail "候选与手机当前 DTBO 相同，但无法清理无需写入的候选目录"
            return 1
        }
        sync || {
            charging_fail "无需写入的候选目录已删除，但文件系统同步失败"
            return 1
        }
        CHARGING_PREPARE_OUTCOME=already-current
        charging_progress_elapsed "$prepare_started" \
            "- 已独立验证 $CHARGING_PREPARED_SELECTED_COUNT/$CHARGING_PREPARED_TOTAL_COUNT 个 DTBO 子镜像；手机当前 DTBO 已符合期望，无需写入，候选已清理"
        return 0
    fi
    CHARGING_PREPARE_OUTCOME=candidate-ready
    charging_progress_elapsed "$prepare_started" \
        "- 已独立验证 $CHARGING_PREPARED_SELECTED_COUNT/$CHARGING_PREPARED_TOTAL_COUNT 个 DTBO 子镜像；尚未写入分区"
    return 0
}

charging_commit_prepared() {
    local slot part current_hash current_after patched_hash resume_reboot=0 state_present=0
    local previous_hash= previous_pps55=0 previous_pd_qc_27w=0

    charging_validate_request || return 1
    if [ "${CHARGING_DTBO_ENABLE:-0}" = 0 ] || \
        { [ "${PPS55_ENABLE:-0}" = 0 ] && [ "${PD_QC_27W_ENABLE:-0}" = 0 ]; }; then
        charging_fail "当前配置没有启用充电 DTBO 补丁，拒绝提交旧的准备事务"
        return 1
    fi
    charging_preflight_apply || return 1
    charging_import_previous_state || {
        charging_fail "继承上一版本 DTBO 状态失败"
        return 1
    }
    slot="$(charging_active_slot)" || return 1
    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；已保留原文件并拒绝提交候选镜像"
        return 1
    }
    part="$(charging_dtbo_partition "$slot")" || return 1
    charging_prepared_load_dir "$CHARGING_PREPARED_DIR" || {
        charging_fail "没有与当前配置匹配且完整的 DTBO 准备事务；请重新生成后再提交"
        return 1
    }
    patched_hash="$CHARGING_PREPARED_PATCHED_HASH"

    current_hash="$(charging_sha256 "$part")" || return 1
    [ "$current_hash" = "$CHARGING_PREPARED_LIVE_HASH" ] || {
        charging_fail "DTBO 分区在离线准备后已经变化；旧候选镜像已拒绝，请重新生成"
        return 1
    }

    if [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ] || \
        [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ] || \
        [ -e "$CHARGING_STATE_PREVIOUS" ] || [ -e "$CHARGING_BACKUP_PREVIOUS" ]; then
        state_present=1
        charging_state_load || {
            charging_fail "写分区前已有 DTBO 备份/状态复核失败"
            return 1
        }
        [ "$CHARGING_STATE_ORIGINAL_HASH" = "$CHARGING_PREPARED_ORIGINAL_HASH" ] || {
            charging_fail "准备事务的原始基线与当前救援状态不一致；拒绝提交"
            return 1
        }
        charging_state_hash_owned "$current_hash" || {
            charging_fail "写分区前当前 DTBO 已不属于原始、目标或上一合法补丁；拒绝提交"
            return 1
        }
        if charging_operation_requires_reboot "$current_hash"; then
            resume_reboot=1
        fi
        if [ "$current_hash" != "$CHARGING_STATE_ORIGINAL_HASH" ]; then
            charging_state_patch_config_for_hash "$current_hash" || {
                charging_fail "写分区前无法确定当前合法补丁对应的配置"
                return 1
            }
            if [ "$current_hash" != "$patched_hash" ]; then
                previous_hash="$current_hash"
                previous_pps55="$CHARGING_MATCHED_PPS55"
                previous_pd_qc_27w="$CHARGING_MATCHED_PD_QC_27W"
            elif [ "$current_hash" = "$CHARGING_STATE_PATCHED_HASH" ]; then
                previous_hash="$CHARGING_STATE_PREVIOUS_PATCHED_HASH"
                previous_pps55="$CHARGING_STATE_PREVIOUS_PPS55"
                previous_pd_qc_27w="$CHARGING_STATE_PREVIOUS_PD_QC_27W"
            fi
        fi
    else
        [ "$current_hash" = "$CHARGING_PREPARED_ORIGINAL_HASH" ] || {
            charging_fail "首次建立所有权前当前 DTBO 与准备事务原始基线不一致"
            return 1
        }
    fi

    CHARGING_ORIGINAL_HASH="$CHARGING_PREPARED_ORIGINAL_HASH"
    CHARGING_ORIGINAL_SIZE="$CHARGING_PREPARED_IMAGE_SIZE"
    CHARGING_SELECTED_DTB_COUNT="$CHARGING_PREPARED_SELECTED_COUNT"
    CHARGING_TOTAL_DTB_COUNT="$CHARGING_PREPARED_TOTAL_COUNT"

    charging_commit_state_transaction "$CHARGING_PREPARED_DIR" "$slot" "$patched_hash" \
        "$CHARGING_PREPARED_PPS55" "$CHARGING_PREPARED_PD_QC_27W" \
        "$previous_hash" "$previous_pps55" "$previous_pd_qc_27w" || {
        charging_fail "提交 DTBO 备份/所有权状态事务失败"
        return 1
    }
    charging_set_operation_phase BACKUP_DURABLE "原始 DTBO 备份已持久化" || {
        charging_fail "无法记录 DTBO 操作状态"
        return 1
    }
    sync || {
        charging_fail "原始 DTBO 备份无法持久化"
        return 1
    }
    charging_state_load_pair "$CHARGING_STATE_FILE" "$CHARGING_BACKUP" || {
        charging_fail "写分区前救援备份复核失败"
        return 1
    }

    if [ "$current_hash" = "$patched_hash" ]; then
        charging_msg "- 当前 DTBO 已是所需配置，无需重复刷写"
        if [ "$resume_reboot" = 1 ]; then
            CHARGING_REBOOT_REQUIRED=1
            charging_set_operation_phase REBOOT_REQUIRED \
                "已恢复上次中断后的补丁重启提示" || {
                charging_fail "DTBO 已匹配补丁，但无法持久化必须重启状态"
                return 1
            }
            charging_msg "- 检测到本次启动内中断的刷写事务，仍必须重启"
        else
            charging_set_operation_phase UNCHANGED "当前 DTBO 已匹配所需配置" 2>/dev/null
        fi
        charging_discard_prepared
        return 0
    fi

    charging_msg "- 已验证并修改 $CHARGING_SELECTED_DTB_COUNT/$CHARGING_TOTAL_DTB_COUNT 个 DTBO 子镜像，正在刷写"
    charging_set_operation_phase FLASHING "正在写入当前槽位 DTBO" || {
        charging_fail "无法进入安全刷写阶段"
        return 1
    }
    sync || {
        charging_fail "刷写阶段状态无法持久化"
        return 1
    }
    charging_begin_partition_critical || {
        charging_fail "无法保护 DTBO 刷写临界区"
        return 1
    }
    if ! charging_write_partition "$CHARGING_PREPARED_IMAGE" "$part"; then
        if charging_restore_after_flash_failure "$part" \
            "$CHARGING_PREPARED_LIVE_HASH" "$resume_reboot"; then
            charging_discard_prepared
        else
            charging_msg "! 自动恢复失败，请勿重启；优先手动刷回 $CHARGING_PREPARED_ROLLBACK，原始救援备份为 $CHARGING_BACKUP"
        fi
        charging_end_partition_critical
        return 1
    fi
    current_after="$(charging_sha256 "$part")"
    if [ "$current_after" != "$patched_hash" ]; then
        if charging_restore_after_flash_failure "$part" \
            "$CHARGING_PREPARED_LIVE_HASH" "$resume_reboot"; then
            charging_discard_prepared
        else
            charging_msg "! 自动恢复失败，请勿重启；优先手动刷回 $CHARGING_PREPARED_ROLLBACK，原始救援备份为 $CHARGING_BACKUP"
        fi
        charging_end_partition_critical
        return 1
    fi

    CHARGING_REBOOT_REQUIRED=1
    if ! charging_set_operation_phase REBOOT_REQUIRED \
        "补丁写入及完整哈希校验成功，等待重启"; then
        charging_end_partition_critical
        charging_fail "补丁已写入，但无法持久化必须重启状态"
        return 1
    fi
    charging_end_partition_critical
    charging_msg "- 充电 DTBO 刷写及完整哈希校验成功；重启后生效"
    charging_log INFO "charging DTBO applied slot=$slot pps55=${PPS55_ENABLE:-0} pd_qc_27w=${PD_QC_27W_ENABLE:-0} hash=$patched_hash"
    charging_discard_prepared
    return 0
}

charging_apply_requested() {
    charging_validate_request || return 1
    if [ "${CHARGING_DTBO_ENABLE:-0}" = 0 ] || \
        { [ "${PPS55_ENABLE:-0}" = 0 ] && [ "${PD_QC_27W_ENABLE:-0}" = 0 ]; }; then
        charging_restore_all_owned
        return $?
    fi
    charging_prepare_requested || return 1
    charging_commit_prepared
}

charging_restore_slot() {
    local slot="$1" active_slot="${2:-}" part current_hash restored_hash resume_reboot=0
    local rescue_pending=0 rescue_detail=
    charging_select_slot_state "$slot" || return 1
    charging_operation_validate_existing || {
        charging_fail "槽位 $slot 的 DTBO 操作状态损坏或不可读；已保留原文件并拒绝覆盖或恢复"
        return 1
    }
    [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ] || \
        [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ] || \
        [ -e "$CHARGING_STATE_PREVIOUS" ] || [ -e "$CHARGING_BACKUP_PREVIOUS" ] || {
        return 0
    }
    charging_state_load || {
        charging_fail "槽位 $slot 的 DTBO 备份/状态校验失败，拒绝执行不安全恢复"
        return 1
    }
    [ "$slot" = "$CHARGING_STATE_SLOT" ] || {
        charging_fail "槽位 $slot 的状态文件内容不匹配"
        return 1
    }
    if [ -z "$active_slot" ]; then
        active_slot="$(charging_active_slot)" || {
            charging_fail "无法识别当前 A/B 活动槽位，拒绝写入任何 DTBO 分区"
            return 1
        }
    fi
    case "$active_slot" in
        _a|_b) ;;
        *)
            charging_fail "活动槽位值异常，拒绝写入任何 DTBO 分区：$active_slot"
            return 1
            ;;
    esac
    part="$(charging_dtbo_partition "$slot")" || {
        charging_fail "找不到槽位 $slot 的 DTBO 分区"
        return 1
    }
    current_hash="$(charging_sha256 "$part")" || return 1
    if charging_operation_requires_rescue "$current_hash"; then
        charging_promote_interrupted_operation_to_rescue "$current_hash" || {
            charging_fail "中断事务对应未知 DTBO，但无法持久化人工救援状态"
            return 1
        }
        rescue_pending=1
        rescue_detail="$CHARGING_OPERATION_DETAIL"
    fi
    if charging_operation_requires_reboot "$current_hash"; then
        resume_reboot=1
    fi
    if [ "$current_hash" = "$CHARGING_STATE_ORIGINAL_HASH" ]; then
        charging_msg "- 槽位 $slot 的 DTBO 已是保存的原始镜像"
        if [ "$active_slot" = "$slot" ] && [ "$resume_reboot" = 1 ]; then
            CHARGING_REBOOT_REQUIRED=1
            charging_set_operation_phase REBOOT_REQUIRED \
                "已恢复上次中断后的原始镜像重启提示" || {
                charging_fail "原始 DTBO 已匹配，但无法持久化必须重启状态"
                return 1
            }
            charging_msg "- 检测到本次启动内中断的恢复事务，仍必须重启"
        else
            charging_set_operation_phase ORIGINAL "当前分区已经是原始 DTBO" 2>/dev/null
        fi
        return 0
    fi
    if ! charging_state_patch_config_for_hash "$current_hash"; then
        charging_msg "! 槽位 $slot 的 DTBO 已被 OTA 或其他工具修改；保留救援备份并拒绝覆盖"
        charging_log WARN "refuse DTBO restore slot=$slot: current hash is not module-owned"
        if [ "$rescue_pending" = 1 ]; then
            charging_set_operation_phase RESCUE_REQUIRED \
                "${rescue_detail:-当前分区处于未知或不完整写入状态}" 2>/dev/null
        else
            charging_set_operation_phase FOREIGN "当前分区不属于本模块" 2>/dev/null
        fi
        return 1
    fi

    charging_msg "- 正在恢复槽位 $slot 的原始 DTBO"
    charging_set_operation_phase RESTORING "正在恢复原始 DTBO" || return 1
    sync || return 1
    charging_begin_partition_critical || return 1
    charging_write_partition "$CHARGING_BACKUP" "$part" || {
        charging_set_operation_phase RESCUE_REQUIRED "原始 DTBO 恢复写入失败" 2>/dev/null
        charging_end_partition_critical
        return 1
    }
    restored_hash="$(charging_sha256 "$part")" || {
        charging_set_operation_phase RESCUE_REQUIRED "原始 DTBO 恢复后无法读取哈希" 2>/dev/null
        charging_end_partition_critical
        return 1
    }
    [ "$restored_hash" = "$CHARGING_STATE_ORIGINAL_HASH" ] || {
        charging_set_operation_phase RESCUE_REQUIRED "原始 DTBO 恢复后哈希不一致" 2>/dev/null
        charging_end_partition_critical
        charging_fail "原始 DTBO 恢复后哈希校验失败"
        return 1
    }
    if [ "$active_slot" = "$slot" ]; then
        CHARGING_REBOOT_REQUIRED=1
        if ! charging_set_operation_phase REBOOT_REQUIRED \
            "原始 DTBO 已恢复并校验，等待重启"; then
            charging_end_partition_critical
            charging_fail "原始 DTBO 已恢复，但无法持久化必须重启状态"
            return 1
        fi
    else
        charging_set_operation_phase RESTORED "非活动槽位原始 DTBO 已恢复并校验" 2>/dev/null
    fi
    charging_end_partition_critical
    charging_msg "- 槽位 $slot 的原始 DTBO 已恢复并校验"
    charging_log INFO "charging DTBO restored slot=$slot hash=$restored_hash"
    return 0
}

charging_restore_owned() {
    local slot candidate
    slot="$(charging_active_slot)" || {
        for candidate in _a _b; do
            charging_select_slot_state "$candidate" || continue
            if [ -e "$CHARGING_STATE_FILE" ] || [ -e "$CHARGING_BACKUP" ] || \
                [ -e "$CHARGING_STATE_PENDING" ] || [ -e "$CHARGING_BACKUP_PENDING" ] || \
                [ -e "$CHARGING_STATE_PREVIOUS" ] || [ -e "$CHARGING_BACKUP_PREVIOUS" ] || \
                charging_slot_has_prepared_artifacts "$candidate" || \
                charging_slot_has_unresolved_operation; then
                charging_fail "无法识别当前 A/B 槽位，不能判断已有救援备份该恢复到哪个分区"
                return 1
            fi
        done
        charging_msg "- 当前设备没有可识别槽位，也没有本模块持有的 DTBO 备份；无需恢复"
        return 0
    }
    charging_select_slot_state "$slot" || return 1
    charging_cleanup_stale_prepared_slot "$slot" || return 1
    if ! charging_slot_has_state_artifacts; then
        if charging_slot_has_prepared_artifacts "$slot"; then
            charging_resolve_prepared_without_state "$slot" || return 1
        elif charging_slot_has_unresolved_operation; then
            charging_resolve_unowned_operation "$slot" || return 1
        else
            charging_msg "- 当前槽位没有本模块持有的 DTBO 备份，无需恢复"
        fi
        return 0
    fi
    charging_restore_slot "$slot" "$slot" || return 1
    charging_select_slot_state "$slot" || return 1
    charging_discard_prepared
}

charging_restore_all_owned() {
    local slot active_slot result=0 found=0
    active_slot="$(charging_active_slot)" || {
        for slot in _a _b; do
            charging_select_slot_state "$slot" || continue
            if charging_slot_has_state_artifacts || \
                charging_slot_has_prepared_artifacts "$slot" || \
                charging_slot_has_unresolved_operation; then
                charging_fail "无法识别当前 A/B 活动槽位；检测到槽位 $slot 的救援状态，拒绝写入或清理"
                return 1
            fi
        done
        charging_msg "- 当前设备没有可识别槽位，也没有本模块持有的 DTBO 救援状态；无需恢复"
        return 0
    }
    charging_cleanup_stale_prepared_all || return 1
    for slot in _a _b; do
        charging_select_slot_state "$slot" || {
            result=1
            continue
        }
        if charging_slot_has_state_artifacts; then
            found=1
            if charging_restore_slot "$slot" "$active_slot"; then
                charging_select_slot_state "$slot" || {
                    result=1
                    continue
                }
                charging_discard_prepared || result=1
            else
                # 恢复失败时 prepared/current.img 仍可能是唯一的刷写前完整镜像。
                result=1
            fi
        elif charging_slot_has_prepared_artifacts "$slot"; then
            found=1
            charging_resolve_prepared_without_state "$slot" || result=1
        elif charging_slot_has_unresolved_operation; then
            found=1
            charging_resolve_unowned_operation "$slot" || result=1
        fi
    done
    [ "$found" = 1 ] || charging_msg "- 没有本模块持有的 DTBO 备份，无需恢复"
    return "$result"
}
