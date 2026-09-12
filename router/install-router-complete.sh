#!/bin/sh
set -eu
umask 077
export LC_ALL=C

# Node Suite router installer bootstrap 1.2
# The full 1.1 router installer is pinned to an immutable commit and patched
# deterministically before execution. The packaged suite carries the base file
# locally; standalone use falls back to GitHub only when that sibling is absent.
# 1.2: install-time REALITY SNI/target auto-selection from 10 built-in domains
#      by strict TLS 1.3 + h2 + certificate checks and lowest handshake latency.

SCRIPT_VERSION='1.2'
BASE_COMMIT='766e13d9f7a0e17c3616538882b707a5468633f4'
BASE_SHA256='12dae0a29d5e21be2c66162afa2f4c199dcea3d4ef53acd8fde00d0438f21789'
REPO='sajik1/node-suite'
BASE_PATH='router/install-router-complete.sh'
LOCAL_BASE_NAME='install-router-complete-base-v1.1.sh'

case "${1:-}" in
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    --preflight|'') ;;
    *) echo '用法：sh install-router-complete.sh [--preflight|--version]' >&2; exit 2 ;;
esac

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "错误：缺少命令：$1" >&2
        exit 1
    }
}
need awk
need grep
need mktemp

base_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
        return 0
    fi
    if [ -x /bin/busybox ] && /bin/busybox sha256sum "$1" >/dev/null 2>&1; then
        /bin/busybox sha256sum "$1" | awk '{print $1}'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
        return 0
    fi
    echo '错误：缺少可用的 SHA256 校验工具；为避免执行未校验的 root 安装器而停止。' >&2
    return 1
}

TMP_DIR="$(mktemp -d /tmp/node-suite-router-bootstrap.XXXXXX)"
BASE_FILE="$TMP_DIR/base.sh"
PATCHED_FILE="$TMP_DIR/install.sh"

cleanup() {
    rc=$?
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SELF_DIR="$(dirname "$0")"
LOCAL_BASE="$SELF_DIR/$LOCAL_BASE_NAME"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BASE_COMMIT}/${BASE_PATH}"
API_URL="https://api.github.com/repos/${REPO}/contents/${BASE_PATH}?ref=${BASE_COMMIT}"

fetch_base() {
    if [ -s "$LOCAL_BASE" ]; then
        cp "$LOCAL_BASE" "$BASE_FILE"
        echo '使用安装包内固定版本路由器基础脚本。'
        return 0
    fi

    echo '安装包内未找到基础脚本，尝试从 GitHub 固定提交获取。'
    if command -v curl >/dev/null 2>&1; then
        if curl -4 -fL --connect-timeout 15 --max-time 120 --retry 3 "$RAW_URL" -o "$BASE_FILE"; then
            return 0
        fi
        echo 'GitHub Raw 下载失败，自动切换 GitHub Contents API。' >&2
        curl -fL --connect-timeout 15 --max-time 120 --retry 3 \
            -H 'Accept: application/vnd.github.raw+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$API_URL" -o "$BASE_FILE" && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -T 120 -O "$BASE_FILE" "$RAW_URL" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -T 120 -O "$BASE_FILE" "$RAW_URL" && return 0
    fi
    echo '错误：无法获取固定版本基础脚本；请使用完整安装包（含 install-router-complete-base-v1.1.sh）或确保 curl/uclient-fetch/wget 可用。' >&2
    return 1
}

echo '========== 获取固定版本路由器安装器 =========='
fetch_base
[ -s "$BASE_FILE" ] || { echo '错误：固定版本基础脚本为空。' >&2; exit 1; }
ACTUAL_SHA="$(base_sha256 "$BASE_FILE")"
[ "$ACTUAL_SHA" = "$BASE_SHA256" ] || {
    echo "错误：固定版本基础脚本 SHA256 不匹配：$ACTUAL_SHA" >&2
    exit 1
}

grep -Fq "SCRIPT_VERSION='1.1'" "$BASE_FILE" || {
    echo '错误：固定版本脚本版本锚点不匹配，停止。' >&2
    exit 1
}
grep -Fq 'prepare_router_reality() {' "$BASE_FILE" || {
    echo '错误：REALITY 配置补丁锚点不存在，停止。' >&2
    exit 1
}
grep -Fq "printf 'REALITY SNI [" "$BASE_FILE" || {
    echo '错误：旧 REALITY SNI 输入锚点不存在，停止。' >&2
    exit 1
}
grep -Fq "printf '应用保守 TCP 优化" "$BASE_FILE" || {
    echo '错误：REALITY 配置结束锚点不存在，停止。' >&2
    exit 1
}

