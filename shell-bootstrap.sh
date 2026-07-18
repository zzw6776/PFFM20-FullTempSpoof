#!/system/bin/sh

# File-descriptor locks opened by Android's mksh are not inherited by the
# external flock command on PJZ110. Re-execute runtime entry points under the
# root manager's BusyBox ash before common.sh opens the lock descriptor.

[ "${PFFM_BUSYBOX_SHELL:-0}" = 1 ] && return 0

for PFFM_BUSYBOX in \
    /data/adb/magisk/busybox \
    /debug_ramdisk/.magisk/busybox/busybox \
    /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox; do
    [ -x "$PFFM_BUSYBOX" ] && break
    PFFM_BUSYBOX=
done

if [ -z "$PFFM_BUSYBOX" ]; then
    PFFM_MAGISK_PATH="$(magisk --path 2>/dev/null | head -n 1)"
    case "$PFFM_MAGISK_PATH" in
        /*)
            for PFFM_BUSYBOX in \
                "$PFFM_MAGISK_PATH/.magisk/busybox/busybox" \
                "$PFFM_MAGISK_PATH/busybox/busybox" \
                "$PFFM_MAGISK_PATH/busybox"; do
                [ -x "$PFFM_BUSYBOX" ] && break
                PFFM_BUSYBOX=
            done
            ;;
        *) PFFM_BUSYBOX= ;;
    esac
fi

if [ -z "$PFFM_BUSYBOX" ]; then
    PFFM_BUSYBOX="$(command -v busybox 2>/dev/null)"
fi
[ -n "$PFFM_BUSYBOX" ] && [ -x "$PFFM_BUSYBOX" ] || {
    echo "缺少 BusyBox，无法建立可靠的运行锁" >&2
    return 1
}

PFFM_BUSYBOX_SHELL=1
export PFFM_BUSYBOX PFFM_BUSYBOX_SHELL
exec "$PFFM_BUSYBOX" sh "$0" "$@"
