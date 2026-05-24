---
name: yefeng
description: Convert a rough, ambitious, or ambiguous user vision into a governed series-proposal workflow with clarifying questions, final-architecture-vs-MVP choice, docs scaffolding, checkpoint planning, parallel task registration, lightweight status snapshots, subagent delegation rules, and heartbeat-style integration. Use when the user asks to create proposals, roadmap a large project, coordinate multiple series, run parallel conversations/subagents, build a total-control document, reduce yefeng startup context cost with a status snapshot, or turn an idea into a long-running governed development system.
---

# Yefeng

## Purpose

Use this skill to turn a large fuzzy request into a durable operating system for work: clarify the user's intent, choose the right planning mode, create series proposals and governance docs, then support parallel execution without losing control of dependencies or shared contracts.

This skill is especially useful when the user says the project is a long-term personal system, toy, research effort, architecture-first build, or multi-module product. Do not assume MVP-first; ask.

## Core Workflow

### 1. Intake The Vision

Read the local docs/code if present. Then ask only the few questions needed to choose the operating mode:

- Is this for personal use, external users, research, production, or a client?
- Is the priority fast MVP validation or final architecture first?
- Should work happen in one conversation, multiple conversations, or via subagents?
- Should git be initialized now, later, or not at all?
- Who may modify the total-control document and the parallel task registry?
- Which operation classes should be `AUTO`, `SCOPED`, `AGENT_REVIEW`, `ASK`, or `FORBID`?
- Is a heartbeat/follow-up integrator wanted? If so, suggest a cadence.

If the user signals "not time constrained", "personal toy", "I want it architected well", or "straight to final version", choose **final-architecture-first**. Treat any MVP as only a first runnable path, never as a feature ceiling.

### 2. Establish Governance Before Implementation

Before code implementation, create or update governance docs. Use names that fit the repo language; for Chinese projects these defaults work well:

- `docs/项目总览.md`
- `docs/系列提案-全周期总控.md`
- `docs/授权策略.md`
- `docs/角色认领.md` when multiple top-level conversations should self-assign roles
- `docs/并行任务登记.md`
- `docs/总控指令.md` when the final integrator must send conflict rulings or recovery instructions to roles
- `docs/总控状态快照.md` when repeated yefeng starts would otherwise require rereading the full governance set
- `docs/交接报告/` when parallel conversations need file-based handoff
- One proposal doc per series, such as `docs/系列提案-数据与存储.md`

The total-control document owns:

- final capability map or MVP boundary;
- checkpoint list and statuses;
- cross-module dependencies;
- write-scope rules;
- approval gates;
- conflict handling;
- integration rules.

The authorization policy owns:

- which operations can run automatically;
- which operations require subagent review before continuation;
- which operations still require asking the user;
- which scopes are allowed for file edits, worktrees, merges, cleanup, dependency installation, network use, secrets, and release actions;
- who or what may move proposal checkpoints to `APPROVED`, implementation checkpoints to `DONE`, and worktree branches into the integration line.

The parallel task registry owns:

- task/checkpoint claims;
- write scopes and forbidden scopes;
- local series ownership;
- review/integration tasks;
- handoff notes.

The role-claim document owns:

- the required final integrator role, `INTEGRATOR`, as priority 0;
- the required coordinator roles;
- whether each role is `OPEN`, `CLAIMED`, `ACTIVE`, `REPORT_READY`, `BLOCKED`, `STALE_CANDIDATE`, or `DONE`;
- the `role_instance_id` / owner label for each role;
- soft lease fields such as `last_seen`, `lease_expires_at`, and `heartbeat_status`;
- the role's owned proposal file and write scope;
- whether all required roles have been claimed.

The control-directive document owns:

- active instructions from the final integrator to affected roles;
- conflict rulings that cannot be inferred safely from total-control, authorization, or registry docs alone;
- affected roles, checkpoints, contracts, required actions, allowed write scopes, and resume conditions;
- directive status such as `ACTIVE`, `ACKNOWLEDGED`, `APPLIED`, `SUPERSEDED`, or `CLOSED`.

