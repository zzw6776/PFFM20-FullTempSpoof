#!/system/bin/sh

# 只使用普通文件验证 DTBO 所有权过渡和精确回滚，不接触真实分区。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

STATE=${1:-/data/local/tmp/pffm_charging_transaction_test}
rm -rf "$STATE"
mkdir -p "$STATE/prepared_a" "$STATE/retry" || exit 1

CHARGING_MODDIR="$ROOT"
CHARGING_RESCUE_DIR="$STATE"
. "$ROOT/charging_dtbo.sh" || exit 2
CHARGING_DTBO_ENABLE=1
PPS55_ENABLE=1
PD_QC_27W_ENABLE=1
charging_select_slot_state _a || exit 3

printf 'AAAAAAAAAAAAAAAA' > "$STATE/original.img" || exit 4
printf 'BBBBBBBBBBBBBBBB' > "$STATE/old-patch.img" || exit 5
printf 'CCCCCCCCCCCCCCCC' > "$STATE/new-patch.img" || exit 6
printf 'DDDDDDDDDDDDDDDD' > "$STATE/fake-part.img" || exit 7
cp -f "$STATE/original.img" "$CHARGING_PREPARED_BASE" || exit 8
cp -f "$STATE/old-patch.img" "$CHARGING_PREPARED_ROLLBACK" || exit 9
cp -f "$STATE/original.img" "$CHARGING_BACKUP" || exit 10

original_hash="$(charging_sha256 "$STATE/original.img")" || exit 11
old_hash="$(charging_sha256 "$STATE/old-patch.img")" || exit 12
new_hash="$(charging_sha256 "$STATE/new-patch.img")" || exit 13
foreign_hash="$(charging_sha256 "$STATE/fake-part.img")" || exit 14
image_size="$(charging_file_size "$STATE/original.img")"

# 先写 format=1，验证升级时仍能读取旧状态。
{
    echo format=1
    echo slot=_a
    echo "original_sha256=$original_hash"
    echo "patched_sha256=$old_hash"
    echo "image_size=$image_size"
    echo pps55=1
    echo pd_qc_27w=0
} > "$CHARGING_STATE_FILE" || exit 15
charging_state_load || exit 16
[ "$CHARGING_STATE_FORMAT" = 1 ] || exit 17
echo legacy_state_format_readable=ok

# 在真正写分区前提交目标状态；format=2 必须同时承认旧补丁和新补丁。
CHARGING_ORIGINAL_HASH="$original_hash"
CHARGING_ORIGINAL_SIZE="$image_size"
charging_commit_state_transaction "$CHARGING_PREPARED_DIR" _a "$new_hash" 1 1 \
    "$old_hash" 1 0 || exit 18
charging_state_load || exit 19
[ "$CHARGING_STATE_FORMAT" = 2 ] || exit 20
[ "$CHARGING_STATE_PATCHED_HASH" = "$new_hash" ] || exit 21
[ "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" = "$old_hash" ] || exit 22
charging_state_hash_owned "$original_hash" || exit 23
charging_state_hash_owned "$old_hash" || exit 24
charging_state_hash_owned "$new_hash" || exit 25
! charging_state_hash_owned "$foreign_hash" || exit 26
echo old_and_new_patch_owned_before_flash=ok

# 模拟状态已更新、分区仍为旧补丁的中断；重新准备不得把旧补丁判成 OTA。
cp -f "$STATE/old-patch.img" "$STATE/fake-part.img" || exit 27
charging_prepare_base "$STATE/retry" _a "$STATE/fake-part.img" || exit 28
[ "$CHARGING_CURRENT_HASH" = "$old_hash" ] || exit 29
cmp -s "$STATE/retry/base.img" "$STATE/original.img" || exit 30
echo interrupted_preflash_old_patch_accepted=ok

# 普通文件不支持 blockdev --flushbufs，用等价完整覆盖模拟分区写入。
charging_write_partition() {
    cp -f "$1" "$2" || return 1
    sync
}

