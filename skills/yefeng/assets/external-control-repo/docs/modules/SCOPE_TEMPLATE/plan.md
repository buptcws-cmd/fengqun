# __SCOPE_ID__ 推进计划

## 当前阶段

`LEVEL_1_GOVERNANCE_BOOTSTRAP`

## 阶段图

1. 治理与意图固化。
2. 权威现状、复用能力和边界调查。
3. 锁定用户可见证明、MVP/非目标、reuse/adapt/new/defer、授权边界和估时熔断。
4. 按产品仓治理约定形成最薄正式变更提案或等价契约。
5. 先做方向/最小路径评审，再做契约正确性评审与审批。
6. 单线程首个真实纵向产品切片。
7. 契约稳定后拆分独立 worktree 并行实现。
8. 真实产品路径验证、实现评审、集成与归档。

## 串行边界

- 产品/控制边界和首切片契约完成前，不实现。
- 公共契约未稳定前，不并行开发依赖它的多个角色。
- 正式变更未通过审批门槛前，不创建实现角色。
- 第二层不可见前置、连续两个 checkpoint 无产品路径推进、或估时越过章程阈值时，暂停受影响派发并形成一次批量决策。

## 验收

- 每个 checkpoint 绑定精确产品 commit。
- 每个 checkpoint 绑定 outcome-lock revision，并标注 PRODUCT_PATH_CLOSED / PRODUCT_PATH_ADVANCED / ENABLEMENT_ONLY / SPEC_ONLY / TEST_ONLY。
- ENABLEMENT_ONLY 绑定立即消费它的产品切片和最迟消费 checkpoint。
- 自动验证和适用的真实产品路径测试通过。
- 最新独立评审明确 `review passed`。
- 产品合并与控制状态分别提交并完成对账。
