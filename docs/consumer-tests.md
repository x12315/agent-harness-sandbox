# 接入使用者自己的测试

测试由被测项目维护，sandbox 只负责 VM、输入注入和取证。推荐通过 `--project` 运行项目自身的用例；不要将它复制、软链或提交到 sandbox 的 `cases/`。

## 前置条件与信任边界

- 先复用已准备好的镜像或 Tart 基底；资产发现与恢复见 [assets.md](assets.md)。
- `--project` 在发起机需要 Node.js，用来生成输入快照；无新增 npm 依赖。
- **只接入已审查的可信项目。** Linux 的 `env`、`post.sh`、`assert.sh` 和 Tart 的 `assert.sh` 在宿主执行，不在 VM 中。`--project` 不将不可信宿主脚本变成安全代码。
- Linux vmspawn 无网卡；Tart 默认 NAT。Tart 禁止宿主共享与查看器的边界不变，GUI 仍需要已登录的 guest 桌面。

## 在使用者仓库创建用例

```text
my-project/
├── src/...
└── tests/sandbox/smoke/
    ├── cmd            # 必填：guest 命令
    ├── target         # 可选：linux-vmspawn（默认）、macos-tart、linux-tart
    ├── push           # 可选：要送入 guest 的项目文件
    ├── assert.sh      # 可选：宿主断言，参数 $1 为本次产物目录
    ├── env            # 仅 vmspawn：可信宿主配置，如 CPUS、RAM
    ├── post.sh        # 仅 vmspawn：VM 尚在运行时的可信宿主检查
    └── display        # 仅 Tart：cli（默认）或 headed
```

`cmd` 的示例（一行，Linux 与 macOS 均可执行）：

```sh
test -s /tmp/ahsb-push/input.txt && printf 'consumer smoke passed\n'
```

`push` 示例：

```text
src/input.txt:/tmp/ahsb-push/input.txt
```

规则：

- 源路径相对 **使用者项目根目录**，不是 sandbox 根目录；只传输清单列出的单文件。
- 源/目标条目使用 ASCII 字母、数字、`_`、`-`、`.`、`/`；每行 `源:目标`，空行和 `#` 开头注释可用。项目根目录本身可以包含空格。
- 目标限定在 guest 的 `/tmp/ahsb-push/` 内；拒绝绝对源路径、`.` / `..` 路径段、符号链接和越界输入。清单采用 LF 换行。
- 三种 backend 共用 `push`；`macos-push` 仅为既有 macOS 用例兼容保留。
- Linux 外部用例不接受 `env` 中的 `PUSH`；使用声明式 `push`，以便完整快照与校验。
- 用例目录中的普通文件会一起暂存（包含宿主断言的辅助脚本），不要在其中存放秘密、构建产物或 `node_modules`。

`assert.sh` 示例：

```bash
#!/usr/bin/env bash
set -euo pipefail
D=${1:?usage: assert.sh <run-dir>}
test "$(< "$D/guest/tmp/ah.rc")" = 0
grep -q 'consumer smoke passed' "$D/guest/tmp/ah.out"
test -s "$D/project-source.sha256"
```

宿主脚本要读辅助文件时使用 `$AHSB_CASE_DIR`（暂存的用例目录）和 `$AHSB_INPUT_ROOT`（暂存的项目输入根）；不要假定 cwd 是项目根，也不要依赖原始 checkout 的未声明文件。guest 看不到这些宿主环境变量或目录。

## 运行

```bash
# Mac 发起，alpha 执行 Linux vmspawn；使用者项目无需在 alpha 预先 clone/sync
REMOTE=alpha /path/to/agent-harness-sandbox/bin/test.sh \
  --project /path/to/my-project smoke

# Linux 本机，无需 SSH 到自己
EXECUTION=local /path/to/agent-harness-sandbox/bin/test.sh \
  --project /path/to/my-project smoke

# Apple Silicon Mac：用例 target 写 macos-tart 或 linux-tart
# 先在当前 shell 设置 TART_BASE_VM、TART_SSH_KEY、TART_KNOWN_HOSTS
EXECUTION=local /path/to/agent-harness-sandbox/bin/test.sh \
  --project /path/to/my-project smoke
```

一次调用的流程：

