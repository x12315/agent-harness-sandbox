# 准备并复用 macOS GUI 基底

面向需要在 Apple Silicon Mac 的 Tart guest 内运行 CLI、原生窗口和浏览器测试的开发者。目标是**首次准备时处理客体授权，日常从停机基底克隆后全程 CLI 执行**，不是承诺裸系统零图形配置或所有应用永远免授权。

## 先确认是否需要准备

已有成熟基底和分发归档时，先用 `bin/locate-assets.sh` 发现本机配置，再按 [资产发现与复用](assets.md) 从本机或 alpha 恢复。只有工具升级、权限主体变化或已有基底确实不满足用例时才执行本文准备流程。分发镜像的 guest-user RPC、公钥注入及摘要见 `assets/catalog.json`；准备期权限与日常测试权限仍严格区分。

## 基底需包含什么

- 固定的 macOS、Node、pi、iTerm、agent-browser 和浏览器版本；iTerm 首次运行所需的 Command Line Tools 也要装完。
- 专用客体账户、SSH 公钥及已核验的客体 ED25519 主机公钥；FileVault、自动登录与私有账户配置须能在重新启动后进入未锁定的 Aqua。
- 客体屏幕录制、辅助功能和控制 System Events 的 Apple Events 授权。本次验证使用 SSH 的权限主体 `sshd-keygen-wrapper`；不能把 Terminal 中成功当成 SSH 已获授权。
- 客体显示睡眠、系统睡眠和屏保不会中断无人值守测试；不恢复准备时的窗口，不保留调试 LaunchAgent。
- 应用首次启动询问和更新策略已配置。固定测试版本不应在日常用例中临时下载或升级。

凭据、授权状态和配置好的 VM 全部留在私有目录。不要改 SIP、写 TCC 数据库、申请宿主权限或把镜像入库。不是给所有程序开放所有权限：相机、麦克风、全磁盘访问等未用于这些用例，不在 ready 结论内。

### iTerm 的首次更新询问

本次从新克隆验收时发现 iTerm 的 Sparkle 更新询问挡住了命令执行。可以在**准备用的独立 guest 克隆**中通过正常应用偏好固定它，不需日常点击：

```bash
defaults write com.googlecode.iterm2 SUEnableAutomaticChecks -bool false
defaults write com.googlecode.iterm2 SUHasLaunchedBefore -bool true
defaults write com.googlecode.iterm2 SUAutomaticallyUpdate -bool false
```

不要因此关闭 `.command` 文件执行警告或其他安全检查。当前 iTerm 用例通过 System Events 新建窗口并输入可信命令，不通过弹窗确认脚本文件，也不宣称 iTerm 自身 AppleScript API 已验收。

## 封存与新克隆验收

1. 在原 seed 的独立克隆内准备；不要改正在被别人使用的 VM。
2. 使用与正式 runner 相同的 SSH 主体检查截图、UI 操作、实际程序版本，处理必要的客体授权。
3. 清理本次调试服务与应用，用客体正常关机，确认 Tart 状态为 `stopped`。从该产物制作新的、独立命名的停机基底；保留旧版作回滚。
4. 设置本机私有环境文件（路径和 VM 名不入库）：

   ```bash
   export TART_BASE_VM=<stopped-gui-seed>
   export TART_GUEST_USER=admin
   export TART_SSH_KEY=<private-guest-key-file>
   export TART_KNOWN_HOSTS=<verified-ed25519-host-key-file>
   ```

5. 在项目 checkout 中，连续执行两轮下面的用例，每条指定不同且尚不存在的 `RUN_DIR`：

   ```bash
   bin/test.sh macos-pi-discovery
   bin/test.sh macos-desktop-smoke
   bin/test.sh macos-iterm-smoke
   bin/test.sh macos-browser-smoke
   ```

   每次由正式入口克隆、启动、取证、销毁。不要使用 VNC、查看器、人工授权或宿主被测应用。发现权限缺项就失败；回准备阶段制作新版本，不在日常 runner 内输入密码或批准弹窗。

6. 复核 `ah.rc`、`ah.err`、断言和三种 GUI 用例的真实 `gui.png`。有 PNG 或窗口计数不够：启动 logo、黑屏或询问框都不是验收通过。确认临时克隆已删除，基底仍停机，才标为 ready。

SSH 可能先于 Aqua 就绪。macOS headed wrapper 最多等 30 秒确认 console 用户与 GUI launchd 域，仍未就绪返回 42；此等待计入 `CASE_TIMEOUT`。窗口/输入操作还有各自的有界检查，截图失败返回 43。启动与 SSH 的预算仍与客体命令预算分开。

## 用例覆盖

| 用例 | 检查及证据 |
| --- | --- |
| `macos-pi-discovery` | 登录 zsh 的 Node/pi、RPC 命令发现 |
| `macos-desktop-smoke` | CoreGraphics 可见 Calculator 窗口、System Events 输入 `7+5=`、客体整桌面截图 |
| `macos-iterm-smoke` | System Events 新建并聚焦 iTerm 窗口、在真实终端输入 pi 命令、校验版本文件及退出码、客体截图 |
| `macos-browser-smoke` | 无头和有头分别打开内置 data 页面，以 label/role 输入和点击，检查 DOM；输出操作 JSON，核对真实 Chrome 窗口并采集整桌面截图 |

浏览器页面独立于业务项目，不请求模型、不需要外网。它是基底 smoke，不替代 Linux `browser-debug-*` 的登录态、HAR、trace、网络故障和诊断覆盖，也不证明模型规划能力。

## 本机验收记录（2026-10-08）

私有停机基底包含 macOS **26.6 / 25G72**、Node **24.21.0**、pi **0.87.1**、iTerm **3.7.3**、agent-browser **0.38.2**、Chrome for Testing **155.0.8059.39**、Command Line Tools **26.6**；SIP 保持启用。资源为 2 CPU、4096 MiB。

最终代码连续两轮、共八个全新克隆，四条用例均 guest rc 0、assert PASS；没有 VNC、授权点击、宿主查看器、宿主录屏/辅助功能授权。已读取实际截图，确认 Calculator `12`、iTerm 窗口与 pi `0.87.1`、Chrome 页面输入/回显；所有测试克隆已删除，基底保持停机。源码摘要和每轮产物路径记录在本机私有清单，不提交镜像或凭据。

保留的失败证据包括：第一版 iTerm 更新询问、`.command` 警告、Aqua 启动竞态，以及早期仅计数通过但截图仍是启动 logo 的轮次。这些不计入 GUI 正向通过。对应修正是准备期固定偏好、采用 System Events UI 路径、等待 Aqua，以及实际检查截图。

## 不在保证范围内

- 新程序、新权限主体、macOS/应用升级可能要求重新授权；应从独立准备克隆制作并验收新 seed。
- 本机克隆权限保留已验证，跨 Mac 导入后的 GUI/TCC 保留仍需重跑上述验收。
- pi `/clone-window`、`/fork-window` 的会话语义和 iTerm 自身 AppleScript API 没有因此通过。
- Tart 使用 NAT，不是 airgap；关闭查看器/共享不等于零资源影响或不能访问宿主网络服务。完整边界见 [本机 VM 链路](local-vm-routes.md)。
