# 野蜂 Total-Control Operations

Read this reference completely for total-control `check`, `poll`, `巡检`, `continue`, `resume`, heartbeat, integration, or closeout turns.

Also read `outcome-and-scope-control.md` completely before the first implementation dispatch, after a material estimate change, or whenever a scope-drift breaker may have tripped.

## Executable Turns

A total-control turn is executable by default, but the recorded startup level, outcome lock, and authorization policy are independent hard bounds. Words such as `check`, `poll`, `巡检`, `continue`, `resume`, and heartbeat mean inspect state and perform every action allowed by all three. Default approval removes repeated operational questions inside those bounds; it never authorizes a different product outcome. Treat a turn as read-only only when the user says `read-only`, `dry-run`, `no launch`, `do not start`, `do not resume`, or `do not merge`, or when startup level, outcome/scope alignment, policy, evidence, capacity, conflict, or missing authority blocks execution.

Treat the snapshot's next-safe-action queue as executable work, not suggestions. Run a drain loop:

1. reconcile the exact outcome-lock revision, user-visible proof, non-goals, delivery classes, estimate baseline, and drift counters;
2. reconcile actual product Git, control Git, worktrees, processes, roles, claims, and current epoch;
3. at authorized Level 3 `control-spool`, verify the exact broker instance, drain accepted runtime events after the tracked cursor, and promote them idempotently into tracked governance; otherwise import legacy/worktree-local role outboxes;
4. route messages and decide whether blockers cleared;
5. resume cleared roles whose assignment remains inside the outcome lock;
6. integrate product branches only when direction-first review and normal evidence gates pass;
7. launch every safe in-lock role that fits capacity only when the recorded startup level permits role execution;
8. update and commit stable control facts;
9. recompute state and repeat until quiescent or a scope-drift breaker trips.

If an action is authorized, unblocked, and within capacity, execute it now. If it cannot execute, record `blocked_by`, `resume_when`, `required_evidence`, and `wake_target`.

Technically possible out-of-lock work is not an executable queue item. When a breaker trips, freeze new dispatch/integration for the affected scope, preserve safe evidence, and issue one batched product decision. Continue unrelated, clearly in-lock work when it remains safe.

Quiescence means one of these is true:

- no executable run completion, outbox, merge, resume, directive, dirty stable governance, or queue item remains;
- remaining work needs authorization, evidence, dependency completion, conflict resolution, or a user decision;
- remaining work is paused by a recorded scope-drift breaker pending one batched outcome-lock decision;
- useful parallel capacity is full and remaining work depends on active roles;
- a launched/resumed role leaves no independent safe action;
- a practical turn budget is reached and the exact deferred actions and reasons are recorded.

## Heartbeat Lifecycle

An already-authorized existing total-control heartbeat is long-lived infrastructure. Its cadence is a wake interval, not a work quantum. Run the drain loop to quiescence before waiting. Do not create or enable one while the recorded level remains Level 1.

Do not stop, pause, or delete an existing authorized heartbeat merely because no roles are running, the queue is empty, or current checkpoints are complete. Stop only when the user explicitly asks to stop, pause, delete, archive, or end the control loop, or when an approved policy requires shutdown.

When idle:

1. verify there are no running roles, pending outboxes, merge-ready branches, ready-to-resume blockers, active directives, dirty stable control files, or incomplete cross-repository integration intents;
2. refresh the status snapshot only if facts changed;
3. report `IDLE_OK`, checked facts, and wake conditions;
4. keep the existing authorized heartbeat cadence, or report that heartbeat is not enabled by the startup-level gate.

Do not create no-op commits to prove a heartbeat ran.

The runtime message broker is separate long-lived infrastructure. It may run only for an active Level 3 `control-spool` scope and should remain active while that execution mode remains active. Its poll cadence is delivery latency, not a total-control heartbeat and not an LLM wake schedule. Verify it by instance ID, PID start time, command line, script path, and script hash. Stop it cooperatively on an authorized scope pause/archive/end or an explicit user/policy stop; never kill a generic PowerShell process. Broker acceptance never replaces the tracked total-control promotion commit.

## Cross-Repository Drain Loop

For `external-git`, process control and product repositories separately:

1. inspect both Git statuses with explicit `git -C` roots;
2. do not let unrelated product-repository dirt block committing independent control facts;
3. never report one combined `clean` state—report control and every affected product repository separately;
4. reconcile incomplete `INTEGRATION_INTENT` events against actual product Git before any new merge;
5. after a successful product merge, commit `BASELINE_UPDATED` with the exact product merge commit;
6. if the control commit fails after product integration, mark reconciliation required and repair idempotently on the next turn rather than attempting to undo unrelated product history.

## Progress And Estimate Reconciliation

For every completed checkpoint, record one primary class from `PRODUCT_PATH_CLOSED`, `PRODUCT_PATH_ADVANCED`, `ENABLEMENT_ONLY`, `SPEC_ONLY`, or `TEST_ONLY`. Name the immediate product consumer for `ENABLEMENT_ONLY`; trip the drift breaker if the consumer is deferred or moved twice.

Keep the last user-confirmed estimate baseline visible. If remaining work grows beyond the recorded tolerance, do not silently replace the baseline. Report the previous baseline, current estimate, scope delta, evidence that changed it, user-visible work completed, enablement-only work completed, and remaining product path, then request one decision only if the outcome lock must change.

Do not add `P50`, `P80`, confidence bands, percentages complete, or estimate labels copied from another workstream unless the current outcome lock or project policy defines them. When the evidence cannot support an honest ETA, state the missing decision/evidence and the next re-estimation boundary instead of fabricating precision.

## Closeout

At closeout, report:

- roles launched, resumed, blocked, replaced, completed, or closed;
- product worktrees/branches created, integrated, and cleaned;
- messages routed, directives changed, and blockers cleared;
- exact product commits and control commits that changed state;
- outcome-lock revision, delivery classification, user-visible proof reached, and any scope/estimate delta;
- validation and reviewer evidence;
- terminal subagent/process cleanup evidence;
- control-repository cleanliness and each affected product-repository cleanliness separately;
- heartbeat state and unresolved user decisions;
- broker state, last accepted/promoted sequence, quarantine/failure state, and whether a cooperative stop is required;
- the next total-control action or the concrete blocker.
