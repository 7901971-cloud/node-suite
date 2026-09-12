# Node Suite 1.2

安装器会检测现有配置：存在本套件配置时复用设备身份、节点参数和数据库；不存在时执行全新安装。不会接管无关的 SSH 或代理配置。

当前组件版本：

- 路由器安装器：`1.2`
- VPS 安装器：`1.1.3`
- Cloudflare / Telegram 控制中心：`3.7.0`

当前固定代码提交：`aa1a7d6dfce324ae51daf5aa94e3d504af18e0a0`。下面的部署/安装命令均固定到该不可变提交，不会因为 `main` 后续变化而执行未知代码。

> `npm ci` 日志里的包名仍可能显示 `node-center-cloudflare-tgbot@3.6.0`，这是基础包元数据；安装时 `apply-index-patch.mjs` 会应用 3.7 运行时补丁，最终以 `/health` 返回的 `version":"3.7.0"` 为实际控制中心版本。

## 最新变化

### REALITY SNI / target 自动选择

路由器和 VPS 安装器会在安装/复用流程中自动测试 12 个内置候选域名。每个候选会连续进行 **3 次严格 TLS 握手**，只有 3 次全部满足以下条件才进入延迟排名：

- TLS 1.3 握手成功
- ALPN 协商为 `h2`
- 证书与域名匹配并验证通过
- 当前机器可以正常连接

通过严格检查后，脚本取该域名 **3 次握手延迟的中位数**，再从 12 个候选中选择中位数最低的域名作为 REALITY SNI，并自动同步：

```text
SNI=<选中的域名>
target=<选中的域名>:443
```

这种方式不会因为某一次偶然的超低延迟就选错目标，同时任意一次严格握手失败都会让该候选跳过，更偏向长期稳定性。

12 个候选域名：

```text
www.apple.com
www.microsoft.com
www.mi.com
www.samsung.com
www.intel.com
www.douyin.com
www.qq.com
www.10086.cn
www.10010.com
www.189.cn
www.bing.com
www.tiktok.com
```

其中 `www.baidu.com` 已替换为 `www.douyin.com`，并新增 `www.bing.com` 与 `www.tiktok.com`。`www.10086.cn`、`www.10010.com`、`www.189.cn` 分别为中国移动、中国联通、中国电信官网候选。所有域名都不会被强制优先，仍然必须通过 3 次 TLS 1.3 / h2 / 证书校验，并按当前设备实测的 3 次握手中位数选择。

### Telegram 当前节点 / 节点配置

Cloudflare 3.7.0 调整了节点展示和配置逻辑：

- 点击 **当前节点** 只返回 **1 条 Quantumult X 整行导入配置**，不再额外返回第二条标准 `vless://` 链接。
- Quantumult X 配置会根据当前 SNI 自动加入：

```text
server_check_url=http://<当前SNI>/generate_204
```

例如当前 SNI 为 `www.mi.com`：

```text
server_check_url=http://www.mi.com/generate_204
```

- 节点配置中的 REALITY 入口统一为 **修改 SNI**；修改后 target 仍自动同步为 `SNI:443`。
- **节点端口**仍保留单独修改，因为它是 VLESS/Xray 的入站监听端口，不是 REALITY target 的 `443`。
- UUID、REALITY 密钥和 Short ID 仍可按原逻辑管理。

### 外部入站检测

Cloudflare 的 TCP 外部探测只代表 **Cloudflare 当前出口到节点公网地址/端口** 的可达性，不再把一次外部连接失败直接等同于“节点公网不可用”。

新版逻辑：

- TCP 外部探测最多重试 3 次。
- 探测成功：显示 `公网入站已验证` / `公网可连接`。
- Cloudflare 探测失败，但设备本机确认 Xray TCP 正常监听：显示 `外部探测未确认`，不会误报为入站失败。
- 本机 TCP 自身未监听：显示 `本机 TCP 未监听`。
- 同一公网地址和端口此前已经验证成功时，临时探测失败不会轻易把已验证状态降级。

因此 `外部探测未确认` 的含义是：**当前 Cloudflare 探测点没有连通，但不能据此证明其它公网客户端无法连接。**

Cloudflare 3.7.0 的上述 Telegram/UI/探测逻辑不需要重新安装路由器或 VPS，也不需要重新配对设备；重新部署 Cloudflare 后点击 **实时刷新** 即可使用新版逻辑。

### Telegram Webhook 重部署保护

