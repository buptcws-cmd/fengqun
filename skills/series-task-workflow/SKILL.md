---
name: series-task-workflow
description: Coordinate user-provided multi-step or multi-module task series with a shared NEXT_STEPS-style registry, coordinator/worker dispatch, claims, worktrees, validation, review, merge, cleanup, pause/handoff, and continuation controls. Use for a series, batch, roadmap, audit set, "one by one" repair flow, multi-conversation workflow, or any request to continue, pause, hand off, or resume an existing coordinated series. Do not use for a standalone report or one-off task unless the user asks to turn it into a series.
---

# Series Task Workflow

## Purpose

Use this skill to turn a large task set into small, independently claimable checkpoints. The default shape is: create or read the shared registry, claim one unblocked task, work in a dedicated worktree, validate and review it, merge it back, update the registry, then release or claim the next genuinely unblocked task.

When the user wants ongoing series execution and subagents are available, prefer a coordinator/worker shape: the main agent coordinates the registry, dependency graph, dispatch, review, merge and cleanup; worker subagents claim and implement individual runnable checkpoints in disjoint task worktrees. The coordinator must not silently become a worker for an already claimed checkpoint.

When a repository uses `yefeng`, let `yefeng` own top-level roles, background processes, the communication bus, and total-control heartbeats. Use this skill for checkpoint, registry, claim, validation, review, merge, and cleanup discipline within that authority model.

## Control Plane Invariants

Treat coordination state as an execution boundary, not documentation commentary.

- Keep one explicit coordinator. If the coordinator directly implements a checkpoint, record a deliberate mode switch, its scope, and when coordinator-only operation resumes.
- Assign a monotonically increasing `run_epoch` to every long-running or multi-conversation series. Bind every claim, worker, reviewer, and continuation to that epoch.
- Treat user instructions to pause, stop, clean up, hand off, or continue in a new conversation as control commands. Increment `run_epoch`, mark the series `paused`, `handed-off`, or `cancelled`, stop or invalidate old workers/heartbeats, and prohibit further writes until an explicit resume creates a current-epoch assignment.
- Reconcile actual Git status, main revision, worktrees, active workers/processes, leases, review subjects, and required external/runtime identity before dispatch, resume, review, merge, cleanup, or a completion claim. Correct stale coordination state before executing new work.
- Apply a default WIP budget of at most two active implementation worktrees, two pending reviews, and one integration/release batch unless the user or local authority records a different budget. Queue discoveries without creating more worktrees when the budget is full.
- Group repeated symptoms by shared root cause. Keep one primary candidate per root-cause group unless an explicit comparison experiment requires more.
- Treat a user progress or ETA request as an intermediate checkpoint. Report current evidence, then continue authorized work unless the user also pauses, redirects, or cancels it.

For a series spanning multiple conversations, delegated workers, or multiple implementation worktrees, read [`references/control-state.md`](references/control-state.md) and require a small machine-readable control state or an existing local equivalent before further delegation. When PowerShell and Git are available, run the read-only [`scripts/reconcile-series-state.ps1`](scripts/reconcile-series-state.ps1) with an explicit `-StatePath` before state-changing actions. Treat a nonzero result or any reported issue as a blocker.

## Intake

1. Classify the request.
   - If it is a standalone review, bug report, or feature request, handle it as a normal task. Do not register it in a persistent roadmap unless the user explicitly asks.
   - If it is a batch, roadmap, module series, audit suite, "系列提案", or "逐个修复" request, use this workflow.
2. Read the local authority for the target repo before changing files: root instructions, project context, OpenSpec rules for proposal/spec work, and any user-named guide.
   - If the repo defines an authorization policy with modes such as `AUTO`, `SCOPED`, `AGENT_REVIEW`, or `ASK`, that policy is the approval source of truth. Generic references to user approval mean the repo's configured approval gate, not necessarily a direct user question.
3. Check current git status and active worktrees. Preserve unrelated changes and avoid taking over another active task unless the user names it and grants authority.
   - Reconcile the registry or machine state against actual Git/worktree/claim state. Do not trust a recorded HEAD, worktree list, lease, or verdict merely because it is recent.
4. Choose the coordination surface deliberately.
   - Use a user-named plan file when provided.
   - For a multi-conversation series, default to a repo-root `NEXT_STEPS.md` unless the repo already has a named equivalent.
   - Use an existing repo roadmap only when it is already the active series board for this exact series.
   - For a single standalone report, prefer a proposal file, issue-style summary, or normal implementation branch over adding rows to a shared `NEXT_STEPS.md`.
