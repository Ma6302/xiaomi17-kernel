# Ma6302 Kernel Addon（MK-Addon）—— 配套内核的用户空间模块

> 配套 Ma6302 自编译内核（cctv18 6.12.69 血统）
> 设计目标：**日常参数调节 + 压缩算法切换 + 研究数据收集**
> 用法：改配置文件 → 重启生效（或 `su -c /data/adb/modules/mk-addon/apply.sh` 立即生效）
> 参考：Nanally 的 `magisk_template` 分发模式（AK3 刷内核 + ksud 装模块）

---

## 一、这是什么

刷内核时一并安装的用户空间模块，**不动内核、不动 vendor 模块**（内核产物 `do.modules=0`）。

它做三件事：

```
① 参数调节  —— 调度/内存/IO/网络 一组可调开关
② zram 控制 —— 压缩算法切换 + zram 相关节点 + 小米 zgroup/xswapd/mctrl 研究开关
③ 数据收集  —— 每次开机/按需 dump 一份「内核 + zram + 内存」状态快照
```

**关键设计**：内嵌在 AK3 包内，`anykernel.sh` 通过 `ksud module install` 在刷内核时自动安装。

---

## 二、目录结构

```
mk-addon/
├── module.prop           模块信息
├── install.sh            安装脚本（Magisk/KSU 通用）
├── customize.sh          (可选) Magisk 新版入口
├── config.conf           ★ 唯一的用户配置文件（改这里）
├── service.sh            开机自动应用（LATESTARTSERVICE）
├── apply.sh              手动立即应用（su -c .../apply.sh）
├── collect.sh            数据收集（生成快照到 /data/local/mk-data/）
├── pack.sh               打包脚本
├── lib/
│   ├── common.sh         公共函数（写节点/日志/读配置）
│   ├── tune.sh           参数调节实现
│   └── zram.sh           zram/压缩算法/研究开关实现
└── README-模块说明.md     本文件
```

---

## 三、config.conf 各项说明

### 3.0 内核身份守卫（防止在原厂内核上误动作）★

```ini
KERNEL_GUARD=1              # 1=只在「本项目内核」上工作（默认）
EXPECTED_KERNEL_TAG=Ma6302  # uname -r 必须包含此标记才算我们的内核
GUARD_COLLECT_ON_FOREIGN=0  # 非我方内核时是否仍做只读快照（0=完全停止）
```

**为什么需要**：刷内核模块（MK-Addon）**不会**随 `fastboot flash boot_a` 一起消失——
它装在 `/data/adb/modules/`。所以当刷回原厂/别家内核时，若不设防，模块仍会在开机后
继续改 VM 参数、切换 zram 压缩算法，这不符合预期。

**行为**：

| 运行内核 | 调参（VM/IO/zram/net） | 数据收集 |
|---|---|---|
| 本项目内核（`*Ma6302*`） | ✅ 正常执行 | ✅ |
| 原厂 / Jianke / 其他 | ⛔ **完全跳过**（日志记录 `GUARD:` 行） | 默认跳过 |

**逃生口**（仅在确需时用）：
```bash
su -c /data/adb/modules/mk-addon/apply.sh --force          # 强制本次执行
su -c /data/adb/modules/mk-addon/apply.sh --only zram --force
# 或把 config.conf 的 KERNEL_GUARD 改为 0（不推荐）
```

**实测证据（2026-10-09）**：

```
真实内核（6.12.69-android16-6-4k-Ma6302）:  vm writes=5, zram 正常, 快照正常
模拟原厂（6.12.69-android16-6-g586bfab...）: vm writes=0, zram writes=0, 快照=0
模拟 Jianke（6.12.111-Jianke）:              拦截（exit=2）
--force 逃生口:                              放行 ✅
```

### 3.1 总开关
```ini
MASTER_ENABLE=1        # 0=模块完全不动作（仍可手动跑 apply.sh）
```