It is a downward coordination channel, not a second total-control document and not a place for long role reports.

The handoff-report directory is only a temporary inbox. It stores reports that a final integrator has not processed yet; it must not become a second total-control document.

The status snapshot owns only bootstrapping facts:

- latest known project mode, authority, active integrator, open roles, active directives, unprocessed handoffs, next safe checkpoints, and blocked implementation gates;
- short pointers to authoritative docs, not full copied sections;
- a freshness marker and the rule that authoritative docs win when stale or conflicting.

It is a read-optimization layer, not an approval source, not a second registry, and not a replacement for checking active directives before work.

Use `references/templates.md` when you need concrete document skeletons or registry tables.

### 3. Choose The Planning Mode

Use one of these modes:

- **Final Architecture First**: Design the final system from the start; implement by dependency order. Use for personal toys, long-term systems, deep architecture work, or when the user rejects MVP cutting.
- **MVP Iteration**: Define a smallest useful product and defer nonessential capabilities. Use only when the user wants fast delivery, external validation, deadline control, or constrained scope.
- **Research Exploration**: Maintain open questions, experiments, and evidence. Use when the user is discovering the domain.
- **Repair Series**: Turn an audit or bug set into checkpointed fixes. Use when the user has a list of issues to process.

When in doubt, ask a direct question instead of silently choosing MVP.

### 4. Create Series Proposals

Split the work into series tracks with disjoint ownership. Typical tracks:

- Product and information architecture
- Data and storage
- Editor and versioning
- AI orchestration and context
- Knowledge base / graph / memory
- Engineering and release
- Quality and validation

Every proposal document must include:

```md
状态：
所属阶段：
负责范围：
主要产物：
前置依赖：
阻塞对象：
写入范围：
审批门槛：
验证方式：
```

Keep proposal states conservative: `DRAFT` until reviewed. Do not mark `APPROVED` just because the document exists.

### 5. Create Authorization Policy

When creating a series proposal system, define permissions up front instead of asking repeatedly during execution. Create or update an authorization policy such as `docs/授权策略.md`.

Use these authorization modes:

- `AUTO`: execute without asking when the task is in scope.
- `SCOPED`: execute automatically only within the listed files, directories, branches, worktrees, tools, or command classes.
- `AGENT_REVIEW`: execute or advance only after an independent reviewer subagent approves the proposal, implementation, merge, or cleanup evidence.
- `ASK`: ask the user before executing.
- `FORBID`: do not execute.

Review authority is part of the authorization policy. `ASK` or a manual-review gate means the user may review directly or name a reviewer. `AGENT_REVIEW` means the user has delegated that gate to the conversation: the current coordinator deploys an independent reviewer subagent for its own proposal, worker output, implementation, merge, or cleanup evidence. The final integrator is not the routine reviewer for coordinator work; it integrates reviewer-passed evidence, checks that evidence exists, records state, and handles conflicts.

The policy should cover at least:

- editing proposal docs, total-control docs, role claims, task registry, and handoff reports;
- spawning subagents and reviewer subagents;
- proposal review and moving checkpoints to `APPROVED`;
- implementation review and moving checkpoints to `DONE`;
- git init, branch/worktree creation, merge, cleanup, and baseline commits;
- dependency install, code generation, tests, lint, build, format, and local app startup;
- OpenSpec proposal creation, review, apply, archive, and spec updates when the repo uses OpenSpec;
- destructive filesystem cleanup, external network, real API keys, cloud sync, publishing, and release actions.

If the user grants broad authority, encode it in the policy as `AUTO`, `SCOPED`, or `AGENT_REVIEW` rather than keeping it as chat-only permission. If the user does not grant broad authority, default risky operations to `ASK`.

In highly automated projects, prefer this gate:

```text
Proposal created -> reviewer subagent checks proposal -> if pass and policy allows AGENT_REVIEW, checkpoint may become APPROVED -> coordinator starts implementation.
Implementation complete -> reviewer subagent checks tests/evidence/diff -> if pass and policy allows AGENT_REVIEW, checkpoint may become DONE and worktree may merge.
```