5. For a cross-conversation or coordinator/worker series, add or update the repo handoff hook, usually in `AGENTS.md`, telling future agents to read the series registry before claiming work.
6. If the user asked to keep a series moving, decide explicitly whether this main agent is acting as coordinator, as a worker claimant, or both for one specific unblocked checkpoint. Do not let that role be implicit.

## Shared Registry

For cross-conversation series work, maintain a registry on the main branch or equivalent coordination branch. Prefer `NEXT_STEPS.md` unless the user names another file.

Treat the registry as the active coordination surface, not as the permanent archive for every completed series. Historical details should be recoverable from git history, PRs, archived OpenSpec changes, review artifacts, or user-named archives, not by accumulating old completed roadmaps inside the active `NEXT_STEPS.md`. The normal time to handle cleanup is series closeout: after the final task is merged, abandoned, or otherwise closed, remind the user that the active registry can be cleared, archived, deleted, or reset, and follow their decision.

The registry should record:

- series goal and non-goals;
- task ids, titles, and statuses;
- claim lease metadata when claimed;
- branch and worktree paths;
- OpenSpec change id or proposal boundary;
- execution graph, including serial boundaries and safe parallel groups;
- dependencies and blocked tasks;
- shared write surfaces;
- validation and manual product-path evidence;
- review gate and latest verdict;
- merge and cleanup status;
- claimant-only next action and non-claimant/coordinator next action.

Use compact statuses such as `unclaimed`, `claimed`, `blocked`, `proposal`, `proposal-review`, `approved`, `implementation`, `implementation-review`, `done`, `merged`, `paused`, `handed-off`, `cancelled`, `expired`, and `closed`. Keep meanings explicit in the registry if the repo needs different names.

`done` means the worktree task passed its local validation/review. `merged` means it has been integrated back to the main branch and the registry has been updated. Do not treat `done` as merged.

`closed` means the required integration or product-path outcome is complete, durable evidence is archived, claims/workers are terminal, and worktree/branch/artifact disposition is recorded. Do not call a task closed while its execution containers or evidence disposition remain unresolved.

For long-running or delegated series, require a small machine-readable control-state file (or a repository-owned equivalent) for dynamic facts such as `run_epoch`, revisions, claims, worktrees, validation, reviews, and cleanup. Keep the Markdown registry as the concise human view. Resolve conflicts in this order: actual system state, machine control state, current evidence manifest, active registry, archive, conversation or worker self-report.

Treat claims as leases, not permanent ownership. A claim lease records who is actively holding a checkpoint and how to find the work. Prefer a registry column named `Claim` instead of `Owner` or `Owner / Conversation`. If an existing registry already has an owner/conversation column, interpret it as the claim lease field until the registry can be safely renamed. The claim value must be stable and absolute, such as `claim: codex-20260520-1210-t1-preflight; since 2026-05-20T12:10+0800; last_seen=2026-05-20T13:00+0800; lease_expires=2026-05-20T17:00+0800`. For coordinator-dispatched workers, include both a worker token and parent coordinator token, such as `claim: codex-20260520-1430-t2-ai-guidance/worker-a; parent=codex-20260520-1425-series-coordinator; since 2026-05-20T14:30+0800`. If no platform-provided thread or agent id is available, generate a local unique token like `codex-YYYYMMDD-HHMM-<task-slug>`.

Do not write relative claim identities such as `current conversation`, `Current Codex conversation`, `this agent`, `me`, `active Codex`, or `当前会话`. They are ambiguous in future conversations. Any non-empty claim lease means the task is already held unless the registry explicitly marks it released, the user authorizes takeover, or the registry defines and satisfies an expiry rule. When used with yefeng role governance, `lease_expires_at` is normally `last_seen + 4h`; once it passes, the old thread is considered dead and the role/task is reclaimable. A takeover should still record the previous owner, expiry time, and reason, then inspect handoffs, commits, worktrees, and active directives before resuming.

When creating a new `NEXT_STEPS.md` or equivalent registry, do not treat the series as a flat backlog. Map the task dependency graph first: mark which checkpoints must be serial, which can safely run in parallel, which decisions or contracts are prerequisites, and which shared write surfaces make parallel work unsafe. A task should be parallel-eligible only when its upstream assumptions are stable and its declared write surfaces will not collide with another active task.

