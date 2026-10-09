# 分析 05 — 能否像 Jianke 那样把内核更新到 6.12.111

> 调研时间：2026-10-08。所有数据来自命令实测或上游源码原文。
> 结论：**技术上可行，但没有现成树；这是「换地基」不是「加功能」。**

---

## 0. 一句话结论

```
「更新到 111」本身能做到 —— 跨版本加载模块这条路已被证伪为障碍
但不存在现成的 6.12.111 GKI 树，必须自己合 42 个上游 stable 版本
而且这是「换地基」，与我们接下来要做的「加功能」是两件事
```

---

## 1. 先破除一个误解：跨版本加载模块不是障碍

设备上跑着两套 actives证据：

| 内核 | vermagic | 加载的模块 vermagic | 结果 |
|---|---|---|---|
| 原厂 | `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k` | 同 | ✅ |
| **Jianke** | `6.12.111-Jianke` | `6.12.69-android16-6-4k` | ✅ **能开机** |
| **我们** | `6.12.69-android16-6-4k-Ma6302` | `6.12.69-android16-6-4k` | ✅ 670 模块 |

Jianke 的内核与模块 **SUBLEVEL 不同（111 vs 69）、LOCALVERSION 完全不同**，仍正常工作。

### 机制：`same_magic()`

上游源码原文（`kernel/module/version.c`，取自 kernel.org stable 树）：

```c
int same_magic(const char *amagic, const char *bmagic, bool has_crcs)
{
	if (has_crcs) {
		amagic += strcspn(amagic, " ");   /* 跳过第一个空格之前的内容 */
		bmagic += strcspn(bmagic, " ");
	}
	return strcmp(amagic, bmagic) == 0;
}
```

**实测比对：`v6.12.69` 与 `v6.12.111` 的 `version.c` 逐字相同（均 2449 字节），
`internal.h` 也逐字相同（均 12163 字节）。**

因此当模块带 `__versions` 段（`CONFIG_MODVERSIONS=y`，本设备为 y）时：

```
比较内容 = 从第一个空格开始的部分
内核 : "6.12.111-Jianke SMP preempt mod_unload modversions aarch64"
                          ↓ 跳过 "6.12.111-Jianke"
模块 : "6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64"
                          ↓ 跳过 "6.12.69-android16-6-4k"
两边都是 " SMP preempt mod_unload modversions aarch64"      → 相同 ✅
```

**结论：vermagic 里的版本号在有 CRC 时被忽略。真正决定成败的是符号 CRC。**

---

## 2. 但全 GitHub 没有现成的 6.12.111 树

实测（GitHub API）：

| 仓库 | 6.12 相关分支 | SUBLEVEL |
|---|---|---|
| `cctv18/android_gki_kernel_common` | `android16-6.12-2025-06` | 6.12.**23** |
| | `android16-6.12-2026-03` | 6.12.**69** ← 我们用的 |
| `aosp-mirror/kernel_common` | 9 个 `android16-6.12-*` | 最高 6.12.**38** |
| 搜索 `android16-6.12.111` | — | 命中 **0** |
| 搜索 `android16-6.12.112` | — | 命中 **0** |

**Jianke 的 111 是有人自己把上游 stable 合进 GKI 树做出来的，不是现成分支。**

### Jianke 的自编证据

```
kernel 段  91,199,456 字节（87 MB）  ← 原厂 40 MB 的 2.19 倍
内含       6.12.111-Jianke
           6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k  ← 原厂串也在
编译者     Linux version 6.12.111-Jianke (JK@JK)
工具链     Android (14043575, ...) clang 19.0.1 r536225     ← 与我们同源
```

87 MB（近 2 倍体积）+ 原厂版本串同在 → 极可能是**未剥离调试信息**或
**包含额外内容**的构建，非标准 GKI 产出。

---

## 3. 上游 stable 版本时间线

```
6.12.69    ← cctv18 2026-03 分支当前，设备原厂
   ⋮       42 个版本
6.12.111   ← 2026-09-21 发布（Jianke 用的，ChangeLog 1,491,617 字节）
6.12.112   ← 2026-10-03 发布（当前最新，ChangeLog 1,420,046 字节）
6.12.113   ← 不存在（HTTP 404）
```

设备 SPL = `2026-09-01`。6.12.111（09-21）能覆盖到 2026-09 的安全补丁。

---

## 4. cctv18 分支的真实状态（重要）

2026-03 分支的提交记录显示**它一直在合上游**，但 **SUBLEVEL 不动**：

