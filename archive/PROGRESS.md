> ℹ️ **【历史归档 2026-10-08】**
>
> 本文写于 AOSP 树阶段，其结论已被后续实测推翻。
> 保留原因：记录当时的推理过程与失败模式。
>
> 正确结论见 [`README.md`](README.md) 与 [`../docs/WHY-CCTV18.md`](../docs/WHY-CCTV18.md)。

---

# 进度追踪 — Xiaomi 17 (pudding) 内核构建

> 更新: 2026-10-08 00:15
> 作者: Ma6302

---

## 当前状态：**已定位「取证为何一直失败」，排除多条嫌疑，两个交叉自检包就绪 → 待二分实验**

> 📄 **新会话请先读 `新会话交接-20261008.md`**（最短路径）

```
[✓] 阶段 0  情报采集 + 分区备份
[✓] 阶段 1  诊断套件制作
[✓] 阶段 2  PC 环境 + 拉源码
[✓] 阶段 3  首次编译（diagnostic-safe）
[✓] 阶段 3.5 刷入前置检查
[✓] 阶段 4a 首刷 + 失败 + 回滚          ← V1 卡一屏
[✓] 阶段 4b 失败现场取证 + 深度归因
[✓] 阶段 4c V2 取证版构建 + 传输到手机
[✓] 阶段 4d 刷入 V2 → 同样卡一屏 → 零证据
[✓] 阶段 4e 机制纠错 + 排除多条嫌疑 + 造出交叉自检包   ← 你在这里
[ ] 阶段 5  二分实验（刷 SELFTEST-B）→ 定性「内核 vs 打包」
[ ] 阶段 6  定位根因 → 修复 → 收口
```

### 🔴 阶段 4e 成果（2026-10-08 01:10）

**两个机制纠错（推翻旧推断）**

1. **mtdoops 写的是「本轮正常关机时的本轮日志」** —— oops 分区 8 条记录尾部全是干净关机流程 → 卡死的 354/356 **没有关机路径 → 永不落盘**。
   → 旧推断「V1 活到 2.1s、卡在显示接管前」**作废**。
2. **PSHOLD 复位（音量下+电源）不走内核 reboot 路径，必然销毁现场** —— 不调 `panic()` → 不触发 `kmsg_dump()` → printk/ramoops 全丢。
   → **「卡住 → 按键重启」本身就是取证失败的原因。**

**V2 的 panic 机制实测未触发**（配置确认已编入）
```
CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y      已编入，未触发
CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y       已编入，未触发
CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=30      已编入，未触发
CONFIG_PANIC_TIMEOUT=20                  已编入（未自动重启）
runtime: # CONFIG_HARDLOCKUP_DETECTOR is not set / # CONFIG_QCOM_WDT is not set
```

**排除的嫌疑（重要，省得重走）**

| 嫌疑 | 排除依据 |
|---|---|
| **`rm kernel_dtb` 删 DTB** | **Nanally 也删，能开机** ← 旧头号嫌疑淘汰 |
| kernel_dtb 是垃圾 | 三个内核都含同样的 72 字节占位 |
| 内核格式不对 | 三个内核 `4d5a40fa`/`ARMd@` 字节级一致 |
| magiskboot 打包损坏数据 | 回拼 md5 完全一致（LOSSLESS: YES） |
| patch_cmdline 破坏 boot 头 | 实测注入正常，`magiskboot -h` 正确读出 |
| ABI 大面积拒载 | 无任何内核日志 |

**⭐ 最有价值的对比发现**

| | anykernel.sh | `rm kernel_dtb` | `patch_cmdline` | 结果 |
|---|---|---|---|---|
| Jianke | 793 B | ❌ | ❌ | ✅ 开机 |
| Nanally | 1581 B | ✅ | ❌ | ✅ 开机 |
| 我们 | 3293 B | ✅ | ✅ ×4 | ❌ 卡一屏 |

→ **`patch_cmdline` 是「我们有、两个成功先例都没有」的唯一操作**（明天重点验证）

**关键数据结构（PE 级，设备端 python3 实测）**
```
我们的 Image : 58,055,168 B  SizeOfImage 62,914,560  .text 40.3MB  .data 17.7MB
Jianke Image : 70,961,664 B  （zip 内完整版；magiskboot 从 boot 切的 21MB 是截断的）
Nanally Image: 42,527,232 B
```
⚠️ 教训：**magiskboot 从 boot 分区切出的 "kernel" 是截断 PE**（KERNEL_SZ 被拆成 kernel+kernel_dtb），必须用 zip 内的原始 Image。

