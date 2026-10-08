# 构建步骤

> 全部参数出自 2026-10-08 实测成功的那次构建（6分19秒，error count 0）。
> 环境：WSL2 Ubuntu 24.04，i7-12700H 16 核可见，12GB 内存可用。

---

## 0. 前置条件

```bash
# 工具
git, make, python3, zip, curl

# AOSP prebuilt clang（必循：与 build.config.constants 的 CLANG_VERSION 一致）
#   clang-r536225
#   + rust 1.82.0.p2
#   + build-tools（内含 pahole，编 BTF 必需）

# 资源
磁盘：源码 ~1.9GB + 输出 ~2GB，建议预留 10GB
内存：12GB 可用实测够用（16 核满载）
时间：首次全量约 6~7 分钟
```

### 工具链目录约定

```
$TC/clang-r536225/bin          clang / ld.lld / llvm-*
$TC/rust/bin                   rustc / bindgen
$TC/build-tools/build-tools/bin  pahole（★ 关键）
```

---

## 1. 取源码（按 `versions.lock` 断言 SHA）

```bash
git clone --depth=1 --branch android16-6.12-2026-03 \
  https://github.com/cctv18/android_gki_kernel_common src

# ★ 断言 SHA 与 versions.lock 一致
EXPECT=58ee67741556c83c523f48518284c4a6b1ef31d6
ACTUAL=$(git -C src rev-parse HEAD)
[ "$ACTUAL" = "$EXPECT" ] || { echo "SHA 不匹配！expect=$EXPECT got=$ACTUAL"; exit 1; }
```

**验证项**（实测基线）：
```bash
head -6 src/Makefile          # SUBLEVEL = 69
head -1 src/arch/arm64/configs/gki_defconfig   # CONFIG_LOCALVERSION="-4k"
find src -path src/.git -prune -o -type f -print | wc -l   # 约 87186
```

---

## 2. 环境准备

```bash
export TC=/path/to/toolchain
export PATH="$TC/clang-r536225/bin:$TC/rust/bin:$TC/build-tools/build-tools/bin:$PATH"
export CC=$TC/clang-r536225/bin/clang
export LIBCLANG_PATH="$TC/clang-r536225/lib"
export RUSTC=rustc
export BINDGEN=bindgen
export LLVM=1
export LLVM_IAS=1

# ★ pahole 必须指向 AOSP prebuilt，否则 BTF 编不出来
export PAHOLE=$TC/build-tools/build-tools/bin/pahole
```

---

## 3. GKI 官方构建环境（★ 最容易被忽略的一步）

```bash
cd src
export ARCH=arm64
export BRANCH=android16-6.12
export KERNEL_DIR="$PWD"
export OUT_DIR=/path/to/out
export BUILD_CONFIG=build.config.gki.aarch64
export LLVM=1 LLVM_IAS=1
export SKIP_CP_KERNEL_HDR=1

. ./_setup_env.sh        # ← 这一行是核心
```

**它会提供什么**：

```bash
export KBUILD_GENDWARFKSYMS_STABLE=1     # ★ 缺这个 → CRC 全错
export KBUILD_BUILD_USER=build-user
export KBUILD_BUILD_HOST=build-host
export KBUILD_BUILD_VERSION=1
export TZ=UTC / LC_ALL=C
export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export TOOL_ARGS="LLVM=1 LLVM_IAS=1"
```

**自检**（必须打印出 `1`）：
```bash
echo "KBUILD_GENDWARFKSYMS_STABLE = ${KBUILD_GENDWARFKSYMS_STABLE}"
```

> ⚠ **不要**在脚本里写 `set -u`。`_setup_env.sh` 引用多个可能未定义的变量
> （`_SETUP_ENV_SH_INCLUDED`、`KLEAF_INTERNAL_NO_BUILD_CONFIG`、`BUILD_CONFIG_FRAGMENTS`），
> 在 `set -u` 下会立即 abort。

---

## 4. 生成配置

```bash
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"

# 用树自带的 defconfig，原样
make O="$OUT_DIR" ARCH=arm64 LLVM=1 gki_defconfig

# 改署名
./scripts/config --file "$OUT_DIR/.config" \
    --set-str LOCALVERSION "-android16-6-4k-Ma6302"
./scripts/config --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO

# 抑制 setlocalversion 追加的 '+'（LOCALVERSION_AUTO=n 时走 short 分支会无条件输出 '+'）
SLV=scripts/setlocalversion
cp -f "$SLV" "$SLV.bak"
sed -i 's|^[[:space:]]*echo "+"[[:space:]]*$|echo ""|' "$SLV"

# 两轮 olddefconfig，让 select 链收敛
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
make O="$OUT_DIR" ARCH=arm64 LLVM=1 olddefconfig
```

### 配置自检（★ 编前必须核对）

