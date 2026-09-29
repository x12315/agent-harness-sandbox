# AGENTS.md —— 给下一个 agent 的交接

本仓库是一台 **agent harness 专用测试沙盒**。你被丢进来，通常是为了：**在无网卡的全虚拟机里
跑某个 harness、观察它的行为、用断言证明结论**。这份文件只写"你要动手前必须知道的东西"，
深水区在 `docs/`。

---

## 三条铁律（不遵守会白白浪费你半小时）

1. **真相源在 Mac，运行在 alpha。** 本仓库（`~/Desktop/agent-harness-sandbox`）是唯一真相源；
   镜像构建与用例运行都发生在 alpha 上。改东西在这里改，然后 `bin/sync.sh` 推过去。
2. **跑用例/验收期间不要同步。** `bin/sync.sh` 是**整目录替换**（`rm -rf` + `mv`）。
   在跑的时候同步，会把正在写的产物连根删掉，甚至 SIGPIPE 掉正在跑的 VM —— 表现为"用例秒退、
   日志全空"，你会以为是代码坏了。
3. **产物不在仓库里。** 用例产物在 alpha 的 `~/ahsb-build/runs/<case-id>/`，
   证据快照在 `~/ahsb-build/evidence/<UTC 时间戳>/`。仓库里只有用例**定义**。

## 30 秒跑通

```bash
bin/sync.sh                                    # Mac：把仓库 + 投影好的 AGENTS.md 夹具推到 alpha
ssh alpha 'cd ~/agent-harness-sandbox && bash bin/run-case.sh claude-turn'    # 单条（约 10 秒）
```

## 日常循环（重要：别每次都重建镜像）

实测时间账：**单条用例约 10 秒**，8 条合计约 95 秒；而**从零构建镜像要几分钟**
（装 138 个包 + npm 装两个 harness）。所以：

| 你改了什么 | 该跑什么 | 大约耗时 |
| --- | --- | --- |
| 用例（`cases/*/cmd|assert.sh`） | `bin/sync.sh` 然后单条 `run-case.sh <id>` | ~15 秒 |
| 指令层夹具 / 要送进 guest 的任务文件 | 用 `PUSH="<宿主文件>:<guest路径>"`（运行期走串口推送，**不用重建镜像**） | ~15 秒 |
| 同上，但想跑一批 | `SKIP_BUILD=1 PRIVDROP=1 bash bin/acceptance.sh <id> <id> ...` | 每条 ~10 秒 |
| `mkosi.conf` / `mkosi.skeleton/` / `mkosi.postinst` | 重新构建：`bash bin/build-image.sh`（或直接跑不带 SKIP_BUILD 的 acceptance） | 几分钟 |
| 什么都不确定 | `PRIVDROP=1 bash bin/acceptance.sh`（含构建，全套） | 几分钟 + 95 秒 |

```bash
# 全套 + 留档（含构建）
ssh alpha 'cd ~/agent-harness-sandbox && PRIVDROP=1 bash bin/acceptance.sh'
# 只跑两条、跳过构建（迭代时最常用）
ssh alpha 'cd ~/agent-harness-sandbox && SKIP_BUILD=1 PRIVDROP=1 bash bin/acceptance.sh claude-turn pi-turn'
```

前提：
- 能 `ssh alpha`（`alpha` 只是本文档用的别名，`REMOTE=<你的别名> bin/sync.sh` 可覆盖）；
- 目标机有可读写的 `/dev/kvm`、`/dev/vhost-vsock`，systemd ≥ 260，QEMU + OVMF；
- Mac 侧有 `~/.agents/AGENTS.md` 时会把它投影成镜像夹具（不入库）；没有则用仓库里的中性夹具，
  用例照样全绿，只是指令层用例验证的是那份中性夹具而不是你的真实指令层。

## 加一条用例（你最可能要做的事）

```
cases/<id>/cmd          # 必填：guest 里执行的一行命令
cases/<id>/assert.sh    # 可选：销毁后跑，参数 = 产物目录（$D）
cases/<id>/post.sh      # 可选：VM 还活着时跑，用于带外/现场类检查
cases/<id>/env          # 可选：覆盖 CPUS / RAM 等变量
```

规矩：

- 命令是**一行**（`sh -lc` 执行），cwd 是 `/work`。
- 已预置环境变量：`ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` → `http://127.0.0.1:18788`
  （guest 里的 socat 把它桥到宿主 vsock 上的 mock），`ANTHROPIC_API_KEY=mock-key`。
  所以 harness **不用改配置**就能打到 mock。
