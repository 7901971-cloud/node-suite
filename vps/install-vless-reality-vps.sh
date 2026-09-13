#!/usr/bin/env bash
set -Eeuo pipefail

# VPS VLESS + XTLS Vision + REALITY + existing Cloudflare/Telegram center
# Supported: Debian/Ubuntu with systemd (root only)
# Cloudflare Pages endpoint is entered interactively and is never hard-coded.

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
umask 077

readonly SCRIPT_VERSION="1.3"
readonly XRAY_RELEASE='v26.7.28'
PREFLIGHT_ONLY=0
case "${1:-}" in --preflight) PREFLIGHT_ONLY=1 ;; --version) echo "$SCRIPT_VERSION"; exit 0 ;; '') ;; *) echo 'Usage: bash install-vless-reality-vps.sh [--preflight|--version]' >&2; exit 2 ;; esac
STAGE=''
SMOKE_PID=''
SUITE_PROBE_PIDS=''
FW_CHANGED=0
FW6_ADDED=0
readonly DEFAULT_NODE_NAME="VPS-VLESS"
readonly DEFAULT_SNI="www.apple.com"
readonly DEFAULT_DEVICE_NAME="$(hostname -s 2>/dev/null || printf 'vps')-VPS"
readonly STATE_DIR="/etc/vless-reality"
readonly SETTINGS_FILE="${STATE_DIR}/settings.conf"
readonly MONITOR_CONF="${STATE_DIR}/monitor.conf"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly NODE_FILE="/root/vless-node-info.txt"
XRAY_BIN="/usr/local/bin/xray"
readonly MONITOR_BIN="/usr/local/sbin/vless-reality-monitor"
readonly PAIR_BIN="/usr/local/sbin/vless-reality-pair"
readonly COMMAND_BIN="/usr/local/sbin/vless-reality-command-agent"
readonly INFO_BIN="/usr/local/sbin/vless-reality-info"
readonly FIREWALL_BIN="/usr/local/sbin/vless-reality-firewall"
readonly BACKUP_DIR="/root/vless-reality-backup-$(date +%Y%m%d-%H%M%S)-$$"

ROLLBACK_READY=0
INSTALL_DONE=0

say() { LAST_MESSAGE="$*"; printf '%s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

restore_on_failure() {
  local rc=$?
  set +e
  stty echo 2>/dev/null || true
  suite_probe_cleanup
  (( rc == 0 )) || warn "停止阶段：${LAST_MESSAGE:-预检}；退出码=$rc；已有业务配置按阶段保留/恢复"
  if [[ -n "$SMOKE_PID" ]]; then kill "$SMOKE_PID" 2>/dev/null; wait "$SMOKE_PID" 2>/dev/null; fi
  if (( rc != 0 )) && (( ROLLBACK_READY == 1 )) && (( INSTALL_DONE == 0 )); then
    warn "本地服务未通过验收，恢复本次修改文件：$BACKUP_DIR"
    systemctl stop xray >/dev/null 2>&1 || true
    while IFS= read -r f; do
      if [[ -e "$BACKUP_DIR/files$f" ]]; then cp -a "$BACKUP_DIR/files$f" "$f"; else rm -f "$f"; fi
    done < "$BACKUP_DIR/manifest"
    if [[ -s "$BACKUP_DIR/config-dir.stat" ]]; then
      read -r old_uid old_gid old_mode < "$BACKUP_DIR/config-dir.stat"
      chown "$old_uid:$old_gid" "$CONFIG_DIR"
      chmod "$old_mode" "$CONFIG_DIR"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    while read -r svc enabled running; do
      if [[ "$enabled" == enabled ]]; then systemctl enable "$svc" >/dev/null 2>&1; else systemctl disable "$svc" >/dev/null 2>&1; fi
      if [[ "$running" == active ]]; then systemctl restart "$svc" >/dev/null 2>&1; else systemctl stop "$svc" >/dev/null 2>&1; fi
    done < "$BACKUP_DIR/services"
    if (( FW_CHANGED == 1 )); then
      # Only our chain; never restore/flush the complete firewall or touch SSH rules.
      if [[ -s "$BACKUP_DIR/chain.rules" ]]; then
        iptables -w 5 -F XRAY_VLESS
        bash "$BACKUP_DIR/chain.rules"
      else
        iptables -w 5 -D INPUT -j XRAY_VLESS 2>/dev/null
        iptables -w 5 -F XRAY_VLESS 2>/dev/null
        iptables -w 5 -X XRAY_VLESS 2>/dev/null
      fi
      if (( FW6_ADDED == 1 )); then ip6tables -w 5 -D INPUT -p tcp --dport "$XRAY_PORT" -m comment --comment home-suite-vless -j ACCEPT 2>/dev/null; fi
    fi
  fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then if (( rc == 0 )); then rm -rf "$STAGE"; else warn "诊断目录：$STAGE（含私钥，请勿公开上传）"; fi; fi
  exit "$rc"
}
trap restore_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_root_and_os() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行。"
  [[ -r /etc/os-release ]] || die "无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "只支持 Debian/Ubuntu；当前系统：${PRETTY_NAME:-未知}" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "系统没有 systemd。"
  [[ -d /run/systemd/system ]] || die "systemd 当前没有运行。"
}

install_dependencies() {
  say "========== 1. 安装基础依赖 =========="
  mkdir -p /run/lock
  if ! command -v flock >/dev/null 2>&1; then
    apt-get -o Acquire::Retries=2 update || die '无法更新软件源以补齐 flock'
    apt-get install -y --no-install-recommends util-linux || die 'flock 依赖安装失败'
  fi
  acquire_lock
  STAGE="$(mktemp -d /tmp/vless-preflight.XXXXXX)"
  [[ "$(date +%s)" -ge 1735689600 ]] || die '系统时间错误，请先校准时间'
  [[ "$(df -Pk /usr/local | awk 'END{print $4}')" -ge 131072 ]] || die '/usr/local 所在分区至少需要 128 MiB 可用空间'
  [[ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 65536 ]] || die '可用内存不足 64 MiB'
  dpkg --audit >"$STAGE/dpkg-audit"
  [[ ! -s "$STAGE/dpkg-audit" ]] || die 'dpkg 存在未配置软件包，请先修复软件包状态'
  apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update || die '软件源更新失败，请检查 DNS/镜像源；不更换未知软件源'
  apt-get install -y --no-install-recommends \
    ca-certificates curl jq openssl qrencode iproute2 iptables procps util-linux unzip coreutils kmod socat mtr-tiny || die '依赖安装失败，尚未改写 Xray 配置'
  for cmd in socat od sysctl curl jq openssl qrencode ss iptables ip6tables timeout base64 flock unzip sha256sum install stat awk sed systemd-analyze runuser; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：$cmd"
  done
  curl --version | grep -q https || die 'curl 不支持 HTTPS'
  timeout -k 1 2 bash -c 'exit 0' || die 'timeout 自检失败'
  ss -Hlnpt >/dev/null || die '无法读取 TCP 监听表'
  iptables -w 5 -S INPUT >/dev/null || die '没有 iptables 内核权限（常见于受限容器）'
  if systemctl is-active --quiet firewalld; then die '检测到运行中的 firewalld，需要专门适配以免相互覆盖；本包不自动停用它'; fi
  id nobody >/dev/null 2>&1 || die '缺少系统 nobody 用户'
  if [[ -s "$CONFIG_FILE" ]] && ! jq -e '.inbounds | length == 1 and .[0].tag == "vless-reality"' "$CONFIG_FILE" >/dev/null 2>&1; then
    die '检测到不属于本单节点安装器的 Xray 配置；为保留其他节点而停止'
  fi
  if pgrep -x xray >/dev/null; then
    [[ -s "$CONFIG_FILE" ]] || die '已有其他 Xray 实例，停止接管'
    for pid in $(pgrep -x xray); do
      tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$CONFIG_FILE" || die "Xray PID=$pid 使用其他配置，停止接管"
    done
  fi
}

acquire_lock() {
  exec 9>/run/lock/install-vless-reality.lock
  flock -n 9 || die "另一份安装脚本正在运行。"
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_uuid() { [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
valid_short_id() { [[ "${1:-}" =~ ^([0-9a-fA-F]{2}){1,8}$ ]]; }
valid_key() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{43}$ ]]; }
valid_hostname() {
  [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
valid_monitor_url() { [[ "${1:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; }

read_default() {
  local prompt="$1" default="$2" value
  # 函数通过命令替换返回值；提示必须写到终端(stderr)，否则会被变量捕获而看起来像卡住。
  printf '%s [%s]：' "$prompt" "$default" >&2
  IFS= read -r value
  printf '%s' "${value:-$default}"
}

random_node_port() {
  local n
  n="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
  [[ "$n" =~ ^[0-9]+$ ]] || n="$(date +%s | tail -c 6)"
  printf '%s' "$((20000 + n % 40000))"
}

auto_select_reality_target() {
  local candidates host log start_ms end_ms ms best_host="" best_ms="" idx=0 probe fail a b c x1 x2 x3 tmp median
  candidates="www.apple.com www.microsoft.com www.mi.com www.samsung.com www.intel.com www.douyin.com www.qq.com www.10086.cn www.10010.com www.189.cn www.bing.com www.tiktok.com"
  say
  say "========== 3A. 自动选择 REALITY SNI / 目标 =========="
  say "将测试 12 个内置域名；每个域名连续严格握手 3 次，3 次均通过 TLS 1.3 / ALPN h2 / 证书校验后取延迟中位数，并选择中位数最低者。"
  for host in $candidates; do
    idx=$((idx + 1))
    fail=0; a=; b=; c=; probe=1
    while (( probe <= 3 )); do
      log="$STAGE/reality-auto-$idx-$probe.log"
      start_ms="$(awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null || printf 0)"
      timeout -k 1 8 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 -alpn h2 -verify_hostname "$host" -verify_return_error </dev/null >"$log" 2>&1 || true
      end_ms="$(awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null || printf 0)"
      if grep -q 'Verify return code: 0 (ok)' "$log" && grep -q 'ALPN protocol: h2' "$log"; then
        case "$start_ms:$end_ms" in *[!0-9:]*|:*) ms=999999 ;; *) if (( end_ms >= start_ms )); then ms=$((end_ms - start_ms)); else ms=999999; fi ;; esac
        case "$probe" in 1) a="$ms" ;; 2) b="$ms" ;; 3) c="$ms" ;; esac
      else
        fail=1
        break
      fi
      ((probe += 1))
    done
    if (( fail == 0 )) && [[ -n "$a" && -n "$b" && -n "$c" ]]; then
      x1="$a"; x2="$b"; x3="$c"
      if (( x1 > x2 )); then tmp="$x1"; x1="$x2"; x2="$tmp"; fi
      if (( x2 > x3 )); then tmp="$x2"; x2="$x3"; x3="$tmp"; fi
      if (( x1 > x2 )); then tmp="$x1"; x1="$x2"; x2="$tmp"; fi
      median="$x2"
      printf '  ✓ %-22s 3次=%s/%s/%s ms  中位数=%s ms\n' "${host}:443" "$a" "$b" "$c" "$median"
      if [[ -z "$best_host" ]] || (( median < best_ms )); then best_host="$host"; best_ms="$median"; fi
    else
      printf '  - %-22s 跳过（3 次严格握手未全部通过）\n' "${host}:443"
    fi
  done
  [[ -n "$best_host" ]] || die '12 个内置 REALITY 目标均未通过 3 次严格检查；未写业务配置'
  REALITY_SNI="$best_host"
  REALITY_DEST="${best_host}:443"
  say "自动选择：SNI=${REALITY_SNI}；目标=${REALITY_DEST}；3 次 TLS 握手中位数约 ${best_ms} ms"
}

