#!/bin/sh
set -eu
umask 077
export LC_ALL=C
SCRIPT_VERSION='1.1'
ENABLE_BBR=1
SUITE_PROBE_PIDS=''
PREFLIGHT_ONLY=0
case "${1:-}" in --preflight) PREFLIGHT_ONLY=1 ;; --version) echo "$SCRIPT_VERSION"; exit 0 ;; '') ;; *) echo '用法：sh install-router-complete.sh [--preflight|--version]' >&2; exit 2 ;; esac
STAGE=''
SMOKE_PID=''
TX_DIR=''
TX_ACTIVE=0
FW_CHANGED=0
LOCK_HELD=0
REMOTE_READY=0

# OpenWrt 家宽 VLESS + REALITY + Vision + DuckDNS + Cloudflare/Telegram 路由节点中心
# 1.1: MIPS 软浮点、REALITY 回环修复、双栈 DDNS 切换与 Cloudflare Bot 权限中心
# 目标：全新 OpenWrt 一次安装、低资源、无持久日志、可重复运行、多路由器
# 远程运维：Telegram -> Cloudflare -> 路由器主动拉取命令；支持任意 root Shell
# 安全边界：不在路由器开放额外管理端口；仅已配对设备 Token + Bot 管理员可下发高权限命令

MAX_PORT_TRIES="500"
STATE_DIR="/etc/home-ss"
CONF_FILE="$STATE_DIR/settings.conf"
MODE_FILE="$STATE_DIR/ddns-mode"
MONITOR_CONF="$STATE_DIR/monitor.conf"
NODE_FILE="/root/home-ss-node.txt"

say() { LAST_MESSAGE="$*"; printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
warn() { say "警告：$*" >&2; }

b64_encode() { base64 | tr -d '\r\n'; }
b64_decode() { base64 -d 2>/dev/null; }
random_node_port() {
    N="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')"
    case "$N" in ''|*[!0-9]*) N="$(date +%s | tail -c 6)" ;; esac
    printf '%s' "$((20000 + N % 40000))"
}

cleanup() {
    RC=$?
    set +e
    stty echo 2>/dev/null || true
    suite_probe_cleanup
    [ "$RC" = 0 ] || warn "安装停止，退出码=$RC；最后阶段：${LAST_MESSAGE:-预检}。旧 SS、SSH 不被接管。"
    [ -z "$SMOKE_PID" ] || { kill "$SMOKE_PID" 2>/dev/null; wait "$SMOKE_PID" 2>/dev/null; }
    if [ "$RC" -ne 0 ] && [ "$TX_ACTIVE" = 1 ]; then
        warn "本地安装未通过验收，恢复备份：$TX_DIR"
        /etc/init.d/home-command-agent stop >/dev/null 2>&1 || true
        /etc/init.d/home-node stop >/dev/null 2>&1 || true
        while IFS= read -r F; do
            if [ -e "$TX_DIR/files$F" ]; then
                cp -p "$TX_DIR/files$F" "$F"
            else
                rm -f "$F"
            fi
        done < "$TX_DIR/manifest"
        while read -r S ENABLED RUNNING; do
            [ -x "/etc/init.d/$S" ] || continue
            if [ "$ENABLED" = 1 ]; then /etc/init.d/"$S" enable; else /etc/init.d/"$S" disable; fi
            if [ "$RUNNING" = 1 ]; then /etc/init.d/"$S" restart; else /etc/init.d/"$S" stop >/dev/null 2>&1; fi
        done < "$TX_DIR/services"
        if [ "$FW_CHANGED" = 1 ]; then /etc/init.d/firewall reload >/dev/null 2>&1 || warn '恢复后的防火墙 reload 返回非零，请查看 /tmp 中的安装日志'; fi
    fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        # Only this mktemp-created directory is removed.
        if [ "$RC" = 0 ]; then rm -rf "$STAGE"; else warn "诊断目录保留：$STAGE（含节点私钥，请勿公开上传）"; fi
    fi
    if [ "$LOCK_HELD" = 1 ]; then rm -f /tmp/home-suite-install.lock/pid; rmdir /tmp/home-suite-install.lock 2>/dev/null || true; fi

    return "$RC"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

need_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 运行本脚本"
    command -v uci >/dev/null 2>&1 || die "没有找到 uci，本脚本只适用于 OpenWrt"
    [ -r /lib/functions/network.sh ] || die "缺少 /lib/functions/network.sh"
}

ensure_xray_init() {
    cat > /etc/init.d/home-node <<'EOF_INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10
start_service() {
    local binary=/usr/libexec/home-node/xray config=/etc/home-ss/xray.json
    [ -x "$binary" ] && [ -s "$config" ] || return 1
    "$binary" run -test -config "$config" >/dev/null 2>&1 || return 1
    procd_open_instance
    procd_set_param command "$binary" run -config "$config"
    procd_set_param user root
    procd_set_param file "$config"
    procd_set_param stdout 0
    procd_set_param stderr 1
    procd_set_param limits core="0 0" nofile="65535 65535"
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF_INIT
    chmod 755 /etc/init.d/home-node
}

# Kwrt 有时会保留一个已不存在的 file:// small_flash 源。opkg 会因此把
# "update" 标为失败，即使官方源全部正常。只禁用指向不存在本地文件的行，
# 不改任何 HTTPS 源、不替换发行版地址，并保留可恢复备份。
opkg_prepare_sources() {
    local src line kind name url rest path tmp changed backup='' candidate idx
    for src in /etc/opkg.conf /etc/opkg/*.conf; do
        [ -f "$src" ] || continue
        tmp="$(mktemp /tmp/home-source.XXXXXX)"; changed=0
        while IFS= read -r line || [ -n "$line" ]; do
            # read is parsing, never shell-evaluating source content.
            read -r kind name url rest <<EOF_SOURCE_LINE
$line
EOF_SOURCE_LINE
            case "$kind:$url" in
                src:file://*|src/gz:file://*)
                    path="${url#file://}"
                    case "$path" in localhost/*) path="/${path#localhost/}";; esac
                    case "$path" in /*) ;; *) path="/$path";; esac
                    idx=Packages; [ "$kind" != src/gz ] || idx=Packages.gz
                    if [ ! -f "$path/$idx" ]; then
                        # Known Kwrt build-path leak; preserve the exact release/architecture suffix.
                        candidate=''
                        case "$path" in /www/wwwroot/dl.openwrt.ai/*)
                            candidate="https://dl.openwrt.ai/${path#/www/wwwroot/dl.openwrt.ai/}"
                            case "$candidate" in */Packages|*/Packages.gz) candidate="${candidate%/*}";; esac
                            ;;
                        esac
                        if [ -n "$candidate" ] && command -v curl >/dev/null 2>&1 && \
                           curl -fsS --connect-timeout 4 --max-time 12 --range 0-32 "$candidate/$idx" -o /dev/null 2>/dev/null; then
                            printf '%s %s %s\n' "$kind" "$name" "$candidate" >> "$tmp"
                        else printf '# home-suite disabled missing local feed: %s\n' "$line" >> "$tmp"; fi
                        changed=1; continue
                    fi
                    ;;
            esac
            printf '%s\n' "$line" >> "$tmp"
        done < "$src"
        if [ "$changed" = 1 ]; then
            if [ -z "$backup" ]; then backup="$(mktemp -d /etc/home-sources-backup.XXXXXX)"; fi
            cp -p "$src" "$backup/$(basename "$src")"
            cat "$tmp" > "$src"
            say "已修复失效本地源；备份：$backup"
        fi
        rm -f "$tmp"
    done
}
opkg_update_required() {
    local pkg log="$STAGE/opkg-update.log"
    opkg_prepare_sources
    if opkg update > "$log" 2>&1; then return 0; fi
    if grep -Ei 'signature check failed|verification failed|signature verification' "$log" >/dev/null; then
        die "软件源签名校验失败；日志：$log"
    fi
    for pkg in $PACKAGES; do
        opkg list "$pkg" 2>/dev/null | awk -v p="$pkg" '$1==p{f=1}END{exit !f}' || {
            if grep -Eq '404|Not Found' "$log"; then warn '有软件源地址失效（404），未跨固件替换源';
            elif grep -Eiq 'resolve|DNS|bad address' "$log"; then warn '软件源域名解析失败，请检查网关/DNS';
            else warn '软件源连接失败或超时'; fi
            die "匹配固件的软件源中缺少 $pkg；日志：$log"
        }
    done
    warn '部分可选源不可达；必需软件包可用，继续安装'
}

install_packages() {
    say "========== 1. 安装并检查依赖 =========="
    CONFIG_PREEXISTED=0
    [ ! -e /etc/sing-box/config.json ] || CONFIG_PREEXISTED=1
    [ -r /etc/rc.common ] && [ -r /lib/functions/procd.sh ] || die '缺少 OpenWrt 核心服务框架；不能安全自动替换固件核心'
    if ! mkdir /tmp/home-suite-install.lock 2>/dev/null; then
        [ ! -L /tmp/home-suite-install.lock ] || die '安装锁路径异常（符号链接）'
        LOCK_PID="$(awk 'NR==1{print;exit}' /tmp/home-suite-install.lock/pid 2>/dev/null || true)"
        case "$LOCK_PID" in ''|*[!0-9]*) die '安装锁没有有效 PID；请确认无另一安装后检查此锁' ;; esac
        if kill -0 "$LOCK_PID" 2>/dev/null; then die "另一安装进程仍运行（PID=$LOCK_PID）"; fi
        rm -f /tmp/home-suite-install.lock/pid
        rmdir /tmp/home-suite-install.lock || die '旧锁含未知文件，不删除'
        mkdir /tmp/home-suite-install.lock || die '无法取得安装锁'
    fi
    LOCK_HELD=1
    printf '%s\n' "$$" > /tmp/home-suite-install.lock/pid
    STAGE="$(mktemp -d /tmp/home-suite.XXXXXX)"
    [ "$(date +%s)" -ge 1735689600 ] || die '系统时间早于 2025 年，先校准时间再进行 HTTPS 安装'
    [ "$(df -Pk /etc | awk 'END{print $4}')" -ge 98304 ] || die '系统可写分区至少需要 96 MiB 空间（含 Xray 及备份）'
    [ "$(awk '/MemAvailable:/{print $2}' /proc/meminfo)" -ge 65536 ] || die '可用内存不足 64 MiB；双进程协议自检至少需要这些余量'
    PACKAGES=''
    for MAP in curl:curl jq:jq openssl:openssl-util socat:socat od:coreutils-od sysctl:procps-ng-sysctl modprobe:kmod unzip:unzip jsonfilter:jsonfilter base64:coreutils-base64 ip:ip-full netstat:net-tools-netstat timeout:coreutils-timeout flock:flock nft:nftables fw4:firewall4 ubus:ubus sha256sum:coreutils-sha256sum; do
        CMD="${MAP%%:*}"; PKG="${MAP#*:}"
        command -v "$CMD" >/dev/null 2>&1 || PACKAGES="$PACKAGES $PKG"
    done
    netstat -lntp >/dev/null 2>&1 || PACKAGES="$PACKAGES net-tools-netstat"
    timeout -k 1 2 sh -c true >/dev/null 2>&1 || PACKAGES="$PACKAGES coreutils-timeout"
    curl --version 2>/dev/null | grep -q https || PACKAGES="$PACKAGES curl"
    [ -s /etc/ssl/certs/ca-certificates.crt ] || PACKAGES="$PACKAGES ca-bundle"
    [ -x /etc/init.d/firewall ] || PACKAGES="$PACKAGES firewall4"
    [ -x /etc/init.d/dropbear ] || PACKAGES="$PACKAGES dropbear"
    # cron is supplied by the firmware's BusyBox package; reinstall only when absent.
    if [ ! -x /etc/init.d/cron ] || ! command -v crond >/dev/null 2>&1; then PACKAGES="$PACKAGES busybox"; fi
    # 即使当前依赖齐全，也先清理确定失效的本地 feed，避免下次补包再次被它中断。
    if command -v opkg >/dev/null 2>&1; then opkg_update_required; fi
    if [ -n "$PACKAGES" ]; then
        say "补齐依赖：$PACKAGES"
        if command -v opkg >/dev/null 2>&1; then
            opkg install --force-reinstall $PACKAGES || die '缺失/损坏依赖修复失败，未开始写入业务配置；不强制忽略架构/内核/签名错误'
        elif command -v apk >/dev/null 2>&1; then
            apk update || die '软件源更新失败'
            apk add $PACKAGES || die '依赖安装失败；不跨发行版安装软件包'
            apk fix $PACKAGES || die '依赖文件修复失败'
        else die '没有 opkg/apk，无法补齐依赖'; fi
    fi
    hash -r 2>/dev/null || true
    for cmd in curl jq openssl socat od sysctl modprobe unzip jsonfilter base64 ip awk sed uci netstat timeout flock nft fw4 ubus sha256sum pidof dd tr wc head tail sort cut cmp crontab crond; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
    done
    exec 6>/tmp/node-config.flock
    flock -n 6 || die '节点配置或代理升级正在执行，请稍后重试'
    curl --version | grep -q 'https' || die 'curl 不支持 HTTPS'
    [ "$(printf cHJlZmxpZ2h0 | base64 -d)" = preflight ] || die 'base64 解码自检失败'
    timeout -k 1 2 sh -c 'exit 0' || die 'timeout 调用方式不兼容，需要支持 -k 的 timeout'
    netstat -lntp >/dev/null 2>&1 || die 'netstat TCP 检查不可用'
    netstat -lnu >/dev/null 2>&1 || die 'netstat UDP 检查不可用'
    ubus call service list >/dev/null 2>&1 || die 'procd/ubus 服务不可用'
    nft list ruleset >/dev/null 2>&1 || die 'fw4/nftables 不可用（本包支持 fw4 固件）'
    fw4 check >"$STAGE/fw4-check.log" 2>&1 || { sed -n '1,40p' "$STAGE/fw4-check.log" >&2; die '现有防火墙校验失败；不自动删除 PassWall 配置'; }
    [ -x /etc/init.d/firewall ] || die "缺少 OpenWrt firewall 服务"
    [ -x /etc/init.d/dropbear ] || die "缺少 OpenWrt Dropbear 服务"
    [ -x /etc/init.d/cron ] || die "缺少 OpenWrt cron 服务"
    pidof dropbear >/dev/null 2>&1 || die 'Dropbear 未运行；不会自动启动/改写已有 SSH 服务'
    tcp_listening 22 || die '当前 SSH 不监听 TCP 22；本安装包保留现有 SSH，不猜测改端口'
    say '依赖、HTTPS、procd/ubus、TCP/UDP 检查工具、fw4 和现有 SSH 预检通过'
}

