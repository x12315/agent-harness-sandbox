# 验收记录（task-8）

按 README 的步骤**从零**跑完整流程：删掉镜像目录 → 重新同步 → 构建 golden 镜像 →
顺序跑全部用例。全程非特权（`PRIVDROP=1`）。

复现命令：

```bash
# Mac 侧（顺带把 ~/.agents/AGENTS.md 投影进镜像夹具）
bin/sync.sh
# alpha 侧（会重建镜像；跑的时候**不要**再同步，sync 是整目录替换）
ssh alpha 'rm -rf ~/ahsb-build/runs && cd ~/agent-harness-sandbox && PRIVDROP=1 bash bin/acceptance.sh'
```

## 环境与起点

```
2026-09-28T11:08:54Z
host: 7.1.11-arch1-1  user: <非 root 用户>  uid: 1001
能力集: CapPrm: 0000000000000000 CapEff: 0000000000000000 CapAmb: 0000000000000000
每条用例: setpriv --no-new-privs（连 sudo 都拒绝以 root 运行）
systemd: systemd 261 (261.2-1-arch)
```

启动方式：**`systemd-vmspawn`**，`--console=native --ephemeral --register=no --pass-ssh-key=no`。
带外 monitor 就是 `--console=native` 下 `-nographic` 复用在同一个 console 上的那个（`Ctrl-A c`）。

镜像产物（从零构建）：

```
ed45a7f10b4c9fcfeea7c0878f91732c6f5f23e9e95a90ebab10601e4fb19bd5  ~/ahsb-build/ahsb.raw
8ebc2c71271e000540f0a7545afd8e73504fcb724671f3d38c720b241842b901  ~/ahsb-build/ahsb.vmlinuz
83d4a69ac2238af60c4912c0ecb984308779c582a447778cc793d037bc6e3f0c  ~/ahsb-build/ahsb.initrd
```

## 全部用例（8 条）

| 用例 | rc | 断言 | 覆盖 |
| --- | --- | --- | --- |
| `claude-turn` | 0 | PASS | Claude Code 2.1.283 端到端一轮 + 三层断言 |
| `pi-turn` | 0 | PASS | pi 0.87.1 端到端一轮 + 三层断言 |
| `agents-md-honored` | 0 | PASS | 请求里出现哨兵**与真实硬规则**（`单写入方` / `投影只能指向本仓库`），且规则驱动出可观测行为（输出带 `AH-COMPLY-7788`） |
| `agents-md-ignored` | 0 | PASS | 同一命令加 `--no-context-files`：请求与输出**两层同时为零** |
| `overwrite-bin-bash` | 0 | PASS | 系统二进制被改写：可观测、被兜住 |
| `disk-fill` | 0 | PASS | 500MiB 无配额写入，损害限于临时盘 |
| `port-scan` | 0 | PASS | 对外不可达；无预期外监听；无上游 DNS |
| `out-of-band-monitor` | 0 | PASS | **guest 内核 panic 后，从 QEMU monitor 读到 `VM status: running` 与 `* CPU #0`**，并用它结束 VM |

指令层那两条的原始输出：

```
----- agents-md-honored -----
ok ①: 请求正文里出现 AGENTS.md 哨兵与**真实硬规则**（单写入方 / 投影只能指向本仓库）
ok ②: 指令层里的规则驱动出了可观测的行为（最终输出带 AH-COMPLY-7788）
ok ③: rc=0，stdout 含 mock 应答
----- agents-md-ignored -----
ok ①: 关掉上下文文件后哨兵与真实硬规则一起消失 —— 正反例可区分
ok ②: 规则没有被注入，最终输出里也没有规则令牌（行为层面同样可区分）
ok ③: rc=0，stdout 含 mock 应答（除开关外条件相同）
```

```
=== 结论 ===
ALL CASES PASS
```

## 证据留档

- 用例**定义**在仓库里（`cases/<id>/`），用例**产物**落在 `~/ahsb-build/runs/<id>/`
  —— **同步树之外**，因为 `bin/sync.sh` 是整目录替换，产物留在仓库树里会被下一次同步连根删掉
  （上一轮验收就是这么被打断的）。
- 每次验收还会把每条用例的 `assert.txt`、`console.txt`、`mock-requests.jsonl`、
  `monitor.txt`、`vm.log`、`guest/` 抄一份到 `~/ahsb-build/evidence/<UTC 时间戳>/`，并带上
  `SHA256SUMS`。本次：`~/ahsb-build/evidence/20260928T110854Z`。

## 说明

- 每个用例都是**一台全新 VM**（`--ephemeral`：临时 CoW 快照，退出即丢弃），
  所以 8 条互不影响 —— `overwrite-bin-bash`（把系统二进制改坏）之后的用例照样全绿。
- 出问题先看 `runs/<id>/console.txt`（串口全文）与 `runs/<id>/monitor.txt`（带外通道）。
- 完整日志在 alpha 的 `/tmp/acceptance.log`；脚本是 `bin/acceptance.sh`，随时可重跑。
- 关于"为什么用 `systemd-vmspawn` 而不是直接调 QEMU"：曾经误判过一次（以为 vmspawn 拿不到
  monitor），结论与更正写在 `docs/decisions.md`。
