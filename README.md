# Node Suite 1.1.2 hotfix

安装器会检测现有配置：存在本套件配置时复用设备身份、节点参数和数据库；不存在时执行全新安装。不会接管无关的 SSH 或代理配置。

当前 GitHub 用户名已更新为 `sajik1`。下面的安装命令固定到不可变提交 `3948e0a25283d452d66f32eb9f7543f7ffdf0645`，不会随 `main` 分支变化。

本次 VPS hotfix 修复三项：

- Quantumult X 节点名称只输入一次，Telegram 设备名称自动保持一致。
- Telegram“当前节点”不再把 `vless:// 通用链接：` 标题误识别为额外节点。
- 下载优先使用 GitHub Raw IPv4；Raw 异常时自动回退 GitHub Contents API，避免部分 VPS 出现 Raw 404/IPv6 路径异常后直接中止。

## 1. 部署或复用 Cloudflare / Telegram

在 Mac 终端执行：

```bash
cd ~/Downloads
rm -rf node-suite-1.1.2
git clone https://github.com/sajik1/node-suite.git node-suite-1.1.2
cd node-suite-1.1.2
git checkout 3948e0a25283d452d66f32eb9f7543f7ffdf0645
bash -n cloudflare/deploy-complete.sh
bash cloudflare/deploy-complete.sh
```

需要 Node.js 22+、npm 和 Cloudflare 账号。同名 Worker、D1、Pages 存在时复用，不存在时创建。原数据加密密钥存在时会保留。

## 2. 安装或复用路由器节点

在 OpenWrt/Kwrt 的 SSH 终端执行：

```sh
REF='3948e0a25283d452d66f32eb9f7543f7ffdf0645'
RAW="https://raw.githubusercontent.com/sajik1/node-suite/$REF/router/install-router-complete.sh"
API="https://api.github.com/repos/sajik1/node-suite/contents/router/install-router-complete.sh?ref=$REF"
OUT='/tmp/install-router-complete.sh'

rm -f "$OUT"
(
  curl -4 -fL --connect-timeout 15 --retry 3 "$RAW" -o "$OUT" || \
  curl -fL --connect-timeout 15 --retry 3 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API" -o "$OUT"
) && \
chmod 700 "$OUT" && \
sh -n "$OUT" && \
sh "$OUT"
```

首次安装会随机生成 TCP 端口；已有节点则默认复用原端口和密钥。默认 SNI/目标为 `www.apple.com:443`。

MT7621/MIPS 路由器无法直接下载 Xray 时，在 Mac 执行：

```bash
cd ~/Downloads
rm -rf node-suite-1.1.2
git clone https://github.com/sajik1/node-suite.git node-suite-1.1.2
cd node-suite-1.1.2
git checkout 3948e0a25283d452d66f32eb9f7543f7ffdf0645
sh router/fetch-offline-xray-mips-softfloat-mac.sh
```

按提示上传 Xray 后，回到路由器重新执行上面的安装命令。

## 3. 安装或复用 VPS 节点

支持 Debian / Ubuntu 和 systemd。在 VPS SSH 终端执行：

```bash
REF='3948e0a25283d452d66f32eb9f7543f7ffdf0645'
RAW="https://raw.githubusercontent.com/sajik1/node-suite/$REF/vps/install-vless-reality-vps.sh"
API="https://api.github.com/repos/sajik1/node-suite/contents/vps/install-vless-reality-vps.sh?ref=$REF"
OUT='/root/install-vless-reality-vps.sh'

rm -f "$OUT"
(
  curl -4 -fL --connect-timeout 15 --retry 3 "$RAW" -o "$OUT" || \
  curl -fL --connect-timeout 15 --retry 3 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API" -o "$OUT"
) && \
chmod 700 "$OUT" && \
bash -n "$OUT" && \
bash "$OUT"
```

VPS 安装器 1.1.2 会固定读取 `v1.1` 的完整基础安装器，在本机做确定性补丁并执行。基础脚本不会从可变 `main` 获取。

首次安装会随机生成 TCP 端口；已有节点则默认复用原端口和密钥。默认 SNI/目标为 `www.apple.com:443`。云安全组必须放行最终显示的 TCP 端口。

安装时只填写一次 `Quantumult X 节点名称`；Telegram 设备名称会自动使用同一个名称。

## 4. Telegram 使用

- 主菜单 → **Pages 地址**：复制当前路由器/VPS 使用的 Pages 入口。
- 设备 → **实时刷新**：通过命令代理立即要求设备完整上报，通常约 10 秒返回。
- **当前节点、SSH 地址、命令结果**均允许复制。
- 管理员是最高权限，可执行全部命令、root Shell、重启整机和修改节点底层配置。
- 禁止把群内所有人设为管理员；可以给群内指定成员管理员权限。
- 群聊中只有包含 `@Bot用户名` 的消息才会回复；点击 Bot 已发出的菜单按钮不受影响。

VPS 的“当前节点”正常只显示两项：

1. `Quantumult X 整行导入`
2. `标准 VLESS 链接`

不会再额外显示只有 `vless:// 通用链接：` 文字的无效节点卡片。

## 5. 网络状态

路由器/VPS 上报公网地址后，Cloudflare 会从外部测试节点 TCP 端口，并在完整状态中显示：

- `公网可连接`：外部 TCP 入站验证通过。
- `TCP 入站未通过`：有公网地址，但端口从外部无法连接。
- `等待外部检测`：尚未完成第一次外部验证。

路由器 DDNS 每 5 分钟检查，并在接口地址变化后触发检查。私网 IPv4、CGNAT 或仅获得 IPv6 地址并不自动代表公网可以入站。
