---
name: yefeng
description: Use 野蜂 when a large project should be advanced by one total-control Codex thread that assigns roles, launches or resumes background Codex sessions, routes recorded communication, delegates subagents, reviews evidence, and integrates work through governed checkpoints. Also use when starting a new large project that needs a phased governance bootstrap before full parallel role execution.
---

# 野蜂

野蜂 is a governed multi-Codex work system. The user talks to one total-control thread. That total-control thread assigns roles, starts and resumes background Codex role sessions, routes recorded communication, manages worktrees and branches, decides when blockers are cleared, and integrates reviewed work.

Do not preserve the older self-claiming workflow. A top-level role session never claims a role by itself. It only accepts an explicit assignment from the total-control thread and verifies that the assignment exists in the project state.

## Startup Mode Selection

When a user asks to start, initialize, organize, or improve a large project, do not default directly to full parallel 野蜂. First classify the project into a startup level and record that decision.

Use these levels:

- `LEVEL_0_DISCUSS`: goals, architecture, task shape, or authorization are still unclear. Discuss, read local docs, and complete a startup intake or task template. Do not create governance files unless the user asks.
- `LEVEL_1_GOVERNANCE_BOOTSTRAP`: the project is ready for durable coordination, but implementation tracks are not independent yet. Create or update governance docs, role pool proposals, task registry, and state skeletons. Keep roles `PLANNED`. Do not launch background Codex sessions, create role worktrees, merge branches, or start a heartbeat.
- `LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL`: the first implementation slice is dependency-heavy and should be advanced by the total-control thread directly while maintaining governance state. Do not launch parallel top-level roles unless the user explicitly authorizes an upgrade.
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

## Core Commitments

- The user interacts with the total-control thread by default.
- The total-control thread is the only dispatcher for top-level roles.
- Roles are assigned, not claimed.
- Role sessions may communicate by writing recorded messages, but only the total-control thread may wake, resume, stop, replace, or reassign another top-level role.
- Every top-level implementation role uses its own worktree and branch unless the total-control thread records a narrower read-only/document-only exception.
- Role sessions may deploy worker and reviewer subagents inside their assigned scope.
- Subagents do not own top-level 野蜂 roles and must report back to the role session that spawned them.
- Cross-role facts, blockers, decisions, and evidence must be written to files. Hidden chat state is not governance.
- Merge happens at the smallest verifiable integration point, not after every tiny action and not after unreviewed half-work.
- The communication bus is dual-layer: machine-readable events plus human-readable views.

## Default Project Shape

Create or maintain these files when a project uses 野蜂. Use local naming conventions if the repo already has equivalent docs, but migrate old self-claiming role docs into assignment semantics.

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

Default `.gitignore` entries for 野蜂 projects should include:

```text
.yefeng/runs/
.yefeng/assignment.json
.yefeng/outbox/
```

The shared `.yefeng/events.jsonl`, `.yefeng/state/*.json`, and human-readable docs should remain trackable. Per-run assignment manifests and role-local outbox files are runtime transport. If a project wants assignment manifests versioned for audit, copy a compact assignment summary into `.yefeng/state/runs.json` or another tracked state file instead of merging `.yefeng/assignment.json` from a role worktree.

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
- whether every implementation role should use a worktree/branch, default yes;
- what operations still require the user: secrets, external accounts, publication, destructive cleanup outside scope, or authority expansion.

If the user indicates personal, long-term, architecture-sensitive, or not time-constrained work, choose final architecture first unless the user explicitly asks for a fast MVP.

## Authority

The total-control thread owns orchestration by default:

- create, update, and stop role assignments;
- launch `codex exec` role sessions;
- resume role sessions by session ID;
- create per-role worktrees and branches;
- write the machine state, event log, role communication views, task registry, handoff reports, and control directives;
- route cross-role messages;
- decide whether a blocker condition is satisfied;
- request or dispatch reviewer subagents when authorized;
- merge reviewed role branches at verifiable integration points;
- notify or resume affected roles after integration.

Still require user confirmation for:

- expanding the authorization policy itself;
- real secrets, external accounts, paid services, publication, cloud writes, or release actions;
- destructive cleanup outside the recorded worktree/branch/run directories;
- continuing despite a required reviewer failure;
- conflicts that the recorded policy and total-control docs cannot adjudicate.

Do not use `--dangerously-bypass-approvals-and-sandbox` for launched role sessions unless the authorization policy explicitly allows it for the project.

## Total-Control Execution Turns

