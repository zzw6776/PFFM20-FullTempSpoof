#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

acquire_lock || {
    log WARN "已有实例正在执行，本次退出"
    exit 0
}
trap 'release_lock' EXIT INT TERM

log INFO "========== service start =========="
apply_runtime
result=$?
log INFO "service end: result=$result"
exit "$result"