- **guest 没有网卡。** harness 需要的一切只能来自三处：(a) 镜像里已有；(b) 写进这条命令；
  (c) 放进 `mkosi.skeleton/` 后重建镜像。别指望它去下东西。
- 断言写**证据种类**，不要写"输出长什么样"：
  ① mock 收到的请求形状 ② harness 自己留下的状态文件 ③ 退出码与 stdout。
  证据种类不会因为你以后改了文案就变脆。
- `assert.sh` 的 `$1` 就是产物目录，别在里面硬编码 `cases/<id>/`。

## 把任务/文件送进 guest

没有网卡，也没有宿主→guest 的通用文件通道，只有两条路：

1. **小文件/提示词**：直接写进命令。命令是一行，换行用 `\n` 转义：
   `printf 'line1\nline2\n' > /work/task.md && claude -p "$(cat /work/task.md)" </dev/null`
2. **稍大的、或反复用的**：放进 `mkosi.skeleton/opt/task/`，重建镜像（约 4 分钟），
   用例里 `cp /opt/task/... /work/`。

（为什么没有更好的通道：`systemd-vmspawn --extra-drive` 与 `--ephemeral` 冲突，
virtiofsd 在这台机器上起不来，所以别浪费时间试挂载。）

## 换掉或加一个 harness

镜像里现在只有 **claude 2.1.283** 与 **pi 0.87.1**，版本钉在 `mkosi.postinst` 里。
要加别的 harness：改 `mkosi.postinst` → `ssh alpha 'bash bin/build-image.sh'` → 新写用例。
pi 的 provider 配置烧在 `mkosi.skeleton/root/.pi/agent/models.json`（指向 mock）。

## 看结果与排查

产物清单（都在 `~/ahsb-build/runs/<case-id>/`）：

| 文件 | 用途 |
| --- | --- |
| `console.txt` | 串口全文 —— **出问题第一个看它** |
| `monitor.txt` | 带外 QEMU monitor 的交互记录（`post.sh` 写的） |
| `vm.log` | QEMU 的日志 |
| `guest/tmp/ah.{out,err,rc}` | 被测命令的 stdout / stderr / 退出码 |
| `guest/root/**` | harness 自己的状态（`~/.claude`、`~/.pi`） |
| `mock-requests.jsonl` | 本次时间窗内 mock 收到的请求 |
| `assert.txt` | 断言输出 |

| 症状 | 多半是什么 |
| --- | --- |
| 用例秒退、`console.txt` 为空 | 跑的时候同步过仓库（见铁律 2） |
| 断言说找不到 `ah.out` | 断言里硬编码了路径；应该用 `$1` |
| `guest 没能起来` | 看 `vm.log`；残留进程可用 `pkill -f 'systemd-vmspaw[n].*ahsb'` 清掉 |
| `mock-requests.jsonl` 为空 | 命令没真打到模型；确认打的是 `127.0.0.1:18788` |
| 断言失败但输出看着对 | 断言在测"措辞"而不是"证据种类"，改断言 |
| `RUN_DIR: unbound variable` | 你把产物目录变量用在了定义之前（脚本 `set -u`） |
| `ssh alpha` 超时 / `Operation timed out` | alpha 走 Tailscale 中继，今天多次抖动，通常 1–2 分钟自愈。**跑长任务一律 `nohup ... > 日志 &` 再轮询**，别让前台 ssh 挂着 —— 中继一抖就会把你的长任务一起带走 |

## 边界（别拿它做这些，会白费功夫）

真实网络层（DNS / TLS / 代理 / 跨机）、GUI / computer-use / 浏览器、多节点与并发、
资源耗尽（CPU/内存/PID 打满）、文件系统与内核层攻击、**真模型的语义质量**
（mock 只能验结构：谁发了什么、带了哪些工具、留下了什么状态）。
完整清单与残余风险见 `docs/BLINDSPOTS.md`。

## 深水区（按需读，不要一开始全读）

| 文件 | 什么时候读 |
| --- | --- |
| `docs/cases.md` | 写用例、改断言 |
| `docs/decisions.md` | 想知道"为什么是 vmspawn / 为什么不用 Incus / 为什么换过又换回来" |
| `docs/golden-image.md` | 改镜像内容、看镜像里有什么 |
| `docs/instruction-layer.md` | 验证 `~/.agents/AGENTS.md` 那条线 |
| `docs/isolation-cases.md` | 越界/破坏类用例与它们暴露的盲区 |
| `docs/host-prereqs.md` | 换机器、或遇到环境坑 |
| `docs/acceptance.md` | 看验收证据、复现标准流程 |
| `docs/BLINDSPOTS.md` | 判断"这件事能不能测" |
