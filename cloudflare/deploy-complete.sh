#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }

[ -x "$BASE_DIR/deploy-cloudflare.sh" ] || die "缺少 deploy-cloudflare.sh 或没有执行权限"
[ -x "$BASE_DIR/deploy-pages-gateway.sh" ] || die "缺少 deploy-pages-gateway.sh 或没有执行权限"

say "========== 部署或复用：Cloudflare + Telegram + Pages =========="
say "检测到同名 Worker、D1 或 Pages 时复用；不存在时创建。"
say

printf 'Worker 名称 [router-node-center]：'
IFS= read -r WORKER_INPUT
ROUTER_WORKER_NAME="${WORKER_INPUT:-router-node-center}"
printf '%s' "$ROUTER_WORKER_NAME" | grep -Eq '^[a-z0-9-]+$' || \
  die "Worker 名称只能包含小写字母、数字和连字符"

DEFAULT_PAGES="router-node-gateway-$(date +%y%m%d)"
printf 'Pages 项目名称 [%s]：' "$DEFAULT_PAGES"
IFS= read -r PAGES_INPUT
ROUTER_PAGES_NAME="${PAGES_INPUT:-$DEFAULT_PAGES}"
printf '%s' "$ROUTER_PAGES_NAME" | grep -Eq '^[a-z0-9-]+$' || \
  die "Pages 项目名称只能包含小写字母、数字和连字符"
[ "$ROUTER_PAGES_NAME" != "$ROUTER_WORKER_NAME" ] || \
  die "Pages 项目和 Worker 必须使用不同名称"

export ROUTER_WORKER_NAME ROUTER_PAGES_NAME

say
say "第一阶段：部署 Worker、D1 和 Telegram Bot"
"$BASE_DIR/deploy-cloudflare.sh"

say
say "第二阶段：部署路由器可访问的 Pages 网关"
"$BASE_DIR/deploy-pages-gateway.sh"

say
say "云端部署/复用完成。"
say "以后新增路由器：Telegram 生成新配对码，然后只运行 install-router-complete.sh。"
