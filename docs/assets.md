# 找到并复用已有测试镜像

面向接手仓库或更换机器的 agent/开发者。目标是复用成熟基底，不是重新安装操作系统。镜像保存在本机或私有 alpha 文件服务；源码在 Git，镜像、私钥、下载凭据和本机选择不入 Git。

## 先发现，再决定是否下载

在仓库运行只读发现入口：

```bash
bin/locate-assets.sh
```

它只报告配置/归档的位置、已有 Linux 启动文件和 Tart inventory，不读取凭据、不启动 VM、不联网下载。Tart 列表中的名字或 `ready` 字样不是验收证明。

按下面的顺序处理，每一步完成后再走下一步：

1. **本机已有配置和基底**：检查发现的私有 `macos-ready.env`，确认是本机管理员维护的文件、权限 600，之后在自己的 shell 载入。核对 `TART_BASE_VM` 存在、OS 正确且停机；复用它跑用例，不重新导入或授权。
2. **有本机归档，没有适合的基底**：按仓库资产目录校验归档，再导入一个不存在的本地名字，注入自己的 SSH 公钥。
3. **本机缺镜像**：读取 [资产目录](../assets/catalog.json)，使用已有只读配置从 alpha 获取。没有账号/CA/Tailscale 访问时，向管理员申请这些具体权限；镜像的位置已经明确，不把授权缺口误判为需要从零构建。
4. **需要新工具或升级系统**：才进入 [GUI 基底准备](macos-gui-seed.md)，在独立克隆准备并验收，保留旧基底。

### 本机标准位置

| 内容 | 默认位置/发现方式 |
| --- | --- |
| Tart 运行基底 | `tart list`；Tart 默认存储为 `~/.tart/vms/`，让 Tart 管理，手工搬目录会破坏元数据 |
| macOS 分发归档 | `~/Library/Application Support/agent-harness-sandbox/images/macos-ready.tvm`；另识别 `~/.local/share/agent-harness-sandbox/images/macos-ready.tvm` |
| Mac 私有运行配置 | `~/Library/Application Support/agent-harness-sandbox/macos-ready.env` |
| 私有下载配置 | Mac 同一目录的 `download.curl`；或 `~/.config/agent-harness-sandbox/download.curl` |
| Linux 启动文件 | `$OUT/ahsb.raw`、`$OUT/ahsb.vmlinuz`、`$OUT/ahsb.initrd`；默认 OUT 为 `~/ahsb-build` |

这些是发现约定，不是把某台机器的 VM 名或私钥路径硬编码为其他机器的默认值。归档与可运行基底不同：归档可保存/传递，Tart 基底用于每例克隆。

## alpha 的资产目录与访问

[assets/catalog.json](../assets/catalog.json) 是非机密的工程声明：服务 URL、平台、当前归档大小/SHA256、guest SSH 主机公钥与已验证范围。服务是只读私有文件托管，不是 OCI registry、CI runner 或远程 VM 执行 API；不需要 GitHub Packages token。Linux 归档约 1 GiB，macOS 完整桌面归档约 22 GiB；不是两个同样大小的裁剪系统。

访问需要：

- 接收端加入获授权的 Tailscale 网络，能够访问目录中的服务地址；
- 管理员给出的只读下载账号；
- 通过可信渠道取得私有 CA 证书，指纹与 catalog 的 `caCertificateFingerprintSha256` 一致。

`download.curl` 存放账号、CA 路径和必要的地址解析设置，权限 600，**不打印、不提交**。CA 只用于这些请求，不导入系统信任库；不用 `curl -k`。新机器不能直接复制另一机器的私钥或带旧绝对路径的配置，应设置自己的 CA 路径。

在仓库中读取工程声明，并先取小文件或 HEAD：

```bash
BASE=$(node -p 'require("./assets/catalog.json").baseUrl')
CONFIG="/absolute/private/path/download.curl"
DEST="$HOME/Library/Application Support/agent-harness-sandbox/images"
umask 077
mkdir -p "$DEST"
curl --config "$CONFIG" --noproxy '*' --max-filesize 65536 \
  "${BASE}asset-manifest.json" -o "$DEST/asset-manifest.json"
curl --config "$CONFIG" --noproxy '*' --head "${BASE}macos-ready.tvm"
```

远端 manifest 必须声明 `published`，归档大小与 SHA256 必须与仓库 catalog 一致。若不同，停止并确认是否换了当前快照，不静默跟随新镜像。源码契约 SHA 是测试时使用的代码身份，不是稳定接口承诺；此分支新增发现/注入入口没有改变镜像内工具或用例定义。

**仅在确实缺少所需归档时下载**。下例不覆盖完成文件，超时/断线保留 `.partial`，再次执行同一条 curl 可续传；给长下载设置自己的预算和文件大小检查点。

