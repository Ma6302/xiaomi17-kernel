# 升级与维护

> 本仓的核心价值就是**让升级可复现**。本文说明怎么跟随上游、怎么加调优、怎么防止回归。

---

## 三种升级场景

| 场景 | 触发 | 风险 | 做法 |
|---|---|---|---|
| A. 跟随上游 patchlevel | cctv18 推新分支/commit | 中 | 改 `versions.lock` 的 SHA，全套重验 |
| B. 加内核调优 | 想改 zram / 调度 / F2FS | 低~中 | 加 `config/*.fragment`，**一次只加一项** |
| C. 加第三方补丁（KernelSU/SUSFS 等） | 想内置 root 方案 | 高 | 见下文「补丁的许可证边界」 |

---

## A. 跟随上游

### 步骤

```bash
# 1. 看上游有什么新的
git ls-remote --heads https://github.com/cctv18/android_gki_kernel_common

# 2. 挑目标分支，取 SHA
git ls-remote https://github.com/cctv18/android_gki_kernel_common \
    refs/heads/android16-6.12-<新分支>

# 3. 改 versions.lock 的 [upstream] 三个字段：
#      branch / commit / commit_msg
#    [tree] sublevel 也要同步更新

# 4. 重新走一遍完整流程
./scripts/fetch-sources.sh   # 会断言 SHA
./scripts/build.sh
./scripts/verify-abi.sh      # ★ 必须四项全过
```

### 选择分支的判据（顺序不能反）

```
1. 先读实机 uname -r 与 KMI 世代
2. 再选分支
```

**不要**从 Android 版本推 Linux 版本。本机实例：

```
OS          = Android 17
KMI 名      = android16-6-4k        ← 不是 android17！
uname -r    = 6.12.69-...
→ 应选分支 = android16-6.12-2026-03 （SUBLEVEL 69）
```

AOSP 的 `android17-6.18` 分支与本机**无关**。Android 版本与 Linux 版本可以不同步。

### 版本号对齐原则

优先选 **SUBLEVEL 与设备原厂一致**的分支：

```
设备原厂      6.12.69
cctv18 分支   android16-6.12-2026-03 → 69  ✅ 选它
              android16-6.12-2025-06 → 23  （版本偏旧）
```

版本号不一致**不一定**失败，但会引入额外变量。首次复现基线时，**尽量只保留一个变量**。

---

## B. 加内核调优

### 原则：一次一项

```
config/
  zram.fragment        ← 只放 zram 相关
  scheduler.fragment   ← 只放调度相关
  f2fs.fragment        ← 只放 F2FS 相关
```

**不要**把所有调优塞进一个 fragment。否则出问题无法定位是哪一项导致的。

### 写法

fragment 用 `merge_config.sh` 合并，只写**增量**：

```ini
# config/zram.fragment
# SPDX-License-Identifier: MIT
# 目标：提升 zram 压缩比
# 前置：需确认 CONFIG_ZRAM_BACKEND_ZSTD=y 已具备（树自带）

CONFIG_ZRAM_DEF_COMP_ZSTD=y
# CONFIG_ZRAM_DEF_COMP_LZORLE is not set
CONFIG_ZRAM_MULTI_COMP=y
```

合并：

```bash
ARCH=arm64 scripts/kconfig/merge_config.sh -O "$OUT_DIR" -m \
    "$OUT_DIR/.config" config/zram.fragment
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
```

### 必须遵守的红线

**任何 fragment 都不能碰这些**（会破坏 ABI 或导致不开机）：

```ini
# ✗ 绝对禁止
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_STACK_TRACER=y
CONFIG_FTRACE_MCOUNT_RECORD=y
CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=<改动>
CONFIG_CFI_CLANG=  <改动>
CONFIG_SHADOW_CALL_STACK=  <改动>
CONFIG_MODULE_SIG_FORCE=y
```

原因见 [`FAILURE-LOG.md` 坑 2](FAILURE-LOG.md)。

### 每加一项都要

