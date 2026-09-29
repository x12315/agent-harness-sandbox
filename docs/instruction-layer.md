# 指令层验证（task-6）

目标：让沙盒能回答「`~/.agents` 那套指令层，harness 到底有没有吃进去」。

## 投影方式：两种夹具，公开版也能跑

| 夹具 | 谁用 | 内容 |
| --- | --- | --- |
| `mkosi.skeleton/opt/agents-fixture/AGENTS.md`（**入库**） | 任何人 clone 下来 | **中性夹具**：几条通用硬规则 + 规则令牌 `AH-COMPLY-7788` + 哨兵 `AH-SENTINEL-4F3C9A-7D21` |
| `mkosi.skeleton/opt/agents-fixture/AGENTS.local.md`（**不入库**） | 作者本机 | `bin/project-agents-md.sh` 把真实的 `~/.agents/AGENTS.md` 抄过来 + 追加规则与哨兵，头部记来源路径与原文 sha256 |

用例优先用 `.local.md`，没有就退回中性夹具：

```bash
cp /opt/agents-fixture/AGENTS.local.md /work/AGENTS.md 2>/dev/null \
  || cp /opt/agents-fixture/AGENTS.md /work/AGENTS.md
```

断言跟着分两路（**不猜内容措辞，按哈希对账**）：

| 正文里有 | 说明 | 断言 |
| --- | --- | --- |
| `原文 sha256: <hash>` | 用的是真实投影 | 正文里记录的 hash 必须等于本机夹具头部记录的 hash（证明到达模型的就是投影脚本生成的那份）；原始文件在 Mac 上，那一环由 `project-agents-md.sh` 生成时保证 |
| 没有 | 用的是中性夹具 | 断言夹具的规则段落在正文里 |

（最初我硬编码了真实文件里的规则文字做断言，结果猜错了措辞 —— 那个文件是 `compose.mjs` 生成的，
内容和我凭渲染结果猜的不一样。改成哈希对账后再没这个风险。）

`bin/sync.sh` 每次同步前重跑投影，所以作者机器上验证的永远是**当前**的
`~/.agents/AGENTS.md`，而且它的正文不会进 git、不会公开。

夹具是**运行期通过串口送进 guest** 的（`run-case.sh` 的 `PUSH`，分块 base64 —— tty 规范模式
单行上限 4096 字节，整块送会被静默截断）。所以**改夹具不需要重建镜像**，一轮只要十几秒。

**为什么不用挂载**：guest 没有网卡，也挂不了宿主目录（`--ephemeral` 与 virtiofsd 在这台机器上
都用不了），宿主→guest 没有文件通道。所以"投影"只有两种实现：烧进镜像，或由用例命令自己写出来。
前者可版本化、可追溯到源，选它。

## 正例 / 反例

| 用例 | 差异 | 断言 |
| --- | --- | --- |
| `agents-md-honored` | 正常跑 | 请求正文里**有**哨兵；rc=0；stdout 含 mock 应答 |
| `agents-md-ignored` | 只多一个 `--no-context-files` | 请求正文里**没有**哨兵；rc=0；stdout 含 mock 应答 |

实测（正例哨兵出现 1 次，反例 0 次）：

```
$ bash bin/run-case.sh agents-md-honored
ok ①: 请求正文里出现 AGENTS.md 哨兵与**真实硬规则**（单写入方 / 投影只能指向本仓库）
ok ②: 指令层里的规则驱动出了可观测的行为（最终输出带 AH-COMPLY-7788）
ok ③: rc=0，stdout 含 mock 应答
assert=agents-md-honored PASS

$ bash bin/run-case.sh agents-md-ignored
ok ①: 关掉上下文文件后哨兵与真实硬规则一起消失 —— 正反例可区分
ok ②: 规则没有被注入，最终输出里也没有规则令牌（行为层面同样可区分）
ok ③: rc=0，stdout 含 mock 应答（除开关外条件相同）
assert=agents-md-ignored PASS
```

两条用例除那一个开关之外完全相同，命令都跑通 —— 所以差异只能来自指令层，
断言区分得开（这是"反例"存在的意义：防止正例断言只是碰巧命中）。

## 断言的是什么：两层

| 层 | 断言 | 证据 |
| --- | --- | --- |
| ① 加载 | 指令层的内容出现在模型请求里 | 请求正文含哨兵 `AH-SENTINEL-4F3C9A-7D21`，**以及真实硬规则的原文**（`单写入方`、`投影只能指向本仓库`） |
| ② 行为 | 指令层里的规则**驱动出了可观测的结果** | 夹具要求"回答以 `AH-COMPLY-7788` 开头"；mock 从请求正文里取出该令牌并照做，于是 harness 的**最终输出**里出现它 |

② 是这次补上的：它把"文件被读进去了"升级成"指令改变了输出"。反例（`--no-context-files`）
在两层上同时为零：请求里没有哨兵，输出里也没有令牌 —— 所以断言区分得开，不是碰巧命中。

**它仍然不是"真模型的服从率"。** mock 扮演的是**一个会遵守规则的模型**：它从请求正文里
（而不是从别的渠道）拿到规则并执行。所以它证明的是整条链路
`指令文件 → harness 注入请求 → 模型行为 → harness 输出 → 我们采集到的产物` 是通的，
而不是"某个真模型会不会照做"。后者需要真模型 + 语义判定，见 `docs/BLINDSPOTS.md`。

## 不可测 / 未覆盖

1. **遵守度**：如上，mock 无法验证"模型是否照做"。可以用真模型接进来（把 shim 指到真网关），
   但那就破了 airgap 前提，且结果不可复现。
2. **Claude Code 的 `CLAUDE.md` 路径**：正反例目前只对 pi 做了 —— 因为 pi 有
   `--no-context-files` 这个干净的开关；claude 侧要构造反例得靠"删文件"，控制变量不如开关干净。
   要做的话：正例放 `/work/CLAUDE.md`，反例不放。
3. **skill 发现**：`~/.agents/skills/*/SKILL.md` 的加载机制（name/description 校验、
   `metadata:` 扩展字段）没有覆盖。可以在夹具里放一个 skill，断言它出现在请求的可用技能清单里。
4. **多级 AGENTS.md 的继承与优先级**（仓根 / 子目录 / 用户级）。
5. **指令与工具调用的互动**：例如"硬规则说只能通过 CLI 装东西"，这需要模型做决策，同上不可测。
