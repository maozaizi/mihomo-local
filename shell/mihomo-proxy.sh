# Source in interactive Bash/Zsh. No eval, no user-controlled shell code.
case $- in *i*) ;; *) return 0;; esac
[ -z "${BASH_VERSION:-}${ZSH_VERSION:-}" ] && return 0

_mihomo_proxy_enable() {
    if [ "${_MIHOMO_PROXY_ACTIVE:-0}" != 1 ]; then
        _ML_SET_http_proxy=${http_proxy+x}; _ML_OLD_http_proxy=${http_proxy-}
        if [ "${http_proxy-}" = http://127.0.0.1:7890 ]; then _ML_SET_http_proxy=; _ML_OLD_http_proxy=; fi
        _ML_SET_https_proxy=${https_proxy+x}; _ML_OLD_https_proxy=${https_proxy-}
        if [ "${https_proxy-}" = http://127.0.0.1:7890 ]; then _ML_SET_https_proxy=; _ML_OLD_https_proxy=; fi
        _ML_SET_HTTP_PROXY=${HTTP_PROXY+x}; _ML_OLD_HTTP_PROXY=${HTTP_PROXY-}
        if [ "${HTTP_PROXY-}" = http://127.0.0.1:7890 ]; then _ML_SET_HTTP_PROXY=; _ML_OLD_HTTP_PROXY=; fi
        _ML_SET_HTTPS_PROXY=${HTTPS_PROXY+x}; _ML_OLD_HTTPS_PROXY=${HTTPS_PROXY-}
        if [ "${HTTPS_PROXY-}" = http://127.0.0.1:7890 ]; then _ML_SET_HTTPS_PROXY=; _ML_OLD_HTTPS_PROXY=; fi
        _ML_SET_no_proxy=${no_proxy+x}; _ML_OLD_no_proxy=${no_proxy-}
        if [ "${no_proxy-}" = localhost,127.0.0.1,::1 ]; then _ML_SET_no_proxy=; _ML_OLD_no_proxy=; fi
        _ML_SET_NO_PROXY=${NO_PROXY+x}; _ML_OLD_NO_PROXY=${NO_PROXY-}
        if [ "${NO_PROXY-}" = localhost,127.0.0.1,::1 ]; then _ML_SET_NO_PROXY=; _ML_OLD_NO_PROXY=; fi
    fi
    export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890
    export HTTP_PROXY=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890
    export no_proxy="localhost,127.0.0.1,::1${_ML_OLD_no_proxy:+,$_ML_OLD_no_proxy}"
    export NO_PROXY="localhost,127.0.0.1,::1${_ML_OLD_NO_PROXY:+,$_ML_OLD_NO_PROXY}"
    _MIHOMO_PROXY_ACTIVE=1
}
_mihomo_proxy_disable() {
    [ "${_MIHOMO_PROXY_ACTIVE:-0}" = 1 ] || return 0
    if [ "${_ML_SET_http_proxy:-}" = x ]; then export http_proxy="$_ML_OLD_http_proxy"; else unset http_proxy; fi
    unset _ML_SET_http_proxy _ML_OLD_http_proxy
    if [ "${_ML_SET_https_proxy:-}" = x ]; then export https_proxy="$_ML_OLD_https_proxy"; else unset https_proxy; fi
    unset _ML_SET_https_proxy _ML_OLD_https_proxy
    if [ "${_ML_SET_HTTP_PROXY:-}" = x ]; then export HTTP_PROXY="$_ML_OLD_HTTP_PROXY"; else unset HTTP_PROXY; fi
    unset _ML_SET_HTTP_PROXY _ML_OLD_HTTP_PROXY
    if [ "${_ML_SET_HTTPS_PROXY:-}" = x ]; then export HTTPS_PROXY="$_ML_OLD_HTTPS_PROXY"; else unset HTTPS_PROXY; fi
    unset _ML_SET_HTTPS_PROXY _ML_OLD_HTTPS_PROXY
    if [ "${_ML_SET_no_proxy:-}" = x ]; then export no_proxy="$_ML_OLD_no_proxy"; else unset no_proxy; fi
    unset _ML_SET_no_proxy _ML_OLD_no_proxy
    if [ "${_ML_SET_NO_PROXY:-}" = x ]; then export NO_PROXY="$_ML_OLD_NO_PROXY"; else unset NO_PROXY; fi
    unset _ML_SET_NO_PROXY _ML_OLD_NO_PROXY
    unset _MIHOMO_PROXY_ACTIVE
}
mihomo-proxy() {
    case "${1:-status}" in
        on)
            [ "$#" = 1 ] || { echo '用法：mihomo-proxy on' >&2; return 2; }
            command mihomo-proxy check || return
            command mihomo-proxy persist on || return
            _mihomo_proxy_enable
            echo '当前终端代理已开启；新终端沿用开启状态。';;
        off)
            [ "$#" = 1 ] || { echo '用法：mihomo-proxy off' >&2; return 2; }
            command mihomo-proxy persist off || return
            _mihomo_proxy_disable
            echo '当前终端原有代理设置已恢复；新终端不自动开启。';;
        status)
            printf '当前终端由本工具开启：%s\n' "${_MIHOMO_PROXY_ACTIVE:-0}"
            if [ "${http_proxy:-}" = http://127.0.0.1:7890 ] && [ "${https_proxy:-}" = http://127.0.0.1:7890 ]; then
                echo '当前终端 HTTP/HTTPS 入口：127.0.0.1:7890'
            else echo '当前终端 HTTP/HTTPS 入口：未同时指向本地代理'; fi
            command mihomo-proxy status;;
        *) command mihomo-proxy "$@";;
    esac
}
_ml_state=${XDG_STATE_HOME:-"$HOME/.local/state"}/mihomo-proxy/state
if [ -r "$_ml_state" ] && [ "$(cat "$_ml_state")" = on ]; then
    # Loading a shell must never block on the network. status checks usability.
    _mihomo_proxy_enable
fi
unset _ml_state
