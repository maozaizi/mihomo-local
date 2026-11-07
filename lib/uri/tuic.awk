# tuic:// — TUIC v5 (uuid:password). v4 token links are reported as skipped.

function parse_tuic(link,    Q, i, uuid, password, k, cc, mode, out) {
    split_link(link, Q)
    i = index(USERINFO, ":")
    if (!i) return skip("TUIC v4")
    uuid = tolower(pct(substr(USERINFO, 1, i - 1))); password = pct(substr(USERINFO, i + 1))
    if (!uuid_ok(uuid)) die("UUID 格式无效")
    if (password == "") die("缺少密码")
    hostport(AUTHORITY, "")
    k = unknown(Q, "remarks congestion_control udp_relay_mode alpn sni insecure disable_sni reduce_rtt version")
    if (k != "") return skip("TUIC 参数 " safe(k))
    if (Q["version"] != "" && Q["version"] != "5") return skip("TUIC v" safe(Q["version"]))
    if (Q["remarks"] != "" && LABEL == "") LABEL = Q["remarks"]
    cc = Q["congestion_control"]
    if (cc != "" && cc != "bbr" && cc != "cubic" && cc != "new_reno") die("congestion_control 无效")
    mode = Q["udp_relay_mode"]
    if (mode != "" && mode != "native" && mode != "quic") die("udp_relay_mode 无效")

    out = head(node_name(LABEL, HOST, PORT), "tuic", HOST, PORT) ",\"uuid\":" q(uuid) ",\"password\":" q(password) ",\"udp\":true"
    if (Q["sni"] != "") out = out ",\"sni\":" q(Q["sni"])
    out = out ",\"skip-cert-verify\":" flag(Q, "insecure", "false")
    if (cc != "") out = out ",\"congestion-controller\":" q(cc)
    if (mode != "") out = out ",\"udp-relay-mode\":" q(mode)
    if (Q["alpn"] != "") out = out ",\"alpn\":" qlist(Q["alpn"])
    if (flag(Q, "disable_sni", "false") == "true") out = out ",\"disable-sni\":true"
    if (flag(Q, "reduce_rtt", "false") == "true") out = out ",\"reduce-rtt\":true"
    return out "}"
}
