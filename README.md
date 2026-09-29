# agent-harness-sandbox

给 agent harness（Claude Code / pi）用的专用测试沙盒。目标：**除网络层外全部可测**。

一条用例 = 一台**没有网卡**的完整虚拟机。

- 唯一对外通道是 **vsock** 上的 mock 模型服务 —— 不是"策略禁止联网"，是这台 VM 里根本不存在网络设备。
- 带外靠**串口 console** 与 `--console=native` 的 **QEMU monitor**：guest 内的东西把系统搞死了也能拿现场。
- 每条用例从同一个镜像、同一个状态开始，`--ephemeral` 保证退出即丢弃。

## 分工

| 位置 | 角色 |
| --- | --- |
| Mac `~/Desktop/agent-harness-sandbox` | **唯一真相源**（git）：mkosi 配置、skeleton、薄脚本、用例定义 |
| 一台 Linux 主机（本文档里叫 `alpha`，只是个 ssh 别名，可用 `REMOTE=` 覆盖） | **构建与运行**：mkosi 造镜像、systemd-vmspawn 起 VM；不放真相源 |

同步用 `bin/sync.sh`（tar over ssh；alpha 上没装 rsync）。构建产物落在 alpha 的 `~/ahsb-build/`，不属于同步树。

## 为什么是这套引擎

| 需求 | 机制 |
| --- | --- |
| 物理级 airgap | 不给 VM 挂网卡（不是 netfilter 规则） |
| 完整主机 | mkosi 造的完整发行版 + systemd，不是最小 rootfs |
| 带外抢救 | 串口 console + `--console=native` 的 QEMU monitor |
| 零特权测试路径 | `/dev/kvm`、`/dev/vhost-vsock` 权限都是 666，测试用户不需要任何 root 等价能力 |
| 每条用例干净起点 | `systemd-vmspawn --ephemeral`（临时 CoW 快照，退出即丢弃） |
| 带外真正可用 | `--console=native` 下 QEMU monitor 多路复用在同一 console 上（`Ctrl-A c`）—— guest 内核 panic 之后仍能取到状态 |

**为什么不用别的**：microsandbox 的 guest 是最小 rootfs（无 systemd、无带外通道），不满足"完整主机"；
Incus / E2B / agent-substrate 同样给全 VM，但要 root daemon 或 K8s，测试用户的权限收敛只能靠
`incus-admin`（root 等价）或 restricted project 的额外工程。详见 `docs/decisions.md`。

## 目录

```
mkosi.conf            golden 镜像的声明式定义（task-3）
mkosi.skeleton/       烧进镜像的静态文件：vsock shim、sshd 配置、AppArmor 档（task-3）
mock/mock_llm.py      确定性 mock 模型 API（Anthropic + OpenAI 双协议，逐请求写 JSONL）
bin/sync.sh           把仓库同步到 alpha
bin/build-image.sh    在 alpha 上构建 golden 镜像（task-3）
bin/run-case.sh       一条用例的完整生命周期（task-4）
cases/                用例定义（task-5..7）
docs/                 决策记录、清理记录、盲区声明
```

## 前置条件（别人 clone 下来要能跑，需要什么）

| 需要 | 说明 |
| --- | --- |
| 一台 Linux 主机（KVM 裸机，或开了嵌套虚拟化） | `/dev/kvm`、`/dev/vhost-vsock` 可读写；systemd ≥ 260（`--ephemeral`）；QEMU + OVMF。**不需要 root** |
| 一个 ssh 可达的别名 | 本文档统一写作 `alpha`，只是本机的别名；`REMOTE=<你的别名> bin/sync.sh` 可覆盖 |
| 构建期有外网 | mkosi 装包 + npm 装两个 harness；**运行期完全不需要网** |
| （可选）你自己的 `~/.agents/AGENTS.md` | 有它，指令层用例验证的是**你的真实指令层**；没有则用仓库里的中性夹具，用例照样全绿 |

