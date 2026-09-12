# Node Suite

自用的一体化节点套件：OpenWrt/Kwrt 路由器、Debian/Ubuntu VPS、Cloudflare Worker/Pages/D1 与 Telegram Bot。

当前只维护这一套：

- Node Suite：`1.2`
- Cloudflare / Telegram：`3.7.0`
- Xray：`v26.7.28`
- 当前固定代码提交：`388448e61825f82185b78d4b8d477b350e48b29c`

下面所有安装命令都固定到这个不可变提交。

当前仓库只保留必要入口：路由器目录对外只有 `install-router-complete.sh` 和 MIPS 离线 Xray 辅助脚本；Cloudflare 对外只执行 `cloudflare/deploy-complete.sh`，其它脚本、源码、schema、Pages Function、依赖锁和测试文件都是它的运行或校验依赖，不需要手工执行。

## 1. REALITY SNI 自动选择

路由器和 VPS 安装时会测试 12 个候选域名。每个域名连续严格握手 3 次，3 次都必须满足：

- TLS 1.3
- ALPN `h2`
- 证书与域名匹配
- 当前设备可正常连接

通过后取 3 次 TLS 握手延迟的中位数，最终选择中位数最低的域名，并自动设置：

```text
SNI=<选中域名>
target=<选中域名>:443
```

候选域名：

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

任意一次严格握手失败，该域名本轮直接跳过。

## 2. 部署 Cloudflare / Telegram

在 Mac 终端执行：

```bash
(
set -eu
REF='388448e61825f82185b78d4b8d477b350e48b29c'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-suite-cf.XXXXXX")"
git clone --no-checkout https://github.com/sajik1/node-suite.git "$WORK/repo"
cd "$WORK/repo"
git checkout --detach "$REF"
bash -n cloudflare/deploy-complete.sh
bash cloudflare/deploy-complete.sh
)
```

要求：Node.js 22+、npm、Cloudflare 账号。

已有项目升级时继续填写原 Worker、D1、Pages 项目名称和原 Bot Token。脚本会复用现有 D1、设备、权限和加密密钥；不要因为一次 Cloudflare API 网络错误临时换项目名或新建 D1。

部署完成后检查：

```bash
curl -sS --noproxy '*' 'https://你的Pages项目.pages.dev/health'
```

应返回：

```text
"ok":true
"version":"3.7.0"
```

## 3. 安装或升级路由器节点

在 OpenWrt/Kwrt SSH 终端执行：

```sh
REF='388448e61825f82185b78d4b8d477b350e48b29c'
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

安装器会优先复用现有设备身份、节点端口和密钥，不会主动接管无关 SSH/代理配置。已有 sing-box/SS 备用节点不会在新 VLESS 验收前自动删除。

仓库中不再放单独的 router base 文件。`install-router-complete.sh` 会自行获取固定且经过 SHA256 校验的内部基础源码，GitHub Raw 超时后自动切换 Contents API，再应用当前补丁并做语法/锚点校验后执行。

### MIPS/MT7621 离线 Xray

Mac 执行：

```bash
cd ~/Downloads
rm -rf node-suite-1.2
git clone https://github.com/sajik1/node-suite.git node-suite-1.2
cd node-suite-1.2
git checkout 388448e61825f82185b78d4b8d477b350e48b29c
sh router/fetch-offline-xray-mips-softfloat-mac.sh
```

按脚本提示上传后，再执行路由器安装命令。

## 4. 安装或升级 VPS 节点

支持 Debian / Ubuntu + systemd。在 VPS SSH 终端执行：

```bash
REF='388448e61825f82185b78d4b8d477b350e48b29c'
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

首次安装随机生成 VLESS TCP 入站端口；已有节点默认复用原端口和密钥。云安全组必须放行最终显示的 TCP 端口。

## 5. Telegram 使用

主菜单：

```text
节点管理
Bot 管理
```

权限：

| 角色 | 权限 |
| --- | --- |
| 只读 | 查看设备、节点、SSH、状态、刷新和外部探测 |
| 控制 | 只读功能 + 配对/移除设备、修改节点、重启、维护、root Shell |
| 管理员 | 全部功能 + 用户权限、Bot 设置、群管理 |

至少保留一位管理员。

常用功能：

- `节点管理 → 添加设备`：获取 Pages 地址和一次性配对码。
- `当前节点`：只返回一条 Quantumult X 整行配置，并自动加入当前 SNI 对应的 `server_check_url`。
- `节点配置 → 修改 SNI`：修改后 target 自动同步为 `SNI:443`。
- `实时刷新`：立即请求设备重新上报状态。
- 节点监听端口、UUID、REALITY 密钥、Short ID 可单独修改。

群聊使用：

- 在 `Bot 管理 → 群聊管理` 启用群 ID。
- “全员可用 Bot”开启后，未单独授权的普通群成员只有只读权限；管理员始终可用。
- 群内命令需要 `@机器人用户名`，按钮不需要 @。
- 自动管群支持屏蔽词、链接/媒体过滤、防刷屏、入群验证、欢迎语、群规、删除/禁言/封禁。
- Bot 要执行删除、禁言、封禁或置顶，必须在 Telegram 群里拥有对应管理员权限。
- Telegram 匿名管理员显示为群身份，Bot 无法还原真实个人身份。

常用群命令：

```text
/del@Bot用户名
/ban@Bot用户名
/unban@Bot用户名
/kick@Bot用户名
/mute@Bot用户名 60
/unmute@Bot用户名
/pin@Bot用户名
/unpin@Bot用户名
/rules@Bot用户名
/grouphelp@Bot用户名
/cancel
```

## 6. 重复部署规则

已有设备升级时：

- Cloudflare/TG 更新不要求重装路由器或 VPS。
- 已配对设备不需要重新配对。
- 重新执行节点安装器会优先复用现有身份、端口和密钥。
- 只有新增设备才生成新的配对码。
- Cloudflare API 临时失败时，恢复网络后继续使用同一固定提交和同一项目名称重跑。

## 7. 节点状态说明

```text
公网可连接 / 公网入站已验证
```
Cloudflare 当前探测点已经连通节点 TCP 端口。

```text
外部探测未确认
```
设备有公网地址且本机监听正常，但 Cloudflare 当前探测点未连通；不代表其它公网客户端一定不可用。

```text
本机 TCP 未监听
```
节点服务自身没有监听配置端口，需要检查 Xray/服务状态。

## 8. 本地检查

Cloudflare/TG 代码：

```bash
cd cloudflare
npm ci
npm run check
npm test
```

路由器/VPS 脚本提交前必须通过 shell 语法检查，仓库 GitHub Actions 会自动执行。