The user is only required for operations marked `ASK`, policy changes that expand authority, conflicts that the policy cannot resolve, secrets/credentials not already provisioned, irreversible external publication, or destructive actions outside the declared scope.

### 6. Self-Claim Roles

When a yefeng project already has governance docs and the user asks a new conversation to "use yefeng" or "advance according to the yefeng workflow" without naming a role, the conversation should not ask the user to assign one by hand.

Every multi-conversation yefeng project must include exactly one final integrator role:

- `INTEGRATOR` is priority 0 and must be claimed or active before series coordinator roles proceed.
- If no `INTEGRATOR` is `CLAIMED` or `ACTIVE`, the next eligible execution conversation claims `INTEGRATOR` first.
- If `INTEGRATOR` is already `CLAIMED` or `ACTIVE`, new conversations skip it and claim the highest-priority eligible series coordinator role.
- If the current conversation is only designing or updating the workflow/skill and is not acting as an execution line, do not claim `INTEGRATOR`; update the rule and tell the user that execution should start with an integrator claim.
- There must not be two active integrators. A duplicate integrator claim is a `COLLISION` and must stop until resolved.

Instead:

1. If a status snapshot such as `docs/总控状态快照.md` exists, read it first to orient cheaply. Then read the authorization policy, role-claim document, task registry, control-directive document, and any snapshot-listed authoritative docs needed for the next action. If the snapshot is missing, stale, or conflicts with authoritative docs, ignore the conflicting snapshot facts and refresh it after the authoritative read.
2. If the role-claim document does not exist and the user is setting up multi-conversation work, create it from the template before starting parallel work.
3. Ensure the role-claim document contains an `INTEGRATOR` row at priority 0. Add it if missing.
4. If `INTEGRATOR` is `OPEN` and this is an execution conversation, claim `INTEGRATOR` before any series role.
5. Read the current conversation identity before claiming. Prefer the environment variable `CODEX_THREAD_ID`; if it is unavailable, generate and persist a UUID fallback.
6. Enforce **one top-level thread, one top-level role**. If this thread identity already owns a non-`DONE` role in the role-claim document, resume or wait on that role. Do not claim a second coordinator role just because another role has unblocked work.
7. Otherwise pick the highest-priority eligible `OPEN` series coordinator role whose write scope does not conflict with `CLAIMED` or `ACTIVE` work.
8. Generate a unique `role_instance_id` from the role and thread identity, then claim that role by updating the role-claim document with the instance ID, full thread ID, timestamp, intended checkpoint, write scope, and any implementation worktree/branch if one exists.
9. Set or refresh the role's soft lease fields. Active work should normally use a generous lease, such as `now + 4h`, and waiting or blocked work should use the heartbeat cadence from the authorization policy.
10. Re-read the role-claim document after writing. If another conversation claimed the same role first, mark or report the collision and choose another `OPEN` role only if this thread still owns no other non-`DONE` role.
11. Treat expired leases as `STALE_CANDIDATE`, not as automatic release. A stale candidate may be taken over only when the authorization policy, final integrator, or user allows it and there is no recent progress, handoff, heartbeat, commit, or status update from the claimant.
12. If the authorization policy allows heartbeat automation, create or update a thread-local heartbeat for this role when waiting or blocked. Do not create a shared role-heartbeat document; a heartbeat can only wake its own thread.
13. Announce the claimed role, owned files, forbidden files, immediate checkpoint, lease/heartbeat status, and next refresh condition.
14. If `INTEGRATOR` and all required coordinator roles are no longer `OPEN`, report that role claiming is complete and list the owners.

Before starting any checkpoint or subtask, the coordinator must check the control-directive document. If an `ACTIVE` directive targets its role, checkpoint, write scope, or contract, follow that directive before claiming new work.

Top-level execution conversations are either the **final integrator** or **series coordinators**, not just direct workers. The final integrator owns shared coordination, conflict directives, task digestion, and total-control updates. A series coordinator plans the role's work, delegates bounded subwork where allowed, reviews subagent output, updates its owned proposal or handoff report, and submits total-control writeback suggestions.

