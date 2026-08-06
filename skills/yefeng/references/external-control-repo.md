# 野蜂 External Git Control Repository

Use this reference when `control_plane_mode=external-git`: operational governance lives in an independent Git repository while product repositories remain authoritative for code, specifications, public contracts, and tests.

## Contents

- When to choose this mode
- Truth and authority boundaries
- Required identities and path resolution
- Recommended repository shape
- Machine state and namespace rules
- Communication transport
- Cross-repository integration protocol
- Discovery and assignment
- Startup bootstrap
- Recovery, archive, and security
- Validation checklist

## When To Choose This Mode

Prefer `external-git` when one or more are true:

- several modules or conversations advance concurrently;
- the product main worktree is frequently dirty or reserved for integration;
- an existing embedded `.yefeng` state belongs to another series;
- high-frequency operational history should not pollute product Git;
- the user wants private/local coordination while product history remains product-focused;
- one control plane coordinates more than one product repository.

Use `embedded` for a small single-repository effort where product and control writes do not contend. Preserve existing embedded projects unless migration is explicitly authorized.

A plain unversioned external directory is runtime transport, not durable governance. A long-lived communication worktree is an allowed fallback only when explicitly recorded; worktrees remain execution containers and must not be the only durable evidence store.

## Truth And Authority Boundaries

The control repository owns execution and governance truth:

- active objective, scope, and non-goals;
- roles, claims, leases, and `run_epoch`;
- task registry, queue, budget, blockers, and directives;
- routed messages, handoffs, validation/review indexes, and run evidence;
- exact product repository and worktree identities used by an execution.

Each product repository owns product truth:

- product code and tests;
- OpenSpec or equivalent normative specifications;
- public contracts, stable architecture decisions, migrations, and release facts;
- product branch, merge, package, and runtime evidence.

A `CONTRACT_CHANGE` in the control repository is a request until the reviewed product change lands in the authoritative product repository. Link to the product path and exact commit; do not maintain a competing normative copy in the control repository.

An assignment manifest, role report, or outbox message is likewise not authoritative merely because it exists. Total-control must reconcile it against the current epoch, lease, expected control HEAD, product commit, and actual runtime state before importing it into tracked governance.

Resolve conflicts in this order:

1. actual product/control Git, filesystem, process, API, and runtime state;
2. machine-readable control state;
3. exact-revision evidence manifests;
4. active human registry and status snapshot;
5. control/product Git history and archive;
6. conversation or worker self-report.

## Required Identities And Path Resolution

Record:

```text
control_plane_mode: external-git
control_repo_id: <stable logical id>
control_root: <absolute local path, stored only in local/runtime state>
scope_id: <series or module namespace>
product_repo_id: <stable logical id>
product_root: <absolute local path, stored only in local/runtime state>
product_integration_branch: <branch>
product_worktree: <absolute assigned worktree>
product_baseline_commit: <exact commit>
transport_mode: control-spool | worktree-local
```

Tracked state should prefer stable repo IDs and repository-relative paths. Store machine-local absolute roots in ignored `.yefeng/local/roots.json` and per-run assignment manifests. Never derive roots from the current directory.

Path rules:

- governance-relative `docs/**` and `.yefeng/**` resolve under `control_root`;
- product files resolve under the named product repository or assigned worktree;
- run logs resolve under the control root;
- `codex exec` and resume run from the assigned product worktree;
- every Git command uses `git -C <explicit-root>`;
- cleanup targets must resolve under a recorded run root or worktree root.
- retention targets require a complete structured run binding and resolve only to an allowed leaf under the exact recorded `run_root`.

## Recommended Repository Shape

