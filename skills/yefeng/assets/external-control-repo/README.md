# __PROJECT_NAME__ Control Repository

This independent Git repository is the 野蜂 execution and governance control plane for `__PROJECT_ID__`. The authoritative product repository remains `__PRODUCT_REPO_ID__` at its recorded Git commits.

Start every control turn by reading:

1. `AGENTS.md`
2. `docs/status.md`
3. `.yefeng/control-plane.json`
4. `.yefeng/series/__SCOPE_ID__/state/control.json`
5. `docs/modules/__SCOPE_ID__/registry.md`
6. open directives, messages, and integration intents

Tracked files hold stable plans, state, events, receipts, decisions, and compact handoffs. Local roots, run logs, assignments, locks, and role outboxes are ignored runtime transport.

Tracked helpers under `scripts/yefeng/` acquire/release the single-writer fence and validate the control repository. Use them from the explicit control root; do not substitute Git's transient `index.lock` for the governance lease.

Product code, normative specifications, public contracts, tests, and release facts do not belong here. Record their product repository paths and exact commits instead.
