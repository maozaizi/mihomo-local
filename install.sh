#!/bin/sh
# Offline only. All preflight checks precede account/file/service changes.
set -eu
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset MLOCAL_ROOT MLOCAL_PATH MLOCAL_API MLOCAL_LOCKED MIHOMO_LOCAL_LIB
fail() { printf '无法安装：%s\n检查未通过，尚未安装程序、创建用户或注册服务。\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail '请使用 sudo sh install.sh。'
[ "$(uname -s)" = Linux ] || fail '仅支持 Linux。'
. /etc/os-release
case "$ID:$VERSION_ID" in debian:12|debian:13|ubuntu:24.04) ;; *) fail '支持 Debian 12/13、Ubuntu 24.04。';; esac
case "$(uname -m)" in x86_64) arch=amd64; machine=62;; aarch64|arm64) arch=arm64; machine=183;; *) fail '仅支持 amd64/arm64。';; esac
pkg=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check_only=no; core_file=; core_sha=; yq_file=; yq_sha=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check_only=yes; shift; continue;;
        --help|-h)
            echo '用法：sudo sh install.sh [--check] [--mihomo 本地文件 --mihomo-sha256 摘要] [--yq 本地文件 --yq-sha256 摘要]'
            echo '安装器不联网、不执行 apt；缺少内核或依赖时停止。'; exit 0;;
    esac
    [ "$#" -ge 2 ] || fail '参数缺少取值。'
    case "$1" in
        --mihomo) core_file=$2;; --mihomo-sha256) core_sha=$2;;
        --yq) yq_file=$2;; --yq-sha256) yq_sha=$2;;
        *) fail "未知参数：$1";;
    esac
    shift 2
done
# Only inspect commands and files here: never auto-install missing packages.
missing=no
for dep in systemctl curl unzip flock timeout sha256sum ss getent useradd userdel groupdel od find awk sed grep head tail wc tr cp mv install chmod chown mkdir mktemp readlink ln rm cat dirname date touch cmp; do
    command -v "$dep" >/dev/null 2>&1 || { echo "缺少系统命令：$dep" >&2; missing=yes; }
done
[ -s /etc/ssl/certs/ca-certificates.crt ] || { echo '缺少 CA 证书：ca-certificates' >&2; missing=yes; }
[ "$missing" = no ] || fail '请提前准备依赖，参阅 DEPENDENCIES.md；不会联网补齐。'
[ -d /run/systemd/system ] || fail '需要 systemd 正常运行。'
echo "通过：$ID $VERSION_ID / $arch，系统依赖已准备。"
[ -f "$pkg/SHA256SUMS" ] || fail '缺少安装包校验清单。'
(cd "$pkg" && sha256sum --check --status SHA256SUMS) || fail '安装包缺少文件或摘要不匹配。'
version=$(cat "$pkg/VERSION")
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail '工具版本无效。'
# A full release provides vendor/bin. Source checkouts require explicit files
# AND trusted SHA256 values; no implicit download fallback exists.
if [ -z "$core_file" ]; then
    core_file="$pkg/vendor/bin/mihomo"
    [ -s "$core_file" ] || fail "尚未准备 Mihomo 内核。当前架构 $arch；请选择完整离线包，或指定 --mihomo 文件 --mihomo-sha256 摘要。"
    core_sha=$(awk '$2 == "vendor/bin/mihomo" {print $1}' "$pkg/SHA256SUMS")
fi
if [ -z "$yq_file" ]; then
    yq_file="$pkg/vendor/bin/yq"
    [ -s "$yq_file" ] || fail '尚未准备 yq；请选择完整离线包，或指定 --yq 文件 --yq-sha256 摘要。'
    yq_sha=$(awk '$2 == "vendor/bin/yq" {print $1}' "$pkg/SHA256SUMS")
fi
verify_binary() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail '二进制文件缺失或为符号链接。'
    case "$2" in ''|*[!a-fA-F0-9]*) fail '本地二进制必须提供可信 SHA256。';; esac
    [ "${#2}" = 64 ] || fail 'SHA256 长度错误。'
    actual=$(sha256sum "$1"); actual=${actual%% *}
    [ "$actual" = "$(printf '%s' "$2" | tr A-F a-f)" ] || fail '二进制 SHA256 不匹配。'
    magic=$(od -An -tu1 -N6 "$1" | tr -s ' ' | sed 's/^ //;s/ $//')
    [ "$magic" = '127 69 76 70 2 1' ] || fail '需要 Linux ELF64 小端可执行文件。'
    set -- $(od -An -tu1 -j18 -N2 "$1")
    [ "$#" = 2 ] && [ "$1" = "$machine" ] && [ "$2" = 0 ] || fail "内核或 yq 架构不匹配，当前服务器需要 $arch。"
}
verify_binary "$core_file" "$core_sha"
verify_binary "$yq_file" "$yq_sha"
# Refuse existing deployments and conflicts before creating any service account.
for path in /usr/local/bin/mihomo /usr/local/bin/yq /usr/local/bin/mihomo-local /usr/local/bin/mihomo-proxy /etc/profile.d/mihomo-proxy.sh /etc/systemd/system/mihomo-local.service /etc/systemd/system/mihomo-local-update.service /etc/systemd/system/mihomo-local-update.timer /usr/local/lib/mihomo-local /etc/mihomo-local /var/lib/mihomo-local; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "已有文件或部署：$path；拒绝覆盖。"
done
for name in mihomo mihomo-local; do
    ! command -v "$name" >/dev/null 2>&1 || fail "已有 $name，不自动替换。"
