# 变更记录

> 每次改动都必须有实测证据。未上机验证的改动标 `[未验证]`。

---

## 2026-10-09 — zstd 1.5.7 + lz4 1.10.0 算法层升级 + mi_sched 路径 A

**状态**：已上机验证 ✅（两次刷入，boot_index 367 与 372）

### 条目 A：算法层升级（boot_index 367）

| 项 | 值 |
|---|---|
| 上游 | `cctv18/android_gki_kernel_common` @ `android16-6.12-2026-03` |
| commit | `58ee67741556c83c523f48518284c4a6b1ef31d6` |
| 内核版本串 | `6.12.69-android16-6-4k-Ma6302` |
| 产物 | `pudding-cctv18-20261009-zstd-lz4.zip` (md5 `7fe863992d60ea88bc6f97c883285c91`) |
| Image md5 | `b90644df98b8f4ced9220eb347ff387d` |
| boot_index | **367** |

**改动内容**：

- zstd `1.5.2 → 1.5.7`，并从 OPPO 补丁二次适配 13 个被删 API（`zstd_default_clevel` / `zstd_get_cparams` / `zstd_custom_mem` 等）
- lz4 `→ 1.10.0`（含 ARM64 NEON 加速 `LZ4_arm64_decompress_safe`）
- 新增运行时 `compression_level` 模块参数

**ABI 校验**：`kobject_uevent_env` = `0x8bb6d45c`，`crypto_comp_compress/decompress` = `0x4995a32d`（未变），zram.ko 依赖 0 缺失。

### 条目 B：mi_sched 路径 A 移植（boot_index 372）

| 项 | 值 |
|---|---|
| 产物 | `pudding-cctv18-20261009-misched.zip` (md5 `a96113bc54a004bf25f0aaba8a59a874`) |
| Image md5 | `72549b282b413f63f9e43431e00cbcbb` |
| boot_index | **372** |

**改动内容**：

- 新增 `kernel/sched/mi_sched.c`（路径 A：框架对接层，**dormant 不启用**）
- 含 BTF 逆向出的全部小米类型定义 + `mqhd_ops` 占位 + mi_* 接口层 + `late_initcall`
- 接进 `kernel/sched/build_policy.c`（unity build）
- 合并 MK-Addon 模块（AK3 内 `ksud module install` 自动装）

**实测证据**：

```
uname -r      6.12.69-android16-6-4k-Ma6302
boot_index    372
boot_a md5    b0059b965ea1c285fde971afecaaa8f3
init_boot_a   f78cdace08393da6272c658f2e1cc66e   （未动，root 保持）
ksud          4.2.0-1-g904c60d1, context=u:r:ksu:s0
已加载模块    668（原厂 660）
sched_ext     state=disabled（符合路径 A 设计）
```

**mi_sched 符号全部就位**（10 个函数 + 6 个 `__ksymtab_*` 导出），
且 `__initcall__kmod_build_policy__1222_317_mi_sched_ext_init7` 存在于运行内核
→ late_initcall 已注册并执行、未崩溃。

**ABI 校验**：unknown symbol 0 / CRC 不符 0 / 签名失败 0 / 模块缺失 0。

**子系统**：显示 / 触控 / 音频 / 相机 / 传感器 / 蓝牙 / WiFi / 电池 / zram / swap 全正常。

详见 [`mi_sched-reverse.md`](mi_sched-reverse.md) 与 [`zram-wb-reverse.md`](zram-wb-reverse.md)。

---

## 2026-10-08 — 首次开机成功 🎉

**状态**：已上机验证 ✅

| 项 | 值 |
|---|---|
| 上游 | `cctv18/android_gki_kernel_common` @ `android16-6.12-2026-03` |
| commit | `58ee67741556c83c523f48518284c4a6b1ef31d6` |
| 内核版本串 | `6.12.69-android16-6-4k-Ma6302` |
| 产物 | `pudding-cctv18-20261008.zip` (md5 `596cf12d745f0651450ca5623db2f9d2`) |
| Image md5 | `146b1bb4810b89383a47e05541ddf24e` |
| boot_index | **365** |

**实测证据**：

```
uname -r      6.12.69-android16-6-4k-Ma6302
boot_index    365
boot_a md5    1d3e64eb3ae73d714bbc3481566e1ed8
init_boot_a   f78cdace08393da6272c658f2e1cc66e   （未动，root 保持）
ksud          4.2.0-1-g904c60d1, context=u:r:ksu:s0
已加载模块    670（原厂 660）
dmesg ABI 错误 0
dmesg panic/oops 0
```

**子系统验证**：

| 子系统 | 证据 |
|---|---|
| 显示 | `msm_drm` 已加载，`/dev/dri/card0` + `renderD128` |
| WiFi | `wlan0`，驱动 `cnss_pci`，`cnss2`/`qca_cld3_peach_v2` 已加载 |
| 蓝牙 | `btpower`、`cnss_utils` |
| 信号 | 基带 `MPSS.DE.9.0`，SIM LOADED，NR_SA |
| 音频 | 声卡 `canoe-mtp-snd-card` |
| 相机 | `/dev/video0` `/dev/video1` `/dev/video32` `/dev/video33` |
| 电池 | status 3 / health 2 / present |
| ZRAM | zram0 16GB，`lzo-rle` |
| 温度 | 51.7 °C（4 分钟后） |

**ABI 校验（四重全过）**：

```
① Module.symvers vs abi.stg : 10235/10235 MATCH, DIFF 0, MISSING 0 (100.0000%)
② msm_drm.ko (851 符号)     : MATCH 701, DIFF 0, MISSING 150（其他 vendor 模块）
③ struct module             : 1600 字节 / 75 成员
④ kobject_uevent_env        : 0x8bb6d45c
```

**配置要点**：

- 用树自带 `gki_defconfig`，**零 fragment**
- `CONFIG_LOCALVERSION="-android16-6-4k-Ma6302"`，`LOCALVERSION_AUTO=n`
- `GKI_HACKS_TO_FIX=y`、`GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024`
- `FUNCTION_TRACER` / `STACK_TRACER` 均为 n
- `KBUILD_GENDWARFKSYMS_STABLE=1`（来自 `_setup_env.sh`）
- 未内置 KernelSU

**构建**：6 分 19 秒，error count 0。

---

## 2026-10-08 — 失败三连（历史记录，勿重复）

| 版本 | boot_index | 源码树 | 结果 |
|---|---|---|---|
| V1 | 354 | AOSP 上游 6.12.93 | ✗ 卡第一屏，静默 |
| V2 | 356 | AOSP 上游 6.12.93（+ panic 化） | ✗ 卡第一屏，静默 |
| 修复版 | 361/362 | AOSP 上游 6.12.93（ABI 已对齐） | ✗ 卡屏 → 闪 → PSHOLD 复位循环 |

**根因**：源码树血统错误。详见 [`WHY-CCTV18.md`](WHY-CCTV18.md) 与 [`FAILURE-LOG.md`](FAILURE-LOG.md)。

---

## 模板（新增条目用）

```markdown
## YYYY-MM-DD — <一句话描述>

**状态**：已上机验证 ✅ / [未验证]

| 项 | 值 |
|---|---|
| 上游 | <repo> @ <branch> |
| commit | `<sha>` |
| 内核版本串 | `...` |
| 产物 | `<zip 名>` (md5 `...`) |
| boot_index | **N** |

**实测证据**：
（命令 + 关键输出行）

**改动内容**：
（相对上一版改了什么，为什么）

**ABI 校验**：
（四项结果）
```