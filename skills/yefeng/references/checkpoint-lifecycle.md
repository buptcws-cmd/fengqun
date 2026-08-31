# 野蜂 Checkpoint Lifecycle

Read this reference before total-control claims, dispatches, reviews, integrates, cleans, pauses, hands off, resumes, or closes a checkpoint. 野蜂 owns these semantics directly; do not load `series-task-workflow` in addition.

## Authority And WIP

Resolve contradictions in this order:

1. actual control/product Git, filesystem, process, API, and runtime state;
2. current machine control state;
3. exact-candidate evidence manifest;
4. the human hot registry;
5. indexed archive and Git history;
6. conversation or role report.

Correct lower-priority truth before mutation. Keep one total-control writer and a monotonically increasing `run_epoch`. Treat the configured WIP budget as ceilings, not targets: default to at most two implementation roles, two pending review gates, and one integration intent. Derive live use from current-epoch assignments joined to a fresh verified runner census; missing or contradictory inputs mean `UNKNOWN` and block dispatch.

Keep at most one active candidate per root-cause direction. Queue other discoveries with evidence instead of opening speculative worktrees or equal-scope reviews.

## Lifecycle Meanings

Use the smallest applicable state set:

```text
PLANNED -> CLAIMED -> IMPLEMENTATION -> VALIDATION -> REVIEW
REVIEW -> DONE -> MERGED -> CLOSED
REVIEW -> IMPLEMENTATION                    (product repair)
any active state -> BLOCKED
any active state -> PAUSED | HANDED_OFF | CANCELLED | EXPIRED
PAUSED | HANDED_OFF -> CLAIMED               (explicit resume, new epoch)
```

- `DONE`: the frozen candidate passed its required exact-revision validation and review but is not integrated.
- `MERGED`: the reviewed candidate is integrated into the named source-of-truth branch.
- `CLOSED`: integration/product-path evidence, claim release, process/worktree disposition, and evidence/archive disposition are complete.
- `BLOCKED`: one concrete blocker, required evidence, owner, and unblock action are recorded.
- `HANDED_OFF`: one named actor, boundary, and acceptance contract owns the next action.

Historical terminal records never count as live WIP. A terminal row in the human hot registry contains only checkpoint ID, terminal state, integration identity, and exact evidence/archive pointers. Move the cycle narrative, rejected candidates, old validations/reviews, former leases, and superseded identities to indexed evidence in the same control transition.

## Claim And Worktree Contract

- Total-control assigns roles; roles never self-claim or dispatch peers.
- Claim the smallest coherent unblocked checkpoint. Bind scope, epoch, stable assignment/claim ID, branch, worktree, write surfaces, forbidden surfaces, validation plan, review gate, and lease when concurrent actors exist.
- Before every state-changing action, verify the current epoch, assignment/lease, worktree, branch/revision, declared paths, and WIP capacity.
- Use one dedicated branch/worktree per implementation role unless a recorded read-only or document-only exception applies.
- A role changes only its declared surfaces, records task-local facts, and returns evidence. It does not edit shared tracked control truth, merge, release claims, or clean shared state.
- A reviewer keeps product files read-only and writes only its authorized verdict/evidence surface.
- Worktrees are execution containers, not durable evidence. Preserve authorized commits or a complete hash-bound patch/archive before cleanup; never delete the only copy of dirty or unpublished work.

`execution_mode: solo` may omit token/lease/timestamp bookkeeping only when exactly one actor works the scope and no delegated role is live. It still records checkpoint, scope, write surfaces, epoch, gates, and revision. Reconcile actual Git/worktree state at startup, and restore multi-actor leases before any concurrent dispatch.

## Candidate And Evidence Loop

1. Reconcile current truth, dependencies, outcome lock, and authorization ceiling.
2. Assign one bounded runnable checkpoint and its write boundary.
3. Create or verify the dedicated worktree before edits.
4. For a semantically thick state machine, cross-module contract, authorization/security change, migration, or irreversible operation, freeze acceptance invariants and the smallest RED matrix before implementation; use a distinct adversarial pre-audit when risk warrants it.
5. Implement only the assigned checkpoint and record stable control facts at meaningful transitions.
6. Run focused validation while iterating, then the declared exact-revision validation and closest real product-path/manual proof at freeze.
7. Freeze one candidate only when its complete diff, known gaps, runtime/toolchain identity, and evidence bundle are stable.
8. Run the required review contract. Consolidate findings before one repair batch; do not alternate tiny patches among reviewers.
9. Relevant candidate changes invalidate bound validation/review. Archive-only metadata outside the reviewed surface may inherit only when the recorded binding proves the product surface is unchanged.
10. When authorized, integrate, run post-integration gates, update terminal status, release the claim, and disposition exact task-created processes/worktrees/branches/artifacts.

Gate evidence binds the exact candidate revision and applicable subject, runtime, toolchain, and outcome-lock identities. An interrupted, timed-out, cancelled, incomplete, or ambiguous result is not passed. A formal review has a unique identity when referenced by a gate, the exact candidate, literal `review passed` or `review failed`, classified findings, residual risk, and unlock/block effect.

## Review And Cost Breakers

Default to one independent final review. Add one distinct adversarial pre-audit only for material architecture, authorization, security, concurrency/state-machine, migration, irreversible, cross-boundary, or explicitly required risk. A documentation checkpoint whose acceptance is factual accuracy may use one light independent fact check.

Give every reviewer one exact subject and evidence bundle, an evidence-trust boundary, and a convergence budget. Parallel reviewers require different charters. A reviewer that exhausts its budget without a verdict or one concrete blocking question is replaced in the same slot; do not add another equal-scope review.

Classify findings before they consume budget:

- `product`: behavior, contract, security, or tests are wrong; consumes candidate/review-failure budget.
- `administrative`: registry, claim coverage, status vocabulary, or evidence hygiene is wrong while the product surface is correct; repair in place and rebind evidence without consuming the product breaker.
- `infrastructure`: executor, capacity, sandbox, or dependency failure; repair the environment and rerun without consuming product attempts.

For one root-cause direction, default `candidate_attempt_limit=2` and `review_failure_limit=2`. When either is reached, stop new candidates, packaging/full matrices, and repeated reviews. Mark the checkpoint blocked on root-cause/design reassessment. Record rejected assumptions, a narrowed causal hypothesis, the smallest acceptance matrix, changed direction, and who may reset/resume.

Run full gates only at candidate freeze and after integration. Size execution windows to known baselines or poll a background gate. An executor kill is infrastructure, but a second identical kill means the window is wrong and must be fixed before another run. Stage-decomposed commands are valid when their recorded union covers the declared full gate on the same frozen revision.

## Integration, Pause, And Closure

Only total-control integrates. Verify the expected target HEAD immediately before merge, use the recorded integration protocol, and never describe two repositories as atomically committed. After integration, record the actual merge identity and product proof before changing `MERGED` to `CLOSED`.

Pause, handoff, cancellation, and takeover increment `run_epoch`, invalidate old assignments/heartbeats, preserve evidence, and stop the old queue. Resume only through explicit current-epoch authority and full reconciliation.

At handoff, retain one compact capsule: objective/non-goals; startup level/topology; exact control/product identities; active checkpoints; completed and remaining gates; blockers; next actor/action; required hot/warm references; cursors/fingerprints; cold archive pointers; process/worktree cleanup state. Never paste completed transcripts or old cycle narratives back into hot state.