A total-control turn is executable by default, including prompts described as "check", "poll", "巡检", "resume", "continue", heartbeat, or automation. Those words mean inspect state and perform any authorized control action now. They do not mean read-only.

Treat a total-control turn as read-only only when the user or automation prompt explicitly says `read-only`, `dry-run`, `no launch`, `do not start`, `do not resume`, `do not merge`, or when policy, evidence, capacity, conflict, or missing authority blocks execution.

When the snapshot, task registry, or total-control document lists next safe total-control actions, treat them as a prioritized execution queue, not suggestions. A total-control turn is a drain loop, not a single-action tick. After every state-changing control action, recompute authoritative state and continue with the next authorized, unblocked, capacity-allowed action before final reporting. State-changing control actions include run completion processing, outbox import, blocker ruling, resume, launch, merge, baseline refresh, stable governance commit, and worktree cleanup.

If no higher-priority completed run, outbox import, blocker ruling, resume, or merge consumes the current loop iteration and capacity remains, execute the first unblocked queue item. That can mean assigning a role, launching a role session, resuming a cleared role, integrating a merge-ready branch, or writing the concrete blocker that prevents execution. Then loop again. Independent launches may be batched up to the recorded parallelism limit; they should not be split across future heartbeats merely because one launch or merge already happened in the current turn.

Repeatedly reporting "next action is X" while X is authorized, unblocked, and within the recorded parallelism limit is a 野蜂 failure. If execution is impossible, record the reason with `blocked_by`, `resume_when`, `required_evidence`, and `wake_target` instead of merely naming the future action.

It is valid to wait for the next heartbeat only after the drain loop reaches quiescence. Quiescence means one of these is true:

- no executable work remains after checking completed runs, outbox messages, merge-ready branches, ready-to-resume blockers, active directives, dirty stable governance files, and the prioritized queue;
- remaining work is blocked by authorization, missing evidence, dependency order, conflict, or an explicit user decision;
- max parallel capacity is filled by active role sessions and the remaining queue depends on those sessions or would exceed safe parallelism;
- a role was just launched or resumed and no independent safe action remains;
- the total-control turn is hitting a practical time budget, in which case record exactly what remains executable and why it was deferred.

Do not use the heartbeat cadence as a batch boundary. A closeout that says "the next heartbeat will assign X" while X can be assigned safely now is incomplete.

## Total-Control Heartbeat Lifecycle

A total-control heartbeat is long-lived project infrastructure. Its job is to keep the total-control thread alive enough to notice new work, cleared blockers, finished role runs, user replies, and stale state. An idle heartbeat is a valid `IDLE_OK` result, not a reason to stop.

Heartbeat cadence is a wakeup interval, not a work quantum. Each heartbeat must run the total-control drain loop until quiescence before waiting for the next cadence. The 20-minute wait, or any other cadence, begins only after all currently executable work has been completed, blocked with evidence, or delegated into running role sessions that fill the useful capacity.

Do not delete, pause, or disable the total-control heartbeat merely because:

- no role sessions are currently running;
- the next queue is empty;
- all currently known checkpoints are complete;
- the turn would otherwise be an empty poll;
- you want to avoid idle loops or "空转".

Only stop or delete a total-control heartbeat when the user explicitly asks to stop, pause, delete, turn off, archive, or end the 野蜂 control loop, or when a recorded authorization policy requires shutdown and that policy was approved by the user. A completed checkpoint, clean working tree, or empty task queue is not enough.

When a heartbeat finds no executable work, it should:

1. verify there are no running roles, pending outbox messages, merge-ready branches, ready-to-resume blockers, active directives, or dirty stable governance files;
2. refresh the status snapshot only if facts changed;
3. report `IDLE_OK`, the facts checked, and what would wake new work;
4. leave the heartbeat active at the existing cadence unless the user explicitly changes it.

Do not create no-op commits just to prove the heartbeat ran. Do not call automation delete/update-to-paused as part of normal total-control closeout.

## Role Assignment

`docs/角色分配.md` is the human-readable assignment board. `.yefeng/state/roles.json` is the script-readable assignment state. Keep them in sync whenever the total-control thread changes role ownership or status.

The authoritative assignment state lives in the total-control workspace. A role worktree usually contains only the committed baseline copy of `.yefeng/state/roles.json`, so it may be stale at launch time. Before starting a role, total-control must write a per-run assignment manifest, preferably:

- in the total-control run directory: `.yefeng/runs/<role_id>/<run_id>/assignment.json`;
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

Use `codex exec` as the default backend for background role sessions. The total-control thread may create helper scripts such as:

