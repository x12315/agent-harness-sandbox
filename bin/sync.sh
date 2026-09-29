#!/usr/bin/env bash
# 把本仓库同步到 alpha。Mac 是真相源，alpha 只负责构建与运行。
#
# alpha 上没有 rsync，所以用 tar over ssh；远端先解到 .new 再整体替换，
# 避免旧文件残留，也不会碰到构建产物（那些落在 ~/ahsb-build/，不在同步树里）。
set -euo pipefail

REMOTE=${REMOTE:-alpha}
DEST=${DEST:-agent-harness-sandbox}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# 本机是真相源：每次同步前把 ~/.agents/AGENTS.md 投影成镜像夹具，
# 保证 alpha 上构建出的镜像用的是**真实**指令层而不是仓库里的旧副本。
if [ -f "$HOME/.agents/AGENTS.md" ]; then
    bash "$ROOT/bin/project-agents-md.sh" >/dev/null
else
    echo "警告：没有 ~/.agents/AGENTS.md，沿用仓库里现有的夹具" >&2
fi

# COPYFILE_DISABLE 抑制 macOS 的 ._ AppleDouble 伴生文件，--no-xattrs 去掉 xattr 头
COPYFILE_DISABLE=1 tar cz -C "$ROOT" --no-xattrs \
  --exclude .git --exclude build --exclude .DS_Store --exclude '._*' \
  --exclude 'mkosi.output*' --exclude 'mkosi.tools*' . \
  | ssh "$REMOTE" "
      set -e
      rm -rf ~/$DEST.new && mkdir -p ~/$DEST.new
      tar xz -C ~/$DEST.new
      rm -rf ~/$DEST && mv ~/$DEST.new ~/$DEST
    "

echo "synced $ROOT -> $REMOTE:~/$DEST"
