# 实机事实（设备侧，只读采集）

> 采集时间：2026-10-08
> 采集方式：`/proc/bootconfig`、`getprop`、`modinfo`、`blockdev`、`lsmod`
> **本文件不含序列号、IMEI、账号、IP 等个人标识。**

---

## 设备身份

| 字段 | 值 | 来源 |
|---|---|---|
| 代号 | `pudding` | `ro.product.device` |
| 平台 | `canoe` | `ro.board.platform` |
| 型号 | `25113PN0EC` | `ro.product.model` |
| SoC | `SM8850` | `ro.soc.model` |
| Android | 17 (SDK 37) | `ro.build.version.*` |
| 安全补丁 | `2026-09-01` | `ro.*.build.security_patch` |

---

## 内核与 KMI

```
原厂 uname -r : 6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k
主版本主线    : 6.12
SUBLEVEL      : 69

KMI 权威来源  : vendor 模块的 vermagic
  cmd: modinfo /vendor_dlkm/lib/modules/msm_drm.ko | grep vermagic
  结果: 6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
  → KMI 世代 = android16-6-4k
```

> **坑**：KMI 名（`android16-6-4k`）**不等于** OS 大版本。
> 本机 OS 是 Android 17，但 KMI 名是 `android16-*`。
> 第三方内核的 `uname -r` 里**没有** `androidNN` 标记，
> 采集脚本按 `uname -r` 解析会恒判 UNKNOWN —— 必须从 vendor 模块 vermagic 兜底。

---

## 分区与槽位

```
slot_suffix       = _a
verifiedbootstate = orange      （取自 /proc/bootconfig，非 getprop）
vbmeta.device_state = unlocked

boot_a        → /dev/block/sde14    100,663,296 B (96 MB)
init_boot_a   → /dev/block/sde30      8,388,608 B (8 MB)
vendor_boot_a → /dev/block/sde25    100,663,296 B
dtbo_a        → /dev/block/sde18     33,554,432 B (32 MB)
```

UFS 多 LUN 布局（`sda`–`sdf`）。

> **警告**：`getprop ro.boot.flash.locked` 与 `ro.boot.verifiedbootstate` 在本机**被伪造**
> （装了 tricky_store / playintegrityfix 这类隐藏模块）。
> `getprop` 报 `green`/`locked`，`/proc/bootconfig` 报 `orange`/`unlocked`。
> **一律以 `/proc/bootconfig` 为准。** 拿被伪造的值判「能不能刷」会把结论判反。

---

## root 模式

```
模式        : KernelSU LKM（非内置）
ksud        : 4.2.0-1-g904c60d1 (uapi: 2)
context     : u:r:ksu:s0
补丁所在分区: init_boot
```

**为什么是 `init_boot`**：GKI 设备上内核在 `boot`、通用 ramdisk 在 `init_boot`。
KernelSU 的 LKM 模式把 `kernelsu.ko` 打进 ramdisk，所以补丁在 `init_boot`。
刷新的 `boot.img` **不会**抹掉它 —— 会不会掉 root，取决于新内核的模块校验是否还让那个 `.ko` 加载。

**本仓方案实测**：不内置 KSU、只换 `boot` 内 Image → root 完好（`boot_index` 365 后实测）。

---

## 模块基线

```
已加载模块  : 660（原厂）
            670（本仓成功版，多 10 个）
vendor_dlkm : 404 个 .ko
dmesg 符号错误 : 0
```

关键模块（成功版实测已加载）：

```
msm_drm              显示栈，卡屏故障的直接嫌疑对象
qcom_va_minidump
hdcp_qseecom_dlkm
cnss2 / cnss_utils / qca_cld3_peach_v2   WiFi
btpower                                  蓝牙
```

---

## boot 镜像结构（header v4）

```
STOCK 原厂 : kernel_sz 41,576,960   ramdisk_sz 0
JIANKE     : kernel_sz 91,199,456   ramdisk_sz 0
两者 kernel 段末尾均不含 FDT magic
```

`ramdisk_sz = 0` → ramdisk-less 设备 → AnyKernel3 走 `flash_boot` 分支（非 `write_boot`）。

---

## 系统现状（成功版运行 4 分钟后）

```
uname -r    6.12.69-android16-6-4k-Ma6302
boot_index  365
温度        51.7 °C
内存        15085 MB total / 16383 MB swap
ZRAM        zram0 16GB 挂载，算法 lzo-rle
声卡        canoe-mtp-snd-card
相机        /dev/video0 / 1 / 32 / 33
显示        /dev/dri/card0 + renderD128
信号        基带 MPSS.DE.9.0，SIM LOADED，NR_SA
```

---

## 分区备份清单（刷机前必须已有）

| 文件 | md5 | 说明 |
|---|---|---|
| `stock-boot.img` | `5157f9020b45b51ec1701c79cda9b93d` | 真原厂 6.12.69，首选回滚镜像 |
| `boot_a.img` | `5329fec9e9c154913673065734662067` | Jianke 6.12.111 备份，备用 |
| `init_boot_a.img` | `f78cdace08393da6272c658f2e1cc66e` | KSU 补丁所在分区 |

> **这些文件必须在刷机前拷到 PC 上**，因为 fastboot 阶段读不到手机内部存储。

---

## UNKNOWN / UNVERIFIED

| 项 | 状态 | 说明 |
|---|---|---|
| ARB 指数 | `UNKNOWN` | 机内无 `ro.boot.anti`；需 fastboot 侧查询。侧面证据：blackbox 里 `stored_rollback_index is: 1` 多轮一致，**未见变化** |
| EDL(9008) 兜底 | `UNKNOWN` | 硬件层通道存在（UFS 多 LUN），是否需要授权文件未验证 |
| 内核 SPL | `UNVERIFIED` | 设备 SPL 为 `2026-09-01`；cctv18 树的 SPL 未核查 |
| `MI_SCHED_EXT` 来源 | `UNVERIFIED` | 原厂为 y，但两棵树里都无此 Kconfig 项，推测来自 vendor 模块层 |
