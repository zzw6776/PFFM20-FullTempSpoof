#!/system/bin/sh

# 只读实机 AVB 容器测试：使用当前 DTBO 的裸 DT table 构建候选，不修改任何分区。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_avb_container_test}
rm -rf "$STATE"
mkdir -p "$STATE" || exit 1

CHARGING_MODDIR="$ROOT"
. "$ROOT/avb_dtbo.sh" || exit 2
. "$ROOT/charging_dtbo.sh" || exit 3
slot="$(charging_active_slot)" || exit 4
part="$(charging_dtbo_partition "$slot")" || exit 5
source="$STATE/source.img"
raw="$STATE/raw.img"
baseline="$STATE/baseline-candidate.img"
modified_raw="$STATE/modified-raw.img"
modified="$STATE/modified-candidate.img"

before_hash="$(charging_sha256 "$part")" || exit 6
dd if="$part" of="$source" bs=1048576 2>/dev/null || exit 7
avb_parse_dtbo_image "$source" || {
    echo "$AVB_ERROR"
    exit 8
}
source_size="$AVB_IMAGE_SIZE"
raw_size="$AVB_ORIGINAL_IMAGE_SIZE"
source_vbmeta_offset="$AVB_VBMETA_OFFSET"
source_vbmeta_size="$AVB_VBMETA_SIZE"
dd if="$source" of="$raw" bs=1 count="$raw_size" 2>/dev/null || exit 9
avb_validate_raw_dtbo "$raw" || exit 10

avb_build_dtbo_image "$source" "$raw" "$baseline" || {
    echo "$AVB_ERROR"
    exit 11
}
cmp -s "$source" "$baseline" || exit 12
echo unchanged_raw_rebuild_is_byte_identical=ok

cp -f "$raw" "$modified_raw" || exit 13
printf '\132' | dd of="$modified_raw" bs=1 seek="$((raw_size - 1))" conv=notrunc 2>/dev/null || exit 14
avb_validate_raw_dtbo "$modified_raw" || exit 15
avb_build_dtbo_image "$source" "$modified_raw" "$modified" || {
    echo "$AVB_ERROR"
    exit 16
}
avb_verify_dtbo_image "$source" "$modified_raw" "$modified" || exit 17
! cmp -s "$source" "$modified" || exit 18
avb_parse_dtbo_image "$modified" || exit 19
[ "$AVB_IMAGE_SIZE" = "$source_size" ] || exit 20
[ "$AVB_VBMETA_OFFSET" = "$source_vbmeta_offset" ] || exit 21
[ "$AVB_VBMETA_SIZE" = "$source_vbmeta_size" ] || exit 22

after_hash="$(charging_sha256 "$part")" || exit 23
[ "$before_hash" = "$after_hash" ] || exit 24
echo "partition_sha256_unchanged=$after_hash"
echo "image_size=$AVB_IMAGE_SIZE"
echo "raw_size=$AVB_ORIGINAL_IMAGE_SIZE"
echo "vbmeta_offset=$AVB_VBMETA_OFFSET"
echo "vbmeta_size=$AVB_VBMETA_SIZE"
echo modified_raw_preserves_avb_container=ok
echo AVB_CONTAINER_ANDROID_OK
rm -rf "$STATE"
