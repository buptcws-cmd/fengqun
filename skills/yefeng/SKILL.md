---
name: yefeng
description: Use 野蜂 when a large or multi-module project needs one total-control thread to bootstrap governance, assign roles across Codex CLI and Claude Code CLI, run or resume governed background sessions, route recorded communication, review evidence, and integrate checkpoints. Use it for embedded coordination and for independent external Git control repositories that keep operational state separate from authoritative product repositories.
---

# 野蜂

野蜂 is a governed multi-backend agent work system. The user talks to one total-control thread. That total-control thread assigns roles, starts and resumes governed Codex CLI or Claude Code CLI sessions, routes recorded communication, manages worktrees and branches, decides when blockers are cleared, and integrates reviewed work.

Do not preserve the older self-claiming workflow. A top-level role session never claims a role by itself. It only accepts an explicit assignment from the total-control thread and verifies that the assignment exists in the project state.

## Startup Mode Selection

When a user asks to start, initialize, organize, or improve a large project, do not default directly to full parallel 野蜂. First classify the project into a startup level and record that decision.

Use these levels:

- `LEVEL_0_DISCUSS`: goals, architecture, task shape, or authorization are still unclear. Discuss, read local docs, and complete a startup intake or task template. Do not create governance files unless the user asks.
- `LEVEL_1_GOVERNANCE_BOOTSTRAP`: the project is ready for durable coordination, but implementation tracks are not independent yet. Create or update governance docs, role pool proposals, task registry, and state skeletons. Keep roles `PLANNED`. Do not launch background CLI sessions, create role worktrees, merge branches, or start a heartbeat.
- `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL`: the first implementation slice is dependency-heavy and should be advanced by the total-control thread directly while maintaining governance state. Do not launch top-level roles while this level remains recorded; user authorization becomes effective only after recording the upgrade to Level 3.
- `LEVEL_3_FULL_PARALLEL_YEFENG`: multiple independent implementation tracks exist and the user has authorized full orchestration. Assign roles, create worktrees/branches, launch or resume role sessions, route communication, require reviewers, and integrate work.

Only enter `LEVEL_3_FULL_PARALLEL_YEFENG` when all are true:

1. the user has authorized 野蜂 execution, not just discussion;
2. maximum parallel top-level role count is recorded;
3. role scopes are independent enough to avoid constant contract churn;
4. governance docs and machine state exist or can be created now;
5. worktree/branch policy is recorded;
6. secrets, external accounts, paid services, publication, and destructive operations remain gated by authorization policy.

For early projects, governance layer does not always mean full background-role infrastructure. Create a lightweight governance bootstrap first and defer role launches until implementation tracks are independent.

For startup-specific templates and prompts, read `references/startup.md`. For full governance skeletons and launch/resume prompt patterns, read `references/templates.md`.

## Backend And Capacity Policy

Treat Codex CLI and Claude Code CLI as interchangeable transports only at the orchestration layer. Their permission implementations differ, but both receive authority by explicit delegation from the operator.

- Every launch comes from a tracked assignment manifest bound to control HEAD, scope, epoch, assignment, role, backend, worktree, prompt hash, sandbox mode, workload class, and lease when applicable.
- Default to the `minimal` MCP profile. Codex uses `--ignore-user-config`; Claude uses `--safe-mode`, an empty `mcpServers` file, and `--strict-mcp-config`.
- Codex read-only uses the Codex sandbox. Claude read-only uses `plan + --safe-mode + strict empty MCP`; do not represent it as an OS filesystem sandbox.
- Record an `operator_permission_ceiling` for every write-capable assignment. A role's requested mode must be less than or equal to that ceiling: `read-only < workspace-write < danger-full-access`.
- The operator may delegate `workspace-write` or `danger-full-access` when their current authority permits it. Prefer the least authority that completes the task. For `workspace-write`, bind one dedicated worktree, explicit relative paths, no role-side commit/merge, and a total-control post-run diff review. For Claude, record `claude_write_boundary_acknowledged=true` because `acceptEdits` is a permission grant rather than an OS path sandbox.
- Determine capacity from the current machine and live load, not a fixed folklore number. Record a normal target, hard cap, backend caps, and workload semaphores; refuse new dispatch in red state.
- For the validated 8-core/16-thread, 61.7GB Windows host, use normal target `6`, hard cap `8`, Codex `4`, Claude `4`, CPU-heavy `2`, database integration `2`, and browser/Electron `1`. Recompute for other machines.

