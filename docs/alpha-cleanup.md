# alpha 清理记录（task-1）

上一版方案（microsandbox）在 alpha 上留下的产物，已全部回收。之所以要清掉而不是留着：
新方案把工具链烧进 mkosi 镜像，宿主目录挂载与 msb 沙箱状态都不再需要，留着只会让"当前真相"变模糊。

## 清理清单

| 路径 / 资源 | 清理前 | 处理 |
| --- | --- | --- |
| `~/alpha-testbed/` | **980M** | 删除。内含 msb 版工具链（655M，claude 2.1.283 + pi 0.87.1 的 npm prefix 安装）、`mock/`、`bin/case.sh`、`bin/smoke.sh`、`bin/serve-mock.sh`、`systemd/mock-llm.service`、`artifacts/`、以及一个未完成的 Debian cloud image 下载 |
| `~/.microsandbox/` | **1.3G** | 删除。msb 0.7.3 二进制 + libkrunfw + 沙箱状态库 |
| `~/.local/bin/msb`、`~/.local/bin/microsandbox` | 2 个符号链接 | 删除 |
| `~/bootstrap-harness.sh` | 1.7K | 删除。msb 时代的引导脚本，含一处错误授权（把测试用户加进 `docker` 组 = 交出 root 等价能力），已由新方案取代 |
| `~/git/` | 空目录 | 删除 |
| 残留进程：mock LLM（`18788/tcp`） | 1 个 | 结束 |
| 残留进程：UDP 回环测试监听（`15353/udp`） | 1 个 | 结束；两个端口均已复核为空闲 |

**合计回收约 2.3G**（`/home` 分区使用量 700G，占 30%，清理前后无可见变化）。

## 迁入本仓库的部分

- `mock/mock_llm.py`（147 行）：确定性 mock 模型 API，Anthropic + OpenAI 双协议、SSE 流式、
  逐请求写 JSONL。已带 `urlparse` 补丁（msb 版踩过的坑：`/v1/messages?beta=true` 这类带查询串的路径
  用 `endswith` 匹配会 404）。

## 未改动

alpha 上既有的东西一律没碰：dotfiles 与既有服务脚本（Sunshine 相关等）、systemd、sshd、
网络配置、libvirt（宿主原本就装着 12.6.0 + QEMU 11.1 + OVMF，新方案会用到，未做任何修改）、
docker（未安装，用户也不在 docker 组）。

## 复核命令

```bash
ssh alpha 'du -sh ~/alpha-testbed ~/.microsandbox 2>&1; ls ~/.local/bin/msb 2>&1; ss -lunp | grep -E ":15353|:18788"'
```

## 追加：另一套 msb 时代目录也已退役（消除本文件与 host-prereqs 的矛盾）

审计指出 `~/alpha-testbed/` 仍然存在，而本文件写着"已删除"，两份文档自相矛盾。事实是两回事：

| 目录 | 来源 | 处理 |
| --- | --- | --- |
| `~/alpha-testbed/`（980M，`bin/ toolchain/ mock/ systemd/ artifacts/`） | 本会话早期按 microsandbox 方案搭的测试床 | 12:04 删除，当时复核过"不存在" |
| `~/alpha-testbed/`（92K，`harnesses.json cases/*.json runs/ msb-argv.json mock/`） | **另一套** microsandbox 风格的脚本，2026-09-28 **15:48** 出现；不是本仓库脚本建的（结构与本会话那套完全不同） | 打包归档后移走 |

归档：`~/ahsb-build/retired/alpha-testbed-msb-era-20260928T104103Z.tgz`
sha256：`75a41bda680d657eb9367257a5aeba439253c46f9b8c43ea26105ac9984632c4`
（18 个文件、92K：`scenario.json`、`prompt.txt`、`guest-script.sh`、mock 输出、`msb-argv.json` 等。
**先归档再删除**，内容没有丢。）

现在 alpha 的 home 里与本项目相关的只剩：
`~/agent-harness-sandbox/`（同步树）与 `~/ahsb-build/`（镜像、mock 日志、证据、归档）。