Cloudflare 重部署时，Webhook Secret 现在由当前 Bot Token 稳定派生；使用同一个 Bot Token 重部署不会每次先随机轮换 Secret，避免 `setWebhook` 临时失败后出现“Worker 已换 Secret、Telegram 仍带旧 Secret”的失配状态。

Webhook 设置流程同时增加：

- `setWebhook` 最多重试 3 次。
- 不再用 `curl -f` 吞掉 Telegram 的 400 响应正文；失败时会直接显示 Telegram 原始错误，方便定位。
- Worker Webhook 设置失败时，如果同名 Pages 网关已经存在且 `/health` 正常，会自动尝试 `https://<Pages项目>.pages.dev/telegram/webhook`。
- `setMyCommands` 会自动重试；最终仍失败只报警，不隐藏 Telegram 原始返回。

如果一次部署停在 Telegram API 错误，直接使用本 README 的同一固定部署命令重新运行即可；不需要重新安装路由器/VPS，也不需要重新配对已有设备。

### Pages 网关部署保护

Pages 部署阶段现在对 Cloudflare API 瞬时 `fetch failed` 做完整容错：

- `wrangler pages project list --json` 最多重试 3 次。
- 如果项目列表 API 连续失败，但 `https://<Pages项目>.pages.dev/health` 已经正常，会据此确认同名 Pages 项目确实存在，直接走复用逻辑，不会误判成“需要创建新项目”。
- 只有项目列表和稳定 Pages 健康检查都无法确认现有项目时，才尝试创建；创建请求也会重试 3 次。
- `wrangler pages deploy` 同样最多重试 3 次。
- 稳定 Pages 地址直接使用 `https://<Pages项目>.pages.dev`，不再依赖部署后的第二次项目列表查询。
- Cloudflare 登录状态先重试确认；普通 `fetch failed` 不会立即重复触发 OAuth。只有明确的登录/认证错误才打开浏览器重新登录。

Pages Function 部署成功且 `/health` 已通过后，脚本会把稳定的 Pages 地址写入 Worker 的 `PUBLIC_GATEWAY_URL`，用于 Telegram 菜单和云端回退：

- `wrangler secret put PUBLIC_GATEWAY_URL` 最多重试 3 次。
- 如果复用的是已经存在的同名 Pages 项目，Pages 稳定地址本身没有变化，而写 Secret 连续失败，则保留 Worker 中原有 `PUBLIC_GATEWAY_URL` 并以警告结束，不再把这种临时 API 故障误判成整套部署失败。
- 如果是首次新建 Pages 项目，新的 Pages 地址从未写入 Worker，而 3 次写入仍全部失败，则继续失败关闭，避免留下不完整的新部署。

因此，若本机访问 Pages `/health` 正常，但 Wrangler 的项目列表、创建、部署或 Secret 写入阶段出现 `fetch failed`，首先应视为 **Mac 到 Cloudflare 管理 API 的临时网络/代理问题**，而不是路由器、VPS、D1 或 Pages 公网入口本身故障。

### Worker / D1 重部署保护

完整部署的第一阶段也加入了与 Pages 相同的保护，避免下次在 Worker/D1 阶段重新遇到同类问题：

- Cloudflare `whoami` 先重试 3 次；普通网络错误不会误判为“登录失效”。
- D1 列表读取最多重试 3 次；如果始终无法读取，会安全停止，**不会因为 API 故障误创建第二个数据库**。
- D1 首次创建、schema 初始化、兼容数据更新均带重试。
- Worker Secret 列表最多重试 3 次。若现有 Worker 的 Secret 列表无法确认，会在写入任何 Secret 前停止，避免把网络故障误判为“没有 `DATA_ENCRYPTION_KEY`”。
- 已存在的 `DATA_ENCRYPTION_KEY` 永远优先保留；不会因为 Secret 查询失败而随机生成新密钥覆盖旧值。
- Telegram Bot Token、Webhook Secret、Owner、Bot 用户名等 Secret 写入均最多重试 3 次。
- Worker 部署最多重试 3 次；Worker `/health` 也会重复检查。

这项保护很重要：已有设备的 `node_cipher` 依赖原 `DATA_ENCRYPTION_KEY`。因此脚本现在宁可在无法确认 Secret 状态时停止，也不会冒险轮换数据加密密钥。

### 重复部署原则

已有项目以后升级时：