Read `references/multi-backend-capacity.md` completely before setting backend policy, changing MCP defaults, or selecting machine parallelism.

## Control Plane Placement

Choose and record one topology during `LEVEL_0_DISCUSS` or `LEVEL_1_GOVERNANCE_BOOTSTRAP`:

- `embedded`: governance, machine state, and product files share one Git repository. Preserve this mode for existing projects unless migration is explicitly authorized.
- `external-git`: an independent Git control repository owns execution/governance state while one or more product repositories own product code, specifications, public contracts, tests, and releases.

Prefer `external-git` for concurrent modules, frequently dirty product main worktrees, an existing embedded `.yefeng` owned by another series, private operational history, or multi-repository coordination. A plain external folder is runtime transport, not durable governance. A long-lived communication worktree is a fallback, not the default durable control plane.

External mode records `control_plane_mode`, `control_repo_id`, `scope_id`, product repo IDs, integration branches, transport mode, and root-resolution policy. New embedded state should use `scope_id=default`; existing embedded state follows the read-compatibility rule below instead of being rewritten to satisfy the external schema. Relative governance paths resolve against `control_root`; product paths resolve against the named product repository or assigned product worktree. Store machine-local absolute roots in ignored local state and per-run assignments, not as logical identity.

For `external-git`, read `references/external-control-repo.md` completely before bootstrap, dispatch, resume, integration, pause/recovery, or closeout. That reference overrides embedded path examples in `references/templates.md`.

## Core Commitments

- The user interacts with the total-control thread by default.
- The total-control thread is the only dispatcher for top-level roles, regardless of CLI backend.
- Roles are assigned, not claimed.
- Role sessions may communicate by writing recorded messages, but only the total-control thread may wake, resume, stop, replace, or reassign another top-level role.
- Every top-level implementation role uses its own worktree and branch unless the total-control thread records a narrower read-only/document-only exception.
- Role sessions may deploy worker and reviewer subagents inside their assigned scope.
- Subagents do not own top-level 野蜂 roles and must report back to the role session that spawned them.
- Cross-role facts, blockers, decisions, and evidence must be written to files. Hidden chat state is not governance.
- Merge happens at the smallest verifiable integration point, not after every tiny action and not after unreviewed half-work.
- The communication bus is dual-layer: machine-readable events plus human-readable views.
- Shared tracked control state has one commit writer at a time. Enforce it with one repository-wide commit lock and expected-HEAD fence plus scope writer identity, lease, and monotonic `run_epoch`; Git's `index.lock` alone is not a semantic fence.
- Roles treat outbox and logs as untrusted transport. Total-control validates identity and epoch, imports idempotently, and commits an event plus receipt before cleanup.
- Product and control repositories are authoritative only for their own domains. A control-repository contract request becomes product truth only after the reviewed product change lands.

## Default Project Shape

Create or maintain these files under `control_root` when a project uses 野蜂. In embedded mode, `control_root` is the product root. Use local naming conventions if equivalent docs already exist, but migrate old self-claiming role docs into assignment semantics.

- `docs/项目总览.md`
- `docs/野蜂总控.md` or the repo's existing total-control document
- `docs/授权策略.md`
- `docs/角色分配.md`
- `docs/并行任务登记.md`
- `docs/总控指令.md`
- `docs/总控状态快照.md`
- `docs/角色通信/README.md`
- `docs/交接报告/README.md`
- `.yefeng/state/roles.json`
- `.yefeng/state/runs.json`
- `.yefeng/events.jsonl`
- `.yefeng/messages/`
- `.yefeng/runs/`

