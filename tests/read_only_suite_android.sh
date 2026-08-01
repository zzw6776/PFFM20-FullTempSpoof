#!/system/bin/sh

# PJZ110 实机只读回归：允许读取真实 DTBO 并生成离线候选，禁止提交或刷写。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91
BB="$PFFM_BUSYBOX"
PREPARED_REUSE_STATE=${1:-}

suite_timestamp() {
    local value
    value="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || value=
    [ -n "$value" ] || value="time-unavailable"
    printf '%s\n' "$value"
}

suite_log() {
    echo "[$(suite_timestamp)] $*"
}

CHARGING_MODDIR="$ROOT"
. "$ROOT/charging_dtbo.sh" || exit 1
SUITE_STATE="/data/local/tmp/pffm_readonly_suite.$$"
SUITE_SUCCESS=0
rm -rf "$SUITE_STATE"
mkdir -p "$SUITE_STATE" || exit 2
cleanup_suite() {
    if [ "$SUITE_SUCCESS" = 1 ]; then
        rm -rf "$SUITE_STATE"
    else
        echo "suite_failure_state=$SUITE_STATE"
    fi
}
trap 'cleanup_suite' EXIT
slot="$(charging_active_slot)" || exit 2
part="$(charging_dtbo_partition "$slot")" || exit 3
before_hash="$(charging_sha256 "$part")" || exit 4
suite_log "PJZ110 实机只读回归开始"
echo "active_slot=$slot"
echo "dtbo_before=$before_hash"

for file in \
    action.sh avb_dtbo.sh charging_dtbo.sh common.sh customize.sh \
    post-fs-data.sh service.sh shell-bootstrap.sh uninstall.sh \
    tests/avb_container_android.sh tests/avb_prepare_android.sh \
    tests/bootstrap_android.sh tests/charging_transaction_android.sh \
    tests/already_current_android.sh \
    tests/config_android.sh tests/cross_slot_restore_android.sh \
    tests/locking_android.sh tests/operation_state_guard_android.sh \
    tests/prepared_guard_android.sh tests/reboot_phase_android.sh \
    tests/read_only_suite_android.sh; do
    "$BB" sh -n "$ROOT/$file" || exit 5
    echo "busybox_syntax_ok=$file"
done

suite_log "running=bootstrap_android.sh"
"$BB" sh "$ROOT/tests/bootstrap_android.sh" "$SUITE_STATE/bootstrap" || exit 10
suite_log "running=config_android.sh"
"$BB" sh "$ROOT/tests/config_android.sh" "$SUITE_STATE/config" || exit 11
suite_log "running=cross_slot_restore_android.sh"
"$BB" sh "$ROOT/tests/cross_slot_restore_android.sh" "$SUITE_STATE/cross-slot" || exit 12
suite_log "running=charging_transaction_android.sh"
"$BB" sh "$ROOT/tests/charging_transaction_android.sh" "$SUITE_STATE/transaction" || exit 13
suite_log "running=already_current_android.sh"
"$BB" sh "$ROOT/tests/already_current_android.sh" "$SUITE_STATE/already-current" || exit 14
suite_log "running=locking_android.sh"
"$BB" sh "$ROOT/tests/locking_android.sh" "$SUITE_STATE/lock" || exit 15
suite_log "running=reboot_phase_android.sh"
"$BB" sh "$ROOT/tests/reboot_phase_android.sh" "$SUITE_STATE/reboot" || exit 16
suite_log "running=prepared_guard_android.sh"
"$BB" sh "$ROOT/tests/prepared_guard_android.sh" "$SUITE_STATE/prepared" || exit 17
suite_log "running=operation_state_guard_android.sh"
"$BB" sh "$ROOT/tests/operation_state_guard_android.sh" "$SUITE_STATE/operation-state" || exit 18
suite_log "running=avb_container_android.sh"
"$BB" sh "$ROOT/tests/avb_container_android.sh" "$SUITE_STATE/avb-container" || exit 19
suite_log "running=avb_prepare_android.sh"
if [ -n "$PREPARED_REUSE_STATE" ]; then
    "$BB" sh "$ROOT/tests/avb_prepare_android.sh" "$PREPARED_REUSE_STATE" reuse || exit 20
else
    "$BB" sh "$ROOT/tests/avb_prepare_android.sh" "$SUITE_STATE/avb-prepare" || exit 20
fi

after_hash="$(charging_sha256 "$part")" || exit 21
echo "dtbo_after=$after_hash"
[ "$before_hash" = "$after_hash" ] || {
    echo dtbo_partition_changed=unexpected
    exit 22
}
SUITE_SUCCESS=1
suite_log "PJZ110 实机只读回归完成"
echo PJZ110_READ_ONLY_REGRESSION_OK