load_old_values() {
  OLD_PORT=""
  OLD_NODE_NAME=""
  OLD_SNI=""
  OLD_DEST=""
  OLD_UUID=""
  OLD_PRIVATE_KEY=""
  OLD_SHORT_ID=""
  OLD_MONITOR_URL=""
  OLD_DEVICE_NAME=""

  if [[ -r "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$SETTINGS_FILE"
    OLD_PORT="${XRAY_PORT:-}"
    OLD_NODE_NAME="${NODE_NAME_B64:+$(printf '%s' "$NODE_NAME_B64" | base64 -d 2>/dev/null || true)}"
    OLD_SNI="${REALITY_SNI:-}"
    OLD_DEST="${REALITY_DEST:-}"
    OLD_UUID="${XRAY_UUID:-}"
    OLD_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
    OLD_SHORT_ID="${REALITY_SHORT_ID:-}"
  elif [[ -r "$CONFIG_FILE" ]] && jq -e '.inbounds[]? | select(.tag=="vless-reality")' "$CONFIG_FILE" >/dev/null 2>&1; then
    OLD_PORT="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].port // empty' "$CONFIG_FILE")"
    OLD_UUID="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].settings.clients[0].id // empty' "$CONFIG_FILE")"
    OLD_PRIVATE_KEY="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")"
    OLD_SHORT_ID="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE")"
    OLD_SNI="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE")"
    OLD_DEST="$(jq -r '[.inbounds[] | select(.tag=="vless-reality")][0].streamSettings.realitySettings.target // [.inbounds[] | select(.tag=="vless-reality")][0].streamSettings.realitySettings.dest // empty' "$CONFIG_FILE")"
  fi

  if [[ -r "$MONITOR_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$MONITOR_CONF"
    OLD_MONITOR_URL="${WORKER_URL:-}"
    OLD_DEVICE_NAME="${DEVICE_NAME_B64:+$(printf '%s' "$DEVICE_NAME_B64" | base64 -d 2>/dev/null || true)}"
  fi
}

read_settings() {
  local port_default
  say
  say "========== 2. 输入节点设置 =========="
  port_default="${OLD_PORT:-$(random_node_port)}"
  XRAY_PORT="$(read_default 'Xray TCP 端口' "$port_default")"
  valid_port "$XRAY_PORT" || die "端口必须是 1-65535。"
  XRAY_PORT="$((10#$XRAY_PORT))"

  NODE_NAME="$(read_default 'Quantumult X 节点名称' "${OLD_NODE_NAME:-$DEFAULT_NODE_NAME}")"
  [[ -n "$NODE_NAME" && ${#NODE_NAME} -le 48 ]] || die "节点名称不能为空且不能超过 48 字节。"
  [[ ! "$NODE_NAME" =~ [[:cntrl:]] ]] || die "节点名称不能包含控制字符。"
  [[ "$NODE_NAME" != *,* ]] || die '圈 X 节点名称不能包含逗号（会破坏配置字段）。'

  auto_select_reality_target

  printf '启用 BBR？[Y/n]：'
  IFS= read -r answer
  case "${answer:-Y}" in y|Y|yes|YES) ENABLE_BBR=1 ;; n|N|no|NO) ENABLE_BBR=0 ;; *) die "请输入 Y 或 N。" ;; esac

  printf '无现有 Swap 时创建 512MB Swap？[Y/n]：'
  IFS= read -r answer
  case "${answer:-Y}" in y|Y|yes|YES) ENABLE_SWAP=1 ;; n|N|no|NO) ENABLE_SWAP=0 ;; *) die "请输入 Y 或 N。" ;; esac

  printf '每天自动重启 Xray？（会中断连接，默认不启用）[y/N]：'
  IFS= read -r answer
  case "${answer:-N}" in
    y|Y|yes|YES)
      ENABLE_DAILY_RESTART=1
      DAILY_RESTART_TIME="$(read_default '服务器本地重启时间' '04:30:00')"
      [[ "$DAILY_RESTART_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]] || die "时间格式必须是 HH:MM:SS。"
      ;;
    n|N|no|NO) ENABLE_DAILY_RESTART=0; DAILY_RESTART_TIME="04:30:00" ;;
    *) die "请输入 Y 或 N。" ;;
  esac

  say
  say "========== 3. 输入现有 Cloudflare/Telegram 信息 =========="
  printf '接入现有 Telegram 监控中心？[Y/n]：'
  IFS= read -r answer
  case "${answer:-Y}" in y|Y|yes|YES) ENABLE_MONITOR=1 ;; n|N|no|NO) ENABLE_MONITOR=0 ;; *) die "请输入 Y 或 N。" ;; esac
  (( ENABLE_MONITOR == 1 )) || die '本完整包要求开启 Telegram 监控和 root 远控；取消安装'
  if (( ENABLE_MONITOR == 1 )); then
    if [[ -n "$OLD_MONITOR_URL" ]]; then
      WORKER_URL="$(read_default 'Cloudflare 监控入口' "$OLD_MONITOR_URL")"
    else
      printf 'Cloudflare Pages 监控入口：'
      IFS= read -r WORKER_URL
    fi
    WORKER_URL="${WORKER_URL%/}"
    valid_monitor_url "$WORKER_URL" || die "监控入口必须是纯 HTTPS 根地址。"
    DEVICE_NAME="$NODE_NAME"
    [[ -n "$DEVICE_NAME" && ${#DEVICE_NAME} -le 48 ]] || die "设备名称不能为空且不能超过 48 字节。"
    [[ ! "$DEVICE_NAME" =~ [[:cntrl:]] ]] || die "设备名称不能包含控制字符。"
  else
    WORKER_URL=""
    DEVICE_NAME="${OLD_DEVICE_NAME:-$DEFAULT_DEVICE_NAME}"
  fi
}

prepare_backup() {
  mkdir -p "$BACKUP_DIR"
  [[ ! -d "$CONFIG_DIR" ]] || stat -c '%u %g %a' "$CONFIG_DIR" > "$BACKUP_DIR/config-dir.stat"
  local f svc
  for f in /usr/local/sbin/node-config /usr/local/lib/node-suite/runtime.sh "$CONFIG_FILE" "$SETTINGS_FILE" "$NODE_FILE" /usr/local/bin/xray /etc/systemd/system/xray.service /etc/systemd/system/xray.service.d/99-home-suite.conf "$FIREWALL_BIN" /etc/systemd/system/vless-reality-firewall.service; do
    printf '%s\n' "$f" >> "$BACKUP_DIR/manifest"
    if [[ -e "$f" ]]; then mkdir -p "$BACKUP_DIR/files$(dirname "$f")"; cp -a "$f" "$BACKUP_DIR/files$f"; fi
  done
  for svc in xray.service vless-reality-firewall.service; do
    local en='disabled' running='inactive'
    systemctl is-enabled --quiet "$svc" 2>/dev/null && en=enabled
    systemctl is-active --quiet "$svc" 2>/dev/null && running=active
    printf '%s %s %s\n' "$svc" "$en" "$running" >> "$BACKUP_DIR/services"
  done
  # Restricted serialization of the chain generated by previous versions.
  iptables -w 5 -S XRAY_VLESS 2>/dev/null | awk '$1=="-A" && $2=="XRAY_VLESS" && $0 ~ /^[- A-Za-z0-9_\/]+$/ {print "iptables -w 5 " $0}' > "$BACKUP_DIR/chain.rules" || true
  ROLLBACK_READY=1
}

port_is_listening() {
  ss -Hlnpt 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_owned_by_xray() {
  ss -Hlnpt 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" && $0 ~ /xray/ {found=1} END {exit !found}'
}

choose_available_port() {
  say
  say "========== 4. 检查监听端口 =========="
  if ! port_is_listening "$XRAY_PORT" || port_owned_by_xray "$XRAY_PORT"; then
    say "TCP ${XRAY_PORT} 可以使用。"
    return
  fi

  local requested="$XRAY_PORT" candidate
  for candidate in 8443 2053 2083 2087 2096; do
    [[ "$candidate" == "$requested" ]] && continue
    if ! port_is_listening "$candidate"; then
      XRAY_PORT="$candidate"
      warn "TCP ${requested} 已被其他程序占用，自动改用 ${XRAY_PORT}。"
      return
    fi
  done
  candidate=10000
  while (( candidate <= 10500 )); do
    if ! port_is_listening "$candidate"; then
      XRAY_PORT="$candidate"
      warn "TCP ${requested} 已被其他程序占用，自动改用 ${XRAY_PORT}。"
      return
    fi
    ((candidate++))
  done
  die "没有找到空闲 TCP 端口。"
}

check_reality_target() {
  suite_check_target
}

check_monitor_endpoint() {
  (( ENABLE_MONITOR == 1 )) || return 0
  say
  say "========== 6. 检查 Cloudflare 入口 =========="
  local health
  health="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 "${WORKER_URL}/health" 2>/dev/null || true)"
  jq -e '.ok == true' <<<"$health" >/dev/null 2>&1 || die "无法访问现有监控入口：${WORKER_URL}"
  local version
  version="$(jq -r '.version // "0"' <<<"$health")"
  [[ "$version" == 3.* ]] && jq -e '.capabilities.command_check == true and .capabilities.vps_root == true' <<<"$health" >/dev/null || die "Cloudflare 节点中心为 ${version}，请先按教程全新部署本仓库的 Cloudflare 中心。"
  say "Cloudflare 监控入口正常，版本 ${version}。"
}

install_xray() {
  say '========== 7. 检查/暂存原生 Xray =========='
  suite_stage_xray /usr/local/bin/xray
}

generate_or_reuse_credentials() {
  say
  say "========== 8. 生成或保留节点凭据 =========="
  if valid_uuid "$OLD_UUID"; then
    XRAY_UUID="$OLD_UUID"
    say "保留原 UUID。"
  else
    XRAY_UUID="$($XRAY_BIN uuid | tr -d '[:space:]')"
    valid_uuid "$XRAY_UUID" || die "UUID 生成失败。"
  fi

  if valid_key "$OLD_PRIVATE_KEY"; then
    REALITY_PRIVATE_KEY="$OLD_PRIVATE_KEY"
    KEY_OUTPUT="$($XRAY_BIN x25519 -i "$REALITY_PRIVATE_KEY" 2>&1)"
    say "保留原 REALITY 私钥。"
  else
    KEY_OUTPUT="$($XRAY_BIN x25519 2>&1)"
    REALITY_PRIVATE_KEY="$(awk -F':[[:space:]]*' 'tolower($1) ~ /^private ?key$/ {print $2; exit}' <<<"$KEY_OUTPUT" | tr -d '[:space:]')"
  fi
  REALITY_PUBLIC_KEY="$(awk -F':[[:space:]]*' 'tolower($1) ~ /public ?key/ || tolower($1)=="password" {print $2; exit}' <<<"$KEY_OUTPUT" | tr -d '[:space:]')"
  valid_key "$REALITY_PRIVATE_KEY" || die "REALITY 私钥解析失败（不输出私钥到错误日志）。"
  valid_key "$REALITY_PUBLIC_KEY" || die "REALITY 公钥解析失败；支持 PublicKey / Password / Password (PublicKey)。"

  if valid_short_id "$OLD_SHORT_ID"; then
    REALITY_SHORT_ID="${OLD_SHORT_ID,,}"
    say "保留原 Short ID。"
  else
    REALITY_SHORT_ID="$(openssl rand -hex 8)"
  fi
}

write_xray_config() {
  say
  say "========== 9. 写入并验证 Xray 配置 =========="
  # Xray infers the configuration format from the final filename suffix.
  # Keep .json as the last suffix or `xray run -test` cannot detect the format.
  local tmp="$STAGE/config.json"
  LISTEN_ADDRESS='0.0.0.0'
  [[ ! -s /proc/net/if_inet6 ]] || LISTEN_ADDRESS='::'
  jq -n \
    --arg uuid "$XRAY_UUID" \
    --arg privateKey "$REALITY_PRIVATE_KEY" \
    --arg shortId "$REALITY_SHORT_ID" \
    --arg sni "$REALITY_SNI" \
    --arg target "$REALITY_DEST" \
    --arg listen "$LISTEN_ADDRESS" \
    --argjson port "$XRAY_PORT" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "vless-reality",
        listen: $listen,
        port: $port,
        protocol: "vless",
        settings: {
          clients: [{id: $uuid, flow: "xtls-rprx-vision", email: "primary"}],
          decryption: "none"
        },
        streamSettings: {
          network: "raw",
          security: "reality",
          realitySettings: {
            show: false,
            target: $target,
            xver: 0,
            serverNames: [$sni],
            privateKey: $privateKey,
            shortIds: [$shortId]
          }
        }
      }],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "block"}
      ]
    }' >"$tmp"

  "$XRAY_BIN" run -test -config "$tmp"
}

smoke_test_xray() {
  suite_smoke_xray
}

commit_xray() {
  install -d -m 750 -o root -g "$(id -gn nobody)" "$CONFIG_DIR"
  install -m 640 -o root -g "$(id -gn nobody)" "$STAGE/config.json" "$CONFIG_FILE"
  install -D -m 755 "$STAGE/xray" /usr/local/bin/xray.home-suite-new
  mv -f /usr/local/bin/xray.home-suite-new /usr/local/bin/xray
  XRAY_BIN='/usr/local/bin/xray'
  runuser -u nobody -- "$XRAY_BIN" run -test -config "$CONFIG_FILE" || die 'Xray 服务用户无法读取配置'
  cat > /etc/systemd/system/xray.service <<'EOF_XRAY_SERVICE'
[Unit]
Description=Managed VLESS REALITY Xray (home-suite v5)
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_XRAY_SERVICE
}

configure_service_limits() {
  say
  say "========== 10. 配置自动恢复与资源限制 =========="
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/99-home-suite.conf <<'EOF_OVERRIDE'
[Unit]
StartLimitIntervalSec=0

[Service]
User=nobody
Group=
ExecStart=
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
LimitNPROC=10000
MemoryHigh=400M
MemoryMax=450M
CPUQuota=
TasksMax=512
EOF_OVERRIDE

}

configure_daily_restart() {

  if (( ENABLE_DAILY_RESTART == 1 )); then
    cat >/etc/systemd/system/xray-daily-restart.service <<'EOF_SERVICE'
[Unit]
Description=Daily restart of Xray

[Service]
Type=oneshot
ExecStart=/bin/systemctl try-restart xray.service
EOF_SERVICE
    cat >/etc/systemd/system/xray-daily-restart.timer <<EOF_TIMER
[Unit]
Description=Daily Xray restart timer

[Timer]
OnCalendar=*-*-* ${DAILY_RESTART_TIME}
RandomizedDelaySec=300
Persistent=true
Unit=xray-daily-restart.service

[Install]
WantedBy=timers.target
EOF_TIMER
  else
    systemctl disable --now xray-daily-restart.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray-daily-restart.timer /etc/systemd/system/xray-daily-restart.service
  fi
}

configure_bbr() {
  suite_write_runtime
  suite_install_editor
  suite_optional_drivers
  (( ENABLE_BBR == 1 )) || return 0
  /usr/local/sbin/node-net-optimize auto || warn '可选 TCP 优化失败，保留可运行的节点并继续'
}

configure_swap() {
  (( ENABLE_SWAP == 1 )) || return 0
  say
  say "========== 12. 检查 Swap =========="
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    say "系统已有 Swap，不重复创建。"
    return
  fi
  if [[ -e /swapfile ]]; then
    warn "/swapfile 已存在但未启用，为避免覆盖已跳过。"
    return
  fi
  [[ "$(df -Pk / | awk 'END{print $4}')" -ge 786432 ]] || { warn '可用磁盘不足 768 MiB，跳过可选 Swap'; return 0; }
  if command -v fallocate >/dev/null 2>&1 && fallocate -l 512M /swapfile 2>/dev/null; then
    :
  else
    dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null || ! swapon /swapfile; then
    warn '当前虚拟化/文件系统不允许 Swap；保留未启用的 /swapfile，不修改 fstab，节点安装继续'
    return 0
  fi
  grep -Fq '/swapfile none swap sw 0 0' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
  say "已创建并启用 512MB Swap。"
}

