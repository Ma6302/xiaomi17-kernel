# 刷机与回滚

> **刷机是不可逆动作。本文的每一条都来自实测。**
> 三次失败、三次成功回滚，路径已验证。

---

## 铁律（先读）

1. **刷前必须把回滚镜像拷到 PC。**
   fastboot 阶段读不到手机内部存储，也没法从手机取文件。
2. **`init_boot` 不要动。** root 的 LKM 补丁在那里；只换 `boot` 即可。
3. **绝不要执行整包 `flash_all`。** 会触发 ARB（防回滚），不可逆。
4. **本仓方案没有 panic 自动重启配置。** 卡住不会自己重启，需手动复位。

---

## 刷前检查清单

```bash
# 1) 确认当前基线
uname -r                                  # 记下来
grep -o 'boot_index=[0-9]*' /proc/cmdline
md5sum /dev/block/by-name/boot_a
md5sum /dev/block/by-name/init_boot_a

# 2) 确认回滚文件存在且 md5 匹配（见 docs/device-facts.md）
ls -la /sdcard/Download/pudding-kernel/stock-boot.img
md5sum /sdcard/Download/pudding-kernel/stock-boot.img
#   期望: 5157f9020b45b51ec1701c79cda9b93d

# 3) 确认待刷包
md5sum /sdcard/Download/pudding-kernel/pudding-cctv18-20261008.zip
#   期望: 596cf12d745f0651450ca5623db2f9d2
```

**在 PC 上确认这两个文件已存在**：

| 文件 | md5 | 用途 |
|---|---|---|
| `stock-boot.img` | `5157f9020b45b51ec1701c79cda9b93d` | 首选回滚（真原厂 6.12.69） |
| `boot_a.img` | `5329fec9e9c154913673065734662067` | 备用回滚（Jianke 6.12.111） |

---

## 刷入

### 方式 A：Horizon Kernel Flasher / SukiSU（推荐）

在手机上刷：

```
/sdcard/Download/pudding-kernel/pudding-cctv18-20261008.zip
```

AnyKernel3 会：
1. 读 `/proc/bootconfig` 校验 `hardware.sku` ∈ {pudding, canoe}，不匹配则 abort
2. 解包当前 `boot` 分区
3. 只替换 `Image`
4. 重新打包并写回 `boot`

### 方式 B：PC fastboot（需要 boot.img，不是 AK3 zip）

```bash
fastboot flash boot_a boot-new.img
```

---

## 回滚（★ 必须在 PC 上手动执行）

```bash
fastboot flash boot_a stock-boot.img
```

**为什么必须手动**：fastboot 阶段 Android 没起来，手机侧的 AI 助手不可用。
这条路径只能由人在 PC 上完成。

---

## 卡住时的自救流程（已实测两次）

```
1. 长按 音量下 + 电源（一次）  → 进入 fastboot
2. PC 上: fastboot devices     → 确认设备可见
3. PC 上: fastboot flash boot_a stock-boot.img
4. 重启 → 正常开机
```

**实测记录**：

| 轮次 | 症状 | 复位方式 | 结果 |
|---|---|---|---|
| V1（boot_index 354） | 卡第一屏，静默 | 音量下+电源 → fastboot | ✅ 刷回后开机 |
| V2（boot_index 356） | 卡第一屏，静默 | 同上 | ✅ |
| 修复版（361/362） | 卡屏 → 屏幕下缘闪 → 自动重启循环 | 同上 | ✅ |

**关键观察**：XBL 层的按键始终可交互 → 不是全局硬死锁。

---

## 刷后验证

```bash
# 1) 确认是我们的内核在跑
uname -r                       # 6.12.69-android16-6-4k-Ma6302
grep -o 'boot_index=[0-9]*' /proc/cmdline   # 应是新的一轮

# 2) 模块加载无错
dmesg | grep -ic 'disagrees about version\|Unknown symbol'   # 期望 0
lsmod | wc -l                                                # 期望 ~670

# 3) root 是否还在
/data/adb/ksud -V
id                             # 期望 uid=0 context=u:r:ksu:s0

# 4) 关键硬件
ls /dev/dri/                   # card0 renderD128
lsmod | grep -c msm_drm        # 1
ip link | grep wlan0           # 存在
ls /dev/video0                 # 相机
cat /proc/asound/cards         # canoe-mtp-snd-card

# 5) 无崩溃
dmesg | grep -ic 'kernel panic\|Oops'   # 期望 0
```

---

## 分区结构（本机实测）

```
boot_a        → /dev/block/sde14    100,663,296 B (96 MB)
init_boot_a   → /dev/block/sde30      8,388,608 B (8 MB)   ← root 补丁，不要动
vendor_boot_a → /dev/block/sde25    100,663,296 B
dtbo_a        → /dev/block/sde18     33,554,432 B (32 MB)
```

我们的 Image 是 41.9 MB，`boot_a` 有 96 MB → 空间充足。

---

## 传输：把文件从 PC 放到手机

本机实测的可行方法（USB adb 不可用时的替代）：

### 手机起接收器 + PC 主动上传（★ 实测可用）

```bash
# 手机侧（HTTP 接收服务，见 scripts/ 或 kernel-dev/upload_recv.py）
python3 upload_recv.py 9999 /sdcard/Download/pudding-kernel

# PC 侧
curl -X POST --data-binary @file.zip http://<手机IP>:9999/file.zip
```

**为什么这个方向可行**：PC → 手机的**出站**连接不受 Windows 防火墙影响；
反过来（PC 起服务、手机去连）会被入站规则拦截。

实测拓扑：手机 `rndis0` = `10.103.66.154/24`，PC = `10.103.66.151`。

---

## 绝对不要做

| 禁止 | 原因 |
|---|---|
| `fastboot flash_all` / 整包刷 | **触发 ARB，不可逆** |
| 动 `vbmeta` | 除非明确知道在做什么；本方案不需要 |
| 刷 `init_boot` | 会动到 root 补丁；本方案不需要 |
| 动 `persist` / `modemst1` / `modemst2` / `frp` / `misc` | 会丢设备凭证 |
| 重锁 BL | 需先回全原厂；否则直接砖 |
| 在没备份的情况下开刷 | 无回滚路径 |

---

## ARB（防回滚）现状

```
机内 ro.boot.anti : 空 → UNKNOWN

侧面证据（blackbox 分区实测）:
  the stored_rollback_index is: 1
  在 boot_index 361 / 362 / 364 多轮中保持一致，未见变化
```

**结论**：多次刷 `boot` 未导致 ARB 变化（刷 `boot` 本身不涉及 ARB 计数）。
但整体状态仍是 `UNKNOWN` —— 需在 fastboot 里查 `fastboot getvar anti` 才能确定。

---

*本文基于 2026-10-07 ~ 2026-10-08 实测。*