```text
<control-root>/
├─ AGENTS.md
├─ README.md
├─ docs/
│  ├─ authorization.md
│  ├─ total-control.md
│  ├─ status.md
│  ├─ roles.md
│  ├─ directives.md
│  ├─ shared/
│  │  ├─ integration-queue.md
│  │  ├─ contract-change-requests/
│  │  └─ decisions/
│  └─ modules/<scope_id>/
│     ├─ charter.md
│     ├─ plan.md
│     ├─ registry.md
│     ├─ budget.md
│     ├─ decisions/
│     └─ handoffs/
├─ .yefeng/
│  ├─ control-plane.json
│  ├─ local/roots.json                 # ignored
│  ├─ series/<scope_id>/
│  │  ├─ state/control.json
│  │  ├─ state/roles.json
│  │  ├─ state/runs.json
│  │  ├─ state/transport.json
│  │  ├─ events.jsonl
│  │  └─ messages/
│  ├─ runs/<scope_id>/<role>/<run>/    # ignored
│  ├─ outbox/<scope_id>/<role>/<run>/  # ignored
│  ├─ broker/<scope_id>/                # ignored runtime journal/projections/guard
│  └─ quarantine/<scope_id>/           # ignored
├─ scripts/yefeng/                      # tracked writer and validation helpers
└─ archive/
```

Keep the current human status view short: about 100–120 lines, no more than two or three active WIP items, and no more than five closed items. Move closed detail to the archive and retain index pointers.

Recommended control-repository ignore rules:

```gitignore
.runtime/
.yefeng/local/
.yefeng/runs/
.yefeng/outbox/
.yefeng/broker/
.yefeng/quarantine/
.yefeng/assignment.json
```

Keep ignore rules scoped to the named runtime directories. Do not use repository-wide suffix rules such as `*.log`, `*.pid`, or `*.tmp`; those can silently hide a stable governance file in a tracked namespace. Do not ignore tracked plans, registries, routed events, state snapshots, decisions, or compact handoffs.

## Machine State And Namespace Rules

Use schema version 2 or later for external mode. `.yefeng/control-plane.json` records stable topology without machine-local roots:

```json
{
  "version": 2,
  "control_plane_mode": "external-git",
  "control_repo_id": "project-control",
  "locator_mode": "prompt-required",
  "default_transport_mode": "control-spool",
  "active_scopes": ["delivery-series"],
  "shared_writer": {
    "scope_id": "delivery-series",
    "role_id": "INTEGRATOR"
  },
  "product_repositories": [
    {
      "repo_id": "product-main",
      "integration_branch": "main",
      "product_truth": true
    }
  ]
}
```

The ignored `.yefeng/local/roots.json` resolves IDs on the current machine:

```json
{
  "version": 1,
  "control_root": "D:/project-control",
  "product_roots": {
    "product-main": "D:/product"
  }
}
```

Each scope has its own role table, run table, event log, and message namespace. Legacy embedded state without a namespace remains compatible through the `SKILL.md` read adapter as in-memory `scope_id=default`; do not auto-migrate it or apply external-mode schema requirements retroactively.

Every external-mode role, run, event, assignment, review, and handoff must include enough identity to prevent cross-scope confusion:

```text
scope_id
run_epoch
role_id
assignment_id
run_id
operation_id (for any cross-repository or external side effect)
control_repo_id
product_repo_id + product_baseline_commit + product_branch
or a complete product_baselines map for scope-wide lifecycle events
product_worktree (runtime manifest)
transport_mode
```

New run records additionally carry `run_root`, `retention_group_id`, `parent_run_id`, `review_gate`, and `control_disposition`. They are optional for read compatibility with existing repositories, but a run missing any one of them is ineligible for evidence compaction. Validate complete bindings when present; never infer missing values from a physical runtime directory.

Each scope has one total-control owner. Only the global integrator writes `docs/shared/**` and any global index. Module total-control threads request shared changes through `CONTRACT_CHANGE`; they do not edit another scope or the shared integration queue directly unless assigned serialized write authority.