write_firewall_helper() {
  say
  say "========== 13. 放行 Xray TCP 端口 =========="
  cat >"$FIREWALL_BIN" <<EOF_FIREWALL
#!/usr/bin/env bash
set -euo pipefail
PORT='${XRAY_PORT}'

iptables -w 5 -N XRAY_VLESS 2>/dev/null || true
iptables -w 5 -C INPUT -j XRAY_VLESS 2>/dev/null || iptables -w 5 -I INPUT 1 -j XRAY_VLESS
iptables -w 5 -F XRAY_VLESS
iptables -w 5 -A XRAY_VLESS -p tcp --dport "\$PORT" -j ACCEPT
iptables -w 5 -A XRAY_VLESS -j RETURN

if [ -s /proc/net/if_inet6 ]; then
  ip6tables -w 5 -C INPUT -p tcp --dport "\$PORT" -m comment --comment home-suite-vless -j ACCEPT 2>/dev/null || \
    ip6tables -w 5 -I INPUT 1 -p tcp --dport "\$PORT" -m comment --comment home-suite-vless -j ACCEPT
fi
EOF_FIREWALL
  chmod 700 "$FIREWALL_BIN"

  cat >/etc/systemd/system/vless-reality-firewall.service <<EOF_FIREWALL_SERVICE
[Unit]
Description=Open managed TCP port for VLESS REALITY
Before=xray.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${FIREWALL_BIN}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_FIREWALL_SERVICE
}

detect_public_ip() {
  local family="$1" value="" url
  if [[ "$family" == 4 ]]; then
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
      value="$(curl -4fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$value"; return 0; }
    done
  else
    for url in https://api6.ipify.org https://ipv6.icanhazip.com; do
      value="$(curl -6fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$value" == *:* ]] && { printf '%s' "$value"; return 0; }
    done
  fi
  return 1
}

write_settings_and_node() {
  say
  say "========== 14. 生成节点信息 =========="
  [[ -n "$PUBLIC4" || -n "$PUBLIC6" ]] || die "没有检测到公网 IPv4 或 IPv6。"
  if [[ -n "$PUBLIC4" ]]; then
    SERVER_ADDRESS="$PUBLIC4"
    QX_ADDRESS="$PUBLIC4"
    URI_ADDRESS="$PUBLIC4"
  else
    SERVER_ADDRESS="$PUBLIC6"
    QX_ADDRESS="[${PUBLIC6}]"
    URI_ADDRESS="[${PUBLIC6}]"
  fi

  NODE_NAME_B64="$(printf '%s' "$NODE_NAME" | base64 -w0)"
  cat >"$SETTINGS_FILE" <<EOF_SETTINGS
XRAY_PORT='${XRAY_PORT}'
NODE_NAME_B64='${NODE_NAME_B64}'
REALITY_SNI='${REALITY_SNI}'
REALITY_DEST='${REALITY_DEST}'
XRAY_UUID='${XRAY_UUID}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
PUBLIC4='${PUBLIC4}'
PUBLIC6='${PUBLIC6}'
ENABLE_DAILY_RESTART='${ENABLE_DAILY_RESTART}'
DAILY_RESTART_TIME='${DAILY_RESTART_TIME}'
EOF_SETTINGS
  chmod 600 "$SETTINGS_FILE"

  NODE_TAG_URI="$(jq -rn --arg value "$NODE_NAME" '$value|@uri')"
  QX_LINE="vless=${QX_ADDRESS}:${XRAY_PORT}, method=none, password=${XRAY_UUID}, obfs=over-tls, obfs-host=${REALITY_SNI}, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, vless-flow=xtls-rprx-vision, udp-relay=true, fast-open=false, tag=${NODE_NAME}"
  VLESS_URI="vless://${XRAY_UUID}@${URI_ADDRESS}:${XRAY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&flow=xtls-rprx-vision#${NODE_TAG_URI}"
  cat >"$NODE_FILE" <<EOF_NODE
Quantumult X 原生配置：
${QX_LINE}

标准 VLESS 链接：
${VLESS_URI}
EOF_NODE
  chmod 600 "$NODE_FILE"
}

write_info_command() {
  cat >"$INFO_BIN" <<'EOF_INFO'
#!/usr/bin/env bash
set -u
SETTINGS='/etc/vless-reality/settings.conf'
[[ -r "$SETTINGS" ]] || { echo '没有找到配置'; exit 1; }
# shellcheck disable=SC1090
. "$SETTINGS"
echo '========== Xray 状态 =========='
systemctl is-active xray.service || true
/usr/local/bin/xray version | sed -n '1p'
echo
echo '========== 端口监听 =========='
ss -Hlnpt | awk -v p=":${XRAY_PORT}" '$4 ~ p"$"'
echo
echo '========== 当前入站 TCP 连接 =========='
CONNECTIONS="$(ss -Htn state established "( sport = :${XRAY_PORT} )" 2>/dev/null || true)"
COUNT="$(printf '%s\n' "$CONNECTIONS" | sed '/^$/d' | wc -l)"
echo "连接数：${COUNT}"
printf '%s\n' "$CONNECTIONS"
echo
echo '========== 公网地址 =========='
echo "IPv4：${PUBLIC4:-无}"
echo "IPv6：${PUBLIC6:-无}"
echo
echo '========== BBR =========='
echo "算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
echo "队列：$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
echo
echo '========== 内存与 Swap =========='
free -h
echo
echo '========== 磁盘 =========='
df -h /
echo
echo '========== 每日重启 =========='
systemctl list-timers --all xray-daily-restart.timer --no-pager 2>/dev/null || true
echo
echo '========== Telegram 监控 =========='
systemctl is-active vless-reality-monitor.timer 2>/dev/null || true
systemctl list-timers --all vless-reality-monitor.timer --no-pager 2>/dev/null || true
echo "远程命令：$(systemctl is-active vless-reality-command-agent.service 2>/dev/null || true)"
echo
echo '========== 节点信息 =========='
cat /root/vless-node-info.txt
EOF_INFO
  chmod 700 "$INFO_BIN"
  ln -sf "$INFO_BIN" /root/vless-info.sh
  ln -sf "$INFO_BIN" /root/vless-link.sh
}

