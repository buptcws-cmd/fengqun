# 野蜂 Outcome And Scope Control

Read this reference completely before authorizing the first implementation slice, changing product scope or architecture boundaries, re-estimating materially, reviewing a proposal, or continuing after product-visible progress stalls.

## Contents

- [Core Rule](#core-rule)
- [Outcome Lock](#outcome-lock)
- [Vertical-Slice Order](#vertical-slice-order)
- [Automatic And Batched-Decision Boundary](#automatic-and-batched-decision-boundary)
- [Scope-Drift Breakers](#scope-drift-breakers)
- [Progress And Estimate Truth](#progress-and-estimate-truth)
- [Direction-First Review](#direction-first-review)
- [Machine-Reconcilable Handoff](#machine-reconcilable-handoff)

## Core Rule

Treat default approval as authority to execute safely and persistently inside an agreed product contract. Do not treat it as authority to decide a different product contract.

Separate three kinds of authority:

- **Execution authority:** inspect, edit declared paths, create bounded worktrees, delegate within the operator ceiling, validate, review, commit, integrate, and clean up when the recorded policy allows it. Drain these actions without repeated approval.
- **Implementation discretion:** choose reversible internal designs that implement the outcome lock without adding a new public capability family, durable data obligation, external dependency, risk boundary, or material schedule change. Exercise this discretion autonomously and record important decisions.
- **Intent authority:** choose the product objective, user-visible outcome, MVP boundary, non-goals, public capability families, destructive/data-preservation policy, or material scope/schedule tradeoff. This remains with the user unless the exact choice is already recorded.

Delegate permissions at or below the operator's ceiling. Never use a broader sandbox, credential scope, external system, or destructive action merely because it is convenient. Conversely, do not ask again for each file, command, role, test, or normal merge already covered by the outcome lock and authorization policy.

## Outcome Lock

Before product implementation, record one compact current outcome lock in the project control surface. For an existing effort without one, synthesize it before the next implementation checkpoint instead of rewriting completed history.

Record:

```text
outcome_lock_schema_version: 2
outcome_lock:
  status: UNCONFIRMED | CONFIRMED
  revision:
  user_objective:
  user_visible_proof:
  first_vertical_slice:
  mvp_scope:
  non_goals:
  existing_capability_inventory:
  reuse_adapt_new_defer:
  approved_public_contract_families:
  allowed_invisible_prerequisite_depth: 1
  authorization_ceiling:
  auto_execution_boundary:
  ask_boundary:
  estimate_baseline:
  drift_thresholds:
  approved_by:
  approved_at:
```

Use these canonical persisted field names. `outcome_lock_revision`, `mvp_in_scope`, `ask_categories`, or a top-level copy of nested outcome fields are view labels only and MUST NOT be emitted as substitutes for the v2 control-state schema.

Define `user_visible_proof` as a real product-path demonstration a user can observe, not a schema, proposal, unit test, internal event, or line-count target. Define the first vertical slice from user action through canonical state and runtime behavior to readable/selectable UI or another directly observable result.

Inventory existing first-class capabilities before proposing a new subsystem. Classify every relevant surface as:

- `reuse`: use as-is;
- `adapt`: add the smallest compatibility or public adapter at the owning layer;
- `new`: create only the smallest missing broadly reusable capability;
- `defer`: keep outside the current MVP.

Default `allowed_invisible_prerequisite_depth` to one newly introduced enablement layer. Every invisible prerequisite must name the immediate product slice that consumes it and the checkpoint by which that consumption becomes real. Do not recursively promote a prerequisite's prerequisites into the active MVP without a scope decision.

## Vertical-Slice Order

Prefer this order unless the outcome lock records a stronger safety or dependency reason:

1. inventory and reuse current capabilities;
2. define the thinnest stable public contract needed by the first slice;
3. connect it to the canonical state/effect owner;
4. prove one real official or user-authored consumer through the product path;
5. expand modes, components, tooling, governance, migration, marketplace, or optimization only as the confirmed MVP requires.

Do not complete a broad storage, migration, policy, security, or governance platform before its first real consumer merely because the internal dependency graph can be made rigorous. Security-critical prerequisites may precede the consumer, but must remain the smallest proven boundary and must name the immediate consuming slice.

## Automatic And Batched-Decision Boundary

Continue automatically when work:

- remains inside the current objective, MVP, non-goals, public contract families, paths, risk ceiling, and estimate tolerance;
- is reversible internal implementation or normal governance;
- reuses or adapts an existing capability as recorded;
- has an identified product-path consumer;
- satisfies startup-level, validation, review, and capacity gates.

Request one batched user decision when work would:

- change the objective, user-visible proof, MVP, or non-goals;
- add a public capability family, external system, durable data obligation, migration/compatibility promise, or major architectural owner not recorded in the lock;
- exceed the authorization ceiling or enter an `ASK` category;
- replace the agreed vertical slice with infrastructure-only delivery;
- materially change the estimate baseline beyond the recorded tolerance;
- resolve contradictory product choices that cannot be derived from repository authority.

Present the current lock, evidence, smallest reuse-first option, alternatives, risk/schedule delta, and recommendation together. After the user decides, increment `outcome_lock_revision`, invalidate or update affected assignments, and resume all unchanged in-scope work without repeating the same question.

## Scope-Drift Breakers

Use project-recorded thresholds when present. Otherwise trip a breaker on any of these defaults:

- a proposed checkpoint adds an unrecorded product goal, public capability family, durable lifecycle, or non-goal reversal;
- a second invisible prerequisite layer appears before the first layer has a real product consumer;
- two consecutive implementation checkpoints produce no `PRODUCT_PATH_ADVANCED` or `PRODUCT_PATH_CLOSED` evidence;
- an enablement-only checkpoint's named consumer is deferred or moved twice;
- remaining effort grows by more than 50% from the last user-confirmed baseline, or the same delivery estimate is extended twice without a confirmed scope change;
- review/candidate breakers trip, or repeated review proves internal correctness while scope alignment remains disputed;
- specifications, tests, schemas, or governance artifacts grow materially while no production consumer can be identified at an exact path/revision.

When a breaker trips:

1. stop new dispatch, integration, and expansion only for the affected scope;
2. preserve safe in-lock work and evidence; do not discard or destructively clean it;
3. classify accumulated work as `reuse`, `adapt`, `new`, `defer`, `salvage`, or `remove-after-review`;
4. return to Level 0 for the unresolved product decision, or Level 2 for a narrowed implementation rebaseline;
5. issue one compact decision packet rather than many low-level approval questions;
6. resume only after recording the new lock revision and reconciling assignments, claims, leases, and estimates.

## Progress And Estimate Truth

Classify every completed checkpoint using exactly one primary delivery class:

- `PRODUCT_PATH_CLOSED`: the promised user path works end to end with applicable manual/product evidence;
- `PRODUCT_PATH_ADVANCED`: a user-observable portion works and the remaining boundary is explicit;
- `ENABLEMENT_ONLY`: necessary internal capability with an exact immediate consumer and deadline;
- `SPEC_ONLY`: contract or proposal work without runtime closure;
- `TEST_ONLY`: test/evidence work without a new product behavior.

Report outcome first. Separate user-visible value from enablement, specifications, tests, review, and cleanup. A merged internal platform checkpoint may be important, but do not call it product closure unless the locked proof is visible on the real path.

Keep the original confirmed estimate baseline alongside the current estimate. When it changes, report:

```text
previous_baseline:
current_estimate:
scope_delta:
evidence_that_changed_the_estimate:
user_visible_work_completed:
enablement_only_work_completed:
remaining_product_path:
next_rebaseline_trigger:
```

Never silently roll an expired estimate forward. Do not use confidence labels imported from another workstream unless the current project's own policy defines them.

## Direction-First Review

Review direction before implementation quality. Bind every proposal and implementation review to the exact outcome-lock revision and frozen candidate revision.

First determine:

1. Does the candidate still produce the agreed user-visible proof?
2. Is it the smallest credible reuse-first path?
3. Did it add scope, prerequisites, public contracts, or schedule obligations outside the lock?
4. Does its delivery classification match the evidence?

Only after those pass, review correctness, security, tests, maintainability, and integration readiness. A candidate cannot receive literal `review passed` when direction/scope alignment fails, even if its internal implementation is excellent.

Use this minimal result:

```text
outcome_lock_revision:
candidate_revision:
scope_alignment: pass / fail
smallest_path_and_reuse: pass / fail
delivery_classification:
implementation_quality: pass / fail / not_reviewed
verdict: review passed / review failed
required_fixes_or_decision:
```

## Machine-Reconcilable Handoff

Do not declare a parallel track handed off from prose alone. Record and reconcile at least:

- exact control/product repositories and revisions;
- worktree and branch;
- owner or explicit `unclaimed` state;
- scope, forbidden scope, claim, lease, `run_epoch`, and outcome-lock revision;
- validation and direction-first review verdict bound to the candidate revision;
- append-only message/event ID and accepted cursor/receipt;
- stable classification of kept, deferred, salvageable, and removal-candidate artifacts;
- recipient ACK or explicit pending-ACK state;
- merge/integration state and next safe actor/action.

Run the applicable reconciliation command or state check before reporting handoff complete. Narrative summaries are useful views, never substitutes for claims, leases, revisions, cursors, and acknowledged control truth.