Choose scope granularity by authority and recovery boundary, not by folder count. Keep tightly coupled modules that share one objective, contract graph, approval gate, budget, and total-control writer in one umbrella scope. Split a new scope only when it can own an independent objective, queue, epoch, budget, and writer lease without direct writes into another scope. Unrelated long-lived series must not accumulate inside one permanent umbrella scope; they coordinate through the global integrator and shared contract-change queue.

The first bootstrap creates one scope and records its `INTEGRATOR` as the shared writer. Adding a later scope is itself a fenced tracked control change: acquire the current shared-writer fence, materialize a new namespaced module/state skeleton, assign a distinct epoch/writer/fence/outbox, update `active_scopes`, validate, publish one control commit, and release the fence. Do not rerun the repository initializer over any existing control-root path.

Tracked control state has a single-writer fence, not merely a social convention. Before a tracked write, total-control uses `scripts/enter-control-write.ps1` to acquire the repository-wide local commit lock, then verifies the repository-global expected control HEAD plus the selected scope's tracked writer identity, epoch, and local lease. The global lock and global HEAD fence serialize commits from every scope; a scope-specific lock or per-scope expected HEAD is incorrect because all scopes share one Git HEAD. If any check differs, stop and reconcile. Stage an explicit allowlist, inspect the staged diff, and publish exactly one coherent control commit, then use `scripts/exit-control-write.ps1` to verify the parent/CAS relation, advance the global HEAD fence, and release the scope lease. Git's transient `index.lock` is not a governance lease and must not be treated as one.

The fence record must be sufficient to reject a stale writer after takeover. Keep stable writer identity and epoch in tracked scope state; keep the raw local lock token and machine/process details in ignored runtime state. A tracked recovery event binds to that token only through `recovery_lock_sha256`; never copy the raw token into Git history. A takeover increments the epoch before new assignments are issued, expires active roles and runs without rewriting their original epoch, and moves only identity-free `PLANNED` role slots to the new epoch.

Do not store the control repository's own current HEAD inside a file whose commit would change that HEAD. Read the actual control HEAD at runtime and include the previous or reviewed control commit in later events and handoffs when needed.

## Communication Transport

Support two transport modes:

- `control-spool`: role writes to an ignored role/run-specific spool under the external control root when sandbox permissions allow it;
- `worktree-local`: role writes to its assigned product worktree's ignored `.yefeng/outbox/`, and total-control imports it.

The assignment manifest gives the exact writable `outbox_dir` and readable `inbox_dir`; the role must not guess. A role writes only its own `<scope>/<role>/<run>` directory. At Level 3, the bundled single-writer broker owns `.yefeng/broker/<scope_id>/` and serializes `control-spool` delivery; use `publish-role-message.ps1` and `receive-role-message.ps1` instead of editing runtime projections. The broker does not support `worktree-local` in version 1, so total-control imports that fallback explicitly. See `integration-and-transport.md` for the protocol, replay behavior, and timing rules.

If a sandbox cannot write the external spool, fall back to `worktree-local`. Do not broaden the role's write authority merely for communication. Shared tracked event logs always have one writer: total-control.

Handoffs use the same transport boundary. A role may produce a compact handoff in its run directory or outbox; total-control imports stable conclusions into tracked control docs. Product worktrees should not accumulate control-only handoff documents.

## Cross-Repository Integration Protocol

Git cannot atomically commit two independent repositories. Never claim otherwise. Use a recoverable operation ledger. Every operation has a stable `operation_id` and advances monotonically through `PREPARED`, `PRODUCT_COMMITTED`, `PRODUCT_VERIFIED`, and `CONTROL_COMMITTED`; failure or cancellation appends a terminal reconciliation record instead of rewriting history.

