#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
read_secret() {
  local prompt="$1"
  local value
  printf '%s' "$prompt" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r value
  stty echo 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$value"
}
random_hex() {
  openssl rand -hex "$1"
}
trap 'stty echo 2>/dev/null || true' EXIT INT TERM

command -v node >/dev/null 2>&1 || die "请先安装 Node.js 22 或更高版本"
command -v npm >/dev/null 2>&1 || die "没有找到 npm"
command -v curl >/dev/null 2>&1 || die "没有找到 curl"
command -v openssl >/dev/null 2>&1 || die "没有找到 openssl"

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 22 ] || die "Node.js 版本过低，需要 22 或更高版本"

say "========== Cloudflare + Telegram 路由节点中心 =========="
say "Bot Token 只会写入 Cloudflare Secret，不会保存到本地配置文件。"
BOT_TOKEN="$(read_secret 'Telegram Bot Token：')"
printf '%s' "$BOT_TOKEN" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]+$' || die "Bot Token 格式不正确"
BOT_USERNAME="$(curl -fsS --connect-timeout 10 --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);if(j.ok&&j.result?.username)process.stdout.write(String(j.result.username))}catch(_){}})')"
printf '%s' "$BOT_USERNAME" | grep -Eq '^[A-Za-z0-9_]{5,32}$' || die '无法取得 Telegram Bot 用户名'

say
say "请先在 Telegram 中打开刚创建的 Bot，发送一次 /start。"
printf '发送完成后按回车继续：'
IFS= read -r _

UPDATES_JSON="$(curl -fsS --connect-timeout 10 --max-time 20 \
  "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)"

DETECTED_OWNER="$(printf '%s' "$UPDATES_JSON" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try {
    const j=JSON.parse(s); const rs=Array.isArray(j.result)?j.result:[];
    for(let i=rs.length-1;i>=0;i--){
      const m=rs[i].message||rs[i].edited_message;
      if(m&&m.chat&&m.chat.type==="private"&&m.from){
        process.stdout.write(String(m.from.id)); return;
      }
    }
  } catch (_) {}
});' 2>/dev/null || true)"

if [ -n "$DETECTED_OWNER" ]; then
  printf '检测到 Telegram 用户 ID [%s]，直接回车使用；也可填写多个ID并用逗号分隔：' "$DETECTED_OWNER"
else
  printf '未自动检测到，请填写 Telegram 数字用户 ID；多个ID用逗号分隔：'
fi
IFS= read -r OWNER_IDS_INPUT
OWNER_IDS="${OWNER_IDS_INPUT:-$DETECTED_OWNER}"
printf '%s' "$OWNER_IDS" | grep -Eq '^[0-9]+(,[0-9]+)*$' || die "Telegram 用户 ID 格式不正确"

if [ -n "${ROUTER_WORKER_NAME:-}" ]; then
  WORKER_NAME="$ROUTER_WORKER_NAME"
  say "Worker 名称：$WORKER_NAME"
else
  printf 'Worker 名称 [router-node-center]：'
  IFS= read -r WORKER_INPUT
  WORKER_NAME="${WORKER_INPUT:-router-node-center}"
fi
printf '%s' "$WORKER_NAME" | grep -Eq '^[a-z0-9-]+$' || die "Worker 名称只能包含小写字母、数字和连字符"

printf 'D1 数据库名称 [router-node-center-db]：'
IFS= read -r DB_INPUT
DB_NAME="${DB_INPUT:-router-node-center-db}"
printf '%s' "$DB_NAME" | grep -Eq '^[A-Za-z0-9_-]+$' || die "数据库名称格式不正确"

printf '每日汇报时区 [Asia/Shanghai]：'
IFS= read -r TZ_INPUT
REPORT_TIMEZONE="${TZ_INPUT:-Asia/Shanghai}"
REPORT_TIMEZONE="$REPORT_TIMEZONE" node -e 'new Intl.DateTimeFormat("en", {timeZone:process.env.REPORT_TIMEZONE})' || die '时区格式不正确'
printf '%s' "$REPORT_TIMEZONE" | grep -Eq '^[A-Za-z0-9_+/-]+$' || die '时区含不支持字符'

printf '每日汇报小时（0-23）[9]：'
IFS= read -r HOUR_INPUT
DAILY_HOUR="${HOUR_INPUT:-9}"
printf '%s' "$DAILY_HOUR" | grep -Eq '^([0-9]|1[0-9]|2[0-3])$' || die "小时格式不正确"

say
say "========== 安装 Wrangler =========="
npm ci --no-audit --no-fund

if ! npx wrangler whoami >/dev/null 2>&1; then
  say "即将打开浏览器登录 Cloudflare。"
  npx wrangler login
fi

say
say "========== 创建或复用 D1 =========="
DB_LIST="$(npx wrangler d1 list --json 2>/dev/null || printf '[]')"
DB_ID="$(printf '%s' "$DB_LIST" | ROUTER_DB_NAME="$DB_NAME" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { const a=JSON.parse(s); const n=process.env.ROUTER_DB_NAME;
    const x=(Array.isArray(a)?a:[]).find(v=>v.name===n);
    if(x) process.stdout.write(String(x.uuid||x.id||""));
  } catch (_) {}
});' 2>/dev/null || true)"

if [ -z "$DB_ID" ]; then
  CREATE_OUTPUT="$(npx wrangler d1 create "$DB_NAME" 2>&1)" || {
    say "$CREATE_OUTPUT" >&2
    die "创建 D1 数据库失败"
  }
  DB_ID="$(printf '%s\n' "$CREATE_OUTPUT" | sed -n \
    -e 's/.*database_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    -e 's/.*"database_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