read_settings() {
    say
    say "========== 2. 输入 DuckDNS 信息 =========="
    OLD_DOMAIN=""
    OLD_TOKEN=""
    OLD_SS_PORT=""
    OLD_SS_KEY=""
    if [ -r "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONF_FILE"
        OLD_DOMAIN="${DOMAIN:-}"
        OLD_TOKEN="${TOKEN:-}"
        OLD_SS_PORT="${SS_PORT:-}"
        OLD_SS_KEY="${SS_KEY:-}"
    fi
    if [ -z "$OLD_SS_KEY" ] && [ -r /etc/sing-box/config.json ] && \
       grep -q '"home-ss"' /etc/sing-box/config.json; then
        OLD_SS_KEY="$(jsonfilter -i /etc/sing-box/config.json -e '@.inbounds[0].password' 2>/dev/null || true)"
        [ -n "$OLD_SS_PORT" ] || \
            OLD_SS_PORT="$(jsonfilter -i /etc/sing-box/config.json -e '@.inbounds[0].listen_port' 2>/dev/null || true)"
    fi

    if [ -n "$OLD_DOMAIN" ]; then
        printf 'DuckDNS 前缀 [%s]：' "$OLD_DOMAIN"
    else
        printf 'DuckDNS 前缀（不要填写 .duckdns.org）：'
    fi
    IFS= read -r INPUT_DOMAIN
    DOMAIN="${INPUT_DOMAIN:-$OLD_DOMAIN}"
    DOMAIN="${DOMAIN%.duckdns.org}"
    printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9-]+$' || die "DuckDNS 前缀格式不正确"

    if [ -n "$OLD_TOKEN" ]; then
        printf 'DuckDNS Token（直接回车保留已保存 Token）：'
    else
        printf 'DuckDNS Token：'
    fi
    stty -echo 2>/dev/null || true
    IFS= read -r INPUT_TOKEN
    stty echo 2>/dev/null || true
    say
    TOKEN="${INPUT_TOKEN:-$OLD_TOKEN}"
    [ -n "$TOKEN" ] || die "Token 不能为空"
    printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9-]+$' || die "Token 格式不正确"
}

read_monitor_settings() {
    say
    say "========== 3. 输入 Cloudflare 路由节点中心信息 =========="
    OLD_MONITOR_ENABLED="1"
    OLD_WORKER_URL=""
    OLD_DEVICE_NAME=""
    OLD_DEVICE_ID=""
    OLD_DEVICE_TOKEN=""
    if [ -r "$MONITOR_CONF" ]; then
        # shellcheck disable=SC1090
        . "$MONITOR_CONF"
        OLD_MONITOR_ENABLED="${MONITOR_ENABLED:-1}"
        OLD_WORKER_URL="${WORKER_URL:-}"
        OLD_DEVICE_ID="${DEVICE_ID:-}"
        OLD_DEVICE_TOKEN="${DEVICE_TOKEN:-}"
        if [ -n "${DEVICE_NAME_B64:-}" ]; then
            OLD_DEVICE_NAME="$(printf '%s' "$DEVICE_NAME_B64" | b64_decode || true)"
        fi
    fi

    DEFAULT_ENABLE="Y"
    printf '启用 Cloudflare/Telegram 监控？[Y/n]：'
    IFS= read -r INPUT_ENABLE
    case "${INPUT_ENABLE:-$DEFAULT_ENABLE}" in
        y|Y|yes|YES|1) MONITOR_ENABLED=1 ;;
        n|N|no|NO|0) MONITOR_ENABLED=0 ;;
        *) die "请输入 Y 或 N" ;;
    esac
    [ "$MONITOR_ENABLED" = 1 ] || die '本完整包要求开启 Telegram 监控和 root 远控；取消安装'

    WORKER_URL="$OLD_WORKER_URL"
    DEVICE_NAME="${OLD_DEVICE_NAME:-home-router}"
    PAIR_CODE=""
    REPAIR_MONITOR=0
    [ "$MONITOR_ENABLED" = 1 ] || return 0

    if [ -n "$OLD_WORKER_URL" ]; then
        printf 'Cloudflare 监控入口 [%s]：' "$OLD_WORKER_URL"
    else
        printf 'Cloudflare Pages 监控入口（推荐 https://xxx.pages.dev）：'
    fi
    IFS= read -r INPUT_WORKER
    WORKER_URL="${INPUT_WORKER:-$OLD_WORKER_URL}"
    WORKER_URL="${WORKER_URL%/}"
    printf '%s' "$WORKER_URL" | grep -Eq '^https://[A-Za-z0-9._:-]+$' || die "Cloudflare 入口格式不正确"

    printf '设备名称 [%s]：' "$DEVICE_NAME"
    IFS= read -r INPUT_NAME
    DEVICE_NAME="${INPUT_NAME:-$DEVICE_NAME}"
    [ -n "$DEVICE_NAME" ] || die "设备名称不能为空"
    [ "$(printf '%s' "$DEVICE_NAME" | wc -c)" -le 48 ] || die "设备名称不能超过48字节"
    if printf '%s' "$DEVICE_NAME" | grep -q '[[:cntrl:]]'; then
        die "设备名称不能包含控制字符"
    fi

    if [ -n "$OLD_DEVICE_ID" ] && [ -n "$OLD_DEVICE_TOKEN" ] && [ "$WORKER_URL" = "$OLD_WORKER_URL" ]; then
        printf '检测到现有设备绑定，重新配对？[y/N]：'
        IFS= read -r INPUT_REPAIR
        case "${INPUT_REPAIR:-N}" in
            y|Y|yes|YES|1) REPAIR_MONITOR=1 ;;
            n|N|no|NO|0) REPAIR_MONITOR=0 ;;
            *) die "请输入 Y 或 N" ;;
        esac
    else
        REPAIR_MONITOR=1
    fi
}

is_public_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1 }
        $1==0 || $1==10 || $1==127 { exit 1 }
        $1==100 && $2>=64 && $2<=127 { exit 1 }
        $1==169 && $2==254 { exit 1 }
        $1==172 && $2>=16 && $2<=31 { exit 1 }
        $1==192 && $2==168 { exit 1 }
        $1==192 && $2==0 && $3==0 { exit 1 }
        $1==198 && ($2==18 || $2==19) { exit 1 }
        $1==192 && $2==0 && $3==2 { exit 1 }
        $1==198 && $2==51 && $3==100 { exit 1 }
        $1==203 && $2==0 && $3==113 { exit 1 }
        $1>=224 { exit 1 }
        { exit 0 }'
}

normalize_ipv6() {
    ADDR="$1"
    [ -n "$ADDR" ] || return 1
    ip -6 route get "$ADDR" 2>/dev/null | awk '
        $1=="local" && $2 ~ /:/ {print $2; exit}
        $1 ~ /:/ {print $1; exit}
    '
}

get_external_ipv4() {
    for URL in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.co/ip
    do
        V="$(curl -4fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null | tr -d '[:space:]' || true)"
        if [ -n "$V" ] && is_public_ipv4 "$V"; then
            printf '%s\n' "$V"
            return 0
        fi
    done
    return 1
}

get_external_ipv6() {
    for URL in \
        https://api6.ipify.org \
        https://ipv6.icanhazip.com \
        https://ifconfig.co/ip
    do
        V="$(curl -6fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null | tr -d '[:space:]' || true)"
        case "$V" in
            [23]*:*)
                N="$(normalize_ipv6 "$V" 2>/dev/null || true)"
                [ -n "$N" ] && { printf '%s\n' "$N"; return 0; }
                ;;
        esac
    done
    return 1
}

default_route_device() {
    case "$1" in
        4) ip -4 route show default 2>/dev/null ;;
        6) ip -6 route show default 2>/dev/null ;;
        *) return 2 ;;
    esac | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
}

default_route_source() {
    case "$1" in
        4) ip -4 route get 1.1.1.1 2>/dev/null ;;
        6) ip -6 route get 2606:4700:4700::1111 2>/dev/null ;;
        *) return 2 ;;
    esac | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}'
}

logical_network_for_device() {
    WANT_DEV="$1"
    [ -n "$WANT_DEV" ] || return 1
    set +u
    for NET in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
        NET_DEV=''
        network_get_device NET_DEV "$NET" 2>/dev/null || NET_DEV=''
        [ "$NET_DEV" = "$WANT_DEV" ] && { printf '%s\n' "$NET"; set -u; return 0; }
    done
    set -u
    return 1
}

first_global_ipv6() {
    ip -6 addr show scope global 2>/dev/null | awk '
        $1=="inet6" && $0 !~ /tentative|dadfailed|deprecated/ {
            split($2,a,"/"); if(a[1] ~ /^[23]/){print a[1]; exit}
        }'
}

detect_network() {
    say
    say "========== 4. 检测家宽 IP 类型 =========="
    hn_detect
    WAN4_DEV="$HN_DEV4"; WAN6_DEV="$HN_DEV6"; WAN4_IF="$HN_NET4"; WAN6_IF="$HN_NET6"
    LOCAL4="$HN_IP4"; LOCAL6="$HN_IP6"; PUBLIC4=''; PUBLIC6=''
    FIREWALL_MANAGED=1
    NETWORK_ROLE='实际出口自动识别'
    PUBLIC4="$(hn_external4 2>/dev/null || true)"
    PUBLIC6=""

    IPV4_KIND="none"
    if [ -n "$LOCAL4" ]; then
        if is_public_ipv4 "$LOCAL4"; then
            if [ -n "$PUBLIC4" ] && [ "$LOCAL4" = "$PUBLIC4" ]; then
                IPV4_KIND="public"
            elif [ -n "$PUBLIC4" ]; then
                IPV4_KIND="upstream-nat"
            else
                IPV4_KIND="public-unverified"
            fi
        else
            IPV4_KIND="private-or-cgnat"
        fi
    fi

    IPV6_KIND="none"
    if [ -n "$LOCAL6" ]; then
        if [ -n "$PUBLIC6" ] && [ "$LOCAL6" = "$PUBLIC6" ]; then
            IPV6_KIND="public"
        elif [ -n "$PUBLIC6" ]; then
            IPV6_KIND="translated-or-unmatched"
        else
            IPV6_KIND="global-unverified"
        fi
    fi

    case "$IPV4_KIND/$IPV6_KIND" in
        public/public) NET_TYPE="独立公网 IPv4 + 公网 IPv6（双栈）" ;;
        public/*) NET_TYPE="独立公网 IPv4；IPv6 不可确认或不可用" ;;
        private-or-cgnat/public|upstream-nat/public) NET_TYPE="运营商内部/上级 NAT IPv4 + 公网 IPv6" ;;
        none/public) NET_TYPE="无 IPv4 + 公网 IPv6" ;;
        */public) NET_TYPE="公网 IPv6；IPv4 不可用于直接入站" ;;
        public-unverified/*) NET_TYPE="疑似公网 IPv4（多个外部检测服务暂时失败）" ;;
        */global-unverified) NET_TYPE="本机有全局 IPv6；外部回显失败，入站能力待外网实测" ;;
        *) NET_TYPE="没有检测到可确认的公网入站地址" ;;
    esac

    say "网络类型：$NET_TYPE"
    say "部署识别：$NETWORK_ROLE（实际出口设备：${WAN4_DEV:-${WAN6_DEV:-未识别}}）"
    say "IPv4 逻辑接口/设备：${WAN4_IF:-无} / ${WAN4_DEV:-无}"
    say "路由器 IPv4：${LOCAL4:-无}；外网出口 IPv4：${PUBLIC4:-检测失败}"
    say "IPv6 逻辑接口/设备：${WAN6_IF:-无} / ${WAN6_DEV:-自动路由}"
    say "路由器 IPv6：${LOCAL6:-无}；外网出口 IPv6：${PUBLIC6:-检测失败}"

    HAVE_V4=0
    HAVE_V6=0
    [ "$IPV4_KIND" = "public" ] && HAVE_V4=1
    case "$IPV6_KIND" in public|global-unverified) HAVE_V6=1 ;; esac

    if [ "$HAVE_V4" != 1 ] && [ "$HAVE_V6" != 1 ]; then
        warn '当前没有可发布地址：仍可完成节点安装；DuckDNS 会保留原记录并在 5 分钟巡检或接口变化后自动重测'
    fi
    [ "$FIREWALL_MANAGED" = 1 ] || say '旁路由提示：本机不写 WAN 放行；IPv4 需在主路由转发端口，IPv6 需主路由允许转发到本机'
    say '注意：出口地址回显和全局 IPv6 均不等于外网入站成功；上级光猫/运营商防火墙仍需外网测试。'
}

