# agent-harness-sandbox

给 agent harness（Claude Code / pi）用的多后端测试项目。按用例选择 VM，而不是让不同 VM 假装有相同的隔离能力：

- **Linux vmspawn**：无网卡全 VM，vsock 模型 mock、串口和 QEMU monitor 带外取证；
  每例从镜像临时启动并丢弃。适合请求形状、指令层和越界用例。
- **Tart（macOS / ARM64 Linux）**：从已配置的本地 VM 克隆；每例经 SSH 执行、取证、销毁。
  默认 NAT **不是**物理 airgap。macOS CLI 已实测；Linux Tart 和 GUI 正向链路尚未实测通过。

**本机执行也在 VM 内，不在工作系统裸跑。** Linux 主机可选本机 vmspawn，Mac 可选本机 Tart；有头应用只使用 guest 桌面，runner 不打开宿主查看器。路由、GUI seed 和资源/网络边界见 [本机 VM 链路](docs/local-vm-routes.md)。

统一入口：`bin/test.sh <case-id>`。缺少 `cases/<id>/target` 时沿用 Linux 后端；
`target=macos-tart` / `linux-tart` 选择对应 OS 的本机 Tart。共同契约是退出码、产物目录与 `guest/tmp/ah.{out,err,rc}`，
不强行统一串口、mock 或 GUI 证据。

**使用边界：** 这是供可信项目编写用例的 CLI 测试床，不是接受任意第三方仓库的安全执行服务。Linux 用例的 `env`、`post.sh`、`assert.sh`，以及 macOS 用例的 `assert.sh` 都会在宿主执行；外部项目提供的用例定义必须先审查，不能把不可信脚本直接交给 runner。macOS 默认 NAT，也不能用于验证无网卡隔离。

## 版本与接口承诺

**项目仍在持续迭代中。** `main`、feature 分支及其他未打发布 tag 的提交，都不是接口保证版本；CLI 参数、用例格式和产物布局可能变化。

使用者应自行固定到一个明确的**已发布 tag**，不要把移动分支作为稳定依赖。升级 tag 前，自行复跑集成测试。尚无发布 tag 可用而需要提前接入时，请临时固定完整提交 SHA，但这不构成接口兼容承诺。

## 分工

| 位置 | 角色 |
| --- | --- |
| Mac `~/Desktop/agent-harness-sandbox` | **唯一真相源**（git）：Linux 构建配方、两个 runner 和用例定义；Tart 在本机运行 |
| 一台 Linux 主机（本文档里叫 `alpha`，只是个 ssh 别名，可用 `REMOTE=` 覆盖） | **Linux 后端构建与运行**：mkosi 造镜像、systemd-vmspawn 起 VM；不放真相源 |

同步用 `bin/sync.sh`（tar over ssh；alpha 上没装 rsync）。构建产物落在 alpha 的 `~/ahsb-build/`，不属于同步树。**共享机器先协调同步：这个脚本会替换整个远端目录。** 有其他 agent 使用时，准备独立的匹配 checkout，用 `DEST=<远端相对 HOME 的路径> bin/test.sh <id>` 选择它，不替换现有目录。

Linux 的统一入口在 `EXECUTION=remote` 时执行前比较本地与远端 `bin/`、`mock/` 和本条 `cases/<id>/` 的文件 SHA256（忽略 `__pycache__`）。文件缺失或内容不同就返回 2、不运行用例；成功核对的清单留在本次产物的 `source.sha256`。这比 Git 提交号更能发现未提交改动，但**不核验 guest 镜像、已经运行的 mock 进程或额外 PUSH 文件**，这些被测输入仍须单独固定版本。直接调用 `bin/run-case.sh` 或 `bin/acceptance.sh` 不作跨机器比较。

## Linux 后端为什么用 vmspawn

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
bin/run-case.sh       Linux 用例原有生命周期（仍可在 alpha 直接调用）
bin/test.sh           统一入口，按 cases/<id>/target 和 EXECUTION 分发
bin/run-tart-case.sh  两种 Tart guest：克隆 → 执行/guest GUI → 取证 → 销毁
bin/run-macos-case.sh 兼容旧的 macOS 入口
cases/                用例定义（Linux 缺省；macOS 显式写 target）
docs/                 决策记录、清理记录、盲区声明
```

## 前置条件（别人 clone 下来要能跑，需要什么）

| 需要 | 说明 |
| --- | --- |
| Linux 用例：一台 Linux 主机（KVM 裸机，或开了嵌套虚拟化） | `/dev/kvm`、`/dev/vhost-vsock` 可读写；systemd ≥ 260（`--ephemeral`）；QEMU + OVMF。**不需要 root** |
| macOS 用例：Apple Silicon Mac | macOS 13+、Tart、已配置且停机的本地 macOS 基底 VM；前置条件见 `docs/macos-tart.md` |
| Linux 用例：一个 ssh 可达的别名 | 本文档统一写作 `alpha`，只是本机的别名；`REMOTE=<你的别名> bin/sync.sh` 可覆盖 |
| Linux 构建期有外网 | mkosi 装包 + npm 装两个 harness；Linux 运行期 VM 无网卡。macOS 备好基底 VM 后，测试时默认 NAT |
| （可选）你自己的 `~/.agents/AGENTS.md` | 有它，指令层用例验证的是**你的真实指令层**；没有则用仓库里的中性夹具，用例照样全绿 |

Linux vmspawn 可在本机 Linux 构建与运行，也可从 Mac 调远端；两种 Tart guest 在 Apple Silicon Mac 上运行。
Linux 路径的 Mac 侧只需要 `git`、`ssh`、`tar`；macOS 用例还需要 Tart、
已配置的基底 VM 与相应断言工具（当前 `macos-pi-discovery` 需要 `jq`）。

## Linux 测试身份

Linux 用例以**发起者本人**（当前登录的非 root 用户，uid 1001）身份跑，不引入专用账号。
`PRIVDROP=1` 验收的零特权保证来自 `NoNewPrivs`（连 `sudo` 都拒绝以 root 运行），
而不是来自账号 —— 证据与残余风险见 `docs/BLINDSPOTS.md` 第四节。

## 用法

```bash
# 1. 把仓库同步到 alpha（Mac 是真相源）
bin/sync.sh

