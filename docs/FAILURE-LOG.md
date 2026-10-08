# 失败记录 — 三次卡第一屏

> 保留此文件的目的：**这些坑是花三天和三次刷机换来的，不要重复踩。**
> 全部数据为实机实测（2026-10-07 ~ 2026-10-08）。

---

## 症状（三次完全一致）

```
刷入 → 卡在开机第一屏（XBL splash logo）
     无声音、无振动、不自动重启（V1/V2）
     或 一分多钟后屏幕下缘闪一下 → 自动重启 → 循环（修复版）

恢复：音量下 + 电源（一次）→ 进 fastboot → PC 刷回 stock-boot.img
```

**关键观察**：XBL 层的按键仍可交互 → 不是全局硬死锁，是内核或显示链路挂起。

---

## 三次尝试对照

| | V1 | V2 | 修复版 | **成功版** |
|---|---|---|---|---|
| 日期 | 10-07 21:46 | 10-08 凌晨 | 10-08 16:48 | **10-08 19:02** |
| boot_index | 354 | 356 | 361/362 | **365** |
| 源码树 | AOSP 上游 | AOSP 上游 | AOSP 上游 | **cctv18** |
| SUBLEVEL | 93 | 93 | 93 | **69** |
| `GKI_HACKS_TO_FIX` | ✗ | ✗ | ✗ | **y** |
| `KBUILD_GENDWARFKSYMS_STABLE` | ✗ | ✗ | ✓ | **✓** |
| `FUNCTION_TRACER` | 开 | 开 | 关 | **关** |
| `struct module` | 1664/77 | 1664/77 | 1600/75 | **1600/75** |
| `msm_drm` DIFF | 471 | 471 | 0 | **0** |
| cmdline 注入 | 有 | 有 | 无 | **无** |
| KernelSU | 内置 | 内置 | 无 | **无** |
| 结果 | ✗ | ✗ | ✗ | **✅** |

---

## 坑 1：用了 AOSP 上游树（根本原因）

**症状**：卡第一屏，无任何内核日志。

**根因**：`aosp-mirror/kernel_common` 缺一整层小米/高通厂商适配。
即使把 ABI 对齐到 100%（修复版做到了），仍然开不了机。

**正确做法**：用 `cctv18/android_gki_kernel_common`。详见 [`WHY-CCTV18.md`](WHY-CCTV18.md)。

---

## 坑 2：`diag-safe.fragment` 破坏 ABI

**症状**：`struct module` = 1664 字节 / 77 成员（正常应为 1600/75）。

**根因**：我们自己的诊断 fragment 里有：

```ini
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_STACK_TRACER=y
```

而该文件的注释写着：

> 「不引入重负载调试 → 不影响启动速度与稳定性」
> 「**不修改任何既有符号 CRC** → 对厂商 404 个 .ko 零影响」

**注释与事实完全相反。**

完整因果链：

```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER              (kernel/trace/Kconfig:316-319)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 多 2 个字段：
        num_ftrace_callsites
        ftrace_callsites                (include/linux/module.h:542 的 #ifdef)
  → struct 从 1600/75 变 1664/77
  → 经 file_system_type->owner 进入 kobject_uevent_env 类型展开
  → gendwarfksyms 递归推出不同 CRC
  → msm_drm.ko 拒载 → 显示栈起不来 → 卡第一屏
```

**注意一个陷阱**：只关 `FUNCTION_TRACER` 无效 —— 会被 `STACK_TRACER` 用 `select` 拉回来。
必须先关 `STACK_TRACER`，再跑**两轮** `olddefconfig` 让 select 链收敛。

**正确做法**：**首版不要加任何 fragment**。用树自带的 `gki_defconfig`。

---

## 坑 3：裸 `make` 缺 `KBUILD_GENDWARFKSYMS_STABLE=1`

**症状**：CRC 全错，`msm_drm.ko` DIFF 高达 471。

**根因**：GKI 的正确构建入口是

```bash
. ./_setup_env.sh
```

它内部有一行关键导出：

```bash
export KBUILD_GENDWARFKSYMS_STABLE=1
```

`scripts/Makefile.build:114` 会把它转成 `gendwarfksyms --stable`。
文档明说 `--stable` 特性 "not used in the mainline kernel" —— 也就是说，
上游主线 `make` 永远走 unstable 路径，出来的 CRC 与本设备不兼容。

**正确做法**：`source _setup_env.sh`，用它导出的 `TOOL_ARGS` 构建。

---

## 坑 4：`set -u` 与 `_setup_env.sh` 冲突

**症状**：

