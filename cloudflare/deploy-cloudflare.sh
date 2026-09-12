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
retry_capture() {
  local __outvar="$1" label="$2"
  shift 2
  local attempt output rc
  output=''
  for attempt in 1 2 3; do
    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf -v "$__outvar" '%s' "$output"
      return 0
    fi
    say "$label 第 ${attempt}/3 次失败，等待后重试。" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  printf -v "$__outvar" '%s' "$output"
  return 1
}
put_secret() {
  local name="$1" value="$2" attempt
  for attempt in 1 2 3; do
    if printf '%s' "$value" | npx wrangler secret put "$name" >/dev/null 2>&1; then
      return 0
    fi
    say "写入 Secret ${name} 第 ${attempt}/3 次失败，等待后重试。" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  return 1
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
BOT_USERNAME="$(curl -fsS --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 \
  "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);if(j.ok&&j.result?.username)process.stdout.write(String(j.result.username))}catch(_){}})')"
printf '%s' "$BOT_USERNAME" | grep -Eq '^[A-Za-z0-9_]{5,32}$' || die '无法取得 Telegram Bot 用户名'

say
say "请先在 Telegram 中打开刚创建的 Bot，发送一次 /start。"
printf '发送完成后按回车继续：'
IFS= read -r _

UPDATES_JSON="$(curl -fsS --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 \
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
printf '%s' "$DB_NAME" | grep -Eq '^[A-Za-z0-9_-]+$' || die "D1 数据库名称格式不正确"

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

WHOAMI_OUTPUT=''
if ! retry_capture WHOAMI_OUTPUT '检查 Cloudflare 登录状态' npx wrangler whoami; then
  if printf '%s' "$WHOAMI_OUTPUT" | grep -Eqi 'not authenticated|not logged|login|authentication'; then
    say "Cloudflare 登录已失效，即将打开浏览器重新登录。"
    npx wrangler login
    retry_capture WHOAMI_OUTPUT '重新确认 Cloudflare 登录状态' npx wrangler whoami || {
      [ -n "$WHOAMI_OUTPUT" ] && say "$WHOAMI_OUTPUT" >&2
      die '重新登录后仍无法确认 Cloudflare 状态'
    }
  else
    [ -n "$WHOAMI_OUTPUT" ] && say "$WHOAMI_OUTPUT" >&2
    die 'Cloudflare 登录状态连续 3 次无法确认，更像本机到 Cloudflare API 的网络/代理故障；为避免无意义重复 OAuth，本次停止，请恢复网络后重跑同一命令'
  fi
fi

say
say "========== 创建或复用 D1 =========="
DB_LIST=''
if ! retry_capture DB_LIST '读取 D1 列表' npx wrangler d1 list --json; then
  [ -n "$DB_LIST" ] && say "$DB_LIST" >&2
  die '连续 3 次无法读取 D1 列表；为避免把临时 API 故障误判成“数据库不存在”，本次停止，不创建新 D1'
fi
DB_ID="$(printf '%s' "$DB_LIST" | ROUTER_DB_NAME="$DB_NAME" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { const a=JSON.parse(s); const n=process.env.ROUTER_DB_NAME;
    const x=(Array.isArray(a)?a:[]).find(v=>v.name===n);
    if(x) process.stdout.write(String(x.uuid||x.id||""));
  } catch (_) {}
});' 2>/dev/null || true)"

if [ -z "$DB_ID" ]; then
  CREATE_OUTPUT=''
  if ! retry_capture CREATE_OUTPUT '创建 D1 数据库' npx wrangler d1 create "$DB_NAME"; then
    [ -n "$CREATE_OUTPUT" ] && say "$CREATE_OUTPUT" >&2
    die "创建 D1 数据库连续 3 次失败"
  fi
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
D1_INIT_OUTPUT=''
if ! retry_capture D1_INIT_OUTPUT '初始化 D1 数据库' npx wrangler d1 execute "$DB_NAME" --remote --file=./schema.sql; then
  [ -n "$D1_INIT_OUTPUT" ] && say "$D1_INIT_OUTPUT" >&2
  die 'D1 初始化连续 3 次失败'
