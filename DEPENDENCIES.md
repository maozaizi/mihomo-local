# 离线部署前的系统准备

支持 Debian 12、Debian 13、Ubuntu 24.04；需要真实运行的 systemd、root 权限和 amd64/arm64 CPU。安装器不会调用 apt、访问 GitHub 或自动下载任何文件。

完整架构包已含 Mihomo、Mike Farah yq、规则和 WebUI。系统命令与 CA 证书仍需由系统镜像或管理员提前提供。

| 系统包 | 用途 |
| --- | --- |
| curl | 安装后访问本地控制接口、下载订阅、代理连通检测 |
| ca-certificates | HTTPS 证书验证 |
| unzip | 本地解压 WebUI |
| util-linux | flock 操作锁 |
| coreutils | timeout、sha256sum、od、install、基础文件操作 |
| iproute2 | ss 检查本机端口冲突 |
| passwd | useradd/userdel/groupdel 管理专用服务账号 |
| systemd | 服务与定时器 |
| findutils、diffutils、grep、sed、mawk 或 gawk、libc-bin | 基础检查与解析命令，通常随系统安装 |

本项目不要求 jq、Python 或 Node 作为服务器运行依赖；Python 仅供准备机打包和开发测试使用。普通用户执行需要管理员权限的命令时还需要 sudo，或直接使用 root。

## 管理员如何补齐

如果软件源可以访问，可在安装本项目之前自行运行：

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends curl ca-certificates unzip util-linux coreutils iproute2 passwd systemd findutils diffutils grep sed mawk libc-bin
```

这不是安装器自动执行的步骤。若软件源不可访问，请在匹配发行版/版本/架构的联网环境准备相应 deb 包及其依赖，或者在服务器初始化镜像中预装。不要混用其他 Debian/Ubuntu 版本的依赖包。

资源齐全后运行 `sudo sh install.sh --check`。缺什么会明确列出；预检查失败只清理自己的临时目录，不创建用户、安装文件或注册服务。

## 源码包用户

Git clone 和 GitHub 自动生成的 Source code 包不包含内核二进制。需单独准备 Linux 对应架构的 Mihomo 稳定版和 Mike Farah yq v4，核对可信来源的 SHA256，再指定：

```sh
sudo sh install.sh --check \
  --mihomo /绝对路径/mihomo --mihomo-sha256 '可信SHA256' \
  --yq /绝对路径/yq --yq-sha256 '可信SHA256'
```

去掉 `--check` 才执行安装。安装器不复用、不覆盖 PATH 中已有的其他 Mihomo 部署。
