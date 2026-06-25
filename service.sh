#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

acquire_lock || {
    log WARN "已有实例正在执行，本次退出"
    exit 0
}
cleanup_lock() {
    release_lock
}

handle_int() {
    trap - EXIT INT TERM
    release_lock
    exit 130
}

handle_term() {
    trap - EXIT INT TERM
    release_lock
    exit 143
}

trap 'cleanup_lock' EXIT
trap 'handle_int' INT
trap 'handle_term' TERM

log INFO "========== service start =========="
apply_runtime
result=$?
log INFO "service end: result=$result"
exit "$result"
