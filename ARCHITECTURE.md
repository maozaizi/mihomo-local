# 结构与不变量

`bin/mihomo-local` 只分发命令；`subscriptions.sh` 管清单、每来源节点、命名空间、版本发布；`parse.sh`/`uri/*.awk` 管解析；`core.sh` 是唯一访问内核 API 的模块；`common.sh` 管路径、锁、原子写和有界下载；`service.sh` 管首次初始化、诊断和定时开关。没有路由器兼容层。

命令流程：获取唯一锁 → 恢复先前 pending → 下载并解析各来源 → 异常骤减检查 → 合并并内核校验 → 写 pending → 原子切换 generation 指针 → 写 provider → API 刷新 → 轮询核对节点名 → 清理 pending。失败反向恢复，无法确认恢复保留 pending。读取命令不创建状态目录、不写日志、不恢复事务。保留 current/previous 两个业务版本；无节点变化不替换 previous。原子 rename 保证读者不见半文件，不承诺突然断电的 fsync 持久性。

只更新节点，不修改主模板。每个来源始终有稳定 `[sNNNN] ` 前缀，同源 dialer-proxy 引用按完全匹配改名。每源与合计最多 4096 节点、8 MiB 输入、解析总时限 120 秒。协议完全消失或节点数少于一半时拒绝更新该来源，只有显式 --force 接受。删除/回滚不复用 ID。

配置 guard 在 systemd ExecStartPre、每次发布、诊断时检查：固定回环代理/控制入口，拒绝 tun/listeners/tunnels/透明入站字段，拒绝 Fake-IP 或外部 DNS 监听；内核无 capabilities、PrivateDevices，因而无法开 TUN。主机网络完全由操作系统管理。

内核以 mihomo-local 用户运行，仅已有 cache.db 可写，provider/规则/UI 及父目录均为 root 所有；控制配置 root 管理，订阅清单 root 私有；发布文件 root:组 0640。systemd 更新任务以 root 运行，但仅持有 state/core 写权限。普通用户的开关不需 sudo，不读取控制密钥。

Shell hook 是父终端执行的函数；外部 mihomo-proxy 负责检查、保存数据和查看日志。状态文件只有 on/off，从不 source/eval。保存前做实际代理请求；失败不改变环境。重复 on 不覆盖原有环境备份，off 恢复 unset/空字符串的差异；其他终端不被异步修改。

第一版不提供内核自动升级、完整卸载、TUN 或后台服务全局接管。安装器仅全新部署，安装前验证包和二进制，失败撤回本工具创建的服务、账号和文件；系统依赖安装不撤回。
