# 分析 07 — 原厂 boot 取证与「可移植性」结论

> 数据来源：设备实测（`/proc/config.gz`、`/vendor/lib/modules/*.ko`、镜像字节分析）。
> 取证时间：2026-10-09。设备状态：原厂内核 `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`，`boot_index=366`。

---

## 0. 一句话结论

```
原厂 boot 里【没有】可移植的内存驱动 —— zram / QPaCE / xswapd / mctrl / zgroup
全部在 vendor 模块（zram.ko），不在 boot 分区。

想移植的 7 个小米定制 CONFIG，cctv18 树里【连源码都没有】（闭源）：
  MI_SCHED_EXT / MI_SCX_PERFETTO_TRACK / XIAOMI_ALLOC_STACK_PAGE
  XIAOMI_VMAP_ALLOC_PAGE / XIAOMI_ENHANCED_IOSTAT / XIAOMI_EROFS_IOSTAT

→ 「移植原厂特性到自编内核」这条路走不通（源码不存在）
→ 唯一可行的改动是【算法层】（这一层我们和原厂本来就一致）
```

---

## 1. 原厂 boot 的真实结构

```
文件             /sdcard/Download/pudding-kernel/stock-boot.img
md5              5157f9020b45b51ec1701c79cda9b93d  （= 当前 boot_a 实测值）
分区大小         100,663,296 字节 (96.0 MB)
header 版本      0（老格式，非 v2+）

  kernel 段      41,576,960 字节 (39.65 MB)
  ramdisk        0                       ← 无
  second         0                       ← 无
  尾部           59,082,240 字节填充
  kernel 之后     AVB0 结构（5396 非零字节，Android Verified Boot）
```

**boot 里只有内核，没有 ramdisk / dtb / 其他可搬段。**

---

## 2. 原厂内核内容（逐项实测）

```
zram 驱动符号          0 处     ← zram_add / writeback_store / disksize_store 全无
QPaCE                  0 处
xswapd                 0 处
zgroup                 0 处
mctrl                  53 处    ← 但全是 UART 的 pl011_get_mctrl / serial8250_do_get_mctrl
backing_dev            3 处     ← 全是 noop_backing_dev_info / backing_dev_info（通用块层）
zsmalloc               1 处     ← 仅字符串引用

算法层（在！）：
  crypto_comp_compress   3
  zstd_compress         13
  zstd_scomp             1
  lz4_scomp              1
  ZSTD 版本              1.5.2
  LZ4 符号数             36
```

---

## 3. 原厂 vs 自编内核（逐项对比）

| 项目 | 原厂 | 自编 | 判定 |
|---|---|---|---|
| `zstd` 字符串 | 156 | 149 | 都有 |
| `zstd_compress` | 13 | **13** | **相同** |
| `zstd_scomp` | 1 | **1** | **相同** |
| `lz4` / `lz4_scomp` | 74 / 1 | **74 / 1** | **相同** |
| LZ4 符号数 | 36 | **36** | **相同** |
| `lzo` | 93 | **93** | **相同** |
| **zstd 版本** | **1.5.2** | **1.5.2** | **相同** |
| `crypto_comp_compress` | 3 | 2 | 差 1 |
| `sched_ext` / `scx_` | 76 / 253 | 45 / 215 | 有差 |
| **`mi_sched`** | **3** | **0** | ★ **仅原厂** |
| `zram` 驱动符号 | 0 | 0 | 都无（在模块里） |
| `qpace` | 0 | 0 | 都无（在模块里） |

**我们自编内核的算法层与原厂几乎逐一对应。真正差的只有 `mi_sched`（小米调度扩展）。**

---

## 4. 三层架构（关键认知）

实测确认的分层：

