# xiaomi17-kernel

小米 17（`pudding` / 平台 `canoe` / SM8850）自编译 GKI 内核的**工程仓**。

本仓**不含内核源码树**，只含：pin 死的上游指认、构建脚本、配置增量、验证方法、与踩坑记录。

> 这是 **patch stack / 工程仓**，不是 `kernel_common` 的 fork。
> 上游源码在 `scripts/fetch-sources.sh` 运行时按 `versions.lock` 现取。

---

## 状态

| 项 | 值 |
|---|---|
| 最新可用版 | `pudding-cctv18-20261008.zip` |
| 实测结果 | **开机成功**（2026-10-08，boot_index 365） |
| 内核版本串 | `6.12.69-android16-6-4k-Ma6302` |
| 上游 | `cctv18/android_gki_kernel_common` @ `android16-6.12-2026-03` |
| 上游 commit | `58ee67741556c83c523f48518284c4a6b1ef31d6` |
| 设备 KMI | `android16-6-4k` |
| KernelSU | **未内置**（保留设备现有 LKM 模式 root） |

---

## 为什么是这棵树 —— 一句话

**能开机的第三方内核全部源自 `cctv18/android_gki_kernel_common`；Google 上游的 `aosp-mirror/kernel_common` 编出来的东西在这台机器上开不了机。**

本仓前三次尝试（V1 / V2 / 修复版）全部失败，换到 cctv18 树后一次通过。
详见 [`docs/WHY-CCTV18.md`](docs/WHY-CCTV18.md)。

```
aosp-mirror/kernel_common      ← 纯 AOSP，无厂商适配  ✗ 开不了机
    └─ cctv18/android_gki_kernel_common    ← 小米/高通适配层  ✓ 可开机
            ├─ Jianke 6.12.111
            ├─ Kokuban
            ├─ Picters
            └─ 本仓 ← 只用树自带 defconfig，零补丁
```

---

## 快速开始

### 依赖
```bash
# 需要：git, make, clang (AOSP prebuilt), python3, zip
# 磁盘：源码树 ~1.9GB + 构建输出 ~2GB，建议预留 10GB
# 内存：16 核 / 12GB 实测 6分19秒编完
```

### 构建
```bash
./scripts/fetch-sources.sh     # 按 versions.lock 取上游，断言 SHA
./scripts/build.sh             # 编译，产出 Image
./scripts/verify-abi.sh        # 四重 ABI 校验（必须通过）
```

### 打包与刷入
见 [`docs/BUILD.md`](docs/BUILD.md) 与 [`docs/FLASH-AND-ROLLBACK.md`](docs/FLASH-AND-ROLLBACK.md)。

```bash
fastboot flash boot_a stock-boot.img    # 回滚（PC 端执行）
```

---

## 目录 → 许可证

| 目录 / 文件 | 许可证 | 说明 |
|---|---|---|
| `scripts/` | MIT | 独立原创的构建脚本，非内核演绎作品 |
| `config/` | MIT | 独立原创的配置增量 |
| `docs/` | CC-BY-4.0 | 文档 |
| `versions.lock` | MIT | 数据文件 |
| 仓库其余部分 | **GPL-2.0-only** | 默认；补丁类内容（若有）适用 |

根 `LICENSE` 为 **GPL-2.0-only**（与上游内核一致）。
脚本可另按 MIT 使用 —— 见各文件头部 SPDX 行。

> 上游 `cctv18/android_gki_kernel_common` 的 `COPYING` 为
> `GPL-2.0 WITH Linux-syscall-note`，且明文写着 **version 2 only**。本仓取同一许可证。

---

## 目录结构

```
versions.lock                 # ★ 唯一真相来源：上游 URL + ref + commit SHA
config/
  README.md                   # 配置增量片段的规矩与红线
scripts/
  fetch-sources.sh            # 取上游并按 SHA 校验
  build.sh                    # 构建（含 GKI 官方构建环境 source）
  verify-abi.sh / .py         # 四重 ABI 校验
  analysis/
    parse-module-versions.py  # 从设备 .ko 提取 ABI 要求（851 符号）
analysis/
  01-config-comparison.md     # 三方 defconfig 对比（Jianke / 原厂 / cctv18）
  02-device-module-abi.md     # 设备真实模块的 ABI 要求
  03-splash-hang-analysis.md  # 卡第一屏完整分析（含 3 个被推翻的判断）
docs/
  WHY-CCTV18.md               # 根因：为什么必须用这棵树
  ABI-VERIFICATION.md         # 四重校验方法论（可复用于每次迭代）
  BUILD.md                    # 完整构建步骤与参数
  FLASH-AND-ROLLBACK.md       # 刷机与回滚
  FAILURE-LOG.md              # 八个坑（勿重复踩）
  device-facts.md             # 实机采集事实
  UPGRADE.md                  # 如何跟随上游升级
  CHANGELOG.md                # 版本记录
  CLEANUP-LOG.md              # 工作区清理记录（删除项与理由）
```

---

## 核心铁律

来自三次失败换来的教训，**违反任意一条都会开不了机**：

1. **必须用 cctv18 树**，不是 AOSP 上游树。
2. **必须 source `_setup_env.sh`**（提供 `KBUILD_GENDWARFKSYMS_STABLE=1`），裸 `make` 会生成错误的符号 CRC。
3. **不要加 ftrace 相关配置**（`FUNCTION_TRACER` / `STACK_TRACER` / `FUNCTION_GRAPH_TRACER`）——会让 `struct module` 从 1600/75 变成 1664/77，显示模块拒载。
4. **版本号要对齐原厂**（SUBLEVEL 69）。
5. **用 AOSP build-tools 的 pahole**，系统 pahole 1.25 编不出 6.12 的 BTF。

详见 [`docs/FAILURE-LOG.md`](docs/FAILURE-LOG.md)。

---

## 相关仓库

- [`Ma6302/xiaomi17-kernel-skills`](https://github.com/Ma6302/xiaomi17-kernel-skills) —— AI agent 的 skills 体系（MIT）。
  两个仓分开是因为**许可证边界就是仓库边界**：本仓含内核派生内容（GPL-2.0-only），skills 仓是纯 MIT 原创文档。

---

## 声明

- 本仓与小米、Google、Qualcomm 无隶属关系。
- 刷机有风险，自行承担。**刷前务必备份 `boot` 与 `init_boot` 到机外。**
- 所有实测数据均标注采集日期与设备状态；未验证项一律标注 `UNVERIFIED`。