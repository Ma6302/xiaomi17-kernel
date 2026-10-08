# 配置对比分析

> 数据来源：`stock-ota-boot.img`（真原厂 6.12.69）的 IKCFG 段、设备实读
> `msm_drm.ko` 的 vermagic、以及三棵树的 `gki_defconfig`。
> **本目录不含上游文件副本** —— 原始 defconfig 可按 `versions.lock` 现取。

---

## 一、三方 defconfig 对比（决定性判据）

用 cctv18 树特有的厂商适配标志去测三棵树：

| 标志 | Jianke(6.12.111) | 真原厂(6.12.69) | cctv18 defconfig | AOSP 上游树 |
|---|---|---|---|---|
| `GKI_HACKS_TO_FIX` | y | y | **y** | ✗ 无此项 |
| `GCMA` | y | y | **y** | ✗ |
| `GCMA_SYSFS` | y | y | **y** | ✗ |
| `RT_SOFTIRQ_AWARE_SCHED` | y | y | **y** | ✗ |
| `UNWIND_PATCH_PAC_INTO_SCS` | y | y | **y** | ✗ |
| `SCHED_PROXY_EXEC` | y | y | **y** | ✗ |
| `SCHED_CLASS_EXT` | y | y | **y** | ✗ |
| `MODULE_SCMVERSION` | y | y | **y** | ✗ |
| `CPUSETS_V1` | y | y | **y** | ✗ |
| `MEMCG_V1` | y | y | **y** | ✗ |
| `AUTOFDO_CLANG` | y | y | **y** | ✗ |
| `HIBERNATION` | y | y | **y** | ✗ |
| `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` | 1024 | 1024 | **1024** | 512（Kconfig 默认） |

**Jianke 命中 12/14**，与 cctv18 完全一致。

> 注：未命中的两项是 `REKERNEL_NETWORK` / `HYBRIDMOUNT` —— 那是 Kokuban 后来加的，
> Jianke 与真原厂都没有。

---

## 二、关键配置项逐条核对

真原厂值 vs cctv18 `android16-6.12-2026-03` 值：

| CONFIG | 真原厂 6.12.69 | cctv18 2026-03 | 判定 |
|---|---|---|---|
| `LOCALVERSION` | `"-4k"` | `"-4k"` | ✅ 一致 |
| `PID_NS` | **n** | **n** | ✅ 一致（早期误判为差异，实因取错分支） |
| `GKI_HACKS_TO_FIX` | y | y | ✅ |
| `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` | 1024 | 1024 | ✅ |
| `MODULE_SCMVERSION` | y | y | ✅ |
| `FUNCTION_TRACER` | **n** | **n** | ✅ |
| `STACK_TRACER` | **n** | **n** | ✅ |
| `CFI_CLANG` | y | y | ✅ |
| `SHADOW_CALL_STACK` | y | y | ✅ |
| `GENDWARFKSYMS` | y | y | ✅ |
| `DEBUG_INFO_BTF` | y | y | ✅ |
| `MODULE_SIG` | y | y | ✅ |
| `MODULE_SIG_FORCE` | n | n | ✅ |
| `ZRAM_BACKEND_ZSTD` | y | y | ✅ |
| `ZRAM_MULTI_COMP` | y | y | ✅ |
| `ZRAM_ANDROID_IOCTL` | y | y | ✅ |
| `F2FS_FS_COMPRESSION` | y | y | ✅ |
| `SCHED_CLASS_EXT` | y | y | ✅ |
| `RT_SOFTIRQ_AWARE_SCHED` | y | y | ✅ |
| `LRU_GEN`（MGLRU） | y | y | ✅ |
| `AUTOFDO_CLANG` | y | y | ✅ |

**结论：`android16-6.12-2026-03` 与真原厂在全部关键项上零差异。**

---

## 三、分支版本号对照（选分支的依据）

```
cctv18/android_gki_kernel_common
    android16-6.12-2025-06   → SUBLEVEL = 23
    android16-6.12-2026-03   → SUBLEVEL = 69   ★ 选它
    android14-6.1-lts        → （无关）

设备原厂 uname -r = 6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k
                                                        ^^ SUBLEVEL 69

我们此前用的 aosp-mirror/kernel_common @ android16-6.12 = 6.12.93（比原厂新 24 个 patchlevel）
```

---

## 四、文件级差异（2026-03 有而 2025-06 无）

26 项，其中与本研究相关的：

```
+ CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX = 1024   ← 正是 V1/V2 缺的那一项
+ CONFIG_ZRAM_ANDROID_IOCTL = y                    ← 小米 zram ioctl 接口
+ CONFIG_ZRAM_BACKEND_ZSTD = y
+ CONFIG_ZRAM_MULTI_COMP = y
+ CONFIG_ZRAM_WRITEBACK = y
+ CONFIG_TCP_CONG_BBR = y
+ CONFIG_SECURITY_LANDLOCK = y
```

---

## 五、`MI_SCHED_EXT` 的归属（重要：避免误判）

```
真原厂配置 : CONFIG_MI_SCHED_EXT=y
cctv18 树  : 无此 Kconfig 项
Kokuban 树 : 无此 Kconfig 项
```

**推断**：该配置来自 vendor 模块层（`vendor_dlkm`），不是 GKI 内核配置项。
证据：两棵能开机的树都没有它，却在真原厂 `/proc/config.gz` 里为 `y`。

**状态：UNVERIFIED** —— 未做进一步验证，仅作假设记录。

---

## 六、如何自行复核

```bash
# 取上游 defconfig（按 versions.lock 的 SHA）
./scripts/fetch-sources.sh
head -1 src/arch/arm64/configs/gki_defconfig        # CONFIG_LOCALVERSION="-4k"

# 提取真原厂配置（需要设备 OTA 的 boot.img）
# IKCFG 段 -> gzip 解压；或用 extract-ikconfig 脚本
scripts/extract-ikconfig stock-boot.img > ota.config

# 逐项对比
python3 scripts/analysis/compare-configs.py ota.config \
    src/arch/arm64/configs/gki_defconfig
```

> **本目录刻意不存放 defconfig 副本**：它们逐字取自上游，按 `versions.lock` 即可复现。

---

*分析时间：2026-10-08。所有数值经命令实测。*