```
┌─ 第 1 层：内核 boot 分区 ──────────────────────────────┐
│  算法层   zstd 1.5.2 / lz4 / lzo / deflate            │
│  文件系统 f2fs / erofs                                 │
│  sched_ext (SCHED_CLASS_EXT=y)                         │
│  ★ 我们和原厂一致，可改                                  │
│  ★ 小米定制 (mi_sched 等 7 项)：cctv18 树无源码，闭源     │
└────────────────────────────────────────────────────────┘
┌─ 第 2 层：vendor 模块（zram.ko）───────────────────────┐
│  QPaCE     qpace_zram_submit_bio / qpace_queue_compress │
│  xswapd    watermark/reclaim_size/wake_interval/...     │
│  mctrl     score/level/comp_ratio/wb_ratio/...          │
│  zgroup    zgroup_alloc / zgroup_wb.c（回写）            │
│  ★ 我们从不修改（AK3 do.modules=0）                      │
│  ★ 自编内核开机后照常加载（670 模块）                     │
└────────────────────────────────────────────────────────┘
┌─ 第 3 层：小米专属模块 ────────────────────────────────┐
│  mi_reclaim.ko       "Memory reclaim optimization"     │
│  mi_low_lat_mem.ko   memcg v1/v2 低延迟内存             │
│  mi_memory_monitor / mi_extent_pool / os_cpu_qi        │
│  ★ 同样不修改，照常加载                                  │
└────────────────────────────────────────────────────────┘
```

### zram.ko 里的源码路径（血统证据）

```
../soc-repo/drivers/block/zram/zram_drv.c
../soc-repo/drivers/block/zram/zgroup.c
../soc-repo/drivers/block/zram/zgroup_wb.c     ← 回写实现
mm/xswapd:online
xswapd: xswapd init success
```

模块信息：

```
name=zram   depends=zsmalloc   license=Dual BSD/GPL   built_with=DDK
vermagic=6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64
parm: num_devices
parm: qpace_pool_size:fs_bio_set pool size used by QPaCE
```

---

## 5. 「内存回写」到底是什么（实测澄清）

用户所说的「内存回写」= **`xswapd`**，它在 `zram.ko` 里。

```
/dev/memcg/ 下的活跃接口：
  memory.xswapd.stat / swapout / swapin / reclaim
  memory.xswapd.shrink_interval / umrenable / watermark ...

实测运行数据：
  压缩比      2.58x
  pswpin      598,669
  pswpout     2,228,622
  swap 已用   3.5G / 16G
  swappiness  100
```

**它不是这些**（逐项排除）：

| 可能 | 实测 | 结论 |
|---|---|---|
| zram writeback | `backing_dev` 不存在 | ✗ |
| swapfile | `/data` 下无 swap 文件 | ✗ |
| zswap | `CONFIG_ZSWAP is not set` | ✗ |
| **xswapd** | `/dev/memcg/memory.xswapd.*` 活跃 | ✅ |

---

## 6. 关于「用 QPaCE 作压缩算法」

**QPaCE 不是 `comp_algorithm` 的选项。** 实测：

```
当前可选算法： lzo [lzo-rle] lz4 zstd
              （QPaCE 不在列表里）

QPaCE 的真实形态（在 zram.ko 里）：
  qpace_zram_submit_bio            ← bio 提交路径
  qpace_queue_compress_wrapper     ← 队列封装
  qpace_pool_size (module_param)   ← fs_bio_set 池大小
  get_qpace / put_qpace            ← 引用计数
  Nubia 反编译源码显示：
    init_module → _platform_driver_register(qpace_driver)
                → pm_stay_awake / dev_pm_qos_update_request(300)
                → ring buffer (tr_rings / ev_rings)
```

**QPaCE = 硬件加速通道 + 电源管理 + ring buffer 队列，不是压缩算法。**
算法（zstd/lz4/lzo）跑在它之上，通过 `crypto_comp_compress` 调用。

**当前状态：QPaCE 已经在用了**（vendor zram.ko 原封不动，自编内核照常加载）。

---

## 7. 可移植性分类（回答「能不能移植」）

### 类别 A：在 vendor 模块里 → **不需要移植，本来就在用**

| 特性 | 位置 | 自编内核是否能加载 |
|---|---|---|
| QPaCE | zram.ko | ✅ vermagic 匹配，实测 670 模块加载 |
| xswapd | zram.ko | ✅ |
| mctrl / zgroup | zram.ko | ✅ |
| mi_reclaim | mi_reclaim.ko | ✅ |
| mi_low_lat_mem | mi_low_lat_mem.ko | ✅ |

**验证依据**：AK3 包 `do.modules=0`、`.ko` 文件数 = 0 → vendor 模块不被覆盖。
`same_magic()` 跳过 LOCALVERSION 段 → `6.12.69-android16-6-4k` 模块可加载到 `6.12.69-android16-6-4k-Ma6302` 内核。

