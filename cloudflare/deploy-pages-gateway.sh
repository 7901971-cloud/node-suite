#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY_DIR="$BASE_DIR/pages-gateway"

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "请先安装 Node.js 22 或更高版本"
command -v npm >/dev/null 2>&1 || die "没有找到 npm"
command -v curl >/dev/null 2>&1 || die "没有找到 curl"

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 22 ] || die "Node.js 版本过低，需要 22 或更高版本"
[ -f "$BASE_DIR/package.json" ] || die "找不到 cloudflare/package.json"
[ -f "$GATEWAY_DIR/functions/[[path]].js" ] || die "找不到 Pages Function"

say "========== 部署独立 Pages 监控入口 =========="
say "本脚本创建或复用 Pages 项目和 Worker Service Binding。"
say "不会修改 D1 数据或任何路由器配置。"
say

if [ -n "${ROUTER_WORKER_NAME:-}" ]; then
  WORKER_NAME="$ROUTER_WORKER_NAME"
  say "现有 Worker 名称：$WORKER_NAME"
else
  printf '现有 Worker 名称 [router-node-center]：'
  IFS= read -r WORKER_INPUT
  WORKER_NAME="${WORKER_INPUT:-router-node-center}"
fi
printf '%s' "$WORKER_NAME" | grep -Eq '^[a-z0-9-]+$' || \
  die "Worker 名称只能包含小写字母、数字和连字符"

if [ -n "${ROUTER_PAGES_NAME:-}" ]; then
  PAGES_NAME="$ROUTER_PAGES_NAME"
  say "Pages 项目名称：$PAGES_NAME"
else
  DEFAULT_PAGES="router-node-gateway-$(date +%y%m%d)"
  printf '新建 Pages 项目名称 [%s]：' "$DEFAULT_PAGES"
  IFS= read -r PAGES_INPUT
  PAGES_NAME="${PAGES_INPUT:-$DEFAULT_PAGES}"
fi
printf '%s' "$PAGES_NAME" | grep -Eq '^[a-z0-9-]+$' || \
  die "Pages 项目名称只能包含小写字母、数字和连字符"
[ "$PAGES_NAME" != "$WORKER_NAME" ] || \
  die "Pages 项目和 Worker 请使用不同名称"

say
say "========== 准备 Wrangler =========="
cd "$BASE_DIR"
npm ci --no-audit --no-fund
WRANGLER="$BASE_DIR/node_modules/.bin/wrangler"
[ -x "$WRANGLER" ] || die "Wrangler 安装失败"

if ! "$WRANGLER" whoami >/dev/null 2>&1; then
  say "即将打开浏览器登录 Cloudflare。"
  "$WRANGLER" login
fi

cat > "$GATEWAY_DIR/wrangler.jsonc" <<EOF
{
  "\$schema": "../node_modules/wrangler/config-schema.json",
  "name": "$PAGES_NAME",
  "pages_build_output_dir": "./public",
  "compatibility_date": "2026-09-01",
  "services": [
    {
      "binding": "ROUTER_WORKER",
      "service": "$WORKER_NAME"
    }
  ]
}
EOF

cd "$GATEWAY_DIR"
say
say "========== 创建或复用 Pages 项目 =========="
PROJECTS_JSON="$("$WRANGLER" pages project list --json 2>/dev/null || printf '[]')"
PROJECT_EXISTS="$(printf '%s' "$PROJECTS_JSON" | ROUTER_PAGES_NAME="$PAGES_NAME" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try {
    const j=JSON.parse(s); const a=Array.isArray(j)?j:
      (Array.isArray(j.result)?j.result:(Array.isArray(j.items)?j.items:[]));
    if(a.some(x=>x&&x.name===process.env.ROUTER_PAGES_NAME)) process.stdout.write("yes");
  } catch (_) {}
});' 2>/dev/null || true)"

if [ "$PROJECT_EXISTS" = "yes" ]; then
  say "检测到同名 Pages 项目，将复用并更新它的部署。"
else
  CREATE_OUTPUT="$("$WRANGLER" pages project create "$PAGES_NAME" \
    --production-branch main 2>&1)" || {
      say "$CREATE_OUTPUT" >&2
      die "创建 Pages 项目失败；如果名称已被占用，请换一个名称重试"
    }
  say "$CREATE_OUTPUT"
fi

say
say "========== 部署 Pages Function =========="
DEPLOY_OUTPUT="$("$WRANGLER" pages deploy public \
  --project-name "$PAGES_NAME" --branch main 2>&1)" || {
    say "$DEPLOY_OUTPUT" >&2
    die "Pages 部署失败；请确认 Worker 名称和 Cloudflare 账号一致"
  }
say "$DEPLOY_OUTPUT"

PROJECTS_JSON="$("$WRANGLER" pages project list --json 2>/dev/null || printf '[]')"
PAGES_TARGET="$(printf '%s' "$PROJECTS_JSON" | ROUTER_PAGES_NAME="$PAGES_NAME" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try {
    const j=JSON.parse(s); const a=Array.isArray(j)?j:
      (Array.isArray(j.result)?j.result:(Array.isArray(j.items)?j.items:[]));
    const x=a.find(v=>v&&v.name===process.env.ROUTER_PAGES_NAME);
    if(!x) return;
    const d=x.subdomain||(Array.isArray(x.domains)?x.domains.find(v=>String(v).endsWith(".pages.dev")):"");
    if(d) process.stdout.write(String(d));
  } catch (_) {}
});' 2>/dev/null || true)"

if [ -n "$PAGES_TARGET" ]; then
  case "$PAGES_TARGET" in
    http://*|https://*) PAGES_URL="${PAGES_TARGET%/}" ;;
    *) PAGES_URL="https://${PAGES_TARGET%/}" ;;
  esac
else
  PAGES_URL="https://${PAGES_NAME}.pages.dev"
fi

say
say "========== 从本机检查网关 =========="
READY=0
for ATTEMPT in 1 2 3; do
  HEALTH="$(curl -fsS --noproxy '*' --connect-timeout 10 --max-time 25 "$PAGES_URL/health" 2>/dev/null || true)"
  if printf '%s' "$HEALTH" | node -e 'let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.exit(j.ok&&j.capabilities?.command_check===true?0:1)}catch(_){process.exit(1)}})'; then READY=1; break; fi
  sleep 5
done
[ "$READY" = 1 ] || die "Pages已发布，但入口验证未通过，整套云端部署未完成：$PAGES_URL"
say 'Pages入口能力检查通过。'

cd "$BASE_DIR"
printf '%s' "$PAGES_URL" | "$WRANGLER" secret put PUBLIC_GATEWAY_URL >/dev/null || \
  die 'Pages 已部署，但地址写入 Worker 失败'
say 'Pages 地址已写入 Telegram Bot 菜单。'

say
say "Pages 监控入口：$PAGES_URL"
say "下一步先从路由器执行："
say "  curl -6 -sS --noproxy '*' --connect-timeout 8 --max-time 20 '$PAGES_URL/health'"
say "看到 \"ok\":true 后，使用这个 Pages 地址重新配对。"
