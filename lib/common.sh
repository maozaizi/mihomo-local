#!/bin/sh
# MLOCAL_ROOT/PATH/API are reserved for isolated tests, never systemd input.
R=${MLOCAL_ROOT:-}
export PATH=${MLOCAL_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
umask 077
NL_VERSION=1.0.1
NL_PKG=${MIHOMO_LOCAL_LIB:-/usr/local/lib/mihomo-local/current}
NL_LIB=$NL_PKG/lib
NL_HOME=$R/var/lib/mihomo-local/state
NL_STORE=$NL_HOME/subscriptions
NL_LOG=$NL_HOME/updates.log
NL_RUN_DIR=$R/var/lib/mihomo-local/core
NL_RUN=$R/etc/mihomo-local/config.yaml
NL_SUB_PROVIDER=subscriptions
NL_SUB_TARGET=$NL_RUN_DIR/providers/subscriptions.yaml
NL_SUB_EMPTY=__mihomo_local_empty__
NL_API=${MLOCAL_API:-http://127.0.0.1:9090}
NL_MAX_BYTES=8388608
NL_MAX_NODES=4096
nl_fail() { printf '%s：%s\n' "${NL_TAG:-mihomo-local}" "$*" >&2; exit 1; }
nl_scratch() { mktemp -d "${TMPDIR:-/tmp}/mihomo-local.XXXXXX"; }
nl_need_admin() { [ "$(id -u)" = 0 ] || [ -n "$R" ] || nl_fail '请通过 sudo 执行订阅管理命令。'; }
nl_lock() {
    if [ "${MLOCAL_LOCKED:-0}" = 1 ]; then
        ( : >&5 ) 2>/dev/null && flock -n 5 || nl_fail '操作锁继承失败。'
        return
    fi
    mkdir -p "$NL_HOME"; chmod 700 "$NL_HOME"
    exec 5>"$NL_HOME/operation.lock"
    flock -n 5 || nl_fail '另一个操作正在执行，请稍后重试。'
    MLOCAL_LOCKED=1; export MLOCAL_LOCKED
}
# Deliberately fail closed: this product supports local explicit proxies only.
nl_assert_config() {
    [ -f "$NL_RUN" ] || { echo '请先执行 mihomo-local init。' >&2; return 1; }
    [ "$(yq e 'has("tun") == false and has("listeners") == false and has("tunnels") == false and has("redir-port") == false and has("tproxy-port") == false and has("port") == false and has("socks-port") == false and ."mixed-port" == 7890 and ."bind-address" == "127.0.0.1" and ."allow-lan" == false and ."external-controller" == "127.0.0.1:9090" and .mode == "rule" and (.secret | type) == "!!str" and (.secret | test("^[a-zA-Z0-9]{32,}$")) and (.dns.listen == null or .dns.listen == "") and .dns."enhanced-mode" != "fake-ip" and ."proxy-providers".subscriptions.type == "file" and ."proxy-providers".subscriptions.path == "./providers/subscriptions.yaml"' "$NL_RUN" 2>/dev/null)" = true ] || {
        echo '配置不符合本机显式代理边界；拒绝启动或发布。请检查模板约束。' >&2; return 1;
    }
}
nl_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$NL_LOG" || return 1
    tail -n 200 "$NL_LOG" > "$NL_LOG.tmp" && mv -f "$NL_LOG.tmp" "$NL_LOG"
}
nl_put() {
    put_tmp=$(mktemp "$(dirname "$2")/.mlocal.XXXXXX") || return 1
    if cp "$1" "$put_tmp"; then
        case "$2" in "$NL_SUB_TARGET"|"$NL_RUN")
            if [ -z "$R" ]; then chown root:mihomo-local "$put_tmp" || return 1; fi
            chmod 640 "$put_tmp";;
        *) chmod 600 "$put_tmp";; esac
        if mv -f "$put_tmp" "$2"; then return 0; fi
    fi
    rm -f "$put_tmp"; return 1
}
nl_placeholder() { printf 'proxies:\n  - name: %s\n    type: reject\n' "$1" > "$2"; }
nl_download_once() (
    url=$1; out=$2; scratch=$3
    cr=$(printf '\r')
    case "$url" in https://*) ;; *) return 3;; esac
    case "$url" in *'"'*|*'\'*|*'
'*|*"$cr"*) return 3;; esac
    printf 'url = "%s"\n' "$url" > "$scratch/download.conf" || return 23
    if [ "$4" = proxy ]; then
        printf 'proxy = "http://127.0.0.1:7890"\nnoproxy = ""\n' >> "$scratch/download.conf"
    else
        printf 'noproxy = "*"\n' >> "$scratch/download.conf"
    fi
    rm -f "$scratch/download.status"
    if ! (
        code=0
        timeout 130 curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 60 --retry 0 --max-filesize "$NL_MAX_BYTES" \
            -A Clash.Meta --config "$scratch/download.conf" -o - 2>/dev/null || code=$?
        printf '%s\n' "$code" > "$scratch/download.status"
    ) | head -c "$((NL_MAX_BYTES + 1))" > "$out"; then return 23; fi
    [ "$(wc -c < "$out")" -le "$NL_MAX_BYTES" ] || return 63
    [ -s "$scratch/download.status" ] || return 23
    code=$(cat "$scratch/download.status")
    case "$code" in 0|3|6|22|23|28|35|51|60|63) return "$code";; 124|137|143) return 28;; *) return 1;; esac
)

# A timer has no interactive shell proxy environment. Prefer direct access;
# retry through our own explicit loopback proxy, never a conversion service.
nl_download() {
    dl_code=0
    nl_download_once "$1" "$2" "$3" direct || dl_code=$?
    case "$dl_code" in
        0) return 0;;
        3|63) return "$dl_code";;
    esac
    nl_download_once "$1" "$2" "$3" proxy
}