check_monitor_endpoint() {
    [ "$MONITOR_ENABLED" = 1 ] || return 0
    say
    say "========== 5. 验证 Cloudflare 监控入口 =========="
    HEALTH="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 \
        "${WORKER_URL}/health" 2>/dev/null || true)"
    if [ "$(printf '%s' "$HEALTH" | jsonfilter -e '@.ok' 2>/dev/null || true)" != true ]; then
        say "停止：路由器无法访问监控入口：$WORKER_URL" >&2
        say "请优先填写部署包生成的 https://xxx.pages.dev 地址。" >&2
        say "此时尚未写 Xray、防火墙、DDNS 或定时任务，可安全修正后重跑。" >&2
        exit 1
    fi
    CF_VERSION="$(printf '%s' "$HEALTH" | jsonfilter -e '@.version' 2>/dev/null || true)"
    [ "$(printf '%s' "$HEALTH" | jsonfilter -e '@.capabilities.command_check' 2>/dev/null || true)" = true ] || die '请先按教程全新部署本仓库的 Cloudflare 中心，当前入口不支持远控预检'
    [ "$(printf '%s' "$HEALTH" | jsonfilter -e '@.capabilities.router_vless' 2>/dev/null || true)" = true ] || die '当前 Cloudflare 中心不支持 VLESS 家宽，请部署本版本 Cloudflare 代码'
    case "$CF_VERSION" in
        3.*) ;;
        *)
            say "停止：Cloudflare 节点中心版本为 ${CF_VERSION:-未知}，当前安装器要求 3.x root 远控版。" >&2
            say "请先按教程全新部署本仓库的 Cloudflare 中心，然后重新执行本脚本。" >&2
            exit 1
            ;;
    esac
    say "Cloudflare 监控/远控入口可达，版本：$CF_VERSION"
    if [ "$REPAIR_MONITOR" = 0 ] && [ -n "$OLD_DEVICE_ID" ]; then
        IDENTITY_CHECK="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 -X POST "${WORKER_URL}/api/v1/command/check" -H "X-Device-ID: $OLD_DEVICE_ID" -H "Authorization: Bearer $OLD_DEVICE_TOKEN" -d '' 2>/dev/null || true)"
        if [ "$(printf '%s' "$IDENTITY_CHECK" | jsonfilter -e '@.ok' 2>/dev/null || true)" != true ]; then
            REPAIR_MONITOR=1
            warn '旧设备身份未通过验证，已改为安装后重新配对；请准备新的 TG 一次性配对码'
        fi
    fi
}

port_in_use() {
    netstat -lntu 2>/dev/null | awk -v p=":$1" '$1 ~ /^(tcp|udp)/ && $4 ~ p"$" {found=1} END {exit !found}'
}

tcp_listening() {
    netstat -ln 2>/dev/null | awk -v p=":$1" '$1 ~ /^tcp/ && $4 ~ p"$" {found=1} END {exit !found}'
}

udp_listening() {
    netstat -ln 2>/dev/null | awk -v p=":$1" '$1 ~ /^udp/ && $4 ~ p"$" {found=1} END {exit !found}'
}

check_existing_node() {
    OWN_EXISTING=0
    LEGACY_SS=0
    # A separate home-node instance never takes over PassWall's sing-box or Xray.
    if [ -s /etc/home-ss/xray.json ]; then
        jq -e '.inbounds | length == 1 and .[0].tag == "home-vless"' /etc/home-ss/xray.json >/dev/null || die '已有 home-node 配置包含其他入站，不覆盖'
        OWN_EXISTING=1
        OLD_VLESS_PORT="$(jq -r '.inbounds[0].port' /etc/home-ss/xray.json)"
    fi
    if [ -s /etc/sing-box/config.json ] && jq -e '.inbounds | length == 1 and .[0].tag == "home-ss" and .[0].type == "shadowsocks"' /etc/sing-box/config.json >/dev/null 2>&1; then
        LEGACY_SS=1
        say '发现旧家宽 SS：本次保持服务/防火墙不变，新 VLESS 使用独立端口；客户端验收后可手动停旧 SS'
    fi
}

node_listening() {
    # Match the procd-owned PID as well as its port, not an unrelated 'xray' process.
    local pids pid
    pids="$(ubus call service list '{"name":"home-node"}' 2>/dev/null | jsonfilter -e '@["home-node"].instances.*.pid' 2>/dev/null || true)"
    for pid in $pids; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ -r "/proc/$pid/cmdline" ] || continue
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq '/usr/libexec/home-node/xray run -config /etc/home-ss/xray.json' || continue
        netstat -lntp 2>/dev/null | awk -v p=":$1" -v id="$pid/" '$4~p"$" && index($7,id)==1{f=1}END{exit !f}' && return 0
    done
    return 1
}

prepare_transaction() {
    TX_DIR="$(mktemp -d /etc/home-suite-backup.XXXXXX)"
    # Explicit, task-owned files only. Packages and external DNS are not rolled back.
    for F in /usr/local/sbin/node-config /usr/local/lib/node-suite/runtime.sh /usr/libexec/home-node/network.sh /etc/home-ss/xray.json /usr/libexec/home-node/xray /etc/init.d/home-node /usr/bin/home-node-legacy /usr/local/sbin/node-temperature /usr/local/sbin/node-net-optimize /usr/local/sbin/node-link-test /usr/local/sbin/node-sqm-setup /etc/config/firewall /etc/home-ss/settings.conf /etc/home-ss/monitor.conf /etc/home-ss/ddns-mode /etc/home-ss/ddns-last.conf /usr/bin/home-ddns-update /usr/bin/home-monitor /usr/bin/home-monitor-pair /usr/bin/home-agent-tick /usr/bin/home-command-agent /etc/init.d/home-command-agent /etc/hotplug.d/iface/95-home-ddns /etc/crontabs/root /root/home-ss-node.txt; do
        printf '%s\n' "$F" >> "$TX_DIR/manifest"
        if [ -e "$F" ]; then mkdir -p "$TX_DIR/files$(dirname "$F")"; cp -p "$F" "$TX_DIR/files$F"; fi
    done
    for S in home-node home-command-agent cron; do
        EN=0; RUN=0
        [ -x "/etc/init.d/$S" ] && /etc/init.d/"$S" enabled >/dev/null 2>&1 && EN=1
        [ -x "/etc/init.d/$S" ] && /etc/init.d/"$S" running >/dev/null 2>&1 && RUN=1
        printf '%s %s %s\n' "$S" "$EN" "$RUN" >> "$TX_DIR/services"
    done
    TX_ACTIVE=1
}

prepare_router_reality() {
    printf 'REALITY SNI [%s]：' "${REALITY_SNI:-www.apple.com}"
    IFS= read -r answer || die '终端输入结束'
    REALITY_SNI="${answer:-${REALITY_SNI:-www.apple.com}}"
    printf '%s' "$REALITY_SNI" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$' || die 'SNI 格式不正确'
    [ "${#REALITY_SNI}" -le 253 ] || die 'SNI 过长'
    printf 'REALITY 目标 [%s:443]：' "$REALITY_SNI"
    IFS= read -r answer || die '终端输入结束'
    REALITY_DEST="${answer:-$REALITY_SNI:443}"
    printf '%s' "$REALITY_DEST" | grep -Eq '^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$' || die '目标应为 域名:端口'
    [ "${REALITY_DEST##*:}" -le 65535 ] || die '目标端口过大'
    printf '应用保守 TCP 优化（内核支持时 BBR + MTU 黑洞恢复）？[Y/n]：'
    IFS= read -r answer || die '终端输入结束'
    case "${answer:-Y}" in y|Y|yes|YES) ENABLE_BBR=1 ;; n|N|no|NO) ENABLE_BBR=0 ;; *) die '请输入 Y 或 N' ;; esac
    suite_stage_xray /usr/libexec/home-node/xray
    suite_check_target
    if ! printf '%s' "${XRAY_UUID:-}" | grep -Eq '^[a-fA-F0-9-]{36}$'; then XRAY_UUID="$("$XRAY_BIN" uuid)"; fi
    if printf '%s' "${REALITY_PRIVATE_KEY:-}" | grep -Eq '^[A-Za-z0-9_-]{43}$'; then
        KEYS="$("$XRAY_BIN" x25519 -i "$REALITY_PRIVATE_KEY")"
    else
        KEYS="$("$XRAY_BIN" x25519)"
        REALITY_PRIVATE_KEY="$(printf '%s\n' "$KEYS" | awk -F':[[:space:]]*' 'tolower($1)~/^private ?key$/{print $2;exit}')"
    fi
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$KEYS" | awk -F':[[:space:]]*' 'tolower($1)~/public ?key/ || tolower($1)=="password"{print $2;exit}')"
    for key in "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY"; do printf '%s' "$key" | grep -Eq '^[A-Za-z0-9_-]{43}$' || die 'REALITY 密钥解析失败（不打印私钥）'; done
    if ! printf '%s' "${REALITY_SHORT_ID:-}" | grep -Eq '^([a-fA-F0-9]{2}){1,8}$'; then REALITY_SHORT_ID="$(openssl rand -hex 8)"; fi
    local listen=0.0.0.0
    [ ! -s /proc/net/if_inet6 ] || listen='::'
    jq -n --argjson port "$SS_PORT" --arg listen "$listen" --arg uuid "$XRAY_UUID" --arg key "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" --arg sni "$REALITY_SNI" --arg target "$REALITY_DEST" \
        '{log:{loglevel:"warning"},inbounds:[{tag:"home-vless",listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"raw",security:"reality",realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$key,shortIds:[$sid]}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$STAGE/config.json"
    suite_smoke_xray
}

choose_port() {
    say '========== 6. 检查新节点 TCP 端口 =========='
    SS_PORT="${OLD_VLESS_PORT:-$(random_node_port)}"
    printf 'VLESS TCP 端口 [%s]：' "$SS_PORT"
    IFS= read -r answer || die '终端输入结束，尚未写配置'
    SS_PORT="${answer:-$SS_PORT}"
    printf '%s' "$SS_PORT" | grep -Eq '^[1-9][0-9]{0,4}$' || die '端口应为 1-65535 的整数（不带前导零）'
    [ "$SS_PORT" -le 65535 ] || die '端口超过 65535'
    local tries=0
    while port_in_use "$SS_PORT"; do
        if [ "$OWN_EXISTING" = 1 ] && [ "$SS_PORT" = "${OLD_VLESS_PORT:-}" ] && node_listening "$SS_PORT"; then break; fi
        SS_PORT=$((SS_PORT+1)); tries=$((tries+1))
        [ "$SS_PORT" -le 65535 ] && [ "$tries" -lt 500 ] || die '未找到可用端口'
    done
    say "新节点使用 TCP $SS_PORT；UDP 在 VLESS 隧道内转发，不需要额外 UDP 监听端口"
}

confirm_install() {
    say
    say "========== 7. 安装前确认 =========="
    say "DuckDNS：${DOMAIN}.duckdns.org"
    say "VLESS + REALITY + Vision：TCP $SS_PORT；UDP 隧道转发（U/V/R）"
    say "SSH：仅新增 TCP 22 放行规则，不改 Dropbear 密码或配置"
    if [ "$MONITOR_ENABLED" = 1 ]; then
        say "监控入口：$WORKER_URL"
        say "监控行为：状态采集 + Telegram root 远控；路由器主动拉取命令，不开放额外管理端口"
        say "远控能力：任意 root Shell、重启独立 Xray、刷新 DDNS、重启路由器"
    else
        say "Cloudflare/Telegram 监控：禁用"
    fi
    printf '确认开始写入配置？[Y/n]：'
    IFS= read -r ANSWER
    case "${ANSWER:-Y}" in
        y|Y|yes|YES|1) ;;
        n|N|no|NO|0) die "用户取消，尚未写入服务配置" ;;
        *) die "请输入 Y 或 N" ;;
    esac
}

