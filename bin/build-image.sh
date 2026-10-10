#!/usr/bin/env bash
# 在 alpha 上构建 golden 镜像，并把它启动时需要的产物准备好、记下哈希。
#
# 用法（从 Mac 上）：bin/sync.sh && ssh alpha 'bash ~/agent-harness-sandbox/bin/build-image.sh'
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH="$HOME/.local/bin:$PATH"   # mkosi 装在用户级，不走系统包
OUT=${OUT:-$HOME/ahsb-build}            # 必须在同步树之外，否则下次同步会把镜像抹掉
CACHE=${AHSB_CACHE_DIR:-$HOME/.cache/agent-harness-sandbox}
NPM_SOURCE="$ROOT/image-deps"
NPM_CACHE=${NPM_CONFIG_CACHE:-$(npm config get cache)}
NPM_ABI=$(node -p 'process.versions.modules')
BUILD_DIRECTORY="$CACHE/build"
NPM_PREFIX="$BUILD_DIRECTORY/npm-prefix/node-abi-$NPM_ABI"
NPM_STAMP="$NPM_PREFIX/.ahsb-manifest"
NPM_MANIFEST=$(
    {
        printf '%s\n' "node=$(node --version)" "npm=$(npm --version)"
        sha256sum "$NPM_SOURCE/package.json" "$NPM_SOURCE/package-lock.json"
    } | sha256sum | awk '{print $1}'
)
mkdir -p "$OUT" "$CACHE/mkosi" "$CACHE/pacman" "$BUILD_DIRECTORY" "$NPM_CACHE"

if [ ! -f "$NPM_STAMP" ] || [ "$(cat "$NPM_STAMP")" != "$NPM_MANIFEST" ]; then
    rm -rf "$NPM_PREFIX"
    mkdir -p "$NPM_PREFIX"
    cp "$NPM_SOURCE/package.json" "$NPM_SOURCE/package-lock.json" "$NPM_PREFIX/"
    NPM_CONFIG_CACHE="$NPM_CACHE" npm ci --ignore-scripts --prefix "$NPM_PREFIX"
    mkdir -p "$NPM_PREFIX/lib"
    mv "$NPM_PREFIX/node_modules" "$NPM_PREFIX/lib/node_modules"
    node "$ROOT/bin/link-npm-prefix.mjs" "$NPM_PREFIX" "$NPM_SOURCE/package.json"
    node "$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/install.cjs"
    NODE_PTY_PACKAGE=$(find "$NPM_PREFIX/lib/node_modules" -type f -path '*/node-pty/package.json' -print -quit)
    test -n "$NODE_PTY_PACKAGE"
    NODE_PTY=${NODE_PTY_PACKAGE%/package.json}
    npm run --silent --prefix "$NODE_PTY" install
    test -f "$NODE_PTY/build/Release/pty.node"
    node -e 'require(process.argv[1])' "$NODE_PTY"
    printf '%s\n' "$NPM_MANIFEST" > "$NPM_STAMP"
    echo "prepared npm prefix: $NPM_PREFIX"
else
    echo "reusing npm prefix: $NPM_PREFIX"
fi

mkosi --force --output-dir "$OUT" \
    --cache-directory "$CACHE/mkosi" \
    --package-cache-directory "$CACHE/pacman" \
    --build-directory "$BUILD_DIRECTORY" \
    --build-key - \
    --environment "AHSB_NPM_PREFIX=/work/build/npm-prefix/node-abi-$NPM_ABI" \
    build

# 直接内核启动（QEMU -kernel/-initrd）需要一个独立的 initramfs 文件，而 mkosi 的盘产物里
# 只有盘内的 /boot/initramfs-linux.img。debugfs 可以直接读 ext4，无需 root、无需挂载。
rm -f "$OUT/ahsb.initrd"
debugfs -R "dump /boot/initramfs-linux.img $OUT/ahsb.initrd" "$OUT/ahsb.root-x86-64.raw" >/dev/null

echo "--- 启动产物与哈希"
sha256sum "$OUT/ahsb.raw" "$OUT/ahsb.vmlinuz" "$OUT/ahsb.initrd" | tee "$OUT/SHA256SUMS"
echo "--- 记录：$(date -u +%FT%TZ)  host=$(uname -r)  mkosi=$(mkosi --version)"
