#!/bin/sh
# Subscription registry, generations, aggregation and publication.
# Each source keeps its own node file; the aggregate is only a build product.
# The profile and its rules are never edited here.
set -eu
. "${MIHOMO_LOCAL_LIB:-/usr/local/lib/mihomo-local/current}/lib/common.sh"
. "$NL_LIB/core.sh"
. "$NL_LIB/parse.sh"
. "$NL_LIB/reasons.sh"
NL_TAG=订阅
nl_need_admin

command=${1:-list}; [ "$#" -eq 0 ] || shift
case "$command" in
    list|check) writer=no ;;
    init|add|remove|set-url|update|rollback|recover) writer=yes ;;
    *) nl_fail '支持 sub add|list|remove|set-url|recover；update 更新全部订阅；rollback 恢复上一版。' ;;
esac
# Queries take no lock and therefore change nothing: no directories, no log
# lines, and never a recovery of a transaction another process may own.
if [ "$writer" = no ]; then
    if [ ! -L "$NL_STORE/current" ]; then
        nl_fail '尚未初始化订阅清单；新设备请先执行 init。'
    fi
    [ ! -f "$NL_STORE/pending" ] || nl_fail '有未完成的订阅操作；请执行 mihomo-local sub recover。'
else
    nl_lock
    nl_assert_config
    [ "$command" = init ] || [ -L "$NL_STORE/current" ] || nl_fail '尚未初始化订阅清单；新设备请先执行 init。'
    mkdir -p "$NL_STORE/generations"
fi
work=$(nl_scratch)
stage=''; logged=no

# RESULT REASON [ID] [EXTRA]
log_event() { nl_log "event=subscription action=$command result=$1 reason=$2 id=${3:-none}${4:+ $4}" || true; }
fail() {
    if [ "$writer" = yes ]; then log_event failed "${error_code:-operation_failed}" "${sid:-none}"; logged=yes; fi
    nl_fail "$*"
}

safe_generation() {
    case "$1" in generations/g.*) case "${1#generations/}" in *[!a-zA-Z0-9.]*) return 1;; esac;; *) return 1;; esac
    [ -f "$NL_STORE/$1/registry.yaml" ]
}
pointer() {
    safe_generation "$2" || return 1
    rm -f "$NL_STORE/.$1.new"
    ln -s "$2" "$NL_STORE/.$1.new" && mv -fT "$NL_STORE/.$1.new" "$NL_STORE/$1"
}

ids() { yq e -r '.subscriptions | keys | .[]' "$1/registry.yaml"; }
field() { NL_ID="$2" NL_FIELD="$3" yq e -r '.subscriptions[strenv(NL_ID)][strenv(NL_FIELD)] // ""' "$1/registry.yaml"; }

validate_registry() {
    [ "$(yq e '.schema == 1 and (.subscriptions | type) == "!!map" and (.next_id | type) == "!!int" and .next_id > 0 and ([.subscriptions | to_entries[] | select((.key | test("^s[0-9][0-9][0-9][0-9]+$") | not) or (.value.url | type) != "!!str" or (.value.name | type) != "!!str" or (.value.prefix | type) != "!!str")] | length) == 0' "$1/registry.yaml")" = true ] || return 1
    for vid in $(ids "$1"); do [ -f "$1/$vid.yaml" ] || return 1; done
}

# Prefix names, and dialer-proxy references to nodes of the same source,
# with the source's stable ID. References are matched by exact name.
namespace() {
    if [ -z "$3" ]; then cp "$1" "$2"; return; fi
    NL_PREFIX="$3" yq e '
      [.proxies[].name] as $names |
      .proxies |= map(
        .name = strenv(NL_PREFIX) + .name |
        ."dialer-proxy" as $d |
        with(select($d != null and ($names | any_c(. == $d)));
          ."dialer-proxy" = strenv(NL_PREFIX) + $d))' "$1" > "$2"
}

