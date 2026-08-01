#!/system/bin/sh

# 普通文件回归：已生成候选与当前 DTBO 相同时，准备阶段必须保留事务，
# 提交阶段必须完成状态收尾、保留重启要求且不写入分区。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_already_current_test}
TEST_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rm -rf "$STATE"
mkdir -p "$STATE" || exit 1

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE/prepare"
. "$ROOT/charging_dtbo.sh" || exit 2
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=1

PREPARE_STATE="$STATE/prepare"
PREPARE_CURRENT_FILE="$PREPARE_STATE/current.img"
mkdir -p "$PREPARE_STATE" || exit 3
printf live > "$PREPARE_CURRENT_FILE" || exit 4
PREPARE_CURRENT_HASH="$(charging_sha256 "$PREPARE_CURRENT_FILE")" || exit 5
PREPARE_BASE_HASH="$TEST_HASH"

# 只替换离线生成所需的外部步骤；charging_prepare_requested 本身保持真实实现。
charging_preflight_apply() { return 0; }
charging_import_previous_state() { return 0; }
charging_active_slot() { printf '%s\n' _a; }
charging_dtbo_partition() { printf '%s\n' "$PREPARE_CURRENT_FILE"; }
charging_backup_original_slot() { return 0; }
charging_cleanup_stale_prepared_all_for_slot() {
    charging_select_slot_state "$1"
}
charging_prepare_base() {
    local work="$1"
    printf base > "$work/base.img" || return 1
    printf live > "$work/current.img" || return 1
    CHARGING_CURRENT_HASH="$PREPARE_CURRENT_HASH"
    CHARGING_ORIGINAL_HASH="$PREPARE_BASE_HASH"
    CHARGING_ORIGINAL_SIZE=4
    return 0
}
charging_build_image() {
    local output="$2" work="$3"
    printf raw > "$work/raw_dtbo.img" || return 1
    cp -f "$PREPARE_CURRENT_FILE" "$output" || return 1
    CHARGING_SELECTED_DTB_COUNT=1
    CHARGING_TOTAL_DTB_COUNT=1
    return 0
}
charging_config_hash() { printf '%s\n' "$TEST_HASH"; }
charging_recipe_hash() { printf '%s\n' "$TEST_HASH"; }
charging_system_fingerprint_hash() { printf '%s\n' "$TEST_HASH"; }
charging_verify_candidate_semantics() { return 0; }
charging_prepared_load_dir() {
    CHARGING_PREPARED_SLOT=_a
    CHARGING_PREPARED_CONFIG_HASH="$TEST_HASH"
    CHARGING_PREPARED_RECIPE_HASH="$TEST_HASH"
    CHARGING_PREPARED_FINGERPRINT_HASH="$TEST_HASH"
    CHARGING_PREPARED_GENERATED_AT=1
    CHARGING_PREPARED_LIVE_HASH="$PREPARE_CURRENT_HASH"
    CHARGING_PREPARED_ORIGINAL_HASH="$PREPARE_BASE_HASH"
    CHARGING_PREPARED_IMAGE_SIZE=4
    CHARGING_PREPARED_RAW_HASH="$TEST_HASH"
    CHARGING_PREPARED_PATCHED_HASH="$PREPARE_CURRENT_HASH"
    CHARGING_PREPARED_PPS55=1
    CHARGING_PREPARED_PD_QC_27W=1
    CHARGING_PREPARED_SELECTED_COUNT=1
    CHARGING_PREPARED_TOTAL_COUNT=1
    CHARGING_PREPARED_VERIFICATION=semantic-v3
    CHARGING_PREPARED_VERIFIED_HASH="$PREPARE_CURRENT_HASH"
    CHARGING_PREPARED_VERIFIED_AT=1
    return 0
}

charging_prepare_requested || exit 6
[ "$CHARGING_PREPARE_OUTCOME" = already-current ] || exit 7
[ -d "$CHARGING_PREPARED_DIR" ] || exit 8
echo prepare_keeps_already_current_transaction=ok
rm -rf "$PREPARE_STATE"

# 使用真实 charging_commit_prepared 验证 apply 的无写入收尾路径。
COMMIT_STATE="$STATE/commit"
CHARGING_RESCUE_DIR="$COMMIT_STATE"
. "$ROOT/charging_dtbo.sh" || exit 9
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=1
mkdir -p "$COMMIT_STATE/prepared_a" || exit 9
charging_select_slot_state _a || exit 10

