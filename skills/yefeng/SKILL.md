---
name: yefeng
description: Use 野蜂 when a large or multi-module project needs one total-control thread to lock the intended outcome and authorization boundary, bootstrap governance, assign roles across Codex CLI and Claude Code CLI, run or resume governed background sessions, detect scope drift, route recorded communication, review evidence, and integrate checkpoints. Use it for embedded coordination and for independent external Git control repositories that keep operational state separate from authoritative product repositories.
---

# 野蜂

野蜂 is a governed multi-backend work system. The user talks to one total-control thread; that thread assigns top-level roles, controls background sessions, routes recorded facts, enforces evidence/review gates, integrates checkpoints, and owns cleanup. Roles are assigned, never self-claimed.

野蜂 is self-contained. When it is active, do not additionally load `series-task-workflow`: this skill directly owns checkpoint, claim, registry, validation, review, merge, cleanup, pause/handoff, cost-breaker, role/process, message-transport, and total-control semantics. Use `series-task-workflow` only as the lighter standalone coordinator for a series that does not use 野蜂.

## Low-Context Startup

1. Read repository authority and this `SKILL.md` as required by the host.
2. Read persisted semantic authority and limits from the compact status snapshot and machine state, then reconcile actual control/product Git, worktrees, current-epoch assignments/leases, verified role processes, broker identity, and pending handoffs.
3. Verify recorded instruction fingerprints and event/message/log cursors. Read only changed authority documents, events after the accepted cursor, and the action-specific references listed below. A fingerprint never replaces a host-required full skill read or dynamic-state reconciliation.
4. Load cold history only to reopen work, audit provenance, resolve contradiction, or recover evidence. Do not replay completed event logs, processed handoffs, old candidates, or prior package evidence into every turn.
5. Rebuild and validate the hot current-truth projection, fingerprints, cursors, archive pointers, and concise stable summary after each durable transition.

Persist only semantic authority and limits. Derive `current_parallel_roles`, WIP, semaphore occupancy, and every active/live/running count on each cycle by reconciling current-epoch state with a fresh verified runner census; do not persist those counts. If either source is missing or invalid, or the two conflict, mark occupancy `UNKNOWN` and block dispatch.

Default hot-state budget: current objective/non-goals, startup level/topology, exact control/product baselines, at most two or three active roles/checkpoints, blockers, open decisions, limits, derivation inputs or an `UNKNOWN` blocker, and next total-control action. Render derived occupancy only as a turn-local view. Keep the human hot view at or below 120 lines and 16384 UTF-8 bytes, with no line above 1000 characters and no more than five recent terminal pointer rows; local authority may deliberately lower these bounds or raise one with a recorded reason. Never place terminal full payloads in hot state. After archival, retain only a compact index with the exact archive locator and integrity/identity bindings needed to recover cold evidence; do not retain a duplicate terminal payload. This projection rule grants no deletion or automatic compaction authority.

## Checkpoints And Current Truth

Total-control owns the human hot projection and is its only writer. Claims are epoch-bound, use the smallest coherent scope, and bind the assigned worktree, write surfaces, validation plan, and review gate. A checkpoint reaching `merged` or `closed` is collapsed in the same control transition to terminal status, integration identity, and evidence/archive pointers; its narrative, failed attempts, old reviews, and superseded identities leave hot state immediately.

Read [`references/checkpoint-lifecycle.md`](references/checkpoint-lifecycle.md) before claiming, dispatching, reviewing, integrating, cleaning, pausing, handing off, or closing checkpoints. Read [`references/current-truth-retention.md`](references/current-truth-retention.md) before creating repository guidance for a current-truth surface, compacting or migrating a legacy registry, or changing its archive/index contract.

Repository authority such as `AGENTS.md` may name stable project-specific control locations, protected paths, and stricter local constraints. Keep generic registry lifecycle, incremental-read, archive, and context-budget policy in this skill; do not place dynamic claims there or require every agent to replay a growing cold history.

## Startup Levels

