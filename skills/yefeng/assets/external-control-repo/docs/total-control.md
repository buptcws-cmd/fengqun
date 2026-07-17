# 野蜂总控

## 目标

通过独立控制仓协调 `__PROJECT_NAME__` 的多个模块和产品 worktree，同时保持产品仓是产品内容、正式规格/契约、验证和发布事实的权威来源。

## 不变量

- 顶层角色由总控分配，不自认领。
- 每个 scope 只有一个总控写者；共享区只有全局 integrator 写入。
- tracked control state、event、receipt 和 Markdown 投影视图形成同一个稳定 Git snapshot。
- 产品集成使用 `PREPARED -> PRODUCT_COMMITTED/VERIFIED -> CONTROL_COMMITTED` 可恢复事务。
- 产品 HEAD 漂移时中止并重新验证，不沿用旧证据。
- 暂停、交接、取消或接管后旧 epoch 输出只能作为迟到证据。

## 当前档位

- `__STARTUP_LEVEL__`
- 角色只规划，不启动。

## 升级条件

- 首个实现切片与非目标明确。
- 产品仓要求的正式变更提案或等价契约完成验证、评审并通过审批门槛。
- product/control 根、Git 身份、writer fence 和 transport probe 通过。
- 至少两个角色写入范围真正独立后，才可升级并行档位。