- `scripts/yefeng/start.ps1`
- `scripts/yefeng/launch-role.ps1`
- `scripts/yefeng/resume-role.ps1`
- `scripts/yefeng/poll.ps1`

Prefer commands shaped like:

```powershell
Get-Content -LiteralPath <prompt-file> -Raw |
  codex exec --json --skip-git-repo-check -C <role-worktree> -s <sandbox-mode> -o <control-root>\.yefeng\runs\<role_id>\<run_id>\last-message.md -
```

Resume only when a session ID is known:

```powershell
codex exec resume <session_id> "<resume prompt>"
```

In current Codex CLI, `codex exec resume` may not accept `-C`. Run the resume command with the process current directory set to the role's assigned worktree. If total-control resumes from the control root, the resumed role may correctly refuse to write because its sandbox writable root no longer matches its assignment. Always create the run log directory before launching a resume command so stdout/stderr redirection cannot fail before Codex starts.

Do not pass interactive-only flags to `codex exec`. In particular, verify flags against `codex exec --help`; `-a/--ask-for-approval` may be accepted by interactive Codex but not by `codex exec`.

Record stdout JSONL, stderr, process ID, run ID, last message path, prompt path, assignment manifest path, sandbox mode, started time, ended time, exit code, and discovered session ID under `.yefeng/runs/<role_id>/<run_id>/`.

When `--json` is enabled, parse the first `thread.started` event and use its `thread_id` as the resumable session ID. Prefer JSON parsing over regex extraction. If no `thread.started` event appears, mark the run as non-resumable until proven otherwise.

If a reliable session ID cannot be found, do not use broad `--last` in a shared Codex home. Either relaunch the role from recorded project state or isolate the role's `CODEX_HOME` so `--last` is unambiguous.

When launching background helper processes on Windows, use `Start-Process` with `-WindowStyle Hidden` unless the user explicitly wants visible terminals. Prefer `pwsh` for helper scripts. If scripts must run under Windows PowerShell 5.1, keep script source ASCII-only or save it with a BOM; UTF-8-without-BOM scripts containing Chinese here-strings can fail before execution.

Before writing launch/resume helper scripts on Windows, resolve the Codex CLI to an explicit command path and verify it. Prefer a working `codex.cmd` or npm shim over the WindowsApps `codex.exe` app alias; the alias can appear in `Get-Command codex` but fail with access denied inside background helper processes. Use the resolved command via `& $codexCommand exec ...` instead of bare `codex`, and record `codex_command` in run metadata. If a helper reports access denied for `WindowsApps\codex.exe`, treat it as a command-resolution failure, fix the launcher, and retry the role from the recorded assignment.

```powershell
$codexCommand = $null
$cmdCandidates = @(
  (Get-Command codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
  (Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { $_ }

foreach ($candidate in $cmdCandidates) {
  if ($candidate -like '*\WindowsApps\codex.exe') { continue }
  try {
    & $candidate --version > $null
    $codexCommand = $candidate
    break
  } catch {}
}

if (-not $codexCommand) {
  throw 'No usable Codex CLI command found; WindowsApps codex.exe app alias is not sufficient for background role launch.'
}
```

