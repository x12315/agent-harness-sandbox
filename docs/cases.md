# 用例与断言

下文的两条基准用例与 `bin/run-case.sh` 属于 Linux vmspawn 后端；macOS Tart 用例见
`cases/macos-pi-discovery/` 和 `docs/macos-tart.md`。两者都可从 Mac 调用 `bin/test.sh <id>`，
公共取证文件是 `guest/tmp/ah.{out,err,rc}`，其余证据依后端而定。

一条 Linux 用例 = `cases/<id>/` 目录里的定义文件（**定义在仓库，产物在 $OUT/runs/<id>/**，
因为 `bin/sync.sh` 是整目录替换，产物留在仓库树里会被下一次同步连根删掉）：

| 文件 | 作用 |
| --- | --- |
| `cmd` | 在 Linux guest 里跑的那一行命令（必填） |
| `target` | 缺省 `linux-vmspawn`；写 `macos-tart` 则由 Mac 本地 Tart 后端运行 |
| `assert.sh` | 拿到产物之后跑的断言，接一个参数：用例目录（可选） |

用例本身进了 git，所以"被测对象 + 断言口径"是一起版本化的；`bin/run-case.sh <id>`
不带命令参数时会读 `cmd`，跑完销毁 VM 再执行 `assert.sh`，结果落在 `assert.txt`。

## 两条基准用例

| 用例 | 命令 | 断言 |
| --- | --- | --- |
| `claude-turn` | `claude -p 'say hi' --output-format text` | ① mock 收到**流式** `/v1/messages`、带鉴权头、工具表 ≥10 项 ② 回收到 `~/.claude.json` ③ rc=0 且 stdout 含 mock 应答 |
| `pi-turn` | `pi --offline -p --provider mock --model mock-model 'say hi'` | ① mock 收到 `/v1/chat/completions`、模型名正确、工具表恰好是 `read/bash/edit/write` ② 回收到 `~/.pi` 下的状态文件 ③ rc=0 且 stdout 含 mock 应答 |

pi 走的是自定义 provider（`~/.pi/agent/models.json` 里指向 `127.0.0.1:18788/v1`，
`api: openai-completions`），这份配置烧在镜像里；claude 靠 runner 注入的
`ANTHROPIC_BASE_URL`。

## 实测输出（可重跑）

```
$ bash bin/run-case.sh claude-turn
ok ①: mock 收到流式 /v1/messages，带鉴权头，工具表 >=10 项
ok ②: 回收到 harness 状态 ~/.claude.json（569 字节）
ok ③: rc=0，stdout 含 mock 应答
assert=claude-turn PASS

$ bash bin/run-case.sh pi-turn
ok ①: mock 收到 /v1/chat/completions，模型名与工具表（read/bash/edit/write）符合预期
ok ②: 回收到 pi 状态文件（4 个）
ok ③: rc=0，stdout 含 mock 应答
assert=pi-turn PASS
```

两条都连跑两遍结果一致。断言按"证据种类"分三层，而不是按"输出长什么样"：
**请求形状**（harness 把什么发给了模型）、**自身状态**（harness 在磁盘上留下了什么）、
**退出码与输出**。这样即使 mock 的应答文案改了，断言依然站得住。

## 加一条新用例

```bash
mkdir cases/<新 id>
printf '%s\n' '<在 guest 里跑的命令>' > cases/<新 id>/cmd
$EDITOR cases/<新 id>/assert.sh   # 用 jq 读传入的那个产物目录（$OUT/runs/<新 id>）
bin/sync.sh && bin/test.sh <新 id>  # Linux；macOS 用例无需 sync，先按 docs/macos-tart.md 构建镜像
```

## 踩过的三个坑（都体现在 runner 里）

1. **标记要由 guest 现场生成。** 串口会把命令行原样回显，标记若写在命令里，回显本身就包含它，
   会让人在命令还没跑完时就误判完成。现在的正则只认数字（`^==M[0-9]+==END==`），
   而回显里是字面量 `$R`。
2. **mock 请求的时间窗要用小数秒。** 整秒会在边界上漏掉请求（实测漏过一次）。
3. **tar 只能收真实存在的路径。** harness 没跑过时 `~/.claude` 不存在，
   tar 遇到不存在的成员会整个不产出归档。
