# 盲区声明

这份文件回答一个问题：**这个沙盒测不到什么。** 一条都不掩饰，因为"不知道自己不知道"
比测不出来更危险。

## 一、设计上排除的（无网卡的必然后果）

| 测不到 | 原因 | 影响 |
| --- | --- | --- |
| 真实 DNS（上游解析、超时、NXDOMAIN、DNS 劫持） | guest 里没有网卡 | harness 的解析相关代码路径从未被执行 |
| TLS 证书链、SNI、CA 校验、证书过期 | 只走 loopback 明文 HTTP | 证书类故障一律测不出 |
| HTTP/SOCKS 代理、`NO_PROXY` 语义 | 同上 | 企业网络相关行为完全未覆盖 |
| 网关、路由、防火墙、NAT | 同上 | — |
| 真实 TCP 语义（重传、拥塞窗口、RST、半开连接） | 只有 loopback 与 vsock | 超时/重连逻辑只能用 mock 层注入近似 |
| IPv6、ICMP、UDP 出站、RAW socket、AF_PACKET | 同上 | `port-scan` 用例只覆盖了 TCP + 域名解析 |
| 跨机行为、多节点集群 | 单机单 VM | 分布式场景全部在范围外 |
| 慢网/丢包/高延迟 | 无网卡，无法用 tc/netem；也没做带宽限制 | 网络质量相关的退避逻辑未验证 |

**"网络层不可测"是这个沙盒的前提，不是缺陷。** 需要时应该另开一个方向（内部网桥 + netem），
而不是往这里塞网卡 —— 那会立刻破坏"物理 airgap"这个最有价值的性质。

## 二、实现了但没做的

| 未覆盖 | 说明 |
| --- | --- |
| GUI / computer-use / 浏览器 | 镜像里没有 X/Wayland、没有浏览器、没有 VNC。要做需要另建镜像（参考 `agent-infra/sandbox` 那类自带 VNC 的方案） |
| 多节点与并发 | 全部用例串行。宿主上并发跑多条用例时的相互影响、资源争抢、端口冲突都没测 |
| 让 agent 自助申请沙盒的 API | 现在是 CLI。要做要走 Incus restricted project / E2B / agent-substrate，且与"权限收敛到非 root 用户"有张力 |
| 资源耗尽（CPU / 内存 / PID 打满） | DSec 记录过递归 `grep /proc/kpagecgroup`、`yes` 写满几十 GB。我们只做了**有界**的磁盘填充 |
| 文件系统/内核层攻击 | DSec 记录的 `XFS_IOC_SWAPEXT` 绕过访问控制损坏 XFS 元数据。我们是 ext4，且这类用例需要专门构造镜像 |
| 宿主侧可达性断言 | 只断言了"guest 唯一监听的是 vsock shim"，**没断言 agent 碰不到 mock 以外的宿主服务** |
| 镜像签名 / 安全启动 / TPM | vmspawn/QEMU 都支持，我们都没启用 |
| 引导路径本身 | 走的是直接内核启动（没有引导装载器），bootloader 相关行为没经过 |
| 长会话 / 多轮工具调用链 / 上下文压缩 | 每条用例都是单轮 |
| 成本与 token 记账 | 完全没测 |
| 真实模型的语义正确性 | mock 是确定性替身，只能验证"结构"（谁发了什么、发了多少、带了哪些工具），不能验证"答得对不对" |

## 三、假装不了的地方（近似与失真）

- **换掉模型就换了被测对象的一半。** 断言抓的是请求形状与状态产物；模型质量、指令遵循度、
  多步规划全部不可测。
- **guest 是 Arch。** 不代表使用者真实的运行环境（不同发行版、不同 glibc、不同 node 版本
  可能有不同故障）。
- **产物回传走串口 base64，受 tmux history 上限约束**（跑之前把 `history-limit` 抬到 10 万行）。
  超大产物（几十 MB 的会话记录）会被截断，这个边界没有测过。
- **每条用例一个全新 VM**：拿到的是"干净起点"的结论，拿不到"被污染过的环境里会怎样"。

## 四、权限模型：测试身份就是现有的非 root 账号

**决定：不引入专用 `harness` 账号，测试一律以发起者（当前登录的非 root 用户，uid 1001）身份跑。**
理由是特权保证不来自"换个身份"，而来自结构性的限制：

| 证据 | 实测结果 |
| --- | --- |
| 能力集 | `CapEff`/`CapPrm`/`CapAmb` 全为 `0` |
| 代码里有没有 `sudo` | `bin/`、`mock/`、`cases/` 里 grep 为空 |
| 有密码也提不了权 | `PRIVDROP=1`（`setpriv --no-new-privs`）下，连 `sudo` 自己都报 *"The 'no new privileges' flag is set, which prevents sudo from running as root."* |
| KVM / vsock | 在 NoNewPrivs 下依然可读写 `/dev/kvm`、`/dev/vhost-vsock`（设备权限，不是能力） |
| 验收 | `PRIVDROP=1 bash bin/acceptance.sh` 全程跑通，8/8 ALL CASES PASS（`docs/acceptance.md`） |

**残余风险（明确的，不掩饰）：** 发起账号在 `wheel` 组里，**它自己**能 sudo（要密码）。
所以"测试路径提不了权"这件事，靠的是**加在每条用例上的 NoNewPrivs**，而不是账号本身。
换句话说：如果用不带 `PRIVDROP=1` 的裸跑，保护就退化成"我们没写 sudo"。
想彻底消除这条，只有两种办法 —— 换用专用非特权账号（`bin/bootstrap-host.sh` 仍留着，
需要 root），或者永远用 `PRIVDROP=1` 跑。

另外：宿主侧还没有 per-case 的资源上限（cgroup slice）。现在用例串行、每台 2 核 2G，
但一条失控用例仍可能拖慢宿主。

## 五、环境脆弱点

| 脆弱点 | 影响 | 缓解 |
| --- | --- | --- |
| 依赖 alpha 上的用户级 mkosi（devel 版） | 换机器/清 home 就失效 | `docs/host-prereqs.md` 记了重建方式 |
| `virtiofsd` 在本机起不来 | 不能用 `--directory=`，产物只能走串口 | 已绕开；若将来修好可简化产物通道 |
| 宿主 `/etc/resolv.conf` 首条是 `127.0.0.1` | 会让依赖宿主 DNS 的方案发疯 | 我们不用 DNS，不受影响；但换机器时要注意 |
| 宿主上还跑着一个 Home Assistant VM（约 3G RSS） | 资源共用 | 用例串行、每台 2 核 2G，暂未冲突 |
| 测试床没有任何宿主侧资源上限（cgroup slice） | 一条失控用例可能拖慢宿主 | 记录为待办 |
