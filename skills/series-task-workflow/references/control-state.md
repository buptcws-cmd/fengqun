# Series control state

Read this reference when a series spans conversations, uses delegated workers/reviewers, maintains more than one worktree, or needs reliable pause/resume behavior.

## Contents

- [Authority order](#authority-order)
- [Context budget](#context-budget)
- [Incremental read protocol](#incremental-read-protocol)
- [Handoff capsule](#handoff-capsule)
- [Lifecycle](#lifecycle)
- [Suggested machine state](#suggested-machine-state)
- [Transition checks](#transition-checks)
- [Reconciliation command](#reconciliation-command)
- [Review and validation semantics](#review-and-validation-semantics)
- [Progress checkpoint](#progress-checkpoint)

## Authority order

Resolve conflicting facts in this order:

1. actual Git, filesystem, process/agent, API, and runtime state;
2. machine-readable control state;
3. current-cycle evidence manifest;
4. active human registry;
5. archive and Git history;
6. conversation summaries and worker self-report.

Correct lower-priority state before taking a state-changing action.

## Context budget

Keep series context in three layers so completed history does not crowd active decisions:

- **Hot:** current goal and control status, exact source/runtime identities, at most two or three active work items, blockers, and next actions. Keep this in the active registry and load it by default.
- **Warm:** the current cycle contract, exact revisions, validation/review evidence, reproduction material, and task-specific handoff detail. Load it only for the active checkpoint.
- **Cold:** closed cycles, superseded candidates, historical logs, old runtime/package identities, and completed registries. Store it in indexed archives, commits, PRs, or evidence manifests and load it only for audit or reopening.

As a default budget, keep the active registry at or below 100 lines, no more than two or three active WIP rows, and at most one just-closed row waiting for archive. Local authority may override these values. Archive stable closed rows, superseded candidates, and completed investigation detail immediately instead of waiting for the registry to become large.

## Incremental read protocol

The host may require the applicable `SKILL.md` to be read in full on every new turn. Keep that entrypoint compact and obey the host. This protocol reduces every other repeated read:

1. Start with actual system state, the machine control state, and the compact hot registry.
2. Record `instruction_fingerprints` as SHA-256 values for authority/reference files after their latest full required read. If a fingerprint changes, reread that file completely before acting under it. A matching fingerprint permits reuse only within the same continuing context and never overrides a host rule requiring a fresh read.
3. Record `event_cursors` for append-only events, messages, logs, and review queues. Read strictly after the accepted cursor, verify continuity, then advance the cursor only after the new facts are reconciled into current truth.
4. Load warm material only for the next action: the active checkpoint contract, exact candidate diff, current evidence, and applicable action-specific reference.
5. Load cold history only when reopening, auditing provenance, resolving a contradiction, or restoring evidence. Search/index first; do not reread an archive from the beginning by default.
6. At the end of a stable transition, refresh the hot registry, fingerprints, cursors, archive pointers, and one concise `last_stable_summary`.

Fingerprints and cursors are cache-validation aids, not authority. A hash match does not prove a dynamic fact is still true; Git, process, API, runtime, claim, and lease facts must still be reconciled.

## Handoff capsule

For a cross-conversation handoff, write a compact, state-verified capsule:

```text
Objective and non-goals:
Control status and current run_epoch:
Authoritative source/runtime identities:
Active work items (maximum two or three):
Completed gates with exact evidence:
Remaining gates:
Blockers and risks:
Next safe action and authorized actor:
Required hot/warm documents:
Cold archive pointers (do not load by default):
Cleanup and paused-worker state:
```

Validate the capsule against actual Git, worktree, process, API/runtime, and control state immediately before handoff. Mark uncertain facts instead of copying them as truth. A next-action sentence never overrides a `paused`, `handed-off`, or `cancelled` control status.

## Lifecycle

Use the smallest applicable state set:

```text
unclaimed -> claimed -> implementation -> validation -> review
review -> done -> merged -> closed
review -> implementation                 (review failed)
any active state -> blocked
any active state -> paused | handed-off | cancelled | expired
paused | handed-off -> claimed            (explicit resume, new epoch)
```

`done` is locally verified and reviewed. `merged` is integrated. `closed` also requires final evidence and execution-container cleanup.

## Suggested machine state

Keep dynamic control facts compact. Adapt field names to local conventions.

Keep only current in-scope candidates in `candidates`; move superseded or historical candidates to warm/cold evidence. Bind every candidate's worktree, branch, revision, validation, and review independently.

```json
{
  "run_epoch": 4,
  "status": "active",
  "main_revision": "<git revision>",
  "wip_budget": {
    "active_repairs": 2,
    "pending_reviews": 2,
    "integration_batches": 1
  },
  "cycle_budget": {
    "candidate_attempt_limit": 2,
    "review_failure_limit": 2,
    "candidate_attempts": 0,
    "review_failures": 0
  },
  "context_checkpoint": {
    "instruction_fingerprints": {
      "AGENTS.md": "<sha256>",
      "NEXT_STEPS.md": "<sha256>"
    },
    "event_cursors": {
      "events.jsonl": 41,
      "review_queue": "<opaque-cursor>"
    },
    "last_stable_summary": "<one compact current-truth summary>",
    "cold_archive": "<path or ref>"
  },
  "claims": [
    {
      "id": "<stable claim>",
      "status": "running",
      "run_epoch": 4,
      "lease_expires": "2026-07-15T12:00:00Z"
    }
  ],
  "candidates": [
    {
      "id": "<task or candidate id>",
      "status": "implementation",
      "worktree": "<absolute path>",
      "branch": "<branch name>",
      "revision": "<git revision>",
      "validations": [
        {
          "name": "targeted-tests",
          "revision": "<same exact git revision>",
          "status": "passed",
          "interrupted": false
        }
      ],
      "reviews": [
        {
          "reviewed_revision": "<same exact git revision>",
          "status": "passed",
          "verdict": "review passed"
        }
      ]
    }
  ],
  "cleanup_state": "pending"
}
```

## Transition checks

Before dispatch, resume, write, long validation, commit, review, merge, cleanup, or closeout, verify:

- control status permits the action;
- worker/claim epoch equals current `run_epoch`;
- claim lease is live;
- actual main revision and every candidate's revision match recorded identities;
- each candidate's declared worktree/write surfaces agree with actual state;
- WIP budget has capacity;
- required upstream gates are exact-revision evidence;
- no source change invalidated validation or review;
- cycle-budget counters do not require a design/root-cause reassessment;
- requested cleanup does not delete the only durable evidence.

Do not infer commit authority from an evidence-preservation requirement. Reuse existing commits/refs where possible. For dirty WIP, use a labelled checkpoint commit only when authorized; otherwise preserve a patch together with every staged/unstaged/untracked file it omits, or a complete archive, then record hashes and verify restoration. Do not treat a Git bundle as dirty-file evidence. If no authorized durable form exists, leave the worktree quarantined and report cleanup blocked.

Increment `run_epoch` on pause, handoff, cancellation, or takeover. Do not reuse an earlier epoch on resume.

## Reconciliation command

From any worktree in the same Git repository, pass the absolute machine-state path explicitly:

```powershell
pwsh -NoProfile -File scripts/reconcile-series-state.ps1 -StatePath <absolute-control-state.json>
```

The script is read-only. It checks local `refs/heads/main`, each declared candidate worktree/branch/revision, exact-revision validation and review evidence, WIP budgets, claim epoch/lease state, and inactive/closed control states. It ignores Git worktrees that are not declared as current candidates, so unrelated work does not consume this series' WIP budget.

Exit `0` means reconciliation completed with no issues. Exit `2` means the JSON result contains schema, identity, evidence, lease, WIP, or lifecycle issues; block state-changing actions until they are reconciled. Omitting mandatory `-StatePath` is rejected by PowerShell before reconciliation. The script never edits state, renews claims, increments epochs, switches branches, fetches remotes, or cleans worktrees.

## Review and validation semantics

- Treat interrupted, cancelled, timed-out, or incomplete validation as not passed.
- Bind passed validation and review to exact candidate revisions.
- Record `pre-audit-ready` only when the contract and candidate direction are stable, focused checks pass, and known gaps are explicit. Use this early gate only when the checkpoint's risk or local authority requires a pre-audit.
- Record `final-review-ready` only when the exact final candidate is frozen and every required post-repair validation/manual evidence item is complete.
- Append review records in observation order. For a terminal candidate, the last review entry is authoritative and must itself be `review passed`; an earlier pass never overrides a later failure or incomplete review.
- Accept only literal `review passed` or `review failed` as a formal verdict.
- Keep advisory output without a verdict as `reviewing` or `incomplete`.
- Default `candidate_attempt_limit` and `review_failure_limit` are both `2` for one root-cause direction. A local authority may lower them or deliberately raise them with a recorded reason.
- Count a candidate attempt when a frozen candidate is rejected by required validation, product-path evidence, or formal review. Count a review failure only for a substantive literal `review failed`; a timeout or infrastructure interruption remains incomplete and does not consume the review-failure counter.
- Before repair, consolidate all available findings into one batch. A changed exact revision is a replacement candidate, not permission to send parallel equal-scope reviewers or repeat the same full evidence load.
- When either limit is reached, mark the checkpoint `blocked` with `root-cause-reassessment-required`. Stop packaging, broad matrices, and new formal review. Write a narrowed causal hypothesis, rejected assumptions, smallest acceptance matrix, and changed direction; then explicitly reset counters before implementation resumes.
- Track delivery efficiency with compact counts: merged checkpoints, product-path-closed checkpoints, candidate attempts, formal review rounds, full package/build rounds, and active-registry size. Token counts may be recorded when the host exposes them, but never invent them.

## Progress checkpoint

Use this compact report:

```text
Cycle / stage:
Evidence-backed progress since last report:
Active owner, state, elapsed:
Remaining gates:
Blockers and risks:
WIP and cleanup debt:
Next milestone:
ETA P50 / P80 and assumptions:
Next report trigger:
```

A progress request does not pause work. A request containing pause, stop, cleanup-before-resume, handoff, or new-conversation intent does.
