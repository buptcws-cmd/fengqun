---
name: series-task-workflow
description: Coordinate a series without 野蜂 using a compact current-truth registry, machine control state, claims, worktrees, validation, review, merge, cleanup, pause/handoff, and continuation controls. Use for a batch, roadmap, audit set, "one by one" repair flow, or multi-conversation series that does not need 野蜂 role/process/message governance. Do not load it in addition to yefeng, and do not use it for a standalone report or one-off task unless the user asks to turn that work into a series.
---

# Series Task Workflow

## Purpose

Turn a large task set into independently claimable checkpoints while keeping the active context small. The coordinator owns current truth, dependency order, dispatch, integration, and cleanup. A claimant owns one bounded checkpoint in its declared worktree and write surfaces.

This is the standalone series coordinator for work that does not use `yefeng`. When `yefeng` is active, do not load this skill in addition: 野蜂 carries compatible checkpoint, claim, registry, validation, review, merge, cleanup, pause/handoff, and cost-breaker semantics internally and owns the whole control loop. Keep this skill independent so a lighter series does not have to load 野蜂's role, process, and message-transport governance.

## Cost-Aware Startup

1. Read repository authority and this `SKILL.md` as required by the host.
2. Read the bounded hot entry and machine control state, then verify dynamic facts against Git, worktrees, agents/processes, APIs, and runtime identity. For schema-v3 directory state, read only `HOT.md` and `control.json` at startup; do not enumerate `active/` or `archive/`. Reconciliation may stat exact declared cold references without reading their contents; use explicit `-AuditArchive` only when the cold hash chain itself must be proven.
3. For cross-conversation, delegated, or multi-worktree work, read [`references/control-state.md`](references/control-state.md). Use its incremental read protocol: load hot current truth first, then only the warm references and event/log deltas required by the next action. Never load cold history merely because it exists.
4. Run [`scripts/reconcile-series-state.ps1`](scripts/reconcile-series-state.ps1) with an explicit absolute `-StatePath` before dispatch, resume, review, merge, cleanup, or a completion claim when PowerShell and Git are available. A nonzero result blocks mutation.
5. State whether this agent is coordinator, claimant for one named checkpoint, or both through a recorded temporary mode switch.

Do not repeatedly reread unchanged large references inside one session. Verify recorded fingerprints and cursors; reread a document fully when its fingerprint changed, when authority requires it for the pending action, or when reconciliation exposes ambiguity.

## Control Invariants

- Keep one explicit coordinator and a monotonically increasing `run_epoch`.
- Treat pause, stop, handoff, cancellation, takeover, and resume as control commands. Invalidate older-epoch authority before further writes.
- Resolve conflicts in this order: actual system state; machine control state; current evidence manifest; active registry; archive/Git history; conversation or worker report.
- Treat `wip_budget` only as ceilings: by default at most two active implementation worktrees, two current pending review gates, and one current-epoch integration intent. Read actual counts only from the reconciler's derived `wip_usage`; never persist usage back into the budget. Capacity is not a requirement to duplicate reviewers.
- Keep at most one active candidate per root-cause direction. Queue other discoveries with evidence instead of opening speculative worktrees.
- Preserve unrelated user changes. Never enter, validate, commit, merge, or clean another live claim unless explicitly assigned as its reviewer or takeover is authorized.
- A progress/ETA request is an intermediate checkpoint, not a pause, unless the user also redirects or stops execution.

## Current-Truth Surfaces

Use a concise human registry such as `NEXT_STEPS.md` plus a small machine-readable control state for multi-conversation work. The registry is an operational dashboard, not an append-only history. Persistent series SHOULD use the schema-v3 directory layout from [`references/control-state.md`](references/control-state.md): `HOT.md` + `control.json` + individually addressed `active/<id>/state.json` + an indexed external archive. A folder is not itself a context boundary: loaders MUST open named files only and MUST NOT recursively enumerate it.

Keep in hot state only:

- current goal/non-goals, `run_epoch`, exact source/runtime identities;
- two or three active work items, claims, blockers, and next actions;
- current candidate revision and its one current `review_gate` binding;
- claimant-only and coordinator/non-claimant next actions;
- archive/evidence pointers and cleanup debt.

