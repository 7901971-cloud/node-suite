#!/usr/bin/env bash
set -Eeuo pipefail

# Node Suite VPS installer bootstrap 1.1.3
# The full 1.1 installer is pinned by tag and patched deterministically before execution.
# This keeps the released base immutable while fixing:
#   1) Quantumult X node name == Telegram device name during installation
#   2) the accidental "vless:// 通用链接：" pseudo-node shown by Telegram
#   3) raw.githubusercontent.com IPv6/path anomalies by preferring IPv4 and falling back to GitHub Contents API
#   4) install-time REALITY SNI/target auto-selection from 12 built-in domains by strict TLS compatibility + lowest handshake latency

export LC_ALL=C
umask 077

readonly SCRIPT_VERSION='1.1.3'
readonly BASE_REF='v1.1'
readonly REPO='sajik1/node-suite'
readonly BASE_PATH='vps/install-vless-reality-vps.sh'

case "${1:-}" in
  --version)
    echo "$SCRIPT_VERSION"
    exit 0
    ;;
  --preflight|'') ;;
  *)
    echo 'Usage: bash install-vless-reality-vps.sh [--preflight|--version]' >&2
    exit 2
    ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "错误：缺少命令：$1" >&2
    exit 1
  }
}

need bash
need curl
need awk
need grep
need mktemp

TMP_DIR="$(mktemp -d /tmp/node-suite-vps-bootstrap.XXXXXX)"
BASE_FILE="$TMP_DIR/base.sh"
PATCHED_FILE="$TMP_DIR/install.sh"

cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RAW_URL="https://raw.githubusercontent.com/${REPO}/${BASE_REF}/${BASE_PATH}"
API_URL="https://api.github.com/repos/${REPO}/contents/${BASE_PATH}?ref=${BASE_REF}"

echo '========== 获取固定版本 VPS 安装器 =========='
if curl -4 -fL --connect-timeout 15 --max-time 120 --retry 3 \
  "$RAW_URL" -o "$BASE_FILE"; then
  echo 'GitHub Raw（IPv4）下载成功。'
else
  echo 'GitHub Raw 下载失败，自动切换 GitHub Contents API。' >&2
  curl -fL --connect-timeout 15 --max-time 120 --retry 3 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API_URL" -o "$BASE_FILE"
fi

[[ -s "$BASE_FILE" ]] || {
  echo '错误：固定版本安装器下载为空。' >&2
  exit 1
}

# Refuse to patch an unexpected base. The tag is immutable in normal use, and these
# anchors make a future accidental tag/content mismatch fail closed instead of silently
# producing a malformed root installer.
grep -Fq 'readonly SCRIPT_VERSION="1.1"' "$BASE_FILE" || {
  echo '错误：固定版本脚本版本锚点不匹配，停止。' >&2
  exit 1
}
grep -Fq 'Telegram 中显示的设备名称' "$BASE_FILE" || {
  echo '错误：设备名称补丁锚点不存在，停止。' >&2
  exit 1
}
grep -Fq 'vless:// 通用链接：' "$BASE_FILE" || {
  echo '错误：节点展示补丁锚点不存在，停止。' >&2
  exit 1
}
grep -Fq "REALITY_SNI=\"\$(read_default 'REALITY SNI'" "$BASE_FILE" || {
  echo '错误：REALITY SNI 自动选择补丁锚点不存在，停止。' >&2
  exit 1
}

