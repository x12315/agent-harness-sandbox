# macOS Tart 后端：运行已配置的测试 VM

面向在 Apple Silicon Mac 上验证 agent CLI 或原生应用行为的开发者。Tart 后端与 Linux vmspawn 后端共享用例入口和结果契约，**不共享网络隔离保证**。

## 基底 VM 前置条件

本机 Linux 路由、Tart 的 `display=headed`、GUI seed 要求及宿主干扰限制统一见 [本机 VM 链路](local-vm-routes.md)。Tart 默认关闭宿主查看器、音频、USB 和剪贴板；有头也只运行 guest 应用。

先在本机准备一台**停机**的 Tart macOS VM；`bin/test.sh` 只克隆它，不修改或删除它。基底需有 `admin` 账户、启用 SSH、在 `admin` 的 `authorized_keys` 中放入专用公钥，并已装好用例所需程序。当前 `macos-pi-discovery` 需要 pi 0.87.1 和 Node，走 guest 的登录 zsh 解析 `pi`；另有需要 GUI seed 的 `macos-desktop-smoke`，其真实正向链路及 iTerm GUI 用例尚未验收。可按 [Tart 官方快速开始](https://tart.run/quick-start/)取得 macOS 镜像，再在基底 VM 内完成账户和程序配置。

本项目**尚不提供经过验证的“裸 IPSW → ready VM”构建器**：实测 Packer 的 Setup Assistant 按键与 OCR 在 macOS 26.6 的账户页面失去同步。不要把构建脚本静态校验通过当成镜像已能自动制作。镜像安装、首次账户配置、系统更新均发生在后端边界之外；后端只承诺从已配置基底运行测试。

将客体 SSH 私钥与已核验的客体 ED25519 主机公钥分别保存在本机用户目录，权限设为 600；不要把密码、密钥、镜像、IPSW 或本机偏好提交到仓库。主机公钥应在自己控制的基底 VM 中核验后固定；每条克隆用例要求同一公钥，拒绝静默接受变化。前置检查在克隆前分别报告：`TART_SSH_KEY` 私钥不存在/为空/不可读、`TART_KNOWN_HOSTS` 主机公钥文件不存在/为空/不可读，或文件中没有固定的 ED25519 主机公钥；不会关闭 SSH 校验来绕过缺项。若使用第三方预制镜像，先替换默认凭据。

### 制作一次，重复克隆

开发者不需要每条用例重新安装 macOS：获得一份完成首次设置的私有基底后，每条用例由 Tart 克隆它。如果需在其他 Mac 上复用已配置基底，可用 Tart 自带的 `export`/`import` 传递 `.tvm` 文件，不依赖镜像仓库下载：

```bash
umask 077
mkdir -p "$HOME/.local/share/agent-harness-sandbox"
tart export <stopped-ready-vm> "$HOME/.local/share/agent-harness-sandbox/ready.tvm"
# 在目标 Mac 的本地私有目录：
tart import /path/to/ready.tvm <local-ready-vm-name>
```

`.tvm` 包含客体账户、SSH 授权、应用及可能的机密；只在受控位置私下传递，不能入库或公开发布。导入后仍须核验客体主机公钥、工具版本和 GUI 是否可登录。已在同一台 Mac 实测 `tart export` → `tart import` → 从导入基底克隆运行 `macos-pi-discovery`，断言通过且临时克隆清理；**跨机器迁移和 GUI 登录仍未验收**。

本机在 macOS 26.6 对 Lume 0.5.3 做过替代方案试验：从 IPSW 安装系统、离线建账户及 SSH 检查均通过，但原版在 `diskutil apfs updatePreboot /` 收尾失败；本地跳过该 Recovery 专用步骤后 CLI 报成功，实际 VNC 截图仍出现 “Update Mac Automatically” 和 “Accessibility” 设置页。仅将记录中的 26.5.2 版本标记改为 26.6 也未消除页面。因此**不能用 SSH 健康检查替代 GUI 基底验收，当前不将 Lume 纳入正式后端**；若今后重试，应从已安装的停机原始镜像克隆，再单独执行 `lume setup`，不要让一次配置失败删掉整台 IPSW 安装产物。

## 运行一条用例

在 **Mac** 上执行；Linux 用例仍需先 `bin/sync.sh` 同步到 alpha，macOS 用例不经过同步。

```bash
export TART_BASE_VM=<your-prepared-vm-name>
export TART_SSH_KEY="$HOME/.config/agent-harness-sandbox/id_ed25519"
export TART_KNOWN_HOSTS="$HOME/.config/agent-harness-sandbox/known_hosts"
bin/test.sh macos-pi-discovery
```

runner 从基底克隆出本次独立 VM，不挂宿主文件、关闭剪贴板与 USB，等 SSH 可用后以 guest 的登录 zsh 执行 `cases/<id>/cmd`，记录 `guest/tmp/ah.{out,err,rc}`、`vm.log`，停机删除临时 VM 后运行 `assert.sh <产物目录>`。命令行输出 `case=<id> rc=<n> dir=<path>`，退出码表示用例是否通过。默认产物在 Mac 的 `~/ahsb-build/runs/<id>/<UTC时间>-<pid>/`；`OUT` 和 `RUN_DIR` 可以覆盖。客体命令的 `CASE_TIMEOUT` 默认为 300 秒，须设正整数；超时返回 124、写入 `timeout.txt` 并销毁克隆。启动与 SSH 等待另有有限重试；这个变量不是整个 VM 生命周期的时限。当前基准用例只验证 pi 的 RPC 命令发现；**安装了 iTerm 不等于 iTerm GUI 用例已通过**。

用例选后端的最小契约：

| 文件 | 两个后端 | 差异 |
| --- | --- | --- |
| `cases/<id>/target` | 缺省 `linux-vmspawn`；显式 `macos-tart` | 每例只选一种环境 |
| `cmd` | guest 要执行的命令 | Linux `/work` 的 shell 一行；macOS guest 用户的登录 zsh 脚本 |
| `assert.sh` | 销毁 VM 后接收产物目录 `$1` | 公共 `guest/tmp/ah.{out,err,rc}`；串口/mock 仅 Linux 有 |

不要把 Linux `PUSH`、`post.sh` 或 vsock mock 当成 macOS API；它们仍是 Linux 后端能力。新的 GUI 用例应检查 guest 中实际窗口/进程和会话状态，并保存可复核的证据，而不只检查 `open` 的退出码。

在停机基底的临时克隆上用 Tart 无宿主窗口的实验性 VNC 验证过：客体启动停在密码登录页；手动输入已有客体密码后可截图看到 Aqua 桌面。之后 SSH `open` 用户目录下的 `Applications/iTerm.app` 返回成功、iTerm 进程存在，但实验性 VNC 的后续两次全帧截图均为黑色；不能区分 iTerm 窗口问题与实验性 VNC 渲染问题。因此**既不能声称基底会自动登录，也不能把 iTerm 进程当作窗口验收通过**。探针克隆已停机删除；正式 GUI 用例需独立解决登录和可复核的窗口截图。

## 隔离与授权

Linux vmspawn VM **没有网卡**；macOS Tart 目前使用默认 NAT：guest 可访问外网，且可能访问宿主服务。macOS 仅关闭目录共享、剪贴板、USB，适合行为测试，**不适合以 Linux airgap 的保证运行不可信代码**。Tart 的 `--net-host` 实测会调用 Softnet，需要给宿主 Softnet 二进制 root/SUID 或免密 sudo，并可能影响 DHCP；此项目不自行提权或自动启用。若需要更强网络隔离，先让人确认权限范围，再设计独立用例。

Linux acceptance（`bin/acceptance.sh`）目前只覆盖 Linux vmspawn；Tart 用例通过 `bin/test.sh` 单独验证。`macos-desktop-smoke` 的 guest 桌面、窗口和截图契约已入库，但本机基底实测在 Aqua 前置检查被拒绝（guest rc 42），真实 GUI 正向仍未通过；不能用 CLI 或模拟测试代替 GUI 结论。
