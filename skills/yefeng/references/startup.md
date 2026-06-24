# 野蜂 Startup Reference

Use this reference when a project is new, not yet safely parallelizable, or still needs product, architecture, task, or authorization decisions before full 野蜂 orchestration.

## Startup Levels

### LEVEL_0_DISCUSS

Use when:

- the user is still exploring direction;
- product goals or non-goals are unclear;
- technical stack or architecture decisions are unresolved;
- a standard task template or project startup intake is needed before edits.

Allowed:

- read local docs and code;
- discuss decisions with the user;
- fill a startup intake or task template;
- propose role pools and next levels.

Forbidden unless explicitly authorized:

- creating governance files;
- launching role sessions;
- creating role worktrees;
- merging or pushing.

### LEVEL_1_GOVERNANCE_BOOTSTRAP

Use when:

- the project is ready for durable governance;
- implementation tracks are still sequential or contract-heavy;
- the user wants organization before coding;
- a project has docs, constraints, and a roadmap but no 野蜂 state yet.

Allowed:

- create or update governance docs;
- create `.yefeng/state/roles.json`, `.yefeng/state/runs.json`, `.yefeng/events.jsonl`;
- create role pool proposals with roles in `PLANNED`;
- create a first-slice contract;
- record authorization policy and startup level decision.

Forbidden unless explicitly authorized:

- launching background Codex sessions;
- creating implementation worktrees;
- enabling heartbeat automation;
- merging role branches.

### LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL

Use when:

- the first implementation slice is important and dependency-heavy;
- one total-control thread can safely implement or scaffold while maintaining governance;
- parallel tracks would create churn.

Allowed:

- advance a small checkpoint directly;
- update task registry and status snapshot;
- run local validation;
- commit governance and implementation changes if authorized by policy.

Still avoid:

- parallel role launches;
- multi-worktree orchestration;
- automatic heartbeat loops.

### LEVEL_3_FULL_PARALLEL_YEFENG

Use when:

- independent implementation tracks exist;
- max parallel roles are recorded;
- role scopes, write scopes, and reviewer gates are clear;
- the user has authorized full 野蜂 execution.

Allowed:

- assign roles;
- create worktrees and branches;
- launch/resume background Codex role sessions;
- route cross-role communication;
- require reviewer evidence;
- integrate merge-ready work.

## Startup Intake Template

```md
# 项目启动确认

项目目标：
当前阶段：
非目标：
产品/技术约束：
已有文档：
第一条用户闭环：
首个可验证切片：
需要用户决策：
推荐启动档位：
选择理由：
升级到下一档位的条件：
```

## Startup Level Decision Record

```md
# 野蜂启动档位决策

当前档位：
选择时间：
选择理由：
允许执行：
禁止执行：
暂不启动角色的原因：
最大并行角色数：
worktree/branch 策略：
升级条件：
需要用户确认：
```

## Role Pool Proposal

```md
# 角色池草案

| 角色ID | 角色 | 启用档位 | 负责范围 | 前置依赖 | 可并行条件 | 默认写入范围 | 禁止范围 |
| --- | --- | --- | --- | --- | --- | --- | --- |
```

## First Slice Contract

```md
# 第一实现切片

目标：
用户路径：
数据模型：
API：
前端：
写入范围：
验收标准：
明确不做：
验证方式：
升级/拆分条件：
```

## Upgrade Checklist

Before upgrading from `LEVEL_1_GOVERNANCE_BOOTSTRAP` to `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL`, confirm:

- the first slice is defined;
- write scope is narrow;
- non-goals are explicit;
- validation can be run locally;
- user authorization covers implementation.

Before upgrading from `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL` to `LEVEL_3_FULL_PARALLEL_YEFENG`, confirm:

- at least two roles can work independently;
- role write scopes do not overlap unexpectedly;
- shared contracts are stable enough;
- max parallel role count is recorded;
- reviewer gates are recorded;
- worktree/branch policy is recorded;
- role launch/resume scripts or commands are known to work in the environment.

## Startup Closeout

When finishing startup work, report:

- selected startup level;
- files created or updated;
- roles proposed but not launched;
- decisions still needed from the user;
- exact upgrade condition for the next level;
- whether any background sessions, worktrees, or heartbeats were started.

