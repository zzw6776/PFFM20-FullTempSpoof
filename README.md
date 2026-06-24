# PFFM20 Full Temperature Spoof

仅针对当前实测设备设计：

- 型号：PFFM20
- 平台：MT6983
- Android：12
- 内核：5.10.66-android12-9-00001-g83cbf18b7dcd-ab8546841

## 工作方式

模块在 late_start service 阶段执行一次：

1. 检查设备型号和冲突模块。
2. 枚举 `/sys/class/thermal/thermal_zone*`。
3. 根据 `type` 分类并从 `config.conf` 读取目标温度。
4. 在 `/dev/pffm20_fulltempspoof` 创建伪造文件。
5. 将伪造文件 bind mount 到每个 `thermal_zoneN/temp`。
6. 可选处理电池 power_supply 温度与 `/proc/shell-temp`。
7. 根据配置停止 Horae、MTK Vendor Thermal HAL 或 thermal_core。
8. 验证每个节点并生成映射表后退出，不驻留后台。

## 明确不会做的事情

- 不修改任何 XML。
- 不修改 `thermal.conf`。
- 不修改 CPU/GPU 频率。
- 不写 cooling device。
- 不写 thermal zone 的 `mode`、trip point 或 `emul_temp`。
- 不包含持续温度 watchdog。

## soc_max 保护说明

即使 `/sys/class/thermal/thermal_zone0/temp` 对用户空间显示伪造值，bind mount 也不会改变内核 thermal zone 对象内部的真实温度。本模块不会修改：

```text
thermal_zone0/type=soc_max
thermal_zone0/mode=enabled
trip_point_0_type=critical
trip_point_0_temp=116500
```

因此内核临界保护仍保留。但这是最终关机保护，不等同于正常温控，也不覆盖电池、PMIC和外壳的全部风险。

## 配置

完整配置和中文注释位于 `config.conf`。默认所有类别开启：

- CPU
- GPU
- APU/NPU
- 内存/DDR
- SoC
- shell/skin
- 电池
- 充电器
- PMIC
- modem/RF
- connectivity
- NTC/ambient
- unknown

修改配置后重启，或在 Magisk 模块页面点击 Action 重新应用。

## 安装顺序

1. 在 Magisk 中停用或卸载 AaTempSpoof、ColorOS解除温控限制及其他温度挂载模块。
2. 重启一次，确保旧模块的 bind mount 已全部消失。
3. 安装本模块 ZIP 并重启。
4. 检查 `module.log` 和 `thermal-map.tsv`；映射表应有 51 行 `mounted`。

如果没有先处理旧模块，本模块会因冲突检测而拒绝应用，不会强行覆盖。

## 运行时文件

```text
/data/adb/pffm20_fulltempspoof/module.log
/data/adb/pffm20_fulltempspoof/thermal-map.tsv
/data/adb/pffm20_fulltempspoof/mounts.tsv
```

## 冲突

不得与 AaTempSpoof、ColorOS解除温控限制或其他对 thermal zone 进行挂载的模块同时运行。发现冲突时，本模块会记录错误并拒绝应用，不会自动禁用其他模块。

## 恢复

- 点击 Magisk Action：运行时卸载挂载并恢复服务。
- 正常重启：bind mount 自动消失。
- 卸载模块：执行 `uninstall.sh` 恢复运行时状态并清理文件。

## 风险边界

默认配置会伪装包括电池、PMIC、充电器和 soc_max 在内的全部温度入口，
并停止 Horae 与 MTK Vendor Thermal HAL。内核 116.5°C critical 是最后保护，
并不是适合长期触发的工作温度；电池、充电 IC 或其他硬件也可能在到达该阈值前受损。