# DIR/aggregate.yaml from every source of DIR, merged in one pass.
render() {
    rdir=$1; set --
    for rid in $(ids "$rdir"); do
        namespace "$rdir/$rid.yaml" "$work/ns-$rid.yaml" "$(field "$rdir" "$rid" prefix)" || return 1
        set -- "$@" "$work/ns-$rid.yaml"
    done
    if [ "$#" -eq 0 ]; then printf 'proxies: []\n' > "$rdir/aggregate.yaml"
    else yq ea '[.proxies[]] | {"proxies": .}' "$@" > "$rdir/aggregate.yaml"; fi
}

# The provider file for DIR: its aggregate, or the REJECT placeholder.
provider_file() {
    if [ "$(yq e '.proxies | length' "$1/aggregate.yaml")" = 0 ]; then nl_placeholder "$NL_SUB_EMPTY" "$2"
    else cp "$1/aggregate.yaml" "$2"; fi
}

publish_generation() {
    provider_file "$1" "$work/publish.yaml" && \
        core_publish "$NL_SUB_PROVIDER" "$work/publish.yaml" "$NL_SUB_TARGET" "$work"
}

recover() {
    [ -f "$NL_STORE/pending" ] || return 0
    old=$(sed -n '1p' "$NL_STORE/pending"); prev=$(sed -n '2p' "$NL_STORE/pending")
    safe_generation "$old" || return 1
    pointer current "$old" && publish_generation "$NL_STORE/$old" || return 1
    if [ -n "$prev" ]; then pointer previous "$prev" || return 1; else rm -f "$NL_STORE/previous"; fi
    rm -f "$NL_STORE/pending"
    echo '订阅：已恢复中断操作前的订阅清单与节点。' >&2
}