Runtime-heavy run logs under `.yefeng/runs/` should normally be ignored by git. Commit durable state, summaries, event lines, and handoff reports; keep full stdout/stderr/prompt logs as local evidence unless the project explicitly wants them versioned.

External mode namespaces durable and runtime state by `scope_id`, for example `.yefeng/series/<scope_id>/...`, `.yefeng/runs/<scope_id>/...`, and `.yefeng/outbox/<scope_id>/...`. Legacy unnamespaced embedded state remains valid: normalize an absent `scope_id` to `default` only in memory, never write it back or invent a missing epoch/identity merely for compatibility. Verify an existing run with the exact role, assignment, and run identity it actually records; ambiguity blocks resume. Every new or replacement assignment created after adoption receives a complete manifest without rewriting older tracked records.

Process lifecycle is part of governance, not an afterthought. A role is not closed out merely because its branch is merged or its final message was read. Total-control must close completed app subagents, audit launched CLI process trees, and check the process budget before adding more background capacity when process counts are high. Cleanup must match more than PID: Windows can reuse PIDs, so obtain and retain a verified root process handle before descendant census, terminate the root tree before convergence census, and verify command line, start time, run directory, runner path, and bound evidence. Never kill generic Codex Desktop, Claude, Electron, MCP, PowerShell, or Node processes merely because they are numerous; map exact command roots to a closed run or rely on explicit host-level cleanup authority.

Default `.gitignore` entries for 野蜂 projects should include:

```text
.yefeng/runs/
.yefeng/assignment.json
.yefeng/outbox/
```

The shared `.yefeng/events.jsonl`, `.yefeng/state/*.json`, and human-readable docs should remain trackable. Per-run assignment manifests and role-local outbox files are runtime transport. If a project wants assignment manifests versioned for audit, copy a compact assignment summary into `.yefeng/state/runs.json` or another tracked state file instead of merging `.yefeng/assignment.json` from a role worktree.

Apply these ignore rules to the control repository in external mode. Do not modify a product repository's `.gitignore` merely to host control runtime data; use a role-local ignored transport only when the product repository already permits it or the product change is separately authorized.

When upgrading an existing yefeng project:

1. Convert any legacy self-claiming role document into `docs/角色分配.md`.
2. Replace self-claiming language with total-control assignment language.
3. Remove prompts that tell a new thread to choose an open role.
4. Add session IDs, process/run IDs, worktree paths, branch names, blocker fields, and resume conditions to role state.
5. Add the communication bus and require all cross-role questions to be recorded.

## Intake

When the user asks to start or improve a large project, read local docs and code first. Ask only for missing decisions that materially affect safety or cost. Prefer defaults when the user has already granted broad automation authority.

Clarify only what is needed:

- desired end state and non-goals;
- whether the work is personal, research, client, production, or public;
- planning stance: final architecture first, MVP iteration, research exploration, or repair series;
- maximum parallel top-level role sessions;
- model/reasoning tier policy for total-control, role sessions, workers, and reviewers;
- whether git should be initialized now;
- control-plane topology: `embedded` or `external-git`;
- stable control/product repo IDs, scope IDs, integration branches, and local root binding;
- whether the product repository may contain a small stable control-plane locator, or launches must always provide the control root;
- transport mode and the sandbox capabilities required to read/write both roots;
- whether every implementation role should use a worktree/branch, default yes;
- what operations still require the user: secrets, external accounts, publication, destructive cleanup outside scope, or authority expansion.

If the user indicates personal, long-term, architecture-sensitive, or not time-constrained work, choose final architecture first unless the user explicitly asks for a fast MVP.

## Authority

The total-control thread owns orchestration by default:

- create, update, and stop role assignments;
- launch governed Codex CLI or Claude Code CLI role sessions;
- resume role sessions by session ID;
- create per-role worktrees and branches;
- write the machine state, event log, role communication views, task registry, handoff reports, and control directives;
- route cross-role messages;
- decide whether a blocker condition is satisfied;
- request or dispatch reviewer subagents when authorized;
- merge reviewed role branches at verifiable integration points;
- notify or resume affected roles after integration.