awk '
function emit_auto_selector() {
  print "auto_select_reality_target() {"
  print "  local candidates host log start_ms end_ms ms best_host=\"\" best_ms=\"\" idx=0"
  print "  candidates=\"www.apple.com www.microsoft.com www.mi.com www.samsung.com www.intel.com www.douyin.com www.qq.com www.10086.cn www.10010.com www.189.cn www.bing.com www.tiktok.com\""
  print "  say"
  print "  say \"========== 3A. 自动选择 REALITY SNI / 目标 ==========\""
  print "  say \"将测试 12 个内置域名；仅接受 TLS 1.3、ALPN h2、证书匹配全部通过的目标，并选择当前机器 TLS 握手延迟最低者。\""
  print "  for host in $candidates; do"
  print "    idx=$((idx + 1))"
  print "    log=\"$STAGE/reality-auto-$idx.log\""
  print "    start_ms=\"$(awk \047{printf \"%d\", $1 * 1000}\047 /proc/uptime 2>/dev/null || printf 0)\""
  print "    timeout -k 1 8 openssl s_client -connect \"${host}:443\" -servername \"$host\" -tls1_3 -alpn h2 -verify_hostname \"$host\" -verify_return_error </dev/null >\"$log\" 2>&1 || true"
  print "    end_ms=\"$(awk \047{printf \"%d\", $1 * 1000}\047 /proc/uptime 2>/dev/null || printf 0)\""
  print "    if grep -q \047Verify return code: 0 (ok)\047 \"$log\" && grep -q \047ALPN protocol: h2\047 \"$log\"; then"
  print "      case \"$start_ms:$end_ms\" in *[!0-9:]*|:*) ms=999999 ;; *) if (( end_ms >= start_ms )); then ms=$((end_ms - start_ms)); else ms=999999; fi ;; esac"
  print "      printf \047  ✓ %-22s %6s ms\\n\047 \"${host}:443\" \"$ms\""
  print "      if [[ -z \"$best_host\" || \"$ms\" -lt \"$best_ms\" ]]; then best_host=\"$host\"; best_ms=\"$ms\"; fi"
  print "    else"
  print "      printf \047  - %-22s 跳过（TLS 1.3 / h2 / 证书 / 连通性未全部通过）\\n\047 \"${host}:443\""
  print "    fi"
  print "  done"
  print "  [[ -n \"$best_host\" ]] || die \04712 个内置 REALITY 目标均未通过严格检查；未写业务配置\047"
  print "  REALITY_SNI=\"$best_host\""
  print "  REALITY_DEST=\"${best_host}:443\""
  print "  say \"自动选择：SNI=${REALITY_SNI}；目标=${REALITY_DEST}；TLS 握手约 ${best_ms} ms\""
  print "}"
  print ""
}
{
  line=$0
  if (line == "readonly SCRIPT_VERSION=\"1.1\"") {
    line="readonly SCRIPT_VERSION=\"1.1.3\""
  }

  # Installation asks for the Quantumult X name once. Telegram uses that same value.
  if (index(line, "Telegram 中显示的设备名称") && index(line, "DEVICE_NAME=")) {
    print "    DEVICE_NAME=\"$NODE_NAME\""
    next
  }

  # This heading used to begin with vless:// and was therefore parsed as a third node.
  if (line == "vless:// 通用链接：") {
    line="标准 VLESS 链接："
  }

  # Add the selector before old values are loaded; it is called later from read_settings.
  if (line == "load_old_values() {") {
    emit_auto_selector()
  }

  # Replace the old manual SNI + target prompts. Target remains synchronized to SNI:443.
  if (index(line, "REALITY_SNI=\"$(read_default \047REALITY SNI\047") > 0) {
    print "  auto_select_reality_target"
    skip_sni=5
    next
  }
  if (skip_sni > 0) {
    skip_sni--
    next
  }

  print line
}
' "$BASE_FILE" > "$PATCHED_FILE"

chmod 700 "$PATCHED_FILE"

# Verify all intended changes before executing anything as root.
grep -Fq 'readonly SCRIPT_VERSION="1.1.3"' "$PATCHED_FILE" || {
  echo '错误：版本补丁未生效。' >&2
  exit 1
}
if grep -Fq 'Telegram 中显示的设备名称' "$PATCHED_FILE"; then
  echo '错误：Telegram 设备名称重复输入未移除。' >&2
  exit 1
fi
if grep -Fq 'vless:// 通用链接：' "$PATCHED_FILE"; then
  echo '错误：无用节点标题未移除。' >&2
  exit 1
fi
grep -Fq 'DEVICE_NAME="$NODE_NAME"' "$PATCHED_FILE" || {
  echo '错误：Telegram/Quantumult X 同名补丁未生效。' >&2
  exit 1
}
grep -Fq 'auto_select_reality_target() {' "$PATCHED_FILE" || {
  echo '错误：REALITY 自动选择函数未注入。' >&2
  exit 1
}
grep -Fq 'www.10086.cn www.10010.com www.189.cn' "$PATCHED_FILE" || {
  echo '错误：三大运营商候选域名未注入。' >&2
  exit 1
}
grep -Fq 'www.douyin.com' "$PATCHED_FILE" || {
  echo '错误：抖音候选域名未注入。' >&2
  exit 1
}
grep -Fq 'www.bing.com' "$PATCHED_FILE" || {
  echo '错误：Bing 候选域名未注入。' >&2
  exit 1
}
grep -Fq 'www.tiktok.com' "$PATCHED_FILE" || {
  echo '错误：TikTok 候选域名未注入。' >&2
  exit 1
}
if grep -Fq 'www.baidu.com' "$PATCHED_FILE"; then
  echo '错误：旧百度候选域名仍存在。' >&2
  exit 1
fi
[[ "$(grep -Fc '  auto_select_reality_target' "$PATCHED_FILE")" -eq 1 ]] || {
  echo '错误：REALITY 自动选择调用数量异常。' >&2
  exit 1
}
if grep -Fq "read_default 'REALITY SNI'" "$PATCHED_FILE"; then
  echo '错误：旧 REALITY SNI 手工输入仍存在。' >&2
  exit 1
fi

bash -n "$PATCHED_FILE" || {
  echo '错误：修补后的安装器语法检查失败。' >&2
  exit 1
}

echo '补丁校验通过，开始运行 VPS 安装器 1.1.3。'
bash "$PATCHED_FILE" "$@"