done
! getent passwd mihomo-local >/dev/null || fail '已有同名用户，拒绝接管。'
! getent group mihomo-local >/dev/null || fail '已有同名用户组，拒绝接管。'
listeners=$(ss -H -lntup) || fail '无法检查端口占用。'
if printf '%s\n' "$listeners" | grep -Eq ':(7890|9090)[[:space:]]'; then fail '7890 或 9090 端口已被占用。'; fi
work=$(mktemp -d)
created_user=no; installed=no
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
        echo '安装未完成，本工具创建的服务和文件已撤回。' >&2
    fi
    rm -rf "$work"
    exit "$result"
}
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/bin"
cp "$core_file" "$work/bin/mihomo"; cp "$yq_file" "$work/bin/yq"
chmod 755 "$work/bin/mihomo" "$work/bin/yq"
core_version=$("$work/bin/mihomo" -v) || fail '内核无法在当前系统执行。'
printf '%s\n' "$core_version" | grep -Eq '^Mihomo Meta v?[0-9]+\.[0-9]+\.[0-9]+ ' || fail '需要 Mihomo 稳定版本。'
"$work/bin/yq" --version | grep -q 'github.com/mikefarah/yq/.*version v4\.' || fail '需要 Mike Farah yq v4。'
"$work/bin/yq" -n -e '[1, 2] | any_c(. == 2)' >/dev/null 2>&1 || fail 'yq 缺少订阅命名空间所需功能；请使用随包的 yq 4.54.2。'
echo "通过：$(printf '%s\n' "$core_version" | head -n1)"
# Exercise the SAME guard/resources/template as init, entirely under /tmp.
(
    export MIHOMO_LOCAL_LIB="$pkg" MLOCAL_ROOT="$work/preflight" MLOCAL_PATH="$work/bin:$PATH"
    . "$pkg/lib/common.sh"
    . "$NL_LIB/resources.sh"
    mkdir -p "$(dirname "$NL_RUN")" "$NL_RUN_DIR/providers" || exit 1
    ML_SECRET=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n'); export ML_SECRET
    yq e '.secret = strenv(ML_SECRET)' "$pkg/template.yaml" > "$NL_RUN" || exit 1
    nl_placeholder "$NL_SUB_EMPTY" "$NL_SUB_TARGET" || exit 1
    resources_prepare "$NL_PKG" "$NL_RUN_DIR" "$work/resources" || exit 1
    nl_assert_config || exit 1
    timeout 120 mihomo -t -d "$NL_RUN_DIR" -f "$NL_RUN" > "$work/preflight.log" 2>&1
) || fail '规则/WebUI 不完整，或完整配置未通过内核校验。'
echo '通过：完整本地规则、WebUI 和无透明代理配置校验；无需下载 GeoIP/GeoSite 数据库。'
if [ "$check_only" = yes ]; then echo '预检查通过。尚未安装文件、创建用户或注册服务。'; exit 0; fi
useradd --system --user-group --home-dir /var/lib/mihomo-local/core --no-create-home --shell /usr/sbin/nologin mihomo-local
created_user=yes
install -d -m 755 /usr/local/lib/mihomo-local /usr/local/bin
digest=$(sha256sum "$pkg/SHA256SUMS"); digest=${digest%% *}
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
install -m 755 "$work/bin/mihomo" /usr/local/bin/mihomo
install -m 755 "$work/bin/yq" /usr/local/bin/yq
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
echo '离线安装完成；尚未添加节点，服务运行不代表代理可用。'
echo '请用 sub add 添加可访问订阅，或先导入本地节点 YAML。随后 source /etc/profile.d/mihomo-proxy.sh，再执行 mihomo-proxy on。'
echo 'Bash 登录终端自动加载；Zsh 请将 source /etc/profile.d/mihomo-proxy.sh 加入自己的 ~/.zshrc。'
