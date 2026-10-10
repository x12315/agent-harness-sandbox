# 本机 VM 链路与客体有头测试

**本机链路指在本机启动 VM，不是直接在工作系统执行被测程序。** 项目仍持续迭代，版本固定规则见 README 的「版本与接口承诺」。

## 选择执行位置

| 用例 target | 主机与执行位置 | 入口 | 网络保证 |
| --- | --- | --- | --- |
| `linux-vmspawn`（缺省） | 远端 Linux，保持原路径 | `EXECUTION=remote bin/test.sh pi-turn` | guest 无网卡，vsock mock |
| `linux-vmspawn` | 本机 Linux，需 KVM/vsock 和已构建镜像 | `EXECUTION=local bin/test.sh pi-turn` | guest 无网卡；以非 root 用户、NoNewPrivs 执行 |
| `macos-tart` | Apple Silicon Mac 上的本机 macOS VM | `EXECUTION=local bin/test.sh macos-pi-discovery` | Tart NAT，不是 airgap |
| `linux-tart` | Apple Silicon Mac 上的本机 ARM64 Linux VM | `EXECUTION=local bin/test.sh linux-pi-discovery` | Tart NAT，不继承 vmspawn 的隔离保证 |

Linux vmspawn 默认 `remote`，Tart 默认 `local`。不支持的主机/位置组合明确报错，不自动切换到远端或裸跑。Tart 尚无远端执行入口。macOS 本机不能用 KVM 启动原 x86_64 Arch 镜像，须另备 Linux ARM64 Tart 基底；此路径与 vmspawn 的串口、PUSH、mock API 不通用。

本机 Linux 的 `OUT` 默认 `~/ahsb-build`，需已具备 `ahsb.raw`、`ahsb.vmlinuz`、`ahsb.initrd`。镜像配置和设备要求见 `docs/host-prereqs.md`；在 Linux 主机上完成构建后可直接运行，无需 SSH 到自己。共享资源和 mock 的并发正确性未验收，使用独立 checkout/产物目录并协调测试时间。

Tart 两种 guest 都需停机基底、启用 SSH、专用私钥、已固定的 ED25519 客体主机公钥，以及被测程序。macOS 前置条件见 `docs/macos-tart.md`；Linux guest 默认用户 `ubuntu`，macOS 为 `admin`，可通过 `TART_GUEST_USER` 指定基底账户。Tart runner 会核对基底 OS，防止将 Linux 用例放进 macOS VM。

```bash
export TART_BASE_VM=<prepared-arm64-linux-vm>
export TART_GUEST_USER=ubuntu
export TART_SSH_KEY=<private-key-file>
export TART_KNOWN_HOSTS=<verified-guest-host-key-file>
EXECUTION=local bin/test.sh linux-pi-discovery
```

## 有头应用只运行在 guest

Tart 用例增加 `cases/<id>/display`，值为 `headed`；缺省为 `cli`。两者都以 `tart run --no-graphics` 启动，不打开宿主 VM 查看器。`headed` 表示**guest 内有桌面与真实应用窗口**，不是让程序在宿主桌面运行。

- macOS seed 必须已配置可用、未锁定的 Aqua 会话。用例不会自动输入密码，也不会修改基底的自动登录设置。SSH 可用后最多再等 30 秒确认 Aqua，仍无客体 GUI 会话返回 guest rc 42；等待计入客体 `CASE_TIMEOUT`。
- macOS 截图与 Apple Events 授权须在**客体**预先完成；截图失败返回 guest rc 43，不申请宿主的屏幕录制/辅助功能权限。
- Linux Tart 当前支持 X11 桌面，需安装 `xdpyinfo` 和 ImageMagick `import`，guest 用户须有对应 X authority。`TART_GUEST_DISPLAY` 缺省 `:0`，只接受 guest-local 的 `:<number>[.<screen>]`，不使用宿主 DISPLAY，不转发宿主 X socket。Wayland 采集尚未支持。
- 用例 `cmd` 经 SSH 在 guest 中执行，完成后 guest 截图以 base64 返回并存为本次 `gui.png`；采集包含在客体命令超时内。
- `assert.sh` 是可信的宿主侧证据检查代码：只读产物，不在宿主打开被测应用或控制桌面。须检查窗口/DOM/会话等真实状态；存在 PNG 本身不是 GUI 正确性的充分证据。