write_pair_command() {
  cat >"$PAIR_BIN" <<'EOF_PAIR'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
STATE_DIR='/etc/vless-reality'
SETTINGS="${STATE_DIR}/settings.conf"
MONITOR_CONF="${STATE_DIR}/monitor.conf"
NODE_FILE='/root/vless-node-info.txt'
[[ "$(id -u)" -eq 0 ]] || { echo '请使用 root 运行' >&2; exit 1; }
[[ -r "$SETTINGS" && -r "$NODE_FILE" ]] || { echo '缺少 VLESS 配置' >&2; exit 1; }
# shellcheck disable=SC1090
. "$SETTINGS"
OLD_URL=''; OLD_NAME="$(hostname -s)-VPS"
if [[ -r "$MONITOR_CONF" ]]; then
  # shellcheck disable=SC1090
  . "$MONITOR_CONF"
  OLD_URL="${WORKER_URL:-}"
  [[ -n "${DEVICE_NAME_B64:-}" ]] && OLD_NAME="$(printf '%s' "$DEVICE_NAME_B64" | base64 -d 2>/dev/null || printf '%s' "$OLD_NAME")"
fi
WORKER="${PAIR_WORKER_URL:-}"
NAME="${PAIR_DEVICE_NAME:-}"
CODE="${PAIR_CODE:-}"
if [[ -z "$WORKER" ]]; then printf 'Cloudflare 监控入口 [%s]：' "$OLD_URL"; IFS= read -r WORKER; WORKER="${WORKER:-$OLD_URL}"; fi
if [[ -z "$NAME" ]]; then printf '设备名称 [%s]：' "$OLD_NAME"; IFS= read -r NAME; NAME="${NAME:-$OLD_NAME}"; fi
if [[ -z "$CODE" ]]; then printf 'Telegram 中生成的一次性配对码：'; IFS= read -r CODE; fi
WORKER="${WORKER%/}"
[[ "$WORKER" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo 'Cloudflare 入口格式错误' >&2; exit 1; }
[[ -n "$NAME" && ${#NAME} -le 48 && ! "$NAME" =~ [[:cntrl:]] ]] || { echo '设备名称不正确' >&2; exit 1; }
CODE="$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
[[ ${#CODE} -eq 8 ]] || { echo '配对码应为 8 位字母数字' >&2; exit 1; }
NODE_B64="$(base64 -w0 "$NODE_FILE")"
RESPONSE="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 -X POST \
  "${WORKER}/api/v1/enroll" \
  --data-urlencode "pair_code=${CODE}" \
  --data-urlencode "device_name=${NAME}" \
  --data-urlencode 'device_type=vps' \
  --data-urlencode 'service_name=Xray' \
  --data-urlencode 'protocol_name=VLESS Reality Vision' \
  --data-urlencode "ss_port=${XRAY_PORT}" \
  --data-urlencode "node_b64=${NODE_B64}" 2>/dev/null || true)"
[[ "$(jq -r '.ok // false' <<<"$RESPONSE" 2>/dev/null)" == true ]] || { echo "配对失败：${RESPONSE:-Cloudflare 无响应}" >&2; exit 1; }
DEVICE_ID="$(jq -r '.device_id // empty' <<<"$RESPONSE")"
DEVICE_TOKEN="$(jq -r '.device_token // empty' <<<"$RESPONSE")"
[[ "$DEVICE_ID" =~ ^[a-f0-9]{16}$ ]] || { echo '设备 ID 不正确' >&2; exit 1; }
[[ "$DEVICE_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || { echo '设备 Token 不正确' >&2; exit 1; }
mkdir -p "$STATE_DIR"
cat >"${MONITOR_CONF}.tmp" <<EOF_CONF
MONITOR_ENABLED='1'
REMOTE_CONTROL='1'
WORKER_URL='${WORKER}'
DEVICE_NAME_B64='$(printf '%s' "$NAME" | base64 -w0)'
DEVICE_ID_B64='$(printf '%s' "$DEVICE_ID" | base64 -w0)'
DEVICE_TOKEN_B64='$(printf '%s' "$DEVICE_TOKEN" | base64 -w0)'
EOF_CONF
chmod 600 "${MONITOR_CONF}.tmp"
mv -f "${MONITOR_CONF}.tmp" "$MONITOR_CONF"
echo "配对成功：${NAME}（设备 ID：${DEVICE_ID}）"
EOF_PAIR
  chmod 700 "$PAIR_BIN"
}

write_monitor_agent() {
  cat >"$MONITOR_BIN" <<'EOF_MONITOR'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
CONF='/etc/vless-reality/monitor.conf'
SETTINGS='/etc/vless-reality/settings.conf'
NODE_FILE='/root/vless-node-info.txt'
STATE='/run/vless-reality-monitor.state'
IP_CACHE='/run/vless-reality-monitor.ip'
LOCK='/run/lock/vless-reality-monitor.lock'
FORCE_FULL=0
VERBOSE=0
for arg in "$@"; do case "$arg" in --full) FORCE_FULL=1 ;; --verbose) VERBOSE=1 ;; esac; done
out() { (( VERBOSE == 1 )) && printf '%s\n' "$*" || true; }
[[ -r "$CONF" && -r "$SETTINGS" && -r "$NODE_FILE" ]] || { out '监控尚未配置'; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
# shellcheck disable=SC1090
. "$SETTINGS"
[[ "${MONITOR_ENABLED:-0}" == 1 ]] || exit 0
exec 9>"$LOCK"
flock -n 9 || exit 0
DEVICE_NAME="$(printf '%s' "${DEVICE_NAME_B64:-}" | base64 -d 2>/dev/null || true)"
DEVICE_ID="$(printf '%s' "${DEVICE_ID_B64:-}" | base64 -d 2>/dev/null || true)"
DEVICE_TOKEN="$(printf '%s' "${DEVICE_TOKEN_B64:-}" | base64 -d 2>/dev/null || true)"
[[ "$DEVICE_ID" =~ ^[a-f0-9]{16}$ && "$DEVICE_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || exit 1

MEM_COUNT=0; STORAGE_COUNT=0; LOAD_COUNT=0; TCP_COUNT=0; SERVICE_COUNT=0; NOIP_COUNT=0
LAST_FULL=0; LAST_NODE_CKSUM=''; CF_FAILURES=0
[[ -r "$STATE" ]] && . "$STATE"
bump() { local var="$1" bad="$2" old new; eval "old=\${$var:-0}"; if (( bad )); then new=$((old+1)); ((new<=10)) || new=10; else new=0; fi; printf -v "$var" '%s' "$new"; }
add_alert() { if [[ -z "${ALERTS:-}" ]]; then ALERTS="$1"; else ALERTS+=",$1"; fi; }
save_state() {
  cat >"${STATE}.tmp" <<EOF_STATE
MEM_COUNT='$MEM_COUNT'
STORAGE_COUNT='$STORAGE_COUNT'
LOAD_COUNT='$LOAD_COUNT'
TCP_COUNT='$TCP_COUNT'
SERVICE_COUNT='$SERVICE_COUNT'
NOIP_COUNT='$NOIP_COUNT'
LAST_FULL='$LAST_FULL'
LAST_NODE_CKSUM='$LAST_NODE_CKSUM'
CF_FAILURES='$CF_FAILURES'
EOF_STATE
  mv -f "${STATE}.tmp" "$STATE"
}

NOW="$(date +%s)"
PUBLIC4="${PUBLIC4:-}"; PUBLIC6="${PUBLIC6:-}"; IP_CHECK_AT=0
[[ -r "$IP_CACHE" ]] && . "$IP_CACHE"
if (( NOW - IP_CHECK_AT >= 86400 )) || [[ -z "$PUBLIC4$PUBLIC6" ]]; then
  NEW4=''; NEW6=''
  for url in https://api.ipify.org https://ipv4.icanhazip.com; do
    NEW4="$(curl -4fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$NEW4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break || NEW4=''
  done
  for url in https://api6.ipify.org https://ipv6.icanhazip.com; do
    NEW6="$(curl -6fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$NEW6" == *:* ]] && break || NEW6=''
  done
  [[ -n "$NEW4" ]] && PUBLIC4="$NEW4"
  [[ -n "$NEW6" ]] && PUBLIC6="$NEW6"
  IP_CHECK_AT="$NOW"
  cat >"${IP_CACHE}.tmp" <<EOF_IP
PUBLIC4='$PUBLIC4'
PUBLIC6='$PUBLIC6'
IP_CHECK_AT='$IP_CHECK_AT'
EOF_IP
  mv -f "${IP_CACHE}.tmp" "$IP_CACHE"
fi

MEM_TOTAL="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
MEM_AVAIL="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
if [[ -z "$MEM_AVAIL" ]]; then MEM_AVAIL="$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo)"; fi
MEM_USED_PCT=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL ))
read -r LOAD1 LOAD5 LOAD15 _ </proc/loadavg
CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
DISK_USED_PCT="$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
UPTIME_SEC="$(awk '{printf "%d",$1}' /proc/uptime)"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
WAN_DEV="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
[[ -n "$WAN_DEV" ]] || WAN_DEV="$(ip -6 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
LOCAL4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
LOCAL6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
WAN_RX=0; WAN_TX=0
if [[ -n "$WAN_DEV" && -r "/sys/class/net/${WAN_DEV}/statistics/rx_bytes" ]]; then
  WAN_RX="$(cat "/sys/class/net/${WAN_DEV}/statistics/rx_bytes")"
  WAN_TX="$(cat "/sys/class/net/${WAN_DEV}/statistics/tx_bytes")"
fi
TEMP_C="$(/usr/local/sbin/node-temperature --value 2>/dev/null || true)"
TEMP_SOURCE="$(/usr/local/sbin/node-temperature --source 2>/dev/null || true)"
XRAY_RUNNING=0; systemctl is-active --quiet xray.service && XRAY_RUNNING=1
TCP_OK=0; ss -Hlnpt 2>/dev/null | awk -v p=":${XRAY_PORT}" '$4 ~ p"$" && $0 ~ /xray/{found=1}END{exit !found}' && TCP_OK=1
# VLESS UDP uses XUDP inside the TCP stream; no separate UDP socket is expected.
UDP_CAPABLE=0; (( XRAY_RUNNING == 1 && TCP_OK == 1 )) && UDP_CAPABLE=1
CONNECTION_COUNT="$(ss -Htn state established "( sport = :${XRAY_PORT} )" 2>/dev/null | sed '/^$/d' | wc -l || true)"
XRAY_VERSION="$(/usr/local/bin/xray version 2>/dev/null | sed -n '1s/^Xray //p' || true)"
OS_NAME="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-Linux}")"

bump SERVICE_COUNT "$((XRAY_RUNNING == 0))"
bump TCP_COUNT "$((TCP_OK == 0))"
bump MEM_COUNT "$((MEM_AVAIL < 65536 || MEM_USED_PCT >= 90))"
bump STORAGE_COUNT "$((DISK_USED_PCT >= 90))"
LOAD_BAD="$(awk -v l="$LOAD5" -v c="$CPU_CORES" 'BEGIN{print (l > c*2)?1:0}')"
bump LOAD_COUNT "$LOAD_BAD"
bump NOIP_COUNT "$([[ -z "$PUBLIC4$PUBLIC6" ]] && echo 1 || echo 0)"
ALERTS=''
(( SERVICE_COUNT >= 2 )) && add_alert service
(( TCP_COUNT >= 2 )) && add_alert tcp
(( MEM_COUNT >= 3 )) && add_alert memory
(( STORAGE_COUNT >= 3 )) && add_alert storage
(( LOAD_COUNT >= 3 )) && add_alert load
(( NOIP_COUNT >= 3 )) && add_alert no_public_ip

NODE_CKSUM="$(sha256sum "$NODE_FILE" | awk '{print $1}')"
FULL="$FORCE_FULL"
(( LAST_FULL == 0 || NOW - LAST_FULL >= 86400 )) && FULL=1
[[ "$NODE_CKSUM" != "$LAST_NODE_CKSUM" ]] && FULL=1

send_report() {
  local send_full="$1" node_b64='' response ok refresh temp_node
  if (( send_full == 1 )); then
    temp_node="$(mktemp /run/vless-node-report.XXXXXX)"
    cat "$NODE_FILE" >"$temp_node"
    cat >>"$temp_node" <<EOF_LIVE

最近完整上报：$(date '+%Y-%m-%d %H:%M:%S %Z')
Xray 版本：${XRAY_VERSION:-未知}
当前 TCP 连接数：${CONNECTION_COUNT}
服务器运行时间：${UPTIME_SEC} 秒
内存使用率：${MEM_USED_PCT}%
根分区使用率：${DISK_USED_PCT}%
EOF_LIVE
    node_b64="$(base64 -w0 "$temp_node")"
    rm -f "$temp_node"
  fi
  NETWORK_TYPE="VPS · VLESS Reality Vision"
  [[ -n "$PUBLIC4" && -n "$PUBLIC6" ]] && NETWORK_TYPE+=" · 双栈" || NETWORK_TYPE+=" · 单栈"
  response="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 20 -X POST \
    "${WORKER_URL}/api/v1/report" \
    -H "X-Device-ID: ${DEVICE_ID}" \
    -H "Authorization: Bearer ${DEVICE_TOKEN}" \
    --data-urlencode "device_name=${DEVICE_NAME}" \
    --data-urlencode 'device_type=vps' --data-urlencode 'service_name=Xray' \
    --data-urlencode 'protocol_name=VLESS Reality Vision' \
    --data-urlencode "current_connections=${CONNECTION_COUNT}" \
    --data-urlencode "router_time=${NOW}" --data-urlencode "uptime_sec=${UPTIME_SEC}" \
    --data-urlencode "boot_id=${BOOT_ID}" --data-urlencode "model=Cloud VPS · 当前连接 ${CONNECTION_COUNT}" \
    --data-urlencode "firmware=${OS_NAME} · Xray ${XRAY_VERSION:-未知}" \
    --data-urlencode "mem_total_kb=${MEM_TOTAL}" --data-urlencode "mem_available_kb=${MEM_AVAIL}" \
    --data-urlencode "mem_used_pct=${MEM_USED_PCT}" --data-urlencode "load1=${LOAD1}" \
    --data-urlencode "load5=${LOAD5}" --data-urlencode "load15=${LOAD15}" --data-urlencode "cpu_cores=${CPU_CORES}" \
    --data-urlencode "temperature_c=$TEMP_C" --data-urlencode "temperature_source=$TEMP_SOURCE" --data-urlencode 'udp_mode=vless-tunnel' --data-urlencode "overlay_used_pct=${DISK_USED_PCT}" \
    --data-urlencode "wan_if=${WAN_DEV}" --data-urlencode "wan_dev=${WAN_DEV}" \
    --data-urlencode "network_type=${NETWORK_TYPE}" --data-urlencode "local4=${LOCAL4}" \
    --data-urlencode "public4=${PUBLIC4}" --data-urlencode "local6=${LOCAL6}" --data-urlencode "public6=${PUBLIC6}" \
    --data-urlencode 'ddns_domain=' --data-urlencode 'ddns_mode=none' --data-urlencode 'ddns_ok=1' \
    --data-urlencode 'ddns_failures=0' --data-urlencode "singbox_running=${XRAY_RUNNING}" \
    --data-urlencode "tcp_listen=${TCP_OK}" --data-urlencode "udp_listen=${UDP_CAPABLE}" \
    --data-urlencode "node_config=1" \
    --data-urlencode "ss_port=${XRAY_PORT}" --data-urlencode "wan_rx_bytes=${WAN_RX}" \
    --data-urlencode "wan_tx_bytes=${WAN_TX}" --data-urlencode 'auto_restarted=0' \
    --data-urlencode "alerts=${ALERTS}" --data-urlencode "full=${send_full}" \
    --data-urlencode "node_b64=${node_b64}" 2>/dev/null || true)"
  ok="$(jq -r '.ok // false' <<<"$response" 2>/dev/null || true)"
  if [[ "$ok" != true ]]; then
    CF_FAILURES=$((CF_FAILURES+1)); (( CF_FAILURES <= 20 )) || CF_FAILURES=20
    out "Cloudflare 上报失败：${response:-无响应}"
    return 1
  fi
  CF_FAILURES=0
  if (( send_full == 1 )); then LAST_FULL="$NOW"; LAST_NODE_CKSUM="$NODE_CKSUM"; fi
  refresh="$(jq -r '.refresh // false' <<<"$response" 2>/dev/null || true)"
  out "状态上报成功；完整=${send_full}；连接=${CONNECTION_COUNT}；异常=${ALERTS:-无}"
  [[ "$refresh" == true && "$send_full" == 0 ]] && return 2
  return 0
}

RESULT=0
send_report "$FULL" || RESULT=$?
if (( RESULT == 2 )); then send_report 1 || RESULT=1; fi
save_state
(( RESULT == 1 )) && exit 1
exit 0
EOF_MONITOR
  chmod 700 "$MONITOR_BIN"

  cat >/etc/systemd/system/vless-reality-monitor.service <<EOF_MONITOR_SERVICE
[Unit]
Description=Report VLESS REALITY VPS state to existing Cloudflare center
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${MONITOR_BIN}
User=root
Nice=10
IOSchedulingClass=idle
StandardOutput=null

[Install]
WantedBy=multi-user.target
EOF_MONITOR_SERVICE
  cat >/etc/systemd/system/vless-reality-monitor.timer <<'EOF_MONITOR_TIMER'
[Unit]
Description=Poll Cloudflare refresh requests and report VPS state

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
RandomizedDelaySec=3s
AccuracySec=1s
Persistent=false
Unit=vless-reality-monitor.service

[Install]
WantedBy=timers.target
EOF_MONITOR_TIMER
}

write_command_agent() {
  cat >"$COMMAND_BIN" <<'EOF_COMMAND'
#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
CONF='/etc/vless-reality/monitor.conf'
SETTINGS='/etc/vless-reality/settings.conf'
LOCK='/run/lock/vless-reality-command-agent.lock'
[[ "$(id -u)" -eq 0 ]] || exit 1
exec 9>"$LOCK"
flock -n 9 || exit 0

decode_identity() {
  [[ -r "$CONF" && -r "$SETTINGS" ]] || return 1
  # shellcheck disable=SC1090
  . "$CONF"
  # shellcheck disable=SC1090
  . "$SETTINGS"
  [[ "${MONITOR_ENABLED:-0}" == 1 ]] || return 1
  [[ "${REMOTE_CONTROL:-0}" == 1 ]] || return 1
  DEVICE_ID="$(printf '%s' "${DEVICE_ID_B64:-}" | base64 -d 2>/dev/null || true)"
  DEVICE_TOKEN="$(printf '%s' "${DEVICE_TOKEN_B64:-}" | base64 -d 2>/dev/null || true)"
  [[ "$DEVICE_ID" =~ ^[a-f0-9]{16}$ && "$DEVICE_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]]
}

safe_status() {
  echo "时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "主机：$(hostname -f 2>/dev/null || hostname)"
  echo "系统：$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-Linux}")"
  echo "内核：$(uname -r)"
  echo "运行时间：$(uptime -p 2>/dev/null || awk '{print $1" 秒"}' /proc/uptime)"
  echo "Xray：$(systemctl is-active xray.service 2>/dev/null || true)"
  /usr/local/bin/xray version 2>/dev/null | sed -n '1p'
  echo "端口：${XRAY_PORT}/TCP"
  echo "当前连接：$(ss -Htn state established "( sport = :${XRAY_PORT} )" 2>/dev/null | sed '/^$/d' | wc -l)"
  echo "公网IPv4：${PUBLIC4:-无}"
  echo "公网IPv6：${PUBLIC6:-无}"
  echo "BBR：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  /usr/local/sbin/node-temperature || true
  echo
  free -h
  echo
  df -h /
}

capture_shell() {
  local payload="$1" output="$2" status_file="${2}.status" rc
  rm -f "$status_file"
  (
    exec 9>&-
    rc=0
    timeout --kill-after=5s 120s bash -lc "$payload" || rc=$?
    printf '%s\n' "$rc" > "$status_file"
  ) 2>&1 | timeout --kill-after=5s 125s sh -c 'head -c 60000; cat >/dev/null' > "$output" || true
  rc="$(cat "$status_file" 2>/dev/null || printf 124)"
  rm -f "$status_file"
  return "$rc"
}

run_command() {
  local action="$1" payload="$2" output_file="$3"
  COMMAND_EXIT=0
  case "$action" in
    node_config)
      printf '%s' "$payload" | timeout -k 10 240 /usr/local/sbin/node-config >"$output_file" 2>&1 || COMMAND_EXIT=$?
      ;;
    status)
      safe_status >"$output_file" 2>&1 || COMMAND_EXIT=$?
      ;;
    refresh)
      {
        echo '正在实时刷新 VPS 状态与节点信息...'
        /usr/local/sbin/vless-reality-monitor --full --verbose
        echo '实时刷新完成'
      } >"$output_file" 2>&1 || COMMAND_EXIT=$?
      ;;
    restart_xray)
      {
        echo '正在重启 Xray...'
        systemctl restart xray.service
        sleep 2
        systemctl --no-pager --full status xray.service | sed -n '1,18p'
      } >"$output_file" 2>&1 || COMMAND_EXIT=$?
      ;;
    update_xray)
      {
        echo '正在从 XTLS 官方仓库更新 Xray...'
        timeout --kill-after=10s 240s /usr/local/sbin/vless-reality-update
      } >"$output_file" 2>&1 || COMMAND_EXIT=$?
      ;;
    reboot)
      printf '%s\n' '已接受重启命令，VPS 将在 3 秒后重启。' >"$output_file"
      REBOOT_AFTER_RESULT=1
      ;;
    shell)
      capture_shell "$payload" "$output_file" || COMMAND_EXIT=$?
      ;;
    *)
      printf '拒绝未知操作：%s\n' "$action" >"$output_file"
      COMMAND_EXIT=64
      ;;
  esac
}

