#!/system/bin/sh

# 从实际打包目录加载默认配置，验证公共脚本与配置文件保持兼容。
ROOT=${0%/*}
ROOT=${ROOT%/*}
. "$ROOT/shell-bootstrap.sh" || exit 90
[ "$PFFM_BUSYBOX_SHELL" = 1 ] || exit 91

PFFM_STATE_DIR=${1:-/data/local/tmp/pffm_config_test}
export PFFM_STATE_DIR
MODDIR="$ROOT"
. "$ROOT/common.sh" || exit 1
load_config || exit 2
validate_config || exit 3

echo CONFIG_ANDROID_OK
rm -rf "$PFFM_STATE_DIR"
