# 授权策略

## 当前模式

- control plane：`external-git`
- startup level：`__STARTUP_LEVEL__`
- 当前 scope：`__SCOPE_ID__`
- 产品仓：`__PRODUCT_REPO_ID__`

## 默认批准语义

- 默认批准是当前 outcome lock 内的执行授权，用于自动排空安全工作和减少重复审批。
- 它不是修改产品目标、MVP、非目标、用户可见证明、公共能力族或估时基线的授权。
- 角色和 subagent 权限不得超过操作者上限；产品意图不能靠权限继承。

## 自动允许

以下自动权限同时受当前 startup level 和 Outcome Lock 约束；低档位禁止项优先。默认批准不能越过启动档位。

- 读取并核对控制仓、产品仓、worktree、进程和运行证据。
- 仅总控 tracked writer 在控制仓声明范围内维护计划、状态、事件、消息、预算和交接；角色只写 assignment-bound runtime transport，由总控验证提升。
- 初始化角色池为 `PLANNED`。
- 使用明确 allowlist 提交控制仓稳定事实。
- 仅在 Level 2/3 允许的范围内，按当前 outcome-lock revision、声明路径、风险上限和估时容差执行常规实现、验证、审查、提交与集成。
- 为实现 locked outcome 自主选择可逆内部设计，并优先复用/适配现有能力。

## 仍需门槛

- 产品实现：需要产品提案、验证和审批门槛。
- 改变目标、MVP、非目标、公共能力族或显著调整估时：合并证据、最小方案、备选和影响后一次 `ASK`。
- outcome lock 外的新架构 owner、持久数据义务、迁移承诺或外部依赖：`ASK`。
- 产品合并：需要精确 revision 的验证与独立评审结论。
- 密钥、外部账号、付费服务、发布、远程 push：`ASK`。
- 超出记录根目录的破坏性清理：`ASK`。
- reviewer 未通过仍继续：禁止，除非用户明确扩大授权。

用户确认并更新 outcome_lock_revision 后，不对未变化的范围内文件、命令、角色、测试或正常合并重复索权。

## Level 1 限制

- 不启动后台角色。
- 不创建产品实现 worktree。
- 不启用 heartbeat。
- 不合并产品分支。
- 不修改产品代码或产品规范性规格/契约。
- 不创建产品实现提交、集成意图或产品基线更新。
