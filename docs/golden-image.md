# golden 镜像（task-3）

`mkosi.conf` + `mkosi.skeleton/` + `mkosi.postinst` 是这台"实验机"的声明式定义；
`bin/build-image.sh` 负责构建它，并把它启动时需要的三件产物与哈希记下来。

## 镜像里有什么

| 类别 | 内容 |
| --- | --- |
| 系统 | Arch Linux，完整 systemd（261/262 世代），journald、getty、preset 全套 |
| 工具 | bash、iproute2、socat、util-linux、kmod、tmux、jq、git、curl、ca-certificates |
| 内核 | `linux` 7.2.7-arch1-1 + mkinitcpio 生成的 initramfs |
| 被测对象 | **claude 2.1.283**、**pi 0.87.1**、**agent-browser 0.38.2**、**pi-web-ui 0.96.1**（版本与依赖 lockfile 在 `image-deps/` 中；`node-pty` 在 prepared prefix 和镜像导入后验证可加载） |
| 浏览器调试 | Chromium、Xvfb、xwininfo、DejaVu 字体；**agent-browser 0.38.2** 固定在 postinst。站点/操作通过 PUSH 送入，见 `docs/browser-debug.md` |
| 原生终端 | xterm（postinstall 固定校验 `411-1`），复用 Xvfb/xwininfo/DejaVu；生产者验证 `linux-native-terminal-smoke`，不承载使用者 clone/fork 断言 |
| 带外 | `serial-getty@hvc0`/`ttyS0` 免密登入 root（skeleton 的 drop-in） |
| 通道 | `vsock-mock-proxy.service`：把宿主 vsock 18788 桥成 guest 的 `127.0.0.1:18788` |
| 网络 | **没有网卡**。不是策略禁止，是这台 VM 里不存在网络设备 |

不装引导装载器（`Bootable=no` + `ElTorito=no`），走直接内核启动；原因见 `docs/host-prereqs.md`。

## 构建

```bash
bin/sync.sh && ssh alpha 'bash ~/agent-harness-sandbox/bin/build-image.sh'
```

构建期需要外网（pacman 装包 + npm 根据 `image-deps/package-lock.json` 准备固定版本的 harness、agent-browser 和 Pi Web UI，见 `[Build] WithNetwork=yes`）；
**运行期不需要任何网络**。构建脚本默认复用 alpha 的 mkosi/pacman cache、ABI-keyed prepared npm prefix 和 npm 自己的 `~/.npm/` cache。

产物落在 alpha 的 `mkosi.output/`（不进同步树）：

| 产物 | 用途 |
| --- | --- |
| `ahsb.raw` | 盘子（单个 root 分区） |
| `ahsb.vmlinuz` | 内核（mkosi 直接产出） |
| `ahsb.initrd` | initramfs —— mkosi 的盘产物里没有它，用 `debugfs` 从 root 分区 dump 出来 |
| `SHA256SUMS` | 上面三件的哈希 |

最近一次验收构建（2026-09-28T11:08:54Z，host kernel 7.1.11-arch1-1，mkosi 28~devel）：

```
ed45a7f10b4c9fcfeea7c0878f91732c6f5f23e9e95a90ebab10601e4fb19bd5  ahsb.raw
8ebc2c71271e000540f0a7545afd8e73504fcb724671f3d38c720b241842b901  ahsb.vmlinuz
83d4a69ac223af60c4912c0ecb984308779c582a447778cc793d037bc6e3f0c  ahsb.initrd
```

完整清单与每次运行的证据见 `docs/acceptance.md`。

## 验收（task-3 合同，实测通过）

启动：由 `bin/run-case.sh` 调 `systemd-vmspawn --console=native --ephemeral`，参数见
`docs/decisions.md` 的变更记录；本次验收用的完整命令行在 alpha 的 `/tmp/acceptance.log` 与
每条用例的 `vm.log` 里。

串口回放（原始）：

```
archlinux login: root (automatic login)
[root@archlinux ~]# systemctl is-system-running
running
[root@archlinux ~]# claude --version | tail -1; pi --version
2.1.283 (Claude Code)
0.87.1
[root@archlinux ~]# echo NETDEV=$(ls /sys/class/net|tr '\n' ' ')
NETDEV=lo
[root@archlinux ~]# systemctl is-active vsock-mock-proxy.service
active
[root@archlinux ~]# curl -s -m 8 http://127.0.0.1:18788/v1/models; echo CURL_RC=$?
{"mock":"vsock-shim-ok"}
CURL_RC=0
```

最后一条是整条通道的端到端证明：guest 里 `curl` 打到 loopback TCP → socat → vsock →
宿主侧 AF_VSOCK 监听，应答原路返回。宿主侧那次监听是个临时的 python HTTP 应答器，
正式实现是 task-4 的 mock。

`--ephemeral` 也在本条命令里用上了：VM 退出即丢弃临时快照，每条用例都从同一个镜像状态开始。

## 两个必须记住的坑

1. **unit 的启用要写 preset，不能写 postinst，也不能靠手放 `.wants` 软链。**
   mkosi 之后会跑 `systemctl preset-all`，把没有在 preset 里的 unit 一律 disable ——
   两种做法都被它抹掉了（都试过，软链那份已删）。唯一有效的是
   `mkosi.skeleton/etc/systemd/system-preset/99-ahsb.preset`。
2. **claude-code 与 node-pty 必须准备为与 Node ABI 匹配的前缀。** `bin/build-image.sh`
   在 alpha 通过 `image-deps/package-lock.json` 和 npm cache 生成 ABI-keyed prefix，并在导入 image 前验证 `pty.node`；当 Node ABI 或依赖 lockfile 变化时它会自动重建。