finish() {
    code=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$writer" = no ]; then rm -rf "$work"; exit "$code"; fi
    if [ "$code" -ne 0 ] && [ "$logged" != yes ]; then log_event failed command_failed; fi
    if [ -f "$NL_STORE/pending" ]; then
        if ! recover; then
            echo "订阅恢复未完成；请检查 doctor 后执行 sub recover。私有诊断保留：$work" >&2
            exit 1
        fi
        [ "$code" -ne 0 ] || code=1
    fi
    if [ -n "$stage" ] && [ -d "$stage" ]; then
        rel=generations/${stage##*/}
        [ "$rel" = "$(readlink "$NL_STORE/current" || true)" ] || [ "$rel" = "$(readlink "$NL_STORE/previous" || true)" ] || rm -rf "$stage"
    fi
    rm -rf "$work"
    exit "$code"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fetch() {
    rm -f "$work/error.code" "$work/error.detail" "$work/skipped"
    case "$1" in
        https://*)
            dl=0; nl_download "$1" "$work/download" "$work" || dl=$?
            [ "$dl" = 0 ] || { error_code=$(nl_download_reason "$dl"); return 1; }
            ;;
        /*)
            [ -f "$1" ] && [ -s "$1" ] || { error_code=local_missing; return 1; }
            head -c "$((NL_MAX_BYTES + 1))" "$1" > "$work/download" || { error_code=local_missing; return 1; }
            ;;
        *) error_code=invalid_url; return 1;;
    esac
    parse_feed "$work/download" "$2" "$work" && return 0
    error_code=$(cat "$work/error.code" 2>/dev/null || echo parse_failed)
    return 1
}
# Reason line for the last fetch, with the parser's own detail when present.
fetch_reason() {
    reason=$(nl_reason "$error_code")
    if [ -s "$work/error.detail" ]; then reason="${reason}：$(head -n 1 "$work/error.detail")"; fi
    printf '%s' "$reason"
}
# "ss 1，vless 5" for a proxies file: the first add has nothing to compare
# against, so the composition is how a short feed becomes visible.
composition() { yq e -r '[.proxies[].type] | group_by(.) | map(.[0] + " " + (length | tostring)) | join("，")' "$1"; }
skip_field() {
    [ -s "$work/skipped" ] || return 0
    printf 'skipped=%s' "$(awk -F '\t' '{ n += $1 } END { print n }' "$work/skipped")"
}

# OLD NEW: refuse a sudden collapse that a broken upstream or converter
# produces: fewer than half the nodes, or a protocol vanishing entirely.
drop_detail() {
    before=$(yq e '.proxies | length' "$1"); after=$(yq e '.proxies | length' "$2")
    new_types=$(yq e -r '[.proxies[].type] | unique | .[]' "$2")
    lost=''
    for t in $(yq e -r '[.proxies[].type] | unique | .[]' "$1"); do
        printf '%s\n' "$new_types" | grep -qx "$t" || lost="$lost $t"
    done
    if [ $((after * 2)) -lt "$before" ] || [ -n "$lost" ]; then
        printf '节点 %s → %s 个' "$before" "$after"
        [ -z "$lost" ] || printf '，%s 节点全部消失' "${lost# }"
        return 0
    fi
    return 1
}

record() {
    NL_ID="$1" NL_RESULT="$2" NL_TIME="$(date '+%Y-%m-%dT%H:%M:%S%z')" yq e -i \
        '.subscriptions[strenv(NL_ID)].result = strenv(NL_RESULT) | .subscriptions[strenv(NL_ID)].last_attempt = strenv(NL_TIME)' "$stage/registry.yaml"
}

# Identity of what the core serves, excluding fetch bookkeeping.
business_state() {
    yq e -o=json -I=0 '.subscriptions | with_entries(.value |= (del(.result) | del(.last_attempt))) | sort_keys(..)' "$1/registry.yaml"
    yq e -o=json -I=0 '.proxies' "$1/aggregate.yaml"
}

commit() {
    validate_registry "$stage" || fail '候选订阅清单无效。'
    render "$stage" || fail '合并节点失败，现有节点未改变。'
    provider_file "$stage" "$work/candidate.yaml"
    total=$(yq e '.proxies | length' "$stage/aggregate.yaml")
    [ "$total" -le "$NL_MAX_NODES" ] || { error_code=too_many_nodes; fail "全部订阅合计 $total 个节点，超过 $NL_MAX_NODES 上限；现有节点未改变。"; }
    core_test "$work/candidate.yaml" "$work" || { error_code=core_rejected; fail '合并后的节点未通过内核校验，现有节点未改变。'; }
    old=$(readlink "$NL_STORE/current")
    different=yes
    if [ "$(business_state "$NL_STORE/$old")" = "$(business_state "$stage")" ]; then different=no; fi
    # The journal precedes the pointer switch, so an interrupted publish is
    # recoverable. Atomic rename does not promise power-loss durability.
    printf '%s\n%s\n' "$old" "$(readlink "$NL_STORE/previous" || true)" > "$NL_STORE/.pending.new"
    mv -f "$NL_STORE/.pending.new" "$NL_STORE/pending"
    pointer current "generations/${stage##*/}" || fail '无法保存订阅清单。'
    publish_generation "$stage" || { error_code=core_refresh; fail '内核未确认新节点，正在恢复原订阅与节点。'; }
    [ "$different" = no ] || pointer previous "$old" || fail '无法保存上一版引用。'
    rm -f "$NL_STORE/pending"
    current=$(readlink "$NL_STORE/current"); previous=$(readlink "$NL_STORE/previous" || true)
    for generation in "$NL_STORE"/generations/g.*; do
        rel=generations/${generation##*/}
        [ "$rel" = "$current" ] || [ "$rel" = "$previous" ] || rm -rf "$generation"
    done
    printf 'time=%s\nnodes=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(yq e '.proxies | length' "$stage/aggregate.yaml")" > "$NL_HOME/last-publish"
}

if [ "$command" = init ]; then
    [ ! -e "$NL_STORE/current" ] || fail '订阅清单已存在。'
    initial=$(mktemp -d "$NL_STORE/generations/g.XXXXXX")
    printf 'schema: 1\nnext_id: 1\nsubscriptions: {}\n' > "$initial/registry.yaml"
    render "$initial"
    pointer current "generations/${initial##*/}"
    exit 0
fi

[ "$writer" = no ] || recover || fail '存在未恢复的操作，请先确认内核控制接口可用后重试。'
base=$(readlink "$NL_STORE/current")
safe_generation "$base" && validate_registry "$NL_STORE/$base" || fail '订阅清单损坏，未修改节点。'

case "$command" in
list)
    [ "$#" -eq 0 ] || fail 'list 不接受参数。'
    echo '编号 / 名称 / 节点数 / 最近获取结果（地址隐藏）'
    for sid in $(ids "$NL_STORE/$base"); do
        printf '%s / %s / %s / %s\n' "$sid" "$(field "$NL_STORE/$base" "$sid" name)" \
            "$(yq e '.proxies | length' "$NL_STORE/$base/$sid.yaml")" "$(field "$NL_STORE/$base" "$sid" result)"
    done
    ;;
recover) [ "$#" -eq 0 ] || fail '参数过多。'; echo '订阅清单已就绪。' ;;
check)
    [ "$#" -eq 0 ] || fail '参数过多。'
    stage=''; cp -R "$NL_STORE/$base" "$work/check"
    render "$work/check"
    provider_file "$work/check" "$work/expected.yaml"
    [ "$(yq e -o=json -I=0 '.proxies' "$work/expected.yaml")" = "$(yq e -o=json -I=0 '.proxies' "$NL_SUB_TARGET")" ] || \
        fail '订阅源与运行节点文件不一致，请执行 update。'
    echo '订阅清单、各来源与汇总节点一致。'
    ;;
