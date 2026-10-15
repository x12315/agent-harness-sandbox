# 通用运行时与 Observer 接口验收（2026-10-10）

## 分工与结论

- sandbox 固定公共工具、准备独立基底、管理缓存、验证真实 CLI/PTY、记录证据并销毁测试克隆。
- 使用者通过 `requires.json` 声明精确版本，通过 `push` 注入源码，并负责 guest 项目初始化和业务断言。
- 缺环境返回 78 / `NOT_READY`，跳过业务 `cmd`、`post.sh` 和 `assert.sh`；业务测试不下载、升级或保存基底。
- Linux 与 macOS 运行时实测通过；独立 Pi 进程和 WebUI 同进程内存子会话均实测通过。2026-10-12 又通过了两次 DeepSeek Flash 真实摘要验收；其他覆盖边界仍见文末，不把单个 provider 的通过称为所有环境零缺口。

## 通用运行时准备

macOS 从原私有 GUI seed 克隆准备，原 seed 和私有 profile 不修改。389 个去重公共 tarball 优先复用已有缓存，仅补下载 2 个；guest 离线安装 409 个包用时 9 秒。修复 node-pty 1.1.0 的 macOS spawn-helper 执行位后，真实 PTY 子进程成功；单纯 `require()` 无法验证这一点。

固定版本：Pi 0.87.1、WebUI 0.96.1、agent-browser 0.38.2、Claude 2.1.283。lockfile SHA256：
`ed96df5dbbe6a1545f4902417280e6b3066be1dfea403d0ead5149af66da8b14`。
macOS 为 Node 24.21.0 / ABI 137 / arm64；Linux 为 Node 26.11.1 / ABI 147 / x64。

Linux 旧镜像缺少 WebUI，正向预检正确返回 78。随后复用 alpha 已准备的固定版本 npm 前缀和系统包缓存，以 `--cache-only=always --with-network=no` 在独立目录生成新镜像；不覆盖原镜像或其他人的测试目录，不在业务 VM 中安装。

版本探针隔离工作目录和 Pi 配置，并在探针子进程强制 `PI_OFFLINE=1`，不影响业务环境。每项保留进度、30 秒有限预算和耗时。此前 macOS Pi 探针曾超过 30 秒；离线探针的最终 macOS 回执为 3063ms。不能把单次耗时变化当作整体性能或唯一根因证明。

## 实机证据

macOS 路径相对 `~/ahsb-build/runs/`：

| 验收 | 通过产物 | 证据 |
| --- | --- | --- |
| 独立基底准备 | `tart-runtime-prepare/20261010T071754Z-34707` | 离线安装、四个 CLI、PTY、runtime.json、prepared-base.txt |
| 最新普通 Pi 自动发现 | `macos-observer-autoload/20261010T102832Z-92685` | 无 `--extension` 的两个 Pi 进程、自动摘要、退出清理 |
| 最新 CLI + 内存会话生命周期 | `macos-observer-memory/20261010T101448Z-89723` | 普通启动、两个独立进程、WebUI 持久父会话及内存子会话、独立摘要上下文、全部退出清理 |
| 最新有头统一查看 | `macos-observer/20261010T102611Z-92466` | 授权前无状态、读授权、5 会话/4 进程/4 活动会话、摘要、定时刷新、runtime.json、gui.png |

有头用例的四个活动会话为两个 CLI 进程，以及同 PID、不同 session ID 的 WebUI 父子会话；另一个空闲 WebUI Pi 计入总数。刷新测试的虚构 PID 最后移除，不用它冒充真实任务。已读取最后一轮整桌面截图：四个真实活动会话并排显示，内存父子 PID 同为 624，CLI 父子 PID 分别为 611 和 612。DOM 断言与 guest 整桌面截图是独立证据。以上 macOS 与内存生命周期轮次使用 guest loopback mock；下节真实 provider 轮次另有独立证据。

Linux 路径相对 alpha 的 `~/ahsb-build/observer-runtime-validation-20261010T085236Z-prepared/`：

| 验收 | 产物 | 退出码 |
| --- | --- | --- |
| 固定版本工具、真实 PTY、业务执行 | `runs/runtime-contract/20261010T101636Z-JLW6Me` | 0 |
| 不兼容 Pi 999.0.0 拒绝执行 | `runs/runtime-contract-incompatible/20261010T101648Z-FLzTKY` | 78 |
| CLI 与 WebUI 内存会话、独立摘要、退出清理 | `runs/linux-observer-memory/20261010T101508Z-i4cL3A` | 0 |

另检查负例没有业务输出、`post-was-called` 或 `assert-was-called`。这不是仅凭退出码推断业务被跳过。

## 生命周期修复与回归

实机内存会话退出曾失败：SDK 关闭后迟到的 `agent_settled` 重新写出已删除快照。现在关闭状态禁止再次持久化和启动定时器；心跳只读取公开 session ID，失效上下文清理自身资源。Linux 与 macOS 重新运行退出用例均通过。

Observer 的 `/observer off` 跨任务保持关闭；显式 `on` 能覆盖禁用的初始间隔。15 秒心跳只更新存活时间，不伪造活动时间；快照有效期 90 秒。摘要请求不重叠，45 秒超时，关闭时取消的只是独立摘要请求。限定摘要输入保留有效 JSON、全体会话计数和阶段计数，明确省略了多少会话细节。

