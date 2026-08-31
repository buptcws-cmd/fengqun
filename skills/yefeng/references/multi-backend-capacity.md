# 野蜂 Multi-Backend Capacity

Read this reference before changing CLI backend policy, MCP defaults, or parallel-role limits.

## Backend Equivalence Boundary

Codex CLI and Claude Code CLI are equivalent only as session transports: both can launch, emit a session ID, resume, stream output, and produce terminal evidence. They are not sandbox-equivalent.

- Codex governed read-only: `codex exec --ignore-user-config --json ... -s read-only`.
- Codex governed workspace-write: the desktop-managed runtime currently resolves ordinary `-s workspace-write` and `--approve-for-me` sessions to an effective read-only `turn_context`. Use `--dangerously-bypass-approvals-and-sandbox` only after the assignment explicitly acknowledges Yefeng as the external fence; require a clean dedicated Git worktree, one declared write root, a repository-relative path allowlist, and a terminal diff audit that fails the run on any out-of-scope path.
- Claude governed read-only: `claude -p --output-format stream-json --permission-mode plan --safe-mode --mcp-config <empty-json> --strict-mcp-config`.
- Claude governed workspace-write: use `--permission-mode bypassPermissions` for non-interactive editing and test execution only after the same external-fence acknowledgement; still bind a clean dedicated worktree, declared write root, relative path allowlist, safe mode, and terminal diff audit.
- `--safe-mode` disables Claude customizations such as hooks and plugins. It does not create an OS filesystem sandbox.
- Both write-capable CLI mappings are unconfined executor permissions, not OS exact-path sandboxes. The assignment remains `workspace-write`; the acknowledged Yefeng worktree/path fence and terminal audit define the governed boundary.
- Permission delegation is backend-neutral: requested authority must not exceed the recorded operator ceiling. Use Codex `-s read-only` or Claude `plan` for read-only. Reject a separate `danger-full-access` assignment mode; the write-capable mappings above are allowed only for an explicitly delegated and externally fenced `workspace-write` role.

## MCP Policy

Use `minimal` by default: no external MCP servers in background roles.

Keep optional MCP definitions disabled globally unless a current task needs them. Enable capability per role only after recording why it is required and how its process and authority are bounded. Browser, documentation, and reasoning MCPs should not be inherited by every role.

For Codex, ignore user MCP config for governed runs. For Claude, use `--safe-mode`, an explicit empty MCP configuration, and `--strict-mcp-config`.

## Capacity Model

Persist only semantic capacity authority and limits:

- normal dispatch target and hard top-level cap;
- per-backend caps;
- CPU-heavy, database, and browser/Electron semaphore limits;
- green, yellow, and red thresholds;
- the identity of the approved machine profile when one supplies those limits.

Observe physical/logical processors, total/available memory, rolling CPU, and host-managed process duplication at dispatch time. Do not persist observed load or occupancy. Derive `current_parallel_roles`, WIP, backend counts, active/live/running counts, semaphore occupancy, and available slots by joining current-epoch control state to a fresh verified runner census. Render them only as a turn-local view with derivation time and source identities, then discard the view.

For the validated Windows host with 8 physical cores, 16 logical processors, and 61.7GB RAM:

| Limit | Value |
| --- | ---: |
| Normal top-level target | 6 |
| Yellow-state top-level target | 6 |
| Hard top-level cap | 6 |
| Codex cap | 6 |
| Claude cap | 6 |
| CPU-heavy | 6 |
| Database integration | 2 |
| Browser/Electron | 1 |

Capacity thresholds:

- green requires at least 16GB available memory and no red signal;
- yellow begins below 16GB or at rolling CPU at/above 75%;
- red begins below 10GB or at rolling CPU at/above 90%;
- red refuses new dispatch; yellow keeps the six-slot target while surfacing host pressure to total-control.

These values are a validated machine profile, not a universal default. Recompute when hardware, workload, container limits, or host behavior changes.

## Dispatch Transaction

One cross-process mutex covers this ordered transaction:

1. resolve the exact current epoch, tracked assignment/lease, semantic authority, and persisted limits;
2. collect a fresh runner census while the mutex remains held and verify exact role/run/process identities;
3. reconcile that census with current-epoch state and derive real-time WIP, parallel-role/backend/live counts, and semaphore occupancy;
4. fail closed on any missing, invalid, stale, or conflicting input, then apply host-load thresholds, caps, and semaphore limits to the derived occupancy;
5. create the fenced launch intent/reservation;
6. start the worker, bind its exact process/session identity, and finalize the run record; if binding/finalization fails, retain an unresolved reservation and block further dispatch until reconciled.

The state/census join is fail closed:

- validate full completion binding and terminal schema before excluding a run;
- accept verified terminal evidence from historical epochs without counting it;
- reject historical non-terminal evidence until reconciled;
- reject corrupt JSON, changed PID identity, path escape, and mismatched epoch/scope;
- treat a current-epoch active row without its verified runner, or a verified current-epoch runner without its authoritative row, as `UNKNOWN`, never zero;
- ignore any persisted `current_parallel_roles`, WIP, semaphore-use, or live-count value when making a dispatch decision.

## Evidence And Review

Every promoted runner needs:

- commit-bound parser, contract, governance, cleanup, and validator receipts;
- real parallel launch and resume for every supported backend;
- session reuse, marker, completion, control HEAD, script hash, and clean-worktree evidence;
- an independent exact-revision review with literal `review passed`.

Do not promote exploratory output or a pre-commit test run as final evidence.