**🔴 根本未知（明天实验核心目标）**
**无法证明我们的内核执行过。** 「卡第一屏」可能是 (a) 内核跑了但挂起，或 (b) **内核根本没开始执行**（ABL 加载失败）。此前默认 (a)，从未验证。

### 明天：二分实验

| 包 | 组成 | md5 |
|---|---|---|
| **SELFTEST-B**（★先刷） | Jianke 的 AK3 外壳 + **我们的 Image** | `a6fef77699fa6a3175971134a517af90` |
| SELFTEST-A | 我们的 AK3 外壳 + **Jianke 完整 Image** | `dc42436d690d0f0f16fbf952f35ef7fd` |

- **B 能开机** → 我们的 Image 是好的，元凶 = 我们的打包链（patch_cmdline）
- **B 仍卡** → 内核侧问题，再刷 A 交叉确认

⚠️ 刷 B 前先核对：Jianke 的 anykernel.sh 用小写 `block=boot`，需确认其 `tools/ak3-core.sh` 是否读小写（若不匹配，AK3 的 `[ ! -e "$BLOCK" ] && abort` 守卫应能安全 abort，但要先确认守卫存在）。

### 📌 当前设备状态（2026-10-08 01:05 实测）

| 项 | 值 |
|---|---|
| 当前内核 | `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k`（**真原厂**） |
| boot_a md5 | `5157f9020b45b51ec1701c79cda9b93d` = `stock-boot.img` ✅ |
| boot_index | 357 |
| PC | 已断开（明天恢复） |

### 📌 首刷失败事件摘要（2026-10-07 21:46）

| 项 | 内容 |
|---|---|
| 现象 | 刷入 `pudding-KernelSU-Ma6302-20261007.zip` 后**卡在开机第一屏 logo**，无声音无振动 |
| 用户处置 | 音量下+电源进 fastboot → PC `fastboot flash boot` 回滚（**实际刷入 boot_a.img = Jianke，非原厂**） |
| 归因结论 | **静默挂起（hang），非 panic**；挂起窗口 **~2.1s ~ ~3.0s**（mtdoops 在 2.1s 写盘成功，显示接管在 3.0s 从未发生） |
| 头号嫌疑 | **显示链路 vendor 模块挂起**（msm_drm/sde/DSI 探测窗口） |
| 次要嫌疑 | 双 KSU 慢冲突（zygote/SystemUI 在 20~60s，与收紧窗口不吻合，已降级） |
| 取证产物 | `刷入失败深度分析-20261007.md`、`kernel-dev/blackbox_strings.txt`、`kernel-dev/oops_strings.txt` |
| 为什么零证据 | `PANIC_ON_OOPS=y` 但 `BOOTPARAM_SOFTLOCKUP_PANIC/HUNG_TASK_PANIC` 未设 → 等锁型挂起不 panic、不落盘 |

### 📌 当前设备状态（2026-10-08 00:10 实测）

| 项 | 值 |
|---|---|
| 当前内核 | **`6.12.111-Jianke`**（boot_a md5 `5329fec9e9c154913673065734662067` = `boot_a.img`） |
| 说明 | **不是原厂**（用户口述"刷回原厂"与实际不符，以分区 md5 为准，无碍） |
| root | init_boot 的 kernelsu.ko（LKM），刷 boot 不影响 |
| 回滚资源 | `stock-boot.img`（真原厂 6.12.69，md5 `5157f902...`）、`boot_a.img`（Jianke，md5 `5329fec9...`） |

### 📌 刷入前的设备状态（2026-10-07 21:40 实测，这是即将被替换的基线）

| 项 | 值 |
|---|---|
| 当前内核 | `6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k` |
| boot 分区 md5 | `5157f9020b45b51ec1701c79cda9b93d` |
| **= `stock-boot.img`** | ✅ **完全一致** —— 已刷回官方内核（但**内置了 KernelSU**，root 仍在） |
| root | `su` 可用，`context=u:r:ksu:s0`；内核侧有 `kernelsu(O)` 模块 |
| KSU 管理器 | SukiSU Ultra v4.2.0（`com.sukisu.ultra`，`ksud 4.2.0-1-g904c60d1`） |
| 已装模块 | YH_YC / asoul_affinity_opt / playintegrityfix / trickstore / zygisk_lsposed / zygisksu |
| **刷机工具** | **Horizon Kernel Flasher 1.3**（`xzr.hkf`）✅ 已确认在手 |
| PC | **已断开连接**（刷入改用机内 Horizon，不依赖 PC） |