- `LEVEL_0_DISCUSS`: goals, architecture, task shape, or authorization remain unclear. Discuss and inspect; do not create governance unless asked.
- `LEVEL_1_GOVERNANCE_BOOTSTRAP`: create/update governance and machine-state skeletons with roles `PLANNED`; do not launch roles, create role worktrees, merge, or start heartbeats/brokers.
- `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL`: total-control advances the dependency-heavy first slice directly; no top-level role launches.
- `LEVEL_3_FULL_PARALLEL_YEFENG`: independent tracks and explicit authorization permit assignments, governed CLI sessions, communication routing, review, and integration.

Enter Level 3 only with recorded authorization, parallel-role limit, independent scopes, governance/machine state, worktree policy, and explicit gates for secrets, external accounts, payment, publication, production, or destructive operations.

Read [`references/startup.md`](references/startup.md) before bootstrap or level changes. Use [`references/templates.md`](references/templates.md) only for the concrete artifact being created; do not load the whole template catalog for routine continuation.

## Topology And Authority

Choose one recorded control-plane topology:

- `embedded`: governance and product share a repository;
- `external-git`: an independent Git control repository owns private operational state while named product repositories own code, specifications, tests, contracts, and releases.

Prefer `external-git` for multiple repositories/modules, frequently dirty product main, private operational history, or an embedded control plane already owned by another series. Read [`references/external-control-repo.md`](references/external-control-repo.md) completely before external bootstrap, dispatch, resume, integration, recovery, or closeout.

Total-control is the only top-level dispatcher and the only writer of tracked control truth. It may assign/stop/resume roles, create role worktrees, route messages, decide blocker clearance, integrate reviewed branches, and update governance within recorded authority. It does not gain permission for secrets, paid/external systems, publication, production writes, destructive out-of-scope cleanup, or policy expansion merely because a role recommends them.

Treat default approval as execution authority inside a confirmed outcome, not authority to redefine the outcome. Use it to remove repetitive approvals for safe in-scope work, keep the queue draining, and delegate no more permission than the operator holds. Do not infer permission to expand the MVP, replace non-goals, introduce a new public capability family, or silently move the schedule baseline. Batch a genuine product/scope decision once, obtain the user's decision, update the outcome lock, and then resume without asking again for unchanged in-scope operations.

## Core Invariants

- Bind implementation to a current outcome lock: objective, user-visible proof, first vertical slice, non-goals, reuse/adapt/new/defer inventory, authorization ceiling, scope/estimate baseline, and drift thresholds. Technically executable work outside that lock is not authorized work.
- Bind every launch to an assignment manifest containing control/product identity, scope, `run_epoch`, assignment/role/run IDs, backend, worktree, prompt hash, sandbox/permission ceiling, workload class, and lease.
- Roles verify assignments and work only inside declared scopes. They do not assign roles, wake peers, merge, or edit shared tracked control state.
- Use one worktree/branch per implementation role unless an explicit read-only/document-only exception exists.
- Cross-role facts, blockers, decisions, review results, and handoffs must enter the governed communication/state surfaces; private chat is not authority.
- Shared tracked control state has one fenced commit writer. Git `index.lock` alone is not a semantic fence.
- In external Level 3 `control-spool`, one verified broker is the only physical writer of ignored runtime communication state. The broker validates/transports; it never assigns, wakes, decides, merges, or writes tracked governance.
- Product and control repositories are authoritative only for their own domains. Verify and report their revisions/cleanliness separately.
- Treat process lifecycle, terminal session cleanup, and evidence disposition as closure gates, not postscript chores.

## Action Reference Router

Read only the reference required by the pending action, completely:

