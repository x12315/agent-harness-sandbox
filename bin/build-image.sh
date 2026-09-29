#!/usr/bin/env bash
# 在 alpha 上构建 golden 镜像，并把它启动时需要的产物准备好、记下哈希。
#
# 用法（从 Mac 上）：bin/sync.sh && ssh alpha 'bash ~/agent-harness-sandbox/bin/build-image.sh'
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"   # mkosi 装在用户级，不走系统包
OUT=${OUT:-$HOME/ahsb-build}            # 必须在同步树之外，否则下次同步会把镜像抹掉
mkdir -p "$OUT"

mkosi --force --output-dir "$OUT" build

# 直接内核启动（QEMU -kernel/-initrd）需要一个独立的 initramfs 文件，而 mkosi 的盘产物里
# 只有盘内的 /boot/initramfs-linux.img。debugfs 可以直接读 ext4，无需 root、无需挂载。
rm -f "$OUT/ahsb.initrd"
debugfs -R "dump /boot/initramfs-linux.img $OUT/ahsb.initrd" "$OUT/ahsb.root-x86-64.raw" >/dev/null

echo "--- 启动产物与哈希"
sha256sum "$OUT/ahsb.raw" "$OUT/ahsb.vmlinuz" "$OUT/ahsb.initrd" | tee "$OUT/SHA256SUMS"
echo "--- 记录：$(date -u +%FT%TZ)  host=$(uname -r)  mkosi=$(mkosi --version)"
