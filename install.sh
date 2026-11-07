#!/bin/sh
# Debian/Ubuntu installer. Network downloads occur only here, not in updates.
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" = 0 ] || { echo '请使用 sudo sh install.sh。' >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo '仅支持 Linux。' >&2; exit 1; }
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) echo '第一版仅支持 Debian/Ubuntu。' >&2; exit 1;; esac
command -v systemctl >/dev/null && [ -d /run/systemd/system ] || { echo '需要 systemd 正常运行。' >&2; exit 1; }
pkg=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Verify before sourcing or installing any package content.
(cd "$pkg" && sha256sum --check --status SHA256SUMS) || { echo '安装包校验失败。' >&2; exit 1; }
core_file=; core_sha=; yq_file=; yq_sha=
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || exit 2
    case "$1" in
        --mihomo) core_file=$2;; --mihomo-sha256) core_sha=$2;;
        --yq) yq_file=$2;; --yq-sha256) yq_sha=$2;;
        *) echo '支持 --mihomo 文件 --mihomo-sha256 摘要 --yq 文件 --yq-sha256 摘要' >&2; exit 2;;
    esac
    shift 2
done
for path in /usr/local/bin/mihomo /usr/local/bin/yq /usr/local/bin/mihomo-local /usr/local/bin/mihomo-proxy /etc/profile.d/mihomo-proxy.sh /etc/systemd/system/mihomo-local.service /etc/systemd/system/mihomo-local-update.service /etc/systemd/system/mihomo-local-update.timer /usr/local/lib/mihomo-local /etc/mihomo-local /var/lib/mihomo-local; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || { echo "已有文件或部署：$path；第一版拒绝覆盖。" >&2; exit 1; }
done
for name in mihomo mihomo-local; do
    if command -v "$name" >/dev/null 2>&1; then echo "已有 $name；请先确认现有服务，不自动替换。" >&2; exit 1; fi
done
# Refuse even a currently stopped, unrelated service account of the same name.
! getent passwd mihomo-local >/dev/null || { echo '已有同名用户，拒绝接管。' >&2; exit 1; }
missing=no
for dep in curl jq unzip flock timeout sha256sum ss gzip useradd; do
    command -v "$dep" >/dev/null 2>&1 || missing=yes
done
[ -s /etc/ssl/certs/ca-certificates.crt ] || missing=yes
if [ "$missing" = yes ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates jq unzip util-linux coreutils iproute2 passwd
fi
if ss -H -lntup | grep -Eq ':(7890|9090)[[:space:]]'; then echo '7890 或 9090 端口已被占用。' >&2; exit 1; fi
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) echo '仅支持 amd64/arm64。' >&2; exit 1;; esac
work=$(mktemp -d)
created_user=no
installed=no
cleanup_install() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$result" -ne 0 ] && [ "$created_user" = yes ] && [ "$installed" = no ]; then
        systemctl disable --now mihomo-local-update.timer mihomo-local.service >/dev/null 2>&1
        rm -f /usr/local/bin/mihomo /usr/local/bin/yq /usr/local/bin/mihomo-local /usr/local/bin/mihomo-proxy /etc/profile.d/mihomo-proxy.sh
        rm -f /etc/systemd/system/mihomo-local.service /etc/systemd/system/mihomo-local-update.service /etc/systemd/system/mihomo-local-update.timer
        rm -rf /usr/local/lib/mihomo-local /etc/mihomo-local /var/lib/mihomo-local
        userdel mihomo-local >/dev/null 2>&1
        groupdel mihomo-local >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
        echo '安装未完成，本工具创建的服务和文件已撤回；已安装的系统依赖保留。' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
