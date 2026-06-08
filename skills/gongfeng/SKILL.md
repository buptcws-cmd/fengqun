---
name: gongfeng
description: >-
  Use before implementing fixes for code bugs, failing tests, runtime errors,
  data inconsistencies, architecture defects, interaction problems, or
  code-level product quality defects that require diagnosis, and when auditing,
  refactoring, or cleaning technical debt.
  Trigger immediately when Codex is tempted to add fallback logic, try/catch
  defaults, sanitizers, normalizers, compatibility shims, catch-all adapters,
  UI-side cleanup, default-value projection, or silent degradation. Enforces
  source-first repair and scans codebases for old degradation debt while allowing
  such handling only at legitimate boundaries such as external input, migration,
  security fail-closed behavior, cross-version compatibility, third-party output,
  or crash recovery.
---

# Gongfeng

Use this skill as a pre-repair quality gate and a technical-debt hunting workflow.

The goal is to prevent new hidden debt and remove old hidden debt. Do not first add a
temporary fallback and then invoke this skill later. Invoke it before choosing the fix.

Do not invoke this skill for ordinary greenfield feature work when there is no bug, quality
defect, refactor, audit request, technical-debt cleanup, or fallback-style repair proposal.

## Core Rule

Always trace the bad state to its earliest producer before designing the repair.

If the bad value, state, payload, copy, or behavior is produced inside the product, fix the
producer, schema, state machine, write path, API contract, test fixture, or workflow. Do not make
consumers compatible with internally broken output.

## New Work Gate

Before changing code for a bug, failed test, runtime error, data inconsistency, architecture defect,
or interaction problem:

1. Name the symptom.
2. Identify the earliest producer of the bad state.
3. Classify the site as internal source, boundary, migration, compatibility, security, crash
   recovery, or display-only.
4. Reject fallback-style repairs unless the site is a legitimate boundary.
5. Fix the source first. If a boundary guard remains, make it narrow and explain why it is valid.
6. Add or update tests that prove bad internal state is rejected or cannot be produced.

## Forbidden Default Repairs

Do not use these as the primary fix for internally generated problems:

- `fallback`, default object/array/string/value projection
- `try/catch` that returns `{}`, `[]`, `null`, `undefined`, `"unknown"`, or success
- broad sanitizer, normalizer, cleaner, mapper, converter, adapter, or shim
- UI-side replacement or render-time filtering
- catch-all compatibility wrappers
- tests that assert silent degradation as expected behavior

These patterns are allowed only after proving they guard a real boundary.

## Legitimate Boundaries

Boundary handling may be acceptable for:

- external user input or third-party API data
- AI/model output parsing
- CLI/tool output and operator-local config
- legacy data during a bounded migration
- cross-version protocol compatibility
- security fail-closed behavior
- crash recovery, cache recovery, or diagnostic best-effort readback

Even at boundaries, keep the handling narrow, observable, and test-covered. Prefer reporting the
degraded condition over silently hiding it.

## Existing Debt Scan

When auditing or cleaning a codebase, scan broadly first, then classify before editing.

Suggested search terms:

```text
fallback
default
try
catch
JSON.parse
safeParse
sanitize
normalize
compat
shim
adapter
cleanup
unknown
return {}
return []
return null
return undefined
```

For JavaScript or TypeScript, prioritize patterns like:

```text
JSON.parse ... catch ... return {}
JSON.parse ... catch ... return []
JSON.parse ... catch ... return null
catch ... "unknown"
safeParse(...).success ? ... : default
```

Do not treat every match as debt. Classify each candidate:

- **Internal state debt**: persisted product state, internal event payloads, generated configs,
  task/session records, repository rows, or product-owned schemas. Fix strictly.
- **External boundary**: request input, package manifests, CLI output, provider/API responses,
  model output, operator-local files. Keep or narrow validation.
- **Migration boundary**: historical records being upgraded. Make cleared or repaired data
  explicit in result counters, logs, or diagnostics.
- **Crash/diagnostic boundary**: cache, snapshot, status, or doctor readback. Allow recovery, but
  surface degraded posture.

## Repair Priority

Use this order:

1. Source fix: prevent invalid internal state from being written or generated.
2. Contract fix: validate at the boundary before data enters internal models.
3. Migration fix: repair historical data and prevent recurrence.
4. Narrow containment: retain a guard only with explicit boundary reasoning.
5. Last resort: consumer-side patching, only when higher-priority fixes are impossible now.

## Completion Standard

Do not call the work done until the final report states:

- what source was fixed
- which fallback or silent degradation was removed or narrowed
- which remaining fallback is a legitimate boundary and why
- which tests, typechecks, lint checks, or product-path checks prove the behavior

If a scan finds many candidates, group by shared mechanism and fix the highest-risk internal
producer first. Avoid unrelated refactors while cleaning debt.
