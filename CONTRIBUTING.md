# 贡献指南

> 本仓用于**维护、升级、记录**小米 17 的自编译内核工程。
> 核心原则：**证据优先于解读。**

---

## 铁律

### 1. 一切结论必须有实测证据

不接受这些表述：

| ✗ 不接受 | ✓ 要这样写 |
|---|---|
| 「应该能开机了」 | `uname -r` = `6.12.69-android16-6-4k-Ma6302`，`boot_index` 365，模块 670 |
| 「性能有提升」 | 交叉配对 A/B，比值 bootstrap 95% CI 是否跨 1.0 |
| 「ABI 已经对齐」 | `Module.symvers` vs `abi.stg`：MATCH 10235 / DIFF 0 / MISSING 0 |
| 「社区都说这样」 | 引用来源 + 标注 `UNVERIFIED` |

**提交消息里的数字必须是命令输出，不是记忆。**

### 2. 未验证的写 `UNVERIFIED`，不知道的写 `UNKNOWN`

两者含义不同：

- `UNVERIFIED` —— 有假设但没测过（例：SPL 对齐的影响）
- `UNKNOWN` —— 完全没拿到数据（例：`fastboot getvar anti` 的值）

不允许用「应该差不多」填空。

### 3. 一次只改一个变量

加配置要**一项一个 fragment**，单独编译、单独验证、单独记录。
否则出问题无法定位。

### 4. 改前先备份，改后先回滚验证

任何刷机前确认：
- 回滚镜像已在 PC 上（fastboot 阶段读不到手机存储）
- `init_boot` 不动（root 补丁在那）

---

## 提交规范

```
[build] 升级上游到 <branch> @ <sha>        — 编译未验证
[flash] 实测开机成功 boot_index <N>        — 已上机验证
[cfg]   加 zram.fragment（zstd 默认）      — 单项配置改动
[docs]  ...                                — 文档
[fix]   修正 <xxx>                         — 修复
```

`[flash]` 类提交**必须带实测证据**（`uname -r`、`boot_index`、模块数、关键子系统状态）。

---

## PR 流程

```
main    ← 只放已验证可开机的版本，受 ruleset 保护
dev/*   ← 试验性改动
```

1. 从 `main` 切 `dev/<主题>`
2. 改完后本地跑 `./scripts/verify-abi.sh`（四项必须全过）
3. 开 PR 到 `main`，PR 描述里贴**命令输出**
4. 合并前确认：ABI 四项全过 + （若涉及内核改动）已上机验证

**不要直接推 `main`。**

---

## 目录约定

| 目录 | 放什么 | 不放什么 |
|---|---|---|
| `scripts/` | 构建/校验脚本 | 上游代码 |
| `config/` | 配置 fragment（增量） | 完整 `.config` |
| `docs/` | 文档 | 日志、临时产物 |
| `versions.lock` | 上游 pin（唯一真相来源） | — |

**绝不入库**（`.gitignore` 已覆盖）：上游源码树、`out/`、`*.img`、`*.ko`、
签名私钥（`*.pem` / `*.pk8`）、工具链、设备标识（序列号/IMEI）。

---

## 许可证

- **补丁类内容**：GPL-2.0-only（演绎作品，跑不掉）
- **`scripts/` `config/`**：MIT（独立原创）
- **`docs/`**：CC-BY-4.0

新加文件请按所在目录加 SPDX 行：

```sh
# SPDX-License-Identifier: MIT      （shell）
# SPDX-License-Identifier: MIT      （Python）
<!-- SPDX-License-Identifier: CC-BY-4.0 -->   （Markdown）
```

**收第三方补丁前先查许可证**（见 [`LICENSE-NOTICE.md`](LICENSE-NOTICE.md)）：
KernelSU 只有 `kernel/` 是 GPL-2.0-only，其余是 GPL-3.0-or-later；
GPL-3.0 不在 kernel.org 的 GPL-2.0 兼容集里。

保留原作者的所有 `Signed-off-by` 与 `Change-Id`，自己经手时再加一条自己的 sign-off。

---

## 文档风格

- 中文叙述，技术名词保留英文
- 每个结论紧跟证据（命令 + 关键输出行）
- 表格优于长段落
- 三级标题以内
- 文件开头写清「基于什么日期、什么状态的数据」

---

## 相关仓库

- [`Ma6302/xiaomi17-kernel-skills`](https://github.com/Ma6302/xiaomi17-kernel-skills) —— AI agent 的 skills（MIT）

**两仓必须分开**：本仓含内核派生内容（GPL-2.0-only），skills 仓是纯 MIT 原创。
许可证边界就是仓库边界。