> ⚠️ 注意：`stock-boot.img` 不是"纯净官方"——它是官方内核 + 已内置 KSU 的版本。
> 这对我们**有利**：ABI 基线回到官方 `6.12.69`，同时 root 保留、模块无需重装。

### 本轮（2026-10-07）成果

| 项目 | 结果 |
|---|---|
| PC 端网络 | Agent 换址至 `http://<LAN-IP>:<PORT>`（手机经 USB/rndis0，手机 `<LAN-IP>`） |
| `.wslconfig` | **写入成功并生效**：12GB 内存 / 32GB swap / 16 核 / networkingMode=mirrored |
| WSL 发行版 | Ubuntu 24.04.5 LTS 安装成功（`wsl --install -d Ubuntu-24.04`，无需重启） |
| 工具链 | clang 19.0.1 (r536225) + rustc 1.82.0-dev + bindgen 0.69.5 + AOSP build-tools |
| 源码 | AOSP ACK `android16-6.12`，**6.12.93**，commit `7e73c6dc`；KernelSU `e7b0711` |
| 编译 | **成功，耗时 6 分 37 秒**（16 核 / 12GB） |
| 产物 | `pudding-KernelSU-Ma6302-20261007.zip`（20,533,883 B，md5 `b137e877ac9d4747cdc201add0f56694`） |
| Image | `58055168` B（55 MB），`Linux kernel ARM64 boot executable Image, little-endian, 4K pages` |
| vermagic | `6.12.93-android16-6-4k-Ma6302 SMP preempt mod_unload modversions aarch64` |
| ABI 红线 | 07 校验**全部通过**（4K页/VA39/SMP/PREEMPT/MODVERSIONS/GENDWARFKSYMS/CFI/SCS/KABI/KPROBES/SIG_FORCE=n） |
| 成品校验 | 08 校验**通过：可以刷入** |
| 产物位置 | PC `D:\刷机\xiaomi 17\6.12内核编译\`；手机 `/sdcard/Download/pudding-kernel/` |

### 本轮踩到并修掉的 3 个坑（已写回套件，套件版本已修正）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `dwarf.h: file not found`（编译 7 秒即挂） | `02-install-deps.sh` 命令里列了 `libdw-dev`，但实际未装上 | `apt-get install -y libdw-dev` |
| 2 | `"...exceeds 64 characters"` | `config.env` 里 `export LOCALVERSION` 进入 make 环境，与 `.config` 的 `CONFIG_LOCALVERSION` **叠加两次** | 改名 `KERNEL_LOCALVERSION` + `unset LOCALVERSION` |
| 3 | vermagic 末尾多一个 `+` | `LOCALVERSION_AUTO` 未关（追加 `-g<sha>-dirty`）；且 `scripts/setlocalversion` 的 short 分支无条件 `echo "+"` | `--disable LOCALVERSION_AUTO` + 抑制该 `echo "+"`（原件备份为 `setlocalversion.ma6302.bak`） |

> 坑 2 与坑 3 的 sed 修复逻辑已内建进 `05-build.sh`，下次重跑可自动生效、幂等。

### 关键 ABI 判据（本轮实测确认）

```
厂商模块 : 6.12.69-android16-6-4k         SMP preempt mod_unload modversions aarch64
我们的   : 6.12.93-android16-6-4k-Ma6302  SMP preempt mod_unload modversions aarch64
           └── MODVERSIONS 下不比较 ──┘    └────── 逐字一致 ──────┘
                                          >>> TAIL MATCH: same_magic OK