Move closed cycles, superseded candidates, old reviews, logs, and obsolete identities to indexed archives immediately after their stable disposition is recorded. Do not wait for a size threshold. Keep only the review record referenced by the current `review_gate` in active state. Enforce the v3 budgets mechanically: `HOT.md <= 120` lines and `16384` bytes, `control.json <= 32768` bytes, at most three candidate refs, each active candidate state `<= 65536` bytes with at most five current validations and one current review. All archive refs declare their base, resolve into one non-reparse `archive_root`, exist, and bind the pointer/control original SHA. Unmigrated history may remain temporarily: v1 always uses last-exact fallback, while v2 permits that read-only fallback only for terminal/inactive candidates that lack a gate. Historical records never count as current WIP, and reactivating a v2 candidate requires an explicit gate field before mutation.

Batch ledger writes: at most one bookkeeping commit per cycle transition (candidate freeze; merge/closeout) — never one commit per state flip. Fold "review failed", "repair gates", "claim expanded" notes into the evidence file and the next transition commit. When a checkpoint reaches `merged`/`closed`, collapse its registry row to status, merge identity, and evidence pointers in the same update; the full cycle history lives in the evidence archive and version control, not the dashboard.

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
- `execution_mode: solo` (declared in control state) applies when exactly one actor works the series with no concurrently live delegated workers: claims keep id, scope, write surfaces, and epoch but drop token/lease/timestamp bookkeeping; the startup reconciliation against actual Git/worktree state replaces lease expiry as the staleness guard. Record the switch back to `multi` and restore leases before dispatching any concurrent worker. Solo mode never relaxes write-surface, WIP, gate, or review rules.
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
4. Satisfy proposal/approval gates when architecture, security, contract, migration, or broad behavior requires them. For a semantically thick checkpoint — a state machine, cross-module semantics, or a ruling/spec with several acceptance-relevant clauses — enumerate its acceptance invariants and RED matrix first and have that list adversarially reviewed before implementation (see `code-review-and-quality`); later reviews verify the implementation against the frozen list instead of re-deriving the spec each round.
5. Implement only the scoped checkpoint and update stable control facts at meaningful transitions.
6. Run exact-revision focused validation and the closest real product-path/manual check.
7. Freeze a candidate only when its declared diff, known gaps, and evidence are stable.
8. Run the required review contract, consolidate findings, repair as one batch, and replace only invalidated evidence.
9. When authorized, commit/merge, run integration gates, update status, release claims, and clean task-created worktrees/branches/artifacts.
10. Reassess the next unblocked checkpoint; continue until complete or genuinely blocked.

## Review And Cost Circuit Breakers

Use `code-review-and-quality` for reviewer count and charters. Default to one independent final review. Add one adversarial pre-audit only for materially high-risk architecture, authorization, security, concurrency/state-machine, migration, irreversible, or cross-boundary work, or when local authority requires it. A documentation-only checkpoint whose acceptance is factual accuracy may take a single light fact-check review against the code it describes instead of the full contract.

- `pre-audit-ready`: contract and candidate direction are stable, cheap focused checks pass, and known gaps are explicit.
- `final-review-ready`: all required post-repair validation/manual evidence is complete and the exact candidate is frozen.
- Give reviewers one exact subject and evidence bundle. Parallel reviewers must have distinct charters; remove equal-scope duplicates. Every reviewer task order states an evidence-trust boundary (gates already recorded for this exact candidate are trusted inputs — verify their binding and run cheap targeted probes, never repeat full gates or expand the validation matrix) and a convergence budget; a reviewer that exhausts its budget without a formal verdict or one concrete blocking question is interrupted and replaced on the same bundle, filling the same slot.
- Consolidate all available findings before mutation. Do not alternate tiny patches between reviewers.
- Any relevant candidate change invalidates bound validation/review. In control-state schema v2, require every hot candidate (`claimed`, `implementation`, `running`, `validation`, `review`, `implementation-review`, `blocked`) to carry an explicit `review_gate` field, using `null` before a gate exists; bind a current gate by unique `review_id`, current `candidate_revision`, binding mode, and proof. Use `exact` by default. Permit `administrative-descendant` only for a direct single-parent child whose entire Git diff exactly equals the whole-file `administrative_paths` frozen by the referenced independent `review passed` record. Hash the complete Git-object tree after excluding those exact administrative paths; require the source and target digests to be identical and match the receipt, and also bind the raw diff digest. Never let the candidate self-declare that surface. Treat mixed-semantic files as product surfaces even when their path looks administrative; require a fresh exact review. Reserve `repository-verifier` for a future repository-owned executable field verifier and fail closed until one exists. Schema v1, and schema-v2 terminal/inactive migration records without a gate, have only a last-exact-revision fallback and never inherit; add a v2 gate before reactivation.
- Classify blocking findings before they consume budget. `product` findings (behavior, contract, security, or tests are wrong) count toward attempt and review-failure budgets. `administrative` findings (registry, claim coverage, status vocabulary, or evidence hygiene wrong while the production tree is correct) are fixed in place — amend the records, re-freeze the binding, prove tree-hash equality — consuming no attempt and never triggering the breaker by themselves. `infrastructure` findings (executor limits, sandbox, missing local dependencies) are repaired and re-run without consuming attempts. The breaker exists to stop wrong product directions, not to punish ledger corrections with a full re-gate cycle.
- After two rejected candidates for one root-cause direction or two `product`-class review failures, stop candidate churn. Mark the checkpoint blocked on design/root-cause reassessment, narrow the hypothesis and acceptance matrix, then explicitly reset the attempt counters before another candidate.
- Do not launch a new expensive package, full matrix, or external review merely to obtain more activity when the current candidate is not stable.

