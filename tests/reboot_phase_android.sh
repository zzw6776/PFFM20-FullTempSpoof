#!/system/bin/sh

ROOT=${0%/*}
ROOT=${ROOT%/*}
BUSYBOX=${PFFM_BUSYBOX:-/data/adb/magisk/busybox}
STATE=${1:-/data/local/tmp/pffm_reboot_phase_test}

if [ "${PFFM_BUSYBOX_SHELL:-0}" != 1 ]; then
    [ -x "$BUSYBOX" ] || exit 90
    PFFM_BUSYBOX="$BUSYBOX"
    PFFM_BUSYBOX_SHELL=1
    export PFFM_BUSYBOX PFFM_BUSYBOX_SHELL
    exec "$BUSYBOX" sh "$0" "$@"
fi

rm -rf "$STATE"
mkdir -p "$STATE" || exit 1
CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE"
. "$ROOT/charging_dtbo.sh" || exit 2
charging_select_slot_state _a || exit 3

CHARGING_STATE_ORIGINAL_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CHARGING_STATE_PATCHED_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CHARGING_STATE_PREVIOUS_PATCHED_HASH=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
CHARGING_STATE_SLOT=_a
CHARGING_STATE_VALID=1

charging_set_operation_phase FLASHING test || exit 4
charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 5
! charging_operation_requires_reboot "$CHARGING_STATE_ORIGINAL_HASH" || exit 6
charging_operation_load || exit 32
charging_operation_owner_is_alive || exit 33
! charging_operation_requires_rescue "$CHARGING_STATE_PATCHED_HASH" || exit 40
echo flashing_target_requires_reboot=ok

UNKNOWN_HASH=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
charging_operation_requires_rescue "$UNKNOWN_HASH" || exit 34
charging_promote_interrupted_operation_to_rescue "$UNKNOWN_HASH" || exit 35
[ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ] || exit 36
echo flashing_unknown_promoted_to_rescue=ok

charging_set_operation_phase RESTORING test || exit 7
charging_operation_requires_reboot "$CHARGING_STATE_ORIGINAL_HASH" || exit 8
! charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 9
echo restoring_original_requires_reboot=ok

charging_operation_requires_rescue "$UNKNOWN_HASH" || exit 37
charging_promote_interrupted_operation_to_rescue "$UNKNOWN_HASH" || exit 38
[ "$CHARGING_OPERATION_PHASE" = RESCUE_REQUIRED ] || exit 39
echo restoring_unknown_promoted_to_rescue=ok

charging_set_operation_phase REBOOT_REQUIRED test || exit 10
charging_operation_requires_reboot "$CHARGING_STATE_ORIGINAL_HASH" || exit 11
charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 12
charging_operation_requires_reboot "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" || exit 20
echo persisted_reboot_required=ok

charging_set_operation_phase ROLLING_BACK test || exit 21
! charging_operation_requires_reboot "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" || exit 22
echo rolling_back_without_prior_pending_does_not_require_reboot=ok

charging_set_operation_phase REBOOT_REQUIRED test || exit 23
sed -i 's/^boot_id=.*/boot_id=00000000-0000-0000-0000-000000000000/' "$CHARGING_OPERATION_FILE" || exit 13
! charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 14
echo prior_boot_is_cleared=ok

charging_set_operation_phase FLASHING test || exit 15
sed -i '/^boot_id=/d' "$CHARGING_OPERATION_FILE" || exit 16
charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 17
echo legacy_interrupted_phase_is_conservative=ok

charging_set_operation_phase RESCUE_REQUIRED '自动回滚失败，禁止重启' || exit 24
charging_operation_requires_rescue || exit 25
[ "$CHARGING_OPERATION_DETAIL" = '自动回滚失败，禁止重启' ] || exit 26
charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 27
! charging_operation_requires_reboot "$UNKNOWN_HASH" || exit 28
sed -i 's/^boot_id=.*/boot_id=00000000-0000-0000-0000-000000000000/' "$CHARGING_OPERATION_FILE" || exit 29
charging_operation_requires_rescue || exit 30
! charging_operation_requires_reboot "$CHARGING_STATE_PATCHED_HASH" || exit 31
echo rescue_warning_survives_reboot_and_blocks_unknown_image=ok

charging_begin_partition_critical || exit 18
kill -HUP $$
echo critical_hup_did_not_interrupt=ok
kill -TERM $$
echo critical_term_did_not_interrupt=ok
charging_end_partition_critical || exit 19

echo REBOOT_PHASE_ANDROID_OK
rm -rf "$STATE"