submit_result() {
  local command_id="$1" exit_code="$2" output_file="$3" result_b64 response attempt
  # Telegram 和 Worker 都有大小限制，只回传前 60 KiB。
  head -c 60000 "$output_file" >"${output_file}.clip"
  result_b64="$(base64 -w0 "${output_file}.clip")"
    RESULT_NODE_B64=''
    if [ "${action:-}" = node_config ] && [ "${exit_code}" = 0 ]; then
        RESULT_NODE_B64="$(base64 /root/vless-node-info.txt | tr -d '\r\n')"
    fi
  for attempt in 1 2 3 4 5; do
    response="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 25 -X POST \
      "${WORKER_URL}/api/v1/command/result" \
      -H "X-Device-ID: ${DEVICE_ID}" \
      -H "Authorization: Bearer ${DEVICE_TOKEN}" \
      --data-urlencode "command_id=${command_id}" \
      --data-urlencode "exit_code=${exit_code}" \
      --data-urlencode "node_b64=${RESULT_NODE_B64}" \
            --data-urlencode "result_b64=${result_b64}" 2>/dev/null || true)"
    [[ "$(jq -r '.ok // false' <<<"$response" 2>/dev/null || true)" == true ]] && return 0
    sleep $((attempt * 2))
  done
  return 1
}

poll_once() {
  decode_identity || return 1
  local response command_id action payload output_file
  response="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 20 -X POST \
    "${WORKER_URL}/api/v1/command/poll" \
    -H "X-Device-ID: ${DEVICE_ID}" \
    -H "Authorization: Bearer ${DEVICE_TOKEN}" -d '' 2>/dev/null || true)"
  [[ "$(jq -r '.ok // false' <<<"$response" 2>/dev/null || true)" == true ]] || return 1
  command_id="$(jq -r '.command.id // empty' <<<"$response")"
  [[ -n "$command_id" ]] || return 2
  action="$(jq -r '.command.action // empty' <<<"$response")"
  payload="$(jq -r '.command.payload // empty' <<<"$response")"
  [[ "$command_id" =~ ^[a-f0-9]{24}$ ]] || return 1
  output_file="$(mktemp /run/vless-command-output.XXXXXX)"
  COMMAND_EXIT=0
  REBOOT_AFTER_RESULT=0
  run_command "$action" "$payload" "$output_file"
  submit_result "$command_id" "$COMMAND_EXIT" "$output_file" || true
  rm -f "$output_file" "${output_file}.clip"
  if (( REBOOT_AFTER_RESULT == 1 )); then
    nohup bash -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
    exit 0
  fi
  return 0
}

while true; do
  rc=0
  poll_once || rc=$?
  case "$rc" in
    0) sleep 2 ;;
    2) sleep 10 ;;
    *) sleep 30 ;;
  esac
done
EOF_COMMAND
  chmod 700 "$COMMAND_BIN"

  cat >/etc/systemd/system/vless-reality-command-agent.service <<EOF_COMMAND_SERVICE
[Unit]
Description=Telegram root command agent for managed VLESS VPS
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${COMMAND_BIN}
User=root
Restart=always
RestartSec=10s
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=false
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_COMMAND_SERVICE
}

start_xray() {
  say
  say "========== 15. 启动并验证 Xray =========="
  systemctl daemon-reload
  systemd-analyze verify /etc/systemd/system/xray.service /etc/systemd/system/vless-reality-firewall.service
  systemctl enable xray.service >/dev/null
  systemctl restart xray.service
  sleep 2
  if ! systemctl is-active --quiet xray.service; then
    journalctl -u xray.service -n 60 --no-pager >&2 || true
    die "Xray 启动失败。"
  fi
  if ! port_owned_by_xray "$XRAY_PORT"; then
    journalctl -u xray.service -n 60 --no-pager >&2 || true
    die "Xray 已启动但没有监听 TCP ${XRAY_PORT}。"
  fi
  say "Xray 已正常监听 TCP ${XRAY_PORT}。"
  FW_CHANGED=1
  if [[ -s /proc/net/if_inet6 ]] && ! ip6tables -w 5 -C INPUT -p tcp --dport "$XRAY_PORT" -m comment --comment home-suite-vless -j ACCEPT 2>/dev/null; then FW6_ADDED=1; fi
  systemctl enable vless-reality-firewall.service >/dev/null
  systemctl restart vless-reality-firewall.service
  iptables -w 5 -C XRAY_VLESS -p tcp --dport "$XRAY_PORT" -j ACCEPT || die 'Xray IPv4 放行规则未生效'
  # Xray 已通过配置测试、启动和端口检查；之后若只是配对失败，不回滚可用节点。
  ROLLBACK_READY=0
}

configure_monitor() {
  (( ENABLE_MONITOR == 1 )) || {
    systemctl disable --now vless-reality-monitor.timer >/dev/null 2>&1 || true
    systemctl disable --now vless-reality-command-agent.service >/dev/null 2>&1 || true
    say "Cloudflare/Telegram 监控未启用。"
    return 0
  }

  say
  say "========== 16. 接入现有 Telegram Bot =========="
  local reuse_ok=0
  if [[ -r "$MONITOR_CONF" ]] && [[ "$WORKER_URL" == "$OLD_MONITOR_URL" ]]; then
    sed -i "s/^MONITOR_ENABLED=.*/MONITOR_ENABLED='1'/" "$MONITOR_CONF"
    if "$MONITOR_BIN" --full --verbose; then
      reuse_ok=1
      say "现有设备身份仍有效，已直接复用。"
    else
      warn "现有设备身份不可用，需要重新配对。"
    fi
  fi
  if (( reuse_ok == 0 )); then
    say "请在 Telegram 中进入：路由节点 → 添加设备，生成新的 10 分钟一次性配对码。"
    PAIR_WORKER_URL="$WORKER_URL" PAIR_DEVICE_NAME="$DEVICE_NAME" "$PAIR_BIN"
    "$MONITOR_BIN" --full --verbose || die "配对成功，但首次状态上报失败。"
  fi
  # Persist chosen name/URL even when reusing a valid identity.
  sed -i '/^REMOTE_CONTROL=/d; /^DEVICE_NAME_B64=/d' "$MONITOR_CONF"
  printf "REMOTE_CONTROL='1'\nDEVICE_NAME_B64='%s'\n" "$(printf '%s' "$DEVICE_NAME" | base64 -w0)" >> "$MONITOR_CONF"
  local device_id device_token check
  device_id="$(. "$MONITOR_CONF"; printf '%s' "$DEVICE_ID_B64" | base64 -d)"
  device_token="$(. "$MONITOR_CONF"; printf '%s' "$DEVICE_TOKEN_B64" | base64 -d)"
  check="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 -X POST "${WORKER_URL}/api/v1/command/check" -H "X-Device-ID: $device_id" -H "Authorization: Bearer $device_token" -d '' 2>/dev/null || true)"
  jq -e '.ok == true and .command_api == true' <<<"$check" >/dev/null || die '远控鉴权/API/命令表验证失败；节点保留，整套安装未完成'
  systemctl daemon-reload
  systemctl enable --now vless-reality-monitor.timer >/dev/null
  systemctl enable vless-reality-command-agent.service >/dev/null
  systemctl restart vless-reality-command-agent.service
  sleep 3
  systemctl is-active --quiet vless-reality-command-agent.service || die '远控代理未运行；整套安装未完成'
  systemctl is-active --quiet vless-reality-monitor.timer || die '监控 timer 未运行'
  say "监控已启用：每 30 秒上报；Telegram root 命令通常 10 秒内领取。"
}

show_result() {
  INSTALL_DONE=1
  say
  say "==================== 安装完成 ===================="
  cat "$NODE_FILE"
  say "=================================================="
  say
  say "Quantumult X 扫码："
  local qx_line
  qx_line="$(sed -n '/^Quantumult X 原生配置：/{n;p;}' "$NODE_FILE")"
  qrencode -t ANSIUTF8 "$qx_line" || true
  say
  say "本机完整检查：vless-reality-info"
  say "强制上报：vless-reality-monitor --full --verbose"
  say "重新配对：vless-reality-pair"
  say "配置备份：${BACKUP_DIR}"
  say
  say "请确认云厂商安全组已放行 TCP ${XRAY_PORT}；无需放行 UDP ${XRAY_PORT}。"
  say "Telegram：节点中心 → VPS → VPS远程控制。"
  say "Shell 命令：/vps 设备ID shell 命令（以 root 执行，最长 120 秒）。"
}

main() {
  need_root_and_os
  install_dependencies
  load_old_values
  read_settings
  choose_available_port
  check_reality_target
  check_monitor_endpoint
  PUBLIC4="$(detect_public_ip 4 || true)"
  PUBLIC6="$(detect_public_ip 6 || true)"
  [[ -n "$PUBLIC4" || -n "$PUBLIC6" ]] || die '外网地址回显失败；尚未改业务配置'
  install_xray
  generate_or_reuse_credentials
  write_xray_config
  smoke_test_xray
  if (( PREFLIGHT_ONLY == 1 )); then say '预检通过；缺失依赖已补齐，未写业务配置、未配对、未改变防火墙'; return 0; fi
  say "即将安装：TCP $XRAY_PORT；Telegram root 远控开启；保留 SSH 配置；备份 $BACKUP_DIR"
  printf '确认写入？[Y/n]：'
  IFS= read -r answer
  case "${answer:-Y}" in y|Y|yes|YES) ;; *) die '用户取消，未写业务配置' ;; esac
  prepare_backup
  mkdir -p "$STATE_DIR"
  commit_xray
  configure_service_limits
  write_firewall_helper
  write_settings_and_node
  start_xray
  configure_bbr
  configure_swap
  configure_daily_restart
  write_info_command
  write_pair_command
  write_monitor_agent
  write_command_agent
  write_update_helper
  configure_monitor
  systemctl daemon-reload
  if (( ENABLE_DAILY_RESTART == 1 )); then systemctl enable --now xray-daily-restart.timer; fi
  show_result
}

write_update_helper() {
  cat > /usr/local/sbin/vless-reality-update <<'EOF_UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $(id -u) == 0 ]] || exit 1
exec 8>/run/lock/install-vless-reality.lock
flock -n 8 || { echo '安装/维护正在运行'; exit 1; }
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(curl -fsS --connect-timeout 10 --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er '.tag_name')"
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '版本格式应为 v26.3.27'; exit 1; }
case "$(uname -m)" in x86_64) ASSET='Xray-linux-64.zip' ;; aarch64|arm64) ASSET='Xray-linux-arm64-v8a.zip' ;; *) exit 1 ;; esac
TMP_UPDATE="$(mktemp -d /tmp/xray-update.XXXXXX)"
CHANGED=0
finish_update() {
  local rc=$?
  set +e
  if [[ $rc != 0 && $CHANGED == 1 ]]; then
    install -m 755 "$TMP_UPDATE/old-xray" /usr/local/bin/xray.restore
    mv -f /usr/local/bin/xray.restore /usr/local/bin/xray
    systemctl restart xray
    echo '更新失败，已恢复旧二进制并尝试重启；节点配置未改'
  fi
  rm -rf "$TMP_UPDATE"
  exit "$rc"
}
trap finish_update EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
URL="https://github.com/XTLS/Xray-core/releases/download/$VERSION/$ASSET"
curl -fL --retry 1 --connect-timeout 10 --max-time 60 "$URL" -o "$TMP_UPDATE/xray.zip"
curl -fL --retry 1 --connect-timeout 10 --max-time 25 "$URL.dgst" -o "$TMP_UPDATE/digest"
EXPECTED="$(grep -iE 'SHA(2|-|2-)?256' "$TMP_UPDATE/digest" | grep -Eo '[a-fA-F0-9]{64}' | head -n1 | tr A-F a-f)"
[[ -n "$EXPECTED" && "$(sha256sum "$TMP_UPDATE/xray.zip" | awk '{print $1}')" == "$EXPECTED" ]]
unzip -p "$TMP_UPDATE/xray.zip" xray > "$TMP_UPDATE/xray"
chmod 755 "$TMP_UPDATE/xray"
"$TMP_UPDATE/xray" run -test -config /usr/local/etc/xray/config.json
cp /usr/local/bin/xray "$TMP_UPDATE/old-xray"
install -m 755 "$TMP_UPDATE/xray" /usr/local/bin/xray.new
CHANGED=1
mv -f /usr/local/bin/xray.new /usr/local/bin/xray
systemctl restart xray
sleep 3
systemctl is-active --quiet xray
. /etc/vless-reality/settings.conf
ss -Hlnpt | awk -v p=":$XRAY_PORT" '$4~p"$" && /xray/ {f=1} END{exit !f}'
CHANGED=0
/usr/local/bin/xray version | sed -n '1p'
echo '内核更新成功，未改 UUID/密钥/配置。只有显式调用本维护命令才升级。'
EOF_UPDATE
  chmod 700 /usr/local/sbin/vless-reality-update
}

# BEGIN SHARED RUNTIME
# Shared installer functions. Embedded into each standalone installer by build.mjs.
# POSIX sh / BusyBox ash compatible; installation-time calls only.

suite_version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if(x[i]+0>y[i]+0)exit 0;if(x[i]+0<y[i]+0)exit 1}exit 0}'
}

suite_native() {
    [ -r "$1" ] && [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = 7f454c46 ]
}

