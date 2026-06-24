#!/system/bin/sh

# 这里只准备持久状态目录，不在 post-fs-data 阶段挂载温度节点。
# PFFM20 的全部 thermal zone 会在 late_start service 阶段就绪后一次性挂载。
mkdir -p /data/adb/pffm20_fulltempspoof 2>/dev/null
chmod 0700 /data/adb/pffm20_fulltempspoof 2>/dev/null

