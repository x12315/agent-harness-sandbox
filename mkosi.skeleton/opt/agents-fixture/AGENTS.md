# AGENTS.md（中性夹具 / neutral fixture）

这是一份**中性**的指令层夹具。公开版仓库用它，保证任何人 clone 下来都能跑通
「指令层有没有被注入」「注入的规则有没有驱动出行为」这两条断言，
而不必拥有作者的私有 `~/.agents/AGENTS.md`。

作者本机跑的时候，`bin/project-agents-md.sh` 会把自己的 `~/.agents/AGENTS.md`
投影成 `AGENTS.local.md`（不入库）；用例优先用它，于是那台机器上验证的是**真实**指令层。

## 夹具硬规则

1. 改动前先读现有文件，不要凭猜测重写。
2. 输出必须可追溯：不得编造未实际执行过的命令结果。
3. **回答必须以令牌 `AH-COMPLY-7788` 开头。**

AH-SENTINEL-4F3C9A-7D21