In external mode, total-control is the only tracked-state writer in the control repository. Product repository writes still obey that repository's authority, branch, review, and merge rules. A module total-control thread may write only its assigned scope; only the global integrator writes shared control indexes and cross-module queues.

Still require user confirmation for:

- expanding the authorization policy itself;
- real secrets, external accounts, paid services, publication, cloud writes, or release actions;
- destructive cleanup outside the recorded worktree/branch/run directories;
- continuing despite a required reviewer failure;
- conflicts that the recorded policy and total-control docs cannot adjudicate.

Do not use `--dangerously-bypass-approvals-and-sandbox` for launched role sessions unless the authorization policy explicitly allows it for the project.

## Total-Control Operations

For total-control checks, polls, continuation, heartbeat, integration, or closeout, read and follow `references/total-control-operations.md` completely. A total-control turn remains executable by default and drains every startup-level-authorized, unblocked, capacity-allowed action to quiescence. In external mode, reconcile and report control and product repositories separately.

## Role Assignment

`docs/角色分配.md` is the human-readable assignment board. `.yefeng/state/roles.json`, or the namespaced external equivalent, is the script-readable assignment state. Resolve both under `control_root` and keep them in sync whenever total-control changes role ownership or status.

The authoritative assignment state lives under `control_root`. An embedded role worktree may contain only a stale committed copy; an external-mode product worktree may contain no governance copy at all. Before starting a role, total-control must write a per-run assignment manifest under the control run root and optionally copy a runtime-only manifest into the product worktree.

- in the total-control run directory: `.yefeng/runs/<scope_id>/<role_id>/<run_id>/assignment.json` in namespaced mode, or the legacy unnamespaced path in compatible embedded mode;
- and in the role worktree when useful: `.yefeng/assignment.json`.

The launched role verifies the assignment manifest and prompt metadata. It should not fail merely because the committed role table inside its worktree still says `PLANNED`; it should report that discrepancy to total-control and avoid editing shared state directly.

A role row should record:

- `role_id`
- `role_name`
- `assigned_by`
- `assignment_id`
- `session_id`
- `process_id`
- `run_id`
- `state`
- `worktree`
- `branch`
- `owned_scope`
- `forbidden_scope`
- `current_checkpoint`
- `blocked_by`
- `resume_when`
- `required_evidence`
- `wake_target`
- `last_seen`
- `lease_expires_at`
- `last_output`

External-mode role and run state also records `scope_id`, `run_epoch`, `control_repo_id`, `product_repo_id`, product baseline commit, product branch/worktree, and transport mode. Reject identity or epoch mismatches instead of guessing.

Use these role states:

- `PLANNED`: role exists but has not been assigned.
- `ASSIGNED`: total-control has assigned the role but no active run is underway.
- `RUNNING`: a role session process is active.
- `WAITING_REVIEW`: role is waiting for its own reviewer result.
- `BLOCKED`: role cannot continue until a recorded condition is satisfied.
- `READY_TO_RESUME`: total-control has determined the blocker is cleared.
- `REPORT_READY`: role has delivered evidence or handoff and has no immediately safe continuation.
- `MERGE_READY`: role branch has required evidence and can be integrated by total-control.
- `DONE`: role's current scope is complete.
- `FAILED`: process failed or produced invalid output.
- `EXPIRED`: lease passed or the process is dead and total-control may replace the role session.

A role session must not:

- assign itself a role;
- change its own role identity;
- take a second top-level role;
- wake or resume another top-level role;
- edit another role's worktree or branch;
- edit total-control state except through fields explicitly assigned to that role;
- treat a private chat answer as cross-role authority.

## Process Backend

Before launching, resuming, polling, or cleaning up background CLI roles, read and follow `references/process-backend.md` completely. It defines explicit control/product/worktree roots, tracked assignments, minimal MCP envelopes, terminal evidence, epoch-safe census, PID-safe cleanup, Windows command/encoding rules, and backend-specific sandbox limits. Never infer roots from the current directory or widen authority merely to write an external control repository.

## Worktrees, Integration, And Communication