1. 单独编译
2. 跑 `verify-abi.sh`（四项必须全过）
3. 单独记录到 `docs/CHANGELOG.md`
4. 刷机验证，再测下一项

---

## C. 加第三方补丁（高风险）

### 许可证边界（这是地雷）

**不是所有「内核补丁」都能以 GPL-2.0 分发。**

| 来源 | 许可证事实 |
|---|---|
| `tiann/KernelSU` | GitHub 识别为 **GPL-3.0**。README 原文：**只有 `kernel/` 目录是 GPL-2.0-only**，其余是 GPL-3.0-or-later → **只有 `kernel/` 可以搬** |
| `simonpunk/susfs4ksu` | 托管在 GitLab。`LICENSE` 是 **GPLv3 全文**，没有 "only"/"or later" 限定词 → 意图 **UNVERIFIED**，必须先查清 |

kernel.org 的 `license-rules` 规定：内核整体是 GPL-2.0 **only**，许可证不同的文件「必须与 GPL-2.0 兼容」，而它列出的兼容集是 **GPL-1.0+、GPL-2.0+、LGPL-2.0、LGPL-2.0+、LGPL-2.1、LGPL-2.1+** —— **GPL-3.0 不在其中**。

> 把 GPLv3-only 的补丁贴进 GPL-2.0-only 的内核源码，是真实的、非外观性的许可证冲突。
> **动手前逐个查补丁文件自己的头部注释和所在子目录**，不要相信仓库首页的 license 徽章。

### 本仓现状

**本仓不含任何第三方补丁**，只用 cctv18 树自带的 `gki_defconfig`。
这是刻意的：先复现能开机的基线，再谈增量。

### 如果将来要加

补丁必须带完整的来源头（DEP-3 + AOSP 组合）：

```
Origin: backport, https://github.com/tiann/KernelSU/commit/<sha>
Upstream-Status: Backport
Signed-off-by: <原作者>
Change-Id: <原 Change-Id>
```

**原样保留原作者的所有 `Signed-off-by` 与 `Change-Id`**，自己经手时再加一条自己的 sign-off。

---

## 回归测试清单（每次升级后必做）

```bash
# 1. 编译无错
grep -c 'error:' build.log          # 期望 0

# 2. 版本串正确
strings Image | grep -m1 '6\.12\.69.*Ma6302'

# 3. ABI 四项全过（脚本会打印）
./scripts/verify-abi.sh

# 4. 刷机前：确认回滚镜像在 PC 上
# 5. 刷机后：跑 docs/FLASH-AND-ROLLBACK.md 的「刷后验证」
```

---

## 分支策略

```
main        ← 只放已验证可开机的版本
             每次成功刷机 + 验证通过后才合并
             受 ruleset 保护（需走 PR）

dev/*       ← 试验性改动
```

**提交信息约定**（便于回溯）：

```
[build] 升级上游到 <branch> @ <sha>            — 编译未验证
[flash] 实测开机成功 boot_index <N>            — 已上机验证
[cfg]   加 zram.fragment（zstd 默认算法）      — 单项配置改动
[docs]  ...                                    — 文档
[fix]   修正 <xxx>                             — 修复
```

**关键**：`[flash]` 类提交必须带**实测证据**（uname -r、boot_index、模块数），
不接受「应该能开机」这类表述。

---

## 版本记录

见 [`CHANGELOG.md`](CHANGELOG.md)。

---

## 何时该往回退

出现以下任意情况，**回退到上一个已知可用版本**，不要在现场调试：

| 现象 | 动作 |
|---|---|
| 刷入后卡第一屏 | 立即回滚，然后离线分析 |
| 开机后频繁重启 | 立即回滚 |
| 模块加载报 `disagrees about version` | 回滚，重跑 ABI 校验 |
| WiFi / 音频 / 相机 任一不可用 | 回滚，检查对应 CONFIG |

**永远保持一个可用的 previous 版本**（本仓即 `pudding-cctv18-20261008.zip`）。

---

*本文基于 2026-10-08 实测与经验。*