---
name: product-facing-frontend
description: Build, modify, redesign, audit, or review frontend UI as real user-facing product surfaces instead of developer reports. Use when Codex creates or changes web apps, dashboards, editors, sidebars, settings pages, AI panels, admin tools, empty states, navigation, or frontend copy; when preventing developer-facing wording such as mock, fixture, readonly, writeback, route matrix, status proof, backend contract, audit report, operation result, or internal IDs from being created in the first place; and when auditing existing UI for these issues only if the user asks, the app already exists, or a broad refactor may leave old surfaces behind.
---

# Product-Facing Frontend

Use this skill before and during frontend implementation. Treat every visible screen as a product surface for the end user, not as a progress report about engineering work.

## Core Rule

Design from the user's job:

- Show what the user can understand, decide, select, edit, confirm, or do next.
- Hide implementation proof, internal state names, test fixtures, transport details, backend contracts, and framework vocabulary.
- Convert internal facts into product language at the view-model or data-source boundary, before rendering.
- Render only real, useful content. Do not fill pages or sidebars with empty module summaries.

## Pre-Build Gate

Before adding UI, answer these questions in your own implementation notes:

1. Who opens this screen?
2. What task are they trying to finish?
3. What is the primary action?
4. What content is real and useful right now?
5. Which technical facts must stay out of the UI?

If a screen cannot answer these questions, simplify the screen before building.

## Forbidden Visible UI

Do not expose these as user-visible text, labels, chips, cards, headings, empty states, tooltips, or sidebars unless the user explicitly asks for a developer/debug view:

- Internal English tokens: `mock`, `fixture`, `readonly`, `writeback`, `text_anchor`, `branch_head`, `route matrix`, `processor`, `repository`, `service`, `schema`, `IPC`, `Tiptap`, `BYOK`, internal issue codes, internal IDs.
- Developer-report Chinese: “安全证明”, “状态矩阵”, “模块入口”, “后端契约”, “操作结果”, “执行结果”, “审计”, “元数据”, “未报告”, “已报告”, “本次已连接”, “本次未连接”.
- Capability reports: “no network attempted”, “renderer cannot see secret”, “mock route”, “readonly policy”, “proof labels”.
- Placeholder/report layouts: generic cards that say what modules might eventually do instead of providing a usable workflow.
- Empty piles: repeated groups such as “0 items”, “0 records”, “0 chapters” when there is no action or useful explanation.

Prefer product terms:

- “待确认”, “可审阅”, “可引用”, “已保存”, “需补充”, “来源待核对”, “手动发起”, “本地处理”.
- “建议”, “候选稿”, “素材”, “资料”, “正文定位”, “章节”, “设置”, “导出”, “下一步”.

## Build Workflow

1. Start from a user workflow, not a status matrix.
2. Keep navigation labels concrete and task-oriented.
3. Give each page one clear primary job.
4. Put developer-only details in code, logs, tests, or diagnostics behind an explicit debug surface.
5. Make empty states useful: explain what is missing, why it matters, and the next user action.
6. Hide empty groups in sidebars and pickers unless the group itself is the action target.
7. Keep AI surfaces framed as suggestions and confirmations, not autonomous execution reports.
8. Make settings pages about user choices and consequences, not integration internals.

## Creation Mode

Use this mode by default when creating new frontend UI.

- Prevent bad UI at design time. Do not create developer-report sections and plan to remove them later.
- Prefer one usable workflow over several explanatory cards.
- Create only the screens, panels, states, and controls needed for the user's task.
- Include empty states only when they help the user act: create, connect, import, select, retry, or configure.
- Use static source review and focused tests to catch forbidden terms before running the app.
- Browser checks are optional for newly created UI unless the repo's normal workflow, the task risk, or the user's request calls for visual verification.

Creation mode succeeds when the implemented source does not introduce developer-report UI in the first place.

## Source-Level Guidance

Map raw states before render:

- Convert transport/runtime states to user language in view models or adapter functions.
- Keep raw enums and backend names out of JSX text.
- Use named label maps for internal tokens.
- Add tests that assert high-risk terms are absent from rendered copy or view-model strings.
- Do not add a render-time sanitizer to hide bad text after the fact; fix the source that created the bad label.

When a technical concept must be shown, explain its product impact:

- Bad: “readonly IPC pending”
- Good: “等待作者确认后再采纳”
- Bad: “writeback candidate”
- Good: “待确认修改建议”
- Bad: “model route matrix”
- Good: “按写作任务选择模型”

## Audit Mode

Use audit mode only when working with existing UI, broad refactors, migrations, reported visual/copy problems, or explicit user requests to inspect pages. In audit mode, inspect reachable pages and panels, not only the page you changed:

- Main navigation pages.
- Sidebars, drawers, filters, popovers, modals, and empty states.
- Settings and diagnostics pages.
- AI/chat/composer panels.
- Low-frequency pages such as export, onboarding, issue review, model configuration, and knowledge/library modules.

For each page verify:

- The page answers “where am I, what can I do, what needs attention?”
- Buttons navigate or act as their labels promise.
- No user-visible developer terms from the forbidden list appear.
- No mixed internal English appears in otherwise localized UI.
- No text is squeezed into vertical columns, clipped, overlapped, or horizontally overflowing.
- Empty groups are hidden or replaced with useful next actions.

## Validation

For newly created UI:

1. Run targeted tests for copy, layout, and view models when present.
2. Run broader tests/typecheck/build appropriate to the repo.
3. Search changed source and relevant test snapshots for high-risk terms.
4. Use browser visual checks only when needed by task risk, repo convention, interactive behavior, or user request.

For existing UI audits or broad refactors:

1. Use a browser to open the local app and walk through relevant reachable pages.
2. Search rendered DOM text or snapshots for high-risk terms.
3. Verify navigation, sidebars, settings, AI panels, and empty states are product-facing.

Useful search pattern:

```text
mock|fixture|readonly|writeback|text_anchor|branch_head|route matrix|repository|service|IPC|Tiptap|BYOK|安全证明|状态矩阵|模块入口|后端契约|操作结果|执行结果|审计|元数据|未报告|已报告|本次未连接|本次已连接
```

## Completion Standard

Do not call frontend work complete merely because implementation compiles. Complete creation work when the source and tests show the UI was designed as a user-facing product surface from the start. Complete audit work when the relevant existing pages have also been inspected and no developer-report surfaces remain visible.