- 继续填写 **原 Worker 名称、原 D1 名称、原 Pages 项目名称、原 Bot Token**。
- 不要因为一次 `fetch failed` 临时换项目名、重新建 D1 或重新创建 Bot。
- 脚本最终因 Cloudflare API 网络错误停止时，恢复网络后直接重跑**同一固定提交、同一名称**即可。
- 已有路由器/VPS **不需要重新配对**；D1 内设备、权限、节点记录继续复用。
- 只有首次添加一台新设备时，才从 Telegram → 节点管理 → 添加设备 获取新的配对码。

## 1. 部署或复用 Cloudflare / Telegram

在 Mac 终端执行：

```bash
(
set -eu
REF='aa1a7d6dfce324ae51daf5aa94e3d504af18e0a0'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-suite-cf.XXXXXX")"
git clone --no-checkout https://github.com/sajik1/node-suite.git "$WORK/repo"
cd "$WORK/repo"
git checkout --detach "$REF"
bash -n cloudflare/deploy-complete.sh
bash cloudflare/deploy-complete.sh
)
```

需要 Node.js 22+、npm 和 Cloudflare 账号。同名 Worker、D1、Pages 存在时复用，不存在时创建。原数据加密密钥存在时会保留。更新现有 Bot 时填写原 Worker、D1 和 Pages 名称；部署会复用现有设备与权限数据。

部署完成后 `/health` 应显示 Cloudflare 控制中心版本 `3.7.0`。

## 2. 安装或复用路由器节点

在 OpenWrt/Kwrt 的 SSH 终端执行：

```sh
REF='aa1a7d6dfce324ae51daf5aa94e3d504af18e0a0'
RAW="https://raw.githubusercontent.com/sajik1/node-suite/$REF/router/install-router-complete.sh"
API="https://api.github.com/repos/sajik1/node-suite/contents/router/install-router-complete.sh?ref=$REF"
OUT='/tmp/install-router-complete.sh'

rm -f "$OUT"
(
  curl -4 -fL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 2 "$RAW" -o "$OUT" || \
  curl -fL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API" -o "$OUT"
) && \
chmod 700 "$OUT" && \
sh -n "$OUT" && \
sh "$OUT"
```

下载外层已设置单次总超时：GitHub Raw 如果建立连接后一直不返回数据，最长 45 秒就会失败并自动切换 GitHub Contents API，不会再无限卡在 `0 bytes`。路由器安装器 1.2 自己下载固定基础脚本时，Raw 最长等待 30 秒后立即切换 Contents API；API 也有 45 秒总超时和重试，之后才会尝试 `uclient-fetch` / `wget`。因此外层和内层都不会再因为 Raw 已连接但 0 bytes 而长时间挂死。

路由器安装器 1.2 会固定读取经过 SHA256 校验的 1.1 基础安装器，再做确定性补丁后执行。现有套件节点默认复用设备身份、端口和密钥；旧 sing-box/SS 节点不会在新 VLESS 验收前被自动删除。

REALITY SNI 和 target 不再手工输入。安装时每个候选域名连续严格测试 3 次，只有 3 次全部通过才参与比较，并选择 3 次 TLS 握手延迟中位数最低的目标；target 自动同步为 `SNI:443`。

MT7621/MIPS 路由器无法直接下载 Xray 时，在 Mac 执行：

```bash
cd ~/Downloads
rm -rf node-suite-1.2
git clone https://github.com/sajik1/node-suite.git node-suite-1.2
cd node-suite-1.2
git checkout aa1a7d6dfce324ae51daf5aa94e3d504af18e0a0
sh router/fetch-offline-xray-mips-softfloat-mac.sh
```

按提示上传 Xray 后，回到路由器重新执行上面的安装命令。

## 3. 安装或复用 VPS 节点

支持 Debian / Ubuntu 和 systemd。在 VPS SSH 终端执行：

```bash
REF='aa1a7d6dfce324ae51daf5aa94e3d504af18e0a0'
RAW="https://raw.githubusercontent.com/sajik1/node-suite/$REF/vps/install-vless-reality-vps.sh"
API="https://api.github.com/repos/sajik1/node-suite/contents/vps/install-vless-reality-vps.sh?ref=$REF"
OUT='/root/install-vless-reality-vps.sh'

rm -f "$OUT"
(
  curl -4 -fL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 2 "$RAW" -o "$OUT" || \
  curl -fL --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 2 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API" -o "$OUT"
) && \
chmod 700 "$OUT" && \
bash -n "$OUT" && \
bash "$OUT"
```

VPS 外层下载同样有 45 秒总超时；Raw 卡住时会自动转 Contents API，不会无限等待。

VPS 安装器 1.1.3 固定读取 `v1.1` 的完整基础安装器，在本机做确定性补丁后执行；基础脚本不会从可变 `main` 获取。

