# 野蜂 Tracked Current-Truth Retention

Read this reference before creating repository guidance for a current-truth surface, compacting or migrating a human registry/status snapshot, changing its archive/index contract, or claiming that a legacy control document is safe to stop reading by default.

This workflow governs tracked human current truth in both `embedded` and `external-git` topologies. It is separate from ignored runtime-log retention: never use the run-log compactor on a tracked registry, and do not treat the embedded run-log restriction as a reason to leave a tracked dashboard unbounded.

## Ownership And Repository Guidance

Total-control is the only writer of the hot human projection. Roles and ordinary workers write task-local evidence and return facts for promotion; they do not append their history directly to the shared dashboard.

Repository authority such as `AGENTS.md` may contain only stable project-specific facts that must apply before a skill can act, for example:

- the project purpose and domain constraints;
- protected or user-owned paths;
- the stable locator of the current control entry;
- a deliberately stricter local limit or approval boundary.

Keep reusable workflow policy in 野蜂: hot/warm/cold classification, lifecycle meanings, full-versus-incremental reads, Claim/lease semantics, archive timing, size budgets, and migration mechanics. Do not put dynamic claims, current revisions, growing closeout history, or a rule requiring every agent to read cold history in `AGENTS.md`.

## Hot, Warm, And Cold

- **Hot:** objective/non-goals, current epoch/topology and exact baselines, at most two or three active checkpoints, current claims/gates, blockers/open decisions, next action, archive pointers, and cleanup debt. Load by default.
- **Warm:** the active checkpoint contract, exact candidate diff, current validation/review, reproduction material, and action-specific handoff. Load only for the next action.
- **Cold:** closed cycles, superseded candidates, old reviews, processed handoffs, former identities, and full historical registries. Search the index first and load only for reopening, audit, contradiction resolution, or evidence recovery.

Do not wait for a size threshold to archive a stable terminal cycle. In the same transition that records `MERGED` or `CLOSED`, collapse the hot row to state, integration identity, and exact evidence/archive pointers. Never preserve a full terminal payload both in hot state and in the archive.

## Lossless Legacy Migration

Use this procedure when a purported current file has accumulated history, contradictory states, malformed rows, unreachable pointers, or exceeds the hot budget.

1. **Fence the writer.** Identify the one total-control writer, stop competing registry writes, record the exact repository/branch/HEAD, and hash the source bytes. If another writer or relevant file edit is live, work in an isolated branch or wait; do not overwrite it.
2. **Reconcile reality.** Inspect actual Git, worktrees, exact role processes, current machine state, recent integration evidence, and unresolved user decisions. The bloated registry is a historical input, not authority for current liveness.
3. **Publish a lossless snapshot first.** Copy the source bytes unchanged into an organized archive, record source path, byte count, SHA-256, repository identity, source HEAD, timestamp, and snapshot path in a manifest, then recompute the snapshot hash. Do not hand-trim the only original.
4. **Create or update an index.** Give every archive locator an explicit base. Organize by scope/checkpoint family and point to existing evidence rather than duplicating it. The index links the lossless snapshot, closeouts, evidence manifests, and integration identities.
5. **Rebuild hot truth.** Write a new bounded projection from reconciled current facts. Keep active items, blockers, next actions, cleanup debt, and explicit archive links. Move contradictory or uncertain legacy facts to a named reconciliation blocker; do not silently choose one old sentence.
6. **Cross-bind machine state.** Refresh the current snapshot fingerprint, archive pointers, epoch/status, exact baselines, and concise stable summary. Mark superseded machine state inactive/archived or migrate it; never leave a higher-priority machine file claiming an old active queue while the human view says closed.
7. **Validate before publication.** Run the validator below, verify every declared local pointer and archive target, inspect the diff, and publish one coherent control transition. Re-run validation against the published bytes.
8. **Retain recovery.** Keep the immutable snapshot and manifest. Deleting or rewriting cold evidence is a separate, explicitly authorized retention action and is not implied by compacting the hot projection.

Recommended archive shape:

```text
<archive-root>/current-truth/
├── index.md
├── snapshots/
│   └── <timestamp-or-revision>/
│       ├── original-current-truth.md
│       └── manifest.json
└── closeouts/
    └── <scope-or-checkpoint-family>.md
```

Prefer one lossless snapshot plus an index into existing evidence. Create a new closeout document only when the stable terminal conclusion is not already recoverable from a task-local evidence file or integration record.

## Mechanical Validation

Use [`../scripts/validate-current-truth.ps1`](../scripts/validate-current-truth.ps1) for a Markdown hot registry/status view:

```powershell
pwsh -NoProfile -File <skill-root>/scripts/validate-current-truth.ps1 `
  -RegistryPath <absolute-hot-file> `
  -ArchiveIndexPath <absolute-archive-index>
```

The default contract checks:

- valid UTF-8, at most 16384 bytes and 120 lines;
- no line above 1000 characters;
- at most three active table rows and five terminal pointer rows;
- unique table IDs and no fused `|| <ID> |` rows;
- every local Markdown link resolves;
- the declared archive index exists and is linked from the hot file.

The validator cannot decide product truth. Passing it does not prove claims, baselines, statuses, or review evidence are correct; reconcile those against actual state. A nonzero result blocks publication, dispatch, resume, review, merge, cleanup, or a completion claim that depends on the malformed hot projection.