fi
[ -n "$DB_ID" ] || die "无法取得 D1 database_id"

cat > wrangler.jsonc <<EOF
{
  "\$schema": "node_modules/wrangler/config-schema.json",
  "name": "$WORKER_NAME",
  "main": "src/index.js",
  "compatibility_date": "2026-09-01",
  "workers_dev": true,
  "observability": { "enabled": false },
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "$DB_NAME",
      "database_id": "$DB_ID"
    }
  ],
  "triggers": { "crons": ["* * * * *"] },
  "vars": {
    "REPORT_TIMEZONE": "$REPORT_TIMEZONE",
    "DAILY_REPORT_HOUR": "$DAILY_HOUR",
    "OFFLINE_MINUTES": "15",
    "ALERT_REMIND_HOURS": "6",
    "ALERT_RETENTION_DAYS": "30"
  }
}
EOF

say
say "========== 初始化数据库 =========="
npx wrangler d1 execute "$DB_NAME" --remote --file=./schema.sql
npx wrangler d1 execute "$DB_NAME" --remote \
  --command="UPDATE bot_groups SET access_mode='members',role='viewer',updated_at=strftime('%s','now') WHERE access_mode='all' AND role<>'viewer';" >/dev/null

WEBHOOK_SECRET="$(random_hex 24)"
SECRET_LIST="$(npx wrangler secret list --json 2>/dev/null || printf '[]')"
HAS_DATA_KEY="$(printf '%s' "$SECRET_LIST" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);if(Array.isArray(a)&&a.some(x=>x?.name==="DATA_ENCRYPTION_KEY"))process.stdout.write("yes")}catch(_){}})')"
DATA_KEY=''
if [ "$HAS_DATA_KEY" != yes ]; then
  DATA_KEY="$(openssl rand -base64 32 | tr -d '\r\n=' | tr '+/' '-_')"
fi

say
say "========== 写入 Cloudflare Secrets =========="
printf '%s' "$BOT_TOKEN" | npx wrangler secret put TELEGRAM_BOT_TOKEN >/dev/null
printf '%s' "$WEBHOOK_SECRET" | npx wrangler secret put TELEGRAM_WEBHOOK_SECRET >/dev/null
printf '%s' "$OWNER_IDS" | npx wrangler secret put OWNER_TELEGRAM_IDS >/dev/null
printf '%s' "$BOT_USERNAME" | npx wrangler secret put TELEGRAM_BOT_USERNAME >/dev/null
if [ -n "$DATA_KEY" ]; then
  printf '%s' "$DATA_KEY" | npx wrangler secret put DATA_ENCRYPTION_KEY >/dev/null
else
  say '检测到现有数据加密密钥，已保留以继续读取原节点信息。'
fi

say
say "========== 部署 Worker =========="
DEPLOY_OUTPUT="$(npx wrangler deploy 2>&1)" || {
  say "$DEPLOY_OUTPUT" >&2
  die "Worker 部署失败"
}
say "$DEPLOY_OUTPUT"
WORKER_URL="$(printf '%s\n' "$DEPLOY_OUTPUT" | grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' | tail -n 1 || true)"
if [ -z "$WORKER_URL" ]; then
  printf '未自动识别 Worker URL，请填写完整 HTTPS 地址：'
  IFS= read -r WORKER_URL
fi
WORKER_URL="${WORKER_URL%/}"
printf '%s' "$WORKER_URL" | grep -Eq '^https://[A-Za-z0-9._:-]+$' || die "Worker URL 格式不正确"

say
say "========== 对接 Telegram Webhook =========="
HOOK_RESULT="$(curl -fsS --connect-timeout 10 --max-time 30 -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
  --data-urlencode "url=${WORKER_URL}/telegram/webhook" \
  --data-urlencode "secret_token=${WEBHOOK_SECRET}" \
  --data-urlencode 'allowed_updates=["message","edited_message","callback_query","chat_member","my_chat_member"]' \
  --data 'drop_pending_updates=true')"
printf '%s' "$HOOK_RESULT" | grep -q '"ok":true' || die "设置 Telegram Webhook 失败：$HOOK_RESULT"

COMMAND_RESULT="$(curl -fsS --connect-timeout 10 --max-time 30 -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
  -H 'Content-Type: application/json' \
  --data '{"commands":[{"command":"start","description":"节点管理 / Bot 管理"},{"command":"routers","description":"节点管理"},{"command":"router","description":"路由器命令"},{"command":"vps","description":"VPS 命令"},{"command":"grouphelp","description":"管群命令"},{"command":"rules","description":"群规"},{"command":"id","description":"查看群和用户 ID"},{"command":"cancel","description":"取消当前输入"},{"command":"menu","description":"返回主菜单"}]}' || true)"

HEALTH="$(curl -fsS --connect-timeout 10 --max-time 20 "${WORKER_URL}/health" || true)"
if ! printf '%s' "$HEALTH" | grep -q '"ok":true'; then
  say 'Worker直连健康检查未通过；继续部署Pages网关，由Pages入口进行最终检查。'
fi

say
say "部署完成"
say "Worker 地址：$WORKER_URL"
say "现在回到 Telegram，向 Bot 发送 /start。"
say "依次点击：节点中心 → 添加设备，取得路由器配对码。"
say "随后部署 Pages 网关，并在 OpenWrt 上运行 install-router-complete.sh。"
