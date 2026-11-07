# Shared helpers for the share-link parsers. POSIX awk only (BusyBox, BWK).
# Never executes or fetches link content; all output is JSON built here.
#
# Policy, applied by every protocol:
#   die(msg)   malformed data (bad UUID, port, Base64, conflict): the whole
#              subscription is rejected, because the feed itself is suspect.
#   skip(why)  well-formed but unsupported (protocol, transport, parameter):
#              the node is left out and counted in the report. In manual
#              mode, where one link is given on purpose, skip is an error.

function die(msg) {
    if (!failed) printf "%s%s\n", where, msg > "/dev/stderr"
    failed = 1
    exit 1
}

function skip(why) {
    if (mode == "manual") die("不支持：" why)
    skip_reason = why
    return ""
}

function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }

# Percent-decoding; '+' stays literal. Control bytes are rejected.
function pct(s,    out, i, c, h, n) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "%") {
            h = substr(s, i + 1, 2)
            if (length(h) != 2 || h ~ /[^0-9A-Fa-f]/) die("百分号编码无效")
            n = hexval(substr(h, 1, 1)) * 16 + hexval(substr(h, 2, 1))
            if (n < 32 || n == 127) die("不允许控制字符")
            c = sprintf("%c", n); i += 2
        }
        out = out c
    }
    return out
}

# Standard or URL-safe Base64, padding optional. With ws=1, whitespace is
# ignored and decoded newlines/tabs are allowed (pretty-printed JSON).
function b64(s, ws,    abc, i, c, v, bits, acc, out, n, pad) {
    if (ws) gsub(/[ \t\r\n]/, "", s)
    gsub(/-/, "+", s); gsub(/_/, "/", s)
    if (s == "" || s ~ /[^A-Za-z0-9+\/=]/ || s ~ /=[^=]/) die("Base64 内容无效")
    pad = s; sub(/^[^=]*/, "", pad)
    if (length(pad) > 2 || length(s) % 4 == 1 || (pad != "" && length(s) % 4 != 0)) die("Base64 长度无效")
    sub(/=+$/, "", s)
    abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    acc = 0; bits = 0; out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        acc = acc * 64 + index(abc, substr(s, i, 1)) - 1; bits += 6
        if (bits >= 8) {
            bits -= 8; v = int(acc / (2 ^ bits)); acc = acc % (2 ^ bits)
            if (v == 127 || (v < 32 && !(ws && (v == 9 || v == 10 || v == 13)))) die("解码内容包含控制字符")
            out = out sprintf("%c", v)
        }
    }
    if (acc != 0) die("Base64 尾部无效")
    return out
}

# JSON string literal. Control characters never reach here.
function q(s,    i, c, out) {
    out = "\""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else out = out c
    }
    return out "\""
}

# JSON array of strings from a comma list; empty items are malformed.
function qlist(csv,    n, a, i, out) {
    n = split(csv, a, ",")
    out = "["
    for (i = 1; i <= n; i++) {
        if (a[i] == "") die("列表项不能为空")
        out = out (i > 1 ? "," : "") q(a[i])
    }
    return out "]"
}

function safe(k) { return (k ~ /^[A-Za-z0-9_.-]+$/ && length(k) <= 32) ? k : "（非常规名称）" }

function alias(k) {
    if (k == "peer") return "sni"
    if (k == "fingerprint") return "fp"
    if (k == "allowInsecure" || k == "allow_insecure" || k == "skip-cert-verify") return "insecure"
    if (k == "congestion-control") return "congestion_control"
    return k
}

# Fill Q from a query string. Identical repeats are harmless; conflicting
# values for one key (including aliases) are malformed.
function query(qs, Q,    n, parts, i, eq, k, v) {
    split("", Q)
    n = split(qs, parts, "&")
    for (i = 1; i <= n; i++) {
        if (parts[i] == "") continue
        eq = index(parts[i], "=")
        if (eq) { k = pct(substr(parts[i], 1, eq - 1)); v = pct(substr(parts[i], eq + 1)) }
        else { k = pct(parts[i]); v = "" }
        k = alias(k)
        if ((k in Q) && Q[k] != v) die("参数重复且取值冲突：" safe(k))
        Q[k] = v
    }
}

# First key of Q outside the space-separated allow list, or "".
function unknown(Q, allowed,    k) {
    for (k in Q) if (index(" " allowed " ", " " k " ") == 0) return k
    return ""
}

function flag(Q, k, def) {
    if (!(k in Q) || Q[k] == "") return def
    if (Q[k] == "1" || Q[k] == "true") return "true"
    if (Q[k] == "0" || Q[k] == "false") return "false"
    die(safe(k) " 必须为 0/1 或 true/false")
}

function port_ok(p) { return p ~ /^[0-9]+$/ && p + 0 >= 1 && p + 0 <= 65535 }