suite_stage_xray() {
    # Never launch Kwrt's /usr/bin/sing-box wrapper, nor replace a package-owned Xray.
    local installed="$1" release='v26.7.28' current='' asset='' expected='' actual=''
    # 家宽官方下载慢时可由 Mac 辅助器校验官方压缩包并预先上传。
    if [ -s /tmp/home-node-xray ] && suite_native /tmp/home-node-xray; then
        current="$(timeout -k 2 10 /tmp/home-node-xray version 2>/dev/null | awk 'NR==1{print $2}' || true)"
        case "$current" in ''|*[!0-9.]*) current='' ;; esac
        if [ -n "$current" ] && suite_version_ge "$current" "${release#v}"; then
            cp /tmp/home-node-xray "$STAGE/xray" || die '无法暂存已校验的离线 Xray'
            say "使用已校验的离线 Xray $current"
        fi
    fi
    if suite_native "$installed"; then
        current="$(timeout -k 2 10 "$installed" version 2>/dev/null | awk 'NR==1{print $2}' || true)"
        case "$current" in ''|*[!0-9.]*) current='' ;; esac
        if [ -n "$current" ] && suite_version_ge "$current" "${release#v}"; then
            cp "$installed" "$STAGE/xray" || die '无法暂存现有 Xray'
            say "保留兼容的原生 Xray $current"
        fi
    fi
    if [ ! -s "$STAGE/xray" ]; then
        case "$(uname -m)" in
            x86_64) asset=Xray-linux-64.zip ;;
            i386|i486|i586|i686) asset=Xray-linux-32.zip ;;
            aarch64|arm64) asset=Xray-linux-arm64-v8a.zip ;;
            armv7*) asset=Xray-linux-arm32-v7a.zip ;;
            armv6*) asset=Xray-linux-arm32-v6.zip ;;
            mipsel|mipsle) asset=Xray-linux-mips32le.zip ;;
            mips) if [ "$(od -An -tu1 -j5 -N1 /bin/busybox | tr -d ' ')" = 1 ]; then asset=Xray-linux-mips32le.zip; else asset=Xray-linux-mips32.zip; fi ;;
            *) die "不支持的架构 $(uname -m)，不猜测二进制" ;;
        esac
        say "暂存官方 Xray $release（$asset），校验成功后才执行"
        local url="https://github.com/XTLS/Xray-core/releases/download/$release/$asset"
        # 可续传，避免家宽连接慢时每次从零开始；仍只接受官方发布和官方摘要。
        curl -fL -C - --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 "$url" -o "$STAGE/xray.zip" || die '官方 Xray 下载失败；旧节点未改，不使用未知镜像'
        curl -fL --retry 2 --connect-timeout 10 --max-time 45 "$url.dgst" -o "$STAGE/xray.dgst" || die '官方摘要下载失败，拒绝跳过校验'
        expected="$(awk 'toupper($0) ~ /SHA(2|-|2-)?256/ {for(i=1;i<=NF;i++)if(length($i)==64 && $i !~ /[^a-fA-F0-9]/){print tolower($i);exit}}' "$STAGE/xray.dgst")"
        actual="$(sha256sum "$STAGE/xray.zip" | awk '{print $1}')"
        [ -n "$expected" ] && [ "$actual" = "$expected" ] || die 'Xray SHA256 不匹配，旧节点未改'
        case "$(uname -m)" in
            mipsel|mipsle|mips)
                # MT7621 等 MIPS 软浮点路由器执行官方 xray 硬浮点文件会报 Illegal instruction。
                # 新版官方 zip 同时带 xray_softfloat，优先使用它；旧 zip 才回退 xray。
                unzip -p "$STAGE/xray.zip" xray_softfloat > "$STAGE/xray" 2>/dev/null || true
                suite_native "$STAGE/xray" || unzip -p "$STAGE/xray.zip" xray > "$STAGE/xray" || die '压缩包内没有 Xray 二进制'
                ;;
            *) unzip -p "$STAGE/xray.zip" xray > "$STAGE/xray" || die '压缩包内没有 Xray 二进制' ;;
        esac
    fi
    suite_native "$STAGE/xray" || die 'Xray 不是原生 ELF 可执行文件'
    chmod 755 "$STAGE/xray"
    XRAY_BIN="$STAGE/xray"
    timeout -k 2 10 "$XRAY_BIN" version || die 'Xray 在当前架构/内核上无法执行'
}

suite_socket_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -Hlnut 2>/dev/null | awk -v p=":$1" '$5~p"$"{f=1}END{exit !f}'
    else
        netstat -lnut 2>/dev/null | awk -v p=":$1" '$4~p"$"{f=1}END{exit !f}'
    fi
}

suite_probe_cleanup() {
    local p
    for p in ${SUITE_PROBE_PIDS:-}; do kill "$p" 2>/dev/null || true; done
    for p in ${SUITE_PROBE_PIDS:-}; do wait "$p" 2>/dev/null || true; done
    SUITE_PROBE_PIDS=''
}

suite_smoke_xray() {
    # Real authenticated REALITY/Vision round trips; not just a LISTEN check.
    local p=49100 ready=0 n=0 tcp='' udp='' marker='home-suite-uvr-test'
    while suite_socket_busy "$p" || suite_socket_busy "$((p+1))" || suite_socket_busy "$((p+2))"; do
        p=$((p+3)); [ "$p" -lt 50000 ] || die '无可用回环测试端口'
    done
    jq --argjson p "$p" '.inbounds[0].listen="127.0.0.1" | .inbounds[0].port=$p' "$STAGE/config.json" > "$STAGE/probe.json"
    jq -n --argjson port "$((p+1))" --argjson echo "$((p+2))" --argjson server "$p" \
        --arg uuid "$XRAY_UUID" --arg sni "$REALITY_SNI" --arg key "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" \
        '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$port,protocol:"dokodemo-door",settings:{address:"127.0.0.1",port:$echo,network:"tcp,udp"}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$server,users:[{id:$uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},streamSettings:{network:"raw",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$key,shortId:$sid}}}]}' > "$STAGE/client.json"
    # Xray 26.4+ 的 freedom 默认阻止私有地址；这只给临时 127.0.0.1 回环回显放行，
    # 正式节点配置仍保持默认私网保护。
    jq --argjson ep "$((p+2))" '.outbounds |= map(if .protocol == "freedom" then .settings.finalRules = ([{action:"allow",network:"tcp,udp",ip:["127.0.0.1/32"],port:($ep|tostring)}] + (.settings.finalRules // [])) else . end)' "$STAGE/probe.json" > "$STAGE/probe.allow.json" || die '无法生成回环测试例外'
    mv "$STAGE/probe.allow.json" "$STAGE/probe.json"
    "$XRAY_BIN" run -test -config "$STAGE/probe.json" > "$STAGE/probe.log" 2>&1 || die "服务端配置检查失败，日志：$STAGE/probe.log"
    "$XRAY_BIN" run -test -config "$STAGE/client.json" >> "$STAGE/probe.log" 2>&1 || die "客户端配置检查失败，日志：$STAGE/probe.log"
    "$XRAY_BIN" run -config "$STAGE/probe.json" >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$!"
    "$XRAY_BIN" run -config "$STAGE/client.json" >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    socat -t 2 -T 60 "TCP4-LISTEN:$((p+2)),bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    socat -t 2 -T 60 "UDP4-RECVFROM:$((p+2)),bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    while [ "$n" -lt 10 ]; do
        if suite_socket_busy "$p" && suite_socket_busy "$((p+1))" && suite_socket_busy "$((p+2))"; then ready=1; break; fi
        n=$((n+1)); sleep 1
    done
    if [ "$ready" = 1 ]; then
        # socat's default EOF grace is only 0.5s; REALITY target RTT may exceed it.
        tcp="$(printf '%s\n' "$marker" | timeout -k 2 55 socat -t 1 -T 45 STDIO,ignoreeof "TCP4:127.0.0.1:$((p+1)),readbytes=$((${#marker}+1))" 2>> "$STAGE/probe.log" || true)"
        udp="$(printf '%s\n' "$marker" | timeout -k 2 55 socat -t 1 -T 45 STDIO,ignoreeof "UDP4:127.0.0.1:$((p+1)),readbytes=$((${#marker}+1))" 2>> "$STAGE/probe.log" || true)"
    fi
    suite_probe_cleanup
    if [ "$tcp" != "$marker" ] || [ "$udp" != "$marker" ]; then
        tail -n 40 "$STAGE/probe.log" >&2
        die "REALITY/Vision TCP 或 UDP 隧道回环验证失败；旧节点保持原状。日志：$STAGE/probe.log"
    fi
    say '真实 REALITY 认证、Vision 配置、TCP/UDP 隧道双向数据回环通过（不等于公网可达或圈 X 实测）'
}

suite_check_target() {
    local try=0 target_host="${REALITY_DEST%:*}" result=1
    while [ "$try" -lt 2 ]; do
        timeout -k 2 15 openssl s_client -connect "$REALITY_DEST" -servername "$REALITY_SNI" -tls1_3 -alpn h2 -verify_hostname "$REALITY_SNI" -verify_return_error </dev/null > "$STAGE/target.log" 2>&1 || true
        if grep -q 'Verify return code: 0 (ok)' "$STAGE/target.log" && grep -q 'ALPN protocol: h2' "$STAGE/target.log"; then result=0; break; fi
        try=$((try+1))
    done
    [ "$result" = 0 ] || { tail -n 12 "$STAGE/target.log" >&2; die 'REALITY 目标必须可直连、证书匹配 SNI、支持 TLS 1.3 与 h2；请重跑更换目标，旧节点未改'; }
    say "REALITY 目标 $REALITY_DEST：TLS 1.3 / h2 / 证书校验通过"
}

suite_write_runtime() {
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/node-temperature <<'EOF_TEMPERATURE'
#!/bin/sh
# All standard hwmon and thermal sysfs temperatures are millidegrees Celsius.
# Never turn zero/no-sensor into '0 degrees' or guess a firmware-specific unit.
LC_ALL=C; export LC_ALL
root="${NODE_SENSOR_ROOT:-/sys}"
best=''; source=''; priority=-1
for file in "$root"/class/hwmon/hwmon*/temp*_input "$root"/class/thermal/thermal_zone*/temp; do
    [ -r "$file" ] || continue
    value="$(awk 'NR==1{print $1;exit}' "$file" 2>/dev/null)"
    case "$value" in ''|*[!0-9-]*) continue ;; esac
    [ "$value" -gt 0 ] 2>/dev/null && [ "$value" -le 125000 ] 2>/dev/null || continue
    dir="${file%/*}"
    name="$(awk 'NR==1{print;exit}' "$dir/name" 2>/dev/null || awk 'NR==1{print;exit}' "$dir/type" 2>/dev/null)"
    level=0
    case "$name" in coretemp|k10temp|cpu*|*cpu*thermal*|*soc*thermal*) level=1 ;; esac
    if [ "$level" -gt "$priority" ] || { [ "$level" -eq "$priority" ] && { [ -z "$best" ] || [ "$value" -gt "$best" ]; }; }; then
        best="$value"; source="$name:${file##*/}"; priority="$level"
    fi
done
case "${1:-}" in
    --value) [ -z "$best" ] || awk -v v="$best" 'BEGIN{printf "%.1f\n",v/1000}'; exit 0 ;;
    --source) printf '%s\n' "${source:-未发现可读传感器}" ;;
    *) if [ -n "$best" ]; then awk -v v="$best" -v s="$source" 'BEGIN{printf "温度：%.1f°C（%s）\n",v/1000,s}'; else echo '温度：未发现可读传感器（可能缺驱动、虚拟机未透传或硬件未暴露；不是 0°C）'; fi ;;
esac
EOF_TEMPERATURE
    cat > /usr/local/sbin/node-net-optimize <<'EOF_NET'
#!/bin/sh
set -eu
umask 077
export LC_ALL=C
state=/etc/node-suite-net
conf=/etc/sysctl.d/99-node-suite-net.conf
say() { printf '%s\n' "$*"; }
status() {
    for key in net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing net.ipv4.tcp_moderate_rcvbuf; do
        sysctl "$key" 2>/dev/null || true
    done
    command -v tc >/dev/null 2>&1 && tc qdisc show 2>/dev/null || true
}
apply_one() {
    key="$1"; wanted="$2"
    old="$(sysctl -n "$key" 2>/dev/null || true)"
    [ -n "$old" ] || return 0
    if ! awk -F= -v k="$key" '$1==k{f=1}END{exit !f}' "$state/original.conf"; then
        printf '%s=%s\n' "$key" "$old" >> "$state/original.conf"
    fi
    if sysctl -w "$key=$wanted" >/dev/null 2>&1; then printf '%s=%s\n' "$key" "$wanted" >> "$conf.new"; else say "跳过：内核不接受 $key=$wanted"; fi
}
case "${1:-status}" in
    status) status; exit 0 ;;
    auto|restore) [ "$(id -u)" = 0 ] || { say '需要 root'; exit 1; } ;;
    *) say '用法：node-net-optimize [auto|status|restore]'; exit 2 ;;
esac
mkdir -p "$state" /etc/sysctl.d
exec 9>"$state/lock"
flock -n 9 || { say '优化工具正在运行'; exit 1; }
if [ "$1" = restore ]; then
    [ -r "$state/original.conf" ] || { say '没有本工具的原值备份'; exit 0; }
    sysctl -p "$state/original.conf" || { say '部分原值恢复失败，保留全部备份和持久化配置供诊断'; exit 1; }
    [ ! -f "$conf" ] || mv "$conf" "$state/last-applied.conf"
    say '已恢复首次优化前的运行参数；不改 WAN MTU、SQM 或现有 qdisc。'; exit 0
fi
touch "$state/original.conf"
: > "$conf.new"
modprobe tcp_bbr >/dev/null 2>&1 || true
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    apply_one net.ipv4.tcp_congestion_control bbr
    # Do not replace any live WAN/CAKE/SQM qdisc. Only change the default for new qdiscs.
    if modprobe sch_fq >/dev/null 2>&1 || [ -d /sys/module/sch_fq ]; then apply_one net.core.default_qdisc fq; fi
