#!/system/bin/sh

MODDIR="${0%/*}"
if [ -r "$MODDIR/common.sh" ]; then
    . "$MODDIR/common.sh"
    restore_runtime
else
    # Fallback：common.sh 不可读时直接清理运行时挂载
    _STATE_DIR="/data/adb/pffm20_fulltempspoof"
    _MOUNTS_FILE="$_STATE_DIR/mounts.tsv"
    _TAB="$(printf '\t')"
    if [ -f "$_MOUNTS_FILE" ]; then
        while IFS="$_TAB" read -r _target _source; do
            [ -n "$_target" ] && umount "$_target" 2>/dev/null
        done < "$_MOUNTS_FILE"
    fi
    # 尝试恢复 /proc/shell-temp
    if [ -w /proc/shell-temp ]; then
        _i=0
        while [ "$_i" -le 7 ]; do
            printf '%s %s\n' "$_i" "0" > /proc/shell-temp 2>/dev/null
            _i=$((_i + 1))
        done
    fi
fi

rm -rf /dev/pffm20_fulltempspoof 2>/dev/null
rm -rf /data/adb/pffm20_fulltempspoof 2>/dev/null

