# vmess:// — v2rayN style: Base64 of a flat JSON object (share format v2).

function utf8(cp) {
    if (cp < 128) return sprintf("%c", cp)
    if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
    if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
    return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}

function hex4(s,    i, v) {
    if (length(s) != 4 || s ~ /[^0-9A-Fa-f]/) die("JSON 转义无效")
    v = 0
    for (i = 1; i <= 4; i++) v = v * 16 + hexval(substr(s, i, 1))
    return v
}

function jws(s) { while (JP <= length(s) && substr(s, JP, 1) ~ /[ \t\r\n]/) JP++ }

# Read the JSON string starting at JP (on the opening quote).
function jstr(s,    out, c, e, cp, lo) {
    out = ""; JP++
    while (JP <= length(s)) {
        c = substr(s, JP, 1)
        if (c == "\"") { JP++; return out }
        if (c ~ /[[:cntrl:]]/) die("JSON 字符串包含控制字符")
        if (c == "\\") {
            e = substr(s, JP + 1, 1); JP += 2
            if (e == "u") {
                cp = hex4(substr(s, JP, 4)); JP += 4
                if (cp >= 55296 && cp <= 56319 && substr(s, JP, 2) == "\\u") {
                    lo = hex4(substr(s, JP + 2, 4))
                    if (lo >= 56320 && lo <= 57343) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); JP += 6 }
                }
                if (cp < 32 || cp == 127 || (cp >= 55296 && cp <= 57343)) die("JSON 转义无效")
                out = out utf8(cp)
            } else if (e == "n" || e == "r" || e == "t" || e == "b" || e == "f") die("JSON 字符串包含控制字符")
            else if (e == "\"" || e == "\\" || e == "/") out = out e
            else die("JSON 转义无效")
            continue
        }
        out = out c; JP++
    }
    die("JSON 字符串未结束")
}

# Parse a flat JSON object into V; nested values are malformed here.
function json_flat(s, V,    key, c, tok) {
    split("", V); JP = 1
    jws(s)
    if (substr(s, JP, 1) != "{") die("VMess 内容不是 JSON 对象")
    JP++; jws(s)
    if (substr(s, JP, 1) == "}") { JP++ }
    else while (1) {
        jws(s)
        if (substr(s, JP, 1) != "\"") die("JSON 键无效")
        key = jstr(s); jws(s)
        if (substr(s, JP, 1) != ":") die("JSON 缺少冒号")
        JP++; jws(s)
        c = substr(s, JP, 1)
        if (c == "\"") V[key] = jstr(s)
        else if (c == "{" || c == "[") die("VMess JSON 含嵌套结构")
        else {
            tok = substr(s, JP); match(tok, /^[^,} \t\r\n]*/)
            tok = substr(tok, 1, RLENGTH)
            if (tok !~ /^(true|false|null|-?[0-9]+(\.[0-9]+)?)$/) die("JSON 值无效")
            V[key] = (tok == "null" ? "" : tok); JP += RLENGTH
        }
        jws(s); c = substr(s, JP, 1); JP++
        if (c == "}") break
        if (c != ",") die("JSON 结构无效")
    }
    jws(s)
    if (JP <= length(s)) die("JSON 之后有多余内容")
}

function parse_vmess(link,    body, i, label, V, net, hdr, tls, cipher, aid, uuid, out, alpn) {
    body = substr(link, 9); label = ""
    i = index(body, "#")
    if (i) { label = pct(substr(body, i + 1)); body = substr(body, 1, i - 1) }
    if (body ~ /[@?]/) return skip("非 v2rayN 格式的 VMess")
    body = b64(body, 1)
    if (body !~ /^[ \t\r\n]*\{/) return skip("非 v2rayN 格式的 VMess")
    json_flat(body, V)
    if (V["v"] != "" && V["v"] != "2") return skip("VMess 分享格式 v" safe(V["v"]))
    if (V["ps"] != "") label = V["ps"]
    if (V["add"] == "") die("缺少服务器")
    hostport(index(V["add"], ":") ? "[" V["add"] "]:" V["port"] : V["add"] ":" V["port"], "")
    uuid = V["id"]
    if (uuid == "" || uuid ~ /[[:cntrl:] ]/ || length(uuid) > 64) die("用户 ID 无效")
    aid = V["aid"]; if (aid == "") aid = 0
    if (aid !~ /^[0-9]+$/) die("alterId 无效")
    cipher = V["scy"]; if (cipher == "") cipher = "auto"
    if (cipher !~ /^(auto|aes-128-gcm|chacha20-poly1305|none|zero)$/) return skip("VMess 的 " safe(cipher) " 加密")

    net = tolower(V["net"]); if (net == "") net = "tcp"
    hdr = tolower(V["type"])
    if (net == "tcp" && hdr == "http") net = "http"
    else if (net == "http") net = "h2"
    else if (net == "tcp" && hdr != "" && hdr != "none") die("TCP 伪装类型无效")
    if (net != "tcp" && net != "http" && net != "h2" && net != "ws" && net != "httpupgrade" && net != "grpc") return skip("VMess 的 " safe(net) " 传输")
    tls = tolower(V["tls"])
    if (tls == "reality") return skip("VMess 的 REALITY")
    if (tls != "" && tls != "none" && tls != "tls") die("tls 字段无效")

    out = head(node_name(label, HOST, PORT), "vmess", HOST, PORT) ",\"uuid\":" q(uuid) ",\"alterId\":" (aid + 0) ",\"cipher\":" q(cipher) ",\"udp\":true,\"xudp\":true,\"tls\":" (tls == "tls" ? "true" : "false")
    if (tls == "tls") {
        out = out ",\"skip-cert-verify\":" ((V["allowInsecure"] == "1" || V["allowInsecure"] == "true") ? "true" : "false")
        if (V["sni"] != "") out = out ",\"servername\":" q(V["sni"])
        if (V["fp"] != "") out = out ",\"client-fingerprint\":" q(V["fp"])
        if (V["alpn"] != "") out = out ",\"alpn\":" qlist(V["alpn"])
    }
    if (net == "ws" || net == "httpupgrade") out = out ws_opts(net, V["path"], V["host"], "", "")
    else if (net == "grpc") out = out grpc_opts(V["path"])
    else if (net == "h2") out = out h2_opts(V["host"], V["path"])
    else if (net == "http") out = out http_opts(V["host"], V["path"])
    return out "}"
}
