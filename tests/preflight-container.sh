#!/bin/sh
# Disposable container only; no real PID1 or host file changes.
set -eu
[ "${ML_DISPOSABLE_CONTAINER:-}" = yes ] || exit 2
mkdir -p /run/systemd/system /usr/local/sbin /usr/local/bin
cat > /usr/local/sbin/apt-get <<'EOF'
#!/bin/sh
echo apt >> /tmp/network-violation
exit 99
EOF
cat > /usr/local/bin/curl <<'EOF'
#!/bin/sh
echo curl >> /tmp/network-violation
exit 99
EOF
chmod +x /usr/local/sbin/apt-get /usr/local/bin/curl
candidate=/tmp/preflight-candidate
cp -R /src "$candidate"
core_sha=$(sha256sum /tools/mihomo);core_sha=${core_sha%% *}
yq_sha=$(sha256sum /tools/yq);yq_sha=${yq_sha%% *}
clean_state() {
    [ ! -e /etc/mihomo-local ] && [ ! -e /var/lib/mihomo-local ] && [ ! -e /usr/local/bin/mihomo ] && [ ! -e /usr/local/lib/mihomo-local ]
    [ ! -e /etc/systemd/system/mihomo-local.service ]
    ! getent passwd mihomo-local >/dev/null
    ! getent group mihomo-local >/dev/null
    [ ! -e /tmp/network-violation ]
}
run_good() { sh "$candidate/install.sh" --mihomo /tools/mihomo --mihomo-sha256 "$core_sha" --yq /tools/yq --yq-sha256 "$yq_sha" "$@"; }
expect_bad() {
    if "$@" > /tmp/preflight-last.log 2>&1; then echo 'Expected preflight failure' >&2; exit 10; fi
    clean_state
}
expect_bad sh "$candidate/install.sh" --check
grep -q '尚未准备 Mihomo' /tmp/preflight-last.log
expect_bad sh "$candidate/install.sh" --check --mihomo /tools/mihomo --mihomo-sha256 "$core_sha"
grep -q '尚未准备 yq' /tmp/preflight-last.log
expect_bad sh "$candidate/install.sh" --check --mihomo /tools/mihomo --mihomo-sha256 0000000000000000000000000000000000000000000000000000000000000000 --yq /tools/yq --yq-sha256 "$yq_sha"
grep -q 'SHA256' /tmp/preflight-last.log
python3 - <<'PY'
from pathlib import Path
p=bytearray(Path('/tools/mihomo').read_bytes());p[18]=62 if p[18]==183 else 183
Path('/tmp/wrong-architecture').write_bytes(p)
PY
wrong_sha=$(sha256sum /tmp/wrong-architecture);wrong_sha=${wrong_sha%% *}
expect_bad sh "$candidate/install.sh" --check --mihomo /tmp/wrong-architecture --mihomo-sha256 "$wrong_sha" --yq /tools/yq --yq-sha256 "$yq_sha"
grep -q '架构不匹配' /tmp/preflight-last.log
mv /etc/ssl/certs/ca-certificates.crt /tmp/saved-ca-bundle
expect_bad run_good --check
grep -q '缺少 CA 证书' /tmp/preflight-last.log
mv /tmp/saved-ca-bundle /etc/ssl/certs/ca-certificates.crt
mv /usr/bin/unzip /usr/bin/unzip.disabled
expect_bad run_good --check
grep -q '缺少系统命令：unzip' /tmp/preflight-last.log
mv /usr/bin/unzip.disabled /usr/bin/unzip
mv "$candidate/assets/cn-ip.mrs" /tmp/saved-rule
expect_bad run_good --check
grep -q '摘要不匹配' /tmp/preflight-last.log
mv /tmp/saved-rule "$candidate/assets/cn-ip.mrs"
mv "$candidate/assets/webui.zip" /tmp/saved-webui
expect_bad run_good --check
mv /tmp/saved-webui "$candidate/assets/webui.zip"
# Full parser validation, not only file presence: a corrupted but rehashed
# candidate still must fail before installing anything.
cp "$candidate/template.yaml" /tmp/saved-template
printf '\ntun:\n  enable: true\n' >> "$candidate/template.yaml"
python3 - <<'PY'
import hashlib
from pathlib import Path
r=Path('/tmp/preflight-candidate');p=r/'SHA256SUMS'
p.write_text(''.join(f'{hashlib.sha256((r/line.split("  ",1)[1]).read_bytes()).hexdigest()}  {line.split("  ",1)[1]}\n' for line in p.read_text().splitlines()))
PY
expect_bad run_good --check
grep -q '完整配置未通过' /tmp/preflight-last.log
mv /tmp/saved-template "$candidate/template.yaml"
cp /src/SHA256SUMS "$candidate/SHA256SUMS"
run_good --check
clean_state
echo 'PASS: missing core/yq/dependency/rule/UI, wrong digest/architecture, forbidden config, and valid precheck all leave installation untouched; no curl/apt invoked'