For Windows projects with non-ASCII paths, filenames, or governance docs, put a UTF-8 prelude at the top of generated launch/resume helper scripts before `Get-Content`, `codex exec`, or log parsing:

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$env:PYTHONIOENCODING = 'utf-8'
try { chcp.com 65001 > $null } catch {}
```

Prefer explicit authoritative paths from prompts, assignment manifests, and docs over paths recovered from garbled console listings. If JSONL or stderr shows mojibake for Chinese file names, fix the launch script encoding and rerun a small probe before relying on that output for routing, blockers, or merges.

Sandbox choice is part of the run record. On Windows, `-s workspace-write` may prevent spawned role sessions from using shell commands in some environments. If that happens and the authorization policy permits it, use a dedicated role worktree plus `-s danger-full-access` for that role run instead of using approval bypass flags. Record the reason and keep the write scope constrained by prompt, worktree, branch, and review gates.

Before launching the first implementation role on Windows, total-control should run a tiny sandbox probe in a disposable directory:

1. `codex exec --json -s workspace-write` with a prompt that asks the role to run a simple shell command such as printing the current directory.
2. If the JSONL or final message shows `CreateProcessAsUserW failed: 5`, mark `workspace-write-shell=false` in `.yefeng/state/runs.json` or the status snapshot.
3. For role sessions that need tests, builds, git commands, dependency inspection, or other shell work, launch them with `-s danger-full-access` inside their dedicated worktree, not in the project root.
4. Keep read-only or document-only role sessions on the stricter sandbox when they do not need shell commands.

This is a workaround for the Windows sandbox process-launch layer, not a relaxation of 野蜂 governance. The effective safety boundary becomes the dedicated worktree, narrow prompt scope, ignored runtime transport files, reviewer gate, and total-control integration review.

App-server or remote-control tooling can be explored as an implementation backend, but 野蜂 must not depend on experimental desktop-thread visibility. Background CLI sessions are sufficient.

## Worktrees And Integration

Every top-level implementation role should have its own worktree and branch. Use conservative names such as:

```text
worktrees/<role_id>
codex/yefeng/<role_id>/<checkpoint-or-date>
```

Document-only planning roles may share the main workspace only when the total-control thread records that their write scopes do not conflict.

Role sessions work toward the smallest verifiable integration point:

1. implement or update the assigned scope;
2. run focused validation;
3. deploy a reviewer subagent when required;
4. fix reviewer findings and re-review when needed;
5. write a handoff report or role result;
6. mark the checkpoint `MERGE_READY` only when evidence exists;
7. wait for total-control integration or continue a safe same-role task if one exists.

The total-control thread integrates:

1. inspect role diff and evidence;
2. verify reviewer conclusion exists when required;
3. check communication bus for unresolved blockers;
4. remove or exclude runtime transport files such as `.yefeng/assignment.json` and `.yefeng/outbox/**` from the role branch unless explicitly archived;
5. merge or rebase the role branch into the integration line;
6. run integration validation;
7. write stable facts to the registry and total-control doc;
8. emit a `BASELINE_UPDATED` event;
9. commit the stable governance updates (`.yefeng/state/**`, `.yefeng/events.jsonl`, task registry, assignment board, route views, directives, handoffs, and status snapshot) unless the project policy explicitly says those files are not versioned;
10. update affected role worktrees with the new baseline, then resume from each role's own worktree if they need to continue.

Do not merge unreviewed half-work merely to keep other roles current. Do not hold a complete reviewed unit indefinitely when it is already safe to integrate.

After an integration checkpoint, a total-control closeout is not complete while stable governance files remain dirty. Either commit those stable facts, or record a concrete blocker explaining why they must stay uncommitted. Ignore runtime transport files only when they are intentionally gitignored or outside the versioned governance surface.

When writing governance update scripts, prefer data structures and templates that are safe to rerun:

- PowerShell `ConvertFrom-Json` returns `PSCustomObject`; assigning a property that does not already exist can fail. For fields that may be new, update an `[ordered]` hashtable before serialization, or use `Add-Member -Force` / `.PSObject.Properties.Remove(...)` plus `Add-Member` deliberately.
- After rewriting `.yefeng/state/*.json`, read the JSON back and verify required fields such as `state`, `session_id`, `exit_code`, `role_commit`, `merge_commit`, and `codex_command` before committing.
- For Markdown governance views, avoid double-quoted PowerShell here-strings that contain Markdown backticks or `$()` text. Prefer single-quoted here-strings with explicit placeholders such as `__ROLE_COMMIT__`, then replace placeholders with concrete values.
- Read generated Markdown views back before commit and check that no unresolved placeholders or accidental script fragments remain, such as `__PLACEHOLDER__`, `$sessionId`, `$roleCommit`, or `$(`.
- Run `git diff --check` and `git status --short` after staging stable governance files. A clean final status is evidence; a dirty stable governance file is a blocker, not a pass.

## Communication Bus

All cross-role communication goes through the recorded bus.

Shared machine-readable source in the total-control workspace:

- `.yefeng/events.jsonl`
- `.yefeng/messages/<message_id>.json`

Human-readable views:

- `docs/角色通信/README.md`
- `docs/角色通信/<role_id>.inbox.md`
- `docs/角色通信/<role_id>.outbox.md`
- `docs/角色通信/总控路由.md`

A role may write a message event addressed to another role or to total-control. It may not resume the target role. Total-control routes the message and decides whether to:

- answer directly;
- append the message to a target inbox without waking the target;
- resume the target role with the message;
- convert the message into a blocker;
- create or update a control directive;
- ask the user.

For implementation roles running in separate worktrees, prefer a local outbox:

- role writes `.yefeng/outbox/<message_id>.json` inside its worktree;
- total-control imports that outbox into the shared `.yefeng/events.jsonl` and human-readable route views;
- total-control marks imported messages as routed, blocking, closed, or ready to wake a target role.

After import, do not merge role-local `.yefeng/outbox/` files into the integration branch unless the project explicitly archives transport messages in git. The durable record is the imported event line and route view. This avoids re-importing stale transport files later.

This avoids concurrent writes to the shared event log and prevents worktree-local copies of shared state from becoming false authority. Direct writes to the shared bus are allowed only when total-control explicitly grants a shared writable directory and serialization/locking is handled.

Use these message types:

- `QUESTION`
- `ANSWER`
- `BLOCKER`
- `CONTRACT_CHANGE`
- `REVIEW_REQUEST`
- `REVIEW_RESULT`
- `HANDOFF`
- `BASELINE_UPDATED`
- `RESUME_NOTICE`
- `USER_DECISION_REQUIRED`
- `DIRECTIVE`

Every blocking message must include:

- `blocking: true`
- `blocked_role`
- `blocked_checkpoint`
- `blocked_by`
- `resume_when`
- `required_evidence`
- `wake_target`

The total-control thread is responsible for closing routed messages after the stable fact has been written to the registry, directive board, total-control doc, or role assignment state.

## Control Directives

`docs/总控指令.md` is the downward instruction channel from total-control to role sessions.

Use a directive when:

- a role needs a conflict ruling;
- a cross-role contract changed;
- a blocker is cleared but the role must resume in a specific way;
- a role must stop, rebase, repair, or re-run validation;
- a reviewer gate or merge gate failed and a concrete repair path exists.

Directives do not replace authorization or reviewer gates. They tell a role what to do next and what evidence is required.

## Status Snapshot

`docs/总控状态快照.md` is a short startup map for the total-control thread and role sessions. It should include:

- last updated time and updater;
- current planning stance;
- active total-control session;
- role assignment summary;
- running, blocked, ready-to-resume, merge-ready, and done roles;
- open messages and blocking messages;
- active directives;
- unprocessed handoff reports;
- latest integration baseline;
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

An assigned role prompt must state:

- this role was assigned by total-control;
- the role must not self-claim or reassign roles;
- role ID, assignment ID, run ID, assignment manifest path, and session metadata if known;
- working directory, worktree, and branch;
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
4. route messages;
5. detect blockers that are cleared;
6. resume roles whose conditions are satisfied;
7. launch or resume every safe role that fits remaining capacity, including unblocked items in the next safe total-control action queue;
8. integrate merge-ready work with evidence;
9. update docs and machine state;
10. refresh the status snapshot;
11. commit stable governance updates or record the blocker that prevents committing them;
12. verify the working tree is clean except for intentionally untracked/ignored runtime transport or unrelated user changes;
13. tell the user what changed and what is still blocked.

After processing run results, messages, blockers, resumes, merges, and stable governance commits, restart the loop from the snapshot/authoritative state. Do not end with only a recommendation if an authorized queue item remains executable. Perform it, or write the concrete blocker that prevents it. If authorized work is ready, do it in this turn; the next heartbeat is only for new facts, running-role completions, or work that is genuinely blocked now.

## Running A Role Session

When the prompt assigns a top-level role:

1. verify the assignment from the prompt and per-run assignment manifest; treat worktree-local `docs/角色分配.md` or `.yefeng/state/roles.json` as possibly stale unless total-control says the worktree was refreshed after assignment;
2. read authorization, total-control doc, task registry, directives, communication inbox, relevant proposal, and recent events;
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
- Do not write governance JSON with scripts that fail when a new field is needed; use rerunnable property update helpers.
- Do not commit Markdown governance views with unresolved placeholders or broken inline code formatting.
- Do not delete, pause, or disable the total-control heartbeat because the project is temporarily idle.
- Do not keep processed handoff reports as permanent state.
- Do not use the communication bus as a substitute for total-control directives when a decision is required.
- Do not edit outside a role's allowed scope.
- Do not leave dead process/session records marked `RUNNING`.
- Do not continue after a policy-expanding decision without user approval.

## Expected Closeout

When finishing a 野蜂 step, report:

- role sessions launched, resumed, blocked, replaced, or completed;
- worktrees/branches created or integrated;
- messages routed and blockers cleared;
- directives opened, applied, closed, or still active;
- reviewer/validation evidence that changed state;
- machine state and human docs updated;
- status snapshot refreshed;
- stable governance changes committed, or the exact blocker preventing that commit;
- working-tree cleanliness for the project-owned integration surface;
- heartbeat remains active, or the explicit user-approved reason it was stopped;
- unresolved user decisions;
- next total-control action.

Use `references/templates.md` for concrete document skeletons and prompt patterns.
