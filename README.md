# ColorOS Full Temperature Spoof

面向 ColorOS 的动态温度读数伪装模块，并为 PJZ110 Android 15 提供受限的充电 DTBO 扩展。

温度伪装功能不绑定具体机型、Android 版本、内核版本或 SoC 平台；运行时会自动枚举当前设备实际存在的
thermal zone、power_supply 温度节点和厂商温控服务，并按 `config.conf` 进行 best-effort 处理。
不支持的节点、SELinux 标签或服务会跳过并记录日志。充电功能不是通用功能：它严格要求
Android 15（SDK 35），并且只修改 DTBO 中 `oplus,project-id=0x5d0d` 的 PJZ110 overlay。

## 工作方式

模块在 late_start service 阶段执行一次：

1. 检查温度挂载冲突；温度功能不校验机型、Android 版本或内核版本。
2. 枚举 `/sys/class/thermal/thermal_zone*`。
3. 根据 `type` 分类并从 `config.conf` 读取目标温度。
4. 按目标节点 SELinux 标签在 `/dev/coloros_fulltempspoof` 下动态创建独立 tmpfs，
   分别保存不同标签对应的伪造文件。
5. 将伪造文件 bind mount 到每个 `thermal_zoneN/temp`。
6. 可选处理电池 power_supply 温度与 `/proc/shell-temp`。
7. 厂商温控服务按单独配置项处理；默认全部 `keep`，不停止、不重启。
8. 验证每个节点并生成映射表后退出，不驻留后台。

安装模块时不会读取或刷写 DTBO。安装完成后可先在 App 的充电控制页点击
“建立原始备份”：该动作只读 A/B DTBO，在哈希与项目内保存的 PJZ110 A77
原始实机哈希及完整大小均一致时，才会把镜像写入外置救援目录；镜像确实带有 AVB Footer
时还会继续解析校验，已知原厂镜像不带 Footer 时不会因此误判失败。该动作不会生成补丁、
修改配置或写 DTBO 分区，已有有效备份也只会重新校验而不会覆盖。只有明确点击
“保存并应用”或 Magisk Action 后，
充电 DTBO 补丁才会单独处理：

1. 要求 SDK 35、有效 A/B 槽位、可读写的当前槽位 DTBO，并且只相信 `/proc/bootconfig`；必须明确显示 `androidboot.verifiedbootstate=orange` 和 `androidboot.vbmeta.device_state=unlocked`。`getprop` 即使被伪装成 locked/green 也不参与判断。脚本同时拒绝与 `battery_unlocker` 叠加。
2. App 先保存“期望配置”，并确认活动槽位已有可信原始备份；若用户尚未手动建立，脚本会在任何候选生成和分区写入之前先执行同一套只读哈希校验与独立备份事务。没有可信原始备份时拒绝继续，不能再把“当前没有状态”的任意 DTBO 临时定义成原始镜像。
3. 随后在外置救援目录离线读取、解包和修改候选镜像，再由只读校验器分别解包可信基线与候选：非目标 DTB 必须逐字节不变；目标 DTB 只允许明确白名单属性变化，且每个新值都必须符合当前配置；最后独立核对容器和 AVB。校验器不会再次调用补丁生成器来重建所谓“期望镜像”。这个有界准备阶段绝不写 DTBO 分区。只有准备成功后才进入无 App 固定超时的短提交阶段，并在提交前重新核对配置哈希、实时分区哈希和候选哈希。准备或提交失败时配置不会倒退，可按相同配置直接重试。
4. 独立原始备份先使用 `baseline-only` 状态持久化；实际提交补丁时再原子升级为包含目标补丁和上一合法补丁哈希的所有权状态。即使在状态提交后、分区写入前中断，也不会把自己的旧补丁误判成 OTA。救援文件保存在模块目录之外并按 `_a`/`_b` 分开，模块安装失败被 Magisk 删除时也不会连带删除备份。
5. 解包后只选择 `project-id=0x5d0d` 的子镜像，其他项目 overlay 保持不变。
6. PPS 开关开启时，写入 A16 PJZ110 官方 PPS 55W 数值和 SOC/温度曲线，并把 CPA 的 PPS 标识由 33W 改为 55W。
7. PD/QC 实验开关开启时，把已有 9V 链路的 ICL 由 2A 改为 3A、输入功率由 18W 改为 27W；
   PD/QC 降温表保留 1200/1500mA 两个严格档，只把 ColorOS 常用的最高档由 2000mA 提高到 3000mA，
   避免系统写入 `cool_down=3～7` 时把已放开的链路重新压回 2A。同时只提高 PD/QC 两行 FCC 中
   原本 2200mA 的平台点；冷区、暖区、其他协议行以及接口/电池温度、AICL 等保护不变。