# 模拟分区写坏：必须恢复刷写前旧补丁，并把活动状态切回旧配置，而不是原始镜像。
printf 'XXXXXXXXXXXXXXX!' > "$STATE/fake-part.img" || exit 31
CHARGING_PREPARED_LIVE_HASH="$old_hash"
CHARGING_REBOOT_REQUIRED=0
charging_restore_after_flash_failure "$STATE/fake-part.img" "$old_hash" 0 || exit 32
restored_hash="$(charging_sha256 "$STATE/fake-part.img")" || exit 33
[ "$restored_hash" = "$old_hash" ] || exit 34
charging_state_load || exit 35
[ "$CHARGING_STATE_PATCHED_HASH" = "$old_hash" ] || exit 36
[ "$CHARGING_STATE_PPS55" = 1 ] && [ "$CHARGING_STATE_PD_QC_27W" = 0 ] || exit 37
[ "$CHARGING_STATE_PREVIOUS_PATCHED_HASH" = "$new_hash" ] || exit 38
[ "$(charging_operation_field phase)" = UNCHANGED ] || exit 39
[ "$CHARGING_REBOOT_REQUIRED" = 0 ] || exit 40
echo failed_flash_restored_exact_preflash_image_and_state=ok

# 迁移旧目录时，若槽位目录恰好处于“正式备份 + pending 新状态”，必须先
# 走通用事务恢复，不能只校验已经陈旧的正式状态。
mkdir -p "$STATE/legacy" || exit 43
cp -f "$STATE/original.img" "$STATE/legacy/original_dtbo.img" || exit 44
charging_state_write_file "$STATE/legacy/charging_state.conf" _a \
    "$original_hash" "$old_hash" "$image_size" 1 0 || exit 45
charging_select_slot_state _a || exit 46
cp -f "$STATE/original.img" "$CHARGING_BACKUP" || exit 47
charging_state_write_file "$CHARGING_STATE_FILE" _a \
    "$original_hash" "$old_hash" "$image_size" 1 0 || exit 48
charging_state_write_file "$CHARGING_STATE_PENDING" _a \
    "$original_hash" "$new_hash" "$image_size" 1 1 "$old_hash" 1 0 || exit 49
PFFM_LOCK_HELD=1
charging_migrate_legacy_state "$STATE/legacy" || exit 50
charging_state_load || exit 51
[ "$CHARGING_STATE_PATCHED_HASH" = "$new_hash" ] || exit 52
[ ! -e "$CHARGING_STATE_PENDING" ] || exit 53
PFFM_LOCK_HELD=0
echo legacy_migration_recovers_pending_transaction=ok

# battery_unlocker 的 disable/remove 不会还原持久化 DTBO；即使模块目录已
# 消失，外部 state.env 指向且命中当前分区的目标哈希也必须继续拦截。
CHARGING_BATTERY_UNLOCKER_MODULE_DIR="$STATE/battery_unlocker"
CHARGING_BATTERY_UNLOCKER_UPDATE_DIR="$STATE/battery_unlocker_update"
CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT="$STATE/op13-rescue"
mkdir -p "$CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT/a" || exit 54
{
    echo "base_sha256=$original_hash"
    echo "target_sha256=$new_hash"
} > "$CHARGING_BATTERY_UNLOCKER_RESCUE_ROOT/a/state.env" || exit 55
cp -f "$STATE/new-patch.img" "$STATE/fake-part.img" || exit 56
! charging_check_battery_unlocker_conflict _a "$STATE/fake-part.img" >/dev/null 2>&1 || exit 57
cp -f "$STATE/original.img" "$STATE/fake-part.img" || exit 58
charging_check_battery_unlocker_conflict _a "$STATE/fake-part.img" || exit 59
mkdir -p "$CHARGING_BATTERY_UNLOCKER_MODULE_DIR" || exit 60
touch "$CHARGING_BATTERY_UNLOCKER_MODULE_DIR/disable" || exit 61
! charging_check_battery_unlocker_conflict _a "$STATE/fake-part.img" >/dev/null 2>&1 || exit 62
echo battery_unlocker_persistent_conflict_guard=ok

# od 默认会把重复的全零行压缩成“*”；容器 entry 元数据正好是 24 字节全零，
# 必须强制完整输出，否则合法的 PJZ110 DTBO 会被误判成元数据长度异常。
dd if=/dev/zero of="$STATE/zeros.bin" bs=24 count=1 2>/dev/null || exit 41
[ "$(charging_read_hex "$STATE/zeros.bin" 0 24)" = \
    000000000000000000000000000000000000000000000000 ] || exit 42
echo repeated_zero_container_metadata_readable=ok

echo CHARGING_TRANSACTION_ANDROID_OK
rm -rf "$STATE"
