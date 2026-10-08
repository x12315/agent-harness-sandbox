# VM 内浏览器调试用例

这组测试针对沙盒自己的需求：本机 VM 路由、客体内有头应用、可诊断的浏览器操作和退出后保留证据。测试站点是 `bin/browser-debug/server.mjs` 的 Node 标准库程序，不依赖 observer、其他业务项目或外部网站。

## 两条用例

| 用例 | 后端 | 浏览器显示 |
| --- | --- | --- |
| `browser-debug-headless` | Linux vmspawn | guest 内 Chromium headless |
| `browser-debug-headed` | Linux vmspawn | guest 内独立 Xvfb，真正的 Chromium X11 窗口 |

两条都使用固定 `agent-browser@0.38.2` 经 **CDP** 连接自己启动的 Chromium。站点和 CDP 只监听 guest 的 `127.0.0.1`，端口由操作系统分配；VM 仍没有网卡。不使用宿主浏览器、宿主 DISPLAY/X socket、VNC 查看器或宿主屏幕录制权限。

有头用例同时检查 X11 窗口树中存在 `Sandbox Browser Debug … Chromium`、进程启动未使用 headless 参数及浏览器截图。它不是完整 GNOME/Wayland 桌面测试，也不证明 macOS Aqua、Tart `display=headed`、iTerm 或其他浏览器可用。

## 准备与运行

Linux 镜像需按当前 `mkosi.conf` / `mkosi.postinst` 重新构建一次，预装 Chromium、Xvfb、xwininfo、字体和固定版本的 agent-browser。旧镜像缺少这些工具时明确失败，不在线安装或回退宿主。Linux 宿主侧断言需要 Node.js。

```bash
# 在 Linux 测试机；OUT 必须在源码树之外，并且不要覆盖其他使用者的镜像。
OUT=$HOME/ahsb-browser-images bash bin/build-image.sh
OUT=$HOME/ahsb-browser-images EXECUTION=local bin/test.sh browser-debug-headless
OUT=$HOME/ahsb-browser-images EXECUTION=local bin/test.sh browser-debug-headed

# 已构建镜像可复用；验收默认列表已包含这两条。
OUT=$HOME/ahsb-browser-images SKIP_BUILD=1 PRIVDROP=1 \
  bash bin/acceptance.sh browser-debug-headless browser-debug-headed
```

`EXECUTION=local` 仍启动无网卡 VM，并要求非 root 的 Linux 发起者，使用 NoNewPrivs。Mac 可用 `EXECUTION=remote` 调用匹配的独立远端 checkout；远端的 `OUT` 需设置为相应镜像目录。不要因共享远端目录源码不匹配而直接执行整目录同步。

夹具由各条 `env` 的 `PUSH` 经串口送入 guest 的 `/opt/browser-debug/`，不挂载宿主目录。修改站点、操作或断言不必重建已具备浏览器工具的镜像。这些 helper 在 `bin/browser-debug/`，属于远端入口所比较的 `bin/` SHA256 清单；guest 镜像仍需另外固定 `SHA256SUMS`。

## 实际检查什么

1. 创建 Chromium 私有 profile，等待其 `DevToolsActivePort`；用 agent-browser 接入该 CDP 端点并导航到客体本地站点。
2. 保存 DOM snapshot，以 label/role 定位输入框和按钮；输入并点击后断言页面回显来自 HTTP API 的结果。
3. 使用纯合成账户 `sandbox` 登录；打开第二个标签页并返回原页，断言实际 DOM 与两个标签页 URL。
4. 保存状态，关闭第一台浏览器，启动**另一份全新 profile**；先等待实际 DOM 显示未登录，再加载状态、刷新并断言已登录。
5. 主动制造 console 标记、未捕获页面异常、HTTP 503 和 socket 中断；同时检查页面状态、CLI 诊断、服务器请求日志及 HAR 中真实的 503 响应。
6. 等待不存在的元素，必须产生真正的定位超时；无效参数/不支持的命令不算通过。失败后仍能读 DOM 并截图。
7. 保存 PNG、HAR 与包含真实事件的 CDP trace。检查 guest 与宿主的证据断言，而不是只接受一个 `PASS` 标记。

每条 guest 操作由 `timeout 240` 限制；站点、显示服务和 CDP 启动各有短检查点。240 秒不包含 VM 引导、串口 PUSH 和证据回传，不能作为整个生命周期的总时限。浏览器为 guest root 运行而加 `--no-sandbox`，此处隔离边界是无网卡 VM，**不宣称 Chromium renderer 沙盒已启用**。

