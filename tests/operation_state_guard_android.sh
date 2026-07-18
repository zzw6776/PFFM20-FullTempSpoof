#!/system/bin/sh

# 普通文件故障注入：即使正式 state/backup 与当前镜像都完整，损坏的
# operation 文件也不能被准备、提交或恢复流程静默覆盖。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_operation_state_guard_test}
rm -rf "$STATE"
mkdir -p "$STATE/prepare-work" || exit 1

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE"
. "$ROOT/charging_dtbo.sh" || exit 2
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=0
charging_select_slot_state _a || exit 3

printf 'ORIGINAL_IMAGE' > "$STATE/original.img" || exit 4
printf 'PATCHED__IMAGE' > "$STATE/patched.img" || exit 5
cp -f "$STATE/original.img" "$STATE/fake-part.img" || exit 6
cp -f "$STATE/original.img" "$CHARGING_BACKUP" || exit 7
original_hash="$(charging_sha256 "$STATE/original.img")" || exit 8
patched_hash="$(charging_sha256 "$STATE/patched.img")" || exit 9
image_size="$(charging_file_size "$STATE/original.img")"
charging_state_write_file "$CHARGING_STATE_FILE" _a \
    "$original_hash" "$patched_hash" "$image_size" 1 0 || exit 10
printf 'broken-operation-state\n' > "$CHARGING_OPERATION_FILE" || exit 11

CHARGING_RESCUE_REQUIRED=0
! charging_prepare_base "$STATE/prepare-work" _a "$STATE/fake-part.img" \
    > "$STATE/prepare.out" 2>&1 || exit 12
[ "$CHARGING_RESCUE_REQUIRED" = 1 ] || exit 13
[ ! -e "$STATE/prepare-work/base.img" ] || exit 14
grep -q '^broken-operation-state$' "$CHARGING_OPERATION_FILE" || exit 15
echo invalid_operation_with_valid_state_blocks_prepare=ok

charging_dtbo_partition() { printf '%s\n' "$STATE/fake-part.img"; }
CHARGING_REBOOT_REQUIRED=0
CHARGING_RESCUE_REQUIRED=0
! charging_restore_slot _a _a > "$STATE/restore.out" 2>&1 || exit 16
[ "$CHARGING_RESCUE_REQUIRED" = 1 ] || exit 17
[ "$CHARGING_REBOOT_REQUIRED" = 0 ] || exit 18
grep -q '^broken-operation-state$' "$CHARGING_OPERATION_FILE" || exit 19
echo invalid_operation_with_owned_original_blocks_restore=ok

charging_preflight_apply() { return 0; }
charging_import_previous_state() { return 0; }
charging_active_slot() { printf '%s\n' _a; }
charging_prepared_load_dir() { touch "$STATE/prepared-load-called"; return 0; }
CHARGING_RESCUE_REQUIRED=0
! charging_commit_prepared > "$STATE/commit.out" 2>&1 || exit 20
[ "$CHARGING_RESCUE_REQUIRED" = 1 ] || exit 21
[ ! -e "$STATE/prepared-load-called" ] || exit 22
grep -q '^broken-operation-state$' "$CHARGING_OPERATION_FILE" || exit 23
echo invalid_operation_blocks_stale_prepared_commit=ok

echo OPERATION_STATE_GUARD_ANDROID_OK
rm -rf "$STATE"