示例 `macos-desktop-smoke` 在 guest 启动 Calculator，用 CoreGraphics 检查可见窗口，以 System Events 输入 `7+5=` 并采集 guest 截图。另有 `macos-iterm-smoke` 和 `macos-browser-smoke`；私有基底制作、反复克隆验收及范围见 [macOS GUI 基底](macos-gui-seed.md)。它需要已准备好的 GUI seed；`macos-pi-discovery` 的 CLI 成功不能替代它。截图收集的 PNG 签名检查只防止缺失/无效响应，不自动判断黑屏或具体窗口是否可见。

Linux vmspawn 的程序始终也在 VM 中。当前镜像加入 Chromium/Xvfb，`browser-debug-headed` 在 guest 私有 X11 显示服务运行浏览器，检查窗口、DOM 并保存浏览器截图/HAR/trace；步骤见 `docs/browser-debug.md`。这不等于完整原生桌面；`display=headed` 的整桌面自动截图契约仅属于 Tart，不能把它当作 vmspawn 的 GUI API。

## Linux 原生终端基底 smoke

`linux-native-terminal-smoke` 验证 sandbox 提供的 Xvfb、xwininfo、原生 xterm（postinstall 固定校验 `411-1`） 和 DejaVu 字体：在 guest 私有 X11 显示中创建可见 xterm 窗口，由其子 shell 在真实 PTY 上执行命令，收回窗口树、窗口映射状态、PTY、尺寸与软件版本。不是浏览器里的 JavaScript xterm，也不证明完整桌面、窗口管理器、SSH 或应用的 clone/fork 功能。脚本经 `push` 注入，不烧入基础镜像。

旧的默认 `~/ahsb-build` 可能缺少 GUI 包；源码配方包含工具不代表已选镜像包含它们。先检查已有启动三件套的版本与 smoke 证据；确实缺依赖时才在独立 `OUT` 构建一次，复用锁定 npm prefix 与包缓存，不覆盖共享运行树/镜像。Linux 主机上显式选择：

```bash
OUT=/absolute/prepared-image EXECUTION=local /path/to/matching-sandbox/bin/test.sh linux-native-terminal-smoke
```

保存三件套的 `SHA256SUMS`、配方摘要及本次 `dir=` 在 Git 外。测试以非 root 宿主用户和 NoNewPrivs 启动，guest shell 仍是镜像的 root；X11 与应用操作都在 guest，不申请宿主 GUI 权限。

## 避免干扰宿主工作的措施与边界

Tart runner 始终不挂目录或额外磁盘、不共享剪贴板/USB，且关闭音频，不打开查看器，不发送宿主系统热键。资源设置只针对本次克隆：默认 2 CPU、4096 MiB、固定显示尺寸、不自动 refit；`TART_CPUS` / `TART_MEMORY_MB` 可覆盖。运行进程用 `nice 10` 降低调度优先级。基底保持停机，不修改宿主系统设置，结束后只停机删除本次 VM。

这保证的是**被测桌面和应用操作不进入工作桌面**，不是「宿主绝对零影响」：VM 仍占用 CPU、内存和磁盘 IO，NAT guest 仍可能访问宿主网络服务。宿主側断言/控制脚本仍必须可信。不要用于不可信代码的安全隔离承诺。

若要求工作机资源完全不共用，使用另一台测试主机。若要求 Tart guest 无法访问宿主服务，需另行设计网络策略：Softnet 的宿主 root/SUID 或免密 sudo 授权及 DHCP 影响必须先由人批准，当前不启用；零提权替代是将 Linux 安全用例继续放在无网卡 vmspawn，或把 macOS 工作负载移到专用测试 Mac。它们不是 macOS 本机 NAT 的等价安全证明。

## 当前证据

- macOS 本机 CLI：已在就绪基底上真实运行通过，克隆清理完成。
- Linux 本机 vmspawn：已在 Linux 主机上以 `EXECUTION=local`、NoNewPrivs 运行 `pi-turn` 通过。不是在 macOS 上执行 Linux vmspawn 的结论。
- GUI 拒绝路径：本机 macOS seed 的 Aqua 会话未就绪时，真实返回 guest rc 42 并清理克隆，未回退到宿主桌面。
- macOS 原生 GUI 正向：最终私有停机基底上四条用例连续两轮通过；八次各用全新克隆，无 VNC 或日常授权点击。实际截图确认 Calculator、iTerm 和 Chrome 窗口；测试克隆均删除。
- Tart OS 分发、guest-only GUI 脚本、Aqua 有界等待、截图采集、拒绝缺项、超时/中断清理有模拟回归；**Linux Tart 正向链路尚未验收**，仍需独立 ARM64 Linux 基底。