Before creating product worktrees, integrating branches, importing outboxes, or changing cross-role communication state, read and follow `references/integration-and-transport.md` completely. For external mode, also apply the cross-repository protocol in `references/external-control-repo.md`.

## Control Directives

`docs/总控指令.md` under `control_root` is the downward instruction channel from total-control to role sessions.

Use a directive when:

- a role needs a conflict ruling;
- a cross-role contract changed;
- a blocker is cleared but the role must resume in a specific way;
- a role must stop, rebase, repair, or re-run validation;
- a reviewer gate or merge gate failed and a concrete repair path exists.

Directives do not replace authorization or reviewer gates. They tell a role what to do next and what evidence is required.

## Status Snapshot

`docs/总控状态快照.md` under `control_root` is a short startup map for total-control and role sessions. It should include:

- last updated time and updater;
- current planning stance;
- active total-control session;
- role assignment summary;
- running, blocked, ready-to-resume, merge-ready, and done roles;
- open messages and blocking messages;
- active directives;
- unprocessed handoff reports;
- latest integration baseline;
- exact control HEAD plus product repo IDs, branches, and baseline commits;
- open cross-repository intents or reconciliation work;
- next safe total-control action queue, as prioritized executable work rather than suggestions;
- docs that must be read before changing state.

The snapshot is not an approval source. If it conflicts with role assignment, registry, directives, event log, reviewer evidence, or authorization policy, trust the authoritative source and refresh the snapshot.

## Launching Role Sessions

Before launching roles, total-control should:

1. read authorization, role assignment, task registry, directives, status snapshot, and event log tail;
2. choose the next safe set of roles within max parallelism;
3. create worktrees and branches for implementation roles;
4. write assignment state;
5. create role prompts;
6. start role sessions;
7. record run metadata;
8. add `ROLE_ASSIGNED` and `ROLE_STARTED` events;
9. report a concise launch summary to the user.

Use a governed runner instead of ad hoc shell strings. The runner must serialize census/capacity/start/run-record creation, validate path-free identifiers, pass arguments structurally, bind the launch envelope by an independently supplied SHA-256, hash and decode the exact prompt bytes it executes, and record a versioned run/completion pair containing control HEAD and runner hashes. A completion file is terminal only after schema, binding, status, integer exit code, and time ordering pass.

An assigned role prompt must state:

- this role was assigned by total-control;
- the role must not self-claim or reassign roles;
- role ID, assignment ID, run ID, assignment manifest path, and session metadata if known;
- working directory, worktree, and branch;
- control-plane mode, control root/repo ID, scope ID, product root/repo ID, and exact product baseline;
- allowed and forbidden write scopes;
- current checkpoint;
- files to read first;
- communication bus rules, including whether the role writes local outbox or shared bus;
- blocker reporting format;
- subagent delegation allowance and reviewer requirement;
- expected final output and handoff path.

## Resuming Role Sessions

Total-control resumes a role when:

- `resume_when` is satisfied;
- a routed message requires the role's answer;
- a directive targets the role;
- baseline changed and the role must rebase/pull;
- reviewer output arrived;
- the user instructs total-control to continue work.

Before resuming:

1. verify the role is still assigned to the recorded session;
2. ensure no newer run is active for the same role;
3. read relevant events, messages, directives, and registry rows;
4. update state to `READY_TO_RESUME`;
5. send a concise resume prompt with the exact reason and required next output.

For external mode, resume from the assigned product worktree while reading authority and state from the control root. Reconcile control HEAD, product HEAD, current epoch, incomplete intents, live processes, and transport before resuming. Never resume from `status.md` alone.

If the previous session is not resumable, total-control may replace it by assigning a new session and recording the previous one as `EXPIRED` or `FAILED`.

## Subagents

Role sessions may deploy subagents for bounded work:

- workers for implementation, exploration, focused docs, tests, or validation;
- reviewers for proposal, implementation, integration-risk, or contract checks.

Rules:

