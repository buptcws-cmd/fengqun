# 授权策略

## 当前模式

- control plane：`external-git`
- startup level：`__STARTUP_LEVEL__`
- 当前 scope：`__SCOPE_ID__`
- 产品仓：`__PRODUCT_REPO_ID__`

## 自动允许

- 读取并核对控制仓、产品仓、worktree、进程和运行证据。
- 在控制仓声明范围内维护计划、状态、事件、消息、预算和交接。
- 初始化角色池为 `PLANNED`。
- 使用明确 allowlist 提交控制仓稳定事实。

## 仍需门槛

- 产品实现：需要产品提案、验证和审批门槛。
- 产品合并：需要精确 revision 的验证与独立评审结论。
- 密钥、外部账号、付费服务、发布、远程 push：`ASK`。
- 超出记录根目录的破坏性清理：`ASK`。
- reviewer 未通过仍继续：禁止，除非用户明确扩大授权。

## Level 1 限制

- 不启动后台角色。
- 不创建产品实现 worktree。
- 不启用 heartbeat。
- 不合并产品分支。
