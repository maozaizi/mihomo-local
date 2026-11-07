# Entry point: a plain or Base64 link list on stdin, one JSON proxy per line
# on stdout. Base64 is decoded as a stream, so no string grows beyond a link.
#   -v mode=feed|manual   manual: exactly one link, and skips become errors
#   -v report=FILE        feed: "count<TAB>reason" for every skipped kind
# Exit: 0 ok; 1 malformed (reason on stderr); 3 not a link list; 4 too many.

BEGIN {
    B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    state = 0; links = 0; acc = 0; bits = 0; chars = 0; pad = 0; cur = ""
}

function not_list() { failed = 3; exit 3 }

function emit(line,    scheme, obj) {
    sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
    if (line == "") return
    if (line !~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) not_list()
    links++
    if (links > 4096) { failed = 4; exit 4 }
    scheme = tolower(substr(line, 1, index(line, "://") - 1))
    where = (mode == "manual") ? "" : "第 " links " 个链接（" safe(scheme) "）："
    if (mode == "manual" && links > 1) die("一次只能添加一个链接")
    if (line ~ /[[:cntrl:]]/ || length(line) > 8192) die("链接过长或包含控制字符")
    skip_reason = ""
    if (scheme == "ss") obj = parse_ss(line)
    else if (scheme == "vless") obj = parse_vless(line)
    else if (scheme == "vmess") obj = parse_vmess(line)
    else if (scheme == "trojan") obj = parse_trojan(line)
    else if (scheme == "hysteria2" || scheme == "hy2") obj = parse_hysteria2(line)
    else if (scheme == "tuic") obj = parse_tuic(line)
    else obj = skip(safe(scheme) " 协议")
    if (obj == "") { skipped[skip_reason]++; return }
    print obj
}

function b64_line(s,    i, n, c, v) {
    gsub(/[ \t\r]/, "", s); gsub(/-/, "+", s); gsub(/_/, "/", s)
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); chars++
        if (c == "=") { pad++; continue }
        v = index(B64, c) - 1
        if (v < 0 || pad) not_list()
        acc = acc * 64 + v; bits += 6
        if (bits < 8) continue
        bits -= 8; v = int(acc / (2 ^ bits)); acc = acc % (2 ^ bits)
        if (v == 10) { emit(cur); cur = "" }
        else if (v == 13) continue
        else if ((v < 32 && v != 9) || v == 127) not_list()
        else {
            cur = cur sprintf("%c", v)
            if (length(cur) > 8192) die("链接过长")
        }
    }
}

{
    line = $0
    if (NR == 1) sub(/^\357\273\277/, "", line)
    if (state == 0) {
        t = line; gsub(/[ \t\r]/, "", t)
        if (t == "") next
        state = (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) ? 1 : 2
    }
    if (state == 1) emit(line); else b64_line(line)
}

END {
    if (failed) exit failed
    if (state == 2) {
        if (pad > 2 || chars % 4 == 1 || (pad && chars % 4 != 0) || acc != 0) not_list()
        emit(cur)
    }
    if (links == 0) not_list()
    if (report != "") for (r in skipped) printf "%d\t%s\n", skipped[r], r > report
    exit 0
}
