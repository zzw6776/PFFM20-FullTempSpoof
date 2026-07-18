#!/system/bin/sh

MODDIR="${0%/*}"
PFFM_LEGACY_LOCK_BOOT_CLEANUP=1
export PFFM_LEGACY_LOCK_BOOT_CLEANUP
. "$MODDIR/shell-bootstrap.sh" || exit 1
. "$MODDIR/common.sh"

acquire_lock || {
    log WARN "已有实例正在执行，本次退出"
    exit 0
}
install_lock_signal_traps

log INFO "========== service start =========="

load_config
if ! is_uint_range "$BOOT_WAIT_TIMEOUT_SEC" 1 1800; then
    log ERROR "BOOT_WAIT_TIMEOUT_SEC 必须是 1～1800 的整数，当前为 $BOOT_WAIT_TIMEOUT_SEC"
    exit 1
fi

# 等待系统开机完成，超时后退出并由 EXIT trap 释放运行锁。
boot_wait_elapsed=0
while [ "$(getprop sys.boot_completed)" != 1 ]; do
    if [ "$boot_wait_elapsed" -ge "$BOOT_WAIT_TIMEOUT_SEC" ]; then
        log ERROR "等待系统启动完成超时：${BOOT_WAIT_TIMEOUT_SEC}s"
        exit 1
    fi
    sleep 1
    boot_wait_elapsed=$((boot_wait_elapsed + 1))
done
sleep 10

apply_runtime
result=$?
log INFO "service end: result=$result"
exit "$result"
