# 野蜂 Governed Process Backend

Read this reference completely before probing, launching, resuming, polling, or cleaning background CLI roles.

## Roots And Authority

Resolve every path from authoritative state:

- `control_root`: embedded product root or independent control Git repository;
- `product_root`: authoritative product repository;
- `role_worktree`: assigned product worktree;
- `assignment_path`: tracked manifest under
  `<control_root>/.yefeng/series/<scope_id>/state/assignments`;
- `control_run_root`:
  `<control_root>/.yefeng/runs/<scope_id>/<role_id>/<run_id>`.

Use `git -C <explicit-root>` for Git. Never infer a sibling control repository, product root, or cleanup root from the current directory.

The assignment manifest binds version, mode, action, scope, epoch, assignment ID, role ID, backend, sandbox, workload class, worktree, prompt path/hash, write declarations, outbox, lease, and backend acknowledgements. It must be tracked at a clean control HEAD before dispatch.

Scope, assignment, role, and run IDs are path-free identifiers. Reject separators, colons, `.`/`..`, trailing dots, and Windows device aliases such as `CON`, `NUL`, `COM1`, and `LPT1`.

## Supported Envelope

The validated envelope supports:

- `codex` launch/resume in read-only mode;
- `claude` launch/resume in `plan + --safe-mode`;
- empty external MCP profile;
- tracked Level 2 conformance assignments;
- capacity-aware parallel transport;
- terminal completion, polling, resume, and exact cleanup.

Level 3 authority is delegated by the operator. Record `operator_permission_ceiling`; require the requested mode to be at or below it. Prefer `workspace-write` in a dedicated worktree with explicit relative paths and post-run diff review. Use `danger-full-access` only when explicitly delegated and technically necessary; it cannot claim an exact path allowlist.

## Minimal MCP

Governed roles do not inherit optional MCP servers.

Codex:

```text
codex exec --ignore-user-config --json --skip-git-repo-check ...
```

Claude:

```text
claude -p --output-format stream-json --verbose \
  --permission-mode plan --safe-mode \
  --mcp-config <empty-mcp.json> --strict-mcp-config ...
```

For an operator-authorized Claude write role, map `workspace-write` to
`--permission-mode acceptEdits`; map explicitly delegated `danger-full-access` to
`--permission-mode bypassPermissions`. Keep the empty strict MCP profile unless the assignment
separately authorizes MCP capability. Record `claude_write_boundary_acknowledged=true` and reject
any out-of-scope diff before review or integration.

`--safe-mode` disables hooks, plugins, skills, project instructions, and other customizations. It still is not an OS filesystem sandbox. Record that distinction.

## Dispatch Transaction

One named cross-process mutex must cover:

1. assignment resolution and tracked-clean verification;
2. fail-closed active-run census;
3. capacity, backend cap, and workload semaphore checks;
4. launch-envelope creation;
5. worker start;
6. run-record creation.

The launch envelope is mutable filesystem data, so pass its SHA-256 as an independent structured process argument. The worker reads the bytes once, validates that hash, strictly decodes UTF-8, and only then parses JSON.

The prompt is also read once as bytes. Hash, strict UTF-8 decode, and execution must use those same bytes.

Version 3 run and completion records bind:

- control HEAD;
- runner, worker, common-library, and policy hashes;
- launch-spec hash;
- assignment and prompt hashes;
- scope, epoch, assignment, role, backend, session, PID, process start time;
- worktree, sandbox, workload, MCP profile, and all artifact paths.

## Launch And Resume

Resolve a usable CLI command by executing `--version`; do not trust a WindowsApps alias that cannot run.

Codex launch uses `codex exec`; resume uses `codex exec resume` from the assigned worktree with an explicit `sandbox_mode="read-only"` override. Parse the `thread.started` event to obtain the session ID.

Claude launch creates an explicit UUID and uses `--session-id`; resume uses `--resume <session-id>`. Normalize the terminal `result` event into the run's last-message file.

Never resume from `--last` in a shared home. Resume only a completed parent whose session, backend, role, worktree, sandbox, workload, scope, and epoch match the new tracked resume assignment. Refuse when another active run owns the same backend session.

## Terminal Evidence

A completion file is not terminal merely because it exists.

Validate:

- matching supported version;
- every scalar and path binding;
- version 3 provenance hashes;
- `status` in `completed|failed`;
- integer `exit_code`;
- `completed` iff exit code is zero, `failed` iff nonzero;
- parseable `started_at` and `ended_at`, with end not before start.

Poll, resume, active census, and cleanup all use the same terminal validator.

Historical terminal runs may remain as immutable evidence and do not count in the current epoch. A historical non-terminal run blocks dispatch until reconciled.

## PID-Safe Cleanup

PID existence is never identity.

1. Read the root CIM identity.
2. Verify recorded start time and exact command fragments.
3. Acquire and retain a `System.Diagnostics.Process` handle for the root before descendant census.
4. Verify all captured descendant handles against the same census.
5. Tree-kill the retained root first so it cannot spawn new children.
6. Stop held descendants still alive.
7. Repeat descendant census to convergence.
8. Dispose every retained handle.

Tests and finalizers follow the same rule. Do not check `HasExited` and then call `Stop-Process -Id`; use the retained `Process` object or the exact-identity cleanup primitive.

Never kill generic Node, PowerShell, Codex Desktop, Claude, Electron, or MCP processes. For host-level cleanup, match exact known MCP command roots and act only with explicit authority.

## Windows Encoding And Process Start

Use structured argument arrays, not shell-concatenated strings. Start background helpers hidden unless the user requests a visible terminal. Redirect worker stdout/stderr to explicit files so the launcher can return without holding caller streams open.

Set UTF-8 console and pipeline encodings in worker scripts. Treat malformed UTF-8 in assignment, launch, or prompt bytes as a hard failure.

## Required Promotion Evidence

Before copying runner policy into this skill:

- run PowerShell parsing;
- run contract and governance tests repeatedly;
- run dynamic process-tree cleanup;
- run the control-repository validator;
- launch Codex and Claude concurrently from a disposable clean Git repository;
- resume both exact sessions;
- prove terminal binding, expected markers, active census zero, targeted cleanup, and clean lab;
- persist a commit-bound receipt with hashes;
- obtain fresh independent exact review with literal `review passed`.
