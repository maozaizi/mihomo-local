# ss:// — SIP002 and legacy whole-authority Base64, with obfs/v2ray-plugin.

function ss_plugin(spec,    n, a, i, kv, eq, name, P, o) {
    n = split(spec, a, ";")
    name = a[1]
    split("", P)
    for (i = 2; i <= n; i++) {
        if (a[i] == "") continue
        eq = index(a[i], "=")
        if (eq) P[substr(a[i], 1, eq - 1)] = substr(a[i], eq + 1); else P[a[i]] = "true"
    }
    if (name == "obfs-local" || name == "simple-obfs" || name == "obfs") {
        if (P["obfs"] != "http" && P["obfs"] != "tls") die("obfs 插件模式必须是 http 或 tls")
        o = ",\"plugin\":\"obfs\",\"plugin-opts\":{\"mode\":" q(P["obfs"])
        if (P["obfs-host"] != "") o = o ",\"host\":" q(P["obfs-host"])
        return o "}"
    }
    if (name == "v2ray-plugin") {
        if (P["mode"] == "") P["mode"] = "websocket"
        if (P["mode"] != "websocket") return skip("v2ray-plugin 的 " safe(P["mode"]) " 模式")
        o = ",\"plugin\":\"v2ray-plugin\",\"plugin-opts\":{\"mode\":\"websocket\",\"tls\":" (("tls" in P) ? "true" : "false")
        if (P["host"] != "") o = o ",\"host\":" q(P["host"])
        if (P["path"] != "") o = o ",\"path\":" q(P["path"])
        if (P["mux"] != "" && P["mux"] != "0" && P["mux"] != "false") o = o ",\"mux\":true"
        return o "}"
    }
    return skip("SS 插件 " safe(name))
}

function parse_ss(link,    Q, rest, encoded, auth, eq, method, password, k, out, plugin) {
    split_link(link, Q)
    rest = AUTHORITY
    encoded = 0
    if (USERINFO == "") {
        # Legacy form: the whole "method:password@host:port" is Base64.
        rest = b64(rest, 0); encoded = 1
        if (!match(rest, /@[^@]*$/)) die("缺少服务器")
        USERINFO = substr(rest, 1, RSTART - 1); rest = substr(rest, RSTART + 1)
    }
    auth = USERINFO
    if (auth !~ /:/) { auth = b64(auth, 0); encoded = 1 }
    eq = index(auth, ":")
    if (!eq) die("缺少加密方式")
    method = substr(auth, 1, eq - 1); password = substr(auth, eq + 1)
    if (!encoded) { method = pct(method); password = pct(password) }
    if (method == "" || password == "") die("加密方式或密码为空")
    hostport(rest, "")
    k = unknown(Q, "plugin uot udp-over-tcp group")
    if (k != "") return skip("SS 参数 " safe(k))
    out = head(node_name(LABEL, HOST, PORT), "ss", HOST, PORT) ",\"cipher\":" q(method) ",\"password\":" q(password) ",\"udp\":true"
    if (Q["uot"] == "1" || Q["udp-over-tcp"] == "true") out = out ",\"udp-over-tcp\":true"
    if (Q["plugin"] != "") {
        plugin = ss_plugin(Q["plugin"])
        if (plugin == "") return ""
        out = out plugin
    }
    return out "}"
}