A top-level execution conversation must not be both a final integrator and a series coordinator, or two different series coordinators, at the same time. Worker and reviewer subagents do not count as top-level role owners; they are delegated by the current role and must stay inside that role's task scope.

Role ownership labels must be unambiguous. Do not use labels like "this conversation" or "current chat" as owners. Use the conversation's self-visible thread identity as the primary cross-conversation differentiator.

Identity rule:

- Prefer `CODEX_THREAD_ID` when the local environment exposes it.
- If no thread ID is available, generate a UUID once and immediately write it into the role-claim document; do not regenerate it later.
- Treat worktree, branch, and proposal slug as scope or implementation-isolation metadata, not as part of conversation identity.

Use a stable role instance ID:

```text
<ROLE_ID>@thread-<thread_id_or_uuid>
```

Examples:

- `INTEGRATOR@thread-019e4a8c-1bf9-7ca2-8b6d-984aa15e98cf`
- `COORD-P@thread-019e4b19-4109-7250-b682-8afa4bfe75b2`
- `COORD-D@thread-019e4c20-8a77-7000-9123-example000001`

Use the full thread ID in the `role_instance_id` when practical; if a display-shortened owner is used, the full `thread_id` must be recorded in a separate field. When a role creates a branch or worktree, record the exact branch and worktree path in the task registry or handoff report, but do not use it to distinguish conversations. Shared docs such as the role-claim board, task registry, control directives, and handoff inbox still live on the main line so every conversation can read coordination state.

If an old role row has an owner such as "this conversation", "current thread", or lacks a thread ID, the owning role must refresh its row with `CODEX_THREAD_ID` before taking new work.

Lease rule:

- A role lease is a recovery signal, not a hard lock timeout.
- Refresh `last_seen` and `lease_expires_at` when claiming, starting or resuming active work, dispatching a worker or reviewer, starting a long command, finishing a long command, writing a handoff, changing blocker state, or entering heartbeat wait.
- Do not let a background heartbeat interrupt active execution just to renew the lease. Active threads should renew at natural progress checkpoints and choose a long enough lease for the task.
- Mark a role `STALE_CANDIDATE` only after its soft lease has expired and there is no recent evidence of progress. Do not release or reassign it automatically.
- The final integrator can clear a stale candidate, extend its lease, or authorize takeover only after checking handoffs, task registry rows, recent git activity, active directives, and the authorization policy.

Use subagents when the current user request or the authorization policy allows subagents, delegation, or parallel agent work. If both are absent, the coordinator should work locally and say that subagent delegation is ready but needs authorization.

#### Coordinator execution loop

A series coordinator is responsible for forward motion inside its owned scope, not only for producing one handoff report. When authorization allows subagents:

1. Before active work begins or resumes, pause the role heartbeat if one exists. Heartbeats are for waiting or blocked states, not for work already being executed in the current thread.
2. Refresh the role's soft lease before meaningful active work. If the task may run long, extend the active lease generously rather than scheduling a heartbeat that will interrupt active work.
3. Pick the next eligible unblocked task in the role's scope. A task is blocked only when a declared dependency is unmet, an `ACTIVE` control directive applies, write scopes conflict, authorization requires `ASK`, reviewer failure cannot be repaired locally, or another external condition is genuinely missing.
4. Decompose execution into bounded worker subagent tasks when that materially advances the role. Give each worker a clear write/read scope and remind it that it is not alone in the workspace.
5. Refresh the role lease before and after dispatching worker or reviewer subagents, before long commands, and after long commands complete.
6. After a worker, coordinator, or implementation subtask produces a proposal, patch, report, or implementation output that needs acceptance, follow the authorization gate. If it is `AGENT_REVIEW`, deploy an independent reviewer subagent from the current coordinator thread; if it is `ASK`, stop for user/manual review. The reviewer must not be the same agent that produced the work.
7. If the reviewer fails, repair within the role's allowed scope and redeploy a reviewer. Do not mark the task `BLOCKED` merely because the first review failed.
8. If a review task such as `REV-*` is open and directly matches the coordinator's current scope, the coordinator may deploy a read-only reviewer subagent even when the final integrator owns registry writes. The minimal review conclusion can be attached to the role handoff or a new handoff report for integrator integration.
9. After each reviewed task, record the minimal review conclusion needed for later state movement, then check for the next eligible unblocked task in the same role or series. Continue only inside the current top-level role.
10. Mark the role `REPORT_READY` / `BLOCKED` and activate or refresh that role's heartbeat only when there is no unblocked task the role can safely advance and there is a concrete same-role resume condition, such as reviewer output, a declared upstream dependency, another role's required result, an `ACTIVE` control directive, or a user/manual-review decision. Do not activate heartbeat merely because a handoff report has not been processed.