# Split "host:port", "[v6]:port" or a bare host (when defport is given)
# into HOST and PORT.
function hostport(a, defport,    i, rest, n, p) {
    if (substr(a, 1, 1) == "[") {
        i = index(a, "]")
        if (!i) die("IPv6 地址格式无效")
        HOST = substr(a, 2, i - 2); rest = substr(a, i + 1)
        if (HOST !~ /:/ || HOST ~ /[^0-9A-Fa-f:.]/) die("IPv6 地址格式无效")
        if (rest == "" && defport != "") PORT = defport
        else if (substr(rest, 1, 1) == ":") PORT = substr(rest, 2)
        else die("缺少端口")
    } else {
        n = split(a, p, ":")
        if (n == 1 && defport != "") { HOST = a; PORT = defport }
        else if (n == 2) { HOST = p[1]; PORT = p[2] }
        else die("服务器必须包含端口；IPv6 需要方括号")
        if (HOST == "" || HOST ~ /[^A-Za-z0-9._-]/) die("服务器地址无效")
    }
    if (!port_ok(PORT)) die("端口无效")
}

# Split scheme://REST into USERINFO, AUTHORITY, Q (query) and LABEL.
# The userinfo is everything before the last '@' of the authority.
function split_link(link, Q,    rest, i, at) {
    rest = substr(link, index(link, "://") + 3)
    LABEL = ""
    i = index(rest, "#")
    if (i) { LABEL = pct(substr(rest, i + 1)); rest = substr(rest, 1, i - 1) }
    i = index(rest, "?")
    if (i) { query(substr(rest, i + 1), Q); rest = substr(rest, 1, i - 1) } else split("", Q)
    sub(/\/$/, "", rest)
    at = match(rest, /@[^@]*$/)
    if (at) { USERINFO = substr(rest, 1, at - 1); AUTHORITY = substr(rest, at + 1) }
    else { USERINFO = ""; AUTHORITY = rest }
}

function uuid_ok(u,    c) {
    c = u; gsub(/-/, "", c)
    return length(u) == 36 && length(c) == 32 && c !~ /[^0-9a-f]/ && \
        substr(u, 9, 1) == "-" && substr(u, 14, 1) == "-" && substr(u, 19, 1) == "-" && substr(u, 24, 1) == "-"
}

function node_name(label, server, port,    n) {
    if (ENVIRON["NL_NODE_NAME"] != "") label = ENVIRON["NL_NODE_NAME"]
    if (label == "") label = server ":" port
    n = (mode == "manual") ? "[手动] " label : label
    if (length(n) > 160 || n ~ /[[:cntrl:]]/) die("节点名称过长或包含控制字符")
    return n
}

# Leading members shared by every proxy object.
function head(name, type, server, port) {
    return "{\"name\":" q(name) ",\"type\":\"" type "\",\"server\":" q(server) ",\"port\":" (port + 0)
}

# ws/httpupgrade options. Early data may arrive as ed=/eh= parameters or as
# ?ed= inside the path (v2rayN), as Mihomo's own converter accepts.
function ws_opts(net, path, host, ed, eh,    o, m) {
    if (match(path, /[?&]ed=[0-9]+/)) {
        m = substr(path, RSTART + 4, RLENGTH - 4)
        if (ed == "") ed = m
        path = substr(path, 1, RSTART - 1) substr(path, RSTART + RLENGTH)
        sub(/^\?&/, "?", path); sub(/\?$/, "", path)
    }
    if (ed != "" && ed !~ /^[0-9]+$/) die("ed 必须是数字")
    o = ",\"network\":\"ws\",\"ws-opts\":{\"path\":" q(path == "" ? "/" : path) ",\"headers\":{" (host == "" ? "" : "\"Host\":" q(host)) "}"
    if (net == "httpupgrade") {
        o = o ",\"v2ray-http-upgrade\":true"
        if (ed != "") o = o ",\"v2ray-http-upgrade-fast-open\":true"
    } else if (ed != "") {
        o = o ",\"max-early-data\":" (ed + 0) ",\"early-data-header-name\":" q(eh == "" ? "Sec-WebSocket-Protocol" : eh)
    }
    return o "}"
}

function grpc_opts(service) { return ",\"network\":\"grpc\",\"grpc-opts\":{\"grpc-service-name\":" q(service) "}" }

function h2_opts(host, path) {
    return ",\"network\":\"h2\",\"h2-opts\":{\"host\":" (host == "" ? "[]" : qlist(host)) ",\"path\":" q(path == "" ? "/" : path) "}"
}

function http_opts(host, path) {
    return ",\"network\":\"http\",\"http-opts\":{\"path\":[" q(path == "" ? "/" : path) "],\"headers\":{\"Host\":" (host == "" ? "[]" : qlist(host)) "}}"
}

function reality(pbk, sid, sni) {
    if (length(pbk) != 43 || pbk ~ /[^A-Za-z0-9_-]/) die("REALITY 公钥无效")
    if (length(sid) > 16 || length(sid) % 2 || sid ~ /[^0-9A-Fa-f]/) die("REALITY short-id 无效")
    if (sni == "") die("REALITY 缺少 sni")
    return ",\"reality-opts\":{\"public-key\":" q(pbk) ",\"short-id\":" q(sid) "}"
}