## 证据与失败诊断

Linux runner 额外归档存在的 `/tmp/ah-artifacts/`。本组文件在本次 `dir=` 下的 `guest/tmp/ah-artifacts/browser-debug/`：

| 文件 | 证据 |
| --- | --- |
| `commands.log`、操作 JSON、`dom.json` | 操作顺序、原始 CLI 结果、实际页面状态 |
| `tabs.json`、`restored.json`、`state.json` | 标签页与合成账户状态恢复；没有真实账号凭据 |
| `console.json`、`errors.json`、`network.json` | console、页面异常、网络请求 |
| `expected-timeout.json` / `.err` | 预期定位失败；脚本不把未知错误当作成功 |
| `network.har`、`trace.json`、`browser.png` | HTTP 响应、CDP trace 事件、渲染截图 |
| `headed-windows.txt`、`display-number`、`chrome-flags.txt` | 有头模式的 guest X11 窗口和配置 |
| `site-requests.jsonl`、浏览器版本、服务日志 | 与 UI/CDP 独立的 HTTP 请求及环境证据 |
| `summary.json` | 所有证据断言成功后生成的简表，不替代原始文件 |

出错先看 `guest/tmp/ah.err`、`commands.log` 和最后一份操作 JSON，再看 `chrome.log` / `xvfb.log`。失败也回传已产生的诊断文件；未停止的 trace/HAR 不保证有最终文件。退出清理仅针对本条创建的浏览器、站点、Xvfb 和 profile，VM 的临时盘由原 runner 丢弃。浏览器缓存/profile 不进入串口归档，以免掩盖故障或淹没回传缓冲。

## 快检查与覆盖边界

```bash
node --test tests/browser-fixture.test.mjs
```

该秒级测试仅用本机 Node HTTP 小夹具检查站点和证据验证器，**不会启动宿主浏览器**。合成证据的单测不算浏览器端到端通过，必须另跑上述 VM 用例并检查真实 PNG。

这里验证的是确定性的 browser-agent 调试操作基座，不调用模型，不证明 agent 的规划/语义正确性。尚未覆盖 TLS、真实网络、代理、外部 SSO/MFA、iframe、下载上传、权限弹窗、跨浏览器、长时间运行或 macOS/Linux Tart 的真实浏览器 GUI。历史八条 Linux 验收记录仍是历史结果，不能把新增两条自动算作已通过。

## 实测记录（2026-10-08）

在 alpha 独立源码副本和镜像目录中构建成功，使用 `EXECUTION=local` / NoNewPrivs 顺序运行：

| 用例 | guest / runner rc | 断言 |
| --- | --- | --- |
| `browser-debug-headless` | 0 / 0 | PASS |
| `browser-debug-headed` | 0 / 0 | PASS |
| 原有 `port-scan` | 0 / 0 | PASS；外部 TCP/DNS 不通，无新增预期外监听 |

浏览器版本：agent-browser 0.38.2、Chromium 153.0.8010.52（Arch Linux）。两份真实 PNG 已检查：可见输入回显、Signed in、HTTP 503 和 dropped=true；有头窗口树有 `Sandbox Browser Debug - Chromium`。运行后本次 VM 已清理。Node 站点/证据单测、dispatch、Linux history、Tart lifecycle 回归均通过；这不是完整十条 Linux 套件重跑，也不是 macOS/Tart 的浏览器验收。

原始证据根：`alpha:~/ahsb-build/ahsb-browser-debug-20261008T081209Z-7808/`。三个本次目录分别为 `images/runs/browser-debug-headless/20261008T084238Z-ZMkLZ6/`、`images/runs/browser-debug-headed/20261008T084702Z-CQo8SV/`、`images/runs/port-scan/20261008T093014Z-LU00fy/`；源码清单在各目录 `source.sha256`，镜像完整哈希在 `images/SHA256SUMS`。盘、内核、initrd 的 SHA256 前缀分别为 `a7fbd09b4bbba495`、`d02afb36d5f99390`、`13d84f64dba62155`。

首轮曾暴露 tmux 新 server 的默认 2000 行截断归档起点；guest 浏览器检查虽成功，runner 解码失败，**不计作该轮通过**。已保留失败目录和原始日志，改用完整 `vm.log` 字节解码、处理 PTY 的 CR/控制前缀，并增加失败退出清理与截断/坏归档回归。表格中的结果来自修复后的新一轮运行。