- startup intake, level selection, governance bootstrap: [`references/startup.md`](references/startup.md);
- checkpoint/claim lifecycle, exact evidence, review, merge, cleanup, pause/handoff: [`references/checkpoint-lifecycle.md`](references/checkpoint-lifecycle.md);
- tracked hot-state validation, legacy registry migration, archive/index maintenance: [`references/current-truth-retention.md`](references/current-truth-retention.md);
- default authorization meaning, outcome lock, vertical-slice order, scope-drift breakers, progress truth, estimate changes, and direction-first review: [`references/outcome-and-scope-control.md`](references/outcome-and-scope-control.md);
- backend permissions, MCP envelope, machine capacity, semaphores: [`references/multi-backend-capacity.md`](references/multi-backend-capacity.md);
- total-control poll/continue/integrate/close loop: [`references/total-control-operations.md`](references/total-control-operations.md);
- CLI launch/resume/census/terminal evidence/PID-safe cleanup: [`references/process-backend.md`](references/process-backend.md);
- worktree integration, writer fence, messages, broker import/promotion: [`references/integration-and-transport.md`](references/integration-and-transport.md);
- external control repository lifecycle: [`references/external-control-repo.md`](references/external-control-repo.md);
- completed-batch log compaction: [`references/run-evidence-retention.md`](references/run-evidence-retention.md);
- exact document/prompt skeleton requested now: [`references/templates.md`](references/templates.md).

Do not load every reference as a startup ritual. If one action crosses several boundaries, load only those boundaries and record their fingerprints afterward.

## Backend And Capacity

Treat Codex CLI and Claude Code CLI as orchestration transports with different permission semantics. Default to minimal MCP. In the current non-interactive desktop environment, a governed `workspace-write` role uses Codex `--dangerously-bypass-approvals-and-sandbox` or Claude `bypassPermissions` only after the assignment explicitly acknowledges that Yefeng's dedicated worktree, declared paths, and terminal diff audit are the external fence. These CLI modes are not OS exact-path sandboxes; reject out-of-scope diffs.

Persist capacity ceilings and semaphore limits, not occupancy. Under the dispatch mutex, calculate occupancy from current-epoch state plus a fresh verified runner census, then apply current machine load and the backend, CPU-heavy, database, and browser/Electron limits. Treat missing or conflicting inputs as `UNKNOWN` and refuse dispatch; reduce fanout when host-managed process duplication is high. Never kill generic Codex Desktop, Claude, Electron, MCP, PowerShell, or Node processes without exact run identity or explicit host-level authority.

## Role And Total-Control Loop

For each total-control cycle:

1. reconcile the current outcome-lock revision, user-visible proof, non-goals, estimate baseline, and drift counters;
2. reconcile hot truth and read event/message deltas after recorded cursors;
3. verify startup level, epoch, assignments, leases, process budget, broker, and repository identities;
4. ingest completed runs and accepted transport facts, then promote only verified facts into tracked control truth;
5. route messages, resolve cleared blockers, and resume/launch every safe capacity-allowed in-lock role;
6. inspect exact evidence and integrate only direction-aligned, review-ready checkpoints;
7. update machine state and concise human views under the writer fence;
8. clean exactly matched terminal processes and disposition completed evidence;
9. if detached roles remain in flight, schedule one host-supported total-control return before yielding;
10. repeat until quiescent or a scope-drift breaker trips, then report the next executable action, batched decision, or concrete blocker.

A role session verifies its assignment/epoch/baseline, reads only its current contract/directives/inbox delta, executes inside its scope, validates, obtains required review, publishes meaningful boundary events, and returns a concise handoff. Use runner-emitted heartbeats for liveness; do not wake the role model for periodic no-change progress. Detached role completion does not wake total-control automatically: follow the self-scheduled-return contract in `references/total-control-operations.md` whenever work remains in flight.

## Candidate, Review, And Cost Breakers

野蜂 uses these defaults directly:

- `candidate_attempt_limit=2` for one root-cause direction;
- `review_failure_limit=2` substantive formal failures;
- one independent final review by default;
- one distinct adversarial pre-audit only for materially high-risk work or explicit local authority;
- one frozen exact candidate/evidence bundle and one consolidated repair batch.

When either limit is reached, stop new candidates, packaging/full matrices, equal-scope reviews, and repeated full-context replay. Mark the checkpoint blocked on root-cause/design reassessment. Before resetting the counters, record the rejected assumptions, narrowed causal hypothesis, smallest acceptance matrix, changed implementation direction, and who may resume.