Generated registries must distinguish the next action for the current claimant from the next action for any other agent. Prefer separate columns named `Claimant Next Action` and `Non-Claimant / Coordinator Action`. If an existing table has only `Next Safe Action`, every active-claim row must explicitly prefix the text with `Claimant-only:` and also state `Non-claimants: do not enter the worktree; report blocked unless takeover/release is explicit.` Never write a claimed task's implementation step as an unqualified global next action.

Keep registry-wide non-goals compatible with task write surfaces. Do not write a broad non-goal such as "do not edit docs" when a later task explicitly owns a docs path. If a setup or fixture instruction says "only create NEXT_STEPS.md" for registry scaffolding, record that as a scaffolding constraint or test-harness note, not as a permanent series non-goal that blocks future workers. Series non-goals should forbid out-of-scope surfaces while each task row lists the surfaces that its claimant may edit.

## Claim Protocol

Only claim work that is `unclaimed` and has no active claim lease, work that is explicitly released by the user/current claimant, or work whose lease is expired and reclaimable under local authority. Do not take over another unexpired active task unless the user authorizes it or the claimant released it.

An active claim is a hard execution boundary for non-claimants. A non-claimant must not enter the claimed task worktree, run validation there, start dev servers, create review artifacts, run governance write-index commands, stage/commit, merge, cleanup, or edit files inside that task. The safe non-claimant actions are to read the registry, inspect main-branch coordination facts when needed, report the blocker, ask for takeover authorization, or wait/heartbeat if the workflow explicitly calls for idle intake.

The exception is an explicitly dispatched reviewer for a review gate. A reviewer may enter the claimed task worktree only when the coordinator or current claimant names the task, worktree, review scope, and allowed review artifact path. The reviewer must keep implementation files read-only, may write only the authorized review artifact or explicitly authorized verdict field, and must not implement, run unrelated validation, stage, commit, merge, release, or clean the task.

When claiming a task, update the registry before implementation with:

- stable claim token and absolute claim time;
- current `run_epoch` for multi-conversation or delegated series;
- `last_seen`, `lease_expires`, and any heartbeat/waiting status when the repo uses leases;
- intended branch/worktree;
- scope and non-goals;
- write surfaces;
- proposal and approval requirements;
- planned validation and review evidence.

Claim the smallest coherent checkpoint. Do not reserve the whole roadmap unless tasks are inseparable or the user explicitly asks this conversation to own the whole series.

Refresh a claim lease at natural progress points: claiming, starting or resuming active work, dispatching or receiving a worker/reviewer result, before and after long commands, writing a handoff, changing blockers, or entering blocked wait. If local authority requires a keepalive heartbeat, use it exactly for liveness renewal. In yefeng projects this is `keepalive-hourly`: it runs about every hour, sets `lease_expires_at` to about `now + 4h`, and must not execute tasks, repeat commands, claim new work, or change scope.

Before every state-changing action, verify that the claim epoch equals the current series epoch and the lease is live. Epoch mismatch, explicit pause/handoff, or an expired lease invalidates execution authority even if a worker process or worktree still exists.

## Coordinator Mode

Use coordinator mode when the user asks to continue a series and subagents can safely own worker checkpoints. Coordinator mode is especially useful when several unblocked tasks can run in parallel.

Model and reasoning tiering is part of dispatch planning. If the user wants top-level agents to use the strongest available model, keep that as the default for the coordinator/final integrator, then choose each worker or reviewer subagent tier by task risk instead of blindly using the strongest tier for every delegation.

- Use the highest tier for final integration, architecture decisions, cross-module contracts, authorization changes, security/privacy boundaries, merge/cleanup decisions, high-impact review gates, and hard root-cause debugging.
- Use a high tier for shared implementation, migrations, editor/version/AI logic, nontrivial refactors, flaky tests, and reviewers whose verdict can unlock `approved`, `done`, merge, or cleanup.
- Use a medium or high-medium tier for bounded implementation, test additions, focused docs updates, local validation, and read-only audits with a narrow scope.
- Use an economy/standard tier only for mechanical search, formatting, boilerplate, or low-risk summarization that cannot change contracts or state.
- If the risk is unclear, upgrade the tier. A reviewer for a high-risk gate should not be weaker than the implementation risk being reviewed.