```

---

## ⚠️ 更正：朋友仓库的定位（前次记录有误）

`StarfallSeas/android_kernel_sm8850_xiaomi_common` **不是**小米厂商整机树。
实测证据：根目录含 `gki/`（含 `gki/aarch64/abi.stg`）、`build.config.gki`、Kleaf 布局；
`arch/arm64/configs/` 只有 `gki_defconfig`（无 pudding/canoe defconfig）；
`arch/arm64/boot/dts/qcom/` 全是上游公版 dts（无 pudding dts）。
**它实为 AOSP ACK `kernel/common` 的 `android16-6.12.90` 快照 + 若干 sched/block 优化补丁 + GitHub Actions CI。**

结论（按用户 2026-10-07 指示）：
- **不引入、不深究、不采用**：作者没有设备，产物开不了机，其结论会误导判断。
- 但其**方向与我们的路线同源**（同为 ACK + gki_defconfig + clang r536225），
  故不能当作"厂商树不开机"的反面证据 —— 前次那份推论作废。
- 唯一可取的参考是其 CI 里已验证的**工具链来源**
  （`cctv18/oneplus_sm8650_toolchain` LLVM-Clang19-r536225 release，含 rust/bindgen/build-tools/pahole）。
  本轮 Rust 与 build-tools 即取自此处，实测可用且与真机内核的 rustc/bindgen 版本完全一致。

---

## ✅ 已完成清单（累计）

| # | 项目 | 结果 |
|---|---|---|
| 1 | 设备情报采集 | → `device_facts.txt` |
| 2 | 内核配置导出 | → `stock_kernel_config.txt` (2385 项) |
| 3 | **完整分区备份** | → `backup_full/` (boot/init_boot/vendor_boot/dtbo/vbmeta×2) |
| 4 | 官方 OTA 收录 | → `pudding-ota_full-OS4.0.0.32.XPCCNXM.../boot.img` |
| 5 | 两家成功内核逆向 | Jianke + Nanally 结构完全解析 |
| 6 | 源码可得性核实 | MiCode 无 pudding 分支；AOSP GKI 全分支可用 |
| 7 | 编译环境搭建 | 手机 proot Ubuntu 24.04，工具齐全 |
| 8 | 代理验证 | 端口 7890，TUN 全局，proot 内也通 |
| 9 | **构建套件制作** | → `pudding-kernel-kit/` + `pudding-kernel-kit.zip` |
| 10 | 采集器实测 | collect.sh / analyze.sh 在真机跑通 |
| 11 | 打包闭环演练 | 06+08 全流程通过 |
| 12 | **PC 打通的传输链路** | 手机↔PC 经 USB/rndis0（HTTP 传输，md5 校验一致，42MB/s） |
| 13 | **首次编译通过** | 6.12.93 + KernelSU，6 分 37 秒，ABI 红线全过 |
| 14 | **Skill 体系部署** | `Ma6302/xiaomi17-kernel-skills` 10 个 skill 装到手机并验证可加载 |

---

## 🔑 核心技术结论

### 1. 为什么「没源码也能编」——same_magic() 机制

```
厂商模块 : 6.12.69-android16-6-4k         SMP preempt mod_unload modversions aarch64
我们的   : 6.12.92-android16-6-4k-Ma6302  SMP preempt mod_unload modversions aarch64
           └── 跳过不比较 ──┘              └──── 必须逐字一致 ────┘