```
58ee67741  2026-03-16  Add Re-Kernel & Re-Kernel netlink support
155a5e4d1  2026-03-16  Add TCP Brutal congestion control algorithm
5db96082c  2026-03-16  Add Adaptive Deadline I/O Scheduler
2b6d0e267  2026-09-16  Deprecate Wunused-command-line-argument
93f6fb80e  2026-09-16  Create _setup_env.sh
a9cd3b35f  2026-08-13  BACKPORT: ring-buffer: Fix subbuf resize race...
0911f84ba  2026-04-21  UPSTREAM: ipv6: rpl: reserve mac_len headroom...
77da0d885  2026-07-17  UPSTREAM: slab: Introduce kmalloc_obj() and family
1c8ee14aa  2026-07-25  UPSTREAM: posix-cpu-timers: Prevent UAF...
```

- 维护者**在打补丁**（日期到 2026-09），但**不提升 SUBLEVEL 号**
- 仓库 `pushed_at` = 2026-09-17，仍活跃
- 默认分支是 `2025-06`（不是我们用的 `2026-03`）

**推论：cctv18 的策略是「保持 SUBLEVEL 稳定 + 挑选性合入上游修复」，
而不是「整条 stable 合流」。** 这解释了为什么它的 SUBLEVEL 一直是 69。

---

## 5. 三条路线对比

| 路线 | 做法 | 优点 | 风险 |
|---|---|---|---|
| **A. 自己合 stable** | cctv18 6.12.69 + 上游 6.12.111 补丁 | 版本最新、安全补丁最全 | 42 个版本累积变更；可能再次卡第一屏；ABI 需全量重验 |
| **B. 保持 6.12.69** | 不动 | 已知可用（当前基线） | 内核版本不更新 |
| **C. 等 cctv18 更新** | 等维护者提升 SUBLEVEL | 最安全（血统已验证） | 时间不可控，可能永远不升 |

### 路线 A 的具体风险

```
1. 42 个 stable 版本累积变更，可能触及厂商适配层（GKI_HACKS_TO_FIX 等）
   → 重蹈「卡第一屏」，而这次原因更难定位（不是树选错，是补丁冲突）
2. struct module 布局可能变化 → 破坏 ABI → 厂商模块拒载
3. 导出符号 CRC 若变化 → 必须同步更新 gki/aarch64/abi.stg
4. 我们现有的 ABI 校验基准数据（10235 个符号全对齐）全部作废，需重建
```

### 路线 A 的可行性依据

stable 补丁**原则上不改变导出 ABI**（否则就不是 stable 了）。
这正是 Jianke 能跨 69→111 的原因。所以 A 路线**理论上安全**，但需要实测验证。

---

## 6. 建议

### 短期：先加功能，不动版本

理由：
```
1. 我们已有「能开机、零调优」的干净基线 → 加功能是对已知可用系统做增量
2. 合 stable 是「换地基」→ 与「加功能」目标不同，一次只应动一个变量
3. 换地基后再加功能，出问题无法区分是补丁冲突还是功能改动
4. ABI 基准数据在换版本后会作废，之前所有验证工作需重做
```

### 如果确实要上 111

正确顺序：
```
1. 在 cctv18 工作树上加 stable remote
2. 合 6.12.111（或 112）→ 解决冲突（预计会碰到厂商适配层）
3. 全量编译
4. 四项 ABI 校验必须全过（全量 CRC / msm_drm DIFF / struct module / kobject_uevent_env）
5. 出 AnyKernel3 包
6. 确认回滚镜像在 PC 上 → 刷入 → 验证
7. 记录到 CHANGELOG
```

**必须做好回滚准备**：当前可用版 `pudding-cctv18-20261008.zip`
（md5 `596cf12d745f0651450ca5623db2f9d2`），回滚镜像 `stock-boot.img`
（md5 `5157f9020b45b51ec1701c79cda9b93d`）。

---

## 7. 待验证事项（UNVERIFIED）

| 项 | 状态 |
|---|---|
| 合 6.12.111 后厂商适配层是否冲突 | `UNVERIFIED` — 需实际尝试 |
| 合 stable 后导出符号 CRC 是否变化 | `UNVERIFIED` — 需实测比对 |
| Jianke 的 87 MB 镜像为何近 2 倍体积 | `UNVERIFIED` — 推测未剥离调试信息 |
| Jianke 具体合了哪些补丁 | `UNKNOWN` — 无公开源码 |
| 6.12.111 相对 69 的变更是否触及 ABI | `UNVERIFIED` — 需逐条审查 |

---

## 8. 本次调研新增的上游源码事实

| 文件 | v6.12.69 | v6.12.111 | 是否相同 |
|---|---|---|---|
| `kernel/module/internal.h` | 12163 字节 | 12163 字节 | ✅ 逐字相同 |
| `kernel/module/version.c` | 2449 字节 | 2449 字节 | ✅ 逐字相同 |

来源：`https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/...?h=v6.12.xxx`

**`same_magic()` 在 6.12 全系列未变** → 跨 SUBLEVEL 加载模块的机制稳定。

---

*调研时间：2026-10-08。数据来源：kernel.org / GitHub API / 设备实测。*