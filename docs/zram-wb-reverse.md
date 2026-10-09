# 逆向：小米 zram 内存回写机制（zgroup / xswapd / mctrl）

> 采集日期：2026-10-09（修正版 v2）
> 设备状态：Xiaomi 17 (pudding)，原厂内核 `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`
> 对象：`/vendor_dlkm/lib/modules/zram.ko`（vendor 只读模块）+ 反汇编 20609 行
> 方法：objdump 全量反汇编 + 符号表交叉引用 + rodata 字符串定位 + 动态验证

---

## 0. 一句话结论

```
小米 zram 回写 = 三层架构，全部活着：
  ① 控制层  memory.xswapd.enable（原厂默认 0 = 关）
  ② 执行层  xswapd 内核线程 → zgroup_memcg_wb → zgroup_write_ext_sync
  ③ 目标层  zram-control ioctl 传入的块设备（extm_file 经 dm-linear 呈现）

sz_wb 是瞬时水位（呼吸正常），drop_wb 是累计流量（真实证据）。
```

> ⚠️ **重要修正说明**：本文的早期版本曾断言「sz_wb 恒为 0 / 断链 / 从未激活」。
> 该结论已被实测推翻（持续采样抓到 `nr_wb=13681`、`sz_wb=18.9MB`、`drop_wb=31047→36851` 持续增长）。
> 本文为修正版。

---

## 1. 三层架构详解

### 1.1 控制层

```
/dev/memcg/memory.xswapd.enable     (原厂默认 0)
/dev/memcg/memory.xswapd.quota      (实测 7511834624)
/dev/memcg/memory.mctrl.comp_ratio  (>=101 才触发自动回写，硬编码 0x65)
/dev/memcg/memory.mctrl.wb_ratio    (<=100)
```

### 1.2 执行层（回写链路）

```
【自动】xswapd 主循环 @0x10110（每 wake_interval=1000ms 或事件唤醒）
  条件链（全部满足才回写）：
     [0x107c0] xswapd_quota >= 1
     [0x10838] mctrl->comp_ratio >= 101      (0x65)
     [0x10884] (s1+s6)*wb_ratio/400 - s6 > 0 (s1/nr_ext, s6/nr_wb 水位)
     [0x4084]  xswapd_stop_wb 未置位（bit1）
   └→ [0x1089c] zgroup_memcg_wb(memcg, nr, &out, 0)

【手动】/dev/memcg/memory.xswapd.swapout （xswapd_swapout_write @0xf4c0）
  格式 "%lu %lu" = (百分比<=100, flag<=1)
  └→ zgroup_memcg_wb(memcg, pct*nr_ext/400, &out, flag)

【执行】zgroup_memcg_wb @0x3f88
  down_read(zgroup_rwsem)
  遍历 zgroup_head 链表：
     [0x403c] 过滤未初始化的 zgroup
     [0x406c] ldsetal 原子取 ext
     [0x40a4] zgroup_init_pool
     [0x40c4] zgroup_start_plug
     [0x40fc] zgroup_write_ext_sync   ← 真正写块设备
  up_read
```

### 1.3 目标层（bdev 从哪来）★ 核心

```
【旧理解（错误）】找 sysfs 节点 → 不存在 → 断链
【真相】bdev 通过 /dev/zram-control ioctl 设置：

  zram_control_ioctl @0xbc04（misc 设备 /dev/zram-control）
    cmd = 0x40A05C01 (IOW, 160B 结构):
      copy_from_user(160B)
      idr_find(zram_index_idr, dev_id)       ← 目标 zram 设备
      kmalloc(3520) 新建 zgroup
      filp_open_block(路径, O_RDWR|O_EXCL)   ← 用户态传来的路径
      校验 inode mode & 0xf000 == 0x6000     ← 必须是块设备！
      I_BDEV(file) → block_device
      按 bdev 大小 kvmalloc 索引数组
      …（挂入 zgroup_head 链表）
    cmd = 0xC0A05C02 (IOR): 回填 ext 起始/长度给用户态（GET 版）

【用户态接线方】/system_ext/xbin/system_perf_init:
  字符串实证它做 dm-linear： "Create dm-linear device for %s at %s successfully"
                          "Failed to create dm-linear device for %s, fallback to loop device"
  即：extm_file → dm-linear（或 fallback loop）→ 块设备节点
     → 通过 /dev/zram-control ioctl 把块设备路径传给 zram.ko
     → zram.ko filp_open_block + I_BDEV 拿到 bdev → zgroup 建立回写目标
```

