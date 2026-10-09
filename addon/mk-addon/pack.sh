# MK-Addon Magisk 模块打包脚本（在手机端或 WSL 里都能跑）
# 用法: sh pack.sh   -> 生成 mk-addon-<ver>.zip
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC"

VER="$(sed -n 's/^version=//p' module.prop)"
OUT="$SRC/mk-addon-${VER}.zip"

rm -f "$OUT"
# 只打包运行所需的文件（排除 README / 打包脚本自身）
zip -r "$OUT" \
    module.prop \
    install.sh \
    config.conf \
    service.sh \
    apply.sh \
    collect.sh \
    lib/ \
    -x '*.md'

echo "packed: $OUT"
ls -la "$OUT"