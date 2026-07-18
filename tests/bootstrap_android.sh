#!/system/bin/sh

ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 1
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 2

PFFM_STATE_DIR=${1:-/data/local/tmp/pffm_bootstrap_test}
export PFFM_STATE_DIR
MODDIR="$ROOT"
. "$ROOT/common.sh" || exit 3
acquire_lock || exit 4
echo bootstrap_lock_acquired=ok
release_lock || exit 5
rm -rf "$PFFM_STATE_DIR"
echo BOOTSTRAP_ANDROID_OK