else say 'BBR 不可用，保留当前拥塞算法；不刷内核、不强装内核模块。'; fi
mtu="$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)"
if [ "$mtu" = 0 ]; then apply_one net.ipv4.tcp_mtu_probing 1; elif [ -n "$mtu" ]; then apply_one net.ipv4.tcp_mtu_probing "$mtu"; fi
apply_one net.ipv4.tcp_moderate_rcvbuf 1
chmod 600 "$conf.new"; mv "$conf.new" "$conf"
say '已应用内核支持的保守 TCP 优化；主要作用于新建连接，不保证提速。'
status
EOF_NET
    cat > /usr/local/sbin/node-link-test <<'EOF_LINK'
#!/bin/sh
# Read-only diagnostics; does not open a listener, change routing, or run a download speed test.
set -u
host="${1:-}"
case "$host" in ''|-*|*[!A-Za-z0-9.:-]*) echo '用法：node-link-test 对端域名或IP [4|6]'; exit 2 ;; esac
family="${2:-4}"
case "$family" in 4|6) ;; *) exit 2 ;; esac
echo "对端：$host；IPv$family；此报告不含 Token/私钥。"
if command -v mtr >/dev/null 2>&1; then
    timeout -k 2 45 mtr "-$family" -r -w -n -c 10 -- "$host" || true
else
    echo '未安装 mtr，使用 ping；只有终点持续丢包才有诊断意义。'
    timeout -k 2 25 ping "-$family" -c 10 "$host" || true
fi
/usr/local/sbin/node-net-optimize status
echo '请从中国、泰国两端分别执行；路由经常不对称。中间跳 ICMP 限速不等于业务丢包。'
EOF_LINK
    chmod 755 /usr/local/sbin/node-temperature /usr/local/sbin/node-net-optimize /usr/local/sbin/node-link-test
    cat > /usr/local/sbin/node-sqm-setup <<'EOF_SQM'
#!/bin/sh
# Optional, explicit bandwidth shaping on a router you control. Never called by installer main.
set -eu
umask 077
export LC_ALL=C
[ -r /etc/openwrt_release ] || { echo 'SQM 向导只用于 OpenWrt 路由器；VPS 不自动整形'; exit 1; }
[ "$(id -u)" = 0 ] || { echo '需要 root'; exit 1; }
exec 9>/tmp/node-sqm-setup.lock
flock -n 9 || { echo '另一 SQM 向导正在运行'; exit 1; }
# Hardware/flow offload can bypass SQM. Do not silently change firewall/offload remotely.
for item in flow_offloading flow_offloading_hw; do
    if [ "$(uci -q get "firewall.@defaults[0].$item" 2>/dev/null || true)" = 1 ]; then
        echo '检测到流量分载开启；本向导不会自动关闭它。请在可本地救援时先关闭流量分载，再运行此向导。'; exit 1
    fi
done
for section in $(uci -q show sqm 2>/dev/null | sed -n 's/^sqm\.\([^=]*\)=queue$/\1/p'); do
    [ "$section" = home_suite ] && continue
    [ "$(uci -q get "sqm.$section.enabled" 2>/dev/null || true)" != 1 ] || { echo '已有其他 SQM 配置正在启用，不覆盖、不叠加限速'; exit 1; }
done
echo 'SQM 改善满载排队延迟，可能降低峰值速度、增加 CPU 占用；不改善跨国绕路。'
echo '请填写实际瓶颈接口和实测上下行，不按套餐速度猜测；建议先有本地救援通道。'
ip link show
printf 'WAN 设备名称（例如 pppoe-wan，不是逻辑接口别名）：'; read -r dev
case "$dev" in ''|-*|*[!A-Za-z0-9_.:@-]*) echo '设备名称不合法'; exit 2 ;; esac
[ -d "/sys/class/net/$dev" ] || { echo '设备不存在'; exit 1; }
printf '实测下行 Mbit/s（正整数）：'; read -r down
printf '实测上行 Mbit/s（正整数）：'; read -r up
for rate in "$down" "$up"; do
    case "$rate" in ''|0*|*[!0-9]*) echo '速率须为不带前导零的正整数'; exit 2 ;; esac
    [ "${#rate}" -le 5 ] && [ "$rate" -le 10000 ] || { echo '速率超出 1-10000 Mbit/s'; exit 2; }
done
down=$((down*900)); up=$((up*900))
echo "将新建/更新本工具 SQM：$dev，下载 $down kbit/s，上传 $up kbit/s（实测值 90%）。"
printf '确认配置并启动？输入 yes：'; read -r answer; [ "$answer" = yes ] || exit 0
if command -v opkg >/dev/null 2>&1; then
    opkg update && opkg install sqm-scripts tc-full kmod-sched-cake || { echo '匹配当前固件的 SQM 依赖安装失败；未修改 SQM 配置'; exit 1; }
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add sqm-scripts tc-full kmod-sched-cake || { echo '匹配当前固件的 SQM 依赖安装失败；未修改 SQM 配置'; exit 1; }
else echo '没有 opkg/apk'; exit 1; fi
[ -x /etc/init.d/sqm ] || { echo '缺少 SQM 服务'; exit 1; }
backup="$(mktemp -d /etc/node-sqm-backup.XXXXXX)"
existed=0; enabled=0; changed=0
if [ -f /etc/config/sqm ]; then cp -p /etc/config/sqm "$backup/sqm"; existed=1; fi
/etc/init.d/sqm enabled >/dev/null 2>&1 && enabled=1
restore() {
    rc=$?
    set +e
    if [ "$rc" != 0 ] && [ "$changed" = 1 ]; then
        /etc/init.d/sqm stop
        if [ "$existed" = 1 ]; then cp -p "$backup/sqm" /etc/config/sqm; else rm -f /etc/config/sqm; fi
        if [ "$enabled" = 1 ]; then /etc/init.d/sqm enable; else /etc/init.d/sqm disable; fi
        /etc/init.d/sqm start
        echo "SQM 未通过验收，已恢复原配置；备份：$backup"
    fi
    exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
touch /etc/config/sqm
changed=1
uci set sqm.home_suite=queue
uci set sqm.home_suite.enabled=1
uci set "sqm.home_suite.interface=$dev"
uci set "sqm.home_suite.download=$down"
uci set "sqm.home_suite.upload=$up"
uci set sqm.home_suite.qdisc=cake
uci set sqm.home_suite.script=piece_of_cake.qos
uci set sqm.home_suite.linklayer=none
uci commit sqm
/etc/init.d/sqm enable
/etc/init.d/sqm restart
tc qdisc show dev "$dev" | grep -qw cake || { echo 'WAN CAKE 队列未建立'; exit 1; }
echo "SQM 已开启；备份：$backup。再次实测满载延迟和 CPU 后决定是否保留。"
echo '只停用本工具配置：uci set sqm.home_suite.enabled=0 && uci commit sqm && /etc/init.d/sqm restart'
EOF_SQM
    chmod 700 /usr/local/sbin/node-sqm-setup
}

suite_optional_drivers() {
    # Use only firmware-matching repositories, never --force-depends or a replacement kernel.
    local pkg='' module=''
    if [ -r /etc/openwrt_release ]; then
        if grep -q GenuineIntel /proc/cpuinfo; then pkg=kmod-hwmon-coretemp; module=coretemp
        elif grep -q AuthenticAMD /proc/cpuinfo; then pkg=kmod-hwmon-k10temp; module=k10temp; fi
        if [ -n "$module" ] && ! modprobe "$module" >/dev/null 2>&1; then
            if command -v opkg >/dev/null 2>&1; then opkg install "$pkg" || warn "温度驱动 $pkg 不可安装，继续节点安装"
            elif command -v apk >/dev/null 2>&1; then apk add "$pkg" || warn "温度驱动 $pkg 不可安装，继续节点安装"; fi
            modprobe "$module" >/dev/null 2>&1 || true
        fi
        if [ "${ENABLE_BBR:-1}" = 1 ] && ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            if command -v opkg >/dev/null 2>&1; then opkg install kmod-tcp-bbr || warn 'BBR 模块不可安装，继续使用现有算法'
            elif command -v apk >/dev/null 2>&1; then apk add kmod-tcp-bbr || warn 'BBR 模块不可安装，继续使用现有算法'; fi
        fi
    else
        if grep -q GenuineIntel /proc/cpuinfo; then modprobe coretemp >/dev/null 2>&1 || true
        elif grep -q AuthenticAMD /proc/cpuinfo; then modprobe k10temp >/dev/null 2>&1 || true; fi
    fi
    return 0
}
# END SHARED RUNTIME

suite_install_editor() {
    mkdir -p '/usr/local/sbin'
    cat > '/usr/local/sbin/node-config' <<'EOF_NODE_CONFIG'
#!/bin/sh
# Structured local editor. Input is JSON on stdin, never evaluated as shell code.
set -eu
umask 077
export LC_ALL=C
die() { printf '%s\n' "$*" >&2; exit 1; }
say() { :; }
[ "$(id -u)" = 0 ] || die '需要 root'
for c in jq flock timeout openssl socat sha256sum; do command -v "$c" >/dev/null || die "节点配置功能缺少组件：$c；请重新运行 1.1 安装器补齐"; done
exec 6>/tmp/node-config.flock
flock -n 6 || die '已有配置修改正在执行'
[ ! -d /tmp/home-suite-install.lock ] || die '安装器正在运行，请稍后重试'
mkdir -p /run/lock
exec 5>/run/lock/install-vless-reality.lock
flock -n 5 || die 'VPS 安装器正在运行'
TYPE=vps; CONFIG=/usr/local/etc/xray/config.json; SETTINGS=/etc/vless-reality/settings.conf
NODE=/root/vless-node-info.txt; XRAY_BIN=/usr/local/bin/xray; SERVICE=xray.service; TAG=vless-reality
if [ -r /etc/openwrt_release ]; then
    TYPE=router; CONFIG=/etc/home-ss/xray.json; SETTINGS=/etc/home-ss/settings.conf
    NODE=/root/home-ss-node.txt; XRAY_BIN=/usr/libexec/home-node/xray; TAG=home-vless
fi
[ -s "$CONFIG" ] && [ -s "$SETTINGS" ] && [ -s "$NODE" ] || die '该设备还不是本套件 VLESS 节点'
jq -e --arg t "$TAG" '.inbounds|length==1 and .[0].tag==$t and .[0].protocol=="vless" and .[0].streamSettings.security=="reality" and (.[0].settings.clients|length)==1' "$CONFIG" >/dev/null || die '不接管其他入站/多用户配置'
. /usr/local/lib/node-suite/runtime.sh
STAGE="$(mktemp -d /tmp/node-config.XXXXXX)"
SUITE_PROBE_PIDS=''; COMMIT=0; DONE=0; BACKUP=''; FW_CHANGED=0
restart_node() { if [ "$TYPE" = router ]; then /etc/init.d/home-node restart; else systemctl restart xray.service; fi; }
node_ready() {
    local pid ids
    if [ "$TYPE" = router ]; then
        ids="$(ubus call service list '{"name":"home-node"}' | jq -r '.["home-node"].instances[]?.pid // empty')"
        for pid in $ids; do netstat -lntp 2>/dev/null | awk -v p=":$PORT" -v id="$pid/" '$4~p"$" && index($7,id)==1{f=1}END{exit !f}' && return 0; done
    else
        systemctl is-active --quiet xray.service || return 1
        pid="$(systemctl show -p MainPID --value xray.service)"
        ss -Hlntp 2>/dev/null | awk -v p=":$PORT" -v id="pid=$pid," '$4~p"$" && index($0,id)>0{f=1}END{exit !f}' && return 0
    fi
    return 1
}
finish() {
    rc=$?; set +e; suite_probe_cleanup
    if [ "$rc" != 0 ] && [ "$COMMIT" = 0 ]; then echo "配置预检未通过，原配置未改" >&2; fi
    if [ "$COMMIT" = 1 ] && [ "$DONE" = 0 ]; then
        cp -p "$BACKUP/config" "$CONFIG"
        cp -p "$BACKUP/settings" "$SETTINGS"
        cp -p "$BACKUP/node" "$NODE"
        if [ "$FW_CHANGED" = 1 ]; then
            if [ "$TYPE" = router ]; then
                cp -p "$BACKUP/firewall" /etc/config/firewall
                uci -q revert firewall
                /etc/init.d/firewall reload >/dev/null 2>&1
                rm -f /tmp/home-node-firewall.signature
            else
                cp -p "$BACKUP/firewall" /usr/local/sbin/vless-reality-firewall
                bash /usr/local/sbin/vless-reality-firewall >/dev/null 2>&1
                ip6tables -w 5 -D INPUT -p tcp --dport "$PORT" -m comment --comment home-suite-vless -j ACCEPT 2>/dev/null
            fi
        fi
        if restart_node >/dev/null 2>&1; then echo '修改失败，已恢复旧配置并重启服务' >&2;
        else echo '旧配置已恢复，但服务启动失败；请检查设备' >&2; fi
    fi
    rm -rf "$STAGE"
    trap - EXIT
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
head -c 2049 > "$STAGE/request.json"
[ "$(wc -c < "$STAGE/request.json")" -le 2048 ] || die '请求过大'
jq -e 'type=="object" and (.field|type)=="string" and (.value|type)=="string"' "$STAGE/request.json" >/dev/null || die '请求格式错误'
FIELD="$(jq -r .field "$STAGE/request.json")"; VALUE="$(jq -r .value "$STAGE/request.json")"
. "$SETTINGS"
cp "$CONFIG" "$STAGE/config.json"
OLD_PORT="$(jq -r '.inbounds[0].port' "$CONFIG")"; PORT="$OLD_PORT"
REALITY_SNI="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")"
REALITY_DEST="$(jq -r '.inbounds[0].streamSettings.realitySettings | .target // .dest' "$CONFIG")"
XRAY_UUID="$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG")"
REALITY_SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG")"
REALITY_PRIVATE_KEY="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG")"
domain_ok() { [ "${#1}" -le 253 ] && printf '%s' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'; }
case "$FIELD" in
    sni) domain_ok "$VALUE" || die 'SNI 格式错误'; REALITY_SNI="$VALUE"; REALITY_DEST="$VALUE:443";;
    target)
        printf '%s' "$VALUE" | grep -Eq '^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$' || die '目标格式：域名:端口'
        [ "${VALUE##*:}" -le 65535 ] || die '目标端口超限'; REALITY_DEST="$VALUE";;
    port)
        printf '%s' "$VALUE" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$VALUE" -le 65535 ] || die '端口范围 1–65535'
        PORT="$VALUE"
        if [ "$PORT" != "$OLD_PORT" ]; then suite_socket_busy "$PORT" && die '端口已占用'; fi;;
    uuid)
        [ "$VALUE" != random ] || VALUE="$("$XRAY_BIN" uuid)"
        printf '%s' "$VALUE" | grep -Eq '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' || die 'UUID 格式错误'; XRAY_UUID="$VALUE";;
    shortid)
        [ "$VALUE" != random ] || VALUE="$(openssl rand -hex 8)"
        printf '%s' "$VALUE" | grep -Eq '^([a-fA-F0-9]{2}){1,8}$' || die 'Short ID 需为 2–16 位偶数长度十六进制'; REALITY_SHORT_ID="$VALUE";;
    keys)
        [ "$VALUE" = random ] || die '密钥仅支持设备本地生成'
        REALITY_PRIVATE_KEY="$("$XRAY_BIN" x25519 | awk -F':[[:space:]]*' 'tolower($1)~/^private ?key$/{print $2;exit}')";;
    *) die '不支持的配置项';;