```

`MODVERSIONS=y` 时只比较第一个空格之后的内容，**版本号段被跳过**。
真正决定加载成败的是**导出符号 CRC**，由 `gki_defconfig` 保证。

### 2. 双重实证 + 本轮实测

| | Jianke | Nanally | 我们 |
|---|---|---|---|
| 纯 GKI Image | ✅ 40.5MB | ✅ 42.5MB | ✅ **55.4MB**（58,055,168 B） |
| 基础版本 | 6.12.111（**不**匹配 6.12.69） | 6.12.69（精确匹配） | **6.12.93** |
| 结果 | ✅ 可用 | ✅ 可用 | ✅ ABI 校验全过 |

**版本跨度 42 个小版本都能用 → 机制验证成立。**（6.12.93 落在 6.12.69 与 6.12.111 之间，两端的先例都成立。）

### 3. 设备特性（利多）

```
原厂 stock-boot.img : header v4, KERNEL_SZ 41,576,960 (39.7MB), RAMDISK_SZ 0, KERNEL_DTB_SZ 20,237,792
Jianke boot_a.img   : header v4, KERNEL_SZ 91,199,456 (87.0MB), RAMDISK_SZ 0, KERNEL_DTB_SZ 69,925,952
我们的 Image        : 58,055,168 B (55.4MB)
```

**三点结论**：

1. **`RAMDISK_SZ = 0`（ramdisk-less）** → 刷机只替换 Image，**完全不碰 ramdisk**。
2. **存在 `kernel_dtb` 段**（19.3 ~ 66.7MB）。已验证其内容为**空占位 DTB**：
   DTB 头声明 `totalsize = 72` 字节，其余 99.9999% 是零填充 → **是刷机残留垃圾**。
   AK3 丢弃它并改用新内核内置 DTB，与 Jianke / Nanally 的做法一致。
3. **`CMDLINE` 为空** → 启动参数来自 vendor_boot 的 bootconfig，
   所以 AK3 注入的 `loglevel=7 ignore_loglevel log_buf_len=4M` 可能被覆盖（不致命，pstore 兜底）。

### 4. 日志基建（已有，可直接用）

| 组件 | 类型 | 早期可用 |
|---|---|---|
| `pstore` / `ramoops` | **内核内置** | ✅ 极早期 |
| `qcom_logbuf_boot_log` | **内核内置** | ✅ |
| ramoops 保留区 | DT `reg=0xff4020…` (2MB) | ✅ |
| `/data/local/bootlog/bootlog.txt` | 引导日志（49MB） | 系统起来后 |
| `dmesg_dumper` / `mtdoops` | 厂商 .ko | ❌ 模块挂了就没 |
| 分区 `oops`/`blackbox`/`logfs` | 独立分区 | — |

---

## 📦 交付物

```
/storage/emulated/0/Operit AI/小米17/6.12内核/
├── 新会话交接.md                   ★★★ 新会话先读这个
├── PROGRESS.md                     本文件（完整进度与风险）
├── skills-安装说明.md              skill 安装与维护规则
├── 参考线索.md                     参考源定性（含朋友仓库更正）
├── 内核构建规划.md                 最初规划
├── 刷入检查记录.md                 ★ 本次刷入前置检查的原始证据
├── pudding-kernel-kit.zip          ★ 3.2 MB / 36 文件（拷到 PC）
├── pudding-kernel-kit/
│   ├── README.md                   完整手册
│   ├── build-all.sh                一键全流程
│   ├── scripts/                    00~08 + config.env（已含 3 处修复）
│   ├── gki-fragment/               diag-safe / diag-deep
│   ├── bootlog-harvester/          ★ 采集器（含 660 模块基线）
│   └── anykernel3/                 AK3 模板（取自 Jianke 验证包）
├── backup_full/                    ★ 全分区备份（回滚保险）
├── pudding-ota_full-.../boot.img   ★ 官方 OTA 原件
├── others/舰长/                     Nanally 参考包
├── device_facts.txt                设备情报（旧，2026-10-06）
├── stock_kernel_config.txt         内核配置导出（2385 项）
└── scripts/repack-kit.py           套件重打包工具
```

### 可刷成品与回滚镜像（都在手机本地，PC 断开也能自救）

```
/sdcard/Download/pudding-kernel/
├── pudding-KernelSU-Ma6302-20261008-V2-diag.zip   20,534,615 B  ★ V2 取证版，待刷
│                                                  md5 92c3d4e858969fc2d2cbbfe9b747b1d3
├── bootlog-harvester-v2.zip                        19,713 B     V2 采集器（含 oops 段）
│                                                  md5 4283026c6c478200fce377019c16791f
├── pudding-KernelSU-Ma6302-20261007.zip          20,533,883 B   V1（卡一屏那版，对照）
│                                                  md5 b137e877ac9d4747cdc201add0f56694
├── stock-boot.img                               100,663,296 B  ★ 真原厂 6.12.69（回滚首选）
│                                                  md5 5157f9020b45b51ec1701c79cda9b93d
├── boot_a.img                                   100,663,296 B  ★ Jianke 6.12.111（当前状态）
│                                                  md5 5329fec9e9c154913673065734662067
├── pudding-kernel-kit.zip                         3,358,154 B
├── skills-repo.tar.gz                              152,551 B
└── PROGRESS.md
```

PC 侧同步副本（PC 当前断开）：`D:\刷机\xiaomi 17\6.12内核编译\`

### Skill 安装位置

```
/sdcard/Download/Operit/skills/     10 个 skill / 20 个文件
（Ma6302/xiaomi17-kernel-skills @ 97ff0d9）
```

---

## 📊 健康基线（两个可用参考点）

### A. Jianke 内核时期（6.12.111）—— 完整采集，`bootlog-harvester` 的对照基线

```
内核          : 6.12.111-Jianke
已加载模块    : 660  ✅
可加载模块    : 404 (.ko 文件)
缺失模块      : 0    ✅
dmesg 符号错误: 无   ✅
KMI           : android16-6-4k
页大小        : 4096
```

> `bootlog-harvester` 里的 `baseline_modules.txt`（660 个模块）就是这份数据。

### B. 当前官方内核时期（6.12.69 + 内置 KSU）—— 刷入前的最后一次实测基线

```
内核          : 6.12.69-android16-6-g586bfab1b9c5-abogki536749445-4k
已加载模块    : 336（dmesg 中带 (O)/(OE) 标记的模块）
KSU           : kernelsu(O) 内核内置
boot md5      : 5157f9020b45b51ec1701c79cda9b93d
```

⚠️ **刷入后对比时注意**：模块数量基线有两个值（660 vs 336），
前者是"`/proc/modules` + 可加载 .ko 文件"的全量口径，
后者是"dmesg 中已加载模块"的口径。**对比时要用同一口径**，
建议统一用 `bootlog-harvester` 的 `modules_loaded.txt`。

### ABI 红线（已验证全部正确）
```
CONFIG_ARM64_4K_PAGES=y       CONFIG_ARM64_VA_BITS=39
CONFIG_CFI_CLANG=y            CONFIG_SHADOW_CALL_STACK=y
CONFIG_MODVERSIONS=y          CONFIG_GENDWARFKSYMS=y
CONFIG_SMP=y                  CONFIG_PREEMPT=y
CONFIG_MODULE_UNLOAD=y        CONFIG_KPROBES=y
CONFIG_ANDROID_KABI_RESERVE=y
# CONFIG_MODULE_SIG_FORCE is not set
```

---

## 🔜 下一步（阶段 4d：刷入 V2 取证版 + 抓 panic 栈）

**前置已完成**：V2 已构建（Image 58,055,168 B 与 V1 逐字节同尺寸）、已传输到手机、md5 校验一致。

> 📄 详细步骤见 **`V2刷入指引.md`**

### 核心区别：V2 是取证版，预期仍会卡

**不要期待它能开机**——卡了才有 panic 栈可抓。这与 V1 的唯一差别是「卡死会被强制转成 panic」。

### 刷入步骤

1. 打开 **Horizon Kernel Flasher**
2. 选择 `/sdcard/Download/pudding-kernel/pudding-KernelSU-Ma6302-20261008-V2-diag.zip`
   （md5 `92c3d4e858969fc2d2cbbfe9b747b1d3`）
3. 刷入 → 重启

**不需要先刷回原厂**（V2 整块替换 boot，当前 Jianke 与原厂都是 ramdisk-less，AK3 走同一分支）。

### 🔑 卡住后的操作顺序（关键）

```
1. 等 40 秒（20s panic 超时 + 20s 重启缓冲）
2. 观察是否自动重启一次  → 自动重启 = panic 已触发 = 证据已落盘
3. 记录现象（是否自动重启 / 卡在哪一屏）
4. 音量下+电源进 fastboot → PC 刷回
     fastboot flash boot_a stock-boot.img   ← 建议本次刷真·原厂
