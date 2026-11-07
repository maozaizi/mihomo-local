#!/bin/sh
set -eu
core=${1:-mihomo}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
for item in 'cn-ip ipcidr' 'ai-foreign domain' 'tiktok domain'; do
    name=${item% *}; behavior=${item#* }
    "$core" convert-ruleset "$behavior" text "$root/assets/sources/$name.list" "$work/$name.mrs"
    cmp "$root/assets/$name.mrs" "$work/$name.mrs"
    printf 'Verified: %s\n' "$name"
done