fi
[ -n "$D1_INIT_OUTPUT" ] && say "$D1_INIT_OUTPUT"
D1_MIGRATE_OUTPUT=''
if ! retry_capture D1_MIGRATE_OUTPUT '更新 D1 兼容数据' npx wrangler d1 execute "$DB_NAME" --remote \
  --command="UPDATE bot_groups SET access_mode='members',role='viewer',updated_at=strftime('%s','now') WHERE access_mode='all' AND role<>'viewer';"; then
  [ -n "$D1_MIGRATE_OUTPUT" ] && say "$D1_MIGRATE_OUTPUT" >&2
  die 'D1 兼容数据更新连续 3 次失败'
fi

# Use a stable webhook secret derived from the Bot Token. Ordinary redeploys therefore
# keep the same Telegram secret header instead of rotating the Worker first and risking
# a broken webhook when Telegram's setWebhook call temporarily fails.
WEBHOOK_SECRET="$(printf 'node-suite-webhook-v1:%s' "$BOT_TOKEN" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
printf '%s' "$WEBHOOK_SECRET" | grep -Eq '^[a-f0-9]{64}$' || die '无法生成稳定的 Telegram Webhook Secret'

SECRET_LIST=''
if ! retry_capture SECRET_LIST '读取 Worker Secret 列表' npx wrangler secret list --json; then
  if printf '%s' "$SECRET_LIST" | grep -Eqi 'worker.*not.*found|script.*not.*found|does not exist|10007'; then
    SECRET_LIST='[]'
    say '尚未发现已部署 Worker，将按首次部署生成数据加密密钥。'
  else
    [ -n "$SECRET_LIST" ] && say "$SECRET_LIST" >&2
    die '连续 3 次无法读取 Worker Secret 列表；为避免误覆盖现有 DATA_ENCRYPTION_KEY，本次在写入任何 Secret 前停止'
  fi
fi
HAS_DATA_KEY="$(printf '%s' "$SECRET_LIST" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);if(Array.isArray(a)&&a.some(x=>x?.name==="DATA_ENCRYPTION_KEY"))process.stdout.write("yes")}catch(_){}})')"
DATA_KEY=''
if [ "$HAS_DATA_KEY" != yes ]; then
  DATA_KEY="$(openssl rand -base64 32 | tr -d '\r\n=' | tr '+/' '-_')"
fi

say
say "========== 写入 Cloudflare Secrets =========="
put_secret TELEGRAM_BOT_TOKEN "$BOT_TOKEN" || die 'TELEGRAM_BOT_TOKEN 连续 3 次写入失败'
put_secret TELEGRAM_WEBHOOK_SECRET "$WEBHOOK_SECRET" || die 'TELEGRAM_WEBHOOK_SECRET 连续 3 次写入失败'
put_secret OWNER_TELEGRAM_IDS "$OWNER_IDS" || die 'OWNER_TELEGRAM_IDS 连续 3 次写入失败'
put_secret TELEGRAM_BOT_USERNAME "$BOT_USERNAME" || die 'TELEGRAM_BOT_USERNAME 连续 3 次写入失败'
if [ -n "$DATA_KEY" ]; then
  put_secret DATA_ENCRYPTION_KEY "$DATA_KEY" || die 'DATA_ENCRYPTION_KEY 连续 3 次写入失败'
else
  say '检测到现有数据加密密钥，已保留以继续读取原节点信息。'
fi

say
say "========== 部署 Worker =========="
DEPLOY_OUTPUT=''
if ! retry_capture DEPLOY_OUTPUT '部署 Worker' npx wrangler deploy; then
  [ -n "$DEPLOY_OUTPUT" ] && say "$DEPLOY_OUTPUT" >&2
  die "Worker 部署连续 3 次失败"
fi
say "$DEPLOY_OUTPUT"
WORKER_URL="$(printf '%s\n' "$DEPLOY_OUTPUT" | grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' | tail -n 1 || true)"
if [ -z "$WORKER_URL" ]; then
  printf '未自动识别 Worker URL，请填写完整 HTTPS 地址：'
  IFS= read -r WORKER_URL
fi
WORKER_URL="${WORKER_URL%/}"
printf '%s' "$WORKER_URL" | grep -Eq '^https://[A-Za-z0-9._:-]+$' || die "Worker URL 格式不正确"