Record the requested model/reasoning tier in the worker or reviewer prompt, and in the registry or handoff when that choice matters for later audit. Do not preserve raw cost traces unless the repo explicitly requires them; a concise tier label and reason are enough.

Coordinator responsibilities:

- read the local authority and registry before dispatch;
- reconcile actual state and current epoch before dispatch, resume, review, merge, cleanup, or closeout;
- enforce the recorded WIP budget before creating worktrees or reviews;
- decide which checkpoints are runnable, blocked, claimant-only, or safe to parallelize;
- choose and record each dispatched subagent's model/reasoning tier based on task risk;
- avoid claiming worker tasks for the main agent unless the main agent will actually implement that one task;
- create or select one dedicated worktree per worker task before product-file edits;
- update the registry with the worker claim, branch/worktree, scope, write surfaces, validation plan, review gate, claimant-only next action, and non-claimant/coordinator action before dispatch;
- give each worker a bounded prompt naming its task id, requested model/reasoning tier, allowed write surfaces, forbidden surfaces, branch/worktree, validation requirements, and whether it may commit;
- keep worker write sets disjoint unless the registry declares a serial boundary and the upstream worker has released or merged;
- use reviewer subagents as review gates when required, but keep the coordinator responsible for remediation decisions and closure;
- integrate returned worker results by inspecting diffs and evidence, then update only stable registry facts;
- perform commit, merge, release, and cleanup only when the repo/user rules authorize closeout.

Worker responsibilities:

- read the registry and claim lease assigned to them;
- verify their assignment epoch before writes, long commands, commits, and handoff; stop on mismatch or pause/handoff state;
- claim or confirm their assigned registry row before implementation, using a stable token, branch/worktree, scope, write surfaces, validation plan, and review gate;
- stay inside the assigned worktree and declared write surfaces;
- update their own task-local registry facts as work progresses, including status, evidence, blockers, and minimal review conclusions;
- move their own task to `done` only after required validation is recorded and the latest required review explicitly says `review passed`;
- do not edit unrelated registry rows, merge to main, mark `merged`, release shared claims, or clean shared branches unless explicitly authorized;
- return changed files, validation evidence, manual-test evidence or accepted gaps, review status, blockers, and residual risk.

If no task is runnable because every candidate is blocked by active claims, dependencies, approval gates, or shared write surfaces, the coordinator reports the blocker or uses the Idle Heartbeat rules. It must not enter another worker's active task to "help" unless takeover is explicit.

## Proposal Approval Gate

Proposal creation and proposal implementation are separate checkpoints unless the user explicitly approved both in advance. A proposal worker may draft proposal/spec/tasks docs, run proposal validation, and obtain proposal review. After the latest proposal review explicitly says `review passed`, the proposal worker must stop before implementation and return the proposal purpose, execution approach, expected benefit, validation evidence, minimal review conclusion, and any risks to the coordinator.

The coordinator is the only role that satisfies the repo approval gate for implementation. If the repo authority says the gate is `ASK`, the coordinator must summarize the proposal for the user and wait for explicit approval before dispatching an implementation worker or marking the registry status `approved`. If the repo authority says the gate is `AGENT_REVIEW`, an independent reviewer pass plus the required registry evidence can satisfy approval without another user question. A proposal review pass, validation pass, or worker confidence is not approval unless the local authority explicitly says it is.

Registries must make this gate visible:

- before proposal review passes, claimant next action is proposal validation/review and coordinator action is track proposal progress;
- after proposal review passes but before the repo approval gate is satisfied, status should be `proposal-review`, `blocked`, or an explicit waiting-for-approval equivalent, not `approved`;
- claimant next action should say `wait for coordinator/repo approval gate`;
- non-claimant/coordinator action should say `satisfy the repo approval gate: user approval for ASK, minimal review conclusion for AGENT_REVIEW`;
- only after the repo approval gate is satisfied may the coordinator update status to `approved`, record the approval fact/date, and dispatch implementation.

If a worker is asked to implement a proposal and the registry does not record the required repo approval evidence, the worker must stop and report the approval blocker instead of editing implementation surfaces.

## Checkpoint Planning

For the selected series, create or select the smallest coherent checkpoint that can be validated and merged independently.

Record, at least in the conversation or the selected coordination surface:

- checkpoint name and scope;
- prerequisite tasks, downstream dependents, and blocked tasks;
- serial boundaries, safe parallel groups, and shared write surface conflicts;
- expected branch/worktree, when file edits are needed;
- proposal vs implementation boundary;
- validation and manual product-path evidence expected;
- review gate, repo approval gate, and cleanup rule.

Prefer one checkpoint over reserving an entire roadmap. Claim later tasks only when they are inseparable for correctness or the user explicitly asks one conversation to own the whole series.

## Worktree Protocol

For file-changing tasks in a shared series, use a dedicated branch and worktree unless the repo explicitly forbids worktrees or the user asks for a single working tree.

- Name branches predictably, such as `codex/<task-id>-short-title`.
- Record the branch and worktree in the registry.
- For coordinator-dispatched work, record the parent coordinator token and the worker token in the claim or notes.
- Keep writes inside the claimed task's declared surfaces.
- Do not edit another task's worktree or revert changes from other conversations.
- If the task only updates the registry itself, work on the main coordination branch when repo rules allow it.
- Do not create an implementation worktree when the WIP budget is full. Read-only diagnosis and review normally reuse the assigned candidate worktree and do not create additional worktrees.
- Treat worktrees as execution containers, never durable evidence stores. Prefer an existing commit/ref plus an evidence manifest before removing a rejected or paused worktree. For dirty WIP, create an explicitly labelled checkpoint commit only when local/user authority permits it; otherwise preserve an authorized patch plus every staged/unstaged/untracked file it does not capture, or a complete archive, with hashes and restore verification. A Git bundle preserves commits/refs, not dirty files. If no authorized durable form is available, quarantine the worktree and report cleanup blocked instead of destroying the only evidence.

## Execution

1. Reconcile actual state against the registry/control state and verify that the series is active, the epoch is current, the WIP budget allows the action, and the claim belongs to this agent/subagent. If any check fails, stop state-changing execution and record the drift or blocker.
2. Create or switch to the correct dedicated worktree before task file edits when the series registry or repo rules require it.
3. Before claiming or dispatching parallel work, check the dependency graph, serial boundaries, safe parallel groups, and shared write surfaces. Do not parallelize tasks when an unfinished prerequisite could change their assumptions or when active tasks would compete for the same contract, schema, module, or registry surface.
4. For architecture, security, contract, large UX, or cross-module work, create an OpenSpec proposal first when the repo uses OpenSpec. Do not implement before the proposal is reviewed and the repo approval gate is satisfied.
5. Keep edits scoped to the checkpoint. Do not refactor unrelated surfaces or rewrite active work from other conversations.
6. Keep the registry current when scope, blockers, evidence, branch/worktree, dependency order, or review state changes. Do not wait until the end to record meaningful coordination facts.
7. Validate with commands and manual product-path checks appropriate to the changed behavior. Treat interrupted, cancelled, timed-out, incomplete, or stale validation as not passed. Any source change invalidates validation evidence that does not bind the new exact revision.
8. If review is required, send only a review-ready exact revision with its contract and validation evidence. Obtain a post-repair review that explicitly passes before calling the checkpoint `done`.
9. When authorized to close out, commit, merge, update only stable coordination facts, remove disposable worktrees/branches/artifacts, mark the task `merged`, and then reassess the next unblocked checkpoint.

## Review Contract

Do not dispatch formal review until the candidate revision is frozen, required validation is complete, actual diff matches declared write surfaces, and known gaps are explicit. A reviewer receives the task contract, exact base and candidate revisions/diff, validation evidence, and necessary reproduction material—not the author's desired verdict.

Require the reviewer to return:

```yaml
reviewed_revision: <exact revision>
verdict: review passed | review failed
findings: []
residual_risk: <text>
unlock_effect: <what this verdict permits or blocks>
```

A closed, timed-out, interrupted, advisory-only, or ambiguous review has no verdict and remains incomplete. Any candidate change invalidates the prior verdict. Use one independent full review by default; add another only when local authority or material architecture, security, authorization, state-machine, or cross-boundary risk justifies it.

## Completion And Cleanup

Before marking a task `done`, record:

- changed proposal/code/docs surfaces;
- validation commands and results;
- manual product-path evidence or accepted gaps;
- minimal review conclusion and residual risks. A durable review conclusion should name reviewer identity, reviewed scope, verdict, required fixes, re-review status, and unlock/block effect; full review transcripts are process material unless the repo explicitly requires retaining them.

Before marking it `merged`, record:

