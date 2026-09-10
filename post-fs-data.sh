#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"
. "$MODDIR/sync-pif-security-patch.sh"

# 温度节点仍只在 late_start service 阶段就绪后挂载；这里只处理必须早于 Zygote
# 生效的可选安全补丁属性同步。
log INFO "========== post-fs-data start =========="
sync_pif_security_patch post-fs-data
result=$?
log INFO "post-fs-data end: patch_result=$result"
exit "$result"