write_xray() {
    say '========== 8. 安装独立 Xray 家宽节点 =========='
    mkdir -p /usr/libexec/home-node "$STATE_DIR"
    cp "$STAGE/xray" /usr/libexec/home-node/xray.new
    chmod 755 /usr/libexec/home-node/xray.new
    mv /usr/libexec/home-node/xray.new /usr/libexec/home-node/xray
    cp "$STAGE/config.json" /etc/home-ss/xray.json
    chmod 600 /etc/home-ss/xray.json
    ensure_xray_init
    cat > "$CONF_FILE.tmp" <<EOF_SETTINGS
DOMAIN='$DOMAIN'
TOKEN='$TOKEN'
SS_PORT='$SS_PORT'
NODE_PROTOCOL='vless-reality-vision'
XRAY_UUID='$XRAY_UUID'
REALITY_PRIVATE_KEY='$REALITY_PRIVATE_KEY'
REALITY_PUBLIC_KEY='$REALITY_PUBLIC_KEY'
REALITY_SHORT_ID='$REALITY_SHORT_ID'
REALITY_SNI='$REALITY_SNI'
REALITY_DEST='$REALITY_DEST'
EOF_SETTINGS
    chmod 600 "$CONF_FILE.tmp"; mv "$CONF_FILE.tmp" "$CONF_FILE"
    if [ "$OLD_DOMAIN" != "$DOMAIN" ]; then rm -f "$MODE_FILE" /etc/home-ss/ddns-last.conf; fi
    suite_write_runtime
    suite_install_editor
    write_network_library
    cat > /usr/bin/home-node-legacy <<'EOF_LEGACY'
#!/bin/sh
set -eu
case "${1:-}" in disable|enable) ;; *) echo '用法：home-node-legacy disable|enable（只控制旧家宽 SS，保留配置）'; exit 2 ;; esac
jq -e '.inbounds | length == 1 and .[0].tag == "home-ss" and .[0].type == "shadowsocks"' /etc/sing-box/config.json >/dev/null || { echo '旧配置不属于本家宽单节点，拒绝操作'; exit 1; }
grep -Fq '/etc/sing-box/config.json' /etc/init.d/sing-box && grep -q procd_set_param /etc/init.d/sing-box || { echo '旧 sing-box 服务启动脚本无法确认，拒绝接管'; exit 1; }
if grep -Eq 'killall|pkill' /etc/init.d/sing-box; then echo '旧启动脚本有全局进程终止逻辑，拒绝自动停用'; exit 1; fi
if [ "$1" = disable ]; then
    echo '将停止旧家宽 SS，现有 SS 连接会中断；请先从外网验证新 VLESS。SSH/DDNS 不改。'
    printf '确认？输入 yes：'; read -r answer; [ "$answer" = yes ] || exit 0
    /etc/init.d/sing-box disable
    /etc/init.d/sing-box stop
    echo '旧 SS 已停用，配置仍保留；恢复命令：home-node-legacy enable'
else
    /etc/init.d/sing-box enable
    /etc/init.d/sing-box start
fi
EOF_LEGACY
    chmod 700 /usr/bin/home-node-legacy
}

find_firewall_zone_for_network() {
    NET="$1"
    [ -n "$NET" ] || return 1

    uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p' | while IFS= read -r SEC; do
        NAME="$(uci -q get "firewall.${SEC}.name" 2>/dev/null || true)"
        NETWORKS="$(uci -q get "firewall.${SEC}.network" 2>/dev/null || true)"
        for N in $NETWORKS; do
            if [ "$N" = "$NET" ]; then
                printf '%s\n' "$NAME"
                exit 0
            fi
        done
    done | head -n 1
}

firewall_zone_exists() {
    WANT="$1"
    FOUND=1
    for SEC in $(uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
        NAME="$(uci -q get "firewall.${SEC}.name" 2>/dev/null || true)"
        if [ "$NAME" = "$WANT" ]; then
            FOUND=0
            break
        fi
    done
    return "$FOUND"
}

preflight_firewall() {
    configure_firewall --preflight
}

configure_firewall() {
    hn_detect
    FIREWALL_ZONES="$(hn_zones)"
    if [ "${1:-}" = --preflight ]; then
        if [ -n "$FIREWALL_ZONES" ]; then say "本机入站区域：$FIREWALL_ZONES";
        else warn '无活动出口区域，待网络恢复后同步指定端口'; fi
        return 0
    fi
    if [ -z "$FIREWALL_ZONES" ]; then warn '无出口区域，暂缓防火墙同步'; return 0; fi
    FW_CHANGED=1
    hn_firewall "$SS_PORT" || die '指定端口放行验证失败，恢复原配置'
}

write_ddns_updater() {
    mkdir -p '/usr/bin'
    cat > '/usr/bin/home-ddns-update' <<'EOF_DDNS_UNIFIED'
#!/bin/sh
set -eu
umask 077
exec 8>/tmp/home-ddns-update.flock
flock -n 8 || exit 0
. /etc/home-ss/settings.conf
. /usr/libexec/home-node/network.sh
VERBOSE=0; FORCE="${HOME_DDNS_FORCE:-0}"; EVENT=0
for a in "$@"; do case "$a" in --verbose) VERBOSE=1;; --event) EVENT=1;; esac; done
out() { if [ "$VERBOSE" = 1 ]; then printf '%s\n' "$*"; fi; }
PERSIST=/etc/home-ss/ddns-last.conf
RUNTIME=/tmp/home-ddns-state
LAST_IP4=''; LAST_IP6=''; LAST_MODE=none; LAST_OK=0; FAILURES=0
LAST_TOPOLOGY=''; LAST_VERIFY=0; WAITING=0
[ ! -r "$PERSIST" ] || . "$PERSIST"
[ ! -r "$RUNTIME" ] || . "$RUNTIME"
save_runtime() {
    cat > "$RUNTIME.new" <<EOF
LAST_IP4='$LAST_IP4'
LAST_IP6='$LAST_IP6'
LAST_MODE='$LAST_MODE'
LAST_OK='$LAST_OK'
FAILURES='$FAILURES'
LAST_TOPOLOGY='$LAST_TOPOLOGY'
LAST_VERIFY='$LAST_VERIFY'
WAITING='$WAITING'
EOF
    mv "$RUNTIME.new" "$RUNTIME"
}
fail() { FAILURES=$((FAILURES+1)); LAST_OK=0; save_runtime; out "$*"; exit 1; }
request() {
    curl -fsS --noproxy '*' --connect-timeout 5 --max-time 20 --retry 2 "$1" 2>/dev/null || true
}
update_values() {
    local query="https://www.duckdns.org/update?domains=$DOMAIN&token=$TOKEN"
    if [ -n "$1" ]; then query="$query&ip=$1"; fi
    if [ -n "$2" ]; then query="$query&ipv6=$2"; fi
    [ "$(request "$query")" = OK ]
}
hn_detect
NOW="$(date +%s)"
CHANGED=0; [ "$HN_TOPOLOGY" = "$LAST_TOPOLOGY" ] || CHANGED=1
# Waiting is cheap: inspect local topology every five minutes, no repeated external probes.
if [ "$WAITING" = 1 ] && [ "$CHANGED" = 0 ] && [ "$EVENT" = 0 ] && [ "$FORCE" = 0 ]; then
    out '等待地址变化'; exit 0
fi
TARGET4=''; TARGET6="$HN_IP6"; EXT4=''
if hn_public4 "$HN_IP4"; then
    if [ "$CHANGED" = 0 ] && [ "$EVENT" = 0 ] && [ "$FORCE" = 0 ] && [ $((NOW-LAST_VERIFY)) -lt 86400 ] && [ "$LAST_IP4" = "$HN_IP4" ]; then
        TARGET4="$LAST_IP4"
    else
        EXT4="$(hn_external4 || true)"
        if [ "$EXT4" = "$HN_IP4" ]; then TARGET4="$HN_IP4";
        elif [ -z "$EXT4" ]; then
            # Echo outage is not proof that IPv4 disappeared. Retry next scheduled run.
            if [ "$LAST_IP4" = "$HN_IP4" ]; then TARGET4="$LAST_IP4";
            elif [ -z "$TARGET6" ]; then fail 'IPv4 回显暂不可达；保留 DNS，稍后重试'; fi
        fi
    fi
fi
LAST_TOPOLOGY="$HN_TOPOLOGY"
if [ -z "$TARGET4$TARGET6" ]; then
    WAITING=1; LAST_OK=0; FAILURES=0; save_runtime
    out '无可发布公网地址；保留 DNS，等待网络变化'; exit 0
fi
MODE=v6
[ -z "$TARGET4" ] || MODE=v4
[ -z "$TARGET4" ] || [ -z "$TARGET6" ] || MODE=dual
if [ "$TARGET4|$TARGET6|$MODE" != "$LAST_IP4|$LAST_IP6|$LAST_MODE" ] || [ "$FORCE" = 1 ]; then
    clear=0
    [ -r "$PERSIST" ] || clear=1
    [ -z "$LAST_IP4" ] || [ -n "$TARGET4" ] || clear=1
    [ -z "$LAST_IP6" ] || [ -n "$TARGET6" ] || clear=1
    update_values "$TARGET4" "$TARGET6" || fail 'DuckDNS 更新失败，等待重试'
    if [ "$clear" = 1 ]; then
        [ "$(request "https://www.duckdns.org/update?domains=$DOMAIN&token=$TOKEN&clear=true")" = OK ] || fail 'DuckDNS 清理旧地址族失败'
        if ! update_values "$TARGET4" "$TARGET6"; then
            if [ -n "$LAST_IP4$LAST_IP6" ]; then update_values "$LAST_IP4" "$LAST_IP6" || true; fi
            fail 'DuckDNS 重写失败，已尝试恢复旧记录；稍后重试'
        fi
    fi
    LAST_IP4="$TARGET4"; LAST_IP6="$TARGET6"; LAST_MODE="$MODE"
    printf "LAST_IP4='%s'\nLAST_IP6='%s'\nLAST_MODE='%s'\n" "$LAST_IP4" "$LAST_IP6" "$LAST_MODE" > "$PERSIST.new"
    mv "$PERSIST.new" "$PERSIST"
    printf '%s\n' "$MODE" > /etc/home-ss/ddns-mode
    out "DuckDNS 已更新：$MODE"
else out "地址未变化：$MODE"; fi
WAITING=0; LAST_OK=1; FAILURES=0
# Do not postpone daily verification indefinitely or cache an echo failure.
if [ -n "$EXT4" ] || ! hn_public4 "$HN_IP4"; then LAST_VERIFY="$NOW"; fi
save_runtime
EOF_DDNS_UNIFIED
    chmod 700 '/usr/bin/home-ddns-update'
}

