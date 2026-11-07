# vless:// — Xray share-link standard, plus legacy Base64 authority and the
# tls/xtls/peer aliases older clients emit.

function parse_vless(link,    Q, rest, uuid, k, net, security, tls, had_flow, flow, xf, fp, out, enc) {
    split_link(link, Q)
    rest = AUTHORITY
    if (USERINFO == "") {
        rest = b64(rest, 0)
        if (!index(rest, "@")) die("缺少用户标识或服务器")
        USERINFO = substr(rest, 1, index(rest, "@") - 1); rest = substr(rest, index(rest, "@") + 1)
    }
    sub(/^(auto|none):/, "", USERINFO)
    uuid = tolower(pct(USERINFO))
    if (!uuid_ok(uuid)) die("UUID 格式无效")
    hostport(rest, "")
    if (Q["remarks"] != "" && LABEL == "") LABEL = Q["remarks"]
    # spx/pqv/mode/authority only tune the client; Mihomo has no equivalent.
    k = unknown(Q, "remarks tls udp xtls pbk sid spx pqv sni fp security flow encryption type headerType path host serviceName mode authority alpn packetEncoding insecure ed eh")
    if (k != "") return skip("VLESS 参数 " safe(k))

    net = tolower(Q["type"]); if (net == "") net = "tcp"
    if (net == "http") net = "h2"
    if (net == "tcp" && tolower(Q["headerType"]) == "http") net = "http"
    else if (Q["headerType"] != "" && tolower(Q["headerType"]) != "none") die("headerType 仅支持 none 或 http")
    if (net != "tcp" && net != "ws" && net != "httpupgrade" && net != "grpc" && net != "h2" && net != "http") return skip("VLESS 的 " safe(net) " 传输")

    enc = Q["encryption"]
    security = tolower(Q["security"])
    if (security == "xtls") return skip("VLESS 的旧版 XTLS")
    if (security != "" && security != "none" && security != "tls" && security != "reality") die("不支持的 security")
    tls = flag(Q, "tls", "false")
    if (security == "") security = (Q["pbk"] != "" ? "reality" : (tls == "true" ? "tls" : "none"))
    if ((security == "none" && tls == "true") || (security != "none" && ("tls" in Q) && tls == "false")) die("TLS 参数冲突")
    if (Q["pbk"] != "" && security != "reality") die("公钥与 security 参数冲突")

    # Test membership before reading: reading an awk array creates the key.
    had_flow = ("flow" in Q); flow = Q["flow"]
    if ("xtls" in Q) {
        if (Q["xtls"] != "0" && Q["xtls"] != "2") die("仅支持 xtls=0 或 xtls=2（Vision）")
        xf = (Q["xtls"] == "2" ? "xtls-rprx-vision" : "")
        if (had_flow && flow != xf) die("flow 与 xtls 冲突")
        flow = xf
    }
    if (flow != "" && flow != "xtls-rprx-vision") return skip("VLESS 的 " safe(flow) " flow")
    if (flow != "" && (security == "none" || net != "tcp")) die("Vision 需要 TCP 和 TLS/REALITY")
    if (security != "reality" && Q["sid"] != "") die("short-id 仅适用于 REALITY")
    if (Q["packetEncoding"] != "" && Q["packetEncoding"] != "xudp" && Q["packetEncoding"] != "packetaddr" && Q["packetEncoding"] != "none") die("packetEncoding 无效")
    if (net == "tcp" && (Q["path"] != "" || Q["host"] != "")) die("path/host 不适用于 TCP")
    if (net != "grpc" && Q["serviceName"] != "") die("serviceName 仅适用于 grpc")
    if (security == "none" && (Q["sni"] != "" || Q["fp"] != "" || Q["alpn"] != "" || flag(Q, "insecure", "false") == "true")) die("TLS 选项需要启用 TLS")

    out = head(node_name(LABEL, HOST, PORT), "vless", HOST, PORT) ",\"uuid\":" q(uuid) ",\"udp\":" flag(Q, "udp", "true") ",\"tls\":" (security == "none" ? "false" : "true")
    if (flow != "") out = out ",\"flow\":" q(flow)
    if (security != "none") {
        fp = Q["fp"]; if (fp == "") fp = "chrome"
        out = out ",\"client-fingerprint\":" q(fp) ",\"skip-cert-verify\":" flag(Q, "insecure", "false")
        if (Q["sni"] != "") out = out ",\"servername\":" q(Q["sni"])
    }
    if (security == "reality") out = out reality(Q["pbk"], Q["sid"], Q["sni"])
    if (net == "ws" || net == "httpupgrade") out = out ws_opts(net, Q["path"], Q["host"] == "" ? HOST : Q["host"], Q["ed"], Q["eh"])
    else if (net == "grpc") out = out grpc_opts(Q["serviceName"])
    else if (net == "h2") out = out h2_opts(Q["host"], Q["path"])
    else if (net == "http") out = out http_opts(Q["host"], Q["path"])
    if (Q["packetEncoding"] == "xudp" || Q["packetEncoding"] == "packetaddr") out = out ",\"packet-encoding\":" q(Q["packetEncoding"])
    if (Q["alpn"] != "") out = out ",\"alpn\":" qlist(Q["alpn"])
    if (enc != "" && enc != "none" && enc != "auto") out = out ",\"encryption\":" q(enc)
    return out "}"
}
