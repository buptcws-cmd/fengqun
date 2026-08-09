# 总控状态快照

- 更新时间：`__CREATED_AT__`
- control plane：`external-git`
- control repo：`__CONTROL_REPO_ID__`
- scope：`__SCOPE_ID__`
- run epoch：`1`
- lifecycle：`ACTIVE`
- startup level：`__STARTUP_LEVEL__`
- outcome lock：`__OUTCOME_LOCK_STATUS__` / `__OUTCOME_LOCK_REVISION__`
- 用户可见验收证明：`__USER_VISIBLE_PROOF__`
- 首个纵向切片：`__FIRST_VERTICAL_SLICE__`
- 估时基线 / 偏移阈值：`__ESTIMATE_AND_DRIFT_THRESHOLDS__`
- product repo：`__PRODUCT_REPO_ID__`
- product branch：`__PRODUCT_BRANCH__`
- product baseline：`__PRODUCT_BASELINE__`
- 当前阶段：治理初始化
- 活动实现角色：无
- 活动 product worktree：无
- open operation：无
- broker：startup-level gate 未启用；Level 3 control-spool 才能启动
- last promoted broker sequence：`0`
- blocker：Outcome Lock 若为 UNCONFIRMED，先完成用户确认；随后完成首个正式产品 checkpoint 的方向优先独立评审与审批后才能实现
- 下一安全动作：细化并评审 `docs/modules/__SCOPE_ID__/plan.md`，随后按产品仓治理约定创建正式变更 checkpoint

本文件是短视图，不是审批源。冲突时以实际 Git/进程状态、机器控制状态和精确 revision 证据为准。
