# trojan:// — password@host:port with TLS or REALITY over tcp/ws/grpc.

function parse_trojan(link,    Q, password, k, net, security, fp, out) {
    split_link(link, Q)
    password = pct(USERINFO)
    if (password == "") die("缺少密码")
    hostport(AUTHORITY, "")
    k = unknown(Q, "remarks security sni fp alpn insecure type headerType path host serviceName mode authority pbk sid spx pqv udp ed eh flow encryption")
    if (k != "") return skip("Trojan 参数 " safe(k))
    if (Q["remarks"] != "" && LABEL == "") LABEL = Q["remarks"]

    net = tolower(Q["type"]); if (net == "") net = "tcp"
    if (net != "tcp" && net != "ws" && net != "httpupgrade" && net != "grpc") return skip("Trojan 的 " safe(net) " 传输")
    if (Q["headerType"] != "" && tolower(Q["headerType"]) != "none") return skip("Trojan 的 HTTP 伪装")
    if (Q["flow"] != "") return skip("Trojan 的 flow")
    if (Q["encryption"] != "" && Q["encryption"] != "none") die("Trojan 不支持 encryption")
    security = tolower(Q["security"]); if (security == "") security = (Q["pbk"] != "" ? "reality" : "tls")
    if (security == "none") return skip("未启用 TLS 的 Trojan")
    if (security != "tls" && security != "reality") die("不支持的 security")
    if (Q["pbk"] != "" && security != "reality") die("公钥与 security 参数冲突")
    if (security != "reality" && Q["sid"] != "") die("short-id 仅适用于 REALITY")
    if (net == "tcp" && (Q["path"] != "" || Q["host"] != "")) die("path/host 不适用于 TCP")
    if (net != "grpc" && Q["serviceName"] != "") die("serviceName 仅适用于 grpc")

    fp = Q["fp"]; if (fp == "") fp = "chrome"
    out = head(node_name(LABEL, HOST, PORT), "trojan", HOST, PORT) ",\"password\":" q(password) ",\"udp\":" flag(Q, "udp", "true")
    if (Q["sni"] != "") out = out ",\"sni\":" q(Q["sni"])
    out = out ",\"skip-cert-verify\":" flag(Q, "insecure", "false") ",\"client-fingerprint\":" q(fp)
    if (security == "reality") out = out reality(Q["pbk"], Q["sid"], Q["sni"])
    if (net == "ws" || net == "httpupgrade") out = out ws_opts(net, Q["path"], Q["host"] == "" ? (Q["sni"] == "" ? HOST : Q["sni"]) : Q["host"], Q["ed"], Q["eh"])
    else if (net == "grpc") out = out grpc_opts(Q["serviceName"])
    if (Q["alpn"] != "") out = out ",\"alpn\":" qlist(Q["alpn"])
    return out "}"
}
