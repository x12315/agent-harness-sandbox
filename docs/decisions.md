# 决策记录

## 引擎：QEMU/KVM 全虚拟机 + mkosi 声明式镜像

选它的四条硬理由：

1. **物理级 airgap**：QEMU 命令行里根本不加网卡（没有 `-netdev`/`-device virtio-net`），VM 里没有网络设备。
   隔离不依赖任何策略正确性 —— 不是"我们相信 netfilter 规则没写错"。
2. **完整主机**：mkosi 造的是完整发行版 + systemd 的镜像，不是最小 rootfs。
3. **带外两条通道**：串口 console + QEMU monitor（monitor 挂在 runner 自己的 unix socket 上，见下方变更记录）。
4. **零特权测试路径**：`/dev/kvm` 与 `/dev/vhost-vsock` 权限都是 `crw-rw-rw-`，
   测试用户不需要任何 root 等价能力，root 只在建用户与构建镜像时出现。

环境前提（alpha 实测）：systemd 261（`--ephemeral` 自 260 起可用、`--image-format=qcow2` 自 260、
`--efi-nvram-state` 自 261）、QEMU 11.1 + OVMF 已装、`/dev/vhost-vsock` 存在。

## 被否决

| 方案 | 否决理由 |
| --- | --- |
| microsandbox（libkrun microVM） | guest 是最小 rootfs，没有 systemd，没有带外 console/monitor；用户态网络。已实测可用，但结构上给不了"完整主机 + 隔离强度"。 |
| Incus | 同样给全 VM + 容器层 + 快照 + ACL + 镜像仓库，但要常驻 root daemon；测试用户的权限收敛只能靠 `incus-admin`（root 等价）或 restricted project 的额外工程。 |
| libvirt（已在宿主装好） | `qemu:///system` 要 libvirt 组（root 等价）；`qemu:///session` 零特权但功能受限。同上，权限模型与收敛要求冲突。 |
| E2B runtime / Firecracker | 极简设备模型（无 PCI、无 UEFI），带外只有串口；要 root daemon + tap/netns；定位是"云沙盒 API"而非"可诊断的测试田"。 |
| agent-substrate / K8s agent-sandbox | 要集群与特权基础设施；适合多租户平台化，不是单机实验田。 |
| Docker + gVisor/Kata | 共享内核；docker 组是 root 等价。 |
| cloud image + 一次性 provisioning | 最快的起步方式，但不可复现、不可审计。保留作为 task-2 spike 的探路工具，不作为最终镜像来源。 |

## 更正：monitor 一直可用，所以回到 systemd-vmspawn

曾经把 runner 改成直接调 QEMU，理由是"vmspawn 把 QEMU monitor 藏在自己的内部 QMP socket 上
（`-chardev socket,id=charmonitor,fd=29`），`--console=native` 也拿不到"。**这个结论是错的，
而且错在方法**：我只看了 QEMU 命令行里那个内部 socket 就下了判断，没有实际按一次键。

实测（vmspawn 261，同一台机器）：

```
--console=native   →  vmspawn 以 -nographic 起 QEMU
tmux 里发 Ctrl-A c  →  出现 (qemu) 提示符
info status        →  VM status: running
```

那个 `charmonitor` 是 vmspawn **自己**用来管 VM 的 QMP 通道；`-nographic` 下 QEMU 另外把
monitor 多路复用到了 console 上，用户按 Ctrl-A c 就能进去。两者不冲突，我把它误当成了排他关系。

所以：

- **启动方式回到目标要求的 `systemd-vmspawn`**：`--console=native --ephemeral --register=no`。
- **monitor 由 console 上的 `Ctrl-A c` 提供**，`cases/out-of-band-monitor/post.sh` 就用它：
  把 guest 打到内核 panic → Ctrl-A c → `info status` / `info cpus` → `quit`。
- 想让 guest 侧是 ttyS0 而不是 hvc0，可以加 `--console-transport=serial`（本次没用）。
- 直接调 QEMU 的那段实现已删除。