- A role session owns its subagents and integrates their output.
- Subagents must stay inside the role's assigned scope.
- A reviewer must be independent from the worker or author it reviews.
- A failed review leads to repair and re-review unless the failure needs a missing dependency, cross-role decision, policy expansion, or user decision.
- Do not preserve long transcripts in governance docs. Keep minimal conclusions: reviewer, scope, verdict, required fixes, re-review status, and unlock/block effect.
- Use only lifecycle operations exposed by the current collaboration host. After a terminal subagent result is consumed, record the verdict or handoff and stop scheduling it. If the host exposes explicit close/dispose, use it; otherwise terminal state is sufficient. Re-engage an idle agent only through the host's supported follow-up mechanism, and interrupt only a still-running agent that is no longer needed.
- If many host-managed Codex Desktop, Electron, MCP, or Node processes remain after app subagents are closed, do not blindly kill them from 野蜂. First map them to a known closed role/subagent or record a host-level cleanup issue, reduce further app-subagent fanout, and ask for explicit host-level cleanup authority when a generic kill would disrupt active tools or other conversations.

Risk tier guidance:

- highest: total-control integration, architecture, authorization, security, merge decisions, hard root-cause debugging;
- high: shared implementation, migrations, editor/version/AI logic, nontrivial refactors, key reviewers;
- medium: bounded implementation, tests, local validation, focused docs;
- economy: mechanical search, formatting, inventory, low-risk summaries.

When unsure, choose the higher tier.

## Governance Before Implementation

Do not start implementation before the 野蜂 governance layer exists unless the user explicitly asks for a one-off change.

At minimum, create:

- total-control doc;
- authorization policy;
- role assignment board;
- task registry;
- communication bus;
- directive board;
- handoff inbox;
- status snapshot when repeated startup would otherwise be expensive.

External mode additionally requires an independent control Git repository, topology manifest, ignored local root binding, per-scope namespace, writer-fencing policy, and cross-repository recovery protocol. At Level 1, create these with every role still `PLANNED`; do not launch roles, create product implementation worktrees, start a heartbeat, or merge product/role branches. General automation authority cannot override the recorded startup level.

Every proposal should include:

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

Keep proposals conservative. A proposal is `DRAFT` until it has been reviewed under the authorization policy.

## Running Total-Control

When acting as the total-control thread, run the following as a loop until quiescence rather than as a one-pass checklist:

1. read the status snapshot first when present;
2. read authorization, role assignment, task registry, directives, communication route view, event log tail, and unprocessed handoffs;
3. process completed role runs;
4. audit the process budget when counts are high, after resume, or before adding more background capacity;
5. audit and clean process trees for terminal runs when they can be matched by command-line evidence;
6. route messages;
7. detect blockers that are cleared;
8. resume roles whose conditions are satisfied;
9. when the recorded startup level permits role execution, launch or resume every safe role that fits remaining capacity, including unblocked items in the next safe total-control action queue;
10. integrate merge-ready work with evidence;
11. update docs and machine state;
12. refresh the status snapshot;
13. commit stable control updates with an explicit allowlist, or record the blocker that prevents committing them;
14. verify control Git and every affected product Git separately; preserve unrelated user changes;
15. tell the user what changed and what is still blocked.

After processing run results, messages, blockers, resumes, merges, and stable governance commits, restart the loop from the snapshot/authoritative state. Do not end with only a recommendation if a startup-level-authorized queue item remains executable. Perform it, or write the concrete blocker that prevents it. If authorized work is ready, do it in this turn; an existing authorized heartbeat is only for new facts, running-role completions, or work that is genuinely blocked now.

## Running A Role Session

When the prompt assigns a top-level role:

1. in external or new-format embedded mode, verify stable repo/scope IDs, current epoch, assignment, product baseline, and per-run manifest; for legacy embedded state, apply the read adapter above and verify every identity actually present, blocking ambiguous resume rather than synthesizing missing fields; in external mode do not expect governance files in the product worktree;
2. read authorization, total-control doc, task registry, directives, inbox, relevant proposal, and recent events from the recorded control root;
3. write only allowed role-local progress, handoff, and outbox files; shared state is updated by total-control unless the assignment explicitly grants a serialized shared state writer;
4. process active directives or messages for this role before new work;
5. deploy subagents when useful and allowed;
6. perform the assigned checkpoint inside the role's worktree/scope;
7. validate;
8. obtain reviewer evidence when required;
9. write handoff/report/message events;
10. finish with a concise state update for total-control.