- merge commit or PR reference when available;
- final branch/worktree cleanup state;
- downstream tasks unblocked or still blocked.

Before marking it `closed`, record:

- final required integration/runtime/product-path evidence;
- archive/evidence-manifest location;
- terminal claim, worker, reviewer, and process state;
- worktree, branch, and temporary-artifact disposition;
- a final reconciliation showing no unrecorded project-owned WIP.

If a task is blocked, mark it `blocked`, state the blocker, and write the next concrete action. Do not leave a claimed task silently idle.

When the whole series is complete, explicitly remind the user that the corresponding active registry is no longer needed for coordination and ask how they want it handled. Offer sensible choices: clear/reset a fixed root file such as `NEXT_STEPS.md`, delete a dedicated registry file, move it to an agreed archive location, or intentionally keep it if the user wants an in-file archive. Do not silently leave completed task rows, closeout summaries, or historical task tables in the active registry as the default. Once the user chooses cleanup, carry it out during closeout and record stable history in commits, PRs, archived OpenSpec changes, review artifacts, or user-named archives rather than copying completed series content forward.

## Continuation

Continue automatically while the user has asked for series execution until the series is complete, the user cancels continuation, or a hard blocker requires a user decision. A series is complete only when the registry marks all relevant checkpoints as `merged`, `abandoned`, or an explicit closed/completed equivalent.

If the user pauses, asks for cleanup before a new conversation, or requests handoff, stop continuation immediately: increment the epoch, mark the control state, cancel/interrupt or invalidate active workers and heartbeats, preserve required evidence, and perform only the requested cleanup/handoff. Do not resume because an old task, automation, worker, or next-action field still says to continue. Resume only from an explicit user instruction and a new current-epoch assignment.

Stop normal task execution and report the blocker when:

- a prerequisite is unmet;
- another active worktree owns the needed surface;
- proposal approval is required;
- real credentials, production access, or irreversible behavior needs confirmation;
- no safe unclaimed checkpoint exists for this coordinator/worker role;

## Idle Heartbeat

For an open series, follow the heartbeat model required by local authority. In yefeng role-based projects, use two distinct heartbeats:

- `keepalive-hourly`: always active for a claimed non-`DONE` role or task, only to refresh `last_seen` and `lease_expires_at=now+4h`.
- `blocker-check-20m`: active only while this conversation has no runnable claimed task, no safe unclaimed checkpoint in its role, and a concrete blocker to re-check.

For non-yefeng series without local heartbeat rules, maintain one idle thread heartbeat at 15 minutes by default only while all of these are true:

- this conversation has no runnable claimed task;
- no safe unclaimed checkpoint exists;
- no local validation, review, merge, cleanup, or other task execution is currently in progress in this conversation;
- the user has asked for continued series execution or the repo guide explicitly calls for idle intake.

If a runnable task appears, or this conversation has a claimed task that can continue, stop the idle or `blocker-check-20m` heartbeat before claiming or continuing work, while keeping any required keepalive heartbeat. If the registry shows the series is complete, or the user cancels continuation, stop the heartbeat permanently and do not recreate it; in yefeng role workflows, stop both `keepalive-hourly` and `blocker-check-20m` when the role is `DONE`.

Before creating a heartbeat, check whether one already exists for the same series when the environment supports automation inspection. Update the existing heartbeat instead of creating a duplicate. If heartbeat automation is unavailable, report the idle state and stop; do not emulate it with shell loops.

Heartbeat wakeups must be quiet and registry-driven: reread the local authority and series registry, obey claim leases, refresh waiting leases when appropriate, continue only newly runnable work, and avoid file edits or long reports when nothing changed. A keepalive wake is even narrower: refresh liveness and exit. Never park a shell `sleep`, `while`, or other long-running process to keep a series alive.

## User-Facing Closeout

For each checkpoint, report the purpose, what changed or was proposed, validation evidence, minimal review conclusion, merge/cleanup state, and the next gated decision. Keep the report brief enough that the user can approve or redirect without reading a second audit log.

For ongoing work or a progress request, report: current cycle/stage; evidence-backed changes since the last report; active owner/state/elapsed time; remaining gates; blockers/risks; current WIP/cleanup debt; next milestone; and P50/P80 ETA assumptions for that milestone. Do not invent a total ETA for an open-ended series. After reporting, continue authorized work unless the user paused, redirected, or cancelled it.
