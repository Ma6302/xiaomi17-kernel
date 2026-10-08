# ABI 校验方法论

> 这套方法在 2026-10-08 成功预测了「内核能否加载设备模块」，
> 四重校验的结论与实测结果完全一致。可作为每次迭代的**回归测试**。

---

## 为什么要做

GKI 设备上的厂商模块（`vendor_dlkm` 里 404 个 `.ko`）在加载时会校验
内核导出符号的 CRC（`modversions`）。任何一个符号的 CRC 不匹配，模块就拒载。

显示模块 `msm_drm.ko` 拒载 → 显示栈起不来 → **卡在第一屏**（正是三次失败的症状）。

**关键**：CRC 不是源码哈希，而是 `gendwarfksyms` 依据**结构体布局**递归推导出来的。
所以改一个**看似无关**的配置项（比如打开 `FUNCTION_TRACER`），
可能让 `struct module` 多两个字段，进而让 `kobject_uevent_env` 的 CRC 变化，最终导致显示模块拒载。

---

## 四重校验

### ① 全量符号 CRC vs GKI ABI 基线

拿构建产出的 `Module.symvers` 对比树自带的 `gki/aarch64/abi.stg`（libabigail 风格文本）。

```bash
# 我们的导出符号
grep -c . out/Module.symvers          # 19344

# 基线
grep -c 'crc:' kernel-61269/gki/aarch64/abi.stg   # 10235
```

解析 `abi.stg` 里 `elf_symbol {...}` 块的 `name` 与 `crc`，与 `Module.symvers` 逐项比对。

**本次结果**：
```
MATCH   : 10235
DIFF    : 0
MISSING : 0
对齐率  : 100.0000%
```

**注意归一化陷阱**：CRC 是十六进制字符串，比对前必须去掉 `0x` 前缀再去前导零。
错误写法 `"0xaebcaf80".lstrip('0')` → `"xaebcaf80"`，会导致 100% 假 DIFF。

---

### ② 设备真实模块的 `__versions` 段

这是**最硬的外部基准**，因为它直接来自设备上真正要加载的那个 `.ko`。

`modversions` 下，每个 `.ko` 的 `__versions` 节记录了它要求的所有符号 CRC：

```c
struct modversion_info {
    unsigned long crc;              /* 8 bytes */
    char name[MODULE_NAME_LEN];     /* 56 bytes */
};                                  /* 记录 = 64 bytes */
```

解析（纯 Python，手机端也能跑，见 `docs/` 附带的脚本思路）：

```python
# ELF64: 读 section header → 找 '__versions' → 按 64 字节切分
REC, NAMELEN = 64, 56
crc = struct.unpack_from('<Q', chunk, 0)[0]
name = chunk[8:8+NAMELEN].split(b'\x00')[0].decode()
```

**本次结果**（`msm_drm.ko`，851 符号）：
```
MATCH   : 701
DIFF    : 0        ← 关键
MISSING : 150
```

`DIFF = 0` 是重点：**凡是我们内核该提供的，CRC 全部一致。**

那 150 个 MISSING 已逐个验证归属**其他 vendor 模块**，不在 GKI ABI 表面内：

```
hdcp1_init              → hdcp_qseecom_dlkm.ko
altmode_register_client → altmode-glink.ko
drm_dp_dpcd_read        → drm_display_helper.ko
ipc_log_string          → altmode-glink.ko / bam_dma.ko / ...
```

所以判定标准应为 **`DIFF == 0`**，不是「对齐率 100%」。

---

### ③ BTF 结构体尺寸

用 pahole 比对关键结构体的字节数与成员数。

```bash
$PAHOLE -C module out/vmlinux | tail -3
# /* size: 1600, cachelines: 25, members: 75 */
```

**判据**（来自实测对照）：

```
能开机内核 (Jianke)   : struct module = 1600 字节 / 75 成员
失败版本 (带 ftrace)  : struct module = 1664 字节 / 77 成员
                         ↑ 多出 num_ftrace_callsites、ftrace_callsites
```

这是**定位根因**时最有用的一把刀：结构体尺寸不同 → 与结构体相关的符号 CRC 必然不同。

**溯源链**（本次实测确认）：
```
CONFIG_STACK_TRACER=y
  → select FUNCTION_TRACER          (kernel/trace/Kconfig)
  → CONFIG_FTRACE_MCOUNT_RECORD
  → struct module 里多出 2 个字段    (include/linux/module.h)
  → kobject_uevent_env 类型展开变化
  → gendwarfksyms 递归推出不同 CRC
  → msm_drm.ko 拒载 → 卡第一屏
```

---

### ④ 关键符号单点核对

挑几个「一眼能看出问题」的符号交叉验证：

```
kobject_uevent_env   0x8bb6d45c   ← 设备模块要求值，必须一致
kobject_uevent       0x3f4f361e
register_filesystem  0x76fa5f08
module_layout        0x797f2b3e
init_task            0x6951c290
```

---

## 构建侧的两个前提

这两个不满足，校验必然失败：

### 1. 必须 `source _setup_env.sh`

GKI 官方构建入口里有一行：

```bash
export KBUILD_GENDWARFKSYMS_STABLE=1
```

`scripts/Makefile.build:114` 会把它转成 `gendwarfksyms --stable`。
不用它 == 走 unstable 路径 == CRC 全错。

### 2. 必须不引入 ftrace

这条已写入 `README.md` 的铁律。根因见 ③ 的溯源链。

---

## 复现步骤

```bash
# 1. 编译完成后，拿到 out/Module.symvers 与 out/vmlinux
# 2. 跑全量对比（脚本见 scripts/verify-abi.sh）
# 3. 从设备拉一个真实模块做交叉验证
adb pull /vendor_dlkm/lib/modules/msm_drm.ko
# 4. BTF 结构体检查
$PAHOLE -C module out/vmlinux
```

---

## 判据速查表

| 指标 | 通过标准 | 说明 |
|---|---|---|
| 全量 CRC 对齐率 | **100%** | 10000 量级符号，DIFF 必须为 0 |
| `msm_drm.ko` DIFF | **0** | MISSING 允许（属其他 vendor 模块） |
| `struct module` | **1600 / 75** | 与能开机内核一致 |
| `kobject_uevent_env` | **0x8bb6d45c** | 与设备模块要求一致 |

四项全过 ≠ 必定开机（血统仍要正确），但**任何一项不过 = 必定不开机**。

---

*本文基于 2026-10-08 实测。*