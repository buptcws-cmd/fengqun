# 野蜂 Process Backend

Read this reference completely before launching, resuming, polling, or cleaning up background Codex CLI role sessions. Resolve every path from the recorded assignment; never infer product or control roots from the current directory.

## Contents

- Root and path rules
- Launch and resume
- Run identity and cleanup
- Windows command resolution and encoding
- Sandbox probe

## Root And Path Rules

Record these roots explicitly:

- `control_root`: embedded project root or independent external Git control repository;
- `product_root`: authoritative product repository;
- `role_worktree`: assigned product worktree;
- `control_run_root`: `<control_root>/.yefeng/runs/<scope_id>/<role_id>/<run_id>` in namespaced mode, or the legacy unnamespaced path under the `SKILL.md` read-compatibility rule in embedded mode. Do not rewrite old records or synthesize missing epoch/identity fields.

Keep helpers under the control root when using `external-git`, for example:

- `scripts/yefeng/start.ps1`
- `scripts/yefeng/launch-role.ps1`
- `scripts/yefeng/resume-role.ps1`
- `scripts/yefeng/poll.ps1`
- `scripts/yefeng/cleanup-completed-runs.ps1`
- `scripts/yefeng/audit-process-budget.ps1`

Use `git -C <explicit-root>` for every Git operation. Launch and resume from the role's product worktree. Store prompts, assignments, stdout, stderr, PIDs, and completion records under the control run root. Do not place runtime logs in the tracked product repository.

## Launch And Resume

Use `codex exec` as the default background backend:

```powershell
Get-Content -LiteralPath <prompt-file> -Raw |
  codex exec --json --skip-git-repo-check -C <role-worktree> -s <sandbox-mode> -o <control-run-root>\last-message.md -
```

Resume only when a session ID is known:

```powershell
codex exec resume <session_id> "<resume prompt>"
```

Current Codex CLI may not accept `-C` on `codex exec resume`. Run resume with the process current directory set to the assigned product worktree. Always create the control run directory before redirecting stdout or stderr.

Do not pass interactive-only flags to `codex exec`. Verify flags against `codex exec --help`; `-a/--ask-for-approval` may exist for interactive Codex but not for `codex exec`.

Record stdout JSONL, stderr, process ID, run ID, last-message path, prompt path, assignment path, sandbox mode, start/end time, exit code, and discovered session ID. When `--json` is enabled, parse the first `thread.started` event and use `thread_id` as the resumable session ID. If that event is absent, mark the run non-resumable until proven otherwise.

## Run Identity And Cleanup

Do not treat `Get-Process -Id <pid>` as proof that a role remains alive. A PID is valid only when the live command line still matches the recorded run directory, runner, stdout/stderr/last-message path, or actual `codex exec` command for the assigned product worktree. Treat a mismatched live PID as PID reuse and continue importing completion evidence.

After `DONE`, `FAILED`, `EXIT_UNKNOWN`, or `EXPIRED`, audit the process tree. Stop only processes tied to that run by command-line evidence. Prefer a dry run first. When supported, record targeted cleanup evidence such as:

```powershell
cleanup-completed-runs.ps1 -DryRun -RecordDryRunState -RunId <run_id>
```

Shared run-state writes require a control-repository lock. Prefer one targeted state-recording command per run rather than concurrent writers.

When process counts are high, audit the process budget before adding capacity. Separate active 野蜂 runs, attributable terminal processes, and host-managed Codex Desktop/Electron/MCP/Node children. Redact secrets from command lines. Never kill unmatched host-managed processes without explicit user authority.

If no reliable session ID exists, do not use broad `--last` in a shared Codex home. Relaunch from recorded state or isolate the role's `CODEX_HOME` so `--last` is unambiguous.

Before recursive cleanup, resolve and verify that every target stays under the recorded control run root or assigned product worktree root. Never infer a cleanup root from an unresolved environment variable.

## Windows Command Resolution And Encoding

Launch background helpers with `Start-Process -WindowStyle Hidden` unless the user explicitly wants visible terminals. Prefer `pwsh`. If Windows PowerShell 5.1 is required, use ASCII-only script source or save Chinese-containing scripts with a BOM.

Resolve Codex CLI to an explicit working command. Prefer `codex.cmd` or an npm shim over the WindowsApps alias:

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

Record `codex_command` in run metadata. Treat WindowsApps access denied as launcher resolution failure and retry the recorded assignment only after fixing the launcher.

For non-ASCII paths or governance docs, prepend UTF-8 setup to generated launch/resume helpers:

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$env:PYTHONIOENCODING = 'utf-8'
try { chcp.com 65001 > $null } catch {}
```

Prefer authoritative paths from prompts, manifests, and control docs over garbled console listings. If logs contain mojibake, repair encoding and rerun a small probe before routing, merging, or cleanup.

## Sandbox Probe

Before the first implementation role on Windows, run a disposable `workspace-write` probe that prints the current directory. If it returns `CreateProcessAsUserW failed: 5`, record `workspace-write-shell=false` in run state or the status snapshot.

Roles needing tests, builds, Git, or dependency inspection may use `danger-full-access` only inside their dedicated product worktree when authorization permits. Do not use approval-bypass flags.

An external control repository may fall outside the role sandbox. Do not widen sandbox authority merely to write shared governance. Prefer, in order:

1. the assignment's role-specific external spool when the sandbox permits it;
2. a worktree-local ignored outbox imported by total-control;
3. a final-message handoff imported by total-control.

The effective safety boundary remains the dedicated worktree, narrow assignment, ignored transport, reviewer gate, and total-control integration review.
