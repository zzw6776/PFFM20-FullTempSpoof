#!/system/bin/sh

MODDIR="${0%/*}"
if [ -r "$MODDIR/common.sh" ]; then
    . "$MODDIR/common.sh"
    restore_runtime
fi

rm -rf /dev/pffm20_fulltempspoof 2>/dev/null
rm -rf /data/adb/pffm20_fulltempspoof 2>/dev/null