```bash
(
set -e
test ! -e "$DEST/macos-ready.tvm"
curl --config "$CONFIG" --noproxy '*' --continue-at - --max-time 259200 \
  "${BASE}macos-ready.tvm" -o "$DEST/macos-ready.tvm.partial"
EXPECTED=$(node -p 'require("./assets/catalog.json").assets["macos-gui"].sha256')
ACTUAL=$(shasum -a 256 "$DEST/macos-ready.tvm.partial" | awk '{print $1}')
test "$ACTUAL" = "$EXPECTED"
mv -n "$DEST/macos-ready.tvm.partial" "$DEST/macos-ready.tvm"
)
```

不要为“确认发布”再把整个镜像下载一次：远端上传过程已校验整档 SHA256。日常托管健康检查用 manifest/校验回执、HEAD 和最多 1 KiB Range 即可；本机首次拿到的新归档仍须完整校验后再导入。

## macOS：导入、公钥注入、四项验收

接收端需要 Apple Silicon Mac、Tart、Node.js、SSH 工具以及用例断言要求的工具（见 [Tart 后端](macos-tart.md)）。共享基底先克隆到自己独占的名字；以下 `ahsb-macos-ready` 是接收端自行选定、必须尚不存在的例子。

```bash
(
set -e
tart import "$DEST/macos-ready.tvm" ahsb-macos-ready
umask 077
mkdir "$DEST/private"
ssh-keygen -q -t ed25519 -N '' -C sandbox-local -f "$DEST/private/id_ed25519"
bin/enroll-tart-key.sh ahsb-macos-ready "$DEST/private/id_ed25519.pub" admin
node -p '"ahsb-guest " + require("./assets/catalog.json").assets["macos-gui"].guestHostKey' \
  > "$DEST/private/known_hosts"
export TART_BASE_VM=ahsb-macos-ready
export TART_GUEST_USER=admin
export TART_SSH_KEY="$DEST/private/id_ed25519"
export TART_KNOWN_HOSTS="$DEST/private/known_hosts"
for case in macos-pi-discovery macos-desktop-smoke macos-iterm-smoke macos-browser-smoke; do
  bin/test.sh "$case"
done
)
```

运行配置可保存在上表的私有 `macos-ready.env`，后续先复用此配置。不要覆盖已有密钥或已被其他 agent 使用的基底。

分发基底的 `authorized_keys` 为空；`bin/enroll-tart-key.sh` 通过 Tart Guest Agent 的普通用户 RPC 写入接收人的公钥，不分享制作人的私钥。它要求停机本地名字、ED25519 公钥以及非 root guest 身份；最多 120 秒等 RPC，每次 RPC 调用最多 5 秒。它只停止自己启动的 VM，保留接收端基底，正式 runner 再为每条用例创建和删除独立克隆。

guest agent v0.15.0 通过上游 release checksum 验证后安装，二进制摘要记录在 catalog。其配置源码为 [RPC-only LaunchAgent](../assets/macos/tart-guest-rpc.plist)，以 guest `admin` 运行，不是 root daemon；不启用 clipboard/vdagent、磁盘扩容、宿主挂载或查看器。新增工具/权限主体可能需重新授权；不能以 RPC 可用替代 GUI/TCC 验收。

**完成标准**：四条用例 guest rc=0、assert PASS；逐一查看 GUI 图，确认 Calculator12、iTerm 中真实 pi 输出、Chrome 输入/回显；测试克隆已清理、基底停机。同 Mac 的归档导入、公钥注入及四项已实测，**跨 Mac 的 GUI/TCC 保留仍未验证**。缺权限回独立准备阶段，不回退宿主、不绕过 SIP/TCC。pi 会话 clone/fork 和 iTerm 原生 AppleScript API 不在通过范围。

## Linux：复用已有启动文件

只需要 Linux 时下载 `linux-vmspawn.tar.zst`，按 catalog 校验该归档的 SHA256；解包到独立的 `OUT`，再校验内部的三个启动文件：

```bash
mkdir /your/private/linux-image
zstd -dc /path/to/linux-vmspawn.tar.zst | tar -xf - -C /your/private/linux-image
(cd /your/private/linux-image && sha256sum -c SHA256SUMS)
# 前置条件齐备且 mock 的端口/所有权已协调后，在 Linux 非 root 用户运行：
OUT=/your/private/linux-image EXECUTION=local bin/test.sh port-scan
```

这是 x86_64 vmspawn 镜像，不是 ARM64 Tart seed；Linux guest 无网卡，macOS Tart 仍是 NAT。三个真实用例已通过，完整 Linux 十条套件尚未补齐。不要借用别人正在运行的 mock 或同步共享运行树；Linux mock 默认端口的并发正确性未验收，见 [接入边界](../README.md)。

## 当前交付边界

镜像和恢复说明已在 alpha 发布，上传者 Mac 关机不影响 alpha 已存文件；alpha 离线时下载不可用。镜像含私有 guest 账户/自动登录状态，应受控分发。Git 保存本目录、测试代码和非机密清单；服务密码、CA 私钥、镜像、大文件分块、传输日志与机器偏好留在私有目录。

仍无稳定发布 tag；固定代码 SHA 并验证集成。发现入口只定位资产，不能将未执行的 Linux 全套、跨 Mac GUI 或会话 GUI 验收变成通过结论。
