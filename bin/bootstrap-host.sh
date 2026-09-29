#!/usr/bin/env bash
# 需要 root 跑**一次**：把测试面收敛到一个非特权账号，并把两处临时 hack 换成发行版包。
#
#   sudo bash ~/agent-harness-sandbox/bin/bootstrap-host.sh
#
# 之后所有测试都以 harness 身份跑；root 只在镜像构建时（如果 mkosi 需要）再出现。
# 这个脚本是幂等的，可以重复跑。
set -euo pipefail

TEST_USER=harness
ADMIN_USER=${ADMIN_USER:-$(id -un)}   # 默认就是当前账号
REPO=/home/$ADMIN_USER/agent-harness-sandbox
DEST=/home/$TEST_USER/agent-harness-sandbox

echo "== 1. 专用非特权账号（不进 wheel / docker / incus-admin / libvirt）"
id "$TEST_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TEST_USER"
passwd -l "$TEST_USER" >/dev/null 2>&1 || true
loginctl enable-linger "$TEST_USER"

echo "== 2. ssh 入口：与管理员共用同一把公钥（测试账号不需要密码）"
install -d -m 700 -o "$TEST_USER" -g "$TEST_USER" "/home/$TEST_USER/.ssh"
install -m 600 -o "$TEST_USER" -g "$TEST_USER" \
    "/home/$ADMIN_USER/.ssh/authorized_keys" "/home/$TEST_USER/.ssh/authorized_keys"

echo "== 3. 把仓库与构建目录交给测试账号"
install -d -o "$TEST_USER" -g "$TEST_USER" "$DEST"
cp -a "$REPO/." "$DEST/"
rm -rf "$DEST/.git"
chown -R "$TEST_USER:$TEST_USER" "$DEST"
install -d -o "$TEST_USER" -g "$TEST_USER" "/home/$TEST_USER/ahsb-build"

echo "== 4. mkosi 换成发行版包；撤掉 pefile 的临时 shim"
pacman -S --needed --noconfirm mkosi
if pacman -Si python-pefile >/dev/null 2>&1; then
    pacman -S --needed --noconfirm python-pefile
    rm -f "/home/$ADMIN_USER/.local/bin/python3"
    echo "   （python-pefile 装好了，~/.local/bin/python3 这个 shim 已删除）"
else
    echo "   注意：仓库里没有 python-pefile —— mkosi 识别内核那一步仍会需要它。"
    echo "   兜底：保留 $ADMIN_USER 的 ~/.local 里的 pefile（构建镜像仍由该账号发起即可）。"
fi

echo "== 5. 核验：测试账号确实拿不到特权"
sudo -u "$TEST_USER" bash -lc 'id; echo "sudo: $(sudo -n true 2>&1 | head -1 || true)"; ls -l /dev/kvm /dev/vhost-vsock'

echo
echo "== 下一步：以 harness 身份跑验收 =="
echo "   ssh $TEST_USER@alpha 'rm -rf ~/ahsb-build && bash ~/agent-harness-sandbox/bin/acceptance.sh'"
