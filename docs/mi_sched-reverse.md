# 逆向：小米 mi_sched (MQHD) 完整结构与移植可行性

> 采集日期：2026-10-09
> 设备状态：Xiaomi 17 (pudding)，**运行原厂内核** `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`
> 方法：BTF 源码级提取（`/sys/kernel/btf/vmlinux`）+ 反汇编交叉验证
> 精度：**源码级**（BTF 是编译器生成的类型信息，等价于从源码读取）

---

## 0. 一句话结论

小米的 `mi_sched` = 一个名为 **MQHD** 的 sched_ext 调度器实现 + 内核侧接口层 + perfetto 跟踪层。
**小米没有修改 `task_struct`**（重大利好，GKI ABI 风险消除）。

---

## 1. 为什么能用 BTF 做「源码级」逆向

设备运行**原厂内核**时，`/sys/kernel/btf/vmlinux` 可直接读取。
BTF（BPF Type Format）是编译器为 BPF CO-RE 生成的**完整类型信息**，包含：

- 全部结构体/枚举/union 的字段名、偏移、大小
- 全部函数原型（FUNC 表）

因此这不是「反汇编猜结构」，而是**读编译器输出的类型信息**，等价于读源码。

```bash
bpftool btf dump file /sys/kernel/btf/vmlinux format c > stock_btf_c.txt   # 160479 行
pahole --btf_base /sys/kernel/btf/vmlinux                                  # 全量结构 dump
```

> ⚠️ 前提：必须运行**原厂**内核。自编译内核若未启用 `CONFIG_DEBUG_INFO_BTF` 或路径不可读则失效。

---

## 2. 完整枚举定义（源码级）

```c
enum mi_scx_cpu_masks_type { SCX_CPU_ISO_MASK=0, SCX_CPU_BACKUP_MASK=1, MAX_SCX_CPU_TYPE=2 };
enum scx_cpu_type  { CTYPE_LTT=0, CTYPE_BIG=1, CTYPE_PRI=2, CPU_TYPE_MAX=3 };
enum scx_disp_type { DTYPE_NORMAL_BIT=0, DTYPE_PERIOD_BIT=1 };
enum mi_sched_ext_ops { SCX_MQHD=0, MAX_SCX_OPS=1 };
enum mi_scx_core_ctl_policy { CORE_CTL_DISABLE=0, CORE_CTL_BKP_ISO=1, CORE_CTL_LTT_BIG=2, MAX_CORE_CTL_POLICY=3 };
enum bpf_dsq_idx { BPF_DSQ_PER_LEVEL0..2=0..2, BPF_DSQ_NOR_LEVEL0..4=3..7, BPF_DSQ_NR=8 };
enum bpf_dsq_timeout_state { NO_TIMEOUT=0, IN_TIMEOUT=1, CLR_TIMEOUT=2 };
enum normal_consume_state { CONSUME_NORMAL=0, CONSUME_BACKUP=1, CONSUME_EXHAUSTED=2, CONSUME_DECAY=3, CONSUME_TIMEOUT=4 };
```

**8 级 DSQ**（dispatch queue）是 MQHD 的核心：

| DSQ idx | 名称 | 用途 |
|---|---|---|
| 0-2 | `BPF_DSQ_PER_LEVEL0..2` | periodic（周期）队列，3 级 |
| 3-7 | `BPF_DSQ_NOR_LEVEL0..4` | normal（普通）队列，5 级 |

实测 `/sys/module/build_policy/parameters/scx_mqhd_stats` 显示 DSQ 3-7 配了非零 quota（16/32/32/16/8）——
**说明 MQHD 是真实激活的调度策略，不是死代码**。

---

## 3. 完整结构体定义（源码级）