Gate economics: record the repository's full-gate baseline duration in the registry, and launch full gates with an execution window of at least twice that baseline (or as a polled background process) so a known-short executor limit never truncates a known-long gate. A gate killed by an executor limit is `infrastructure`, not failure — but a second kill means the window is set wrong; fix the window instead of re-running blind. Stage-decomposed runs (build, typecheck, tests executed separately against the same frozen revision) are valid full-gate evidence when together they cover the required command's semantics; record the decomposition rather than re-running a combined command for literalism. Run focused gates during iteration; reserve full gates for freeze points and post-merge verification.

Require a formal review result to include a unique `review_id` when it is a v2 gate target, the exact revision, literal `review passed` or `review failed`, findings with their `product`/`administrative`/`infrastructure` classes, residual risk, and unlock/block effect. Historical records do not need retrofitted ids unless a gate references them. A timeout, interruption, advisory note, or ambiguous response is not a verdict.

## Coordinator And Worker Boundary

The coordinator reconciles state, enforces WIP/dependencies, dispatches bounded prompts, inspects evidence/diffs, integrates, and cleans up. It must not silently implement a checkpoint already assigned to another claimant.

A worker verifies its assignment and epoch, stays inside its worktree/write surfaces, maintains task-local facts, validates, obtains required review, and returns evidence. It does not merge, change unrelated registry rows, release shared claims, or clean shared state unless explicitly authorized.

Choose model/reasoning tier by risk: strongest for integration, architecture, authorization, security, and hard root cause; high for shared implementations and gate reviewers; medium for bounded implementation/tests/docs; economy only for mechanical low-risk work.

## Continuation, Handoff, And Heartbeats

Continue automatically while authorized work remains. Stop mutation on unmet prerequisites, live conflicting claims, missing approval/credentials, irreversible authority expansion, or the cost circuit breaker.

On pause/handoff/cancel/takeover, increment `run_epoch`, invalidate old workers/heartbeats, preserve evidence, and write the compact handoff capsule from `references/control-state.md`. Resume only from explicit current-epoch authority.

Use host-provided heartbeat/automation only when local authority requires continued idle intake. Keepalive renews liveness only; blocker checks read current truth and act only on newly runnable work. Never emulate heartbeats with shell sleep loops.

## Completion And Reporting

Before `done`, record changed surfaces, exact-revision validation, manual evidence or accepted gap, and a valid current `review_gate` resolving to the required `review passed`. Before `merged`, record merge identity and cleanup/downstream state. Before `closed`, record final product/integration evidence, archive manifest, terminal agents/processes, and worktree/branch/artifact disposition.

For a progress report, give: current cycle/stage; evidence-backed progress since the prior report; owner/state; remaining gates; blockers/risks; WIP/cleanup debt; next milestone; and milestone-scoped P50/P80 assumptions. Do not convert an open-ended roadmap into a misleading single ETA.

For closeout, report outcome first, then validation/review, merge/cleanup state, residual risk, and the next gated action. Keep the active registry compact after closure.
