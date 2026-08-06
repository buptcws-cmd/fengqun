# 野蜂 Run Evidence Retention

Read this reference before assessing, compacting, archiving, or deleting ignored run logs.

## Contents

- [Purpose](#purpose)
- [Structured Binding](#structured-binding)
- [Default Policy](#default-policy)
- [Exact Deletion Surface](#exact-deletion-surface)
- [Two-Commit Apply Protocol](#two-commit-apply-protocol)
- [Failure And Recovery](#failure-and-recovery)

## Purpose

Compact semantic duplicates after a completed batch without weakening active review, recovery, or audit evidence. This is evidence lifecycle management, not a generic disk cleanup command.

Use the bundled files:

- `scripts/run-retention-policy.json`: conservative defaults;
- `scripts/compact-run-evidence.ps1`: dry-run planner and exact-leaf Apply;
- `scripts/test-run-evidence-retention.ps1`: disposable fixture and installation-chain tests;
- `scripts/install-governed-runner.ps1`: transactional five-file installer;
- `scripts/validate-run-evidence-retention.ps1`: dedicated installed-chain validator.

## Structured Binding

A run is eligible only when its tracked run row contains all of:

```text
run_root
retention_group_id
parent_run_id
review_gate
control_disposition
```

`run_root` is the exact control-root-relative path `.yefeng/runs/<scope_id>/<role_id>/<run_id>`. IDs are path-free. `parent_run_id` is `null` or an exact run ID. `review_gate` is `PENDING`, `PASSED`, `FAILED`, or `NOT_REQUIRED`.

Use these control dispositions:

- protected: `ACTIVE`, `UNREVIEWED`, `BLOCKING`, `RECOVERY`, `RECONCILIATION`, `ACCEPTED`;
- potentially compactable after every other gate passes: `SUPERSEDED`, `ARCHIVED`, `DISCARDABLE`.

The fields are additive. Existing run rows remain readable. Missing or partial binding means legacy-protected, never an error-driven cleanup opportunity. A terminal structured run must also have a canonical, round-trip `ended_at`; blank, missing, non-string, invalid, or noncanonical values protect the whole run. Group ordering and all age/retention decisions use only that trusted `ended_at` and never fall back to `started_at`.

The governed producer contract is exact: runner completion writers, writer-takeover expiry, recovery code, and any future terminal-run producer MUST assign a `DateTimeOffset` serialized with `.ToString('o')`. `prepare-control-writer-takeover.ps1` derives one `$nowText = $now.ToString('o')` and assigns that value to expired runs; runner implementations are governed by the same process-backend contract. Do not substitute a merely parseable ISO string, `DateTime.ToString`, locale output, shortened fractional seconds, or a `Z` spelling. The external-control validator enforces this contract, while the compactor independently fails closed so a producer defect cannot become deletion authority.

## Default Policy

- Dry-run: required and default.
- Terminal minimum age: 24 hours.
- Superseded retention: 7 days.
- Long-log threshold: 1 MiB.
- Per-scope soft cap: 512 MiB.
- Overall runs cap: 1 GiB.
- Receipt cap: 64 KiB.
- Per retention group: keep the newest failure and final passing run.

Always protect:

- active or non-terminal runs;
- pending/unreviewed, blocking, recovery, or reconciliation runs;
- `ACCEPTED` runs;
- runs referenced by active control/role state, explicit pins, or `parent_run_id`;
- the newest failure and final pass in each retention group;
- every legacy or partially bound directory;
- every path containing a symlink, junction, mount point, or other reparse point.

The planner selects semantically eligible leaf logs at or above 1 MiB. When a scope or overall cap is exceeded, it may also select smaller eligible leaves. It batches and defers candidates to keep each plan/receipt within 64 KiB.

Each plan binds exactly one `product_repo_id`. In a multi-product scope, candidates for other product repositories remain deferred for later plans; every candidate repeats the same product identity so PREPARED and Apply attribution cannot cross product boundaries.

The bundled policy is a ceiling on deletion authority, not an authorization source. A custom policy may only be stricter: terminal/superseded ages, log threshold, caps, and retained failure/pass counts may increase; receipt size, Apply window, and batch size may decrease. The exact four allowed leaves cannot change. Hard-coded code invariants always protect known protected dispositions, pending/unknown review gates, nonterminal/unknown states, and invalid or blank identities/enums/bindings.

Before generating candidates, audit the complete run tree without following links. Any symlink, junction, reparse point, containment error, or non-ordinary leaf ambiguity protects the whole run; an ordinary log encountered before the bad entry never remains in the plan.

## Exact Deletion Surface

Only these ordinary leaf files may be deleted:

```text
stdout.jsonl
stderr.log
worker-stdout.log
worker-stderr.log
```

Never recursively delete a run directory. Never delete prompts, assignments, `run.json`, `completion.json`, cleanup evidence, last-message files, MCP profiles, handoffs, compact receipts, or unknown files. Do not gzip full logs as a substitute for semantic compaction.

## Two-Commit Apply Protocol

1. Reconcile roles, runs, reviews, blockers, recovery state, references, and the current control HEAD. The exact control Git top level must be clean.
2. Run a dry plan. The script makes no filesystem writes and reads tracked state from the committed HEAD. Its plan binds the base control HEAD, scope/epoch, policy hash, runs/roles/control/transport state hashes, token hash, explicit/derived reference-set hash, and candidate count/bytes/hash.
3. Inspect protected counts, deferred count, exact candidates, sizes, hashes, and paths.
4. Persist the unmodified dry-run JSON outside tracked truth, then acquire the normal control writer fence.
5. Append exactly one `RUN_EVIDENCE_RETENTION_PREPARED` event for the plan digest and commit it as the direct single-parent child of the plan's base control HEAD. Use the exact schema enforced by the script: event/operation/time/scope/epoch/repository identities, `prepared_parent_control_head`, plan/policy/token/reference digests, four state hashes, and candidate count/bytes/hash. Do not put a raw apply token in Git.
6. Release the writer fence and revalidate the committed control repository.
7. Apply using the exact saved plan plus explicit raw token and expected plan digest. Apply refuses a dirty repository, a non-direct or merge HEAD, a HEAD that did not change the scope event log, or zero/multiple/mismatched PREPARED events.
8. Apply reads the current committed state and validates all four state hashes, reference/candidate summaries, plan expiry against `[DateTimeOffset]::UtcNow`, canonical containment, complete no-reparse run audit, exact leaf name, and every file hash/size/mtime. There is no production caller-clock parameter. Any drift rejects before deletion.
9. Acquire the writer fence again and commit an `APPLIED` record containing plan digest, receipt digest, deleted count/bytes, protected/deferred counts, and any failure/reconciliation state.
10. Archive only compact summaries and evidence pointers.

Example dry-run:

```powershell
$receipt = & scripts/yefeng/compact-run-evidence.ps1 `
  -ControlRoot D:\project-control -ScopeId delivery-series
$receipt | Set-Content -LiteralPath <ignored-plan-path> -Encoding utf8
```

Example Apply after the `PREPARED` commit:

```powershell
& scripts/yefeng/compact-run-evidence.ps1 `
  -ControlRoot D:\project-control -ScopeId delivery-series -Mode Apply `
  -PlanPath <ignored-plan-path> `
  -ApplyToken <raw-token-from-dry-run> `
  -ExpectedPlanDigest <plan-digest-from-dry-run>
```

Do not pipe directly from dry-run to Apply. Human/total-control inspection and the committed `PREPARED` transition are mandatory.

Install or refresh only the retention helpers without depending on the separately reviewed runner pin:

```powershell
& <skill-root>\scripts\install-governed-runner.ps1 `
  -DestinationControlRoot D:\project-control -InstallRetentionOnly
```

The retention-only installer verifies one fixed five-file trust manifest before writing: compactor, policy, test, installer, and `validate-run-evidence-retention.ps1`. The three non-carrier artifacts use their raw SHA-256. Installer and the dedicated retention validator both carry the same manifest, so their fixed hashes are SHA-256 over the complete UTF-8 file after replacing only the five hash values between the exact `RETENTION_TRUST_MANIFEST` markers with zero-filled slots. This normalization removes the self-reference without excluding executable code or any content outside those five value slots.

The installer stages and verifies all five source files first. It then prepares and verifies every existing destination backup before the first replace, uses same-volume staged replacements, verifies each installed artifact, and restores or removes all five destinations on any failure. Invoking the installed installer against its own destination directory is supported because staging detaches every source byte before replacement. Installation evidence requires running the installed dedicated validator and installed test from the destination with both PowerShell 7 and Windows PowerShell 5.1. Source-tree tests alone are not installation proof.

Staging cleanup occurs after the five-file transaction. A cleanup failure is diagnostic residue, not permission to rewrite a completed install as failed, and it must never mask the primary install/rollback exception. On success, inspect `staging_cleanup_warning`; on failure, preserve the primary exception and treat any cleanup warning as a secondary manual-cleanup pointer. Remove such residue only after independently rechecking that its canonical path is inside the destination `scripts/yefeng` directory.

Retention validation is intentionally independent of whole-control validation. `validate-run-evidence-retention.ps1` checks only the five retention artifacts, their raw/normalized hashes, carrier-slot contract, and the exact retention policy. `-InstallRetentionOnly` MUST preserve any existing `validate-external-control-repo.ps1` byte-for-byte and must neither require nor install the message stack, runner stack, or a newer roles/runs schema. A full runner, message-stack, global-validator, or control-schema migration is a separate explicit workflow with its own proposal, compatibility decision, destination validation, and rollback evidence; it may never be triggered implicitly by retention-only installation.

## Failure And Recovery

- Zero eligible files is success. Record why items were protected; do not loosen the policy.
- A missing structured binding requires reconciliation and a later dry-run, not inferred migration.
- Reparse or containment ambiguity protects the run and blocks any affected Apply.
- Plan, policy, runs-state, hash, size, or mtime drift invalidates the plan. Generate and review a new dry-run.
- If an external interruption occurs after some exact leaves were deleted, inventory actual state, enter `RECONCILIATION`, and record observed hashes/counts before another plan. Never recursively clean the remainder.
- Never run Apply against a live scope using an uncommitted or stale control disposition.