# 2. 构建 golden 镜像（首次，或改了 mkosi.conf / skeleton / postinst 之后）
ssh alpha 'bash ~/agent-harness-sandbox/bin/build-image.sh'

# 2.6 零特权验收：整条测试路径套上 NoNewPrivs（连 sudo 都拒绝以 root 运行）
ssh alpha 'cd ~/agent-harness-sandbox && PRIVDROP=1 bash bin/acceptance.sh'

# 3. 从 Mac 跑一条 Linux 用例（也可在 alpha 直接调用原有 run-case.sh）
bin/test.sh pi-turn

# 4. 在 Linux 主机本机运行（仍是无网卡 VM，不需要 SSH 到自己）
EXECUTION=local bin/test.sh pi-turn

# 5. Mac 本机 Tart：先按 docs/macos-tart.md 准备基底 VM 和 SSH 配置
EXECUTION=local bin/test.sh macos-pi-discovery
# ARM64 Linux 基底准备方法与限制见 docs/local-vm-routes.md
# EXECUTION=local bin/test.sh linux-pi-discovery
```

用例**定义**在仓库里（`cases/<case-id>/`：`cmd`、可选的 `target`/`assert.sh`；Linux
还支持 `post.sh`/`env`）。Linux 产物在 alpha 的 `~/ahsb-build/runs/<case-id>/<run-id>/`，
macOS 产物在 Mac 的 `~/ahsb-build/runs/<case-id>/<run-id>/`，均在同步树之外。
两个后端都写 `guest/tmp/ah.{out,err,rc}`；Linux 额外写串口、monitor、mock 证据，
macOS 写 VM 日志。`bin/acceptance.sh` 目前仍只验收 Linux。

Linux 同名用例和 acceptance 重跑均保留历史产物；以本次输出 `dir=` 为准。显式设置 Linux `RUN_DIR` 时必须指向不存在的目录，已有目录返回 2，不覆盖。会话名也按调用进程区分，但共享 mock/资源的并发正确性尚未验收；这不等于支持并行跑完整套件。

## 状态

- [x] task-1 立项与骨架
- [x] task-2 Step-0 可行性 spike（gate）：四条判据全部通过，见 `docs/spike-results.md`
- [x] task-3 mkosi golden 镜像（见 `docs/golden-image.md`）
- [x] task-4 薄 runner + vsock 上的 mock 服务
- [x] task-5 两个 harness 绿色闭环与三处断言（见 `docs/cases.md`）
- [x] task-6 AGENTS.md 行为验证（见 `docs/instruction-layer.md`）
- [x] task-7 越界与破坏用例第一批（见 `docs/isolation-cases.md`）
- [x] task-8 Linux 权限收敛、清理与验收报告（见 `docs/acceptance.md`、`docs/BLINDSPOTS.md`）
- [x] 多后端统一入口与 macOS pi CLI 用例；Linux `pi-turn`、`claude-turn` 和 macOS `macos-pi-discovery` 已分别在对应后端通过（见 `docs/macos-tart.md`）
- [ ] 从裸 IPSW 无人值守制作 macOS 基底镜像（Setup Assistant 自动化尚未稳定）
- [ ] macOS iTerm GUI 窗口用例及断言

## 已知盲区

- Linux 设计上排除**真实网络层**；macOS 默认 NAT 可联网，却没有 Linux 的物理 airgap。
  Tart 的 Softnet/仅主机网络模式需要宿主 root/SUID，本项目不自动申请或启用。
- Linux vmspawn 基准镜像没有桌面；Tart 的 `display=headed` 只在已准备好的 guest 桌面运行。有头截图契约及失败拒绝已实现，但**真实 GUI 正向与 iTerm 用例仍未验收**。
- **多节点**与「让别的 agent 通过 API 自助申请沙盒」仍不支持。

完整盲区清单见 `docs/BLINDSPOTS.md`。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/decisions.md` | 引擎选型与被否决的方案 |
| `docs/spike-results.md` | task-2 gate 的四条判据与原始证据 |
| `docs/cases.md` | 用例定义与三层断言 |
| `docs/instruction-layer.md` | 指令层验证的正反例、投影方式与不可测部分 |
| `docs/isolation-cases.md` | 越界/破坏用例、结论与每条用例暴露的盲区 |
| `docs/acceptance.md` | Linux 从零复现的验收记录（环境、哈希、8 条用例结果） |
| `docs/BLINDSPOTS.md` | Linux 盲区与 macOS 后端的不同保证 |
| `docs/macos-tart.md` | macOS 基底前置条件、CLI 调用及隔离边界 |
| `docs/local-vm-routes.md` | 本机 Linux/macOS 路由、guest 有头测试和不干扰工作桌面的边界 |
| `docs/golden-image.md` | golden 镜像定义与验收 |
| `docs/host-prereqs.md` | alpha 前置条件、两处临时 hack、环境坑清单 |
| `docs/alpha-cleanup.md` | 上一版（microsandbox）产物的回收记录 |

## 许可

MIT（见 `LICENSE`）。