### 类别 B：在内核里但树里无源码 → **无法移植（闭源）**

```
CONFIG_MI_SCHED_EXT=y              Kconfig=0  whole-tree=0
CONFIG_MI_SCX_PERFETTO_TRACK=y     Kconfig=0  whole-tree=0
CONFIG_XIAOMI_ALLOC_STACK_PAGE=y   Kconfig=0  whole-tree=0
CONFIG_XIAOMI_VMAP_ALLOC_PAGE=y    Kconfig=0  whole-tree=0
CONFIG_XIAOMI_ENHANCED_IOSTAT=y    Kconfig=0  whole-tree=0
CONFIG_XIAOMI_EROFS_IOSTAT=y       Kconfig=0  whole-tree=0
```

原厂内核里的相关符号（cctv18 树完全找不到）：

```
mi_sched_ext_ops
mi_sched_ext_register_krn_ops
mi_scx_core_ctl_policy / mi_set_scx_core_ctl_policy
mi_get_scx_cpu_masks / mi_set_scx_cpu_masks
mi_scx_task_struct / mi_scx_cpu_masks_type
blk_alloc_queue_xiaomi_extra_limit
xiaomi_exlim_sfi / xiaomi_fastdiscard_info / xiaomi_feature_info
```

### 类别 C：算法层 → **可改（唯一可行目标）**

```
当前（我们与原厂相同）：zstd 1.5.2 / lz4(32-bit) / lzo-rle
可升级：              zstd 1.5.7 / lz4 1.10.0
补丁来源：            cctv18/oppo_oplus_realme_sm8850 → zram_patch/
补丁基座可行性：      实测 002-zstd.patch 56/57 一致、001-lz4.patch 9/11 一致
```

---

## 8. 建议方案

### 方案（推荐）：只升算法层，保留 vendor 全栈

```
1. 保持 AK3 do.modules=0        → QPaCE / xswapd / mctrl / zgroup 全保留
2. 打 cctv18 的 zstd 1.5.7 补丁  → 内核算法升级，vendor zram.ko 自动用新算法
3. 打 lz4 1.10.0 补丁            → 可选
4. 刷入验证
```

**原理**：`zram.ko` 通过 `crypto_comp_compress` 调用内核算法 →
**改内核里的 lib/zstd，vendor 模块就跟着用新的**（不需要碰模块）。

**注意**：`002-zstd.patch` 会把默认等级 3 → 1（更快，压缩比略降），
且新增 `compression_level` 运行时参数（`module_param`，0644）。

### 不推荐的方案

```
✗ 把 zram 改为内置（=y）→ 丢失 QPaCE / xswapd / mctrl / zgroup
✗ 移植 mi_sched 等 → 源码不存在，无法实现
✗ 移植 QPaCE → 已在模块里工作，无需移植
```

---

## 9. 待验证事项（UNVERIFIED）

| 项 | 状态 |
|---|---|
| cctv18 的 zstd 补丁打到我们树上后能否正常编译 | `UNVERIFIED` |
| zstd 1.5.7 是否与 vendor zram.ko 的 `crypto_comp_*` 调用完全兼容 | `UNVERIFIED` |
| 升级 zstd 后实际压缩比变化 | `UNVERIFIED` — 需实机测量 |
| `mi_sched` 缺失是否造成可感知差异 | `UNVERIFIED` |
| 能否从原厂内核提取 `mi_sched` 二进制patch | `UNKNOWN` — 闭源 |

---

## 10. 数据来源

```
设备实测：
  /proc/config.gz                          md5 072f971054a9c271c72ec081aa5f3fc8
  /vendor/lib/modules/zram.ko              282,432 字节
  /sys/block/zram0/*                       （算法列表、mm_stat）
  /dev/memcg/memory.xswapd.*
  /proc/swaps, /proc/vmstat

镜像字节分析：
  stock-boot.img kernel 段                41,576,960 字节
  kcmp/Image（自编）                      41,896,448 字节
  strings 符号对比：原厂 247,623 / 自编 250,955 唯一串

PC 源码树检查（WSL）：
  /root/pudding-kernel/kernel-61269        cctv18 @ 58ee67741
  grep 全树：MI_SCHED_EXT / qpace / xswapd / zgroup 均无
```

---

*取证时间：2026-10-09。所有数值来自命令实测，非推测。*
