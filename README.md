# mihomo-local 1.0.1

面向 Debian/Ubuntu Linux 服务器的轻量订阅管理工具。应用主动使用本机 HTTP/SOCKS 代理，Mihomo 按规则分流。独立于 Nikki/OpenWrt；现有 nikki-local 不受影响。

## 产品边界

- 不提供 TUN，不提供 redirect/tproxy，不修改系统路由、防火墙或系统 DNS。
- 模板根本不含 `tun`；启动前拒绝包含该键的配置，即使 enable 为 false。
- 代理固定监听 `127.0.0.1:7890`，控制接口固定 `127.0.0.1:9090`。不向公网开放。
- 终端开关只影响当前用户的当前 Shell 和后续新 Shell，不强制接管所有流量。
- systemd 服务、Docker 容器和已经运行的程序需要单独配置代理；不自动修改其他服务。
- 当前版本面向全新部署，安装器拒绝覆盖已有内核、同名账号、文件和服务。尚不提供原地升级或卸载命令。

## 新服务器安装

支持 Debian/Ubuntu、systemd、amd64/arm64。将完整发布包上传服务器、解压后：

```sh
sudo sh install.sh
sudo mihomo-local sub add 'https://你的订阅地址' --name '主订阅'
source /etc/profile.d/mihomo-proxy.sh
mihomo-proxy on
mihomo-proxy status
```

安装器补齐 curl、CA 证书、jq（仅安装阶段）、unzip、util-linux/flock、coreutils/timeout、iproute2；从官方最新非预发布 Release 下载 Mihomo 和 Mike Farah yq v4，核对 GitHub 资产 SHA256 后安装。上游缺少资产摘要时停止，不跳过校验。首次安装需要访问软件源和 GitHub；若访问不通，可以预先准备 Linux 可执行文件和从可信渠道核对的摘要：

```sh
sudo sh install.sh \
  --mihomo /绝对路径/mihomo --mihomo-sha256 '64位SHA256' \
  --yq /绝对路径/yq --yq-sha256 '64位SHA256'
```

这条方式跳过两项 GitHub 下载；系统依赖仍需已经安装，或可用的软件源；依赖齐全时不访问软件源。规则和 WebUI 随包提供，不依赖首次访问 GitHub。内核不随日常订阅更新自动升级。

安装完成时启动空节点服务（空组拒绝转发），并启用每小时更新。添加有效订阅、选好节点后开启终端代理。没有有效节点时不要把“服务在运行”当成“代理可用”。

Bash 登录终端通过 `/etc/profile.d` 加载。Zsh 用户在 `~/.zshrc` 手动加入一行：

```sh
source /etc/profile.d/mihomo-proxy.sh
```

Bash 非登录交互终端如未读取系统 profile，也可在自己的 `~/.bashrc` 加入同一行。安装器不会改写任何用户的 dotfiles。

## 日常使用

```sh
mihomo-proxy on             # 实际 HTTPS 请求返回 204 后，开启并保存当前用户选择
mihomo-proxy off            # 恢复本终端之前的 HTTP/HTTPS/no_proxy 设置
mihomo-proxy status         # 本终端是否接入、保存状态、服务状态、实际请求
mihomo-proxy log            # 最近 100 条内核日志（普通用户通过 sudo 读取）
mihomo-proxy log --follow   # 持续查看日志
```

`on` 用 https://cp.cloudflare.com 做一次实际代理检查，失败不会修改环境或保存开启状态；检测目标不可达也可能导致检查失败，并不证明所有节点均不可用。新 Shell 按保存状态加载变量，不在登录过程中发网络请求；实际可用性用 status 检查。

`off` 不停止内核，也不关闭订阅定时任务。开关按用户保存，其他已经打开的终端需各自执行 on/off。不设置 ALL_PROXY，不修改 Git/apt 的持久代理配置，也不保证每个软件识别代理环境变量。开启后国内仍按规则直连。