An unprocessed handoff is not by itself a blocker. Use handoff reports to inform the integrator while continuing local, non-conflicting work in the same role. If only other roles have unblocked work, this thread waits only when its own role has a concrete resume condition; a new top-level conversation should claim those other roles.

### 7. Parallelize Safely

If the user explicitly authorizes subagents or multiple conversations, or the authorization policy already allows them:

- Give each coordinator role one owned proposal file or disjoint directory.
- Let coordinators decompose work into bounded subagent tasks with disjoint read/write scopes.
- After delegated work completes, route the result through an independent reviewer subagent before treating it as approved, done, mergeable, or ready to unblock later work.
- Tell each worker it is not alone in the workspace.
- Forbid workers from changing total-control and registry docs unless explicitly assigned.
- Forbid subagents from changing the role-claim document, total-control document, or task registry unless explicitly assigned; they report back to their coordinator.
- Have coordinators report changed files, covered checkpoints, key dependencies, and total-control update suggestions.
- Use a final integrator to integrate reviewer-passed evidence, review conflicts, and update shared docs.

For multi-conversation workflows, use this governance model:

- Each series coordinator maintains its own proposal and local notes.
- The main registry is visible to all lines.
- The control-directive document is visible to all lines and carries final-integrator instructions back to affected roles.
- A final integrator modifies total-control and global registry.
- Series coordinators submit "total-control writeback suggestions"; they do not directly change shared cross-contracts.

If a coordinator finds a conflict that cannot be resolved from the total-control document, authorization policy, task registry, and current control directives, it must stop the affected work, write a handoff report, and mark the role or checkpoint blocked where policy allows. It activates its thread-local heartbeat only when there is no other unblocked task in the same role and the missing final-integrator directive is the concrete resume condition.

### 8. Use Handoff Documents

For multi-conversation workflows, prefer a shared handoff inbox when chat-only copying becomes fragile. Use a project-local directory such as `docs/交接报告/`.

Each series coordinator may create or update exactly one handoff report for its current assignment, using a clear filename such as:

```text
YYYYMMDD-HHMM-<role>-<checkpoint>.md
```

A handoff report is an evidence packet and temporary coordination record, not a lock on the role. An unprocessed handoff does not block the same coordinator from continuing unblocked same-role work and does not justify heartbeat without a concrete resume condition.

A handoff report should include:

- role and checkpoint;
- files changed;
- checkpoints covered;
- status suggestions, such as `REVIEW_REQUESTED`, `REVIEW`, or `BLOCKED`;
- cross-module contract impacts;
- conflicts found;
- total-control writeback suggestions;
- registry update suggestions;
- unresolved user decisions.

After the final integrator processes a handoff report:

- stable facts must be written into the task registry, total-control document, or relevant proposal;
- unresolved blockers must be registered in the task registry;
- a concise handoff digest must be recorded in the registry, directive board, or total-control change log;
- any reviewer result should be reduced to the minimum durable conclusion: reviewer identity, reviewed scope, verdict, required fixes, whether fixes were re-reviewed, and what the verdict unlocks or keeps blocked;
- the processed handoff report must be deleted or cleared;
- only the persistent `README` or template remains in the handoff directory.

