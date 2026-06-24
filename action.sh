#!/system/bin/sh

MODDIR="${0%/*}"
. "$MODDIR/common.sh"

acquire_lock || {
    echo "已有实例正在执行，请稍后重试"
    exit 1
}
trap 'release_lock' EXIT INT TERM

if [ -e "$ACTIVE_FILE" ]; then
    echo "正在卸载温度伪装并恢复服务……"
    restore_runtime
    touch "$DISABLED_FILE"
    echo "已运行时关闭。再次点击 Action 可重新应用。"
else
    echo "正在应用 PFFM20 温度伪装……"
    rm -f "$DISABLED_FILE"
    if apply_runtime; then
        echo "应用成功。"
        echo "映射：$MAP_FILE"
        echo "日志：$LOG_FILE"
    else
        echo "应用失败，请检查：$LOG_FILE"
        exit 1
    fi
fi