```sh
sudo mihomo-local sub add 'https://第二份订阅' --name '备用订阅'
sudo mihomo-local sub list
sudo mihomo-local sub set-url s0002 'https://新地址'
sudo mihomo-local sub remove s0002
sudo mihomo-local update
sudo mihomo-local update --force  # 确认骤减/协议移除属正常变化后使用
sudo mihomo-local rollback
sudo mihomo-local sub recover
sudo mihomo-local schedule off
sudo mihomo-local schedule hourly
sudo mihomo-local doctor
sudo mihomo-local logs
```

订阅下载先直连，失败后通过已运行的 `127.0.0.1:7890` 代理重试一次，不依赖交互终端的环境变量。首次订阅若无法直连、又没有可用节点，需要先准备可访问的订阅或本地 YAML 引导。

更新始终针对所有已记录订阅。单个失败保留旧节点，其余正常发布，退出码 2 表示部分失败（systemd 视为已执行，操作日志仍记录失败）。下载/解析/发布失败不会伪装成成功。

接受带 `proxies` 的 Mihomo YAML/JSON，也沿用已验证的 SS/VLESS/VMess/Trojan/Hysteria2/TUIC 明文或 Base64 链接解析器。仅提取节点，不采用订阅中的规则、DNS、端口或其他配置。不调用第三方转换 API。不支持的链接类型会明确报告跳过数量与原因。第一份订阅内容本身已缺节点时，程序无法凭空知道缺少多少；请核对显示的数量和协议组成。

也支持绝对路径本地文件，后续 update 会重新读取原路径；不要删除源文件或把带凭据的文件放在公共可读位置。不提供额外手动节点库命令，需要时可用独立本地 YAML 订阅维护。

## 配置、日志和服务

| 路径 | 内容 |
| --- | --- |
| `/etc/mihomo-local/config.yaml` | 实际主配置、规则、随机控制密钥；root:组，0640 |
| `/var/lib/mihomo-local/state` | 订阅地址、原节点、两版快照、私有操作日志；root 0700 |
| `/var/lib/mihomo-local/core/providers/subscriptions.yaml` | 合并节点；内核只读 |
| `/var/lib/mihomo-local/core/rule-providers` | 随包的规则快照 |
| `/var/lib/mihomo-local/core/ui` | 随包的 WebUI |
| `~/.local/state/mihomo-proxy/state` | 当前用户的 on/off（遵循 XDG_STATE_HOME） |

分流保留手动选择、自动选择、AI服务、TikTok 策略组，国内域名/IP 直连和私网直连。DNS 是 Mihomo 内部真实地址解析，不监听系统 DNS 端口。规则使用本地快照，订阅更新不更新规则、不重写模板。不包含路由器上用户另行添加的站点规则。

服务：`mihomo-local.service`（专用无登录用户、空 capability、无设备权限）、`mihomo-local-update.service`、`mihomo-local-update.timer`。更新工具通过 sudo 管理，内核不需要 root 或网络管理权限。

内核日志可能包含访问目标，排障分享前请脱敏。订阅操作日志不记录 URL、密钥或节点凭据。

## WebUI

在服务器上通过本地控制接口访问。远程管理建议 SSH 转发：

```sh
ssh -L 9090:127.0.0.1:9090 用户@服务器
```

本机访问 `http://127.0.0.1:9090/ui/`，填写控制接口和配置中的 `secret`。每次全新初始化生成独立随机密钥，重复 init 不重置。不要把控制接口改为公网监听。

## 开发与测试

见 `ARCHITECTURE.md`、`VALIDATION.md`。`tools/package.py` 生成 SHA256SUMS、ZIP 与 tar.gz。摘要用于完整性核对，不替代发布来源可信性验证。

协议解析和订阅事务移植自同工作区 nikki-local 4.1.0；第三方规则与 WebUI 的许可证及来源保留于 assets。本项目原创代码采用 [MIT](LICENSE) 许可证；第三方资源继续遵循各自许可证，见 [来源与许可说明](assets/UPSTREAM-NOTICES.md)。