Use digestion, not copying. The final integrator should extract only durable coordination facts:

- role, checkpoint, report file, processed time;
- changed files or scopes;
- status delta;
- stable decisions or facts, capped to a short summary;
- blockers or control directives opened;
- reviewer conclusion if relevant, summarized rather than copied;
- next owner or resume condition.

Do not paste long report bodies, reviewer transcripts, or process logs into the registry or total-control document. Reviewer findings are process material when they have been fixed and re-reviewed; preserve the minimal conclusion and status effect, not the full transcript. If detail is needed later, rely on git history, diff summaries, or the affected proposal document. Do not let old handoff reports accumulate. The handoff directory is an inbox, not an archive.

### 9. Use Control Directives

Use a project-local control-directive document such as `docs/总控指令.md` as the persistent channel from the final integrator back to series coordinators.

Each directive should include:

- directive ID and status;
- source conflict or handoff report;
- affected roles, checkpoints, contracts, and files;
- final-integrator decision;
- required repair or alignment steps;
- allowed write scope;
- resume condition;
- expected role feedback or handoff report;
- close condition.

Lifecycle:

1. A role detects a conflict that cannot be automatically adjudicated. It stops the affected work, writes a handoff report, and marks itself or the task blocked if policy allows. It activates its heartbeat only if there is no other unblocked task in the same role and a final-integrator directive is the concrete resume condition.
2. The final integrator reads the handoff report and authoritative docs, then writes or updates a directive with the repair strategy and resume condition.
3. The affected role's next normal turn or heartbeat wake reads the directive before taking any new task.
4. If the directive unblocks the role, the role pauses its heartbeat, applies the required repair inside its allowed scope, and writes feedback through a handoff report or the allowed acknowledgement field.
5. The final integrator closes or supersedes the directive after stable facts are written back to the total-control document, registry, or proposal docs.

Directives do not replace authorization or reviewer gates. A directive can tell a role how to repair or resume; it cannot by itself approve a checkpoint, mark implementation `DONE`, or merge work unless the authorization policy and minimal review conclusion also allow that action.

### 10. Integrate And Review

After proposals are created or updated:

- Process any unprocessed handoff reports first, then clean them up after stable facts have been folded into the authoritative docs.
- Process active control directives and close only those whose stable facts have been folded into the authoritative docs.
- Read the authorization policy before deciding whether review, approval, merge, cleanup, or continuation needs a user question.
- Check required headers.
- Search for old assumptions, especially accidental MVP ceilings in final-architecture-first projects.
- Identify conflicting terms and shared contracts.
- Update the total-control document only with stable coordination facts.
- Move tasks to `REVIEW`, `APPROVED`, `DONE`, or merge-ready only through the authorization policy and agreed review evidence, not by instinct.
- Refresh the status snapshot after durable changes to roles, task states, active directives, handoff inbox, approval gates, or next safe checkpoints.

When policy allows `AGENT_REVIEW`, use an independent reviewer subagent as the approval gate. The reviewer must not be the same agent that produced the proposal or implementation. The coordinator that owns the work deploys this reviewer unless the task is explicitly an integration-owned review. A passing minimal review conclusion may authorize the coordinator or final integrator to advance the checkpoint without asking the user.

The final integrator's normal review duty is evidence and state integration: verify that the required reviewer gate happened, check conflicts, fold stable facts into shared docs, and issue directives when needed. The durable record may be a short reviewer conclusion rather than the full reviewer transcript, as long as it names the reviewer, reviewed scope, verdict, required fixes, re-review status, and unlock/block effect. If even that minimum evidence is missing under `AGENT_REVIEW`, return the work to the coordinator to deploy a reviewer instead of using the final integrator as the default reviewer.

If the reviewer returns "fail" or "needs changes", the coordinator should repair the identified issues and redeploy an independent reviewer. Do not ask the user or mark the checkpoint `BLOCKED` just because the first review failed. Use `BLOCKED` only when the fix requires a missing dependency, cross-role contract decision, authorization outside policy, or the coordinator wants to proceed despite a failing review.