5. 回滚开机后读：
     cat /data/local/bootlog/oops.log        ← panic 栈在这里
     cat /data/local/bootlog/kernel.log
```

**绝对不要**在卡住时反复强制重启（每次重启都会覆盖 oops 分区的机会）。

### 判读表

| 结果 | 含义 | 下一步 |
|---|---|---|
| 自动重启 + oops.log 有 panic 栈 | 🎯 取证成功 | 定位卡点模块 → 修复 |
| 卡住但不自动重启 | 死锁太深，watchdog 未触发 | 上 diag-deep / ftrace |
| **能开机进系统** | 卡死机制顺带救活 | 直接跑验收清单 |
| 卡在 <2s | V2 改动引入新问题 | 查 initcall_debug 时序 |

### V1 验收清单（若 V2 意外能开机，用这份）

- [ ] `uname -r` = `6.12.93-android16-6-4k-Ma6302`
- [ ] 已加载模块 ≈ 660，`modules_missing.txt` 为空
- [ ] `symbol_errors.txt` 为空
- [ ] **WiFi 能连**（头号指标，验 ABI）
- [ ] 蓝牙 / 音频 / 相机 / 充电 / 信号正常
- [ ] KernelSU 管理器能识别（`su` 可用）

### 回滚资源（机内 + PC 都可用）

```
/sdcard/Download/pudding-kernel/stock-boot.img   md5 5157f9020b45b51ec1701c79cda9b93d  ← 真原厂 6.12.69
/sdcard/Download/pudding-kernel/boot_a.img       md5 5329fec9e9c154913673065734662067  ← Jianke 6.12.111（当前）
```

**绝对禁止整包 `flash_all`** —— 会触发 ARB，不可逆。

---

## ⚠️ 刷入风险与已知疑点（刷前必读）

### 风险 1：`kernel_dtb` 被丢弃（中等）

实测原厂 boot 结构：

```
原厂 stock-boot.img : HEADER_VER 4, KERNEL_SZ 41,576,960, KERNEL_DTB_SZ 20,237,792
Jianke boot_a.img   : HEADER_VER 4, KERNEL_SZ 91,199,456, KERNEL_DTB_SZ 69,925,952
```

AK3 脚本会 `rm -f kernel_dtb`，改用新内核内置 DTB。

**已验证那 66.7MB 是垃圾**：`kernel_dtb` 的 DTB 头声明 `totalsize = 72` 字节，
其余 69,925,880 字节（**99.9999%**）是零填充。所以删除它是对的。

**但仍属未实测** —— 若开机异常，这是第一嫌疑点。
（Jianke 与 Nanally 都这么做且能用，先例支持。）

### 风险 2：双重 KSU（低，且已找到缓解证据）

**首先更正一条之前的错误记录**：root **不在 boot 分区，在 `init_boot`**。

实测 `init_boot_a` 的 ramdisk 内容：

```
header v4, KERNEL_SZ 0, RAMDISK_SZ 3,079,899 (2.94MB), lz4_legacy

  init             607 KB   ← SukiSU wrapper（替换了原 init）
  init.real       2.81 MB   ← 原始 init
  kernelsu.ko      390 KB   ← LKM 本体
  stock_image.sha1  40 B    ← 原厂镜像 sha1
