# 为什么必须用 cctv18 树

> 本文件记录**根因**。三次失败的完整时间线见 [`FAILURE-LOG.md`](FAILURE-LOG.md)。
> 所有数据为实机实测（2026-10-07 ~ 2026-10-08）。

---

## 结论

**能否开机由「源码树血统」决定，而不是由配置项的微调决定。**

`aosp-mirror/kernel_common`（Google 上游 GKI）缺一整层小米/高通适配。用它编出的内核，
即使把所有 ABI 相关配置都对齐到 100%，**仍然卡在第一屏**。

---

## 证据一：厂商适配标志的三方对照

用 cctv18 树特有的标志去测「能开机的 Jianke」与「真原厂」：

| 标志 | Jianke(6.12.111) | 真原厂 OTA(6.12.69) | cctv18 defconfig | AOSP 上游树 |
|---|---|---|---|---|
| `GKI_HACKS_TO_FIX` | y | y | **y** | ✗ |
| `GCMA` / `GCMA_SYSFS` | y | y | **y** | ✗ |
| `RT_SOFTIRQ_AWARE_SCHED` | y | y | **y** | ✗ |
| `UNWIND_PATCH_PAC_INTO_SCS` | y | y | **y** | ✗ |
| `SCHED_PROXY_EXEC` | y | y | **y** | ✗ |
| `MODULE_SCMVERSION` | y | y | **y** | ✗ |
| `CPUSETS_V1` / `MEMCG_V1` | y | y | **y** | ✗ |
| `AUTOFDO_CLANG` | y | y | **y** | ✗ |
| `GKI_TASK_STRUCT_VENDOR_SIZE_MAX` | 1024 | 1024 | **1024** | 512（默认） |

**Jianke 命中 12/14。** 这些项全部由 cctv18 树自带，AOSP 上游树里根本没有对应的 Kconfig。

---

## 证据二：版本号精确对齐

```
cctv18/android_gki_kernel_common 分支与 SUBLEVEL:
    android16-6.12-2025-06   → 23
    android16-6.12-2026-03   → 69   ★ 与设备原厂完全一致
    android14-6.1-lts        → （无关）

设备原厂 uname -r = 6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k
```

上游 `aosp-mirror/kernel_common@android16-6.12` 是**滚动分支**，我们当时拿到的是
`6.12.93`（README 与 Makefile 实测），比设备新 24 个 patchlevel。

---

## 证据三：血统图（社区实证）

网上可查的、能在小米 17 系列开机的第三方内核，**全部**源自 cctv18 这棵树：

```
aosp-mirror/kernel_common（Google 上游 GKI）
    │
    └─ cctv18/android_gki_kernel_common   ← 小米/高通适配层（LOCALVERSION="-4k"）
            ├─ YuzakiKokuban/android_kernel_xiaomi_sm8850    (Kokuban, 46★/186 releases, +40 commits)
            ├─ Picters Kernel                                 (XDA, "KMI-Safe: Drop-in replacement")
            ├─ Jianke 6.12.111                                (设备上实测能开机)
            └─ 本仓                                           (只用树自带 defconfig)
```

共同点：**第一行都是 `CONFIG_LOCALVERSION="-4k"`**，且都带 `GKI_HACKS_TO_FIX=y`。

---

## 证据四：决定性反例

「修复版」这个中间产物非常有价值，因为它**排除**了两个候选解释：

| 候选解释 | 修复版的做法 | 结果 |
|---|---|---|
| 「ABI 不匹配」 | 四重 ABI 校验全部对齐（`msm_drm` DIFF=0，`struct module` 1600/75，`kobject_uevent_env` 0x8bb6d45c） | ✗ **仍然卡屏** |
| 「KernelSU 干扰」 | 完全不内置 KSU（LKM-only） | ✗ **仍然卡屏** |
| 「cmdline 注入干扰」 | 移除全部 `patch_cmdline` | ✗ **仍然卡屏** |
| **「源码树血统」** | 换成 cctv18 树 | ✅ **开机成功** |

> 修复版 ABI 已 100% 对齐却仍失败 —— 这是「血统才是决定因素」最硬的证据。
> 说明：**用错的树对齐出来的 ABI，对齐得再准也不充分。**

---

## 那 ABI 校验还有用吗

**有用，但它的定位要修正。**

- ABI 校验是**必要条件**，不是充分条件。它能排除一整类故障（模块拒载），
  本次成功版的 `msm_drm` 加载、670 个模块零符号错误，正是校验预测的兑现。
- 但它**不能**替代「选对树」。选错树时 ABI 校验会给你虚假的安全感。

正确顺序：

```
1. 选对树（血统）        ← 决定性
2. 版本号对齐原厂        ← 重要
3. 走 GKI 官方构建入口    ← 重要（_setup_env.sh）
4. 不引入 ftrace 等 ABI 敏感项
5. 四重 ABI 校验         ← 验证手段，非保证
```

---

## 代价对比

| 方案 | 代价 | 结果 |
|---|---|---|
| 用 AOSP 上游树自己对齐 | 三次编译 + 三次刷机 + 三天排查 | ✗ 全败 |
| 用 cctv18 树 | 一次编译（6分19秒）+ 一次刷机 | ✅ 成功 |

**教训**：当社区已有成熟血统时，先复现它的基线，再谈增量优化。

---

## UNVERIFIED 项

本文件未证实的假设，不得当成结论使用：

1. **具体是哪个厂商适配项起决定作用** —— 未做逐个开关的二分验证。
   `GKI_HACKS_TO_FIX` 只是相关标志中最显眼的一个，**不是已证实的因果**。
2. **内核安全补丁日期（SPL）对齐的影响** —— 有社区文章警告「SPL 不得比设备旧」，
   本机设备 SPL 为 `2026-09-01`，cctv18 树的 SPL **尚未核查**。`UNVERIFIED`
3. **`MI_SCHED_EXT` 的来源** —— 真原厂为 `y`，但 cctv18 与 Kokuban 树里都没有该
   Kconfig 项，推测来自 vendor 模块层（`vendor_dlkm`）而非 GKI。**假设未证实。**

---

*本文基于 2026-10-08 实测数据。*