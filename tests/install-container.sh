#!/bin/sh
# Only in a disposable Debian container. PID 1/systemctl scheduling is simulated;
# the service itself is a real Mihomo process running under the real service UID.
set -eu
[ "${ML_DISPOSABLE_CONTAINER:-}" = yes ] || exit 2
mkdir -p /run/systemd/system /usr/local/bin /usr/local/sbin
cat > /usr/local/sbin/apt-get <<'EOF'
#!/bin/sh
exit 0
EOF
cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    daemon-reload) exit 0;;
    enable)
        case "$*" in
            *mihomo-local.service*)
                [ ! -f /tmp/fail-service ] || exit 1
                if [ -f /tmp/test-core.pid ] && kill -0 "$(cat /tmp/test-core.pid)" 2>/dev/null; then exit 0; fi
                runuser -u mihomo-local -- /usr/local/bin/mihomo-local guard
                runuser -u mihomo-local -- /usr/local/bin/mihomo -d /var/lib/mihomo-local/core -f /etc/mihomo-local/config.yaml > /tmp/installed-core.log 2>&1 5>&- &
                echo "$!" > /tmp/test-core.pid;;
        esac
        exit 0;;
    disable)
        if [ -f /tmp/test-core.pid ]; then kill "$(cat /tmp/test-core.pid)" 2>/dev/null || true; rm -f /tmp/test-core.pid; fi
        exit 0;;
    is-active) [ -f /tmp/test-core.pid ] && kill -0 "$(cat /tmp/test-core.pid)";;
    is-enabled) echo enabled;exit 0;;
    *) exit 1;;
esac
EOF
chmod 755 /usr/local/sbin/apt-get /usr/local/bin/systemctl
candidate=/tmp/mihomo-local-candidate
mkdir -p "$candidate"
cp -R /src/. "$candidate/"
printf 'DEMO_EXCLUDED_FILE\n' > "$candidate/.env"
mkdir -p "$candidate/.git"
printf 'DEMO_EXCLUDED_GIT_METADATA\n' > "$candidate/.git/config"
core_sha=$(sha256sum /tools/mihomo);core_sha=${core_sha%% *}
yq_sha=$(sha256sum /tools/yq);yq_sha=${yq_sha%% *}
# Record host-network state in this container, not just source-level assurances.
sha256sum /etc/resolv.conf > /tmp/dns-before
ip -j address > /tmp/address-before
ip -j route > /tmp/route-before
# Failed startup must remove product-owned files and user; it must be retryable.
touch /tmp/fail-service
if sh "$candidate/install.sh" --mihomo /tools/mihomo --mihomo-sha256 "$core_sha" --yq /tools/yq --yq-sha256 "$yq_sha"; then exit 10; fi
[ ! -e /etc/mihomo-local ] && [ ! -e /usr/local/bin/mihomo ] && [ ! -e /usr/local/lib/mihomo-local ]
! getent passwd mihomo-local >/dev/null
rm -f /tmp/fail-service
sh "$candidate/install.sh" --mihomo /tools/mihomo --mihomo-sha256 "$core_sha" --yq /tools/yq --yq-sha256 "$yq_sha"
/usr/local/bin/mihomo-local doctor
[ ! -e /usr/local/lib/mihomo-local/current/.env ]
[ ! -e /usr/local/lib/mihomo-local/current/.git ]
sha256sum /etc/mihomo-local/config.yaml > /tmp/config-before
/usr/local/bin/mihomo-local init
sha256sum --check --status /tmp/config-before
# Dedicated UID can read the provider but cannot read subscription registry.
runuser -u mihomo-local -- test -r /var/lib/mihomo-local/core/providers/subscriptions.yaml
runuser -u mihomo-local -- test -w /var/lib/mihomo-local/core/cache.db
if runuser -u mihomo-local -- test -w /var/lib/mihomo-local/core; then exit 13; fi
if runuser -u mihomo-local -- mv /var/lib/mihomo-local/core/providers /var/lib/mihomo-local/core/providers-renamed 2>/dev/null; then exit 14; fi
if runuser -u mihomo-local -- test -r /var/lib/mihomo-local/state/subscriptions/current/registry.yaml; then exit 11; fi
cat > /tmp/fixture.yaml <<'EOF'
proxies:
  - {name: Demo, type: ss, server: 127.0.0.1, port: 39999, cipher: aes-128-gcm, password: TEST_ONLY}
EOF
/usr/local/bin/mihomo-local sub add /tmp/fixture.yaml --name '安装验收'
/usr/local/bin/mihomo-local update
/usr/local/bin/mihomo-local doctor
sha256sum --check --status /tmp/config-before
# Refuse to overwrite an installed deployment.
if sh "$candidate/install.sh" --mihomo /tools/mihomo --mihomo-sha256 "$core_sha" --yq /tools/yq --yq-sha256 "$yq_sha"; then exit 12; fi
systemd-analyze verify /etc/systemd/system/mihomo-local.service /etc/systemd/system/mihomo-local-update.service /etc/systemd/system/mihomo-local-update.timer
sha256sum --check --status /tmp/dns-before
ip -j address > /tmp/address-after
ip -j route > /tmp/route-after
cmp /tmp/address-before /tmp/address-after
cmp /tmp/route-before /tmp/route-after
# Ensure the running process really uses the unprivileged account.
python3 - <<'PYTEST'
import os,pathlib,pwd
uid=pwd.getpwnam('mihomo-local').pw_uid
assert any(p.name.isdigit() and p.stat().st_uid==uid and (p/'comm').exists() and (p/'comm').read_text().strip()=='mihomo' for p in pathlib.Path('/proc').iterdir())
PYTEST
[ "$(yq 'has("tun")' /etc/mihomo-local/config.yaml)" = false ]
echo 'PASS: fresh install, failed-start rollback/retry, service UID, permissions, subscription publish, idempotent init, overwrite refusal, unit syntax, unchanged routes/interfaces/resolv.conf'
systemctl disable --now mihomo-local.service