```

`kernelsu.ko` 由 init wrapper 在启动时 `insmod`，然后才 exec `init.real`。
交叉验证：当前跑纯官方内核（boot md5 = stock）时，`dmesg` 里 `kernelsu(O)` 以**模块**形式存在。
→ **root 与 boot 分区无关。刷 boot 不会掉 root。**（用户 2026-10-07 指正，已核实）

**于是产生本风险**：我们的内核把 KSU **编进内核**（实测 Image 有 **811 处** `ksu_*`/`KernelSU` 符号），
而 init_boot 仍会 `insmod kernelsu.ko` → 潜在双实例。

**缓解证据**：`kernelsu.ko` 内建自检，实测字符串：

```
/__w/SukiSU-Ultra/SukiSU-Ultra/kernel/runtime/ksud_integration.c
KernelSU may be already loaded in kernel, skip!
```

→ SukiSU 官方已考虑"内核里已有 KSU"的场景，会主动跳过。

**残留不确定**：不知其检测手段（若只查 `/sys/module/kernelsu` 则检测不到内置 KSU）。
最坏结果也只是 .ko 加载失败，**内置 KSU 仍在，root 不会掉**。

### 风险 5：`boot` 与 `init_boot` 的版本配对（低）

`init_boot` 里存了 `stock_image.sha1`（原厂镜像哈希，供 restore 用）。
刷了我们的 Image 后，boot 不再是原厂 → **`ksud boot-restore` 会拒绝工作**。

这**不影响功能**（restore 只是用来还原的），但要知道：
想回官方内核，用 Horizon 刷 `stock-boot.img`，**不要**依赖 `boot-restore`。

### 风险 3：隐藏模块伪造属性（信息性，非阻塞）

设备上 `flash.locked=1` / `verifiedbootstate=green` 是**假的**，由
`YH_YC`（月虹一键隐藏）+ `playintegrityfix` + `tricky_store` 在 property 层伪造。

**真实值**（取自 `/proc/bootconfig`，resetprop 改不到）：

```
androidboot.vbmeta.device_state = "unlocked"   ← BL 实际已解锁
androidboot.verifiedbootstate   = "orange"     ← 解锁设备的正确值
androidboot.slot_suffix         = "_a"
androidboot.veritymode          = "enforcing"
```

**教训：在这台设备上永远不要用 `getprop` 判断 BL/验证启动状态，要读 `/proc/bootconfig`。**

### 风险 4：ARB 状态 UNKNOWN（按高危处理）

`ro.boot.anti` 为空 → **未知**，不是"没有 ARB"。
因此：**不要刷任何比当前版本旧的官方整包**，不要用"降级"当回滚手段。
本项目的回滚只用 `boot` 分区，不碰 ARB。

---

## ⚠️ 重要提醒

### 回滚资源（PC 已断开，机内即可自救）

| 文件 | md5 | 用途 |
|---|---|---|
| `/sdcard/Download/pudding-kernel/stock-boot.img` | `5157f9020b45b51ec1701c79cda9b93d` | **当前状态**（官方 6.12.69 + 内置 KSU），首选回滚目标 |
| `/sdcard/Download/pudding-kernel/boot_a.img` | `5329fec9e9c154913673065734662067` | Jianke 6.12.111 时期备份（旧基线，一般不用） |
| `backup_full/`（工作区内） | 见各 .md5 | 全分区备份（boot/init_boot/vendor_boot/dtbo/vbmeta） |

PC 侧同步副本：`D:\刷机\xiaomi 17\6.12内核编译\backup\`（md5 实测一致）。

### 刷机后

- 先看 `/data/local/bootlog/summary.txt`
- 首刷用 `diag-safe`，**不要**用 `diag-deep`（会拖慢启动）

### PC 端重编时的工具链环境

PC 当前**已断开**。重连后编译所需（WSL2 内）：

```bash
export TC=/root/pudding-kernel/toolchain
export PATH="$TC/clang-r536225/bin:$TC/rust/bin:$TC/build-tools/build-tools/bin:$PATH"
export RUSTC=rustc BINDGEN=bindgen LIBCLANG_PATH="$TC/clang-r536225/lib"
export LLVM=1 LLVM_IAS=1
export KIT_DIR=/root/pudding-kernel/pudding-kernel-kit
export WORK_DIR=/root/pudding-kernel
# 源码树与套件都还在，可直接 bash scripts/05-build.sh 增量重编
```

### 两条硬约束

1. **永远不要用 `getprop` 判断这台设备的 BL / 验证启动状态** —— 隐藏模块会伪造。
   要读 `/proc/bootconfig`。
2. **永远不要整包 `flash_all`** —— 会触发 ARB，不可逆。
   回滚只用 `boot` 分区。

---

## 🧭 故障分支表

| 结果 | 下一步 |
|---|---|
| ✅ 开机 + 硬件正常 | ABI 判断成立 → 进入功能迭代（阶段 5） |
| ⚠️ 开机但某硬件坏 | 看 `/data/local/bootlog/symbol_errors.txt` → 补 `EXPORT_SYMBOL` → PC 重编 |
| ⚠️ 关机再开机才正常 | 正常现象（KSU 首次装载），观察即可 |
| ❌ 卡二屏（过 logo 后重启） | 用 Horizon 刷回 `stock-boot.img` → `cat /sys/fs/pstore/*` → 分析崩溃栈 |
| ❌ 卡一屏（黑屏/卡 logo） | **第一嫌疑：kernel_dtb 被丢弃** → 刷回 `stock-boot.img`；查 `bootlog.txt` + `blackbox` 分区 |
| ❌ 完全黑屏 | 检查 Image 格式（PC 端跑 `08-verify-package.sh`）；用 Horizon 刷回 |

### 恢复阶梯（按代价排序，PC 已断开）

1. **Horizon Kernel Flasher 刷回 `stock-boot.img`** —— 机内即可，最快
2. Horizon 刷回 `boot_a.img`（Jianke 时期，旧基线）
3. 进 bootloader + PC fastboot：`fastboot flash boot_a stock-boot.img`
4. 进 fastboot 后 `fastboot boot <boot.img>` 临时启动测试（不写入分区）

> **root 相关的故障不在上表**：root 在 `init_boot`，刷 boot 不会掉 root。
> 若 root 真出问题，见「双 KSU」一节的处理方式，**不要动 boot**。

---

*Ma6302 ｜ 基于 2026-10-07 21:40 实测数据*