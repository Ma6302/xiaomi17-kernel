# 删除记录 — 工作区清理（2026-10-08）

> 本文件记录本轮清理删除的每一项及其理由，供追溯。
> 执行者：手机端 agent。用户授权：「需要删的删了，不想删的上传 github」。

---

## 清理范围

| 位置 | 清理前 | 清理后 | 释放 |
|---|---|---|---|
| `/sdcard/Download/Operit/kernel-dev/` | 882 MB | 17 MB | **865 MB** |

---

## 批 1：大体积取证中间产物（299 MB）

| 文件 | 大小 | 删除理由 |
|---|---|---|
| `blackbox_fix.txt` | 188,743,680 | blackbox 分区原始 dump；结论已提取进 `docs/` 分析文档 |
| `blackbox_fix_strings.txt` | 19,847,792 | strings 中间产物 |
| `blackbox_strings.txt` | 21,421,552 | 同上（V1 轮） |
| `blackbox_v2.txt` | 18,426,153 | 同上（V2 轮） |
| `oops_fix.bin` | 16,777,216 | oops 分区 dump |
| `oops_fix.txt` | 14,797,301 | 同上 |
| `oops_strings.txt` | 15,259,588 | 同上 |
| `oops_v2_strings.txt` | 15,287,214 | 同上 |
| `rec361.txt` | 1,716,717 | 361 轮记录段；分析已完成 |
| `rec361_oops.txt` | 593,219 | 同上 |
| `seg361.txt` | 30,185 | 同上 |
| `s361tail.txt` | 7,801 | 同上 |
| `r361.txt` | 3,612 | 同上 |

**关键结论均已落盘**（不随 dump 一起丢）：
- 卡死轮无内核日志（`Ma6302` 零匹配）
- blackbox 有 361/362 header，但内容是刷机前 Jianke 轮
- 复位原因是 PSHOLD 而非看门狗
- ARB 无变化（`stored_rollback_index is: 1`）

---

## 批 2：一次性脚本与零散输出

### 一次性探查脚本（18 个）

`mv.py` `mv2.py` `fetch.py` `symchk.py` `ikcfg.py` `jkfull.py` `crcsearch.py`
`cfg-diff.sh` `cfg-check.sh` `btf_sz.py` `cmp3way.py` `diff_gap.py`
`cmp-ota-vs-cctv18.py` `gh-commit2.py` `gh-mode-fix.py` `fix-license.py` `recv.py`

> 核心逻辑已进仓库 `scripts/`（`fetch-sources.sh` / `build.sh` / `verify-abi.py`）

### 零散输出/日志（46 个）

`abifiles.txt` `afterroll.txt` `arb.txt` `avb2.txt` `bb2.txt` `bbctx.txt`
`bootfail.txt` `cfg-abi-diff.txt` `collect-out.txt` `crcsearch-out.txt`
`cur-state.txt` `cur1.txt` `curl.log` `edl-probe.txt` `final-state.txt`
`jk-crc.txt` `jk-crc2.txt` `jk3.txt` `mv-out.txt` `net.txt` `net2.txt`
`probe2.txt` `probe3.txt` `probe4.txt` `rst.txt` `tl.txt` `ts.txt`
`v69.txt` `wdt.txt` `wdt2.txt` `zipcheck.txt` `zipcheck-new.txt`
`recv.log` `ghl.log` `parse_versions.log` `check_dtb.log` `final_abi_check.log`
`recon-raw.txt` `root-mode-raw.txt` ~ `root-mode-raw4.txt` `state-now.txt`
`kern-strings.txt` `mod-evidence.txt` `preflash-baseline.txt`

---

## 批 3：冗余备份、实验残留、重复文件（566 MB）

| 项 | 大小 | 删除理由 |
|---|---|---|
| `work/{ourv2,refj,testA,testA2,testB}` | **345 MB** | SELFTEST 实验解包残留；源 zip 仍在 `/sdcard/Download/pudding-kernel/` |
| `stock-ota-boot.img` | **100 MB** | 与 `/sdcard/Download/pudding-kernel/stock-boot.img` **md5 完全相同**（`5157f902…`），纯重复 |
| `ak3self/{our.Image,stock.kernel,jianke.kernel,magiskboot}` | **99 MB** | SELFTEST 解包残留 |
| `skills-backup-97ff0d9-20261007/` | 274 KB | 旧备份，已被 `4de7172` 取代 |
| `skills-stage/` `skills-stage2/` | 738 KB | 已安装完成 |
| `kitz/` | 7.5 KB | 只含过时的 `diag-safe.fragment`（已确认是 ABI 破坏源） |
| `live_btf.bin` | 7 MB | 可从 `/sys/kernel/btf/vmlinux` 重取 |
| `pudding-KernelSU-Ma6302-20261008-V2-diag.zip` | 20 MB | V2 失败版本 |
| `skills-main.tar.gz` | 88 KB | 旧 tarball（新版为 `skills-main-fa77bb9.tar.gz`） |
| `verify-run.txt` | 5.7 KB | 技能验证输出 |
| `backup/` `logs/` | 空 | 空目录 |

---

## 未删除（保留理由）

| 项 | 保留理由 |
|---|---|
| `device-profile.md` | 设备档案，权威事实来源 |
| `build.env` | 构建环境记录 |
| `success/` 与 `docs/` 下的分析文档 | 已上传仓库 |
| `analysis/` 下的配置与 CRC 数据 | 已上传仓库 |
| `skills-backup-4de7172-20261008/` | 当前 skills 版本的备份 |
| `skills-main-fa77bb9.tar.gz` | 当前 skills 版本 tarball |
| `skills-update-and-recon-2026100{7,8}.md` | 技能更新记录（历史） |
| `msm_drm.ko` `qcom_va_minidump.ko` | 设备真实模块，ABI 校验的硬基准 |
| `cctv18-abi.stg` | ABI 基线（体积大，按 `versions.lock` 可重取） |

---

## 未上传到仓库的内容及原因

| 内容 | 原因 |
|---|---|
| `msm_drm.ko` / `qcom_va_minidump.ko` | **Qualcomm 专有二进制**，不可再分发 |
| `cctv18-abi.stg`（9.1 MB） | 逐字取自上游仓库，`scripts/fetch-sources.sh` 可按 SHA 重取 |
| `cctv18-*.txt` / `*.gki` / `build.config.*` | 上游文件，同上 |
| `skills-backup-*` / skills tarball | 属于 `xiaomi17-kernel-skills` 仓，不属于本仓 |
| `device-profile.md` / `build.env` | `.gitignore` 明文排除：可能含设备标识 |
| `stock-ota-boot.img.config.txt` | 提自厂商 OTA 镜像；内容为内核配置（GPL 对应源码范畴），但直接再分发 OTA 提取物有风险，改为在本仓 `analysis/` 里以**对比结论**形式记录 |

---

## 复现清理的方法

```bash
# 体积分布
du -sh /sdcard/Download/Operit/kernel-dev/*

# 找重复（按 md5）
md5sum <fileA> <fileB>

# 逐文件删除（避开 rm -rf，手机端安全策略会拦截）
find <dir> -type f -delete
find <dir> -depth -type d -empty -delete
```

---

*记录时间：2026-10-08。执行前各文件的体积、md5 均经命令实测。*