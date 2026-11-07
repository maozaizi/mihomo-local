#!/bin/sh
# The only code that talks to Mihomo: offline validation and provider refresh.
# Callers pass a private scratch directory; the controller secret never
# appears in process arguments.

# Validate a {proxies:[...]} file with the real core, without starting it.
core_test() {
    nl_assert_config || return 1
    yq e '{"mode":"rule","proxies":.proxies,"rules":["MATCH,DIRECT"]}' "$1" > "$2/core-test.yaml" || return 1
    mkdir -p "$2/core-home"
    timeout 120 mihomo -t -d "$2/core-home" -f "$2/core-test.yaml" > "$2/core-test.log" 2>&1
}

core_auth() {
    nl_assert_config || return 1
    core_secret=$(yq e -r '.secret // ""' "$NL_RUN") || return 1
    case "$core_secret" in *[!a-zA-Z0-9]*) return 1;; esac
    [ "${#core_secret}" -ge 32 ] || return 1
    printf 'header = "Authorization: Bearer %s"\n' "$core_secret" > "$1/curl.conf"
}

core_names() { yq e -o=json -I=0 '[.proxies[].name] | sort' "$1"; }

# One read: is PROVIDER a loaded File provider holding exactly FILE's names?
core_matches() {
    curl --noproxy '*' -fsS --connect-timeout 3 --max-time 5 --config "$3/curl.conf" \
        "$NL_API/providers/proxies/$1" -o "$3/provider.json" 2>/dev/null || return 1
    [ "$(yq e -r '.vehicleType // ""' "$3/provider.json")" = File ] || return 1
    [ "$(core_names "$3/provider.json")" = "$(core_names "$2")" ]
}

# PROVIDER FILE SCRATCH: read-only check, used by doctor.
core_verify() { core_auth "$3" && core_matches "$1" "$2" "$3"; }

# PROVIDER FILE SCRATCH: ask the core to reload FILE, then wait until the
# loaded provider matches it. Refresh is asynchronous, so poll.
core_refresh() {
    core_auth "$3" || return 1
    curl --noproxy '*' -fsS --connect-timeout 3 --max-time 10 -X PUT --config "$3/curl.conf" \
        "$NL_API/providers/proxies/$1" -o /dev/null 2>/dev/null || return 1
    core_try=0
    while [ "$core_try" -lt 15 ]; do
        core_matches "$1" "$2" "$3" && return 0
        core_try=$((core_try + 1)); sleep 1
    done
    return 1
}

# PROVIDER SOURCE TARGET SCRATCH: install SOURCE as TARGET, refresh, verify.
# Recovery on failure belongs to the caller's journal, not to this function.
core_publish() {
    nl_put "$2" "$3" && core_refresh "$1" "$3" "$4"
}
