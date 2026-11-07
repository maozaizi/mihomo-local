#!/bin/sh
# Reason code -> message. Messages never contain URLs, links or secrets.

# nl_download exit status -> reason code.
nl_download_reason() {
    case "$1" in
        3) echo invalid_url;; 63) echo input_too_large;; 6) echo download_dns;; 28) echo download_timeout;;
        35|51|60) echo download_tls;; 22) echo download_http;; *) echo download_failed;;
    esac
}

nl_reason() {
    case "$1" in
        input_too_large) echo '订阅超过 8 MiB';;
        too_many_nodes) echo '节点数超过 4096';;
        validation_timeout) echo '节点解析或内核校验超时';;
        download_dns) echo '订阅域名解析失败';;
        download_timeout) echo '订阅下载超时';;
        download_tls) echo '订阅 TLS 验证或握手失败';;
        download_http) echo '订阅服务器返回 HTTP 错误';;
        download_failed) echo '订阅下载或连接失败';;
        unsupported_format) echo '返回内容既不是含 proxies 的 YAML，也不是节点链接列表';;
        uri_node_invalid) echo '节点链接格式损坏，整份订阅未采用';;
        all_skipped) echo '订阅中的节点全部是不支持的类型';;
        empty_nodes) echo '订阅节点为空';;
        missing_proxies) echo 'YAML 中没有 proxies 节点数组';;
        yaml_invalid) echo '节点数据无法转换为 YAML';;
        missing_fields) echo '节点缺少名称、类型、服务器或端口';;
        duplicate_names) echo '同一订阅存在重复节点名';;
        core_rejected) echo 'Mihomo 内核拒绝节点配置';;
        node_drop) echo '节点数量骤减或整类协议消失，疑似上游异常';;
        invalid_url) echo '地址无效或包含不允许的字符';;
        local_missing) echo '本地订阅文件不存在或为空';;
        *) echo '订阅解析或文件处理失败';;
    esac
}
