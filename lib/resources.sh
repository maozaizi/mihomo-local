#!/bin/sh
# Shared, offline public assets preparation. No network or system service calls.
resources_prepare() {
    rp_pkg=$1; rp_run=$2; rp_work=$3
    mkdir -p "$rp_run/rule-providers" "$rp_work" || return 1
    while IFS='|' read -r rp_id rp_digest rp_format rp_behavior rp_file rp_url; do
        case "$rp_file" in ''|*/*|*..*) nl_fail '资源文件名无效。';; esac
        rp_actual=$(sha256sum "$rp_pkg/assets/$rp_file"); rp_actual=${rp_actual%% *}
        [ "$rp_actual" = "$rp_digest" ] || nl_fail "资源校验失败：$rp_id"
        case "$rp_format" in
            zip)
                unzip -q "$rp_pkg/assets/$rp_file" -d "$rp_work/webui" || return 1
                [ -s "$rp_work/webui/dist/index.html" ] || nl_fail 'WebUI 缺少入口。'
                [ -e "$rp_run/ui" ] || cp -R "$rp_work/webui/dist" "$rp_run/ui" || return 1;;
            yaml|mrs) cp "$rp_pkg/assets/$rp_file" "$rp_run/rule-providers/$rp_file" || return 1;;
            *) nl_fail "未知资源格式：$rp_id";;
        esac
    done < "$rp_pkg/assets/manifest.tsv"
}
