# 设备真实模块的 ABI 要求（msm_drm.ko）

> 本文记录从设备实读模块中提取的符号 CRC 要求，作为 ABI 校验的**外部硬基准**。
> 原始数据：`msm_drm_req.txt`（851 条）、`msm_drm_crc.txt`。

---

## 一、为什么用设备真实模块

`gki/aarch64/abi.stg` 是**上游声明的** ABI 表面。
`msm_drm.ko` 是**设备上真的要加载的**模块 —— 它记录的 CRC 才是最终判据。

两者交叉验证，任何一方单独看都不够。

---

## 二、模块元数据（实测）

```
路径       /vendor_dlkm/lib/modules/msm_drm.ko
大小       6,855,496 字节
vermagic   6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
符号数     851（取自 ELF __versions 段）
```

`__versions` 段解析方式：

```c
struct modversion_info {
    unsigned long crc;              /* 8 bytes */
    char name[MODULE_NAME_LEN];     /* 56 bytes */
};                                  /* 记录 = 64 bytes */
```

---

## 三、校验结果（对成功的 6.12.69 内核）

```
msm_drm.ko 要求符号 : 851
MATCH               : 701
DIFF                : 0        ← 关键判据
MISSING             : 150
```

### MISSING 的 150 个是什么

逐个验证，**全部由其他 vendor 模块导出**，不在 GKI ABI 表面内：

| 符号 | 由谁导出 |
|---|---|
| `hdcp1_init` `hdcp1_deinit` `hdcp1_start` `hdcp1_stop` … | `hdcp_qseecom_dlkm.ko` |
| `altmode_register_client` `altmode_deregister_notifier` … | `altmode-glink.ko` |
| `drm_dp_dpcd_read` `drm_dp_dpcd_write` | `drm_display_helper.ko` |
| `ipc_log_string` | `altmode-glink.ko` / `bam_dma.ko` / … |
| `gh_rm_mem_lend` `gh_irq_lend_v2` `gh_msgq_send` … | gunyah 相关模块 |

**所以正确判据是 `DIFF == 0`，不是「对齐率 100%」。**

---

## 四、关键符号单点对照

| 符号 | 设备模块要求 | 我们的内核 | 判定 |
|---|---|---|---|
| `kobject_uevent_env` | `0x8bb6d45c` | `0x8bb6d45c` | ✅ |
| `kobject_uevent` | `0x3f4f361e` | `0x3f4f361e` | ✅ |
| `kobject_set_name` | `0xbae57d6a` | `0xbae57d6a` | ✅ |
| `module_layout` | `0x797f2b3e` | `0x797f2b3e` | ✅ |
| `init_task` | `0x6951c290` | `0x6951c290` | ✅ |
| `_printk` | `0x16b5b21d` | `0x16b5b21d` | ✅ |
| `memcpy` | `0x8a7493b2` | `0x8a7493b2` | ✅ |
| `schedule` | `0xd272d446` | `0xd272d446` | ✅ |
| `kthread_create_on_node` | `0xe5fe03cf` | `0xe5fe03cf` | ✅ |
| `mutex_lock` | `0x995658e3` | `0x995658e3` | ✅ |
| `__pm_runtime_resume` | `0x83525673` | `0x83525673` | ✅ |
| `regulator_get` | `0x28a9691d` | `0x28a9691d` | ✅ |
| `iommu_map` | `0x13ae6a78` | `0x13ae6a78` | ✅ |

---

## 五、失败版本的对照（历史）

| 版本 | 源码树 | msm_drm DIFF | 结果 |
|---|---|---|---|
| V1 | AOSP 上游 6.12.93 | **471** | ✗ 卡第一屏 |
| V2 | AOSP 上游 6.12.93 | **471** | ✗ 卡第一屏 |
| 修复版 | AOSP 上游 6.12.93 | 0 | ✗ 卡屏循环 |
| **成功版** | **cctv18 6.12.69** | **0** | ✅ 开机 |

**注意第 3 行**：ABI 已对齐（DIFF=0）但仍失败 —— 证明 ABI 对齐是**必要非充分**条件。

---

## 六、如何自行复现

```bash
# 1) 从设备拉一个真实模块
adb pull /vendor_dlkm/lib/modules/msm_drm.ko

# 2) 用仓库脚本校验（纯 Python，手机端也能跑）
KO=msm_drm.ko ./scripts/verify-abi.sh

# 3) 只看模块视角
python3 - <<'EOF'
import sys
sys.path.insert(0, 'scripts')
from importlib import import_module
v = import_module('verify-abi'.replace('-', '_'))  # 或直接内联 parse_versions_section
EOF
```

或者用 `scripts/analysis/parse-module-versions.py`（本仓提供）：

```bash
python3 scripts/analysis/parse-module-versions.py msm_drm.ko > msm_drm_req.txt
wc -l msm_drm_req.txt      # 851
```

---

## 七、可再分发的说明

`msm_drm.ko` 是 **Qualcomm 专有二进制**，本仓**不包含**该文件。
本文仅记录从其中**提取的符号名与 CRC 数值**（属事实数据），并给出复现方法。

---

*记录时间：2026-10-08。所有数值经命令实测。*