write_monitor_agent() {
    say
    say "========== 11. 安装轻量监控代理 =========="
    cat > /usr/bin/home-monitor <<'EOF'
#!/bin/sh
# 兼容内部会引用未定义变量的旧版 OpenWrt network.sh。
set +u
MON_CONF='/etc/home-ss/monitor.conf'
SS_CONF='/etc/home-ss/settings.conf'
DDNS_STATE='/tmp/home-ddns-state'
DDNS_PERSIST='/etc/home-ss/ddns-last.conf'
STATE='/tmp/home-monitor-state'
NODE_FILE='/root/home-ss-node.txt'
VERBOSE=0; FORCE_FULL=0
for a in "$@"; do
    [ "$a" = '--verbose' ] && VERBOSE=1
    [ "$a" = '--full' ] && FORCE_FULL=1
done
out() { [ "$VERBOSE" = 1 ] && printf '%s\n' "$*" || true; }
[ -r "$MON_CONF" ] || { out '尚未配置Cloudflare监控'; exit 0; }
. "$MON_CONF"
[ "${MONITOR_ENABLED:-0}" = 1 ] || { out 'Cloudflare监控已禁用'; exit 0; }
[ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ] && [ -n "${WORKER_URL:-}" ] || { out '设备尚未配对'; exit 1; }
[ -r "$SS_CONF" ] || { out '家宽节点配置不存在'; exit 1; }
. "$SS_CONF"
. /lib/functions/network.sh

DEVICE_NAME="$(printf '%s' "${DEVICE_NAME_B64:-}" | base64 -d 2>/dev/null || printf 'home-router')"
MEM_COUNT=0; TEMP_COUNT=0; STORAGE_COUNT=0; LOAD_COUNT=0; TCP_COUNT=0; UDP_COUNT=0; SERVICE_COUNT=0; NOIP_COUNT=0
LAST_FULL=0; LAST_NODE_CKSUM=''; CF_FAILURES=0
[ -r "$STATE" ] && . "$STATE"

bump() {
    V="$1"; BAD="$2"
    eval "OLD=\${$V:-0}"
    if [ "$BAD" = 1 ]; then NEW=$((OLD + 1)); [ "$NEW" -le 10 ] || NEW=10; else NEW=0; fi
    eval "$V=$NEW"
}
add_alert() { if [ -z "$ALERTS" ]; then ALERTS="$1"; else ALERTS="$ALERTS,$1"; fi; }
save_state() {
    umask 077
    T="$STATE.tmp.$$"
    cat > "$T" <<STATEV
MEM_COUNT='$MEM_COUNT'
TEMP_COUNT='$TEMP_COUNT'
STORAGE_COUNT='$STORAGE_COUNT'
LOAD_COUNT='$LOAD_COUNT'
TCP_COUNT='$TCP_COUNT'
UDP_COUNT='$UDP_COUNT'
SERVICE_COUNT='$SERVICE_COUNT'
NOIP_COUNT='$NOIP_COUNT'
LAST_FULL='$LAST_FULL'
LAST_NODE_CKSUM='$LAST_NODE_CKSUM'
CF_FAILURES='$CF_FAILURES'
STATEV
    mv "$T" "$STATE"
}

. /usr/libexec/home-node/network.sh
hn_detect
WAN4_IF="$HN_NET4"; WAN6_IF="$HN_NET6"; WAN_DEV="${HN_DEV4:-$HN_DEV6}"
LOCAL4="$HN_IP4"; LOCAL6="$HN_IP6"

LAST_IP4=''; LAST_IP6=''; LAST_MODE='none'; LAST_OK=0; FAILURES=0
[ -r "$DDNS_PERSIST" ] && . "$DDNS_PERSIST"
[ -r "$DDNS_STATE" ] && . "$DDNS_STATE"
PUBLIC4=''; PUBLIC6="$LOCAL6"; DDNS_MODE="$LAST_MODE"; DDNS_OK="$LAST_OK"; DDNS_FAILURES="$FAILURES"
[ -n "$LOCAL4" ] && [ "$LOCAL4" = "$LAST_IP4" ] && PUBLIC4="$LOCAL4"
if [ -n "$PUBLIC4" ] && [ -n "$PUBLIC6" ]; then NETWORK_TYPE='双栈公网地址已获取；等待 Cloudflare 外部验证入站'
elif [ -n "$PUBLIC6" ]; then NETWORK_TYPE='IPv6 公网地址已获取；IPv4 为上级 NAT 或未确认；等待 Cloudflare 外部验证入站'
elif [ -n "$PUBLIC4" ]; then NETWORK_TYPE='IPv4 公网地址已获取；等待 Cloudflare 外部验证入站'
else NETWORK_TYPE='上级 NAT / 暂无可发布地址'; fi

MEM_TOTAL="$(awk '/^MemTotal:/{print $2;exit}' /proc/meminfo)"
MEM_AVAIL="$(awk '/^MemAvailable:/{print $2;exit}' /proc/meminfo)"
if [ -z "$MEM_AVAIL" ]; then
    MEM_AVAIL="$(awk '/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print f+b+c}' /proc/meminfo)"
fi
MEM_TOTAL="${MEM_TOTAL:-0}"; MEM_AVAIL="${MEM_AVAIL:-0}"
if [ "$MEM_TOTAL" -gt 0 ]; then MEM_USED_PCT=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL )); else MEM_USED_PCT=0; fi
MEM_BAD=0
[ "$MEM_AVAIL" -lt 32768 ] && MEM_BAD=1
[ "$MEM_TOTAL" -gt 0 ] && [ $((MEM_AVAIL * 100 / MEM_TOTAL)) -lt 10 ] && MEM_BAD=1
bump MEM_COUNT "$MEM_BAD"

read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
[ "${CPU_CORES:-0}" -ge 1 ] 2>/dev/null || CPU_CORES=1
if awk -v l="$LOAD5" -v c="$CPU_CORES" 'BEGIN{exit !(l>c*2)}'; then LOAD_BAD=1; else LOAD_BAD=0; fi
bump LOAD_COUNT "$LOAD_BAD"

TEMP_C="$(/usr/local/sbin/node-temperature --value 2>/dev/null || true)"
TEMP_SOURCE="$(/usr/local/sbin/node-temperature --source 2>/dev/null || true)"
TEMP_BAD=0
[ -z "$TEMP_C" ] || { awk -v t="$TEMP_C" 'BEGIN{exit !(t>=80)}' && TEMP_BAD=1; }
bump TEMP_COUNT "$TEMP_BAD"

OVERLAY_PCT="$(df -P /overlay 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5;exit}')"
[ -n "$OVERLAY_PCT" ] || OVERLAY_PCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5;exit}')"
OVERLAY_PCT="${OVERLAY_PCT:-0}"
STORAGE_BAD=0; [ "$OVERLAY_PCT" -ge 90 ] 2>/dev/null && STORAGE_BAD=1
bump STORAGE_COUNT "$STORAGE_BAD"

SING_RUNNING=0; TCP_OK=0; UDP_OK=0
RUN_STATE="$(ubus call service list '{"name":"home-node"}' 2>/dev/null | jsonfilter -e '@["home-node"].instances.*.running' 2>/dev/null || true)"
[ "$RUN_STATE" = true ] && SING_RUNNING=1
netstat -ln 2>/dev/null | awk -v p=":$SS_PORT" '$1~/^tcp/ && $4~p"$"{f=1}END{exit !f}' && TCP_OK=1
# Capability only: UDP is carried by VLESS, not a separate listening socket.
[ "$SING_RUNNING" = 1 ] && [ "$TCP_OK" = 1 ] && UDP_OK=1
bump SERVICE_COUNT "$([ "$SING_RUNNING" = 1 ] && printf 0 || printf 1)"
bump TCP_COUNT "$([ "$TCP_OK" = 1 ] && printf 0 || printf 1)"
bump UDP_COUNT "$([ "$UDP_OK" = 1 ] && printf 0 || printf 1)"
if [ -z "$PUBLIC4" ] && [ -z "$PUBLIC6" ]; then NOIP_BAD=1; else NOIP_BAD=0; fi
bump NOIP_COUNT "$NOIP_BAD"

ALERTS=''
[ "$SERVICE_COUNT" -ge 1 ] && add_alert service
[ "$TCP_COUNT" -ge 2 ] && add_alert tcp
[ "$UDP_COUNT" -ge 2 ] && add_alert udp
[ "$MEM_COUNT" -ge 3 ] && add_alert memory
[ "$TEMP_COUNT" -ge 2 ] && add_alert temperature
[ "$STORAGE_COUNT" -ge 2 ] && add_alert storage
[ "$LOAD_COUNT" -ge 3 ] && add_alert load
[ "$DDNS_FAILURES" -ge 3 ] 2>/dev/null && add_alert ddns
[ "$NOIP_COUNT" -ge 3 ] && add_alert no_public_ip

UPTIME_SEC="$(awk '{printf "%d",$1}' /proc/uptime)"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || printf 'OpenWrt Router')"
FIRMWARE=""
[ -r /etc/openwrt_release ] && . /etc/openwrt_release
FIRMWARE="${DISTRIB_DESCRIPTION:-OpenWrt}"
WAN_RX=0; WAN_TX=0
if [ -n "$WAN_DEV" ] && [ -r "/sys/class/net/$WAN_DEV/statistics/rx_bytes" ]; then
    WAN_RX="$(cat "/sys/class/net/$WAN_DEV/statistics/rx_bytes" 2>/dev/null || printf 0)"
    WAN_TX="$(cat "/sys/class/net/$WAN_DEV/statistics/tx_bytes" 2>/dev/null || printf 0)"
fi
NOW="$(date +%s 2>/dev/null || printf '0')"; case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
if command -v sha256sum >/dev/null 2>&1; then
    NODE_CKSUM="$(sha256sum "$NODE_FILE" 2>/dev/null | awk '{print "sha256:"$1}')"
elif command -v md5sum >/dev/null 2>&1; then
    NODE_CKSUM="$(md5sum "$NODE_FILE" 2>/dev/null | awk '{print "md5:"$1}')"
elif command -v cksum >/dev/null 2>&1; then
    NODE_CKSUM="$(cksum "$NODE_FILE" 2>/dev/null | awk '{print "cksum:"$1":"$2}')"
else
    NODE_CKSUM="$(wc -c < "$NODE_FILE" 2>/dev/null | awk '{print "size:"$1}')"
fi
FULL="$FORCE_FULL"
[ "$LAST_FULL" -eq 0 ] && FULL=1
[ "$NOW" -gt 0 ] && [ $((NOW - LAST_FULL)) -ge 86400 ] && FULL=1
[ "$NODE_CKSUM" = "$LAST_NODE_CKSUM" ] || FULL=1

send_report() {
    SEND_FULL="$1"; NODE_B64=''
    if [ "$SEND_FULL" = 1 ] && [ -r "$NODE_FILE" ]; then NODE_B64="$(base64 "$NODE_FILE" | tr -d '\r\n')"; fi
    RESP="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 -X POST \
        "${WORKER_URL}/api/v1/report" \
        -H "X-Device-ID: $DEVICE_ID" \
        -H "Authorization: Bearer $DEVICE_TOKEN" \
        --data-urlencode "device_name=$DEVICE_NAME" \
        --data-urlencode "router_time=$NOW" \
        --data-urlencode "uptime_sec=$UPTIME_SEC" \
        --data-urlencode "boot_id=$BOOT_ID" \
        --data-urlencode "model=$MODEL" \
        --data-urlencode "firmware=$FIRMWARE" \
        --data-urlencode "mem_total_kb=$MEM_TOTAL" \
        --data-urlencode "mem_available_kb=$MEM_AVAIL" \
        --data-urlencode "mem_used_pct=$MEM_USED_PCT" \
        --data-urlencode "load1=$LOAD1" --data-urlencode "load5=$LOAD5" --data-urlencode "load15=$LOAD15" \
        --data-urlencode "node_config=1" \
        --data-urlencode "device_type=router" --data-urlencode "service_name=Xray" --data-urlencode "protocol_name=VLESS REALITY Vision" \
        --data-urlencode "udp_mode=vless-tunnel" --data-urlencode "temperature_source=$TEMP_SOURCE" \
        --data-urlencode "cpu_cores=$CPU_CORES" --data-urlencode "temperature_c=$TEMP_C" \
        --data-urlencode "overlay_used_pct=$OVERLAY_PCT" \
        --data-urlencode "wan_if=$WAN4_IF" --data-urlencode "wan_dev=$WAN_DEV" \
        --data-urlencode "network_type=$NETWORK_TYPE" \
        --data-urlencode "local4=$LOCAL4" --data-urlencode "public4=$PUBLIC4" \
        --data-urlencode "local6=$LOCAL6" --data-urlencode "public6=$PUBLIC6" \
        --data-urlencode "ddns_domain=${DOMAIN}.duckdns.org" --data-urlencode "ddns_mode=$DDNS_MODE" \
        --data-urlencode "ddns_ok=$DDNS_OK" --data-urlencode "ddns_failures=$DDNS_FAILURES" \
        --data-urlencode "singbox_running=$SING_RUNNING" --data-urlencode "tcp_listen=$TCP_OK" \
        --data-urlencode "udp_listen=$UDP_OK" --data-urlencode "ss_port=$SS_PORT" \
        --data-urlencode "wan_rx_bytes=$WAN_RX" --data-urlencode "wan_tx_bytes=$WAN_TX" \
        --data-urlencode "auto_restarted=0" --data-urlencode "alerts=$ALERTS" \
        --data-urlencode "full=$SEND_FULL" --data-urlencode "node_b64=$NODE_B64" 2>/dev/null || true)"
    OK="$(printf '%s' "$RESP" | jsonfilter -e '@.ok' 2>/dev/null || true)"
    if [ "$OK" != 'true' ]; then
        CF_FAILURES=$((CF_FAILURES + 1)); [ "$CF_FAILURES" -le 20 ] || CF_FAILURES=20
        out "Cloudflare上报失败：${RESP:-无响应}"
        return 1
    fi
    CF_FAILURES=0
    if [ "$SEND_FULL" = 1 ]; then LAST_FULL="$NOW"; LAST_NODE_CKSUM="$NODE_CKSUM"; fi
    REFRESH="$(printf '%s' "$RESP" | jsonfilter -e '@.refresh' 2>/dev/null || true)"
    out "状态上报成功；异常=${ALERTS:-无}；完整=$SEND_FULL"
    [ "$REFRESH" = 'true' ] && [ "$SEND_FULL" != 1 ] && return 2
    return 0
}

RESULT=0
send_report "$FULL" || RESULT=$?
if [ "$RESULT" = 2 ]; then send_report 1 || true; fi
save_state
[ "$RESULT" = 1 ] && exit 1
exit 0
EOF
    chmod 700 /usr/bin/home-monitor

    cat > /usr/bin/home-monitor-pair <<'EOF'
#!/bin/sh
set -eu
MON_CONF='/etc/home-ss/monitor.conf'
SS_CONF='/etc/home-ss/settings.conf'
NODE_FILE='/root/home-ss-node.txt'
OLD_URL=''; OLD_NAME='home-router'
if [ -r "$MON_CONF" ]; then
    . "$MON_CONF"
    OLD_URL="${WORKER_URL:-}"
    [ -n "${DEVICE_NAME_B64:-}" ] && OLD_NAME="$(printf '%s' "$DEVICE_NAME_B64" | base64 -d 2>/dev/null || printf 'home-router')"