*)
    stage=$(mktemp -d "$NL_STORE/generations/g.XXXXXX")
    cp "$NL_STORE/$base/registry.yaml" "$stage/registry.yaml"
    for sid in $(ids "$NL_STORE/$base"); do cp "$NL_STORE/$base/$sid.yaml" "$stage/$sid.yaml"; done
    sid=''; failures=0
    case "$command" in
    add)
        [ "$#" -eq 1 ] || [ "$#" -eq 3 ] || fail "用法：sub add 'https://地址' [--name 名称]"
        url=$1; label=''
        if [ "$#" -eq 3 ]; then [ "$2" = --name ] || fail '只支持 --name 名称。'; label=$3; fi
        [ "$(NL_URL="$url" yq e '[.subscriptions[] | select(.url == strenv(NL_URL))] | length' "$stage/registry.yaml")" = 0 ] || fail '这个地址已经记录，不会重复添加。'
        number=$(yq e '.next_id' "$stage/registry.yaml")
        sid=$(printf 's%04d' "$number")
        [ -n "$label" ] || label=$sid
        # Every source uses a stable namespace, independent of insertion order.
        prefix="[$sid] "
        fetch "$url" "$work/new.yaml" || fail "$(fetch_reason)；未添加订阅。"
        # Keep an absolute local source path, so update re-reads the user's file.
        cp "$work/new.yaml" "$stage/$sid.yaml"
        NL_ID="$sid" NL_URL="$url" NL_LABEL="$label" NL_PREFIX="$prefix" NL_NEXT="$((number + 1))" yq e -i \
            '.next_id = (strenv(NL_NEXT) | tonumber) | .subscriptions[strenv(NL_ID)] = {"name": strenv(NL_LABEL), "url": strenv(NL_URL), "prefix": strenv(NL_PREFIX)}' "$stage/registry.yaml"
        record "$sid" success
        ;;
    remove)
        [ "$#" -eq 1 ] || fail '用法：sub remove s0001'
        sid=$1
        [ "$(NL_ID="$sid" yq e '.subscriptions | has(strenv(NL_ID))' "$stage/registry.yaml")" = true ] || fail '没有这个订阅。'
        NL_ID="$sid" yq e -i 'del(.subscriptions[strenv(NL_ID)])' "$stage/registry.yaml"
        rm -f "$stage/$sid.yaml"
        ;;
    set-url)
        [ "$#" -eq 2 ] || fail "用法：sub set-url s0001 'https://新地址'"
        sid=$1; url=$2
        [ "$(NL_ID="$sid" yq e '.subscriptions | has(strenv(NL_ID))' "$stage/registry.yaml")" = true ] || fail '没有这个订阅。'
        [ "$(NL_URL="$url" NL_ID="$sid" yq e '[.subscriptions | to_entries[] | select(.key != strenv(NL_ID) and .value.url == strenv(NL_URL))] | length' "$stage/registry.yaml")" = 0 ] || fail '地址已属于另一份订阅。'
        fetch "$url" "$work/new.yaml" || fail "$(fetch_reason)；原地址和节点保留。"
        cp "$work/new.yaml" "$stage/$sid.yaml"
        NL_ID="$sid" NL_URL="$url" yq e -i '.subscriptions[strenv(NL_ID)].url = strenv(NL_URL)' "$stage/registry.yaml"
        record "$sid" success
        ;;
    update)
        force=no
        case "$#:${1:-}" in 0:) ;; 1:--force) force=yes;; *) fail 'update 更新全部订阅，只接受 --force；新增请用 sub add。';; esac
        for sid in $(ids "$stage"); do
            before=$(yq e '.proxies | length' "$stage/$sid.yaml")
            if ! fetch "$(field "$stage" "$sid" url)" "$work/new.yaml"; then
                record "$sid" failed; failures=$((failures + 1)); log_event failed "$error_code" "$sid"
                echo "${sid}：$(fetch_reason)；保留原有 $before 个节点。"
                continue
            fi
            if [ "$force" = no ] && detail=$(drop_detail "$stage/$sid.yaml" "$work/new.yaml"); then
                record "$sid" failed; failures=$((failures + 1)); log_event failed node_drop "$sid"
                echo "${sid}：${detail}，疑似上游异常；保留原有节点。确认属于正常变化时执行 mihomo-local update --force。"
                continue
            fi
            cp "$work/new.yaml" "$stage/$sid.yaml"; record "$sid" success
            log_event fetched source_validated "$sid" "$(skip_field)"
            skipped=$(parse_skipped "$work")
            echo "${sid}：获取成功，$before → $(yq e '.proxies | length' "$stage/$sid.yaml") 个节点（$(composition "$stage/$sid.yaml")）${skipped:+；$skipped}；等待统一发布。"
        done
        sid=''
        ;;
    rollback)
        [ "$#" -eq 0 ] || fail 'rollback 不接受参数。'
        [ -L "$NL_STORE/previous" ] || fail '没有上一版订阅快照。'
        prev=$(readlink "$NL_STORE/previous"); safe_generation "$prev" || fail '上一版快照无效。'
        rm -f "$stage"/*.yaml
        cp "$NL_STORE/$prev/registry.yaml" "$stage/registry.yaml"
        for rid in $(ids "$NL_STORE/$prev"); do cp "$NL_STORE/$prev/$rid.yaml" "$stage/$rid.yaml"; done
        # Never reuse an ID after rollback or removal.
        NL_NEXT=$(yq e '.next_id' "$NL_STORE/$base/registry.yaml") yq e -i \
            '.next_id = ([.next_id, (strenv(NL_NEXT) | tonumber)] | max)' "$stage/registry.yaml"
        ;;
    esac
    commit
    case "$command" in add|set-url) extra=$(skip_field);; *) extra='';; esac
    log_event published runtime_confirmed "${sid:-none}" "$extra"; logged=yes
    case "$command" in
        add|set-url)
            [ "$command" = add ] && verb='已添加订阅' || verb='已更换来源：订阅'
            printf '%s %s（%s 个节点：%s）。%s\n' "$verb" "$sid" "$(yq e '.proxies | length' "$stage/$sid.yaml")" "$(composition "$stage/$sid.yaml")" "$(parse_skipped "$work")" ;;
        remove) printf '已删除订阅 %s。\n' "$sid" ;;
    esac
    echo '已同步到 Mihomo；模板、规则和密钥未改变。'
    if [ "$failures" -gt 0 ]; then
        log_event partial upstream_failures
        echo "$failures 份订阅未更新；其他订阅已生效。"
        exit 2
    fi
    ;;
esac
