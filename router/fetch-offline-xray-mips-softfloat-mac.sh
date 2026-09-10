#!/bin/sh
# Mac 备用下载器：仅在 MT7621/MIPS 路由器无法从官方源完成 Xray 下载时使用。
set -eu
umask 077

command -v curl >/dev/null 2>&1 || { echo '缺少 curl'; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo '缺少 unzip'; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo '缺少 shasum'; exit 1; }
command -v scp >/dev/null 2>&1 || { echo '缺少 scp'; exit 1; }

RELEASE='v26.7.28'
FILE='Xray-linux-mips32le.zip'
BASE="https://github.com/XTLS/Xray-core/releases/download/${RELEASE}"
WORK="$(mktemp -d /tmp/home-node-xray-mips.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM
cd "$WORK"

curl -fL --retry 3 --connect-timeout 15 --max-time 900 "$BASE/$FILE" -o "$FILE"
curl -fL --retry 3 --connect-timeout 15 --max-time 120 "$BASE/$FILE.dgst" -o "$FILE.dgst"
EXPECTED="$(awk 'toupper($0) ~ /SHA(2|-|2-)?256/ {for(i=1;i<=NF;i++) if(length($i)==64 && $i !~ /[^a-fA-F0-9]/) {print tolower($i);exit}}' "$FILE.dgst")"
ACTUAL="$(shasum -a 256 "$FILE" | awk '{print $1}')"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || { echo '官方 SHA256 校验失败，停止上传'; exit 1; }
unzip -p "$FILE" xray_softfloat > home-node-xray
[ -s home-node-xray ] || { echo '官方压缩包中没有 xray_softfloat'; exit 1; }
chmod 700 home-node-xray
shasum -a 256 home-node-xray > home-node-xray.sha256
printf '路由器 LAN SSH 地址（例如 10.0.0.1）：'
IFS= read -r ROUTER_IP
printf '%s' "$ROUTER_IP" | grep -Eq '^[0-9A-Fa-f:.]+$' || { echo '地址格式不正确'; exit 1; }
scp -O home-node-xray home-node-xray.sha256 "root@${ROUTER_IP}:/tmp/"
echo '已上传 /tmp/home-node-xray 与 SHA256 文件。路由器安装器会自动优先使用该已校验软浮点二进制。'
