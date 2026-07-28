# 野蜂 Startup Reference

Use this reference when a project is new, not yet safely parallelizable, or still needs product, architecture, task, or authorization decisions before full 野蜂 orchestration.

During Level 0 or Level 1, choose `embedded` or `external-git`. For `external-git`, read `external-control-repo.md` completely before creating files.

## Contents

- [Startup Levels](#startup-levels)
- [Startup Intake Template](#startup-intake-template)
- [Startup Level Decision Record](#startup-level-decision-record)
- [Role Pool Proposal](#role-pool-proposal)
- [First Slice Contract](#first-slice-contract)
- [Upgrade Checklist](#upgrade-checklist)
- [Startup Closeout](#startup-closeout)

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
- create embedded `.yefeng/state/roles.json`, `.yefeng/state/runs.json`, `.yefeng/events.jsonl`, or the namespaced external equivalents;
- create role pool proposals with roles in `PLANNED`;
- create a first-slice contract;
- record authorization policy and startup level decision;
- initialize an independent external Git control repository when `control_plane_mode=external-git`;
- record stable repo/scope IDs, ignored local root bindings, product baseline commits, and roles in `PLANNED`.

Forbidden while the recorded level remains `LEVEL_1_GOVERNANCE_BOOTSTRAP`. General automation authority or a one-off implementation request does not override this gate; first satisfy the upgrade checklist and record `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL` or `LEVEL_3_FULL_PARALLEL_YEFENG`:

- launching background Codex sessions;
- creating implementation worktrees;
- enabling heartbeat automation;
- starting the runtime message broker;
- merging role branches;
- changing product code or product normative specifications;
- treating control-repository bootstrap as authority to launch roles.

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

Forbidden while the recorded level remains Level 2:

- top-level role launches or resumes;
- role-specific multi-worktree orchestration;
- automatic heartbeat loops;
- the runtime message broker.

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

For `external-git` plus `control-spool`, this is the first level that may start the per-scope single-writer message broker. Start it only after control-repository validation, exact role/run assignments, transport path binding, and the broker lifecycle probe pass. Its presence at lower levels is installation state, not execution authority.

## Startup Intake Template

```md
# 项目启动确认

项目目标：
当前阶段：
非目标：
产品/技术约束：
已有文档：
control_plane_mode：embedded / external-git
control_repo_id：
control_root（本机绑定）：
scope_id：
product_repositories（repo_id / integration branch / baseline）：
产品事实位置：
治理事实位置：
transport_mode：control-spool / worktree-local
broker_mode：disabled / control-spool-single-writer
broker_poll_interval_ms：
产品仓 locator 策略：tracked pointer / local binding / prompt-required
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
control_plane_mode：
control_repo_id / scope_id：
产品仓映射与 baseline：
本机 root 绑定位置：
transport 与 sandbox probe：
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
- user authorization covers implementation;
- control and product repo IDs/roots resolve and do not nest;
- actual control/product Git state matches recorded baselines;
- writer lock/lease/epoch policy exists;
- role transport has a tested writable path or worktree-local fallback;
- no incomplete bootstrap or cross-repository operation remains.

Before upgrading from `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL` to `LEVEL_3_FULL_PARALLEL_YEFENG`, confirm:

- at least two roles can work independently;
- role write scopes do not overlap unexpectedly;
- shared contracts are stable enough;
- max parallel role count is recorded;
- reviewer gates are recorded;
- worktree/branch policy is recorded;
- role launch/resume scripts or commands are known to work in the environment.
- per-scope state and outbox paths cannot collide;
- Level 3 `control-spool` broker passes exact-instance start/status, concurrent publish, delivery/read cursor, replay/idempotency, malformed/stale quarantine, and cooperative stop tests;
- product baseline compare-and-swap and external control reconciliation have been tested;
- pause/resume invalidates old epochs and late output safely.

## Startup Closeout

When finishing startup work, report:

- selected startup level;
- files created or updated;
- roles proposed but not launched;
- decisions still needed from the user;
- exact upgrade condition for the next level;
- whether any background sessions, worktrees, or heartbeats were started.
- whether the runtime broker was started, its verified instance state, and why the startup level permitted it;
- control-plane mode, control Git commit/cleanliness, and product Git commit/cleanliness separately;
- whether product repositories were changed, and the exact locator change if one was authorized;
- ignored runtime/local binding paths and any backup/remote gap.