Recommended review lanes:

- Product + validation review
- Data + editor + version + AI contract review
- Knowledge graph + AI + version review
- Engineering + quality + safety review
- Terminology / total-control integration

### 11. Heartbeat Integration

Use heartbeat automation when the user asks for periodic integration or the authorization policy grants heartbeat automation. For high-frequency Codex-driven work, suggest 15-20 minutes; for quiet waiting states, hourly or daily is enough. Do not use heartbeat just to renew an active role lease while the same thread is already working; active work should refresh its lease at natural progress checkpoints.

There are two heartbeat levels:

- **Final integrator heartbeat**: checks all roles, shared docs, handoff reports, conflicts, and global status.
- **Role coordinator heartbeat**: checks one role's blockers, dependencies, minimal review conclusions, handoff status, and next unblocked checkpoint.

All coordinator roles should use a thread-local heartbeat when the policy allows it and when the role is waiting or blocked. Lifecycle:

1. After claiming a role, create a heartbeat for the current thread if the role may need to wake later.
2. When actively executing work in the current thread, pause or do not schedule the heartbeat so it does not wake redundantly. This includes active proposal work, worker coordination, reviewer deployment, reviewer repair loops, and local handoff writing.
3. When blocked or waiting for a concrete same-role resume condition, activate the heartbeat only if there is no other unblocked task in the role's scope that can be advanced safely. Valid resume conditions include reviewer output, an upstream dependency, another role's required result, an `ACTIVE` control directive, or a user/manual-review decision. Do not activate a role heartbeat merely because a handoff report is unprocessed.
4. On heartbeat wake, re-read authorization policy, role claim, task registry, total-control, handoff inbox, and the owned proposal.
5. Read active control directives before taking any new checkpoint; if a directive targets this role, apply it first.
6. If unblocked, pause the heartbeat, refresh the role lease for active work, and continue work inside the same role, including delegating the next eligible task in that role if one exists.
7. If still blocked, report the current blocker, refresh `last_seen` and the waiting lease, and do not duplicate work.
8. When the role reaches `DONE` and has no active or waiting checkpoint, delete or stop the heartbeat.

A final integrator heartbeat should inspect:

- status snapshot first, when present, to reduce startup context;
- role-claim document;
- authorization policy;
- task registry;
- control-directive document;
- total-control document;
- series proposal docs;
- unprocessed handoff reports;
- new writeback suggestions;
- write-scope conflicts;
- cross-contract changes;
- checkpoints ready for review, approval, implementation, merge, or cleanup under the authorization policy;
- checkpoints that should be blocked.

The heartbeat may report suggestions automatically. It may approve checkpoints or merge/cleanup work only when the authorization policy explicitly allows that path and required minimal review conclusion is present.

When authorized to modify files, a heartbeat integrator may clean processed handoff reports after recording stable facts in the registry or total-control document. Without that authority, it should report which handoff files are safe to clear.

After processing reports, directives, or status changes, the final integrator should update the status snapshot with only compact durable facts and pointers. Do not paste long handoff bodies, reviewer transcripts, or proposal text into the snapshot.

A role coordinator heartbeat should inspect:

- status snapshot first, when present, to identify likely blockers and next documents to read;
- its own role row;
- its owned proposal;
- relevant task registry rows;
- active control directives for its role, checkpoint, write scope, or contract;
- relevant handoff report;
- reviewer subagent minimal conclusions or missing reviewer gate evidence;
- upstream dependency checkpoints;
- authorization policy changes.
- lease fields for the current role, including whether it is merely waiting, active, or a stale candidate.

It should not update unrelated roles or global docs unless the authorization policy explicitly allows it.

### 12. Maintain Status Snapshot

Use a project-local status snapshot such as `docs/总控状态快照.md` to reduce repeated startup cost in mature yefeng projects.

Create the snapshot when governance docs exist and repeated role starts, heartbeats, or integration turns would otherwise reread the full total-control stack. Keep it short enough to load cheaply.

