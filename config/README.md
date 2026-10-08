# config/ — 配置增量片段

> **本目录当前为空（只有说明文件）。**
> 成功版刻意使用树自带的 `gki_defconfig`，零 fragment。

---

## 为什么现在是空的

三次失败中有一次就是因为自己加的 fragment：

```
diag-safe.fragment 里有 CONFIG_FUNCTION_TRACER=y / CONFIG_STACK_TRACER=y
     ↓
struct module 从 1600/75 变 1664/77
     ↓
msm_drm.ko 拒载
     ↓
卡第一屏
```

而那个 fragment 的注释还写着「不修改任何既有符号 CRC」—— 与事实完全相反。

所以第一版的目标是**只复现基线，不引入任何变量**。

---

## 加 fragment 的规矩

### 一次只加一项

```
zram.fragment          ← 只放 zram
scheduler.fragment     ← 只放调度
f2fs.fragment          ← 只放 F2FS
```

否则出问题无法定位是哪一项导致的。

### 必须遵守的红线

**任何 fragment 都不能出现这些**：

```ini
✗ CONFIG_FUNCTION_TRACER=y
✗ CONFIG_FUNCTION_GRAPH_TRACER=y
✗ CONFIG_STACK_TRACER=y
✗ CONFIG_FTRACE_MCOUNT_RECORD=y
✗ CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=<改值>
✗ CONFIG_CFI_CLANG=<改值>
✗ CONFIG_SHADOW_CALL_STACK=<改值>
✗ CONFIG_MODULE_SIG_FORCE=y
```

原因见 [`../docs/FAILURE-LOG.md` 坑 2](../docs/FAILURE-LOG.md)。

`scripts/build.sh` 会在编译前自动检查这几项，命中就**中止编译**。

---

## 写法模板

```ini
# config/zram.fragment
# SPDX-License-Identifier: MIT
# ------------------------------------------------------------
# 目标    : 提升 zram 压缩比
# 依据    : 原厂 defconfig 已含 ZRAM_BACKEND_ZSTD=y / ZRAM_MULTI_COMP=y
# 前置条件: 必须先有可开机的基线（本仓 pudding-cctv18-20261008）
# 回滚    : 删除本文件即可恢复默认
# ------------------------------------------------------------

CONFIG_ZRAM_DEF_COMP_ZSTD=y
# CONFIG_ZRAM_DEF_COMP_LZORLE is not set
CONFIG_ZRAM_MULTI_COMP=y
```

`scripts/build.sh` 会自动合并本目录下所有含 `CONFIG_` 行的 `*.fragment`。

---

## 加完必须做

1. 单独编译
2. `./scripts/verify-abi.sh` —— **四项必须全过**
3. 记录到 [`../docs/CHANGELOG.md`](../docs/CHANGELOG.md)
4. 刷机验证，确认没问题后再加下一项

---

## 候选方向（尚未实施）

| 项 | 说明 | 风险 |
|---|---|---|
| ZRAM 算法 | `lzo-rle` → `zstd`（压缩比更高，CPU 略升） | 低 |
| ZRAM 多算法分层 | `ZRAM_MULTI_COMP` + 冷页重压 | 低 |
| F2FS 压缩 | 内核侧 `F2FS_FS_LZ4/ZSTD` 已具备，需 fs 侧启用 | 低 |
| 调度参数 | `SCHED_CLASS_EXT` / `RT_SOFTIRQ_AWARE_SCHED` 已在树中 | 中 |
| 内存管理 | MGLRU 参数（`LRU_GEN=y` 已在） | 中 |

**建议**：先跑一两天稳定性与功耗基线，确认当前版本本身无问题，再叠上游改。这样每次只有一个变量。