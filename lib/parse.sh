#!/bin/sh
# Subscription content -> validated {proxies:[...]}. Needs common.sh, core.sh.
# Only the node list is taken; remote rules, DNS and groups are never read.

# MODE [REPORT]: share links on stdin, one JSON proxy per line on stdout.
parse_links() {
    LC_ALL=C awk -v mode="$1" -v report="${2:-}" \
        -f "$NL_LIB/uri/common.awk" -f "$NL_LIB/uri/ss.awk" -f "$NL_LIB/uri/vless.awk" \
        -f "$NL_LIB/uri/vmess.awk" -f "$NL_LIB/uri/trojan.awk" -f "$NL_LIB/uri/hysteria2.awk" \
        -f "$NL_LIB/uri/tuic.awk" -f "$NL_LIB/uri/main.awk"
}

# JSONL proxies -> {proxies:[...]} YAML.
parse_collect() { yq ea -p=json -o=yaml '[.] | {"proxies": .}' "$1"; }

# INPUT OUTPUT SCRATCH. On failure SCRATCH/error.code names the reason and
# SCRATCH/error.detail may hold a credential-free parser message. Skipped
# links are summarised in SCRATCH/skipped ("count<TAB>reason").
# The whole parse (yq, awk and the core check) shares one time budget.
parse_feed() {
    rm -f "$3/error.code" "$3/error.detail" "$3/skipped"
    pf_code=0
    timeout 120 sh -c 'MIHOMO_LOCAL_LIB=$1; . "$1/lib/common.sh"; . "$NL_LIB/core.sh"; . "$NL_LIB/parse.sh"; parse_feed_run "$2" "$3" "$4"' \
        sh "$NL_PKG" "$1" "$2" "$3" || pf_code=$?
    [ "$pf_code" -ne 0 ] || return 0
    case "$pf_code" in 124|137|143) printf 'validation_timeout\n' > "$3/error.code";; esac
    [ -s "$3/error.code" ] || printf 'parse_failed\n' > "$3/error.code"
    return 1
}

parse_feed_run() (
    in=$1; out=$2; s=$3
    bad() { printf '%s\n' "$1" > "$s/error.code"; exit 1; }
    [ "$(wc -c < "$in")" -le "$NL_MAX_BYTES" ] || bad input_too_large
    if [ "$(yq e 'type == "!!map" and has("proxies")' "$in" 2>/dev/null)" = true ]; then
        [ "$(yq e '.proxies | type' "$in")" = '!!seq' ] || bad missing_proxies
        yq e '{"proxies": .proxies}' "$in" > "$s/parsed.yaml" || bad yaml_invalid
    else
        code=0
        parse_links feed "$s/skipped" < "$in" > "$s/nodes.jsonl" 2> "$s/error.detail" || code=$?
        case "$code" in
            0) ;;
            3) [ "$(yq e 'type' "$in" 2>/dev/null)" = '!!map' ] && bad missing_proxies; bad unsupported_format;;
            4) bad too_many_nodes;;
            *) bad uri_node_invalid;;
        esac
        [ -s "$s/nodes.jsonl" ] || bad all_skipped
        parse_collect "$s/nodes.jsonl" > "$s/parsed.yaml" || bad yaml_invalid
    fi
    count=$(yq e '.proxies | length' "$s/parsed.yaml")
    [ "$count" -gt 0 ] || bad empty_nodes
    [ "$count" -le "$NL_MAX_NODES" ] || bad too_many_nodes
    [ "$(yq e '[.proxies[] | select(.name == null or .name == "" or .type == null or .type == "" or .server == null or .server == "" or .port == null or .port == "")] | length' "$s/parsed.yaml")" = 0 ] || bad missing_fields
    [ "$(yq e '[.proxies[].name] | unique | length' "$s/parsed.yaml")" = "$count" ] || bad duplicate_names
    core_test "$s/parsed.yaml" "$s" || bad core_rejected
    cp "$s/parsed.yaml" "$out"
)

# One-line human summary of SCRATCH/skipped, empty when nothing was skipped.
parse_skipped() {
    [ -s "$1/skipped" ] || return 0
    awk -F '\t' '{ n += $1; s = s (s == "" ? "" : "，") $2 " " $1 " 个" } END { printf "跳过 %d 个不支持的节点（%s）", n, s }' "$1/skipped"
}
