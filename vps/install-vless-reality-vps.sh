#!/usr/bin/env bash
set -Eeuo pipefail

# Node Suite VPS installer bootstrap 1.1.2
# The full 1.1 installer is pinned by tag and patched deterministically before execution.
# This keeps the released base immutable while fixing:
#   1) Quantumult X node name == Telegram device name during installation
#   2) the accidental "vless:// 通用链接：" pseudo-node shown by Telegram
#   3) raw.githubusercontent.com IPv6/path anomalies by preferring IPv4 and falling back to GitHub Contents API

export LC_ALL=C
umask 077

readonly SCRIPT_VERSION='1.1.2'
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

awk '
{
  line=$0
  if (line == "readonly SCRIPT_VERSION=\"1.1\"") {
    line="readonly SCRIPT_VERSION=\"1.1.2\""
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

  print line
}
' "$BASE_FILE" > "$PATCHED_FILE"

chmod 700 "$PATCHED_FILE"

# Verify all intended changes before executing anything as root.
grep -Fq 'readonly SCRIPT_VERSION="1.1.2"' "$PATCHED_FILE" || {
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

bash -n "$PATCHED_FILE" || {
  echo '错误：修补后的安装器语法检查失败。' >&2
  exit 1
}

echo '补丁校验通过，开始运行 VPS 安装器 1.1.2。'
bash "$PATCHED_FILE" "$@"