1. Reconcile actual product and control state.
2. Commit an `INTEGRATION_INTENT`/`PREPARED` record in the control repository with `operation_id`, `scope_id`, product repo ID, expected product base and target HEAD, reviewed candidate commit, target branch, validation/review evidence, and intended operation.
3. Re-read the actual product target HEAD. Abort on drift; do not merge against an unexpected base. Otherwise merge or fast-forward the reviewed candidate in the explicit product repository.
4. Run required integration validation and capture the actual product merge commit.
5. Record the observed product commit and verification result, then commit `BASELINE_UPDATED` plus roles/runs/registry changes in the control repository, referencing the old and new product commits and closing the operation as `CONTROL_COMMITTED`.
6. Refresh dependent worktrees and resume roles only after the closing control commit succeeds.

If interrupted:

- inspect actual product Git first;
- if product integration did not occur, close or retry the intent only after revalidation;
- if product integration occurred but control state did not update, write `RECONCILIATION_REQUIRED`, then idempotently record the actual merge commit and close the intent;
- do not undo valid product history merely to simulate cross-repository atomicity.

The same intent-before-effect rule applies to other externally visible side effects: launching or resuming a role, waking a scheduler, creating or deleting a worktree, publishing, and destructive cleanup. Record intent and the expected epoch/state first, perform the effect once, then record the observed result. Recovery checks the external state before retrying, using `operation_id` for idempotency.

Unrelated dirty files in the product repository do not prevent committing independent control facts. They may still block a product merge when Git reports overlap or local authority forbids merging into a dirty integration worktree. Report control and product Git cleanliness separately.

## Discovery And Assignment

Every launched role prompt and assignment manifest must contain absolute resolved roots and stable IDs. At minimum:

```json
{
  "control_plane_mode": "external-git",
  "control_repo_id": "project-control",
  "control_root": "D:/project-control",
  "scope_id": "delivery-series",
  "run_epoch": 3,
  "role_id": "COORD-D",
  "assignment_id": "assign-YYYYMMDD-HHMMSS-COORD-D",
  "run_id": "run-YYYYMMDD-HHMMSS-COORD-D",
  "product_repo_id": "product-main",
  "product_root": "D:/product",
  "product_worktree": "D:/product/.worktrees/<task>",
  "product_branch": "codex/<task>",
  "product_baseline_commit": "<sha>",
  "transport_mode": "control-spool",
  "outbox_dir": "D:/project-control/.yefeng/outbox/delivery-series/COORD-D/run-YYYYMMDD-HHMMSS-COORD-D",
  "inbox_dir": "D:/project-control/.yefeng/broker/delivery-series/inbox/COORD-D"
}
```

For new conversations, prefer a small stable pointer or AGENTS hook in the product repository that identifies the control repository logically. Keep dynamic status out of that pointer. If the user permits zero tracked-file changes but accepts local repository metadata, bind stable IDs and the local control root through product-repository-local Git config and still include the resolved roots in every launch prompt. If the user requires zero product-repository mutation, do not touch `.git/config`; use `prompt-required` discovery, set `GIT_OPTIONAL_LOCKS=0` for product Git probes so status inspection does not refresh index metadata, and record the reduced portability as an accepted constraint. Never guess a writable control repository merely because a sibling directory has a familiar name.

On a new machine, discovery is explicit: clone or restore the control repository, recreate ignored root bindings, verify repo IDs and baselines, and only then dispatch. Absolute paths are machine-local locators, never cross-machine identity.

## Startup Bootstrap