esac
printf '%s' "$REALITY_PRIVATE_KEY" | grep -Eq '^[A-Za-z0-9_-]{43}$' || die '密钥生成失败'
REALITY_PUBLIC_KEY="$("$XRAY_BIN" x25519 -i "$REALITY_PRIVATE_KEY" | awk -F':[[:space:]]*' 'tolower($1)~/public ?key/ || tolower($1)=="password"{print $2;exit}')"
printf '%s' "$REALITY_PUBLIC_KEY" | grep -Eq '^[A-Za-z0-9_-]{43}$' || die '公钥生成失败'
jq --argjson p "$PORT" --arg u "$XRAY_UUID" --arg s "$REALITY_SNI" --arg d "$REALITY_DEST" --arg k "$REALITY_PRIVATE_KEY" --arg i "$REALITY_SHORT_ID" \
 '.inbounds[0].port=$p | .inbounds[0].settings.clients[0].id=$u | .inbounds[0].streamSettings.realitySettings |= (.serverNames=[$s] | .target=$d | del(.dest) | .privateKey=$k | .shortIds=[$i])' "$CONFIG" > "$STAGE/config.json"
suite_check_target > "$STAGE/check.log" 2>&1 || die '目标 TLS / SNI 检查失败，原配置未改'
suite_smoke_xray >> "$STAGE/check.log" 2>&1 || die 'REALITY TCP/UDP 回环验证失败，原配置未改'
# Functions above call die on error; errors remain generic outside the private temp log.
BACKUP="$(mktemp -d "$(dirname "$SETTINGS")/node-change.XXXXXX")"
cp -p "$CONFIG" "$BACKUP/config"; cp -p "$SETTINGS" "$BACKUP/settings"; cp -p "$NODE" "$BACKUP/node"
cp -p "$SETTINGS" "$STAGE/settings"
awk '!/^(SS_PORT|XRAY_PORT|XRAY_UUID|REALITY_SNI|REALITY_DEST|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID)=/' "$SETTINGS" > "$STAGE/settings"
{
    if [ "$TYPE" = router ]; then printf "SS_PORT='%s'\n" "$PORT"; else printf "XRAY_PORT='%s'\n" "$PORT"; fi
    printf "XRAY_UUID='%s'\nREALITY_SNI='%s'\nREALITY_DEST='%s'\nREALITY_PRIVATE_KEY='%s'\nREALITY_PUBLIC_KEY='%s'\nREALITY_SHORT_ID='%s'\n" "$XRAY_UUID" "$REALITY_SNI" "$REALITY_DEST" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
} >> "$STAGE/settings"
sh -n "$STAGE/settings"
if [ "$TYPE" = router ]; then HOST="$DOMAIN.duckdns.org"; LABEL=home-vless;
else
    HOST="${PUBLIC4:-${PUBLIC6:-}}"; [ -n "$HOST" ] || die '缺少节点地址'
    LABEL="$(printf '%s' "${NODE_NAME_B64:-}" | base64 -d)"
fi
case "$HOST" in *:*) HOST="[$HOST]";; esac
LABEL="$(printf '%s' "$LABEL" | tr '\r\n,' '   ')"
URI_TAG="$(jq -rn --arg s "$LABEL" '$s|@uri')"
printf 'vless=%s:%s, method=none, password=%s, obfs=over-tls, obfs-host=%s, reality-base64-pubkey=%s, reality-hex-shortid=%s, vless-flow=xtls-rprx-vision, udp-relay=true, fast-open=false, tag=%s\n\nvless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision#%s\n' \
 "$HOST" "$PORT" "$XRAY_UUID" "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$LABEL" "$XRAY_UUID" "$HOST" "$PORT" "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$URI_TAG" > "$STAGE/node"
COMMIT=1
if [ "$PORT" != "$OLD_PORT" ]; then
    if [ "$TYPE" = router ]; then
        cp -p /etc/config/firewall "$BACKUP/firewall"; FW_CHANGED=1
        . /usr/libexec/home-node/network.sh
        hn_firewall "$PORT" || die '新端口防火墙校验失败'
    else
        [ "$(grep -Ec "^PORT='[0-9]+'$" /usr/local/sbin/vless-reality-firewall)" = 1 ] || die '防火墙脚本格式不兼容，原配置未改'
        cp -p /usr/local/sbin/vless-reality-firewall "$BACKUP/firewall"; FW_CHANGED=1
        sed "s/^PORT='[0-9]*'/PORT='$PORT'/" "$BACKUP/firewall" > /usr/local/sbin/vless-reality-firewall
        bash -n /usr/local/sbin/vless-reality-firewall
        bash /usr/local/sbin/vless-reality-firewall || die '新端口放行失败'
    fi
fi
# Keep the service account ownership/mode while replacing the config atomically.
cp -p "$CONFIG" "$CONFIG.new"
cat "$STAGE/config.json" > "$CONFIG.new"
mv "$CONFIG.new" "$CONFIG"
restart_node >/dev/null 2>&1 || die '新服务启动失败'
n=0
until node_ready; do n=$((n+1)); [ "$n" -lt 15 ] || die '新服务未监听'; sleep 1; done
sleep 2; node_ready || die '新服务退出'
cp "$STAGE/settings" "$SETTINGS.new"; chmod 600 "$SETTINGS.new"; mv "$SETTINGS.new" "$SETTINGS"
cp "$STAGE/node" "$NODE.new"; chmod 600 "$NODE.new"; mv "$NODE.new" "$NODE"
DONE=1
if [ "$TYPE" = vps ] && [ "$PORT" != "$OLD_PORT" ]; then
    ip6tables -w 5 -D INPUT -p tcp --dport "$OLD_PORT" -m comment --comment home-suite-vless -j ACCEPT 2>/dev/null || true
fi
printf '配置已更新：%s\n备份：%s\n' "$FIELD" "$BACKUP"
if [ "$TYPE" = router ]; then /usr/bin/home-monitor --full --verbose || echo '节点已更新；上报待重试';
else /usr/local/sbin/vless-reality-monitor --full --verbose || echo '节点已更新；上报待重试'; fi
EOF_NODE_CONFIG
    chmod 700 '/usr/local/sbin/node-config'
    mkdir -p /usr/local/lib/node-suite
    cat > /usr/local/lib/node-suite/runtime.sh <<'EOF_CONFIG_RUNTIME'
suite_socket_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -Hlnut 2>/dev/null | awk -v p=":$1" '$5~p"$"{f=1}END{exit !f}'
    else
        netstat -lnut 2>/dev/null | awk -v p=":$1" '$4~p"$"{f=1}END{exit !f}'
    fi
}

suite_probe_cleanup() {
    local p
    for p in ${SUITE_PROBE_PIDS:-}; do kill "$p" 2>/dev/null || true; done
    for p in ${SUITE_PROBE_PIDS:-}; do wait "$p" 2>/dev/null || true; done
    SUITE_PROBE_PIDS=''
}

suite_smoke_xray() {
    # Real authenticated REALITY/Vision round trips; not just a LISTEN check.
    local p=49100 ready=0 n=0 tcp='' udp='' marker='home-suite-uvr-test'
    while suite_socket_busy "$p" || suite_socket_busy "$((p+1))" || suite_socket_busy "$((p+2))"; do
        p=$((p+3)); [ "$p" -lt 50000 ] || die '无可用回环测试端口'
    done
    jq --argjson p "$p" '.inbounds[0].listen="127.0.0.1" | .inbounds[0].port=$p' "$STAGE/config.json" > "$STAGE/probe.json"
    jq -n --argjson port "$((p+1))" --argjson echo "$((p+2))" --argjson server "$p" \
        --arg uuid "$XRAY_UUID" --arg sni "$REALITY_SNI" --arg key "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" \
        '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$port,protocol:"dokodemo-door",settings:{address:"127.0.0.1",port:$echo,network:"tcp,udp"}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$server,users:[{id:$uuid,encryption:"none",flow:"xtls-rprx-vision"}]}]},streamSettings:{network:"raw",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$key,shortId:$sid}}}]}' > "$STAGE/client.json"
    # Xray 26.4+ 的 freedom 默认阻止私有地址；这只给临时 127.0.0.1 回环回显放行，
    # 正式节点配置仍保持默认私网保护。
    jq --argjson ep "$((p+2))" '.outbounds |= map(if .protocol == "freedom" then .settings.finalRules = ([{action:"allow",network:"tcp,udp",ip:["127.0.0.1/32"],port:($ep|tostring)}] + (.settings.finalRules // [])) else . end)' "$STAGE/probe.json" > "$STAGE/probe.allow.json" || die '无法生成回环测试例外'
    mv "$STAGE/probe.allow.json" "$STAGE/probe.json"
    "$XRAY_BIN" run -test -config "$STAGE/probe.json" > "$STAGE/probe.log" 2>&1 || die "服务端配置检查失败，日志：$STAGE/probe.log"
    "$XRAY_BIN" run -test -config "$STAGE/client.json" >> "$STAGE/probe.log" 2>&1 || die "客户端配置检查失败，日志：$STAGE/probe.log"
    "$XRAY_BIN" run -config "$STAGE/probe.json" >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$!"
    "$XRAY_BIN" run -config "$STAGE/client.json" >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    socat -t 2 -T 60 "TCP4-LISTEN:$((p+2)),bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    socat -t 2 -T 60 "UDP4-RECVFROM:$((p+2)),bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >> "$STAGE/probe.log" 2>&1 &
    SUITE_PROBE_PIDS="$SUITE_PROBE_PIDS $!"
    while [ "$n" -lt 10 ]; do
        if suite_socket_busy "$p" && suite_socket_busy "$((p+1))" && suite_socket_busy "$((p+2))"; then ready=1; break; fi
        n=$((n+1)); sleep 1
    done
    if [ "$ready" = 1 ]; then
        # socat's default EOF grace is only 0.5s; REALITY target RTT may exceed it.
        tcp="$(printf '%s\n' "$marker" | timeout -k 2 55 socat -t 1 -T 45 STDIO,ignoreeof "TCP4:127.0.0.1:$((p+1)),readbytes=$((${#marker}+1))" 2>> "$STAGE/probe.log" || true)"
        udp="$(printf '%s\n' "$marker" | timeout -k 2 55 socat -t 1 -T 45 STDIO,ignoreeof "UDP4:127.0.0.1:$((p+1)),readbytes=$((${#marker}+1))" 2>> "$STAGE/probe.log" || true)"
    fi
    suite_probe_cleanup
    if [ "$tcp" != "$marker" ] || [ "$udp" != "$marker" ]; then
        tail -n 40 "$STAGE/probe.log" >&2
        die "REALITY/Vision TCP 或 UDP 隧道回环验证失败；旧节点保持原状。日志：$STAGE/probe.log"
    fi
    say '真实 REALITY 认证、Vision 配置、TCP/UDP 隧道双向数据回环通过（不等于公网可达或圈 X 实测）'
}

suite_check_target() {
    local try=0 target_host="${REALITY_DEST%:*}" result=1
    while [ "$try" -lt 2 ]; do
        timeout -k 2 15 openssl s_client -connect "$REALITY_DEST" -servername "$REALITY_SNI" -tls1_3 -alpn h2 -verify_hostname "$REALITY_SNI" -verify_return_error </dev/null > "$STAGE/target.log" 2>&1 || true
        if grep -q 'Verify return code: 0 (ok)' "$STAGE/target.log" && grep -q 'ALPN protocol: h2' "$STAGE/target.log"; then result=0; break; fi
        try=$((try+1))
    done
    [ "$result" = 0 ] || { tail -n 12 "$STAGE/target.log" >&2; die 'REALITY 目标必须可直连、证书匹配 SNI、支持 TLS 1.3 与 h2；请重跑更换目标，旧节点未改'; }
    say "REALITY 目标 $REALITY_DEST：TLS 1.3 / h2 / 证书校验通过"
}
EOF_CONFIG_RUNTIME
    chmod 600 /usr/local/lib/node-suite/runtime.sh
}

main "$@"

# Only reached after every installation step succeeds; keep failed/preflight scripts.
if [ "$PREFLIGHT_ONLY" = 0 ] && [ -f "$0" ]; then
    rm -f -- "$0" && printf '安装完成，已清除本次安装脚本。\n' || printf '安装完成，但安装脚本清理失败，请手动删除。\n'
fi