1. 在发起机仓库外生成独立快照，仅包含选定用例和声明输入，生成 SHA-256 清单。
2. 本机直接将快照交给对应 runner；远端先校验 sandbox 的 `bin/`、`mock/` 与发起机一致，再校验输入快照的完整文件清单。
3. 将输入注入一次性 guest，执行命令、收回产物、运行使用者断言。
4. 清理发起机和远端暂存目录，保留本次测试证据。失败/断言失败也会清理；远端 runner 被 SIGKILL 或机器掉电时无法承诺清理。

远端 sandbox 不匹配时返回失败，不启动 VM、不自动更新 checkout。先协调 `bin/sync.sh`，或设置 `DEST` 为独立的匹配 sandbox checkout；不要在别人运行时覆盖目录。外部项目不会被安装到远端 sandbox 的 `cases/`。

## 依赖与产物

依赖策略见 [artifact-policy.md](artifact-policy.md)：通用稳定工具来自 base，频繁安装的包复用包管理器 cache，项目源码通过 `push`。有 Linux 原生依赖的制品必须在目标平台准备，显式传入；不要将 Mac `node_modules` 给 Linux guest。Linux guest 无法现场下载依赖。

原生终端准备由 sandbox 生产者负责：Linux vmspawn 基底提供 Xvfb、xwininfo、原生 xterm 与字体，并用 `linux-native-terminal-smoke` 验证窗口和 PTY；macOS GUI seed 用既有 `macos-iterm-smoke` 验证 iTerm 基础窗口/终端。使用者负责声明应用所需的终端、Pi 版本/API、环境以及 clone/fork 等业务断言；基础 smoke 不能替代应用兼容测试，不能为了掩盖应用兼容问题升级基底 Pi。guest SSH 环境与本地原生终端路径是不同场景，使用者应明确选择真实身份/环境，不以伪造 SSH 变量代替本地窗口测试。

Tart 的 SSH/SCP 生命周期由 Sandbox 管理：每次用例使用私有连接 socket 复用握手，退出时关闭自己的连接并移除临时目录；固定客体主机公钥、专用私钥、非交互及无宿主共享限制保持不变。消费方不需要自备 SSH/SCP 包装器。连接复用不是权限授权，也不改变客体调用进程的身份。

macOS ready 的 GUI 授权验收主体是 guest 的 `sshd-keygen-wrapper`，既有 smoke 用 System Events 新建 iTerm 窗口并输入命令；它不证明 iTerm 子进程发出的 Apple Events 或 iTerm 自身 AppleScript API 已授权。使用者必须按实际调用进程验收，缺权限交给管理员决定；runner 不写 TCC、SIP 或申请宿主权限。

选择非默认 Linux 镜像时，在 alpha 的可信 shell 中用 `OUT=/absolute/prepared-image EXECUTION=local /path/to/matching-sandbox/bin/test.sh --project /path/to/project <id>`；项目必须已准备在该 Linux 主机，或通过既有快照工具暂存。Mac 远端入口的 `DEST` 只选择匹配源码 checkout，不选择镜像；不会把发起机任意 `OUT` 转发到远端。基底依赖与验收范围见 [local-vm-routes.md](local-vm-routes.md)。

退出码和本次位置以输出为准：

```text
case=smoke rc=0 dir=/.../runs/smoke/<run-id>
assert=smoke PASS
```

公共证据是 `guest/tmp/ah.{out,err,rc}` 和 `project-source.sha256`。Linux 还保存完整串口和 mock 请求，远端 Linux 调用额外保存 `source.sha256`（sandbox 源码）；Tart headed 保存 `gui.png`。Linux 可收回 guest `/tmp/ah-artifacts/`；Tart 当前不提供通用附件下载，不应假定与 vmspawn 相同。具体 backend 差异见 [cases.md](cases.md) 和 [local-vm-routes.md](local-vm-routes.md)。

远端证据留在远端的 `OUT/runs/`，需要时由使用者通过 SSH/SCP 取回；`--project` 不自动复制整个运行目录。显式 `RUN_DIR`、`OUT` 只在本机调用时由环境传入；远端使用远端 runner 的默认路径。新接入仍应先跑一个最小 smoke，再执行项目自己的完整测试。