Prefer the bundled `scripts/init-external-control-repo.ps1`, which transactionally materializes `assets/external-control-repo/` through a sibling staging directory, initializes Git, resolves the exact registered product branch ref and baseline, copies versioned writer/validator helpers into `<control-root>/scripts/yefeng/`, and can bind the product repository through local Git config without changing tracked product files. When local Git binding is selected, all binding keys are written before the final control-root publication; a failure restores every previous value and leaves no published control root. It rejects an already-existing target, UNC/mapped/SUBST roots, and any reparse point in the product, target-parent, asset, staging, or cleanup path chain. Use direct ordinary local paths. Template rendering is context-aware: JSON strings, Markdown prose, table cells, and code spans use different encoders so visible repository identities round-trip exactly. Use the copied validator before the first commit. After the reviewed bootstrap commit, call the copied `enter-control-write.ps1` and `exit-control-write.ps1` once without a tracked change to bind the ignored local fence to the actual bootstrap HEAD, then validate with `-RequireCommitted`; this zero-change release is accepted only when `enter` recorded the bootstrap-only `bootstrap_head_binding` lock state from an unbound Level 1/epoch 1 repository. Every later writer release requires exactly one direct-child control commit. Add `-RequireProductBinding` when local Git binding was selected.

```powershell
& <skill-root>\scripts\init-external-control-repo.ps1 `
  -ControlRoot <control-root> -ProductRoot <product-root> `
  -ProjectName <name> -ProjectId <id> -ScopeId <scope-id> `
  -BindProductGitConfig