```bash
for k in GKI_HACKS_TO_FIX GKI_TASK_STRUCT_VENDOR_SIZE_MAX GENDWARFKSYMS \
         MODVERSIONS EXTENDED_MODVERSIONS CFI_CLANG SHADOW_CALL_STACK \
         FUNCTION_TRACER STACK_TRACER MODULE_SIG_FORCE DEBUG_INFO_BTF; do
  grep -E "^(CONFIG_${k}=|# CONFIG_${k} is not set)" "$OUT_DIR/.config" || echo "  $k = <absent>"
done
grep '^CONFIG_LOCALVERSION' "$OUT_DIR/.config"
```

**期望结果**（实测基线）：

```
CONFIG_GKI_HACKS_TO_FIX=y
CONFIG_GKI_TASK_STRUCT_VENDOR_SIZE_MAX=1024
CONFIG_GENDWARFKSYMS=y
CONFIG_MODVERSIONS=y
CONFIG_EXTENDED_MODVERSIONS=y
CONFIG_CFI_CLANG=y
CONFIG_SHADOW_CALL_STACK=y
# CONFIG_FUNCTION_TRACER is not set       ← 必须是 n
# CONFIG_STACK_TRACER is not set          ← 必须是 n
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_LOCALVERSION="-android16-6-4k-Ma6302"
```

**任何一项不符 → 停下来查，不要继续编。**

---

## 5. 编译

```bash
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) 2>&1 | tee build.log
```

**实测**：`make rc=0 elapsed=6m19s`，`error count = 0`。

---

## 6. 校验产物

```bash
IMG="$OUT_DIR/arch/arm64/boot/Image"
ls -la "$IMG"           # 41,896,448 字节
md5sum "$IMG"

# 版本串
strings "$IMG" | grep -m1 '6\.12\.69.*Ma6302'
# → Linux version 6.12.69-android16-6-4k-Ma6302 (build-user@build-host)

# vermagic（必须前段与设备一致）
strings "$IMG" | grep -m1 'SMP preempt'
# → 6.12.69-android16-6-4k-Ma6302 SMP preempt mod_unload modversions aarch64
```

> **vermagic 说明**：设备模块是 `6.12.69-android16-6-4k`，我们是 `...-Ma6302`。
> 这不影响加载 —— `modversions` 下 vermagic 只比较**第一个空格之前**的内容，
> 且 `file_system_type` 的 `-4k` 部分一致。真正决定加载的是符号 CRC，由 ABI 校验把关。

---

## 7. ABI 校验（★ 必须通过）

见 [`ABI-VERIFICATION.md`](ABI-VERIFICATION.md)。四项判据：

| 指标 | 通过标准 |
|---|---|
| 全量 CRC vs `gki/aarch64/abi.stg` | 100%，DIFF = 0 |
| `msm_drm.ko`（设备真实模块） | DIFF = 0 |
| `struct module` | 1600 字节 / 75 成员 |
| `kobject_uevent_env` | `0x8bb6d45c` |

---

## 8. 打包 AnyKernel3

```
包内容：
  Image                       （新内核）
  anykernel.sh                （devicecheck 自建）
  tools/{ak3-core.sh, magiskboot, busybox, magiskpolicy, fec, ...}
  META-INF/com/google/android/update-binary
  LICENSE
```

`anykernel.sh` 关键设置：

```sh
BLOCK=boot                # ramdisk-less 设备走 flash_boot 分支
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=1
do.devicecheck=1          # 注意：此 fork 未实现，需自建检查（见 FAILURE-LOG 坑 7）
device.name1=pudding
device.name2=canoe
```

**本版刻意不加的东西**：
- 任何 `patch_cmdline` 注入（保持单变量测试）
- 任何 ftrace / 诊断配置
- KernelSU（保持设备现有 LKM root）

打包后机械校验：

```bash
unzip -l pudding-cctv18-*.zip          # 应 18 个文件，无 .bak 残留
# 校验包内 Image 的 md5 与源文件一致
```

---

## 完整脚本

见 `scripts/build.sh`（可直接执行）。

---

## 常见编译错误

| 错误 | 原因 | 处理 |
|---|---|---|
| `_SETUP_ENV_SH_INCLUDED: unbound variable` | 脚本设了 `set -u` | 去掉 `set -u` |
| `load BTF from vmlinux: Invalid argument` | 系统 pahole 1.25 太旧 | 用 AOSP build-tools 的 pahole |
| `dwarf.h: file not found` | 缺 libdw-dev | `apt install libdw-dev` |
| Rust 相关错误 | rust 版本不符 | 用 AOSP prebuilt rust 1.82.0.p2 |
| `error: unable to read sha1 file of ...` | 用了 `--filter=blob:none` 又检出工作区 | 改用 `--depth=1` |

---

*本文基于 2026-10-08 实机构建。*