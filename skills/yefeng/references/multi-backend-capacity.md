# 野蜂 Multi-Backend Capacity

Read this reference before changing CLI backend policy, MCP defaults, or parallel-role limits.

## Backend Equivalence Boundary

Codex CLI and Claude Code CLI are equivalent only as session transports: both can launch, emit a session ID, resume, stream output, and produce terminal evidence. They are not sandbox-equivalent.

- Codex governed read-only: `codex exec --ignore-user-config --json ... -s read-only`.
- Claude governed read-only: `claude -p --output-format stream-json --permission-mode plan --safe-mode --mcp-config <empty-json> --strict-mcp-config`.
- `--safe-mode` disables Claude customizations such as hooks and plugins. It does not create an OS filesystem sandbox.
- `acceptEdits` is a permission grant, not an OS exact-path sandbox. Use it only after the operator delegates `workspace-write`, bind the role to a dedicated worktree and intended paths, and audit the resulting diff.
- Permission delegation is backend-neutral: requested authority must not exceed the recorded operator ceiling. Use `plan` for read-only, `acceptEdits` for Claude workspace writes, and `bypassPermissions` only for explicitly delegated danger-full-access.

## MCP Policy

Use `minimal` by default: no external MCP servers in background roles.

Keep optional MCP definitions disabled globally unless a current task needs them. Enable capability per role only after recording why it is required and how its process and authority are bounded. Browser, documentation, and reasoning MCPs should not be inherited by every role.

For Codex, ignore user MCP config for governed runs. For Claude, use `--safe-mode`, an explicit empty MCP configuration, and `--strict-mcp-config`.

## Capacity Model

Record:

- physical cores and logical processors;
- total and currently available memory;
- normal dispatch target and hard top-level cap;
- per-backend caps;
- CPU-heavy, database, and browser/Electron semaphores;
- green, yellow, and red thresholds.

For the validated Windows host with 8 physical cores, 16 logical processors, and 61.7GB RAM:

| Limit | Value |
| --- | ---: |
| Normal top-level target | 6 |
| Hard top-level cap | 8 |
| Codex cap | 4 |
| Claude cap | 4 |
| CPU-heavy | 2 |
| Database integration | 2 |
| Browser/Electron | 1 |

Capacity thresholds:

- green requires at least 16GB available memory and no red signal;
- yellow begins below 16GB or at rolling CPU at/above 75%;
- red begins below 10GB or at rolling CPU at/above 90%;
- red refuses new dispatch; yellow reduces to a conservative target.

These values are a validated machine profile, not a universal default. Recompute when hardware, workload, container limits, or host behavior changes.

## Dispatch Transaction

One cross-process mutex covers:

1. tracked assignment resolution;
2. active-run census;
3. capacity and backend semaphore checks;
4. worker start;
5. run record creation.

The active census is fail closed:

- validate full completion binding and terminal schema before excluding a run;
- accept verified terminal evidence from historical epochs without counting it;
- reject historical non-terminal evidence until reconciled;
- reject corrupt JSON, changed PID identity, path escape, and mismatched epoch/scope.

## Evidence And Review

Every promoted runner needs:

- commit-bound parser, contract, governance, cleanup, and validator receipts;
- real parallel launch and resume for every supported backend;
- session reuse, marker, completion, control HEAD, script hash, and clean-worktree evidence;
- an independent exact-revision review with literal `review passed`.

Do not promote exploratory output or a pre-commit test run as final evidence.
