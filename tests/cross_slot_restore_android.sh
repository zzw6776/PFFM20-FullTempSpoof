#!/system/bin/sh

# 普通文件故障注入：关闭总开关必须遍历 A/B，清理旧 PID 临时目录，
# 但槽位恢复失败时必须保留正式 prepared/current.img 供人工救援。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_cross_slot_restore_test}
rm -rf "$STATE"
mkdir -p "$STATE/rescue" || exit 1

PFFM_STATE_DIR="$STATE/runtime"
export PFFM_STATE_DIR
MODDIR="$ROOT"
. "$ROOT/common.sh" || exit 2
acquire_lock || exit 3
install_lock_signal_traps

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE/rescue"
. "$ROOT/charging_dtbo.sh" || exit 4
CHARGING_DTBO_ENABLE=0
PPS55_ENABLE=1
PD_QC_27W_ENABLE=0

mkdir -p \
    "$STATE/rescue/.prepared_a.111" \
    "$STATE/rescue/prepared_a.previous.222" \
    "$STATE/rescue/prepared_a" || exit 5
printf rescue > "$STATE/rescue/prepared_a/current.img" || exit 6
touch "$STATE/rescue/charging_state_a.conf" || exit 7

charging_active_slot() { echo _b; }
charging_restore_slot() {
    printf '%s\n' "$1" >> "$STATE/restored-slots"
    return 0
}

charging_apply_requested || exit 8
[ "$(cat "$STATE/restored-slots" 2>/dev/null)" = _a ] || exit 9
[ ! -e "$STATE/rescue/.prepared_a.111" ] || exit 10
[ ! -e "$STATE/rescue/prepared_a.previous.222" ] || exit 11
[ ! -e "$STATE/rescue/prepared_a" ] || exit 12
echo inactive_owned_slot_restored=ok
echo stale_prepare_directories_cleaned=ok
echo successful_restore_discards_prepared=ok

mkdir -p "$STATE/rescue/prepared_b.previous.444" || exit 13
printf rescue-before-swap > "$STATE/rescue/prepared_b.previous.444/current.img" || exit 14
charging_cleanup_stale_prepared_slot _b || exit 15
[ "$(cat "$STATE/rescue/prepared_b/current.img" 2>/dev/null)" = rescue-before-swap ] || exit 16
echo interrupted_swap_previous_restored=ok
rm -rf "$STATE/rescue/prepared_b" || exit 17

mkdir -p "$STATE/rescue/prepared_a" || exit 13
printf rescue > "$STATE/rescue/prepared_a/current.img" || exit 14
touch "$STATE/rescue/charging_state_a.conf" || exit 15
charging_restore_slot() { return 1; }
! charging_apply_requested >/dev/null 2>&1 || exit 16
[ "$(cat "$STATE/rescue/prepared_a/current.img" 2>/dev/null)" = rescue ] || exit 17
echo failed_restore_preserves_prepared_rollback=ok

rm -f "$STATE/rescue/charging_state_a.conf" || exit 18
! charging_apply_requested >/dev/null 2>&1 || exit 19
[ "$(cat "$STATE/rescue/prepared_a/current.img" 2>/dev/null)" = rescue ] || exit 20
charging_has_unresolved_rescue_artifacts || exit 21
charging_select_slot_state _a || exit 31
charging_operation_load || exit 32
[ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ] || exit 33
echo missing_state_promoted_to_rescue_and_preserved_rollback=ok
echo uninstall_guard_detects_prepared_rollback=ok

# 全槽位清理结束时会停在 _b；准备入口必须显式恢复调用前的活动槽上下文。
charging_select_slot_state _a || exit 22
charging_cleanup_stale_prepared_all_for_slot _a || exit 23
[ "$CHARGING_PREPARED_DIR" = "$STATE/rescue/prepared_a" ] || exit 25
echo active_slot_context_restored_after_cross_slot_cleanup=ok

release_lock || exit 26
trap - EXIT HUP INT TERM
! charging_migrate_legacy_state "$STATE/no-legacy" >/dev/null 2>&1 || exit 27
echo unlocked_legacy_migration_refused=ok
mkdir -p "$STATE/rescue/.prepared_a.333" || exit 28
! charging_cleanup_stale_prepared_slot _a >/dev/null 2>&1 || exit 29
[ -d "$STATE/rescue/.prepared_a.333" ] || exit 30
echo unlocked_cleanup_refused=ok

# 即便调用方绕过全槽位入口直接请求恢复，活动槽无法识别时也必须在定位、
# 哈希和写入分区之前失败。全槽位入口同时不得清理任何救援文件。
. "$ROOT/charging_dtbo.sh" || exit 34
CHARGING_RESCUE_DIR="$STATE/rescue"
rm -rf "$CHARGING_RESCUE_DIR"
mkdir -p "$CHARGING_RESCUE_DIR/prepared_a" || exit 35
touch "$CHARGING_RESCUE_DIR/charging_state_a.conf" || exit 36
charging_active_slot() { return 1; }
charging_state_load() {
    CHARGING_STATE_SLOT=_a
    CHARGING_STATE_ORIGINAL_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    CHARGING_STATE_PATCHED_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    CHARGING_STATE_PREVIOUS_PATCHED_HASH=
    return 0
}
charging_dtbo_partition() { printf '%s\n' "$STATE/fake-dtbo"; }
charging_sha256() { printf '%s\n' "$CHARGING_STATE_PATCHED_HASH"; }
charging_write_partition() { touch "$STATE/partition-written"; return 0; }
! charging_restore_slot _a >/dev/null 2>&1 || exit 37
[ ! -e "$STATE/partition-written" ] || exit 38
! charging_restore_all_owned >/dev/null 2>&1 || exit 39
[ -e "$CHARGING_RESCUE_DIR/charging_state_a.conf" ] || exit 40
[ -d "$CHARGING_RESCUE_DIR/prepared_a" ] || exit 41
echo unknown_active_slot_blocks_all_partition_writes=ok
echo unknown_active_slot_preserves_rescue_artifacts=ok

rm -rf "$CHARGING_RESCUE_DIR/prepared_a"
rm -f "$CHARGING_RESCUE_DIR/charging_state_a.conf"
printf broken > "$CHARGING_RESCUE_DIR/operation_a.conf" || exit 42
! charging_restore_all_owned >/dev/null 2>&1 || exit 43
[ -f "$CHARGING_RESCUE_DIR/operation_a.conf" ] || exit 44
echo unknown_active_slot_preserves_invalid_operation_state=ok

acquire_lock || exit 45
install_lock_signal_traps
charging_active_slot() { echo _a; }
! charging_restore_all_owned >/dev/null 2>&1 || exit 46
[ -f "$CHARGING_RESCUE_DIR/operation_a.conf" ] || exit 47
echo known_active_slot_rejects_invalid_operation_state=ok

rm -f "$CHARGING_RESCUE_DIR/operation_a.conf"
charging_select_slot_state _a || exit 48
charging_set_operation_phase FLASHING interrupted-without-state || exit 49
! charging_restore_all_owned >/dev/null 2>&1 || exit 50
charging_select_slot_state _a || exit 51
charging_operation_load || exit 52
[ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ] || exit 53
echo known_active_slot_promotes_unowned_critical_operation=ok
release_lock || exit 54
trap - EXIT HUP INT TERM

rm -rf "$STATE"
echo CROSS_SLOT_RESTORE_ANDROID_OK
