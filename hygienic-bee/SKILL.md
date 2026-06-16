---
name: hygienic-bee
description: >-
  Audit and repair product code paths where exceptions, thrown errors,
  fail-closed states, null results, missing resources, provider errors, route
  errors, or generic error UI become the end of a user-facing workflow. Use when
  Codex is tempted to add catch blocks, fallback values, fail-closed exits,
  red-screen prevention, generic error messages, or "throw and stop" logic; when
  users say software should stay usable, recover automatically, guide the user,
  or not expose developer errors; and when reviewing resource loading, auth,
  entitlement, package update, local runtime readiness, sync, network, storage,
  router, or async state-machine failures.
---

# Hygienic Bee

Use this skill to convert user-path failures into recovery flows. A failure is
not a product endpoint; it is a signal that the system must diagnose, recover,
or guide the user through a concrete action and then resume the original intent.

## Core Principle

Do not let a user-facing branch end with `throw`, a red screen, raw exception
text, a generic error page, or a silent fallback that fakes success.

Every user-facing failure path must end in one of these states:

- **Recovered**: the system fixed the condition automatically and continued.
- **Actionable**: the user is shown a product path they can complete.
- **Safely suspended**: continuing would corrupt data or violate authority, so
  the system blocks writes and offers repair, restore, retry, or support.

Expected lifecycle states such as loading, auth refresh, local runtime warmup,
package check, entitlement verification, sync retry, or resource preparation are
not errors. Model them as states, not exceptions.

## Failure-To-Recovery Workflow

Before editing code, perform this workflow.

1. **Name the user intent**
   - Identify what the user was trying to do.
   - Keep the original intent available so the flow can resume after recovery.

2. **Locate the first failing producer**
   - Find the first place that produces a missing resource, invalid state,
     unavailable dependency, or thrown exception.
   - Do not start by adding consumer-side catch blocks.

3. **Classify the condition**
   - `expected_pending`: normal lifecycle state, such as loading or warmup.
   - `auto_recoverable`: system can retry, refresh, rebuild, re-download,
     re-index, re-authenticate, re-sync, or switch to an authoritative source.
   - `user_actionable`: user must connect network, sign in, update package,
     free storage, approve permission, or choose a plan.
   - `safety_blocker`: continuing could corrupt data, write under the wrong
     account, bypass entitlement, or use incompatible resources.
   - `programmer_bug`: invariant violation caused by internal code producing an
     impossible state.

4. **Design the recovery flow**
   - For `expected_pending`, expose a loading/preparing state and avoid creating
     downstream objects that require readiness.
   - For `auto_recoverable`, attempt bounded automatic recovery before asking
     the user to do anything.
   - For `user_actionable`, show a product-specific action and route, not raw
     exception text.
   - For `safety_blocker`, stop unsafe writes, provide repair/restore guidance,
     and keep the original intent resumable when possible.
   - For `programmer_bug`, fix the internal producer and add tests that prevent
     the impossible state from being produced.

5. **Resume or close deliberately**
   - After recovery succeeds, continue the original user action automatically.
   - If recovery cannot continue automatically, return the user to a stable
     product surface with a clear next action.

## Prohibited Endpoints

Treat these as code smells in user-facing paths:

- `throw Exception`, `StateError`, `ArgumentError`, or custom exceptions as the
  final branch for loading, readiness, resource lookup, auth, package, network,
  sync, or navigation states.
- UI that renders `error.toString()`, stack traces, provider errors, internal
  enum names, or developer recovery hints.
- `catch (_) { return null; }`, `return []`, default objects, or fake success
  that hides the condition instead of repairing it.
- Fail-closed used as ordinary control flow for pending readiness.
- Retry buttons that repeat the same failing path without changing any
  prerequisite.
- Package/resource/network/auth failures that do not route to package update,
  download, reconnect, sign-in, refresh, or repair flows.

## Recovery Patterns

Use concrete product actions. Prefer names that fit the product rather than
technical failures.

- Missing local resource:
  `load -> classify missing -> check package index -> refresh index -> download/update package -> resume original load`
- Outdated package:
  `detect incompatibility -> open package update surface -> install -> invalidate runtime -> resume`
- Network unavailable:
  `check offline capability -> continue local path if safe -> otherwise show reconnect path -> retry after network`
- Auth/session pending:
  `wait for session refresh -> retry protected read -> if expired, route to sign-in -> resume intent`
- Entitlement pending:
  `refresh entitlement -> use local valid lease if allowed -> otherwise route to account/subscription repair`
- Local data damaged:
  `stop writes -> attempt recoverable cache rebuild or remote restore -> if unsafe, show repair/reset/support path`
- Programmer bug:
  `fix producer -> remove impossible state -> add tests for creation path and user route`

## Audit Checklist

When reviewing code, scan for:

```text
throw
StateError
ArgumentError
Exception
catch
return null
return []
fallback
failClosed
Unavailable
PendingException
AsyncError
error.toString
snapshot.error
```

For each match, answer:

- Is this a true impossible state, or an expected lifecycle state?
- Can an upstream gate prevent this branch from being entered?
- Can the system automatically recover before involving the user?
- If the user must act, what exact product surface completes that action?
- How does the app resume the original intent after recovery?
- Which test proves the user never sees the internal error endpoint?

## Output Standard

When using this skill, report in this shape:

```markdown
### Hygienic Bee Report
- User intent:
- Current failure endpoint:
- Earliest producer:
- Classification:
- Why this should not end as an error:

### Recovery Design
1. Automatic recovery:
2. User-action path:
3. Resume behavior:
4. Safety boundary:

### Code Changes
- Producers to fix:
- State machine/readiness changes:
- UI/product route changes:
- Fallbacks or throws removed:

### Validation
- Unit/provider tests:
- Widget/product-path tests:
- Manual product path:
```

The final design must prove that the branch no longer ends with a developer
error. It must either recover, guide, or safely suspend with a concrete next
step.