本仓库在 macOS 上维护、在 Linux 上构建与运行；Mac 侧只需要 `git`、`ssh`、`tar`。

## 测试身份

测试一律以**发起者本人**（当前登录的非 root 用户，uid 1001）身份跑，不引入专用账号。
零特权的保证来自加在每条用例上的 `NoNewPrivs`（连 `sudo` 都拒绝以 root 运行），
而不是来自账号 —— 证据与残余风险见 `docs/BLINDSPOTS.md` 第四节。

## 用法

```bash
# 1. 把仓库同步到 alpha（Mac 是真相源）
bin/sync.sh

# 2. 构建 golden 镜像（首次，或改了 mkosi.conf / skeleton / postinst 之后）
ssh alpha 'bash ~/agent-harness-sandbox/bin/build-image.sh'

# 2.6 零特权验收：整条测试路径套上 NoNewPrivs（连 sudo 都拒绝以 root 运行）
ssh alpha 'cd ~/agent-harness-sandbox && PRIVDROP=1 bash bin/acceptance.sh'

# 3. 跑一条用例（一条命令走完起 VM→等就绪→执行→收产物→销毁）
ssh alpha "cd ~/agent-harness-sandbox && bash bin/run-case.sh <case-id> '<一行命令>'"
```

用例**定义**在仓库里（`cases/<case-id>/`：`cmd` 与可选的 `assert.sh`/`post.sh`/`env`）；
用例**产物**落在 alpha 的 `~/ahsb-build/runs/<case-id>/`（同步树之外，`bin/sync.sh` 抹不掉），
具体清单见 `bin/run-case.sh` 头部注释。出问题先看同目录的 `console.txt`（串口全文）
与 `monitor.txt`（带外通道）。

## 状态

- [x] task-1 立项与骨架
- [x] task-2 Step-0 可行性 spike（gate）：四条判据全部通过，见 `docs/spike-results.md`
- [x] task-3 mkosi golden 镜像（见 `docs/golden-image.md`）
- [x] task-4 薄 runner + vsock 上的 mock 服务
- [x] task-5 两个 harness 绿色闭环与三处断言（见 `docs/cases.md`）
- [x] task-6 AGENTS.md 行为验证（见 `docs/instruction-layer.md`）
- [x] task-7 越界与破坏用例第一批（见 `docs/isolation-cases.md`）
- [x] task-8 权限收敛、清理与验收报告（见 `docs/acceptance.md`、`docs/BLINDSPOTS.md`）

## 已知盲区

- **真实网络层**：DNS、TLS 证书链、代理、跨机行为 —— 这是设计上的排除项，不是遗漏。
- **GUI / computer-use / 浏览器**。
- **多节点**与「让别的 agent 通过 API 自助申请沙盒」——那条路要 Incus / E2B / agent-substrate，且与"权限收敛到非 root 用户"有张力。

完整盲区清单见 `docs/BLINDSPOTS.md`。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/decisions.md` | 引擎选型与被否决的方案 |
| `docs/spike-results.md` | task-2 gate 的四条判据与原始证据 |
| `docs/cases.md` | 用例定义与三层断言 |
| `docs/instruction-layer.md` | 指令层验证的正反例、投影方式与不可测部分 |
| `docs/isolation-cases.md` | 越界/破坏用例、结论与每条用例暴露的盲区 |
| `docs/acceptance.md` | 从零复现的验收记录（环境、哈希、7 条用例结果） |
| `docs/BLINDSPOTS.md` | 盲区声明：测不到什么，以及为什么 |
| `docs/golden-image.md` | golden 镜像定义与验收 |
| `docs/host-prereqs.md` | alpha 前置条件、两处临时 hack、环境坑清单 |
| `docs/alpha-cleanup.md` | 上一版（microsandbox）产物的回收记录 |

## 许可

MIT（见 `LICENSE`）。
