# 目录 → 许可证对照

本仓采用**按目录区分许可证**的做法。根 `LICENSE` 是 GPL-2.0-only，作为整棵树的默认。

| 路径 | 许可证 | 说明 |
|---|---|---|
| `scripts/` | **MIT** | 独立原创的构建脚本，不是内核的演绎作品 |
| `config/` | **MIT** | 独立原创的配置增量片段 |
| `docs/` | **CC-BY-4.0** | 文档 |
| `versions.lock` | **MIT** | 数据文件 |
| 其余部分 | **GPL-2.0-only** | 默认；若有补丁类内容适用 |

## 为什么这么分

补丁是对 GPL-2.0 内核源码的**演绎作品**（diff 里的上下文行本身就是 GPL-2.0 代码），
所以补丁跑不掉 GPL。

但 **shell / CI 脚本与 config fragment 是独立原创作品**，不是内核的演绎，可以另用许可证。
先例：Yocto recipe style guide 要求「recipes、配置文件与脚本的许可证也应被清楚标明」；
OE-Core 同时收录 GPL-2.0-only 与 MIT 两份文本，并用 LICENSE 文件解释归属。

做法是**三件一起**才成立：

1. 仓库根 `LICENSE` = GPL-2.0-only（整树默认）✓
2. 本文件（目录 → 许可证对照表）✓
3. 能写注释的文件加 SPDX 行 ✓（见各 `scripts/*` 头部 `# SPDX-License-Identifier: MIT`）

> **`Signed-off-by` 是认证（DCO），不是再分发许可证。**
> 收入别人的补丁时，**原样保留原作者的所有 `Signed-off-by` 与 `Change-Id`**，
> 自己经手时再加一条自己的 sign-off。

## 上游许可证事实（已核查）

`cctv18/android_gki_kernel_common` 的 `COPYING` 内容（实测解码）：

```
The Linux Kernel is provided under:

	SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note

Being under the terms of the GNU General Public License version 2 only,
according with:

	LICENSES/preferred/GPL-2.0

With an explicit syscall exception, as stated at:

	LICENSES/exceptions/Linux-syscall-note

In addition, other licenses may also apply. Please see:

	Documentation/process/license-rules.rst

for more details.

All contributions to the Linux Kernel are subject to this COPYING file.
```

→ **GPL-2.0-only**。本仓取同一许可证。

## 如果将来要收第三方补丁：先查许可证（地雷）

| 来源 | 事实 |
|---|---|
| `tiann/KernelSU` | GitHub 识别为 **GPL-3.0**。README 原文：**只有 `kernel/` 是 GPL-2.0-only**，其余 GPL-3.0-or-later → **只有 `kernel/` 可搬** |
| `simonpunk/susfs4ksu` | `LICENSE` 是 **GPLv3 全文**，无 "only"/"or later" 限定词 → 意图 **UNVERIFIED**，先查清再搬 |

kernel.org 的 `license-rules` 列出与 GPL-2.0 兼容的许可证集是
**GPL-1.0+、GPL-2.0+、LGPL-2.0、LGPL-2.0+、LGPL-2.1、LGPL-2.1+** —— **GPL-3.0 不在其中**。

> 把 GPLv3-only 的补丁贴进 GPL-2.0-only 的内核源码，是真实的许可证冲突。
> **动手前逐个查补丁文件自己的头部注释和所在子目录**，不要相信仓库首页的 license 徽章。