fi
WORKER="${PAIR_WORKER_URL:-}"
NAME="${PAIR_DEVICE_NAME:-}"
CODE="${PAIR_CODE:-}"
if [ -z "$WORKER" ]; then printf 'Cloudflare 监控入口 [%s]：' "$OLD_URL"; IFS= read -r WORKER; WORKER="${WORKER:-$OLD_URL}"; fi
if [ -z "$NAME" ]; then printf '设备名称 [%s]：' "$OLD_NAME"; IFS= read -r NAME; NAME="${NAME:-$OLD_NAME}"; fi
if [ -z "$CODE" ]; then printf 'Telegram 中生成的一次性配对码：'; IFS= read -r CODE; fi
WORKER="${WORKER%/}"
printf '%s' "$WORKER" | grep -Eq '^https://[A-Za-z0-9._:-]+$' || { echo 'Cloudflare入口格式不正确' >&2; exit 1; }
[ -n "$NAME" ] && [ "$(printf '%s' "$NAME" | wc -c)" -le 48 ] || { echo '设备名称不正确' >&2; exit 1; }
CODE="$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
[ "${#CODE}" = 8 ] || { echo '配对码格式不正确' >&2; exit 1; }
NODE_B64=''; [ -r "$NODE_FILE" ] && NODE_B64="$(base64 "$NODE_FILE" | tr -d '\r\n')"
SS_PORT=''; [ -r "$SS_CONF" ] && . "$SS_CONF"
RESP="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 -X POST \
    "${WORKER}/api/v1/enroll" \
    --data-urlencode "pair_code=$CODE" --data-urlencode "device_name=$NAME" \
    --data-urlencode "ss_port=${SS_PORT:-}" --data-urlencode "node_b64=$NODE_B64" 2>/dev/null || true)"
OK="$(printf '%s' "$RESP" | jsonfilter -e '@.ok' 2>/dev/null || true)"
[ "$OK" = 'true' ] || { echo "配对失败：${RESP:-Cloudflare无响应}" >&2; exit 1; }
ID="$(printf '%s' "$RESP" | jsonfilter -e '@.device_id')"
TOKEN="$(printf '%s' "$RESP" | jsonfilter -e '@.device_token')"
printf '%s' "$ID" | grep -Eq '^[a-f0-9]{16}$' || { echo '设备 ID 格式不正确'; exit 1; }
printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9_-]{32,}$' || { echo '设备 Token 格式不正确'; exit 1; }
NAME_B64="$(printf '%s' "$NAME" | base64 | tr -d '\r\n')"
mkdir -p /etc/home-ss; umask 077; T="$MON_CONF.tmp.$$"
cat > "$T" <<CONF
MONITOR_ENABLED='1'
REMOTE_CONTROL='1'
WORKER_URL='$WORKER'
DEVICE_NAME_B64='$NAME_B64'
DEVICE_ID='$ID'
DEVICE_TOKEN='$TOKEN'
CONF
chmod 600 "$T"; mv "$T" "$MON_CONF"
echo "配对成功：$NAME（设备ID：$ID）"
/usr/bin/home-monitor --full --verbose || {
    sed -i "s/^MONITOR_ENABLED=.*/MONITOR_ENABLED='0'/" "$MON_CONF"
    echo '首次上报失败，监控保持禁用；请检查入口后重新运行 home-monitor-pair' >&2
    exit 1
}
EOF
    chmod 700 /usr/bin/home-monitor-pair

    cat > /usr/bin/home-agent-tick <<'EOF'
#!/bin/sh
umask 077
exec 9>/tmp/home-agent-tick.flock
flock -n 9 || exit 0

# Avoid racing configuration edits; preserve their process-owned lock.
exec 6>/tmp/node-config.flock
flock -n 6 || exit 0
. /etc/home-ss/settings.conf
. /usr/libexec/home-node/network.sh
hn_firewall "$SS_PORT" >/dev/null 2>&1 || true
case " $* " in
    *" --verbose "*) /usr/bin/home-ddns-update "$@" || true; /usr/bin/home-monitor --verbose || true;;
    *) /usr/bin/home-ddns-update "$@" >/dev/null 2>&1 || true; /usr/bin/home-monitor >/dev/null 2>&1 || true;;
esac
EOF
    chmod 700 /usr/bin/home-agent-tick
}

write_command_agent() {
    say
    say "========== 12A. 安装 Telegram root 远控代理 =========="

    cat > /usr/bin/home-command-agent <<'EOF_COMMAND_AGENT'
#!/bin/sh
umask 077
CONF='/etc/home-ss/monitor.conf'
SS_CONF='/etc/home-ss/settings.conf'
exec 9>/tmp/home-command-agent.flock
flock -n 9 || exit 0
trap 'exit 130' INT
trap 'exit 143' TERM

load_identity() {
    [ -r "$CONF" ] && [ -r "$SS_CONF" ] || return 1
    . "$CONF"
    . "$SS_CONF"
    [ "${MONITOR_ENABLED:-0}" = 1 ] || return 1
    [ "${REMOTE_CONTROL:-0}" = 1 ] || return 1
    [ -n "${WORKER_URL:-}" ] && [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ] || return 1
    return 0
}

safe_status() {
    echo "时间：$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
    echo "主机：$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo OpenWrt)"
    if [ -r /etc/openwrt_release ]; then
        . /etc/openwrt_release
        echo "系统：${DISTRIB_DESCRIPTION:-OpenWrt}"
    else
        echo "系统：OpenWrt"
    fi
    echo "内核：$(uname -r 2>/dev/null || echo 未知)"
    echo "运行时间：$(awk '{printf "%d 秒",$1}' /proc/uptime 2>/dev/null || echo 未知)"
    /etc/init.d/home-node running >/dev/null 2>&1 && echo "Xray：运行中" || echo "Xray：已停止"
    echo "Xray版本：$(/usr/libexec/home-node/xray version 2>/dev/null | sed -n '1p' || echo 未知)"
    echo "VLESS TCP 端口：${SS_PORT:-未知}"
    if [ -n "${SS_PORT:-}" ]; then
        TCP="否"; UDP="否"
        netstat -ln 2>/dev/null | awk -v p=":$SS_PORT" '$1~/^tcp/ && $4~p"$"{f=1}END{exit !f}' && TCP="是"
        netstat -ln 2>/dev/null | awk -v p=":$SS_PORT" '$1~/^udp/ && $4~p"$"{f=1}END{exit !f}' && UDP="是"
        echo "TCP监听：$TCP；UDP：VLESS 隧道支持（不是独立 UDP 监听检测）"
    fi
    /usr/local/sbin/node-temperature
    /usr/local/sbin/node-net-optimize status
    echo "DDNS：${DOMAIN:-未知}.duckdns.org"
    echo
    echo "负载：$(cat /proc/loadavg 2>/dev/null || echo 未知)"
    command -v free >/dev/null 2>&1 && free 2>/dev/null || true
    echo
    df -h /overlay 2>/dev/null || df -h / 2>/dev/null || true
    echo
    ip -br addr 2>/dev/null || ip addr 2>/dev/null | sed -n '1,80p'
}

run_shell_timeout() {
    PAYLOAD="$1"
    OUT="$2"
    STATUS_FILE="${OUT}.status"
    rm -f "$STATUS_FILE"
    (
        exec 9>&-
        timeout -k 5 120 /bin/sh -c "$PAYLOAD"
        printf '%s\n' "$?" > "$STATUS_FILE"
    ) 2>&1 | timeout -k 5 125 /bin/sh -c 'head -c 60000; cat >/dev/null' > "$OUT"
    RC="$(cat "$STATUS_FILE" 2>/dev/null || printf 124)"
    rm -f "$STATUS_FILE"
    return "$RC"
}

run_command() {
    ACTION="$1"; PAYLOAD="$2"; OUT="$3"
    COMMAND_EXIT=0
    REBOOT_AFTER_RESULT=0
    case "$ACTION" in
        node_config)
            printf '%s' "$PAYLOAD" | timeout -k 10 240 /usr/local/sbin/node-config >"$OUT" 2>&1 || COMMAND_EXIT=$?
            ;;
        status)
            safe_status >"$OUT" 2>&1 || COMMAND_EXIT=$?
            ;;
        refresh)
            {
                echo '正在实时刷新路由器状态与节点信息...'
                /usr/bin/home-monitor --full --verbose
                echo '实时刷新完成'
            } >"$OUT" 2>&1 || COMMAND_EXIT=$?
            ;;
        restart_singbox|restart_xray)
            (
                echo '正在重启家宽 Xray...'
                /etc/init.d/home-node restart
                sleep 3
                if /etc/init.d/home-node running >/dev/null 2>&1; then echo 'Xray：运行中'; else echo 'Xray：启动失败'; exit 1; fi
                netstat -ln 2>/dev/null | grep -E ":${SS_PORT:-38443}([[:space:]]|$)" || true
            ) >"$OUT" 2>&1 || COMMAND_EXIT=$?
            ;;
        ddns_refresh)
            {
                echo '正在强制刷新 DuckDNS 并立即上报状态...'
                HOME_DDNS_FORCE=1 /usr/bin/home-ddns-update --verbose
                /usr/bin/home-monitor --full --verbose || true
            } >"$OUT" 2>&1 || COMMAND_EXIT=$?
            ;;
        reboot)
            printf '%s\n' '已接受重启命令，路由器将在回执发送后约 3 秒重启。' >"$OUT"
            REBOOT_AFTER_RESULT=1
            ;;
        shell)
            {
                echo "root shell> $PAYLOAD"
                echo
            } >"$OUT"
            TMP_OUT="${OUT}.shell"
            : > "$TMP_OUT"
            run_shell_timeout "$PAYLOAD" "$TMP_OUT" || COMMAND_EXIT=$?
            cat "$TMP_OUT" >> "$OUT"
            rm -f "$TMP_OUT"
            ;;
        *)
            printf '拒绝未知操作：%s\n' "$ACTION" >"$OUT"
            COMMAND_EXIT=64
            ;;
    esac
}

submit_result() {
    COMMAND_ID="$1"; EXIT_CODE="$2"; OUT="$3"
    CLIP="${OUT}.clip"
    head -c 60000 "$OUT" > "$CLIP" 2>/dev/null || dd if="$OUT" of="$CLIP" bs=60000 count=1 2>/dev/null || true
    RESULT_B64="$(base64 "$CLIP" 2>/dev/null | tr -d '\r\n')"
    rm -f "$CLIP"
    RESULT_NODE_B64=''
    if [ "${ACTION:-}" = node_config ] && [ "${EXIT_CODE}" = 0 ]; then
        RESULT_NODE_B64="$(base64 /root/home-ss-node.txt | tr -d '\r\n')"
    fi
    ATTEMPT=1
    while [ "$ATTEMPT" -le 5 ]; do
        RESP="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 25 -X POST \
            "${WORKER_URL}/api/v1/command/result" \
            -H "X-Device-ID: ${DEVICE_ID}" \
            -H "Authorization: Bearer ${DEVICE_TOKEN}" \
            --data-urlencode "command_id=${COMMAND_ID}" \
            --data-urlencode "exit_code=${EXIT_CODE}" \
            --data-urlencode "node_b64=${RESULT_NODE_B64}" \
            --data-urlencode "result_b64=${RESULT_B64}" 2>/dev/null || true)"
        OK="$(printf '%s' "$RESP" | jsonfilter -e '@.ok' 2>/dev/null || true)"
        [ "$OK" = true ] && return 0
        sleep $((ATTEMPT * 2))
        ATTEMPT=$((ATTEMPT + 1))
    done
    return 1
}

poll_once() {
    load_identity || return 1
    RESP="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 20 -X POST \
        "${WORKER_URL}/api/v1/command/poll" \
        -H "X-Device-ID: ${DEVICE_ID}" \
        -H "Authorization: Bearer ${DEVICE_TOKEN}" -d '' 2>/dev/null || true)"
    OK="$(printf '%s' "$RESP" | jsonfilter -e '@.ok' 2>/dev/null || true)"
    [ "$OK" = true ] || return 1
    COMMAND_ID="$(printf '%s' "$RESP" | jsonfilter -e '@.command.id' 2>/dev/null || true)"
    [ -n "$COMMAND_ID" ] || return 2
    ACTION="$(printf '%s' "$RESP" | jsonfilter -e '@.command.action' 2>/dev/null || true)"
    PAYLOAD="$(printf '%s' "$RESP" | jsonfilter -e '@.command.payload' 2>/dev/null || true)"
    printf '%s' "$COMMAND_ID" | grep -Eq '^[a-f0-9]{24}$' || return 1
    OUT="/tmp/home-command-output.$$"
    : > "$OUT"
    run_command "$ACTION" "$PAYLOAD" "$OUT"
    submit_result "$COMMAND_ID" "$COMMAND_EXIT" "$OUT" || true
    rm -f "$OUT" "${OUT}.shell" "${OUT}.clip"
    if [ "$REBOOT_AFTER_RESULT" = 1 ]; then
        ( sleep 3; reboot ) >/dev/null 2>&1 &
        sleep 1
        return 3
    fi
    return 0
}

