# hysteria2:// and hy2:// — official URI scheme plus the mport extension.
# Port hopping may appear as host:443,2000-3000 or as mport=.

function ports_ok(spec,    n, a, i, r) {
    if (spec !~ /^[0-9,-]+$/) return 0
    n = split(spec, a, ",")
    for (i = 1; i <= n; i++) {
        if (split(a[i], r, "-") == 2) { if (!port_ok(r[1]) || !port_ok(r[2]) || r[1] + 0 > r[2] + 0) return 0 }
        else if (!port_ok(a[i])) return 0
    }
    return 1
}

function bandwidth(v) {
    if (v ~ /^[0-9]+$/) return v + 0
    if (v ~ /^[0-9]+ ?[KMGTkmgt]?bps$/) return q(v)
    die("带宽参数无效")
}

function parse_hysteria2(link,    Q, auth, a, c, ports, k, pin, out) {
    split_link(link, Q)
    auth = pct(USERINFO)
    if (auth == "") die("缺少认证密码")
    a = AUTHORITY; ports = ""
    c = match(a, /:[0-9]+[,-][0-9,-]*$/)
    if (c && substr(a, 1, c - 1) !~ /^\[[^]]*$/) {
        ports = substr(a, c + 1)
        if (!ports_ok(ports)) die("端口跳跃范围无效")
        a = substr(a, 1, c - 1) ":" substr(ports, 1, match(ports, /[,-]/) - 1)
    }
    hostport(a, "443")
    k = unknown(Q, "remarks sni insecure obfs obfs-password pinSHA256 alpn up down upmbps downmbps mport fp fastopen")
    if (k != "") return skip("Hysteria2 参数 " safe(k))
    if (Q["remarks"] != "" && LABEL == "") LABEL = Q["remarks"]
    if (Q["mport"] != "") {
        if (ports != "" && ports != Q["mport"]) die("端口跳跃参数冲突")
        if (!ports_ok(Q["mport"])) die("端口跳跃范围无效")
        ports = Q["mport"]
    }
    if (Q["obfs"] != "" && Q["obfs"] != "none" && Q["obfs"] != "salamander") return skip("Hysteria2 的 " safe(Q["obfs"]) " 混淆")
    if (Q["obfs"] == "salamander" && Q["obfs-password"] == "") die("salamander 混淆缺少密码")
    pin = tolower(Q["pinSHA256"]); gsub(/:/, "", pin)
    if (pin != "" && (length(pin) != 64 || pin ~ /[^0-9a-f]/)) die("pinSHA256 必须是 SHA-256 十六进制指纹")
    if (Q["up"] == "") Q["up"] = Q["upmbps"]
    if (Q["down"] == "") Q["down"] = Q["downmbps"]

    out = head(node_name(LABEL, HOST, PORT), "hysteria2", HOST, PORT)
    if (ports != "") out = out ",\"ports\":" q(ports)
    out = out ",\"password\":" q(auth) ",\"udp\":true"
    if (Q["sni"] != "") out = out ",\"sni\":" q(Q["sni"])
    out = out ",\"skip-cert-verify\":" flag(Q, "insecure", "false")
    if (Q["obfs"] == "salamander") out = out ",\"obfs\":\"salamander\",\"obfs-password\":" q(Q["obfs-password"])
    if (Q["alpn"] != "") out = out ",\"alpn\":" qlist(Q["alpn"])
    if (pin != "") out = out ",\"fingerprint\":" q(pin)
    if (Q["up"] != "") out = out ",\"up\":" bandwidth(Q["up"])
    if (Q["down"] != "") out = out ",\"down\":" bandwidth(Q["down"])
    return out "}"
}
