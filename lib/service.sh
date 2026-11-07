#!/bin/sh
set -eu
. "${MIHOMO_LOCAL_LIB:-/usr/local/lib/mihomo-local/current}/lib/common.sh"
. "$NL_LIB/core.sh"
. "$NL_LIB/resources.sh"
nl_need_admin
cmd=${1:-}; shift
case "$cmd" in
init)
    [ "$#" -eq 0 ] || nl_fail 'init 不接受参数；初始化后用 sub add 添加订阅。'
    nl_lock
    for dep in curl yq mihomo timeout flock unzip; do command -v "$dep" >/dev/null || nl_fail "缺少依赖：$dep"; done
    resume=no
    if [ -e "$NL_RUN" ]; then
        nl_assert_config || exit 1
        [ -L "$NL_STORE/current" ] || nl_fail '发现已有配置但订阅清单缺失；拒绝覆盖，请检查备份。'
        resume=yes
    else
        [ ! -L "$NL_STORE/current" ] || nl_fail '订阅清单已存在但配置缺失，拒绝覆盖。'
    fi
    work=$(nl_scratch)
    cleanup_init() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" -ne 0 ] && [ "$resume" = no ] && [ ! -L "$NL_STORE/current" ]; then
            rm -f "$NL_RUN" "$NL_SUB_TARGET"
        fi
        rm -rf "$work"
        exit "$result"
    }
    trap cleanup_init EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$resume" = no ]; then
        mkdir -p "$(dirname "$NL_RUN")" "$NL_RUN_DIR/providers" "$NL_RUN_DIR/rule-providers"
        secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
        ML_SECRET="$secret" yq e '.secret = strenv(ML_SECRET)' "$NL_PKG/template.yaml" > "$work/config.yaml"
        nl_placeholder "$NL_SUB_EMPTY" "$work/subscriptions.yaml"
        nl_put "$work/subscriptions.yaml" "$NL_SUB_TARGET"
        resources_prepare "$NL_PKG" "$NL_RUN_DIR" "$work/resources"
        nl_put "$work/config.yaml" "$NL_RUN"
        nl_assert_config
        timeout 120 mihomo -t -d "$NL_RUN_DIR" -f "$NL_RUN" > "$work/check.log" 2>&1 || {
            rm -f "$NL_RUN"; nl_fail '模板未通过内核校验；尚未启动服务。';
        }
        "$NL_LIB/subscriptions.sh" init
    fi
    if [ -z "$R" ]; then
        chown root:mihomo-local /etc/mihomo-local; chmod 750 /etc/mihomo-local
        chown root:mihomo-local /var/lib/mihomo-local; chmod 750 /var/lib/mihomo-local
        # The service cannot rename provider/rule directories. Only its existing
        # selection cache is writable; all paths used by privileged writers are
        # under root-owned parents.
        chown -R root:mihomo-local "$NL_RUN_DIR"
        find "$NL_RUN_DIR" -type d -exec chmod 750 {} +
        find "$NL_RUN_DIR" -type f -exec chmod 640 {} +
        touch "$NL_RUN_DIR/cache.db"
        chown mihomo-local:mihomo-local "$NL_RUN_DIR/cache.db"
        chmod 640 "$NL_RUN_DIR/cache.db"
        systemctl enable --now mihomo-local.service
        attempt=0
        until core_verify "$NL_SUB_PROVIDER" "$NL_SUB_TARGET" "$work"; do
            attempt=$((attempt + 1)); [ "$attempt" -lt 15 ] || nl_fail '配置已准备，但服务未就绪；请运行 doctor 和 mihomo-proxy log。'
            sleep 1
        done
        systemctl enable --now mihomo-local-update.timer
    fi
    echo '配置已就绪，已有模板和订阅保持不变。'
    echo '初始化完成：本地代理 127.0.0.1:7890；请用 sub add 添加订阅。'
    ;;
doctor)
    [ "$#" -eq 0 ] || nl_fail 'doctor 不接受参数。'
    nl_assert_config
    work=$(nl_scratch); trap 'rm -rf "$work"' EXIT HUP INT TERM
    timeout 120 mihomo -t -d "$NL_RUN_DIR" -f "$NL_RUN" > "$work/check.log" 2>&1 || nl_fail '配置校验失败。'
    "$NL_LIB/subscriptions.sh" check
    core_verify "$NL_SUB_PROVIDER" "$NL_SUB_TARGET" "$work" || nl_fail '节点文件与运行内核不一致，或控制接口不可用。'
    echo '通过：本机代理配置、订阅文件与内核节点；没有系统网络接管。'
    if [ -z "$R" ]; then
        systemctl is-active mihomo-local.service
        systemctl is-enabled mihomo-local-update.timer || true
    fi
    ;;
schedule)
    [ "$#" -eq 1 ] || nl_fail '用法：schedule hourly|off'
    case "$1" in hourly|off) ;; *) nl_fail '用法：schedule hourly|off';; esac
    nl_lock; nl_assert_config
    if [ "$1" = hourly ]; then systemctl enable --now mihomo-local-update.timer
    else systemctl disable --now mihomo-local-update.timer; fi
    ;;
*) nl_fail '未知服务命令。';;
esac
