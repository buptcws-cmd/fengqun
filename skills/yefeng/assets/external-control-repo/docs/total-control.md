# 野蜂总控

## 目标

通过独立控制仓协调 `__PROJECT_NAME__` 的多个模块和产品 worktree，同时保持产品仓是产品内容、正式规格/契约、验证和发布事实的权威来源。

## Outcome Lock

- status：`__OUTCOME_LOCK_STATUS__`
- outcome_lock_revision：`__OUTCOME_LOCK_REVISION__`
- 用户可见验收证明：`__USER_VISIBLE_PROOF__`
- 首个纵向切片：`__FIRST_VERTICAL_SLICE__`
- MVP / 非目标：`__MVP_AND_NON_GOALS__`
- 现有能力清单：`__EXISTING_CAPABILITY_INVENTORY__`
- reuse / adapt / new / defer：`__REUSE_ADAPT_NEW_DEFER__`
- 估时基线 / 偏移阈值：`__ESTIMATE_AND_DRIFT_THRESHOLDS__`

## 不变量

- 顶层角色由总控分配，不自认领。
- 每个 scope 只有一个总控写者；共享区只有全局 integrator 写入。
- tracked control state、event、receipt 和 Markdown 投影视图形成同一个稳定 Git snapshot。
- 产品集成使用 `PREPARED -> PRODUCT_COMMITTED/VERIFIED -> CONTROL_COMMITTED` 可恢复事务。
- 产品 HEAD 漂移时中止并重新验证，不沿用旧证据。
- 暂停、交接、取消或接管后旧 epoch 输出只能作为迟到证据。
- Level 3 control-spool 每个 scope 只有一个经 PID/启动时间/脚本路径与 hash/命令行/instance ID 校验的 broker；它只写 ignored runtime transport，不做调度或 tracked 治理决策。
- 总控按 broker sequence 幂等提升消息，并在同一 writer-fenced commit 中写 tracked event、receipt、状态和投影视图。
- 默认批准只授权 Outcome Lock 内的执行，不授权总控更换产品目标或静默扩大范围/工期。
- 每个 checkpoint 标注 PRODUCT_PATH_CLOSED / PRODUCT_PATH_ADVANCED / ENABLEMENT_ONLY / SPEC_ONLY / TEST_ONLY；用户价值与内部使能分开汇报。
- 两个连续实现 checkpoint 没有产品路径推进、出现第二层不可见前置、或估时越过记录阈值时，暂停受影响范围并提交一次批量决策。

## 当前档位

- `__STARTUP_LEVEL__`
- 角色只规划，不启动。

## 升级条件

- 首个实现切片与非目标明确。
- Outcome Lock 已记录真实用户可见证明、复用清单、授权边界、估时基线和偏移熔断。
- 产品仓要求的正式变更提案或等价契约完成验证、评审并通过审批门槛。
- product/control 根、Git 身份、writer fence 和 transport probe 通过。
- broker start/status、并发发布、收取游标、重放修复、隔离和 cooperative stop 探针通过。
- 至少两个角色写入范围真正独立后，才可升级并行档位。