while :; do
    RC=0
    poll_once || RC=$?
    case "$RC" in
        0) sleep 2 ;;
        2) sleep 10 ;;
        3) exit 0 ;;
        *) sleep 30 ;;
    esac
done
EOF_COMMAND_AGENT
    chmod 700 /usr/bin/home-command-agent

    cat > /etc/init.d/home-command-agent <<'EOF_COMMAND_INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=98
STOP=10

start_service() {
    [ -x /usr/bin/home-command-agent ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/home-command-agent
    procd_set_param respawn
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
EOF_COMMAND_INIT
    chmod 755 /etc/init.d/home-command-agent
}

configure_remote_control() {
    [ -x /etc/init.d/home-command-agent ] || return 0
    REMOTE_OK=0
    if [ -r "$MONITOR_CONF" ]; then
        # shellcheck disable=SC1090
        . "$MONITOR_CONF"
        [ "${MONITOR_ENABLED:-0}" = 1 ] && [ -n "${DEVICE_ID:-}" ] && [ -n "${DEVICE_TOKEN:-}" ] && REMOTE_OK=1
    fi
    if [ "$REMOTE_OK" = 1 ]; then
        CHECK="$(curl -fsS --noproxy '*' --connect-timeout 8 --max-time 25 -X POST "${WORKER_URL}/api/v1/command/check" -H "X-Device-ID: $DEVICE_ID" -H "Authorization: Bearer $DEVICE_TOKEN" -d '' 2>/dev/null || true)"
        [ "$(printf '%s' "$CHECK" | jsonfilter -e '@.ok' 2>/dev/null || true)" = true ] || die '远控鉴权/API/数据库预检失败，尚未完整安装'
        grep -q "^REMOTE_CONTROL='1'" "$MONITOR_CONF" || printf "REMOTE_CONTROL='1'\n" >> "$MONITOR_CONF"
        /etc/init.d/home-command-agent enable
        /etc/init.d/home-command-agent restart
        sleep 3
        RUN="$(ubus call service list '{"name":"home-command-agent"}' | jsonfilter -e '@["home-command-agent"].instances.*.running' 2>/dev/null || true)"
        [ "$RUN" = true ] || die '远控代理没有在 procd 中运行；整套安装未完成'
        REMOTE_READY=1
        say "Telegram root 远控开关=开启；服务运行、设备鉴权和命令 API 通过（尚需 TG 发一次 status 验收）"
    else
        /etc/init.d/home-command-agent disable >/dev/null 2>&1 || true
        /etc/init.d/home-command-agent stop >/dev/null 2>&1 || true
        die "Telegram root 远控未启用（设备尚未成功配对或监控已禁用）"
    fi
}

configure_schedule() {
    say
    say "========== 14. 最后启用定时任务 =========="
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/95-home-ddns <<'EOF'
#!/bin/sh
case "$ACTION" in
    ifup|ifupdate|ifdown)
        ( sleep 15; /usr/bin/home-agent-tick --event >/dev/null 2>&1 ) &
        ;;
esac
EOF
    chmod 700 /etc/hotplug.d/iface/95-home-ddns

    CRON_FILE='/etc/crontabs/root'
    touch "$CRON_FILE"
    sed -i '\|/usr/bin/home-ddns-update|d;\|/usr/bin/home-monitor|d;\|/usr/bin/home-agent-tick|d' "$CRON_FILE"
    printf '%s\n' '*/5 * * * * /usr/bin/home-agent-tick >/dev/null 2>&1' >> "$CRON_FILE"
    /etc/init.d/cron enable
    pidof crond >/dev/null 2>&1 || /etc/init.d/cron start
    pidof crond >/dev/null 2>&1 || die 'cron 未启动，整套安装未完成'
    say "已启用 5 分钟 DDNS/状态上报任务；root 远控由常驻代理约10秒轮询"
}

start_and_write_node() {
    if [ "${1:-}" != --node-only ]; then
        sh -n /etc/init.d/home-node
        /etc/init.d/home-node enable
        if /etc/init.d/home-node running >/dev/null 2>&1; then
            /etc/init.d/home-node restart > "$STAGE/service.log" 2>&1 || true
        else /etc/init.d/home-node start > "$STAGE/service.log" 2>&1 || true; fi
        local n=0 ready=0
        while [ "$n" -lt 15 ]; do
            if node_listening "$SS_PORT"; then ready=1; break; fi
            n=$((n+1)); sleep 1
        done
        [ "$ready" = 1 ] || { tail -n 30 "$STAGE/service.log" >&2; die "home-node/procd 未在 TCP $SS_PORT 运行；恢复本地备份"; }
        [ "${1:-}" != --service-only ] || return 0
    fi
    local mode node_tag uri_tag
    mode="$(cat "$MODE_FILE" 2>/dev/null || printf unknown)"
    node_tag="$(printf '%s' "$DEVICE_NAME" | tr '\r\n,' '   ')"
    uri_tag="$(jq -rn --arg s "$node_tag" '$s|@uri')"
    cat > "$NODE_FILE" <<EOF_NODE
Quantumult X（整行导入）：
vless=${DOMAIN}.duckdns.org:${SS_PORT}, method=none, password=${XRAY_UUID}, obfs=over-tls, obfs-host=${REALITY_SNI}, reality-base64-pubkey=${REALITY_PUBLIC_KEY}, reality-hex-shortid=${REALITY_SHORT_ID}, vless-flow=xtls-rprx-vision, udp-relay=true, fast-open=false, tag=${node_tag}

标准链接（圈 X 建议用上面的完整配置行）：
vless://${XRAY_UUID}@${DOMAIN}.duckdns.org:${SS_PORT}?encryption=none&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision#${uri_tag}
EOF_NODE
    chmod 600 "$NODE_FILE"
}

configure_monitoring() {
    if [ "$MONITOR_ENABLED" != 1 ]; then
        if [ -r "$MONITOR_CONF" ]; then
            sed -i "s/^MONITOR_ENABLED=.*/MONITOR_ENABLED='0'/" "$MONITOR_CONF"
        fi
        say "Cloudflare/Telegram监控已禁用；DuckDNS定时更新仍保留"
        return 0
    fi

    if [ "$REPAIR_MONITOR" = 1 ]; then
        say
        say "========== 13. 配对 Cloudflare/Telegram =========="
        printf '请现在在 Telegram 中获取一次性配对码并填写：'
        IFS= read -r PAIR_CODE
        PAIR_CODE="$(printf '%s' "$PAIR_CODE" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
        [ "${#PAIR_CODE}" = 8 ] || die "配对码格式不正确"

        if PAIR_WORKER_URL="$WORKER_URL" PAIR_DEVICE_NAME="$DEVICE_NAME" PAIR_CODE="$PAIR_CODE" \
            /usr/bin/home-monitor-pair; then
            say "Cloudflare 配对和首次完整上报均成功"
            return 0
        fi
        die '节点已运行，但配对或首次上报失败；没有完成整套安装。可重新运行本安装器保留节点重试'
    fi

    NAME_B64="$(printf '%s' "$DEVICE_NAME" | b64_encode)"
    umask 077
    T="$MONITOR_CONF.tmp.$$"
    cat > "$T" <<EOF
MONITOR_ENABLED='1'
REMOTE_CONTROL='1'
WORKER_URL='$WORKER_URL'
DEVICE_NAME_B64='$NAME_B64'
DEVICE_ID='$OLD_DEVICE_ID'
DEVICE_TOKEN='$OLD_DEVICE_TOKEN'
EOF
    chmod 600 "$T"
    mv "$T" "$MONITOR_CONF"

    if ! /usr/bin/home-monitor --full --verbose; then
        die '现有身份上报失败；请重新运行安装器并选择重新配对'
    fi
}

finish() {
    MODE="$(cat "$MODE_FILE" 2>/dev/null || true)"
    say
    say "================ 安装完成 ================"
    say "网络类型：$NET_TYPE"
    say "节点信息：$NODE_FILE"
    say "DDNS：${DOMAIN}.duckdns.org（${MODE:-未知}）"
    say "VLESS REALITY Vision：TCP $SS_PORT（U/V/R）"
    [ "$HAVE_V4" = 1 ] && say "SSH IPv4：ssh -4 root@${DOMAIN}.duckdns.org"
    [ "$HAVE_V6" = 1 ] && say "SSH IPv6：ssh -6 root@${DOMAIN}.duckdns.org"
    if [ "$MONITOR_ENABLED" = 1 ] && [ -r "$MONITOR_CONF" ]; then
        say "Telegram项目：节点中心 → ${DEVICE_NAME} → 远程控制"
        say "任意 root Shell：/router <设备ID> shell <命令>"
        say "立即检测：/usr/bin/home-agent-tick --verbose"
        say "远控代理：/etc/init.d/home-command-agent status"
    fi
    say "本方案不写持久运行日志；所有周期任务默认静默。"
    say "公网 SSH TCP 22 已保留；本脚本不修改现有 Dropbear 密码登录方式。"
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
    # 家宽官方下载慢时可由包内 Mac 辅助器预先上传；必须同时有 SHA256 清单才接受。
    if [ -s /tmp/home-node-xray ] && [ -s /tmp/home-node-xray.sha256 ] && \
       (cd /tmp && sha256sum -c home-node-xray.sha256 >/dev/null 2>&1) && suite_native /tmp/home-node-xray; then
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
if [ "$TYPE" = router ]; then
    HOST="$DOMAIN.duckdns.org"; LABEL=home-vless
    if [ -r /etc/home-ss/monitor.conf ]; then
        . /etc/home-ss/monitor.conf
        [ -z "${DEVICE_NAME_B64:-}" ] || LABEL="$(printf '%s' "$DEVICE_NAME_B64" | base64 -d 2>/dev/null || printf home-vless)"
    fi
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

# One detector for installation, DDNS, monitoring and interface events.
# Does not change routes, addresses, DHCP or IPv6 settings.
hn_public4() {
    printf '%s\n' "$1" | awk -F. '
    NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}
    $1==0||$1==10||$1==127||$1>=224{exit 1}
    $1==100&&$2>=64&&$2<=127{exit 1}
    $1==169&&$2==254{exit 1} $1==172&&$2>=16&&$2<=31{exit 1}
    $1==192&&($2==168||($2==0&&($3==0||$3==2))){exit 1}
    $1==198&&($2==18||$2==19||($2==51&&$3==100)){exit 1}
    $1==203&&$2==0&&$3==113{exit 1} {exit 0}'
}
hn_route_dev() {
    ip "-$1" route show table main default 2>/dev/null | awk '
    $1=="default" {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}
hn_network() {
    ubus call network.interface dump 2>/dev/null | jq -r --arg d "$1" \
      '[.interface[]? | select(.l3_device==$d or .device==$d) | .interface][0] // empty'
}
hn_detect() {
    HN_DEV4="$(hn_route_dev 4)"; HN_DEV6="$(hn_route_dev 6)"
    HN_IP4=''; HN_IP6=''; HN_ADDRDEV6=''
    if [ -n "$HN_DEV4" ]; then
        HN_IP4="$(ip -4 addr show dev "$HN_DEV4" scope global 2>/dev/null | awk '$1=="inet"{split($2,a,"/");print a[1];exit}')"
    fi
    if [ -n "$HN_DEV6" ]; then
        # Prefer stable GUA on uplink, then a routed GUA on another local physical/bridge interface.
        for hn_dev in "$HN_DEV6" $(ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/,"",$2);print $2}'); do
            case "$hn_dev" in lo|tun*|tap*|wg*|tailscale*|docker*|veth*) continue;; esac
            hn_ip="$(ip -6 addr show dev "$hn_dev" scope global 2>/dev/null | awk '
              $1=="inet6" && $0!~/tentative|dadfailed|deprecated/ {
                split($2,a,"/"); if(a[1]~/^[23]/){if($0!~/temporary/){print a[1];f=1;exit}; if(t=="")t=a[1]}}
              END {if(t!="" && !f)print t}')"
            [ -n "$hn_ip" ] || continue
            # Address must have an outbound route; never pick a stale prefix or VPN address.
            if ip -6 route get 2606:4700:4700::1111 from "$hn_ip" 2>/dev/null | grep -q ' dev '; then
                HN_IP6="$hn_ip"; HN_ADDRDEV6="$hn_dev"; break
            fi
        done
    fi
    HN_NET4="$(hn_network "$HN_DEV4")"; HN_NET6="$(hn_network "$HN_DEV6")"
    HN_TOPOLOGY="$( { printf '%s\n' "$HN_DEV4|$HN_IP4|$HN_DEV6|$HN_IP6"; ip -4 route show table main default; ip -6 route show table main default; } 2>/dev/null | sha256sum | awk '{print $1}')"
}
hn_external4() {
    local hn_v hn_url
    for hn_url in https://api.ipify.org https://ipv4.icanhazip.com; do
        hn_v="$(curl -4fsS --noproxy '*' --interface "$HN_DEV4" --connect-timeout 4 --max-time 8 "$hn_url" 2>/dev/null | tr -d '[:space:]' || true)"
        if hn_public4 "$hn_v"; then printf '%s\n' "$hn_v"; return 0; fi
    done
    return 1
}
hn_zones() {
    local hn_sec hn_name hn_net hn_dev hn_n hn_d
    for hn_sec in $(uci -q show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
        hn_name="$(uci -q get "firewall.$hn_sec.name" || true)"
        hn_net="$(uci -q get "firewall.$hn_sec.network" || true)"
        hn_dev="$(uci -q get "firewall.$hn_sec.device" || true)"
        for hn_n in $hn_net; do
            if [ -n "$hn_n" ] && { [ "$hn_n" = "$HN_NET4" ] || [ "$hn_n" = "$HN_NET6" ]; }; then printf '%s\n' "$hn_name"; break; fi
        done
        for hn_d in $hn_dev; do
            case "$HN_DEV4" in $hn_d) printf '%s\n' "$hn_name";; esac
            case "$HN_DEV6" in $hn_d) printf '%s\n' "$hn_name";; esac
        done
    done | sort -u
}
hn_firewall() (
    # Only task-owned TCP input rules. No LAN policy, forwarding or SSH service changes.
    set -eu
    exec 7>/tmp/home-node-firewall.flock
    flock 7 || { echo '防火墙更新忙，请稍后重试' >&2; exit 1; }
    hn_detect
    zones="$(hn_zones)"
    [ -n "$zones" ] || { echo '未识别到出口防火墙区域；保留原规则' >&2; exit 1; }
    port="$1"
    case "$port" in ''|*[!0-9]*) exit 1;; esac
    [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 1
    sig="$zones:$port"
    if [ -r /tmp/home-node-firewall.signature ] && [ "$(cat /tmp/home-node-firewall.signature)" = "$sig" ]; then
        valid=1
        for zone in $zones; do
            for p in "$port" 22; do
                nft list chain inet fw4 "input_$zone" 2>/dev/null | grep -F "home-suite-node-$p-$zone" | grep -q accept || valid=0
            done
        done
        [ "$valid" = 0 ] || exit 0
    fi
    [ -z "$(uci -q changes firewall)" ] || { echo '防火墙存在未提交更改，暂缓同步' >&2; exit 1; }
    backup="$(mktemp /tmp/home-node-fw.XXXXXX)" || exit 1
    cp -p /etc/config/firewall "$backup" || exit 1
    ok=0; changed=0
    trap 'if [ "$ok" = 0 ] && [ "$changed" = 1 ]; then cp -p "$backup" /etc/config/firewall; uci -q revert firewall; /etc/init.d/firewall reload >/dev/null 2>&1 || true; fi; rm -f "$backup"' EXIT
    changed=1
    for sec in $(uci -q show firewall | sed -n 's/^firewall\.\(home_vless_[0-9]*\|home_ssh_[0-9]*\)=rule$/\1/p'); do uci -q delete "firewall.$sec" || exit 1; done
    i=0
    for zone in $zones; do
        i=$((i+1))
        for kind in vless ssh; do
            p="$port"; [ "$kind" != ssh ] || p=22
            sec="home_${kind}_$i"
            uci set "firewall.$sec=rule" || exit 1
            uci set "firewall.$sec.name=home-suite-node-$p-$zone" || exit 1
            uci set "firewall.$sec.src=$zone" || exit 1
            uci set "firewall.$sec.proto=tcp" || exit 1
            uci set "firewall.$sec.dest_port=$p" || exit 1
            uci set "firewall.$sec.family=any" || exit 1
            uci set "firewall.$sec.target=ACCEPT" || exit 1
        done
    done
    fw4 check >/dev/null 2>&1 || exit 1
    uci commit firewall || exit 1
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    for zone in $zones; do
        for p in "$port" 22; do
            nft list chain inet fw4 "input_$zone" 2>/dev/null | grep -F "home-suite-node-$p-$zone" | grep -q accept || exit 1
        done
    done
    printf '%s\n' "$sig" > /tmp/home-node-firewall.signature
    ok=1
)