```c
struct mi_scx_task_struct {   /* 独立结构，【不在】task_struct 内 */
    u64       task_prop;      /* 0 */
    cpumask_t cpus_mask;      /* 8 */
};  /* size: 16 */

struct scx_cpu_conf {
    enum scx_cpu_type ctype;      /* LTT/BIG/PRI */
    cpumask_var_t     static_mask;
    cpumask_var_t     dynamic_mask;
};  /* size: 24 */

struct scx_disp_conf {
    enum scx_disp_type dtype;  /* NORMAL/PERIOD */
    u8 start; u8 end;
};  /* size: 8 */

struct scx_disp_zone {          /* 小米核心概念 */
    struct scx_cpu_conf  cpu_conf;      /* 0, 24 */
    struct scx_disp_conf disp_conf;     /* 24, 8 */
    int      thresh_l;                  /* 32 */
    int      thresh_h;                  /* 36 */
    bool     busy;                      /* 40 */
    atomic_t all_exhausted;             /* 44 */
    int      reset_cpu;                 /* 48 */
};  /* size: 56 */
```

---

## 4. 函数清单（BTF FUNC 表 / kallsyms 提取）

### 4.1 MQHD 调度器本体（真正的调度器）
```
mqhd_init / exit / enqueue / dequeue / dispatch / select_cpu / tick
mqhd_update_runtime / cpu_online / cpu_offline / get_mqhd_stats
→ 对应 struct sched_ext_ops 的回调签名（424B / 39 回调，AOSP 标准）
```

### 4.2 接口层（10 个）
```
mi_sched_ext_register_krn_ops    mi_get_scx_cpu_masks
mi_set_scx_cpu_masks             mi_set_scx_masks_backup_thresh
mi_set_scx_core_ctl_policy       register_mi_scx_disp_zone
register_mi_get_scx_task_struct  register_mi_get_sched_cpu_usage
parse_scx_task_prop              do_disp_zone_consume
```

### 4.3 perfetto 跟踪层（5 个）
```
perfetto_show_scx_ops_state  perfetto_dsq_consume_state
perfetto_common_show_info    perfetto_normal_dsq_quota
perfetto_show_cpu_util_usage tracing_mark_write
```

### 4.4 android vendor hooks（小米在 ext.c 插入）
```
android_vh_scx_enabled / ops_enable_state / task_can_run_on / set_cpus_allowed
android_vh_scx_fix_prev_slice / ops_consider_migration / switch_repeat_skip
android_vh_scx_task_switch_finish / restore_flags / exit_on_abnormal
android_vh_switching_to_scx / task_should_scx
```

---

## 5. ABI 风险结论（关键）

```
原厂 task_struct : size 5184, members 234, struct sched_ext_entity scx @848 (+200)
AOSP 6.12 基线   : size 5184, members 234, 同上
→ 完全一致，小米【没有】修改 task_struct！
```

`mi_scx_task_struct`(16B) 独立存在，通过 getter 回调间接访问 → **不破坏 GKI ABI**。

**结论：移植 mi_sched 不会破坏 vendor 模块 ABI。**

---

## 6. 四方做法对照

| | Stock 原厂 | Jianke | Nanally | 我们（cctv18） |
|---|---|---|---|---|
| sched_ext 框架 (`CONFIG_SCHED_CLASS_EXT`) | ✓ | ✓ | ✓ | ✓ |
| `CONFIG_MI_SCHED_EXT` | ✓ | ✗ | (有符号) | ✗ |
| MQHD 调度器 | ✓ | ✗ | ✓ | ✗ |
| mi_* 接口层 | ✓ | ✗ | ✓ | ✗ |
| perfetto 跟踪 | ✓ | ✗ | ✓ | ✗ |

---

## 7. 移植路径

### 路径 A（已实现，已验证能开机）
只做**框架对接层**：`kernel/sched/mi_sched.c`，含全部类型定义 + `mqhd_ops` 占位实现（dormant）+ mi_* 接口层 + `late_initcall`。
**不改默认调度**，用于验证「能编译 + 能开机 + ABI 不破」。

### 路径 B（未实现）
按反汇编逐个还原 MQHD 全部回调的真实逻辑（`mqhd_select_cpu` / `mqhd_enqueue` 等），完整移植。
工作量大、风险高。

---

## 8. 逆向产物

- `stock_btf_c.txt`（160479 行完整 C 类型定义）
- `stock_btf_all.txt`（pahole 全量 dump）
- `pull_stock_vmlinux.btf`（原始 BTF 7MB）
- `mi_cluster_stock.asm` / `bpf_scx_reg.asm`（反汇编）

---

*方法：BTF 源码级提取 + objdump 反汇编交叉验证。所有结论均有设备实测或二进制证据支撑。*
