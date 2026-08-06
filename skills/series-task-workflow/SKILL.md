---
name: series-task-workflow
description: Coordinate user-provided multi-step or multi-module task series with a compact current-truth registry, machine control state, claims, worktrees, validation, review, merge, cleanup, pause/handoff, and continuation controls. Use for a series, batch, roadmap, audit set, "one by one" repair flow, multi-conversation workflow, or any request to continue, pause, hand off, or resume an existing coordinated series. Do not use for a standalone report or one-off task unless the user asks to turn it into a series.
---

# Series Task Workflow

## Purpose

Turn a large task set into independently claimable checkpoints while keeping the active context small. The coordinator owns current truth, dependency order, dispatch, integration, and cleanup. A claimant owns one bounded checkpoint in its declared worktree and write surfaces.

When `yefeng` is active, let it own top-level roles, background processes, the communication bus, and total-control heartbeats. This skill remains authoritative for checkpoint, claim, registry, validation, review, merge, and cleanup semantics.

## Cost-Aware Startup

1. Read repository authority and this `SKILL.md` as required by the host.
2. Read the active registry and machine control state, then verify dynamic facts against Git, worktrees, agents/processes, APIs, and runtime identity.
3. For cross-conversation, delegated, or multi-worktree work, read [`references/control-state.md`](references/control-state.md). Use its incremental read protocol: load hot current truth first, then only the warm references and event/log deltas required by the next action. Never load cold history merely because it exists.
4. Run [`scripts/reconcile-series-state.ps1`](scripts/reconcile-series-state.ps1) with an explicit absolute `-StatePath` before dispatch, resume, review, merge, cleanup, or a completion claim when PowerShell and Git are available. A nonzero result blocks mutation.
5. State whether this agent is coordinator, claimant for one named checkpoint, or both through a recorded temporary mode switch.

Do not repeatedly reread unchanged large references inside one session. Verify recorded fingerprints and cursors; reread a document fully when its fingerprint changed, when authority requires it for the pending action, or when reconciliation exposes ambiguity.

## Control Invariants

- Keep one explicit coordinator and a monotonically increasing `run_epoch`.
- Treat pause, stop, handoff, cancellation, takeover, and resume as control commands. Invalidate older-epoch authority before further writes.
- Resolve conflicts in this order: actual system state; machine control state; current evidence manifest; active registry; archive/Git history; conversation or worker report.
- Default WIP budget: at most two active implementation worktrees, two pending review jobs across the series, and one integration/release batch. Capacity is not a requirement to duplicate reviewers.
- Keep at most one active candidate per root-cause direction. Queue other discoveries with evidence instead of opening speculative worktrees.
- Preserve unrelated user changes. Never enter, validate, commit, merge, or clean another live claim unless explicitly assigned as its reviewer or takeover is authorized.
- A progress/ETA request is an intermediate checkpoint, not a pause, unless the user also redirects or stops execution.

## Current-Truth Surfaces

Use a concise human registry such as `NEXT_STEPS.md` plus a small machine-readable control state for multi-conversation work. The registry is an operational dashboard, not an append-only history.

Keep in hot state only:

- current goal/non-goals, `run_epoch`, exact source/runtime identities;
- two or three active work items, claims, blockers, and next actions;
- current candidate revision and required gates;
- claimant-only and coordinator/non-claimant next actions;
- archive/evidence pointers and cleanup debt.

Move closed cycles, superseded candidates, old reviews, logs, and obsolete identities to indexed archives immediately after their stable disposition is recorded. Do not carry them forward as active truth.

Use lifecycle meanings literally:

- `implementation`: being changed in a worktree;
- `review`: exact candidate frozen and under review;
- `done`: worktree validation and required review passed, not merged;
- `merged`: integrated into the source-of-truth branch;
- `closed`: required integration/product-path evidence and cleanup are complete;
- `blocked`: a concrete blocker and unblock action are recorded;
- `handed-off`: a named actor, boundary, and acceptance criteria own the next action.

## Claim And Worktree Protocol

- Claims are epoch-bound leases with a stable token, timestamps, branch/worktree, scope, write surfaces, validation plan, and review gate.
- Claim the smallest coherent unblocked checkpoint. Do not reserve the whole roadmap by default.
- Before every state-changing action, verify the current epoch, live lease, declared worktree, revision, and WIP capacity.
- Use a dedicated branch/worktree for file-changing checkpoints unless local authority says otherwise.
- Non-claimants may inspect shared truth and report blockers. They must not operate in the claimed worktree.
- An assigned reviewer keeps product files read-only and writes only the authorized verdict/evidence surface.
- Treat worktrees as execution containers, not durable evidence stores. Preserve authorized commits, complete patches/archives, and hashes before cleanup; never delete the only copy of dirty work.