8. 对 PPS 参数表和 PD/QC FCC 表逐项验证；重打包后检查 DT table 头、条目元数据、顺序和每个子镜像。属性白名单之外的节点、属性和值必须与可信基线一致，协议列表与 PD/QC 输入功率则按基线计算完整期望值，不能只检查少数目标单元。构建器不再用零填充破坏原容器，而是逐字节保留原签名 vbmeta、按新的 DT table 长度重建 AVB footer，并在构建函数内部一次性复核 AVB0/vbmeta/AVBf 的位置、大小和内容，不再由外层立即重复同一校验。原始备份完成 `sync` 并复核后才会刷写；准备事务还会保存并校验刷写前完整镜像，刷写或回读失败时恢复该镜像和对应旧状态，而不是无条件退回最初原始 DTBO。

保留原签名 vbmeta 只保证 AVB 容器结构完整；其中的签名哈希描述符仍指向原始 DTBO，不会被本模块伪造或重新签名。因此修改后的镜像只能在 Bootloader 已解锁、设备允许 orange 状态启动时使用；锁定或无法从 Bootconfig 明确确认解锁时会在任何分区写入前拒绝。

DTBO 修改是持久的，必须重启才会进入新的设备树。late_start service 不会每次开机重复刷写。

跨设备使用时，模块采用 best-effort 策略：安装阶段会预检查并显示预计会跳过的
thermal zone、power_supply 节点、`/proc/shell-temp` 或厂商服务；运行阶段会把实际
跳过项记录到 `module.log`。thermal zone 数量不再写死，当前设备发现几个就处理几个。
只要至少一个 thermal zone 成功挂载，就不会因为其他入口失败而整体回滚。
默认只伪装当前值位于 10°C～130°C 的 thermal zone 和 power_supply 温度节点，
用于跳过 0、`-273000` 等明显不是正常温度读数的节点。`socd`、`vbat`、
`*-bcl-lvl*`、`*-ibat-lvl*` 等 BCL 百分比、电压、电流及状态节点会在分类、
映射和挂载前直接排除；其余 thermal zone 按常见毫摄氏度节点处理。
`sdr0`、`mmw_ific0` 等会随 5G/射频活动动态上线或深度休眠的节点归入
`DYNAMIC_RADIO` 分类，默认关闭伪装，避免挂载数量随网络活动在两种状态间波动。
除分类级配置外，`config.conf` 还支持按 thermal zone 的 `type` 写 `NODE_*`
覆盖项；未配置的节点继续继承分类配置，因此模块不依赖配套 App 也可以单独使用。

伪造文件通过 tmpfs 的 `context=` 挂载参数直接获得原温度节点使用的 SELinux 标签。
当前白名单包括 `sysfs_therm`、`sysfs_thermal`、`sysfs_battery_supply`、
`sysfs_batteryinfo`、`vendor_sysfs_battery_supply` 和 `vendor_sysfs_usb_supply`。
模块不会使用 `magiskpolicy --live` 修改运行时 SELinux 策略。

## 明确不会做的事情

- 不修改任何 XML。
- 不修改 `thermal.conf`。
- 不修改 CPU/GPU 频率。
- 不写 cooling device。
- 不写 thermal zone 的 `mode`、trip point 或 `emul_temp`。
- 不包含持续温度 watchdog。
- 充电补丁不修改 SVOOC/UFCS 曲线或其实际 6A 限制。
- 不加入 A16 的 12V PDO、PH2 硬件切换链路或 11V 过压阈值修改。
- 不提高满充电压，不改 Gauge 容量，不解除所谓“锁容”。
- 不把 A16-only 的 `curr_max_ma_percent` 写入 A15；A15 驱动没有解析该属性。

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
- dynamic radio，默认关闭
- modem/RF
- connectivity
- NTC/ambient
- unknown

温度伪装配置修改后可重启，或在 Magisk 模块页面点击 Action 重新应用。充电配置不会在开机时自动刷写，
必须通过 App 的“保存并应用”或 Magisk Action 明确执行。

充电配置默认值：

```properties
CHARGING_DTBO_ENABLE=0
PPS55_ENABLE=1
PD_QC_27W_ENABLE=0
```

新安装不会启用或刷写任何充电补丁。`PPS55_ENABLE=1` 只是预选 A16 官方 PJZ110 PPS 数据移植；
用户明确打开总开关并应用后才会执行。`PD_QC_27W_ENABLE=1` 是 A15 上的独立实验项，不是 A16 官方默认值，
因此默认关闭。把 `CHARGING_DTBO_ENABLE=0` 后应用，会逐个检查 `_a`、`_b`，并恢复所有权哈希仍匹配的原始 DTBO；任一槽位无法安全确认时整体返回失败并保留其救援文件。
`MASTER_ENABLE` 只控制温度伪装，不代替充电 DTBO 总开关。