```
./_setup_env.sh: line 20: _SETUP_ENV_SH_INCLUDED: unbound variable
./_setup_env.sh: line 25: KLEAF_INTERNAL_NO_BUILD_CONFIG: unbound variable
```

**根因**：`_setup_env.sh` 里多处直接引用可能未定义的变量（`${BUILD_CONFIG_FRAGMENTS}` 等），
在 `set -u` 下立即 abort。

**正确做法**：构建脚本**不要**设 `set -u`。预定义 `_SETUP_ENV_SH_INCLUDED=""` 也无效
（会被后续变量继续绊倒）。直接去掉 `set -u`。

---

## 坑 5：系统 pahole 编不出 6.12 的 BTF

**症状**：

```
FAILED: load BTF from vmlinux: Invalid argument
```

**根因**：Ubuntu 24.04 自带 pahole 1.25，为 6.12 生成的 BTF 会被内核自带的
`resolve_btfids` 拒收。**这不是树不完整**——此时已经编译到 `LD vmlinux`。

**正确做法**：用 AOSP `build-tools` 里的 prebuilt pahole，并在 PATH 中优先。

> **绝不要**因为这个问题去关 `CONFIG_DEBUG_INFO_BTF` 掩盖真实的编译错误。
> 只在**精确命中**该报错时才考虑降级，且在日志里明确记录。

---

## 坑 6：诊断取证的三个错误结论（方法论教训）

这三次失败中，我们曾做出三个后来被推翻的判断。记录如下，避免重犯：

### 6.1 「内核至少存活 2.1 秒」—— 推翻

**当时的推理**：`mtdoops` 在 oops 分区留下了记录，说明内核跑到了能写 flash 的阶段。

**推翻**：实测 `mtdoops` 是**每轮内核在正常关机时写自己的日志**。
卡死轮没有关机路径，永远不会落盘。那条记录实际属于**健康轮次**（353）。

### 6.2 「有看门狗在工作」—— 修正为 PSHOLD 硬复位

**当时的推理**：修复版会自动重启循环，说明看门狗在起作用。

**修正**：blackbox 实测显示 `PM: Reset by PSHOLD`，
且 dmesg 里有 `Hard watchdog permanently disabled`。
是 **PSHOLD（电源键长按/PMIC 路径）硬复位**，不是看门狗。

### 6.3 「拿到内核日志了」—— 其实是别的轮次

**当时**：在 blackbox 的 361 段看到了正常的 init 日志。

**修正**：那是**刷机前 Jianke 轮**的运行日志，被本轮启动时 bootmonitor 归档进来。
判据：整段里 `Ma6302` 零匹配、`6.12.93` 零匹配。

**方法论教训**：解析取证分区时**必须用版本串/署名做归属判定**，
不能看到「有日志」就认为「是我们的内核写的」。

---

## 坑 7：`do.devicecheck=1` 是假防呆

**症状**：AnyKernel3 包里设了 `do.devicecheck=1`，但设备不匹配时**不会**中止。

**根因**：这个 AK3 fork 的 `tools/ak3-core.sh` **根本没有实现 devicecheck**
（`grep -c devicecheck ak3-core.sh` = 0）。设 `do.devicecheck=1` 只是写了个没人读的变量。

**正确做法**：在 `anykernel.sh` 里自行实现：

```sh
DEV_OK=0
if [ -f /proc/bootconfig ]; then
  SKU_LINE=$(grep -oE 'hardware[.]sku *= *"[^"]+"' /proc/bootconfig | head -1)
  echo "$SKU_LINE" | grep -qE '"(pudding|canoe)"' && DEV_OK=1
fi
[ "$DEV_OK" = "1" ] || abort "DEVICE CHECK FAILED"
```

---

## 坑 8：工具链的通道问题（非内核问题，但浪费时间）

| 现象 | 应对 |
|---|---|
| PC Agent 通道整条空返回 `Step error` | 重试通常恢复；先 `write` 脚本文件再 `process_start` 跑 |
| WSL 命令里的 `\| tail` 被 PowerShell 拦截 | 用 wrapper 脚本内部重定向 `> log 2>&1` |
| Windows 路径含空格 | 必须加引号：`"C:\Program Files\Python313\python.exe"` |
| PC 的 `adb devices` 空 | USB 调试未连接；改用 HTTP 传输（详见 `FLASH-AND-ROLLBACK.md`） |
| 手机端 `rm -rf` 被拦 | 安全策略，改用其它方式 |

---

## 一句话总结

> **血统决定能不能开机；ABI 校验决定模块能不能加载；两者都做对才成功。**
