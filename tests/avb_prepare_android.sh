#!/system/bin/sh

# 实机只读验证：生成完整候选镜像并验证 AVB 容器，但绝不调用提交/刷写函数。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_avb_prepare_test}
MODE=${2:-generate}
case "$MODE" in
    generate)
        rm -rf "$STATE"
        mkdir -p "$STATE" || exit 1
        ;;
    reuse)
        [ -d "$STATE" ] || exit 1
        ;;
    *) exit 1 ;;
esac

prepare_fail() {
    echo "AVB_PREPARE_FAIL stage=$1 rc=$2"
    exit "$2"
}

PFFM_STATE_DIR="$STATE/runtime"
export PFFM_STATE_DIR
MODDIR="$ROOT"
. "$ROOT/common.sh" || exit 2
acquire_lock || prepare_fail lock 2
install_lock_signal_traps

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE"
. "$ROOT/charging_dtbo.sh" || exit 2
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=1

slot="$(charging_active_slot)" || prepare_fail active_slot 3
part="$(charging_dtbo_partition "$slot")" || prepare_fail partition 4
before_hash="$(charging_sha256 "$part")" || prepare_fail before_hash 5

avb_require_unlocked_bootloader || {
    echo "bootconfig_gate=$AVB_ERROR"
    prepare_fail bootconfig 6
}
echo bootconfig_gate=orange_unlocked

if [ "$MODE" = generate ]; then
    charging_prepare_requested || prepare_fail prepare_requested 7
else
    echo "- 复核已经离线生成的 DTBO 准备事务（不写分区）"
fi
after_hash="$(charging_sha256 "$part")" || prepare_fail after_hash 8
[ "$before_hash" = "$after_hash" ] || {
    echo partition_changed=unexpected
    prepare_fail partition_unchanged 9
}

charging_select_slot_state "$slot" || prepare_fail select_slot_state 10
charging_prepared_load_dir "$CHARGING_PREPARED_DIR" || prepare_fail prepared_load 11
avb_parse_dtbo_image "$CHARGING_PREPARED_IMAGE" || prepare_fail candidate_parse 12
[ "$AVB_FOOTER_OFFSET" -gt 0 ] && [ "$AVB_VBMETA_SIZE" -gt 0 ] || prepare_fail candidate_footer 13

echo "slot=$slot"
echo "partition_sha256_unchanged=$after_hash"
echo "selected_dtb=$CHARGING_PREPARED_SELECTED_COUNT/$CHARGING_PREPARED_TOTAL_COUNT"
echo "candidate_size=$AVB_IMAGE_SIZE"
echo "candidate_vbmeta_offset=$AVB_VBMETA_OFFSET"
echo "candidate_vbmeta_size=$AVB_VBMETA_SIZE"
echo AVB_PREPARE_ANDROID_OK
release_lock || prepare_fail release_lock 14
trap - EXIT HUP INT TERM
rm -rf "$STATE"