write_network_library() {
    mkdir -p '/usr/libexec/home-node'
    cat > '/usr/libexec/home-node/network.sh' <<'EOF_NETWORK_LIBRARY'
# One detector for installation, DDNS, monitoring and interface events.
# Does not change routes, addresses, DHCP or IPv6 settings.
hn_public4() {
    printf '%s\n' "$1" | awk -F. '
    NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}
    $1==0||$1==10||$1==127||$1>=224{exit 1}
    $1==100&&$2>=64&&$2<=127{exit 1}
    $1==169&&$2==254{exit 1} $1==172&&$2>=16&&$2<=31{exit 1}
    $1==192&&($2==168||($2==0&&($3==0||$3==2))){exit 1}
    $1==198&&($2==18||$2==19||($2==51&&$3==100)){exit 1}
    $1==203&&$2==0&&$3==113{exit 1} {exit 0}'
}
hn_route_dev() {
    ip "-$1" route show table main default 2>/dev/null | awk '
    $1=="default" {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}
hn_network() {
    ubus call network.interface dump 2>/dev/null | jq -r --arg d "$1" \
      '[.interface[]? | select(.l3_device==$d or .device==$d) | .interface][0] // empty'
}
hn_detect() {
    HN_DEV4="$(hn_route_dev 4)"; HN_DEV6="$(hn_route_dev 6)"
    HN_IP4=''; HN_IP6=''; HN_ADDRDEV6=''
    if [ -n "$HN_DEV4" ]; then
        HN_IP4="$(ip -4 addr show dev "$HN_DEV4" scope global 2>/dev/null | awk '$1=="inet"{split($2,a,"/");print a[1];exit}')"
    fi
    if [ -n "$HN_DEV6" ]; then
        # Prefer stable GUA on uplink, then a routed GUA on another local physical/bridge interface.
        for hn_dev in "$HN_DEV6" $(ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/,"",$2);print $2}'); do
            case "$hn_dev" in lo|tun*|tap*|wg*|tailscale*|docker*|veth*) continue;; esac
            hn_ip="$(ip -6 addr show dev "$hn_dev" scope global 2>/dev/null | awk '
              $1=="inet6" && $0!~/tentative|dadfailed|deprecated/ {
                split($2,a,"/"); if(a[1]~/^[23]/){if($0!~/temporary/){print a[1];f=1;exit}; if(t=="")t=a[1]}}
              END {if(t!="" && !f)print t}')"
            [ -n "$hn_ip" ] || continue
            # Address must have an outbound route; never pick a stale prefix or VPN address.
            if ip -6 route get 2606:4700:4700::1111 from "$hn_ip" 2>/dev/null | grep -q ' dev '; then
                HN_IP6="$hn_ip"; HN_ADDRDEV6="$hn_dev"; break
            fi
        done
    fi
    HN_NET4="$(hn_network "$HN_DEV4")"; HN_NET6="$(hn_network "$HN_DEV6")"
    HN_TOPOLOGY="$( { printf '%s\n' "$HN_DEV4|$HN_IP4|$HN_DEV6|$HN_IP6"; ip -4 route show table main default; ip -6 route show table main default; } 2>/dev/null | sha256sum | awk '{print $1}')"
}
hn_external4() {
    local hn_v hn_url
    for hn_url in https://api.ipify.org https://ipv4.icanhazip.com; do
        hn_v="$(curl -4fsS --noproxy '*' --interface "$HN_DEV4" --connect-timeout 4 --max-time 8 "$hn_url" 2>/dev/null | tr -d '[:space:]' || true)"
        if hn_public4 "$hn_v"; then printf '%s\n' "$hn_v"; return 0; fi
    done
    return 1
}
hn_zones() {
    local hn_sec hn_name hn_net hn_dev hn_n hn_d
    for hn_sec in $(uci -q show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
        hn_name="$(uci -q get "firewall.$hn_sec.name" || true)"
        hn_net="$(uci -q get "firewall.$hn_sec.network" || true)"
        hn_dev="$(uci -q get "firewall.$hn_sec.device" || true)"
        for hn_n in $hn_net; do
            if [ -n "$hn_n" ] && { [ "$hn_n" = "$HN_NET4" ] || [ "$hn_n" = "$HN_NET6" ]; }; then printf '%s\n' "$hn_name"; break; fi
        done
        for hn_d in $hn_dev; do
            case "$HN_DEV4" in $hn_d) printf '%s\n' "$hn_name";; esac
            case "$HN_DEV6" in $hn_d) printf '%s\n' "$hn_name";; esac
        done
    done | sort -u
}
hn_firewall() (
    # Only task-owned TCP input rules. No LAN policy, forwarding or SSH service changes.
    set -eu
    exec 7>/tmp/home-node-firewall.flock
    flock 7 || { echo '防火墙更新忙，请稍后重试' >&2; exit 1; }
    hn_detect
    zones="$(hn_zones)"
    [ -n "$zones" ] || { echo '未识别到出口防火墙区域；保留原规则' >&2; exit 1; }
    port="$1"
    case "$port" in ''|*[!0-9]*) exit 1;; esac
    [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 1
    sig="$zones:$port"
    if [ -r /tmp/home-node-firewall.signature ] && [ "$(cat /tmp/home-node-firewall.signature)" = "$sig" ]; then
        valid=1
        for zone in $zones; do
            for p in "$port" 22; do
                nft list chain inet fw4 "input_$zone" 2>/dev/null | grep -F "home-suite-node-$p-$zone" | grep -q accept || valid=0
            done
        done
        [ "$valid" = 0 ] || exit 0
    fi
    [ -z "$(uci -q changes firewall)" ] || { echo '防火墙存在未提交更改，暂缓同步' >&2; exit 1; }
    backup="$(mktemp /tmp/home-node-fw.XXXXXX)" || exit 1
    cp -p /etc/config/firewall "$backup" || exit 1
    ok=0; changed=0
    trap 'if [ "$ok" = 0 ] && [ "$changed" = 1 ]; then cp -p "$backup" /etc/config/firewall; uci -q revert firewall; /etc/init.d/firewall reload >/dev/null 2>&1 || true; fi; rm -f "$backup"' EXIT
    changed=1
    for sec in $(uci -q show firewall | sed -n 's/^firewall\.\(home_vless_[0-9]*\|home_ssh_[0-9]*\)=rule$/\1/p'); do uci -q delete "firewall.$sec" || exit 1; done
    i=0
    for zone in $zones; do
        i=$((i+1))
        for kind in vless ssh; do
            p="$port"; [ "$kind" != ssh ] || p=22
            sec="home_${kind}_$i"
            uci set "firewall.$sec=rule" || exit 1
            uci set "firewall.$sec.name=home-suite-node-$p-$zone" || exit 1
            uci set "firewall.$sec.src=$zone" || exit 1
            uci set "firewall.$sec.proto=tcp" || exit 1
            uci set "firewall.$sec.dest_port=$p" || exit 1
            uci set "firewall.$sec.family=any" || exit 1
            uci set "firewall.$sec.target=ACCEPT" || exit 1
        done
    done
    fw4 check >/dev/null 2>&1 || exit 1
    uci commit firewall || exit 1
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    for zone in $zones; do
        for p in "$port" 22; do
            nft list chain inet fw4 "input_$zone" 2>/dev/null | grep -F "home-suite-node-$p-$zone" | grep -q accept || exit 1
        done
    done
    printf '%s\n' "$sig" > /tmp/home-node-firewall.signature
    ok=1
)
EOF_NETWORK_LIBRARY
    chmod 700 '/usr/libexec/home-node/network.sh'
}

need_root
install_packages
read_settings
read_monitor_settings
detect_network
preflight_firewall
check_monitor_endpoint
check_existing_node
choose_port
prepare_router_reality
if [ "$PREFLIGHT_ONLY" = 1 ]; then say '预检完成；未写入业务配置、未更新 DDNS、未配对，缺失软件包已补齐。'; exit 0; fi
confirm_install
prepare_transaction
write_xray
start_and_write_node --service-only
configure_firewall
write_ddns_updater
write_monitor_agent
write_command_agent
rm -f /tmp/home-ddns-state /tmp/home-monitor-state
# Local service and firewall have passed; pairing/DNS failures must not tear down a working node.
TX_ACTIVE=0
suite_optional_drivers
if [ "$ENABLE_BBR" = 1 ]; then /usr/local/sbin/node-net-optimize auto || warn '可选网络优化未完整应用，节点继续运行'; fi
/usr/local/sbin/node-temperature
HOME_DDNS_FORCE=1 /usr/bin/home-ddns-update --verbose || die "节点已运行，但 DuckDNS 首次更新失败；整套安装未完成，重跑可继续"
start_and_write_node --node-only
configure_monitoring
configure_remote_control
configure_schedule
say "本次本地备份：$TX_DIR（包含凭据，请只由 root 保管；不含外部 DuckDNS/云端回滚）"
finish