If blocked, the role must write:

```text
blocked_by:
resume_when:
required_evidence:
wake_target:
safe_same_role_work_available: yes/no
```

If safe same-role work remains, the role may continue it. If not, it should report `BLOCKED` or `REPORT_READY` and stop.

## Guardrails

- Do not let a role session assign itself or another role.
- Do not let role sessions directly resume each other.
- Do not let a subagent become a top-level role owner.
- Do not merge without the required reviewer and validation evidence.
- Do not hide cross-role decisions in chat-only text.
- Do not let Markdown views and JSON state drift silently; reconcile before launching or resuming roles.
- Do not let two total-control writers rely on Git `index.lock`, independent per-scope locks, or per-scope HEAD copies; require one repository-wide commit lock and expected-HEAD fence plus the selected scope's lease and current epoch.
- Do not treat an outbox payload as authority before validated import and durable receipt.
- Do not write `MERGED` or `BASELINE_UPDATED` before the product commit exists and its ref/ancestry is verified.
- Do not infer or initialize a control repository from a guessed sibling path; verify explicit binding and control repo ID.
- Do not let a paused, handed-off, cancelled, or archived scope drain its old queue.
- Do not write governance JSON with scripts that fail when a new field is needed; use rerunnable property update helpers.
- Do not commit Markdown governance views with unresolved placeholders or broken inline code formatting.
- Do not delete, pause, or disable an existing startup-level-authorized total-control heartbeat merely because the project is temporarily idle.
- Do not keep processed handoff reports as permanent state.
- Do not use the communication bus as a substitute for total-control directives when a decision is required.
- Do not edit outside a role's allowed scope.
- Do not leave dead process/session records marked `RUNNING`.
- Do not keep dispatching work to a terminal app subagent after its result has been consumed; explicitly close it only when the current host exposes that capability.
- Do not leave safely matched terminal Codex CLI process trees alive after a role reaches `DONE`, `FAILED`, `EXIT_UNKNOWN`, or `EXPIRED`.
- Do not kill generic host-managed Codex Desktop, Electron, MCP, or Node processes without command-line evidence tying them to a closed role/subagent or explicit user authorization for host-level cleanup.
- Do not keep launching app subagents when process-budget audits show high duplicate host-managed MCP/Node command groups; throttle app-subagent fanout and prefer bounded CLI workers until the host recovers or the user authorizes host-level cleanup.
- Do not continue after a policy-expanding decision without user approval.
- Map Claude `workspace-write` to `acceptEdits` and `danger-full-access` to `bypassPermissions` only when the assignment records an adequate operator ceiling and explicit acknowledgement. Exact paths define intended scope and audit expectations; total-control must reject out-of-scope diff after the run. Never let a backend self-escalate beyond the recorded ceiling.

## Expected Closeout

When finishing a 野蜂 step, report:

- role sessions launched, resumed, blocked, replaced, or completed;
- worktrees/branches created or integrated;
- messages routed and blockers cleared;
- directives opened, applied, closed, or still active;
- reviewer/validation evidence that changed state;
- completed app subagents closed after result consumption;
- process cleanup audit result for terminal CLI runs, including dry-run/non-dry-run mode, matched PIDs stopped if any, and PID-reuse warnings;
- process-budget audit result when counts were high, including whether remaining processes were yefeng-attributable or host-managed;
- machine state and human docs updated;
- status snapshot refreshed;
- stable control changes committed, or the exact blocker preventing that commit;
- control-repository commit/cleanliness and each affected product repository commit/cleanliness separately;
- open integration intents, baseline drift, or reconciliation debt;
- an authorized heartbeat remains active, was not enabled at the current startup level, or has an explicit user-approved reason it was stopped;
- unresolved user decisions;
- next total-control action.

Use `references/templates.md` for concrete document skeletons and prompt patterns.