awk '
function emit_selector_body() {
    print "    local candidates host log start_ms end_ms ms best_host=\047\047 best_ms=\047\047 idx=0"
    print "    candidates=\047www.apple.com www.microsoft.com www.mi.com www.samsung.com www.intel.com www.baidu.com www.qq.com www.10086.cn www.10010.com www.189.cn\047"
    print "    say"
    print "    say \047========== 6A. 自动选择 REALITY SNI / 目标 ==========\047"
    print "    say \047将测试 10 个内置域名；仅接受 TLS 1.3、ALPN h2、证书匹配全部通过的目标，并选择当前路由器 TLS 握手延迟最低者。\047"
    print "    for host in $candidates; do"
    print "        idx=$((idx + 1))"
    print "        log=\"$STAGE/reality-auto-$idx.log\""
    print "        start_ms=\"$(awk \047{printf \"%d\", $1 * 1000}\047 /proc/uptime 2>/dev/null || printf 0)\""
    print "        timeout -k 1 8 openssl s_client -connect \"$host:443\" -servername \"$host\" -tls1_3 -alpn h2 -verify_hostname \"$host\" -verify_return_error </dev/null > \"$log\" 2>&1 || true"
    print "        end_ms=\"$(awk \047{printf \"%d\", $1 * 1000}\047 /proc/uptime 2>/dev/null || printf 0)\""
    print "        if grep -q \047Verify return code: 0 (ok)\047 \"$log\" && grep -q \047ALPN protocol: h2\047 \"$log\"; then"
    print "            case \"$start_ms:$end_ms\" in"
    print "                *[!0-9:]*|:*) ms=999999 ;;"
    print "                *) if [ \"$end_ms\" -ge \"$start_ms\" ]; then ms=$((end_ms - start_ms)); else ms=999999; fi ;;"
    print "            esac"
    print "            printf \047  ✓ %-22s %6s ms\\n\047 \"$host:443\" \"$ms\""
    print "            if [ -z \"$best_host\" ] || [ \"$ms\" -lt \"$best_ms\" ]; then"
    print "                best_host=\"$host\""
    print "                best_ms=\"$ms\""
    print "            fi"
    print "        else"
    print "            printf \047  - %-22s 跳过（TLS 1.3 / h2 / 证书 / 连通性未全部通过）\\n\047 \"$host:443\""
    print "        fi"
    print "    done"
    print "    [ -n \"$best_host\" ] || die \04710 个内置 REALITY 目标均未通过严格检查；尚未写业务配置\047"
    print "    REALITY_SNI=\"$best_host\""
    print "    REALITY_DEST=\"$best_host:443\""
    print "    say \"自动选择：SNI=$REALITY_SNI；目标=$REALITY_DEST；TLS 握手约 ${best_ms} ms\""
}
{
    line=$0
    if (line == "SCRIPT_VERSION=\0471.1\047") {
        line="SCRIPT_VERSION=\0471.2\047"
    }
    if (line == "prepare_router_reality() {") {
        print line
        emit_selector_body()
        in_old_reality=1
        next
    }
    if (in_old_reality) {
        if (index(line, "    printf \047应用保守 TCP 优化") == 1) {
            in_old_reality=0
            print line
        }
        next
    }
    print line
}
' "$BASE_FILE" > "$PATCHED_FILE"

chmod 700 "$PATCHED_FILE"

grep -Fq "SCRIPT_VERSION='1.2'" "$PATCHED_FILE" || {
    echo '错误：版本补丁未生效。' >&2
    exit 1
}
grep -Fq 'www.10086.cn www.10010.com www.189.cn' "$PATCHED_FILE" || {
    echo '错误：三大运营商候选域名未注入。' >&2
    exit 1
}
grep -Fq '自动选择：SNI=$REALITY_SNI；目标=$REALITY_DEST' "$PATCHED_FILE" || {
    echo '错误：REALITY 自动选择逻辑未注入。' >&2
    exit 1
}
if grep -Fq "printf 'REALITY SNI [" "$PATCHED_FILE"; then
    echo '错误：旧 REALITY SNI 手工输入仍存在。' >&2
    exit 1
fi
if grep -Fq "printf 'REALITY 目标 [" "$PATCHED_FILE"; then
    echo '错误：旧 REALITY 目标手工输入仍存在。' >&2
    exit 1
fi
sh -n "$PATCHED_FILE" || {
    echo '错误：修补后的路由器安装器语法检查失败。' >&2
    exit 1
}

echo '补丁校验通过，开始运行路由器安装器 1.2。'
sh "$PATCHED_FILE" "$@"