HEALTH=''
for ATTEMPT in 1 2 3; do
  HEALTH="$(curl -fsS --connect-timeout 10 --max-time 20 "${WORKER_URL}/health" 2>/dev/null || true)"
  printf '%s' "$HEALTH" | grep -q '"ok":true' && break
  [ "$ATTEMPT" -lt 3 ] && sleep 3
done
if printf '%s' "$HEALTH" | grep -q '"ok":true'; then
  say 'Worker 直连健康检查通过。'
else
  say '警告：Worker 直连健康检查暂未通过；仍会尝试 Telegram Webhook，并在失败时显示 Telegram 原始错误。' >&2
fi

set_telegram_webhook() {
  local endpoint="$1"
  local attempt result=''
  for attempt in 1 2 3; do
    result="$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
      "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
      --data-urlencode "url=${endpoint}" \
      --data-urlencode "secret_token=${WEBHOOK_SECRET}" \
      --data-urlencode 'allowed_updates=["message","edited_message","callback_query","chat_member","my_chat_member"]' \
      --data 'drop_pending_updates=true' 2>&1 || true)"
    if printf '%s' "$result" | grep -q '"ok":true'; then
      say "Telegram Webhook 已设置：$endpoint"
      return 0
    fi
    say "Telegram Webhook 第 ${attempt}/3 次失败：${result:-无响应}" >&2
    [ "$attempt" -lt 3 ] && sleep 2
  done
  return 1
}

say
say "========== 对接 Telegram Webhook =========="
WEBHOOK_ENDPOINT="${WORKER_URL}/telegram/webhook"
if ! set_telegram_webhook "$WEBHOOK_ENDPOINT"; then
  PAGES_URL=''
  if [ -n "${ROUTER_PAGES_NAME:-}" ] && printf '%s' "$ROUTER_PAGES_NAME" | grep -Eq '^[a-z0-9-]+$'; then
    PAGES_URL="https://${ROUTER_PAGES_NAME}.pages.dev"
  fi
  if [ -n "$PAGES_URL" ]; then
    PAGES_HEALTH="$(curl -fsS --connect-timeout 10 --max-time 20 "${PAGES_URL}/health" 2>/dev/null || true)"
    if printf '%s' "$PAGES_HEALTH" | grep -q '"ok":true'; then
      say "Worker Webhook 设置失败，检测到现有 Pages 网关可用，改用 Pages 入口重试。" >&2
      WEBHOOK_ENDPOINT="${PAGES_URL}/telegram/webhook"
      set_telegram_webhook "$WEBHOOK_ENDPOINT" || die 'Telegram Webhook 在 Worker 与 Pages 入口均设置失败；上方已保留 Telegram 原始错误。'
    else
      die 'Telegram Webhook 设置失败；现有 Pages 网关也未通过健康检查。上方已保留 Telegram 原始错误。'
    fi
  else
    die 'Telegram Webhook 设置失败；上方已保留 Telegram 原始错误。'
  fi
fi

COMMAND_RESULT=''
for ATTEMPT in 1 2 3; do
  COMMAND_RESULT="$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
    -H 'Content-Type: application/json' \
    --data '{"commands":[{"command":"start","description":"节点管理 / Bot 管理"},{"command":"routers","description":"节点管理"},{"command":"router","description":"路由器命令"},{"command":"vps","description":"VPS 命令"},{"command":"grouphelp","description":"管群命令"},{"command":"rules","description":"群规"},{"command":"id","description":"查看群和用户 ID"},{"command":"cancel","description":"取消当前输入"},{"command":"menu","description":"返回主菜单"}]}' 2>&1 || true)"
  printf '%s' "$COMMAND_RESULT" | grep -q '"ok":true' && break
  [ "$ATTEMPT" -lt 3 ] && sleep 2
done
if ! printf '%s' "$COMMAND_RESULT" | grep -q '"ok":true'; then
  say "警告：Telegram 命令菜单更新失败：${COMMAND_RESULT:-无响应}" >&2
fi

say
say "部署完成"
say "Worker 地址：$WORKER_URL"
say "Telegram Webhook：$WEBHOOK_ENDPOINT"
say "首次部署：回到 Telegram 发送 /start，再从 节点管理 → 添加设备 获取配对码。"
say "已有部署重跑：原设备、权限和配对关系保留，不需要重新配对。"
say "随后 deploy-complete.sh 会继续部署/复用 Pages 网关。"