### 1.4 释放（drop_wb 路径）

```
zgroup_untrack_obj @0x46c8
  ├→ zgroup_stats_wb_size_dec(zgroup, memcg_id, size)  [0x476c]
  │    sz_wb 减量（水位下降）—— per-memcg percpu 统计
  └→ zgroup_stats_wb_ext_dec [0x47fc]
       nr_ext 计数减

统计结构（zgroup+120 指向的 percpu 数组）：
  [memcg_id*64 + 0x24] = nr_wb 类字段
  [memcg_id*64 + 0x28] = sz_wb 类字段
  → sz_wb(水位) = 所有 memcg 的 wb_size 之和
  → drop_wb(累计) = 历史上所有 untrack 的总和
```

**「短暂涨到 10KB 又归零」的完整解释**：

```
短时压力 → zgroup_memcg_wb 回写 N 页 → sz_wb 上升
压力解除/进程退出 → zgroup_untrack_obj 释放 → sz_wb 下降、drop_wb 上升
→ sz_wb 是「当前驻留回写区」的水位计，不是流量计
```

---

## 2. enable 与回写关系的精确表述

```
xswapd_enable_write @0xf784 的逻辑：
  写 1 时：
     检查 zgroup_get_enable()（zgroup_enable 必须已开）
     检查 swap 总量（si_swapinfo）
     设 xswapd_enabled (.bss+0xa28) = 1
     起延迟工作（__msecs_to_jiffies + system_wq）
  写 0 时：取消

wakeup_xswapds @0xe204 的入口判定：
    if (xswapd_enabled != 1) return;      ← enable 是唤醒闸门
```

实测 `enable=0` 但 `nr_wb`/`drop_wb` 仍在增长，说明：

- `enable` 控制 **xswapd 主动回写循环**（后台守护式的定期回写）
- **被动路径**（进程退出 / 页回收时的 `zgroup_untrack`、`zgroup_swapout_objs`）**不依赖 enable**
- 这解释了「enable=0 也能看到 drop_wb 增长」与「手动开启 enable 后流量放大」两个事实

---

## 3. 为什么 MIUI 原厂默认关闭 xswapd（enable=0）

逆向证据（标注为**推断**，非实锤）：

```
① 双回写引擎冲突：
   MIUI 上层有 extm（system_perf_init + MiuiMemoryInfoImpl，extMemUsage 154MB+）
   内核有 xswapd/zgroup_wb
   两套机制的回写目标【同为 extm_file】
   → 若都全开，同一块设备会被双路径写入，需要锁与仲裁
   → MIUI 选择：上层 extm 主导，内核 xswapd 默认关

② xswapd 唤醒闸门极多（wakeup_xswapds @0xe204）：
   si_mem_available >> 8 与水位比较（mem_press/high/low watermark）
   wake_interval 频控（1000ms）
   …不满足则 low_mem_skip++（实测 802 万次 skip）
   → 全开内核回写会带来不可控的 I/O 风暴风险，MIUI 保守关闭

③ smart_cache 是配套的「内存策略」子系统而非 bdev 接口：
   注册的是 filemap_add_folio / memcg_charge / shrink_node 等回收钩子
   → /sys/kernel/smart_cache/file 在内核侧【没有 store 实现】（只有 show）
     写不进去是【设计如此】（旧版归咎 SELinux 是误判）
```

