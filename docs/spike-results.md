# task-2 spike 结果：四条判据（gate）

结论：**四条全部通过**，`systemd-vmspawn` 这条路成立，不退回 Incus。

执行环境：alpha（Arch，systemd 261，QEMU 11.1 + OVMF），**执行者是当前登录的非 root 用户，全程无 sudo**。

镜像：task-2 的最小 Arch 系统（mkosi 构建，`Bootable=no` + `ElTorito=no`），
盘里只有一个 root 分区，走**直接内核启动**。

启动命令（原始）：

```bash
systemd-vmspawn --machine=ahsb-spike \
  --image=mkosi.output/ahsb.raw --image-format=raw \
  --linux=mkosi.output/ahsb.vmlinuz --initrd=/tmp/ahsb-initrd.img \
  --cpus=2 --ram=2G --console=interactive --register=no --pass-ssh-key=no
```

---

## ① 非特权用户能启动全 VM —— 通过

上面的命令由非 root 用户直接执行成功，qemu 以普通用户身份拉起，guest 侧 systemd 走到
multi-user：

```
[  OK  ] Started Getty on tty1.
[  OK  ] Started Serial Getty on hvc0.
[  OK  ] Reached target Multi-User System.
Arch Linux 7.2.7-arch1-1 (hvc0)
[root@archlinux ~]#
```

## ② guest 内只有 loopback，没有网络设备 —— 通过

串口上执行（原始输出）：

```
[root@archlinux ~]# ip -o link show; echo NETDEV=$(ls /sys/class/net | tr '\n' ' ')
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
NETDEV=lo
```

**NETDEV 只有 lo** —— 这不是"策略禁止联网"，是这台 VM 里根本不存在网卡。

## ③ host ↔ guest 的 vsock 双向通信 —— 通过

guest 侧能力检查：

```
[root@archlinux ~]# ls -l /dev/vsock
crw-rw-rw- 1 root root 10, 261 Sep 28 07:39 /dev/vsock
[root@archlinux ~]# lsmod | grep -c vsock     → 4        （vsock 传输已加载）
[root@archlinux ~]# socat -hh | grep -ci vsock → 2        （socat 支持 vsock 地址族）
```

宿主侧用 python 监听 AF_VSOCK 18788；guest 侧发起并收到回包：

```
宿主 /tmp/vsock_host.log:  LISTENING GOT:GUEST_TO_HOST_OK  REPLIED
guest 的 /tmp/vsock_reply:  REPLY=HOST_TO_GUEST_OK
```

**双向都通了。** 这是 golden 镜像里 mock 模型服务的通道。

## ④ 串口 console 能执行命令并取回产物 —— 通过

上面所有命令都是通过 serial console（hvc0）下发的；输出通过 console 回收。
产物回收另测一条：guest 内 `printf ... | socat ... > /tmp/vsock_reply`，再 `cat` 读回，
内容与宿主发出的字节一致（见 ③）。

---

## 顺带踩到并解决的坑（已写进 docs/host-prereqs.md）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Failed to enter user namespace for virtiofsd: Operation not permitted` | 这台机器上 virtiofsd 起不来 | 放弃 `--directory=`，改 `--image=` + 直接内核启动 |
| `mkfs binary for vfat not available` | 没装 dosfstools，做不出 UEFI ESP | `Bootable=no` + `ElTorito=no`，走直接内核启动 |
| mkosi 的盘产物里没有独立 initrd | mkosi 只把 initramfs 放在盘内 `/boot` | 用 `debugfs` 从 root 分区里 dump 出来（无需 root、无需挂载） |
| `ModuleNotFoundError: No module named 'pefile'` | mkosi 的沙箱会丢弃外部 PYTHONPATH，其内核识别步骤要 pefile | 装进用户级 site-packages + `~/.local/bin/python3` shim；有 root 时可换成 `pacman -S python-pefile` |
| 串口上没有登录提示 | vmspawn 给的是 **hvc0**，不是 ttyS0 | skeleton 里同时覆盖 `serial-getty@hvc0` 与 ttyS0 |
| `'/usr/bin/ssh-keygen' failed` | vmspawn 默认要生成并注入 SSH key | `--pass-ssh-key=no` |

## 尚未验证，留给后续 task

- `--ephemeral`（每条用例的临时 CoW 快照）—— 需要在 task-4 的 runner 里实测。
- 带外抢救的真实场景（把 guest 内的东西打死后再进去）—— task-5 的两个 gate 之一。
- TUI 保真度（真 pty 下的 resize/SIGWINCH/alt-screen）—— task-5 的另一个 gate。
