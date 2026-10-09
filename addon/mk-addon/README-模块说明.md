# Ma6302 Kernel 附加模块（MK-Addon）

> 配套 Ma6302 自编译内核（cctv18 6.12.69 血统）
> 设计目标：**日常参数调节 + 压缩算法切换 + 研究数据收集**
> 用法：改配置文件 → 重启生效（或 `su -c /data/adb/modules/mk-addon/apply.sh` 立即生效）
> 生成：2026-10-09

---

## 一、这是什么

刷内核时一并安装的用户空间模块，**不动内核、不动 vendor 模块**（`do.modules=0`）。
它做三件事：

```
① 参数调节  —— 调度/内存/IO/网络 一组可调开关
② zram 控制 —— 压缩算法切换 + zram 相关节点 + 小米 zgroup/xswapd/mctrl 研究开关
③ 数据收集  —— 每次开机/按需 dump 一份「内核 + zram + 内存」状态快照
```

## 二、目录结构

```
mk-addon/
├── module.prop           模块信息
├── install.sh            安装脚本（Magisk/KSU 通用）
├── customize.sh          (可选) Magisk 新版入口
├── config.conf           ★ 唯一的用户配置文件（改这里）
├── service.sh           开机自动应用（LATESTARTSERVICE）
├── apply.sh             手动立即应用（su -c .../apply.sh）
├── collect.sh           数据收集（生成快照到 /data/local/mk-data/）
├── lib/
│   ├── common.sh         公共函数（写节点/日志/读配置）
│   ├── tune.sh           参数调节实现
│   └── zram.sh           zram/压缩算法/研究开关实现
└── data/                 collect.sh 的输出目录（运行时生成）
```

## 三、config.conf 各项说明

### 3.1 总开关
```ini
MASTER_ENABLE=1        # 0=模块完全不动作（仍可手动跑 apply.sh）
```

### 3.2 zram / 压缩算法
```ini
ZRAM_ENABLE=1          # 是否管理 zram
ZRAM_ALGO=lz4          # 压缩算法: lzo | lzo-rle | lz4 | zstd
                       #   ★ 切换会 reset zram（清空 swap），需要 off/on swap
ZRAM_DISKSIZE_GB=16    # zram 大小（GB），0=保持现状
ZRAM_SWAPPINESS=100
```
> ⚠️ 算法切换是**破坏性**的（会丢弃 zram 里现有压缩页 → 对应 swap 数据丢失）。
> 脚本默认会先 `swapoff` 再切换再 `swapon`，但仍可能导致部分进程被杀。
> 建议在**低负载 + 有空闲内存**时切换。

### 3.3 小米 zgroup/xswapd/mctrl 研究开关（默认全 0）
```ini
XSWAPD_ENABLE=0            # /dev/memcg/memory.xswapd.enable   （0/1）
MCTRL_COMP_RATIO=0         # /dev/memcg/memory.mctrl.comp_ratio（0=不写；>100 才触发自动回写）
MCTRL_WB_RATIO=0           # /dev/memcg/memory.mctrl.wb_ratio  （0=不写；<=100）
```
> 依据逆向结论（`逆向-zram回写机制-结论-20261009.md`）：
> 自动回写需 `xswapd.enable=1` + `mctrl.comp_ratio>=101`。
> **默认保持 0，避免意外引入 I/O 压力。**

### 3.4 内存 VM
```ini
SWAPPINESS=100
VFS_CACHE_PRESSURE=100
COMPACTION_PROACTIVENESS=20
WATERMARK_BOOST_FACTOR=0
EXTFRAG_THRESHOLD=1000
DIRTY_RATIO=0              # 0=不写（保持 ROM 默认）
```

### 3.5 IO
```ini
IO_SCHEDULER=keep         # keep | none | adios | ...（写 "keep" 则不改）
READ_AHEAD_KB=128
```

### 3.6 网络（默认关闭，防止影响日常）
```ini
NET_TUNE=0
```

### 3.7 数据收集
```ini
COLLECT_ON_BOOT=1          # 每次开机收一份快照
COLLECT_DIR=/data/local/mk-data
KEEP_SNAPSHOTS=60          # 保留最近 N 份
```

## 四、常用操作

```bash
# 改配置
vi /data/adb/modules/mk-addon/config.conf

# 立即生效（不重启）
su -c /data/adb/modules/mk-addon/apply.sh

# 只重跑 zram 部分
su -c /data/adb/modules/mk-addon/apply.sh --only zram

# 手动收一次快照
su -c /data/adb/modules/mk-addon/collect.sh
ls -la /data/local/mk-data/

# 看日志
cat /data/local/mk-addon.log
```

## 五、数据快照内容（每次收集）

```
snapshot-<时间>.txt
  ├─ 内核标识        uname -a / /proc/version / vermagic
  ├─ 加载模块        lsmod 计数 + 是否含 KernelSU
  ├─ ABI 自检        kobject_uevent_env 等关键符号存在性
  ├─ zram            mm_stat / comp_algorithm / disksize / mem_limit
  ├─ swap            /proc/swaps
  ├─ 内存            MemTotal/Free/available / vmstat 摘要
  ├─ mi_sched        /sys/kernel/sched_ext/* （state 等）
  ├─ zgroup/xswapd   /dev/memcg/memory.xswapd.* / mctrl.*
  └─ 我加的参数      回显本次 apply 写入的值
```

## 六、安全与回滚

```
✗ 不写任何 vendor/erofs 分区
✗ 不动 do.modules（模块本身与内核无关）
✗ 不强制覆盖不可写节点（写失败只记日志，不中断）
✓ 所有节点写入前先读原值，记入日志（便于对照）
✓ 提供 restore.sh 一键回到「不调参」状态（可选，见下）
回滚内核：音量下+电源 → fastboot → fastboot flash boot_a stock-boot.img
```

## 七、与 Nanally 模块的关系

本模块结构参考 Nanally 的 `magisk_template`（`service.sh` + `common/`）思路，但：
```
- 不打包 .ko（do.modules=0，绝不动 vendor 模块）
- 把「改参数」集中到一个 config.conf（Nanally 是硬编码在 service.sh）
- 新增「数据收集」与「zram 研究开关」两块（面向内核迭代）
```

---

*本模块仅用于自用设备内核研究与调优。*
