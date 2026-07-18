# PJZ110 Android 15 A.77 DTBO 救砖手册

本目录保存的是这台 PJZ110 在 `PJZ110_11.A.77_0770_202508130220`、活动槽 `_a` 时，从真实分区只读取得的原始 A/B DTBO。

## 备份文件

| 文件 | 对应分区 | 字节数 | SHA-256 |
|---|---|---:|---|
| `dtbo_a.img` | `dtbo_a` | 25165824 | `d02115e11e519a0ad1d03fdf05f491baed409a9f7a05ff83cf4907b3d1d39ec5` |
| `dtbo_b.img` | `dtbo_b` | 25165824 | `95aeaae03b56c171cf88753c821630a3c24f1fcf406cec3e17d56781aa3f8369` |

两个槽位的镜像本来就不同，严禁互换。

## 每次救援前先校验本地文件

```bash
cd /Users/zhangzhengwei/code/PFFM20-FullTempSpoof/rescue/PJZ110-A77
wc -c dtbo_a.img dtbo_b.img
shasum -a 256 dtbo_a.img dtbo_b.img
```

输出必须与上表及 `SHA256SUMS` 完全一致。任何大小或哈希不一致都必须停止，不能刷写。

## 场景一：手机仍能进入系统并且 ADB/root 可用

1. 如果 App 能正常读取模块状态，优先使用“安全恢复原始 DTBO”。
2. 或将模块配置中的 `CHARGING_DTBO_ENABLE` 改为 `0`，再运行 Magisk Action。
3. 必须看到恢复成功、完整哈希校验成功和“必须重启”提示后，才能重启。
4. 如果页面或脚本显示 `RESCUE_REQUIRED`、`禁止重启`、分区哈希未知，停止反复应用；不要直接重启，改用下面的 fastboot 方案。

仅停用或删除 Magisk 模块不能撤销已经持久写入的 DTBO。

## 场景二：无法开机，但 Bootloader fastboot 可用

先连接手机并确认 fastboot 与当前槽位：

```bash
fastboot devices
fastboot getvar current-slot 2>&1
```

如果明确返回当前槽位为 `a`：

```bash
cd /Users/zhangzhengwei/code/PFFM20-FullTempSpoof/rescue/PJZ110-A77
shasum -a 256 dtbo_a.img
fastboot flash dtbo_a dtbo_a.img
fastboot reboot
```

如果明确返回当前槽位为 `b`：

```bash
cd /Users/zhangzhengwei/code/PFFM20-FullTempSpoof/rescue/PJZ110-A77
shasum -a 256 dtbo_b.img
fastboot flash dtbo_b dtbo_b.img
fastboot reboot
```

只有 fastboot 明确报告刷写成功后才执行 `fastboot reboot`。如果出现 `partition doesn't exist`、`flashing is not allowed`、槽位无法确认或任何错误，立即停止，不要改刷另一个槽位，也不要执行 erase。

## 场景三：fastboot 无法刷写

1. 如果 Recovery 提供具有块设备写权限的 root ADB shell，可在确认槽位并校验镜像后恢复对应 `dtbo_a` 或 `dtbo_b`。
2. Stock Recovery 只有 sideload、无法写块设备时，不要盲目尝试。
3. 使用与当前系统版本完全匹配的官方完整固件、官方下载模式、EDL/售后工具恢复。

当前本地另一个 OTA `PJZ110_11.C.91_1910_202607021252` 是 Android 16，不是本机备份时的 Android 15 A.77，严禁拿 C.91 的 DTBO 修复 A.77。

## 恢复成功后

1. 进入系统后再次读取对应分区 SHA-256，必须与本目录记录一致。
2. 将 `CHARGING_DTBO_ENABLE=0`，避免以后手动点击 Action 时再次应用补丁。
3. 在确认 A/B DTBO 均为正确原始镜像前，不得重新锁定 Bootloader。
4. 保留本目录的两个镜像，不要用以后系统版本的文件覆盖。

## 严禁操作

- 严禁执行 `fastboot erase dtbo`。
- 严禁把 `dtbo_a.img` 刷到 `dtbo_b`，或反向互换。
- 严禁使用 Android 16 C.91 镜像修复 Android 15 A.77。
- 严禁在补丁仍存在时重新锁定 Bootloader。
- 严禁在 `RESCUE_REQUIRED` 且当前分区未知时反复重启。