### 3.2 zram / 压缩算法
```ini
ZRAM_ENABLE=1          # 是否管理 zram
ZRAM_ALGO=lz4          # 压缩算法: lzo | lzo-rle | lz4 | zstd | keep
ZRAM_DISKSIZE_GB=0     # zram 大小（GB），0=保持现状
ZRAM_REMOUNT_SWAP=1    # 切换算法时自动 swapoff/swapon
ZRAM_MKSWAP=1          # reset 后自动 mkswap（必须，否则 swapon 失败）
```

> ⚠️ 算法切换是**破坏性**的（会丢弃 zram 里现有压缩页 → 对应 swap 数据丢失）。
> 脚本会先 `swapoff` 再切换再 `swapon`，但仍可能导致部分进程被杀。
> **建议在低负载 + 有空闲内存时切换。**

**默认值说明**：`ZRAM_ALGO=lz4`（2026-10-09 起）。
lz4 相比 lzo-rle 有更好的压缩率/速度权衡（高通平台实测）。

### 3.3 小米 zgroup/xswapd/mctrl 研究开关（默认全 0）
```ini
XSWAPD_ENABLE=0            # /dev/memcg/memory.xswapd.enable   （0/1）
MCTRL_COMP_RATIO=0         # /dev/memcg/memory.mctrl.comp_ratio（0=不写；>=101 才触发自动回写）
MCTRL_WB_RATIO=0           # /dev/memcg/memory.mctrl.wb_ratio  （0=不写；<=100）
```

依据逆向结论（`docs/zram-wb-reverse.md`）：

- `enable` 控制 **xswapd 主动回写循环**（后台守护式定期回写）
- **被动路径**（进程退出/页回收时的 `zgroup_untrack`）**不依赖 enable**，`drop_wb` 仍会增长
- `comp_ratio >= 101` 是自动回写的硬编码门槛
- **默认保持 0，避免意外引入 I/O 压力**

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
IO_SCHEDULER=keep          # keep | none | adios | ...（"keep" 则不改）
READ_AHEAD_KB=0            # 0=不改（保持 ROM 默认 512，UFS4 下更优）
```

> **修正记录（2026-10-09）**：初版默认 `READ_AHEAD_KB=128`（抄自 Nanally），
> 实测会把原厂 512 降到 128，**降低顺序读性能**。
> 已改为 `0`（=不改），并把已改的设备恢复为 512。

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

---

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

---

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

---

## 六、踩坑记录

### 6.1 zram 算法切换后 swap 丢失

**现象**：切换算法后 `/proc/swaps` 变空（swap 没了）。

**根因**：
1. `echo 1 > /sys/block/zram0/reset` 会清除设备上的 swap 签名
2. 必须重新 `mkswap` 才能 `swapon`
3. toybox 的 `swapon` **不接受负数 `-p`**（ROM 默认优先级是 -2，无法用 `-p` 显式指定）

**修复**（`lib/zram.sh` 的 `do_swapon()`）：

```sh
if [ "$(cfg_get ZRAM_MKSWAP 1)" = "1" ]; then
    mkswap /dev/block/zram0 >/dev/null 2>&1
fi
swapon /dev/block/zram0 2>/dev/null     # 不带 -p，ROM 自动分配默认优先级
```

---

## 七、安全与回滚

```
✗ 不写任何 vendor/erofs 分区
✗ 不动 do.modules（模块本身与内核无关）
✗ 不强制覆盖不可写节点（写失败只记日志，不中断）
✓ 所有节点写入前先读原值，记入日志（便于对照）
回滚内核：音量下+电源 → fastboot → fastboot flash boot_a stock-boot.img
```

---

## 八、实测记录（2026-10-09，boot_index 372）

刷机后 `ksud module install` 自动安装，开机后自动执行成功：

```
[10-09 22:43:51] ================ service.sh boot apply ================
  vm: swappiness=100 vfs_cache_pressure=100 compaction_proactiveness=20
      watermark_boost_factor=0 extfrag_threshold=1000
  io: scheduler=keep
  net: disabled
  zram: already lzo-rle
  mi-zram: xswapd.enable=0
  snapshot written: /data/local/mk-data/snapshot-20261009-224352.txt
```

---

*本模块仅用于自用设备内核研究与调优。*