独立备份目前只信任项目 `rescue/PJZ110-A77/SHA256SUMS` 中记录的 A/B 原始哈希。
如果已经 OTA、使用其他 Android 15 版本或分区被其他工具修改，按钮会拒绝把当前镜像登记成
“原始备份”；应先补充并审核对应 OTA 的可信原始哈希，不能用“强制备份”绕过。

## 安装顺序

1. 若安装过 `battery_unlocker`，必须先用它恢复原始 DTBO、卸载并重启；仅停用模块不足以撤销持久刷写。
2. 在 Magisk 中停用或卸载 AaTempSpoof、ColorOS解除温控限制及其他温度挂载模块。
3. 重启一次，确保旧模块的 bind mount 已全部消失。
4. 安装模块 ZIP。安装器持有与 App、Action、卸载入口相同的全局锁后，只做温度节点预检查和可信旧备份迁移，不会触碰 DTBO；升级时会保留原 `config.conf`，旧版缺失的充电键按安全默认值补齐。
5. 安装成功后重启，检查 `module.log` 和 `thermal-map.csv`。只有 PJZ110 Android 15 可以再主动应用充电补丁，脚本会在实际刷写前完成 SDK、槽位、项目 ID 和结构校验。

如果没有先处理旧模块，本模块会因冲突检测而拒绝应用，不会强行覆盖。

## 运行时文件

```text
/data/adb/coloros_fulltempspoof/module.log
/data/adb/coloros_fulltempspoof/thermal-map.csv
/data/adb/coloros_fulltempspoof/mounts.tsv
/data/adb/coloros_fulltempspoof/dtbo-rescue/original_dtbo_a.img
/data/adb/coloros_fulltempspoof/dtbo-rescue/charging_state_a.conf
/data/adb/coloros_fulltempspoof/dtbo-rescue/operation_a.conf
/data/adb/coloros_fulltempspoof/dtbo-rescue/prepared_a/
```

槽位 `_b` 使用对应的 `*_b` 文件。`prepared_a/current.img` 是提交阶段专用的刷写前回滚镜像；只有对应槽位提交或恢复成功后才会清理，失败时继续保留。进程中断遗留的 `.prepared_a.<pid>` 只会在持有全局运行锁时回收；若目录交换中断且正式目录缺失，`prepared_a.previous.<pid>` 会先恢复为正式目录。每次生成新候选前都会检查 A/B 两个槽位。卸载时只要仍有未解决的 prepared/回滚目录，就会保留整个救援目录并返回失败。救援目录权限为 `0700`，镜像与状态文件为 `0600`。运行锁使用独立的 `lock.v2`；升级期间若发现无法确认所有者的旧目录锁，普通入口会拒绝操作并交由下一次启动安全清理。

## 冲突

不得与 AaTempSpoof、ColorOS解除温控限制或其他对 thermal zone 进行挂载的模块同时运行；
充电部分不得与 `battery_unlocker` 或其他 DTBO 充电补丁叠加。发现已知冲突时，本模块会拒绝操作，
不会自动禁用或覆盖其他模块。

## 恢复

- 点击 Magisk Action：临时恢复真实节点并读取状态，随后按最新配置重新应用。
- 正常重启：bind mount 自动消失。
- 将 `CHARGING_DTBO_ENABLE=0` 后点击 Action：逐个检查 `_a`、`_b`，恢复所有完整哈希仍属于本模块的原始 DTBO。
- 卸载模块：执行 `uninstall.sh` 恢复运行时状态，并逐个检查 `_a`、`_b` 的所有权后恢复；任一槽位无法安全恢复时保留整个救援目录。

切换槽位不会覆盖另一槽位的备份。如果某个 DTBO 已被 OTA/其他工具改写，模块会拒绝把该未知镜像重新定义为原始基线，且不会自动覆盖它；对应救援备份会继续保留供人工判断。

## 风险边界

默认配置会伪装包括电池、PMIC、充电器和 soc_max 在内的全部温度入口。
Horae、MTK 或 Qualcomm 厂商温控服务默认均为 `keep`，不会被停止或重启；只有手动把对应
`*_SERVICE_MODE` 改为 `stop`、`restart` 或 `stop_then_restart` 后才会处理。内核 116.5°C critical 是最后保护，
并不是适合长期触发的工作温度；电池、充电 IC 或其他硬件也可能在到达该阈值前受损。

PPS55 移植采用的是 A16 同机型数据，但 A15 的完整充电栈并不等同于 A16；PD/QC 27W 更是实验配置。
配置值只是上限，不保证充电器一定协商到对应功率。温度伪装还可能让用户空间策略看不到真实温升，
因此首次使用必须在可立即断电的环境中观察电池、接口和充电器的真实温度与异常行为。