当前 VPS 安装器包含：

- Quantumult X 节点名称只输入一次，Telegram 设备名称自动保持一致。
- GitHub Raw 优先走 IPv4；Raw 异常时回退 GitHub Contents API。
- REALITY SNI / target 对 12 个候选分别进行 3 次严格握手，只有 3 次全部通过才参与比较，并选择 3 次握手延迟中位数最低的目标。
- target 自动同步为 `SNI:443`。

首次安装会随机生成 VLESS TCP 入站端口；已有节点默认复用原端口和密钥。云安全组必须放行最终显示的 TCP 入站端口。

## 4. Telegram 使用

- 主菜单只有 **节点管理 / Bot 管理** 两部分。
- 节点管理 → **添加设备**：同一张卡片获取 Pages 地址和一次性配对码。
- 设备 → **实时刷新**：通过命令代理立即要求设备完整上报，通常约 10 秒返回。
- **当前节点**：只返回 1 条 Quantumult X 整行导入配置，并自动带当前 SNI 对应的 `server_check_url`。
- **SSH 地址、命令结果**允许复制。
- 节点配置 → **修改 SNI**：输入新域名后，设备同步更新 REALITY SNI 和 `<域名>:443` target；客户端需重新导入节点。
- 节点监听端口、UUID、REALITY 密钥、Short ID 仍按独立配置项管理。
- **管理员**：所有功能，包括添加/删除用户与管理员、Bot 设置、群规则；至少保留一位管理员。
- **控制用户**：设备管理、配对/移除、改节点配置、重启和 root Shell；不能改 Bot 权限。
- **只读用户**：查询设备、节点与 SSH 信息及刷新状态，不能修改设备配置。
- Bot 管理 → **群聊管理**：添加/停用群 ID。已授权用户在启用群内继承原角色；“全员可用 Bot”默认关闭，开启后普通群成员获得只读使用权，管理员始终可用。
- 群聊命令要 `@Bot用户名`；按钮无需 @。自动管群会检查未 @ 的普通消息、编辑后的消息和入群事件。
- 管群支持屏蔽词、内容自动删除/禁言/封禁、防刷屏、入群验证、欢迎语和群规；均默认关闭，需为 Bot 授予相应群管理员权限。
- 风控规则会检查普通成员、Telegram 群管理员和匿名管理员发出的内容。管理员或匿名管理员命中“禁言/封禁”类规则时，只删除违规消息，不尝试限制管理员本身。
- Telegram 开启“匿名管理员/保持匿名”后，Bot 收到的是群身份而不是真实用户身份，因此可以过滤和删除违规消息，但无法还原该匿名管理员的真实名字，也无法按真实用户执行禁言/封禁。若要群消息显示个人名字，请关闭对应管理员的匿名模式。

详细步骤与命令：[Telegram 管理说明](docs/telegram-management.md)。

Quantumult X 当前节点示例：

```text
vless=example.duckdns.org:35930, method=none, password=<UUID>, obfs=over-tls, obfs-host=www.mi.com, reality-base64-pubkey=<PUBLIC_KEY>, reality-hex-shortid=<SHORT_ID>, vless-flow=xtls-rprx-vision, udp-relay=true, fast-open=false, server_check_url=http://www.mi.com/generate_204, tag=节点名称
```

## 5. 网络状态

路由器/VPS 上报公网地址和本机监听状态后，Cloudflare 会尝试从外部测试节点 TCP 端口。

状态含义：

- `公网可连接` / `公网入站已验证`：Cloudflare 外部 TCP 探测成功。
- `外部探测未确认`：设备有公网地址且本机 TCP 正常监听，但 Cloudflare 当前出口没有完成外部连通验证；**不代表其它公网客户端不能使用**。
- `本机 TCP 未监听`：设备自己上报代理 TCP 端口没有监听，需要检查 Xray/服务本身。
- `等待外部检测`：尚未获得有效外部验证结果。
- `无公网地址`：该协议族没有检测到可发布公网地址。

手动点击 **外部探测** 时，Cloudflare 会重试 TCP 探测；若仍失败但设备本机监听正常，会明确提示：

```text
Cloudflare 当前探测点未连通（不代表公网不可用）
```

同一公网 IP 和节点端口此前已验证成功时，后续短暂的 Cloudflare 出口失败不会轻易清除已验证状态。

路由器 DDNS 每 5 分钟检查，并在接口地址变化后触发检查。私网 IPv4、CGNAT 或仅获得 IPv6 地址并不自动代表公网可以入站。