```

At `LEVEL_1_GOVERNANCE_BOOTSTRAP`:

1. verify the requested control root does not exist, traverses no reparse point, and is outside every product repository;
2. initialize an independent Git repository with a default branch;
3. create the tracked topology, authorization, total-control, status, module, shared, archive, and machine-state skeletons;
4. create ignored local root mapping and runtime transport directories, including the per-scope broker root;
5. read product Git status and exact baseline without modifying product files;
6. create scopes with roles in `PLANNED`, `run_epoch=1`, and no active claims;
7. validate JSON, path containment, ignore rules, Git tracking, product/control identity, and startup level;
8. commit the control bootstrap atomically;
9. optionally add a reviewed stable pointer to the product repository through its normal Git workflow;
10. install and validate broker helpers, but do not start the broker, launch roles, create product implementation worktrees, enable heartbeats, or merge product branches at Level 1.

Remote creation, pushing, cloud backup, or publication remains an external write and requires the applicable user authorization.

## Recovery, Archive, And Security

- Never store secrets, API keys, provider credentials, or unredacted sensitive command lines in the control repository.
- Treat ignored run logs as local evidence; promote only compact, redacted conclusions.
- Compact ignored run logs only with `scripts/yefeng/compact-run-evidence.ps1` and the governed protocol in `run-evidence-retention.md`. Default to dry-run. Apply requires a clean control repository whose current single-parent HEAD uniquely commits the matching `RUN_EVIDENCE_RETENTION_PREPARED` event directly over the plan baseline; the event binds policy/token/candidates/references and runs/roles/control/transport state hashes. An `APPLIED` commit promotes the bounded receipt afterward. If the actual run directory cannot be matched to complete structured state, leave it untouched.
- Bind validations and reviews to exact product commits.
- Model scope lifecycle explicitly as `ACTIVE`, `PAUSING`, `PAUSED`, `RECOVERING`, or `ARCHIVED`. During `PAUSING`, stop new dispatch, collect role state, invalidate leases, and increment `run_epoch`; only then publish `PAUSED`. Resume through `RECOVERING`, reconciling repositories, processes, worktrees, open operations, and transport receipts before returning to `ACTIVE`.
- Increment `run_epoch` on pause, handoff, cancellation, or takeover, and reject messages from earlier epochs.
- A leftover writer lock is not safe to delete merely because its timestamp expired. Enter `RECOVERING`; after explicit acknowledgement, `scripts/yefeng/recover-control-write.ps1` serializes lock lifecycle operations through the persistent physical file guard `.yefeng/local/locks/control-repo.lifecycle.guard`, requires both lease expiry and a non-authoritative exact PID/start-time identity on the same machine, accepts only the locked HEAD or one direct child, and treats the global lock as authoritative even when a crash left the local fence in its pre-entry or post-exit empty shape. Each local/global mirror file is replaced atomically, but the collection is not described as a multi-file atomic transaction. Unless a lock-bound recovery transition commit already landed, recovery conservatively marks `recovery_required`; the next enter must use `-RecoveryTransition`, then `prepare-control-writer-takeover.ps1` verifies the physical lifecycle guard and HEAD/content CAS identities, expires old-epoch roles and runs, and creates a reviewed epoch/writer event bound to the local token by SHA-256 only. The event carries the complete product baseline map for the scope rather than guessing one product. Publish that diff as exactly one reviewed commit and exit with the replacement fields. UNC, mapped-drive, SUBST, reparse-point, process, local-state-shape, or repository-state ambiguity must stop as blocked.
- Archive closed cycles immediately; do not let the active registry become permanent history.
- Archive with a manifest that records the final control commit, product commits, open/closed operation IDs, retained evidence, and ignored runtime material intentionally discarded. `ARCHIVED` scopes do not dispatch until explicitly reopened with a new epoch.
- Back up the independent control Git repository if the user wants cross-machine recovery; do not silently publish it.
- On recovery, verify actual control HEAD, product HEADs, worktrees, processes, open integration intents, and current epoch before dispatch.
- Keep a product commit or patch as durable implementation evidence; never rely on a worktree or control message alone.
- Git history can recover tracked governance, but not ignored logs, local roots, live processes, uncommitted worktrees, credentials, or unpublished product commits. State these disaster-recovery limits plainly; never claim the control repository alone is a complete backup.

## Validation Checklist

- [ ] Existing embedded projects continue without migration.
- [ ] `control_plane_mode`, `control_repo_id`, and `scope_id` are explicit.
- [ ] Product and control truth ownership are distinct.
- [ ] Tracked state contains repo IDs; ignored local state resolves absolute roots.
- [ ] Every registered product baseline resolves from its exact local integration-branch ref, not the current checkout, and every mapped product repository is validated.
- [ ] Product/control/staging/cleanup path chains contain no reparse point and neither repository is nested in the other.
- [ ] Every scope has isolated roles, runs, events, messages, and transport.
- [ ] `.yefeng/broker/` is ignored, untracked, and owned only by one exact verified broker instance per active Level 3 scope.
- [ ] Assignment manifests bind exact outbox and inbox paths; roles cannot write the broker journal or projections.
- [ ] Broker start, publish, receive, replay repair, quarantine, status, and cooperative stop probes pass before parallel dispatch.
- [ ] Shared control state has one writer.
- [ ] One repository-wide commit lock and expected-control-HEAD fence plus scope writer identity, lease, and epoch fence concurrent and stale writers.
- [ ] Crash recovery accepts only documented local-fence shapes, requires expired lease plus dead exact process identity, and converges through a reviewed epoch/writer transition.
- [ ] Role assignments include exact product/control roots and commits.
- [ ] Sandbox failure falls back to worktree-local outbox without broader authority.
- [ ] Outbox import is validated, idempotent, and receipted before cleanup.
- [ ] Product merge and control update use operation IDs, expected product HEAD, and intent/close reconciliation.
- [ ] Other external side effects are intent-before-effect and recoverable.
- [ ] Control and product Git statuses are reported separately.
- [ ] Product repository remains unchanged during Level 1 unless a pointer change is separately authorized.
- [ ] Runtime logs, local roots, outboxes, broker state, quarantine payloads, and assignments are ignored.
- [ ] New run rows carry complete structured retention bindings; legacy rows remain readable and retention-protected.
- [ ] Evidence compaction defaults to dry-run, protects every active/review/recovery/reference gate, deletes exact allowed leaves only, and produces a receipt no larger than 64 KiB.
- [ ] Retention helpers are installed from the exact five-file hash manifest; partial or tampered installations fail validation.
- [ ] Tracked plans, state, events, decisions, and compact handoffs are committed.
- [ ] Pause/resume follows the explicit lifecycle and increments the epoch.
- [ ] Archive manifests and disaster-recovery limits are recorded.
