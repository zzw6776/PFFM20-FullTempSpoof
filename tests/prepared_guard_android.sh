#!/system/bin/sh

# 使用普通文件模拟分区，验证准备事务损坏、配置变化和 live hash 变化都会在写入前拒绝。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_prepared_guard_test}
rm -rf "$STATE"
mkdir -p "$STATE/prepared_a" || exit 1

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE"
. "$ROOT/charging_dtbo.sh" || exit 2
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=1
charging_select_slot_state _a || exit 3

printf 'AAAA' > "$CHARGING_PREPARED_BASE" || exit 4
printf 'BBBB' > "$CHARGING_PREPARED_RAW" || exit 5
printf 'CCCC' > "$CHARGING_PREPARED_IMAGE" || exit 6
printf 'DDDD' > "$STATE/fake-part.img" || exit 7
printf 'EEEE' > "$STATE/expected-live.img" || exit 8
cp -f "$STATE/expected-live.img" "$CHARGING_PREPARED_ROLLBACK" || exit 8

base_hash="$(charging_sha256 "$CHARGING_PREPARED_BASE")" || exit 9
raw_hash="$(charging_sha256 "$CHARGING_PREPARED_RAW")" || exit 10
patched_hash="$(charging_sha256 "$CHARGING_PREPARED_IMAGE")" || exit 11
live_hash="$(charging_sha256 "$STATE/expected-live.img")" || exit 12
{
    echo format=1
    echo slot=_a
    echo "live_sha256=$live_hash"
    echo "original_sha256=$base_hash"
    echo image_size=4
    echo "raw_sha256=$raw_hash"
    echo "patched_sha256=$patched_hash"
    echo pps55=1
    echo pd_qc_27w=1
    echo selected_dtb_count=1
    echo total_dtb_count=2
} > "$CHARGING_PREPARED_STATE" || exit 13

# 本测试只验证事务元数据与提交门禁，AVB 容器本身由 avb_prepare_android.sh 验证。
avb_validate_raw_dtbo() { return 0; }
avb_verify_dtbo_image() { return 0; }
charging_prepared_load_dir "$CHARGING_PREPARED_DIR" || exit 14
echo prepared_metadata_valid=ok

PPS55_ENABLE=0
! charging_prepared_load_dir "$CHARGING_PREPARED_DIR" || exit 15
charging_prepared_load_dir "$CHARGING_PREPARED_DIR" 0 || exit 22
PPS55_ENABLE=1
echo changed_config_rejected_for_commit_but_readable_for_recovery=ok

charging_dtbo_partition() { echo "$STATE/fake-part.img"; }
cp -f "$STATE/expected-live.img" "$STATE/fake-part.img" || exit 23
charging_prepared_status_slot _a || exit 24
[ "$CHARGING_PREPARED_PRESENT" = 1 ] || exit 25
[ "$CHARGING_PREPARED_SAFE" = 1 ] || exit 26
[ "$CHARGING_PREPARED_PROBLEM" = 0 ] || exit 27
echo unchanged_partition_marks_prepared_safe=ok

printf 'XXXX' > "$CHARGING_PREPARED_IMAGE" || exit 16
! charging_prepared_load_dir "$CHARGING_PREPARED_DIR" || exit 17
charging_prepared_status_slot _a || exit 28
[ "$CHARGING_PREPARED_PROBLEM" = 1 ] || exit 29
printf 'CCCC' > "$CHARGING_PREPARED_IMAGE" || exit 18
echo corrupted_candidate_rejected=ok

charging_preflight_apply() { return 0; }
charging_import_previous_state() { return 0; }
charging_active_slot() { echo _a; }
charging_commit_state_transaction() { touch "$STATE/state-commit-called"; return 1; }
charging_write_partition() { touch "$STATE/partition-write-called"; return 1; }

printf 'DDDD' > "$STATE/fake-part.img" || exit 30
! charging_commit_prepared > "$STATE/stale-live.out" 2>&1 || exit 19
[ ! -e "$STATE/state-commit-called" ] || exit 20
[ ! -e "$STATE/partition-write-called" ] || exit 21
echo stale_live_hash_rejected_before_commit=ok

cp -f "$STATE/expected-live.img" "$STATE/fake-part.img" || exit 31
charging_set_operation_phase RESCUE_REQUIRED prior-rescue || exit 36
! charging_resolve_prepared_without_state _a >/dev/null 2>&1 || exit 37
[ -d "$CHARGING_PREPARED_DIR" ] || exit 38
charging_operation_load || exit 39
[ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ] || exit 40
echo prepared_cleanup_does_not_clear_prior_rescue=ok
printf broken-operation > "$CHARGING_OPERATION_FILE" || exit 46
! charging_resolve_prepared_without_state _a >/dev/null 2>&1 || exit 47
[ -d "$CHARGING_PREPARED_DIR" ] || exit 48
echo prepared_cleanup_preserves_invalid_operation_evidence=ok
charging_set_operation_phase UNCHANGED test-reset || exit 41
charging_resolve_prepared_without_state _a || exit 32
[ ! -e "$CHARGING_PREPARED_DIR" ] || exit 33
charging_operation_load || exit 34
[ "$CHARGING_OPERATION_PHASE" = UNCHANGED ] || exit 35
echo safe_uncommitted_prepared_transaction_cleaned=ok

mkdir -p "$STATE/retry-rescue" || exit 42
charging_set_operation_phase RESCUE_REQUIRED prior-rescue || exit 43
! charging_prepare_base "$STATE/retry-rescue" _a "$STATE/fake-part.img" >/dev/null 2>&1 || exit 44
[ ! -e "$STATE/retry-rescue/base.img" ] || exit 45
echo rescue_without_state_cannot_be_rebased_as_original=ok

printf broken-operation > "$CHARGING_OPERATION_FILE" || exit 49
rm -rf "$STATE/retry-invalid"
mkdir -p "$STATE/retry-invalid" || exit 50
! charging_prepare_base "$STATE/retry-invalid" _a "$STATE/fake-part.img" >/dev/null 2>&1 || exit 51
[ ! -e "$STATE/retry-invalid/base.img" ] || exit 52
echo invalid_operation_without_state_cannot_be_rebased_as_original=ok
echo PREPARED_GUARD_ANDROID_OK
rm -rf "$STATE"
