# 卡第一屏完整分析（三次失败）

> 本文是 2026-10-08 排查过程的完整记录，含**三个后来被推翻的判断**。
> 保留这些错误的推理过程，是为了下次不再犯。

---

## 一、症状时间线

```
V1   boot_index 354   2026-10-07 21:46   卡第一屏，静默，不自动重启
V2   boot_index 356   2026-10-08 凌晨   同上（V2 加了 panic 化，未触发）
修复版 boot_index 361/362 2026-10-08 16:48  卡屏 → 下缘闪一下 → PSHOLD 复位循环
成功版 boot_index 365  2026-10-08 19:02  ✅ 开机
```

**共同点**：XBL splash 一直在，从未交接给内核显示栈。

---

## 二、最终根因

**选了错误的源码树。** 细节见 [`../docs/WHY-CCTV18.md`](../docs/WHY-CCTV18.md)。

```
aosp-mirror/kernel_common（纯 AOSP，无厂商适配层）  →  ✗ 三次全败
cctv18/android_gki_kernel_common（有厂商适配层）    →  ✅ 一次通过
```

---

## 三、排查过程中确认的事实

### 3.1 `struct module` 尺寸是关键指标

```
能开机内核 (Jianke) : 1600 字节 / 75 成员
V1 / V2（带 ftrace）: 1664 字节 / 77 成员   ← 多 num_ftrace_callsites、ftrace_callsites
```

溯源链（实测确认）：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER                    (kernel/trace/Kconfig)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 多 2 个字段                 (include/linux/module.h)
  → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开
  → gendwarfksyms 递归推出不同 CRC
  → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏
```

**注意**：只关 `FUNCTION_TRACER` 无效 —— 会被 `STACK_TRACER` 用 `select` 拉回来。
必须先关 `STACK_TRACER`，再跑**两轮** `olddefconfig`。

### 3.2 `KBUILD_GENDWARFKSYMS_STABLE=1` 不能缺

GKI 官方构建入口 `_setup_env.sh` 里有：

```bash
export KBUILD_GENDWARFKSYMS_STABLE=1
```

`scripts/Makefile.build` 把它转成 `gendwarfksyms --stable`。
缺它 → 走 unstable 路径 → CRC 全错（`msm_drm` DIFF 高达 471）。

### 3.3 ABI 对齐是必要非充分条件

**修复版**（AOSP 树 + 全部 ABI 修复）：

```
Module.symvers vs abi.stg : 100% 对齐
msm_drm.ko DIFF           : 0
struct module             : 1600 / 75
kobject_uevent_env        : 0x8bb6d45c
                                ↓
                          仍然卡屏
```

→ **用错的树对齐出来的 ABI，对齐得再准也不充分。**

---

## 四、三个被推翻的判断（方法论教训）

### 4.1 「内核至少存活 2.1 秒」→ 推翻

**当时推理**：`mtdoops` 在 oops 分区留下记录 → 说明内核跑到了能写 flash 的阶段。

**推翻**：实测 `mtdoops` 是**每轮内核在正常关机时写自己的日志**。
卡死轮没有关机路径，永远不落盘。那条记录实属**健康轮次**（boot_index 353）。

### 4.2 「有看门狗在工作」→ 修正为 PSHOLD 硬复位

**当时推理**：修复版会自动重启循环 → 看门狗在起作用。

**修正**：blackbox 实测显示

```
B - 825543 - PM: Reset by PSHOLD
B - 828837 - PM: Reset Type: ...
```

且 dmesg 里有 `Hard watchdog permanently disabled`。
是 **PSHOLD（PMIC/电源路径）硬复位**，不是看门狗。

### 4.3 「拿到内核日志了」→ 其实是别的轮次

**当时**：在 blackbox 的 361 段看到正常的 init 日志。

**修正**：那是**刷机前 Jianke 轮**的日志，被本轮启动时 bootmonitor 归档进来。

**判据**（关键方法）：整段里 `Ma6302` 零匹配、`6.12.93` 零匹配。

> **教训**：解析取证分区时，**必须用版本串/署名做归属判定**，
> 不能看到「有日志」就认为「是我们的内核写的」。

---

## 五、取证证据链（最终版本）

| 项 | 结果 | 判据 |
|---|---|---|
| ALB 成功加载我们的 boot 镜像 | ✅ | blackbox: `Loading Image boot_a Done` |
| 我们的内核是否留下日志 | ❌ | blackbox 与 oops 分区中 `Ma6302` 零匹配 |
| 复位原因 | PSHOLD | blackbox: `PM: Reset by PSHOLD` |
| ARB 是否变化 | **未变** | `the stored_rollback_index is: 1`，多轮一致 |
| 双 KSU 是否冲突 | 无证据 | `ksud 4.2.0` 单实例，context `u:r:ksu:s0` |

### ARB 那一条要特别说明

排查中曾看到一条 `avb_slot_verify` 报错（`rollback index is less than the stored rollback index`），
一度以为是真凶。核实后：

```
boot_index=179   ← 很早期轮次（2026-10-06 之前）的历史记录
error_num=29
```

**该错误在整个 blackbox 中只出现一次，且属历史轮次。**
361/362/364 段的 `stored_rollback_index` 始终为 1，**没有变化**。

---

## 六、为什么「静默」—— 无日志的机制链

```
CONFIG_PANIC_ON_OOPS=y            → 无 panic 即无 oops
BOOTPARAM_SOFTLOCKUP_PANIC 未设   → softlockup 不 panic
BOOTPARAM_HUNG_TASK_PANIC 未设    → hung task 不 panic
/proc/sys/kernel/sysrq = 0        → 被 init 关闭
CONFIG_PSTORE_BLK=n               → 无 pstore-blk
ramoops record_size=0             → ramoops 未启用
        ↓
等锁型挂起 → 零证据落盘
```

所以「静默」不是内核没跑，而是**所有落盘通道都是关的**。

---

## 七、结论

| 层 | 判定 |
|---|---|
| AK3 打包链 | **无辜**（SELFTEST-A：Jianke 内核 + 我们外壳 → 能开机） |
| 内核本体 | **有罪**（SELFTEST-B：我们内核 + Jianke 外壳 → 不开机） |
| 具体原因 | 源码树血统错误（缺厂商适配层） |

**验证**：换 cctv18 树后一次通过，boot_index 365，全部子系统正常。

---

*记录时间：2026-10-08。所有数据经命令实测。*