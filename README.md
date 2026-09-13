# Node Suite

自用的一体化节点套件：OpenWrt/Kwrt 路由器、Debian/Ubuntu VPS、Cloudflare Worker/Pages/D1 与 Telegram Bot。

当前只维护这一套：

- Node Suite：`1.3`
- Cloudflare / Telegram：`3.8.1`
- Xray：`v26.7.28`

安装命令跟随 `main`，代码与本文同步维护，不再维护自建安装校验码或下载历史安装器打补丁。路由器与 VPS 均为可直接执行的独立脚本；Cloudflare 直接部署仓库源码。

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
work=$(mktemp -d)
git clone --depth 1 https://github.com/sajik1/node-suite.git "$work/node-suite" && bash "$work/node-suite/cloudflare/deploy-complete.sh"
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
"version":"3.8.1"
```

## 3. 安装或升级路由器节点

在 OpenWrt/Kwrt SSH 终端执行。入口默认先从 GitHub Raw 下载；如果 Raw 的 DNS、TLS 或网络访问失败，会自动切换 jsDelivr。两边都失败才停止本次安装：

```sh
(
OUT=/tmp/install-router-complete.sh
RAW=https://raw.githubusercontent.com/sajik1/node-suite/main/router/install-router-complete.sh
CDN=https://cdn.jsdelivr.net/gh/sajik1/node-suite@main/router/install-router-complete.sh
rm -f "$OUT"
if curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$RAW" -o "$OUT"; then
    echo '安装器下载源：GitHub Raw'
else
    echo 'GitHub Raw 下载失败，自动切换 jsDelivr...'
    curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$CDN" -o "$OUT" || {
        rm -f "$OUT"
        echo '错误：GitHub Raw 与 jsDelivr 均下载失败，本次安装停止。' >&2
        exit 1
    }
    echo '安装器下载源：jsDelivr'
fi
sh "$OUT"
)
```

安装器会优先复用现有设备身份、节点端口和密钥，不会主动接管无关 SSH/代理配置。已有 sing-box/SS 备用节点不会在新 VLESS 验收前自动删除。

安装全部完成后自动删除本次运行的安装脚本；失败、中断、`--preflight` 和 `--version` 不删除。已安装服务、配置和备份保留。GitHub Raw 不可用时入口会自动改用 jsDelivr；只有两个 HTTPS 下载源都失败时才停止安装。仍可在 Mac 克隆仓库后用 scp 上传对应脚本执行。

### MIPS/MT7621 离线 Xray

Mac 执行：

```bash
cd ~/Downloads
work=$(mktemp -d)
git clone --depth 1 https://github.com/sajik1/node-suite.git "$work/node-suite"
cd "$work/node-suite"
sh router/fetch-offline-xray-mips-softfloat-mac.sh
```

按脚本提示上传后，再执行路由器安装命令。

## 4. 安装或升级 VPS 节点

支持 Debian / Ubuntu + systemd。在 VPS SSH 终端执行；同样采用 GitHub Raw → jsDelivr 双源回退：

```bash
(
OUT=/root/install-vless-reality-vps.sh
RAW=https://raw.githubusercontent.com/sajik1/node-suite/main/vps/install-vless-reality-vps.sh
CDN=https://cdn.jsdelivr.net/gh/sajik1/node-suite@main/vps/install-vless-reality-vps.sh
rm -f "$OUT"
if curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$RAW" -o "$OUT"; then
    echo '安装器下载源：GitHub Raw'
else
    echo 'GitHub Raw 下载失败，自动切换 jsDelivr...'
    curl -fL --retry 2 --connect-timeout 10 --max-time 120 "$CDN" -o "$OUT" || {
        rm -f "$OUT"
        echo '错误：GitHub Raw 与 jsDelivr 均下载失败，本次安装停止。' >&2
        exit 1
    }
    echo '安装器下载源：jsDelivr'
fi
bash "$OUT"
)
```

VPS 同样只在安装全部完成后删除本次安装脚本，失败/预检保留。

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
- `设备详情 → 修改设备名`：控制用户和管理员可改名，最多 48 个 UTF-8 字节，不含逗号或控制字符。云端设备列表、节点配置行和后续通知统一采用新名称，旧心跳不会覆盖。通过现有远控同步本地监控配置、节点文件和 VPS 节点名称，无需重装或重启 Xray；执行结果另行通知。离线超过命令的 5 分钟有效期或执行失败时，上线后重新提交同名即可重试。旧 Telegram 消息和已导入客户端的配置不会被追溯编辑，需重新获取/导入。
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
- Cloudflare API 临时失败时，恢复网络后继续使用同一项目名称重跑。

## 7. 节点状态说明

Cloudflare 向已登记的公网 IPv4/IPv6 和节点 TCP 端口建立连接（例如 38444），连接建立后再写入一个极小的探测字节；连接和写入都成功才显示“公网可连接”。失败重试最多 3 次，每次超时 4 秒，不保留旧的成功结果，也不再显示“外部探测未确认”。

完整上报、地址/端口变化、手动探测立即检查；普通心跳距上次探测满 5 分钟再次检查。双栈设备只要任一公网路径连接并写入成功，设备整体就是正常绿色；只有全部可用公网路径都连续失败才进入异常列表、状态汇总和告警。单个地址族的失败仍会在完整状态和外部探测中单独显示，恢复后自动解除。没有公网地址的地址族显示无地址，不当作端口连接失败。

探测字节只用于确认 Cloudflare 能连接端口并成功写入数据，不代表已完成 VLESS 认证或实际代理上网测试；UDP 隧道支持与公网 TCP 可达性分别展示。实现依据：[Cloudflare TCP sockets](https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/)。

自建安装脚本 SHA256 门槛、固定历史提交安装流程及离线二进制自建校验文件已移除。Xray 官方发布包完整性校验、TLS 证书校验、设备认证哈希和运行时变化检测保留，它们不属于自建安装校验码。

## 8. 本地检查

Cloudflare/TG 代码：

```bash
cd cloudflare
npm ci
npm run check
npm test
```

路由器/VPS 脚本提交前必须通过 shell 语法检查，仓库 GitHub Actions 会自动执行。