printf base > "$CHARGING_PREPARED_BASE" || exit 11
printf raw > "$CHARGING_PREPARED_RAW" || exit 12
printf live > "$COMMIT_STATE/fake-part.img" || exit 13
cp -f "$COMMIT_STATE/fake-part.img" "$CHARGING_PREPARED_IMAGE" || exit 14
cp -f "$COMMIT_STATE/fake-part.img" "$CHARGING_PREPARED_ROLLBACK" || exit 15
cp -f "$CHARGING_PREPARED_BASE" "$CHARGING_BACKUP" || exit 16

COMMIT_ORIGINAL_HASH="$(charging_sha256 "$CHARGING_PREPARED_BASE")" || exit 17
COMMIT_RAW_HASH="$(charging_sha256 "$CHARGING_PREPARED_RAW")" || exit 18
COMMIT_CURRENT_HASH="$(charging_sha256 "$COMMIT_STATE/fake-part.img")" || exit 19
COMMIT_IMAGE_SIZE="$(charging_file_size "$CHARGING_PREPARED_BASE")"
charging_state_write_file "$CHARGING_STATE_FILE" _a \
    "$COMMIT_ORIGINAL_HASH" "$COMMIT_CURRENT_HASH" "$COMMIT_IMAGE_SIZE" 1 1 || exit 20

# 该用例也可在无 Android /proc 的主机上执行；保留空 boot_id 等价于旧版
# 状态文件，真实 boot/reboot 状态由 reboot_phase_android.sh 覆盖。
charging_set_operation_phase() {
    local phase="$1" detail="${2:-}"
    {
        echo format=1
        echo slot=_a
        echo "phase=$phase"
        echo boot_id=
        echo owner_pid=
        echo owner_start=
        echo "detail=$detail"
        echo "backup=$CHARGING_BACKUP"
    } > "$CHARGING_OPERATION_FILE"
}
charging_set_operation_phase REBOOT_REQUIRED already-current || exit 21

{
    echo format=2
    echo slot=_a
    echo "config_sha256=$TEST_HASH"
    echo "recipe_sha256=$TEST_HASH"
    echo "fingerprint_sha256=$TEST_HASH"
    echo generated_at=1
    echo "live_sha256=$COMMIT_CURRENT_HASH"
    echo "original_sha256=$COMMIT_ORIGINAL_HASH"
    echo "image_size=$COMMIT_IMAGE_SIZE"
    echo "raw_sha256=$COMMIT_RAW_HASH"
    echo "patched_sha256=$COMMIT_CURRENT_HASH"
    echo pps55=1
    echo pd_qc_27w=1
    echo selected_dtb_count=1
    echo total_dtb_count=1
    echo verification=semantic-v3
    echo "verified_patched_sha256=$COMMIT_CURRENT_HASH"
    echo verified_at=1
} > "$CHARGING_PREPARED_STATE" || exit 22

charging_preflight_apply() { return 0; }
charging_import_previous_state() { return 0; }
charging_active_slot() { printf '%s\n' _a; }
charging_dtbo_partition() { printf '%s\n' "$COMMIT_STATE/fake-part.img"; }
charging_prepared_context_matches() { return 0; }
avb_verify_dtbo_image() { return 0; }
charging_prepare_requested() {
    CHARGING_PREPARE_OUTCOME=already-current
    return 0
}
charging_write_partition() {
    touch "$COMMIT_STATE/partition-write-called"
    return 1
}

CHARGING_REBOOT_REQUIRED=0
charging_apply_requested || exit 23
[ "$CHARGING_REBOOT_REQUIRED" = 1 ] || exit 24
[ "$(charging_operation_field phase)" = REBOOT_REQUIRED ] || exit 25
[ ! -e "$CHARGING_PREPARED_DIR" ] || exit 26
[ ! -e "$COMMIT_STATE/partition-write-called" ] || exit 27
[ "$(charging_sha256 "$COMMIT_STATE/fake-part.img")" = "$COMMIT_CURRENT_HASH" ] || exit 28
echo apply_already_current_preserves_reboot_and_skips_partition_write=ok

echo ALREADY_CURRENT_ANDROID_OK
rm -rf "$STATE"