The snapshot should include:

- freshness: updated time, updater role/thread, source docs checked;
- startup read order: which docs to read every time and which to read only when needed;
- current mode and authority summary;
- active integrator and claimed/report-ready/open roles;
- role soft-lease health, including stale candidates and takeover blockers;
- active control directives, if any;
- unprocessed handoff reports;
- open review lanes and blocked implementation gates;
- next safe actions by role;
- conflicts, stale risks, and links back to authoritative docs.

Rules:

1. Read the snapshot first on yefeng startup when it exists.
2. Always read `docs/授权策略.md`, `docs/角色认领.md`, `docs/并行任务登记.md`, and `docs/总控指令.md` before claiming or executing work, unless the user only asks a high-level question.
3. Treat the snapshot as stale if its listed source docs changed after its timestamp, if git status shows those docs modified after the snapshot, or if its facts conflict with authoritative docs.
4. When stale or conflicting, trust authoritative docs, then refresh the snapshot.
5. Update the snapshot after processing handoffs, opening/closing directives, changing role/task states, approving checkpoints, completing merges, or changing authorization.
6. Do not use the snapshot to approve checkpoints, mark work `DONE`, resolve conflicts, or override authorization.
7. Keep detailed history in the registry, total-control document, handoff digests, minimal review conclusions, or git history. The snapshot is the map, not the territory.

## Guardrails

- Do not implement before governance exists unless the user explicitly asks for a one-off implementation.
- Do not default to MVP when the user wants a long-term final system.
- Do not rely on chat-only broad permission; write authorization into the project policy before using it repeatedly.
- Do not let multiple roles freely edit the total-control document.
- Do not let one top-level thread own multiple non-`DONE` roles. A thread that already owns a role must resume, wait on, or finish that role instead of claiming another role.
- Do not make the user manually assign roles when a role-claim board exists and eligible roles are open.
- Do not leave active role heartbeats running after the role is `DONE`.
- Do not let a role heartbeat do duplicate work while the role coordinator is already actively executing in the same thread.
- Do not use heartbeat as a substitute for deploying required worker or reviewer subagents. Heartbeat is a waiting mechanism, not the normal execution engine.
- Do not treat an expired role lease as automatic permission to release or take over a role. It is only a stale-candidate signal until checked by the authorized integrator or user.
- Do not mark a role `REPORT_READY` while it still has eligible unblocked tasks in its scope unless the final integrator explicitly asked for a pause.
- Do not use the final integrator as the default reviewer when the authorization policy grants `AGENT_REVIEW`; the coordinator must deploy an independent reviewer subagent.
- Do not treat an unprocessed handoff report as a blocker or heartbeat reason by itself.
- Do not use "continue unblocked work" to jump to another coordinator's series. Continuing means continuing within the current role's owned proposal, review lane, handoff, or explicitly assigned same-role task.
- Do not let registry updates become hidden chat-only state; write them into the agreed registry.
- Do not let final-integrator repair decisions become hidden chat-only state; write them into the control-directive document.
- Do not start new role work while an active control directive targets that role, checkpoint, write scope, or contract.
- Do not let the status snapshot override authorization, role claims, task registry, active directives, minimal review conclusions, or total-control facts.
- Do not preserve processed handoff reports as permanent coordination state.
- Do not advance to `APPROVED`, `DONE`, merge, cleanup, release, or destructive operations unless the authorization policy and required evidence allow it.
- If git is not initialized and parallel work is about to begin, recommend initializing git and committing a documentation baseline.

## Expected Closeout

When finishing a yefeng step, report:

- created or changed governance files;
- authorization policy changes and effective authority;
- status snapshot created, refreshed, stale, or not needed;
- role claimed or role-claim completion status;
- role lease refreshed, stale-candidate status, or takeover not needed;
- heartbeat created, paused, activated, stopped, or not needed;
- control directives opened, applied, superseded, closed, or not needed;
- series/checkpoints covered;
- unresolved decisions;
- suggested next review lane;
- whether git, heartbeat, or subagent delegation is ready.
