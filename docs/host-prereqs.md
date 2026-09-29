# alpha 侧前置条件与被踩过的环境坑

这些是"换一台机器重来时要重新知道"的东西。目标态是全部零特权；当前有两处临时 hack 可以用 root 换掉。

## 必需且已满足

| 项 | 现状 | 说明 |
| --- | --- | --- |
| KVM | `/dev/kvm` 权限 `crw-rw-rw-` | 无组、无 root 即可用 |
| vhost-vsock | `/dev/vhost-vsock` 权限 `crw-rw-rw-`，`vhost_vsock` 已加载 | 宿主侧 AF_VSOCK 可用（实测 `AF_VSOCK_SOCKET_OK`） |
| systemd | 261 | `--ephemeral` 需 260+、`--image-format=qcow2` 需 260+、`--efi-nvram-state` 需 261 |
| QEMU | QEMU 11.1 已装 | runner 直接调它（`-kernel/-initrd/-drive/-serial/-monitor`） |
| mkosi | 用 `uv tool install --with pefile git+https://github.com/systemd/mkosi` 装在 `~/.local`（28~devel） | 见下面"临时 hack" |
| 打包缓存 | 宿主就是 Arch，mkosi 走宿主的 pacman 缓存 | 重复构建很快 |

## 当前的两处临时 hack（有 root 就能换掉）

1. **pefile 可见性**：mkosi 的沙箱会自建环境（丢弃外部 `PYTHONPATH`，也可能不设 `HOME`），
   而它的内核镜像识别步骤需要 `pefile`。现状是装进用户级 site-packages 并在
   `~/.local/bin/python3` 放了一个 shim。
   - 撤销：`rm ~/.local/bin/python3`
   - 干净替代：`sudo pacman -S python-pefile mkosi`

2. **mkosi 来源**：uv 从 git 装的 devel 版，不是发行版包。
   - 干净替代：`sudo pacman -S mkosi`（同时解决上面那条）

可选（本轮不需要，但做 UEFI 启动盘会需要）：
`sudo pacman -S dosfstools mtools` —— 本机没有 `mkfs.vfat`/`mcopy`，
所以造不出 FAT 的 ESP；我们改走直接内核启动绕开了它。

## 环境坑清单

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Failed to enter user namespace for virtiofsd: Operation not permitted` | virtiofsd 在本机起不来（宿主 userns 本身是好的：`unshare --user` 实测通过） | 放弃 `--directory=`，改用 `--image=` |
| `mkfs binary for vfat not available` | 缺 dosfstools | `Bootable=no` + `ElTorito=no`，直接内核启动 |
| 盘产物里没有独立 initrd | mkosi 把 initramfs 只放在盘内 `/boot` | `debugfs -R "dump /boot/initramfs-linux.img ..." ahsb.root-x86-64.raw`（无需 root、无需挂载） |
| `No module named 'pefile'` | 见上 | 见上 |
| 串口上没有登录提示就卡在 login | vmspawn 给的是 **hvc0** 而非 ttyS0 | skeleton 同时覆盖 `serial-getty@hvc0` 与 `serial-getty@ttyS0` |
| `'/usr/bin/ssh-keygen' failed with exit status 1` | vmspawn 默认生成并注入 SSH key | `--pass-ssh-key=no`（将来要用 ssh-over-vsock 再打开） |
| `Failed to connect to vsock:<cid>:22: No such device` | vmspawn 默认想通过 vsock 22 端口连 guest（guest 侧还没起 sshd） | 加 `--pass-ssh-key=no` 即可忽略；不影响 vsock 本身 |

## 端口与资源

- 宿主已有一个跑了 24 天的 Home Assistant VM（libvirt，约 3G RSS）。新测试床要避开它的资源峰值：
  16 核 / 31G，实测每台 spike VM 2 核 / 2G。
- 测试床用的 vsock 端口：18788（宿主侧 mock 模型服务）。

## 宿主上曾有的另一套测试床（已退役归档）

alpha 的 `~/alpha-testbed/` 曾经出现过**两套**互不相干的东西，容易搞混，现在都已处理完：

| 目录 | 来源 | 处理 |
| --- | --- | --- |
| 980M，含 `bin/ toolchain/ mock/ systemd/` | 本会话早期按 microsandbox 方案搭的测试床 | 已删除（12:04） |
| 92K，含 `harnesses.json cases/*.json runs/ msb-argv.json` | **另一套** microsandbox 风格脚本，2026-09-28 15:48 出现，不是本仓库脚本建的 | 已打包归档并移走 |

归档位置与哈希见 `docs/alpha-cleanup.md`。现在与项目相关的只剩 `~/agent-harness-sandbox/`
（同步树）与 `~/ahsb-build/`（镜像、mock 日志、证据、归档）。
