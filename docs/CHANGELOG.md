# 变更记录

> 每次改动都必须有实测证据。未上机验证的改动标 `[未验证]`。

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