2026-10-10 本地 26 个 Node 测试、六个 shell 回归和秘密扫描通过。最新 `harness doctor` 退出 0、耗时 10.290 秒，日志为 `~/ahsb-build/validation/doctor-observer-final.log`。生命周期单测不冒充真实 provider、真实超时网络或 GUI 验收。

失败记录保留：Linux 初次内存退出失败 `20261010T095223Z-QepeCE`；macOS 探针 NOT_READY `20261010T095837Z-89294`；一次组合 GUI/自动加载命令被外层 90 秒预算中断，其后自动加载目录 `20261010T101725Z-90121` 不计为通过。

## 宿主 Harness 修复

Engine 验证子进程清除继承的 `PI_CODING_AGENT_DIR`，使用 `PI_OFFLINE=1`；测试夹具隔离 Git/HOME/XDG，保留生产环境拒绝 Git 自定义 filter 和 `pi-h` 嵌套启动的安全检查。launcher 保留正确的 SIGTERM→143 语义，补充超时诊断和有限预算。

六层控制面测试、doctor-benchmark 单测及完整 `harness doctor` 已通过。三轮串行/并行的真实 doctor 基准全部退出 0：串行中位 27.119 秒、并行中位 11.505 秒，降低 57.6%；本轮并行 20 秒预算通过。报告含两仓身份、覆盖和耗时，位于 `~/ahsb-build/validation/perf-env-isolation-20261010T090926Z/report.json`。没有历史可比基线，不宣称相对历史版本提速。Catalog 的用户改动未覆盖，未 compose/apply 或更改认证。

## DeepSeek Flash 真实验收（2026-10-12）

用户明确指定 `deepseek / deepseek-flash`（当时目录名称为 DeepSeek V4.1 Flash），授权最多两次请求。不改变当前会话默认模型。凭据仅由宿主原生 `ModelRuntime` 解析，未输出、未复制进 VM 或 Git。

两名真正的 guest Pi 工作进程照常加载 Observer；普通工作请求由 guest 本地夹具保持等待，只有 Observer 的独立摘要请求通过 guest loopback → vsock → alpha loopback → 固定 SSH 隧道 → 宿主 loopback 代理提交真实模型。因此验证的是 Observer 真实摘要，不是普通任务已经使用真实模型完成业务。

代理只接受指定模型、system/user 两条消息、无工具、两个活动会话的观测数据；保留独立 session ID、关闭重试、每次最多 160 输出 tokens、最多两次调用。重启也从证据恢复已用次数，不重置授权额度。只记录模型、角色、计数、摘要、用量和耗时，不记录凭据、请求头、服务 URL 或完整请求体。

实机退出 0，业务断言 PASS：alpha 的 `~/ahsb-build/observer-deepseek-20261012T015233Z/runs/linux-observer-real-provider/20261012T015233Z-mI2nTI/`。guest 保存的两份摘要与代理的真实返回文本逐一匹配，不接受本地 fallback；两个 PID 不同，退出后 snapshot/summary 完全清理。已有固定版本镜像被复用，没有安装或升级。

两次返回：

- 1277ms：主会话和子会话各有一个 Pi 处于活跃状态，均在思考阶段且刚开始第 0 轮。
- 701ms：主会话和子会话都刚启动并处于第 0 轮思考阶段。

总输入 868、输出 42 tokens；SDK 目录估算费用合计 0.0003108 USD，不是账户实际账单。两次均 `stopReason=stop`，没有发起第三次请求。

最终 27 个 Node 测试、语法检查、秘密扫描及 `harness doctor` 全部通过；doctor 为 11.665 秒、退出 0，日志在 `~/ahsb-build/validation/doctor-deepseek-final.log`。另将宿主两次完成记录与 guest 两份已保存摘要逐一交叉匹配，断言通过。

宿主证据及已取回的 Linux 断言、运行时回执、源码 SHA 和摘要保存在 `~/ahsb-build/validation/deepseek-observer-20261010T122251Z/`，全部位于 Git 外。实验结束后，自己的 vsock/mock 进程、SSH 隧道及宿主代理均关闭。

此前失败未抹去：alpha 的 SSH/转发曾超时；macOS fallback 曾因外层预算中断、代理端口就绪竞争、OpenAI 文本块解析不匹配及 Pi 版本探针 30 秒超时失败。修复文本块解析与就绪检查后，恢复的 Linux 链路通过；macOS 的真实 provider 路线仍没有通过记录，没有放宽探针预算或把它算成成功。

## 持续适用的覆盖边界

观察对象必须加载扩展并使用同一 Observer 目录：既有未加载进程、`--no-extensions` 或隔离的 agent 目录不会凭空受到观察。普通 guest Pi 的自动加载已验证；公共基底不含项目代码，部署仍属于使用者初始化，不是所有 sandbox runner 无条件安装项目扩展。

本次不修改原资产认证范围：跨 Mac 验证、完整 Linux 十用例套件和 Linux Tart 正向仍未被本次结果证明。镜像、缓存、VM 身份、认证和输出全部留在 Git 外。