verify() {
    case "$2" in ''|*[!a-fA-F0-9]*) echo '缺少有效 SHA256 摘要。' >&2; return 1;; esac
    [ "${#2}" = 64 ] || return 1
    actual=$(sha256sum "$1"); actual=${actual%% *}
    [ "$actual" = "$(printf '%s' "$2" | tr A-F a-f)" ] || { echo '文件 SHA256 不匹配。' >&2; return 1; }
}
fetch_release() {
    repo=$1; asset=$2; out=$3
    curl --noproxy '*' -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 \
        "https://api.github.com/repos/$repo/releases/latest" -o "$work/release.json"
    jq -e '.draft == false and .prerelease == false' "$work/release.json" >/dev/null
    url=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' "$work/release.json")
    digest=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .digest | select(startswith("sha256:"))' "$work/release.json")
    case "$url" in "https://github.com/$repo/releases/download/"*) ;; *) exit 1;; esac
    curl --noproxy '*' -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 300 "$url" -o "$out"
    verify "$out" "${digest#sha256:}"
}
if [ -n "$yq_file" ]; then verify "$yq_file" "$yq_sha"; cp "$yq_file" "$work/yq"
else fetch_release mikefarah/yq "yq_linux_$arch" "$work/yq"; fi
chmod 755 "$work/yq"
"$work/yq" --version | grep -q 'github.com/mikefarah/yq/.*version v4\.' || { echo '需要 Mike Farah yq v4。' >&2; exit 1; }
if [ -n "$core_file" ]; then verify "$core_file" "$core_sha"; cp "$core_file" "$work/mihomo"
else
    tag=$(curl --noproxy '*' -fsSL --proto '=https' --connect-timeout 10 --max-time 60 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -er '.tag_name')
    case "$tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) exit 1;; esac
    # Pin the same tag for both asset naming and release metadata.
    repo=MetaCubeX/mihomo; asset="mihomo-linux-$arch-$tag.gz"
    curl --noproxy '*' -fsSL --proto '=https' --connect-timeout 10 --max-time 60 "https://api.github.com/repos/$repo/releases/tags/$tag" -o "$work/release.json"
    jq -e '.draft == false and .prerelease == false' "$work/release.json" >/dev/null
    url=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' "$work/release.json")
    digest=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .digest | select(startswith("sha256:"))' "$work/release.json")
    case "$url" in "https://github.com/$repo/releases/download/$tag/"*) ;; *) exit 1;; esac
    curl --noproxy '*' -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 300 "$url" -o "$work/mihomo.gz"
    verify "$work/mihomo.gz" "${digest#sha256:}"
    gzip -dc "$work/mihomo.gz" > "$work/mihomo"
fi
chmod 755 "$work/mihomo"
"$work/mihomo" -v | grep -Eq '^Mihomo Meta v?[0-9]+\.[0-9]+\.[0-9]+ ' || { echo '内核无法执行或不是稳定版本号。' >&2; exit 1; }
# All downloads and checks precede system mutations specific to this product.
useradd --system --user-group --home-dir /var/lib/mihomo-local/core --no-create-home --shell /usr/sbin/nologin mihomo-local
created_user=yes
install -d -m 755 /usr/local/lib/mihomo-local /usr/local/bin
version=$(cat "$pkg/VERSION"); digest=$(sha256sum "$pkg/SHA256SUMS"); digest=${digest%% *}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || exit 1
release="/usr/local/lib/mihomo-local/releases/$version-${digest%${digest#????????????}}"
install -d -m 755 "$release"
# Copy exactly the verified manifest. A developer's .git, .env, backups or
# other unlisted files must never become installed/publicly readable files.
while IFS= read -r entry; do
    relative=${entry#*  }
    case "$relative" in ''|/*|../*|*/../*|*/..|.git|.git/*) echo '清单路径无效。' >&2; exit 1;; esac
    [ -f "$pkg/$relative" ] && [ ! -L "$pkg/$relative" ] || exit 1
    (cd "$pkg" && cp --parents -- "$relative" "$release/")
done < "$pkg/SHA256SUMS"
cp "$pkg/SHA256SUMS" "$release/"
chmod -R a+rX "$release"
ln -s "$release" /usr/local/lib/mihomo-local/current
install -m 755 "$work/mihomo" /usr/local/bin/mihomo
install -m 755 "$work/yq" /usr/local/bin/yq
for name in mihomo-local mihomo-proxy; do
    printf '#!/bin/sh\nunset MLOCAL_ROOT MLOCAL_PATH MLOCAL_API MLOCAL_LOCKED MIHOMO_LOCAL_LIB\nexec /usr/local/lib/mihomo-local/current/bin/%s "$@"\n' "$name" > "/usr/local/bin/$name"
    chmod 755 "/usr/local/bin/$name"
done
install -m 644 "$release/shell/mihomo-proxy.sh" /etc/profile.d/mihomo-proxy.sh
install -m 644 "$release"/systemd/* /etc/systemd/system/
install -d -o root -g mihomo-local -m 750 /var/lib/mihomo-local /etc/mihomo-local
install -d -o root -g root -m 700 /var/lib/mihomo-local/state
install -d -o mihomo-local -g mihomo-local -m 750 /var/lib/mihomo-local/core
systemctl daemon-reload
/usr/local/bin/mihomo-local init
installed=yes
echo '安装完成。添加订阅后，当前终端执行 source /etc/profile.d/mihomo-proxy.sh，再执行 mihomo-proxy on。'
echo 'Bash 登录终端自动加载；Zsh 请将 source /etc/profile.d/mihomo-proxy.sh 加入自己的 ~/.zshrc。'