Reviewers must be independent of the author they review. A failed, timed-out, interrupted, or ambiguous review does not unlock merge. Reuse a full gate or review only when its key binds the exact `subject_hash`, every applicable `gate_hash`/`charter_hash`, `runtime_identity`, `toolchain_identity`, and `outcome_lock_identity`; any missing, unknown, or changed component invalidates reuse. A subsystem receipt such as an OpenSpec path/blob manifest supplies only its declared subject component: it never overrides, replaces, or implicitly fills the rest of this key. When 野蜂 is active, total-control must compose the subsystem binding with every applicable key component and persist one complete reuse receipt before inheritance. Relevant candidate changes invalidate bound verdicts; archive-only metadata outside the reviewed surface does not when the complete reuse key remains identical.

Track compact delivery signals per cycle: product-path-closed or advanced checkpoints, enablement/spec/test-only checkpoints, merged checkpoints, candidate attempts, review rounds, estimate changes, full build/package rounds, active-state size, and cleanup debt; report running-role count only as a turn-local derived view. Do not present lines changed, documents completed, tests added, or internal checkmarks as equivalent to user-visible value. Record token usage only when exposed by the host; never estimate consumed tokens as fact.

## Evidence Retention

Tracked current-truth retention and ignored runtime-log retention are separate workflows. For a human registry/status snapshot in either embedded or external topology, use [`references/current-truth-retention.md`](references/current-truth-retention.md): publish a lossless hash-bound snapshot and index before replacing the hot projection, and never delete the only historical copy.

Runtime-heavy logs stay ignored by default. The bundled log compactor currently supports only an exact `external-git` control repository and fails closed for embedded topology. After an external reviewed batch reaches a terminal control disposition, use the dry-run, committed `PREPARED`, exact-leaf Apply protocol in [`references/run-evidence-retention.md`](references/run-evidence-retention.md). In embedded mode, retain the logs and record cleanup debt unless a separately reviewed embedded implementation exists. Missing bindings protect legacy runs. Never recursively delete run directories or weaken recovery/review evidence to save space.

A retention-only refresh installs and validates the full five-file trust chain as one rollback-capable transaction. Destination validation and tests are required; source-tree tests alone are not installation proof.

## Pause, Handoff, And Closeout

Pause/handoff/cancel/takeover increments `run_epoch`, invalidates old assignments/heartbeats, preserves evidence, and stops old queue draining. Resume requires explicit current-epoch authority and reconciliation, never `status.md` alone.

At a stable boundary, keep only a compact handoff capsule: objective/non-goals; startup level/topology; exact control/product identities; active roles/checkpoints; completed and remaining gates; blockers; next actor/action; required hot/warm references; cursors/fingerprints; archive pointers; process/worktree cleanup state.

Closeout reports outcome first, then roles launched/resumed/completed, integration identities, messages/blockers, review/validation state changes, broker/cursor state, process and evidence-retention cleanup, control/product Git state, residual decisions, and the next total-control action. Do not include full transcripts or processed historical handoffs.

## Guardrails

- Do not self-claim or let roles dispatch peers.
- Do not merge without exact required validation and literal passing review evidence.
- Do not infer roots, repositories, identities, epochs, permissions, or compatibility fields.
- Do not infer product intent or treat default approval as authority to expand the agreed outcome, MVP, non-goals, public capability families, or schedule baseline.
- Do not dispatch or merge technically valid out-of-lock work; trip the scope breaker and request one batched decision instead.
- Do not invent or import `P50`, `P80`, confidence bands, completion percentages, or another workstream's estimate vocabulary unless the current outcome lock or project policy explicitly defines them. Report known baselines, evidence, deltas, remaining product path, and uncertainty in plain language.
- Do not treat runtime messages, outboxes, broker events, or projections as tracked authority before verified promotion and commit.
- Do not start brokers or role execution below the recorded startup level.
- Do not continue an old queue after pause, handoff, cancellation, archive, or epoch change.
- Do not hide state drift, stale `RUNNING` sessions, unfinished integration intents, or cleanup debt behind a green summary.
