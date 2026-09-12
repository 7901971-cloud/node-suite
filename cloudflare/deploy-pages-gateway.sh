#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY_DIR="$BASE_DIR/pages-gateway"

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }

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

health_ok() {
  local url="$1" body
  body="$(curl -fsS --noproxy '*' --connect-timeout 10 --max-time 25 "$url/health" 2>/dev/null || true)"
  printf '%s' "$body" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { const j=JSON.parse(s); process.exit(j.ok&&j.capabilities?.command_check===true?0:1); }
  catch (_) { process.exit(1); }
});'
}

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

PAGES_URL="https://${PAGES_NAME}.pages.dev"

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
PROJECT_EXISTS=no
PROJECTS_JSON=''
if retry_capture PROJECTS_JSON '读取 Pages 项目列表' "$WRANGLER" pages project list --json; then
  PROJECT_EXISTS="$(printf '%s' "$PROJECTS_JSON" | ROUTER_PAGES_NAME="$PAGES_NAME" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try {
    const j=JSON.parse(s); const a=Array.isArray(j)?j:
      (Array.isArray(j.result)?j.result:(Array.isArray(j.items)?j.items:[]));
    if(a.some(x=>x&&x.name===process.env.ROUTER_PAGES_NAME)) process.stdout.write("yes");
    else process.stdout.write("no");
  } catch (_) { process.stdout.write("no"); }
});' 2>/dev/null || printf 'no')"
else
  say '警告：Cloudflare API 暂时无法读取 Pages 项目列表，将通过稳定 Pages 地址确认是否为已存在项目。' >&2
fi

if [ "$PROJECT_EXISTS" != "yes" ] && health_ok "$PAGES_URL"; then
  PROJECT_EXISTS=yes
  say "项目列表 API 未确认，但稳定入口健康，确认同名 Pages 项目已存在：$PAGES_URL"
fi

if [ "$PROJECT_EXISTS" = "yes" ]; then
  say "检测到同名 Pages 项目，将复用并更新它的部署。"
else
  CREATE_OUTPUT=''
  if retry_capture CREATE_OUTPUT '创建 Pages 项目' "$WRANGLER" pages project create "$PAGES_NAME" --production-branch main; then
    [ -n "$CREATE_OUTPUT" ] && say "$CREATE_OUTPUT"
    PROJECT_EXISTS=yes
  elif printf '%s' "$CREATE_OUTPUT" | grep -Eqi 'already exists|code:[[:space:]]*8000002'; then
    PROJECT_EXISTS=yes
    say "检测到同名 Pages 项目已存在，将直接复用并更新它的部署。"
  else
    [ -n "$CREATE_OUTPUT" ] && say "$CREATE_OUTPUT" >&2
    die "连续 3 次无法确认或创建 Pages 项目；当前更像本机到 Cloudflare API 的网络故障，请恢复网络后重试"
  fi
fi

say
say "========== 部署 Pages Function =========="
DEPLOY_OUTPUT=''
if ! retry_capture DEPLOY_OUTPUT '部署 Pages Function' "$WRANGLER" pages deploy public --project-name "$PAGES_NAME" --branch main; then
  [ -n "$DEPLOY_OUTPUT" ] && say "$DEPLOY_OUTPUT" >&2
  die "Pages 部署连续 3 次失败；请检查本机到 Cloudflare API 的网络或代理"
fi
say "$DEPLOY_OUTPUT"

say
say "========== 从本机检查网关 =========="
READY=0
for ATTEMPT in 1 2 3; do
  if health_ok "$PAGES_URL"; then READY=1; break; fi
  sleep 5
done
[ "$READY" = 1 ] || die "Pages已发布，但入口验证未通过，整套云端部署未完成：$PAGES_URL"
say 'Pages入口能力检查通过。'

cd "$BASE_DIR"
say
say "========== 写入 Pages 地址到 Worker =========="
SECRET_OK=0
for ATTEMPT in 1 2 3; do
  if printf '%s' "$PAGES_URL" | "$WRANGLER" secret put PUBLIC_GATEWAY_URL >/dev/null 2>&1; then
    SECRET_OK=1
    break
  fi
  say "Pages 地址写入 Worker 第 ${ATTEMPT}/3 次失败，等待后重试。" >&2
  sleep $((ATTEMPT * 3))
done

if [ "$SECRET_OK" = 1 ]; then
  say 'Pages 地址已写入 Telegram Bot 菜单。'
elif [ "$PROJECT_EXISTS" = "yes" ]; then
  say '警告：Pages 已部署且复用的是原项目，但本机到 Cloudflare API 的写 Secret 请求连续失败。' >&2
  say '由于同名 Pages 项目的稳定地址未变化，保留 Worker 中现有 PUBLIC_GATEWAY_URL；本次不把临时 API 网络故障判定为整套部署失败。' >&2
  say "当前 Pages 入口：$PAGES_URL" >&2
else
  die 'Pages 已部署，但新项目地址连续 3 次无法写入 Worker；请恢复 Cloudflare API 网络后重试'
fi

say
say "Pages 监控入口：$PAGES_URL"
say "下一步先从路由器执行："
say "  curl -6 -sS --noproxy '*' --connect-timeout 8 --max-time 20 '$PAGES_URL/health'"
say "看到 \"ok\":true 后，使用这个 Pages 地址重新配对。"