---

## 4. QPaCE 结论（空桩，无法开启）

```
get_qpace / put_qpace                → 空函数（直接 ret）
qpace_queue_compress_wrapper         → 恒返回 -EINVAL
```

三个函数全为空桩、无重定位、无硬件访问能力。
**无 sysfs 开关**——QPaCE 在 zram.ko 里没有任何可启用的路径。
若要启用需重编 vendor zram.ko 或改用第三方 LKM（均未实施）。

---

## 5. 旧版结论逐条复核

| 旧论断 | 复核结果 | 依据 |
|---|---|---|
| QPaCE 是空桩 | ✅ 成立 | 3 函数全空/恒错，无重定位 |
| 回写代码真实存在 | ✅ 成立 | zgroup_wb_init 256B / submit_zio 2936B |
| 「sz_wb 恒为 0，从未激活」 | ❌ **作废** | 实测 nr_wb=13681 / sz_wb=18.9MB / drop_wb 持续增长 |
| 「zgroup_add 无调用者，链表恒空」 | ❌ **作废** | 有调用者 0x4ef8（zgroup_alloc 内） |
| 「主因是 xswapd.enable=0」 | ⚠️ 部分成立 | enable 是回写开关没错，但「未使能时 sz_wb 必为 0」不成立 |
| `mctrl_wb_ratio_write` 是纯参数设置 | ✅ 成立 | `if (val>100) return -EINVAL; c->wb_ratio=val;` |
| 手动 swapout 接口 `"%lu %lu"` | ✅ 成立 | sscanf 格式串 `.rodata+0x445` |

---

## 6. 运行时可观测指标

```bash
# 水位与流量
cat /dev/memcg/memory.xswapd.stat
  nr_ext / nr_wb / sz_wb（水位）/ drop_wb（累计）/ fault_wb / wake_up

# mctrl
cat /dev/memcg/memory.mctrl.stat     # wb_pages

# zgroup
cat /sys/block/zram0/zgroup_enable
```

实测（2026-10-09 boot_index 372）：

```
xswapd.enable = 0   （出厂默认）
nr_wb   = 3024
sz_wb   = 3431716   ← 水位（正常呼吸）
drop_wb = 66845     ← 累计流量（持续增长）
fault_wb= 24
zgroup_enable = 1
```

---

## 7. 遗留问题

| # | 问题 | 线索 |
|---|---|---|
| R1 | ioctl 0x40A05C01 的 160B 结构精确布局（路径偏移、dev_id 位置） | be04 前 sp+0x80 起 |
| R2 | 当前 dm/loop 无 extm 条目但回写在工作——bdev 实体在哪 | 检查更早 boot 阶段的 dm 表快照 |
| R3 | `zgroup_swapin_objs` / fault_wb 何时非零（冷页读回） | 0x5xxx 区间 |
| R4 | xswapd 主循环中 mctrl group_param 10 级策略表的作用位置 | mctrl_group_param_write @0x5ed4 |

---

## 8. 佐证：MIUI 原厂 init.rc 开机尝试开启回写但被拦

BootLog Harvester 在新内核启动日志中抓到：

```
[38.421] init: 'write /dev/memcg/freeze-app/memory.anno_writeback_enable 1' failed: Permission denied
[38.421] init: 'write /dev/memcg/protected-app/memory.anno_writeback_protected 1' failed
[38.423] init: 'write /dev/memcg/protected-app/memory.anno_writeback_control 1' failed
```

→ MIUI 原厂 init.rc 开机想开 `anno_writeback` 但被 SELinux 拦
→ 佐证「回写相关机制原厂未完全开启」的判断

---

*逆向方法：objdump 全量反汇编 + 符号表交叉引用 + rodata 字符串定位 + 动态验证。*