## Execution Loop

1. Reconcile current truth and dependencies.
2. Claim or confirm one runnable checkpoint and its write boundary.
3. Create/select the dedicated worktree before edits.
4. Satisfy proposal/approval gates when architecture, security, contract, migration, or broad behavior requires them.
5. Implement only the scoped checkpoint and update stable control facts at meaningful transitions.
6. Run exact-revision focused validation and the closest real product-path/manual check.
7. Freeze a candidate only when its declared diff, known gaps, and evidence are stable.
8. Run the required review contract, consolidate findings, repair as one batch, and replace only invalidated evidence.
9. When authorized, commit/merge, run integration gates, update status, release claims, and clean task-created worktrees/branches/artifacts.
10. Reassess the next unblocked checkpoint; continue until complete or genuinely blocked.

## Review And Cost Circuit Breakers

Use `code-review-and-quality` for reviewer count and charters. Default to one independent final review. Add one adversarial pre-audit only for materially high-risk architecture, authorization, security, concurrency/state-machine, migration, irreversible, or cross-boundary work, or when local authority requires it.

- `pre-audit-ready`: contract and candidate direction are stable, cheap focused checks pass, and known gaps are explicit.
- `final-review-ready`: all required post-repair validation/manual evidence is complete and the exact candidate is frozen.
- Give reviewers one exact subject and evidence bundle. Parallel reviewers must have distinct charters; remove equal-scope duplicates.
- Consolidate all available findings before mutation. Do not alternate tiny patches between reviewers.
- Any relevant candidate change invalidates bound validation/review; metadata-only archive updates outside the reviewed surface do not.
- After two rejected candidates for one root-cause direction or two substantive review failures, stop candidate churn. Mark the checkpoint blocked on design/root-cause reassessment, narrow the hypothesis and acceptance matrix, then explicitly reset the attempt counters before another candidate.
- Do not launch a new expensive package, full matrix, or external review merely to obtain more activity when the current candidate is not stable.

Require a formal review result to include the exact revision, literal `review passed` or `review failed`, findings, residual risk, and unlock/block effect. A timeout, interruption, advisory note, or ambiguous response is not a verdict.

## Coordinator And Worker Boundary

The coordinator reconciles state, enforces WIP/dependencies, dispatches bounded prompts, inspects evidence/diffs, integrates, and cleans up. It must not silently implement a checkpoint already assigned to another claimant.

A worker verifies its assignment and epoch, stays inside its worktree/write surfaces, maintains task-local facts, validates, obtains required review, and returns evidence. It does not merge, change unrelated registry rows, release shared claims, or clean shared state unless explicitly authorized.

Choose model/reasoning tier by risk: strongest for integration, architecture, authorization, security, and hard root cause; high for shared implementations and gate reviewers; medium for bounded implementation/tests/docs; economy only for mechanical low-risk work.

## Continuation, Handoff, And Heartbeats

Continue automatically while authorized work remains. Stop mutation on unmet prerequisites, live conflicting claims, missing approval/credentials, irreversible authority expansion, or the cost circuit breaker.

On pause/handoff/cancel/takeover, increment `run_epoch`, invalidate old workers/heartbeats, preserve evidence, and write the compact handoff capsule from `references/control-state.md`. Resume only from explicit current-epoch authority.

Use host-provided heartbeat/automation only when local authority requires continued idle intake. Keepalive renews liveness only; blocker checks read current truth and act only on newly runnable work. Never emulate heartbeats with shell sleep loops.

## Completion And Reporting

Before `done`, record changed surfaces, exact-revision validation, manual evidence or accepted gap, and the latest required `review passed`. Before `merged`, record merge identity and cleanup/downstream state. Before `closed`, record final product/integration evidence, archive manifest, terminal agents/processes, and worktree/branch/artifact disposition.

For a progress report, give: current cycle/stage; evidence-backed progress since the prior report; owner/state; remaining gates; blockers/risks; WIP/cleanup debt; next milestone; and milestone-scoped P50/P80 assumptions. Do not convert an open-ended roadmap into a misleading single ETA.

For closeout, report outcome first, then validation/review, merge/cleanup state, residual risk, and the next gated action. Keep the active registry compact after closure.
