# 1.0.0 验证记录 — 2026-11-07

## 已验证

环境：隔离 Debian 13 arm64 Docker 容器，网络关闭。真实 Linux Mihomo 1.19.33、Mike Farah yq 4.54.2、dash、flock、timeout、Bash、Zsh；所有应用请求都在回环接口。测试订阅为人工构造数据，无生产凭据。

21 项 Python 集成测试：

- 多来源同名节点隔离、更新全部来源、删除和回滚；主配置字节不变。
- 单来源失败保留旧节点，其余来源正常更新；退出码 2。
- 节点骤减、协议消失保护，显式 --force 接受变化。
- 原生 Base64 六节点全部保留，跳过类型明确报告；解析超时和 8 MiB 输入限制。
- 合计 4100 节点被拒绝，现有 2050 节点不变。
- API 发布失败恢复原 provider/清单；写进程被杀后下一次写操作恢复 pending。
- 查询操作不恢复 pending、不修改订阅状态；并发写被真实 flock 拒绝。
- 本地 YAML 更新重新读取原文件；重复 URL 被拒绝。
- 含禁止的网络入口配置在发布前被拒绝。
- 直连下载失败时携带本地代理配置重试（下载链路模拟，非公网测试）。
- Bash/Zsh：重复 on、off 恢复原值与 unset/空字符串区别、失败不启用、保存状态加载。
- 真实 HTTP 请求：AI/TikTok 出口独立，国内 IP 兜底解析后直连，no-resolve 对照，空组拒绝。

完整安装容器验收：

- 本地二进制 + SHA256 安装，全包资源摘要校验。
- 注入服务启动失败后撤回自建文件/用户，可重新安装。
- 真实专用普通用户运行 Mihomo、读取 provider；无法读取 root 私有订阅清单。
- 重复 init 保留密钥/模板，添加订阅并刷新真实内核。
- 拒绝覆盖已安装部署。
- systemd-analyze verify 三份 unit 通过。
- 安装前后网卡地址、路由和 `/etc/resolv.conf` 一致。

所有 shell 文件通过 `sh -n`；发布包 SHA256SUMS 与 ZIP/tar.gz 内容核对。

## 验证范围

Docker 的 PID 1 不是 systemd；安装测试模拟 systemctl 启停和定时器登记，真实执行 guard 和普通用户内核。真实 systemd 开机启动、计时触发和安全隔离设置仍需首台服务器部署验收。未在真实 Ubuntu/amd64 主机运行；未测试真实付费节点、公网连通、云安全组或 SSH 登录环境。

安装器在线 GitHub 下载分支依据官方 release API 实现，支持资产 digest 校验；完整安装验收使用预备二进制，未重复在线安装最新内核。安装时若官方资产命名或摘要不可用，会停止，不降级到不校验安装。

## 复现

用 `tests/Dockerfile` 创建 `mihomo-local-test:debian13`。准备可信 Linux arm64 Mihomo/yq，可挂载到 `/tools/mihomo`、`/tools/yq`，将源码只读挂载到 `/src`。

测试套件在容器内：

```sh
install -m755 /tools/yq /usr/local/bin/yq
install -m755 /tools/mihomo /usr/local/bin/mihomo
cd /src
python3 -B -m unittest discover -s tests -v
```

完整安装测试使用另一个全新容器（不能先安装二进制到 /usr/local/bin），环境设置 `ML_DISPOSABLE_CONTAINER=yes`，执行 `sh /src/tests/install-container.sh`。该脚本会操作容器内 /etc 和用户账号，禁止在真实服务器直接执行。

## 1.0.1 公开发布前回归 — 2026-11-07

23 项测试全部通过（原 21 项 + 两项发布隐私测试）。重新执行完整安装验收，确认：

- 服务 UID 仅可写 cache.db，不能写工作目录或重命名 provider 父目录。
- 源目录额外存在 .env 和 .git 时，安装目录不包含它们。
- 打包排除未批准文件，拒绝符号链接，tar 不包含本机用户名/归属信息。
- 安装、失败撤回、重复初始化、真实内核发布、网络配置不变和 unit 语法继续通过。

泄密扫描和开源资源检查见 SECURITY_AUDIT.md。实际服务器验证范围仍按上文限制。
