# 野蜂 Templates

Use these templates only when the project lacks equivalent local docs. 野蜂 does not use self-claiming roles. The total-control thread assigns, launches, resumes, and integrates all top-level roles.

For new-project startup levels, intake, level decisions, role-pool proposals, first-slice contracts, and upgrade checklists, use `startup.md` before using the full launch/resume patterns below.

The recorded startup level is a hard upper bound. The authorization matrix grants authority only for operations already permitted by that level. At Level 1, roles remain `PLANNED`; role assignment/launch, implementation worktrees, heartbeat creation, and product or role merges remain forbidden until a reviewed level transition is recorded.

For `external-git`, read `external-control-repo.md` first. Treat the templates below as embedded defaults unless they explicitly include `control_root` and `product_root`. Resolve governance paths under `control_root`, product paths under the named product repository/worktree, and run logs under the control root.

## Contents

- Total-control and authorization skeletons
- Role assignment and machine state
- Event and communication patterns
- Task registry, directives, and handoffs
- Assigned role, worker, reviewer, launch, and poll prompts
- PowerShell update notes and proposal header

## External Mode Required Overrides

Before using any skeleton in `external-git`, add:

```text
control_plane_mode
control_repo_id
control_root (runtime/local binding)
scope_id
run_epoch
role_id
assignment_id
run_id
product_repo_id
product_root (runtime/local binding)
product_integration_branch
product_baseline_commit
transport_mode
```

Namespace roles, runs, events, messages, and runtime transport by `scope_id`. The product worktree may contain no governance snapshot. Only total-control writes tracked control state; roles use the assignment's exact ignored outbox path.

## Total-Control Document Skeleton

```md
# 野蜂总控

## 1. 文档目的

本文件是项目的顶层协调面，记录目标、推进取向、角色分配原则、集成节奏、跨角色契约和审批门槛。

用户默认只和总控线程对话。总控线程负责分配角色、启动/恢复后台 Codex 会话、路由通信、处理阻塞、整合已审查工作。

## 2. 顶层原则

- 总控分配角色，不允许角色线程自认领。
- 所有跨角色沟通必须进入通信总线。
- 实现型角色默认一角色一 worktree/branch。
- 角色可以部署 subagent，但 subagent 不拥有顶层角色。
- 合并按最小可验证集成点进行。
- 总控线程是唯一可以唤醒、恢复、停止、替换顶层角色的线程。

## 3. 推进取向

- 当前取向：
- 选择理由：
- 明确非目标：

## 4. 权威文件

| 文件 | 作用 |
| --- | --- |
| docs/授权策略.md | 操作授权、审查门槛、用户介入条件 |
| docs/角色分配.md | 人类可读角色分配表 |
| .yefeng/state/roles.json | 机器可读角色状态 |
| .yefeng/state/runs.json | 机器可读进程/会话运行记录 |
| .yefeng/runs/<role>/<run>/assignment.json | 本次角色会话分配清单 |
| docs/并行任务登记.md | checkpoint、写入范围、依赖、状态 |
| docs/总控指令.md | 总控下发给角色的指令 |
| .yefeng/events.jsonl | 机器可读事件流 |
| docs/角色通信/ | 人类可读通信视图 |
| docs/交接报告/ | 临时交接收件箱 |
| docs/总控状态快照.md | 启动/恢复时的短快照 |

## 5. 角色池

| 角色ID | 角色名 | 负责范围 | 默认 worktree | 默认 branch | 必读提案 | 允许写入 | 禁止写入 |
| --- | --- | --- | --- | --- | --- | --- | --- |

## 6. 集成节奏

最小可验证集成点定义：

- 有边界清晰的产物；
- 有验证证据；
- 需要 reviewer 时已有最小审查结论；
- 已写交接报告或结果摘要；
- 无未关闭的阻塞消息或 ACTIVE 指令。

## 7. 执行性总控轮次

总控轮次默认是执行轮次。用户或自动化提示中出现“检查”“巡检”“心跳”“继续”“恢复”时，含义是先检查状态，再执行当前已授权且未阻塞的控制动作。

只有当提示明确写了 `read-only`、`dry-run`、`no launch`、`do not start/resume/merge`，或授权/证据/并行度/冲突确实阻塞时，才只读汇报。

`docs/总控状态快照.md` 中的“下一步待执行队列”不是建议列表。一次总控轮次是排空循环，不是单动作 tick。每次处理完成 run、导入 outbox、裁决阻塞、恢复、启动、合并、刷新基线或提交稳定治理事实后，都必须重新读取权威状态并继续执行下一项已授权、未阻塞、容量允许的动作，直到进入真正空闲。

若没有更高优先级的 run 处理、outbox 路由、阻塞裁决、恢复或合并工作消耗当前循环，总控必须执行队列中所有当前安全且容量允许的动作，而不是只执行第一项后等待下一次心跳；如果不能执行，必须写清 `blocked_by`、`resume_when`、`required_evidence` 和 `wake_target`。

总控心跳是长期保活机制。心跳间隔只是唤醒间隔，不是工作批次边界；20 分钟等待应该发生在排空所有能做的事之后。没有运行角色、没有待执行队列、当前 checkpoint 全部完成，只能得到 `IDLE_OK`，不能因此删除、暂停或关闭心跳。只有用户明确要求停止/暂停/删除/归档/结束野蜂总控循环，或经用户批准的授权策略要求停机时，才可停止心跳。空跑时报告已检查的事实和下一次唤醒条件，并保持现有 cadence。

## 8. 阻塞处理

角色阻塞时必须写清：

```text
blocked_by:
resume_when:
required_evidence:
wake_target:
safe_same_role_work_available:
```

总控线程判定 `resume_when` 满足后，使用记录的 session_id 恢复目标角色。

## 9. 变更记录
```

## Authorization Policy Skeleton

```md
# 授权策略

## 1. 文档目的

本文件记录野蜂工作中的自动化授权。总控线程、角色线程、worker subagent 和 reviewer subagent 都必须按本文件行动。

## 2. 授权类别

| 类别 | 含义 |
| --- | --- |
| AUTO | 范围内自动执行 |
| SCOPED | 仅在指定范围内自动执行，越界转 ASK |
| AGENT_REVIEW | 需要独立 reviewer subagent 通过后自动推进 |
| ASK | 执行前询问用户 |
| FORBID | 禁止执行 |

## 3. 默认授权矩阵

下表的 `AUTO` / `SCOPED` 只在当前已记录启动档位允许该操作时生效，不能越过启动档位。`LEVEL_1_GOVERNANCE_BOOTSTRAP` 中所有角色保持 `PLANNED`。

| 操作 | 授权 | 自动范围 | 需要证据 | 越界处理 |
| --- | --- | --- | --- | --- |
| 总控分配角色 | AUTO | 仅 LEVEL_3；docs/角色分配.md; .yefeng/state/roles.json | assignment_id + 事件 | ASK |
| 启动/恢复 Codex 角色会话 | AUTO | 仅 LEVEL_3；已分配角色；max_parallel 内 | run_id + session_id/日志 | ASK |
| 停止/替换失效角色会话 | SCOPED | 仅 LEVEL_3；EXPIRED/FAILED 或总控明确暂停 | 原 run 记录 | ASK |
| 创建角色 worktree/branch | SCOPED | 仅 LEVEL_3；worktrees/<role_id>; codex/yefeng/<role_id>/** | git 输出 + 状态记录 | ASK |
| 修改角色分配表 | SCOPED | 总控线程；角色仅能写本角色状态反馈字段 | 事件 + diff | ASK |
| 写通信事件 | AUTO | .yefeng/events.jsonl; .yefeng/messages/** | message_id | ASK |
| 导入角色本地 outbox | AUTO | 角色 worktree 的 `.yefeng/outbox/*.json` 到共享事件流 | message_id + source_file | ASK |
| 更新通信 Markdown 视图 | AUTO | docs/角色通信/** | 对应 message_id | ASK |
| 写交接报告 | AUTO | docs/交接报告/** | 报告文件 | ASK |
| 写总控指令 | SCOPED | 总控线程创建/关闭；目标角色只写反馈字段 | directive_id | ASK |
| 部署 worker subagent | AUTO | 本角色任务范围 | 子任务说明 | ASK |
| 部署 reviewer subagent | AUTO | 本角色审查门槛 | 最小审查结论 | ASK |
| proposal 审核 | AGENT_REVIEW | 对应角色提案 | reviewer 结论 | 不通过则修复重审 |
| checkpoint 实现 | AGENT_REVIEW | 已批准范围 | 测试/验证 + reviewer | 不通过则修复重审 |
| merge 到集成线 | AGENT_REVIEW | 仅 LEVEL_3；MERGE_READY 角色分支 | diff + 测试 + reviewer | ASK |
| 清理已合并 worktree/branch | SCOPED | 已合并且无未保存产物 | merge 记录 | ASK |
| 安装依赖 | SCOPED | 已批准技术栈 | lockfile diff + 构建验证 | ASK |
| 使用真实密钥/外部账号 | ASK | 无 | 用户确认 | FORBID |
| 发布/云同步/外部写入 | ASK | 无 | 用户确认 | FORBID |
| 删除非野蜂运行产物 | ASK | 无 | 用户确认 | FORBID |
| 使用 dangerously bypass | ASK | 无 | 用户确认 | FORBID |

说明：

- `codex exec` 不应传入交互 CLI 专用的 `-a/--ask-for-approval` 参数；只使用 `codex exec --help` 中存在的参数。
- `codex exec resume` 若没有 `-C`，必须从角色 worktree 目录发起；恢复前先创建 run 日志目录，避免 stdout/stderr 重定向先失败。
- Windows helper 生成前必须解析并验证 Codex CLI 的显式路径。优先使用可执行的 `codex.cmd`/npm shim；若 `Get-Command codex` 指向 `WindowsApps\codex.exe`，不要把它当作后台启动命令。helper 中使用 `& $codexCommand exec ...`，并把 `codex_command` 写入 run metadata。若日志出现 `WindowsApps\codex.exe` access denied，视为 launcher 解析失败，修正后按同一 assignment 重试。
- Windows 项目若有中文路径、中文文件名或中文治理文档，生成的 launch/resume helper 脚本必须先设置 UTF-8 控制台编码，再读取 prompt 或启动 `codex exec`。建议脚本开头加入：

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$env:PYTHONIOENCODING = 'utf-8'
try { chcp.com 65001 > $null } catch {}
```

- 若 JSONL、stdout 或 stderr 中出现中文文件名乱码，不要用乱码路径当作权威事实；先按 manifest/prompt 中的显式路径读取，并修正脚本编码后重跑小探针。
- 默认记录 sandbox mode。Windows 上总控启动第一批实现角色前应先运行一次 sandbox probe：用 `workspace-write` 启动极小 `codex exec`，要求打印当前目录；若出现 `CreateProcessAsUserW failed: 5`，把 `workspace-write-shell=false` 写入状态快照或 runs 状态。之后需要 shell 的实现角色在独立 worktree 内使用 `-s danger-full-access`，但不得使用 approval bypass。
- `.yefeng/runs/`、`.yefeng/assignment.json`、`.yefeng/outbox/` 默认是本地运行/运输材料，建议加入 `.gitignore`；长期事实写入状态 JSON、事件 JSONL、通信视图和交接摘要。

## 4. 用户介入条件

- 扩大授权策略；
- 使用真实密钥、外部账号、付费服务、发布或云写入；
- 删除或覆盖非本任务创建的文件；
- reviewer 不通过但角色想继续；
- 总控、授权策略、登记表和指令无法裁决的冲突。

## 5. 模型/推理档位

- highest：总控整合、架构、授权、安全、合并、关键 reviewer、困难根因定位。
- high：共享实现、迁移、编辑器/版本/AI 逻辑、非平凡重构。
- medium：边界清晰实现、测试、局部文档、验证。
- economy：机械搜索、格式整理、依赖清点、低风险摘要。

不确定时升档。关键 reviewer 不应弱于被审查任务的风险。
```

## Role Assignment Board Skeleton

```md
# 角色分配

## 1. 文档目的

本文件记录总控线程分配给后台 Codex 会话的顶层角色。角色线程不得自认领，也不得互相调度。

机器可读状态见 `.yefeng/state/roles.json`。本文件是人类可读视图；两者冲突时，总控线程必须暂停调度并先校准。

## 2. 状态约定

| 状态 | 含义 |
| --- | --- |
| PLANNED | 角色存在但尚未分配 |
| ASSIGNED | 已由总控分配，尚未运行 |
| RUNNING | 对应进程/会话正在运行 |
| WAITING_REVIEW | 等待本角色 reviewer 结果 |
| BLOCKED | 等待记录的恢复条件 |
| READY_TO_RESUME | 总控判定阻塞已解除，可恢复 |
| REPORT_READY | 交接/证据已就绪，无安全续作 |
| MERGE_READY | 审查和验证齐备，可由总控集成 |
| DONE | 本轮范围完成 |
| FAILED | 进程失败或输出无效 |
| EXPIRED | 租约过期或进程死亡，可替换 |

## 3. 分配表

| 优先级 | 角色ID | 角色 | 状态 | assignment_id | session_id | process_id | run_id | worktree | branch | 当前 checkpoint | owned_scope | forbidden_scope | blocked_by | resume_when | required_evidence | wake_target | last_seen | lease_expires_at | last_output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | INTEGRATOR | 总控线程 | RUNNING |  | 当前总控线程 |  |  | 项目根 | main/integration | orchestration | 总控、分配、通信、指令、集成 | 直接实现未分配源码任务 |  |  |  |  |  |  |  |
| 1 | COORD-P | 产品与信息架构 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-产品与信息架构.md | 未授权源码和其他角色文件 |  |  |  |  |  |  |  |
| 2 | COORD-D | 数据与存储 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-数据与存储.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |
| 3 | COORD-EV | 编辑器与版本 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-编辑器与版本.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |
| 4 | COORD-A | AI 调度与上下文 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-AI调度与上下文.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |
| 5 | COORD-K | 知识库深化 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-知识库深化.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |
| 6 | COORD-G | 工程化与发布 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-工程化与发布.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |
| 7 | COORD-Q | 质量与验证 | PLANNED |  |  |  |  |  |  |  | docs/系列提案-质量与验证.md; assigned worktree | 其他角色 worktree |  |  |  |  |  |  |  |

## 4. 总控调度规则

1. 只有总控线程可把角色从 `PLANNED` 改为 `ASSIGNED`。
2. 只有总控线程可启动或恢复顶层角色会话。
3. 角色线程只能更新本角色进度、阻塞、证据和交接字段。
4. 角色线程不能唤醒其他角色，只能写消息。
5. 租约过期或进程死亡后，总控线程把角色标为 `EXPIRED` 并分配新会话。
```

## Machine State Skeleton

`.yefeng/state/roles.json`

```json
{
  "version": 1,
  "updated_at": "YYYY-MM-DDTHH:mm:ssZ",
  "updated_by": "INTEGRATOR",
  "roles": [
    {
      "role_id": "COORD-D",
      "role_name": "数据与存储",
      "assigned_by": "INTEGRATOR",
      "assignment_id": "assign-YYYYMMDD-HHMMSS-COORD-D",
      "session_id": "",
      "process_id": null,
      "run_id": "",
      "state": "ASSIGNED",
      "worktree": "worktrees/COORD-D",
      "branch": "codex/yefeng/COORD-D/D0",
      "owned_scope": ["docs/系列提案-数据与存储.md", "worktrees/COORD-D"],
      "forbidden_scope": ["其他角色 worktree", "未授权总控文件"],
      "current_checkpoint": "D0",
      "blocked_by": "",
      "resume_when": "",
      "required_evidence": "",
      "wake_target": "",
      "last_seen": "",
      "lease_expires_at": "",
      "last_output": ""
    }
  ]
}
```

`.yefeng/state/runs.json`

```json
{
  "version": 1,
  "runs": [
    {
      "run_id": "run-YYYYMMDD-HHMMSS-COORD-D",
      "role_id": "COORD-D",
      "assignment_id": "assign-YYYYMMDD-HHMMSS-COORD-D",
      "session_id": "",
      "process_id": null,
      "command": "codex exec ...",
      "cwd": "worktrees/COORD-D",
      "stdout_jsonl": ".yefeng/runs/COORD-D/run-.../stdout.jsonl",
      "stderr": ".yefeng/runs/COORD-D/run-.../stderr.log",
      "last_message": ".yefeng/runs/COORD-D/run-.../last-message.md",
      "assignment_manifest": ".yefeng/runs/COORD-D/run-.../assignment.json",
      "sandbox_mode": "workspace-write",
      "started_at": "",
      "ended_at": "",
      "exit_code": null,
      "status": "RUNNING"
    }
  ]
}
```

Per-run assignment manifest for every new assignment, stored at `.yefeng/runs/<role_id>/<run_id>/assignment.json` in compatible embedded mode or `.yefeng/runs/<scope_id>/<role_id>/<run_id>/assignment.json` in namespaced mode, and optionally copied to the role worktree as `.yefeng/assignment.json`. This is not a migration requirement for existing unnamespaced embedded records:

```json
{
  "version": 1,
  "control_plane_mode": "embedded",
  "control_repo_id": "project-control",
  "scope_id": "default",
  "run_epoch": 1,
  "assignment_id": "assign-YYYYMMDD-HHMMSS-COORD-D",
  "run_id": "run-YYYYMMDD-HHMMSS-COORD-D",
  "role_id": "COORD-D",
  "role_name": "数据与存储",
  "checkpoint": "D0",
  "assigned_by": "INTEGRATOR",
  "control_root": "D:/project",
  "product_repo_id": "project",
  "product_root": "D:/project",
  "product_baseline_commit": "<exact-sha>",
  "worktree": "D:/project-worktrees/COORD-D",
  "branch": "codex/yefeng/COORD-D/D0",
  "owned_scope": ["src/data/**", "docs/交接报告/**", ".yefeng/outbox/**"],
  "forbidden_scope": ["docs/角色分配.md", ".yefeng/state/**", "其他角色 worktree"],
  "outbox_dir": ".yefeng/outbox",
  "handoff_dir": "docs/交接报告",
  "sandbox_mode": "workspace-write",
  "created_at": "YYYY-MM-DDTHH:mm:ssZ"
}
```

## Event JSONL Pattern

Each line in `.yefeng/events.jsonl` is one JSON object.

```json
{
  "event_id": "evt-YYYYMMDD-HHMMSS-xxxx",
  "created_at": "YYYY-MM-DDTHH:mm:ssZ",
  "type": "QUESTION",
  "from": "COORD-A",
  "to": "COORD-D",
  "role_id": "COORD-A",
  "checkpoint": "A1",
  "message_id": "msg-YYYYMMDD-HHMMSS-COORD-A-COORD-D",
  "blocking": true,
  "blocked_role": "COORD-A",
  "blocked_checkpoint": "A1",
  "blocked_by": "COORD-D schema contract",
  "resume_when": "COORD-D publishes reviewed schema contract D0",
  "required_evidence": "reviewer-passed schema contract summary",
  "wake_target": "COORD-A",
  "status": "OPEN",
  "payload": "Question or summary here",
  "related_files": ["docs/系列提案-AI调度与上下文.md"],
  "evidence": []
}
```

Event types:

```text
CONTROL_BOOTSTRAPPED
ROLE_ASSIGNED
ROLE_STARTED
ROLE_OUTPUT
ROLE_BLOCKED
ROLE_READY_TO_RESUME
ROLE_DONE
QUESTION
ANSWER
BLOCKER
CONTRACT_CHANGE
REVIEW_REQUEST
REVIEW_RESULT
HANDOFF
BASELINE_UPDATED
INTEGRATION_INTENT
PRODUCT_COMMITTED
PRODUCT_VERIFIED
CONTROL_COMMITTED
RECONCILIATION_REQUIRED
IMPORT_RECEIPT
RECOVERY_STARTED
RECOVERY_COMPLETED
RESUME_NOTICE
USER_DECISION_REQUIRED
DIRECTIVE
```

## Role Communication README

```md
# 角色通信

本目录是 `.yefeng/events.jsonl` 和 `.yefeng/messages/` 的人类可读视图。角色之间可以写消息，但不能互相唤醒或调度。所有恢复、停止、替换、重新分配都由总控线程执行。

实现型角色通常在自己的 worktree 内写 `.yefeng/outbox/<message_id>.json`。总控线程导入这些 outbox 后，才写入共享 `.yefeng/events.jsonl` 和本目录视图。角色不要并发直接追加共享事件流，除非总控明确提供了序列化写入机制。

导入完成后，除非项目明确要归档运输消息，否则不要把角色 worktree 的 `.yefeng/outbox/` 合并进主线。共享事件流和本目录视图才是长期事实。

## 文件

- `总控路由.md`：总控已路由、待路由、已关闭消息。
- `<role_id>.inbox.md`：发给某角色的消息视图。
- `<role_id>.outbox.md`：某角色发出的消息视图。

## 消息状态

| 状态 | 含义 |
| --- | --- |
| OPEN | 已写入，待总控路由 |
| ROUTED | 总控已决定处理方式 |
| WAKING_TARGET | 总控将恢复目标角色 |
| ANSWERED | 已有回答 |
| BLOCKING | 阻塞已登记 |
| CLOSED | 稳定事实已回写，消息关闭 |

## 消息模板

| message_id | 状态 | from | to | 类型 | blocking | checkpoint | 摘要 | resume_when | required_evidence | 总控路由 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
```

## Parallel Task Registry Skeleton

```md
# 并行任务登记

## 1. 文档目的

记录 checkpoint、写入范围、依赖、审查证据、合并状态和阻塞关系。角色是谁由 `docs/角色分配.md` 管；消息交流由通信总线管；总控裁决由 `docs/总控指令.md` 管。

## 2. 状态约定

| 状态 | 含义 |
| --- | --- |
| DRAFT | 草案 |
| REVIEW | 审查中 |
| APPROVED | 可实现 |
| ACTIVE | 正在做 |
| BLOCKED | 阻塞 |
| REVIEWED | 已通过审查 |
| MERGE_READY | 可集成 |
| DONE | 已完成 |
| PAUSED | 暂停 |

## 3. 当前任务

| ID | checkpoint | 类型 | 状态 | assigned_role | worktree/branch | 写入范围 | 禁止范围 | 前置依赖 | 影响契约 | 预期产物 | 验证方式 | reviewer 结论 | 阻塞/消息 | 交接说明 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
```

## Control Directive Board Skeleton

```md
# 总控指令

## 1. 文档目的

本文件记录总控线程下发给角色线程的当前有效指令。它是向下调度面，不是交接收件箱，也不是第二份总控。

## 2. 状态

| 状态 | 含义 |
| --- | --- |
| ACTIVE | 总控已下发，目标角色必须先处理 |
| ACKNOWLEDGED | 角色已确认 |
| APPLIED | 角色已按指令完成 |
| SUPERSEDED | 被新指令替代 |
| CLOSED | 稳定事实已回写，指令结束 |

## 3. 当前指令

| ID | 状态 | 创建时间 | 来源 | 目标角色 | 目标 checkpoint | 涉及契约/文件 | 总控裁决 | 要求动作 | 允许写入范围 | 恢复条件 | 角色反馈/交接 | 关闭条件 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
```

## Handoff Inbox Pattern

```md
# 交接报告收件箱

本目录只保存尚未整合的临时交接报告。总控线程处理报告后，必须把稳定事实回写到角色分配、任务登记、总控指令、总控文档、通信总线或对应提案，然后删除或清空已处理报告。

交接报告不是角色锁，也不是长期事实源。若交接报告声称完成但缺少授权策略要求的 reviewer 闭环，总控应退回对应角色补审，不登记为完成。

临时文件：

- `YYYYMMDD-HHMM-<role>-<checkpoint>.md`

消化摘要规则：

- 不复制长报告全文。
- 只保留角色/checkpoint、处理时间、状态变化、变更范围、稳定事实、阻塞/指令、下一责任人。
- reviewer 过程材料只保留最小审查结论。
```

## Handoff Report Template

```md
# 交接报告：<role> / <checkpoint>

状态：待总控整合
角色：
assignment_id：
session_id：
run_id：
checkpoint：
生成时间：

## 1. 已完成修改

- 修改文件：
- 涉及章节：
- 新增或调整内容：

## 2. 验证证据

- 命令：
- 结果：
- 未运行原因：

## 3. Reviewer 结论

- reviewer：
- 范围：
- 结论：
- 返工项：
- 重审状态：
- 解锁/阻塞影响：

## 4. 跨角色影响

- 影响契约：
- 影响角色：
- 已写消息：
- 需要总控路由：

## 5. 阻塞或恢复条件

blocked_by：
resume_when：
required_evidence：
wake_target：
safe_same_role_work_available：

## 6. 总控回写建议

- 任务登记：
- 角色分配：
- 总控指令：
- 通信消息：
- 状态快照：

## 7. 建议消化摘要

- 一句话摘要：
- 状态变化：
- 必须登记的稳定事实：
- 可删除的临时细节：
```

## Assigned Role Prompt Pattern

Use this for a top-level role session launched by the total-control thread.

```text
请使用 yefeng / 野蜂。工作目录是 <worktree-or-project-root>。

你不是自认领角色。你已被总控线程分配为：

- role_id: <role_id>
- role_name: <role_name>
- assignment_id: <assignment_id>
- run_id: <run_id>
- assignment_manifest: <exact-control-run-root>/assignment.json
- control_plane_mode: <embedded-or-external-git>
- control_repo_id: <control-repo-id>
- control_root: <absolute-control-root>
- scope_id / run_epoch: <scope-id> / <epoch>
- product_repo_id: <product-repo-id>
- product_root: <absolute-product-root>
- product_baseline_commit: <exact-sha>
- session_id: <session_id-if-known>
- worktree: <worktree>
- branch: <branch>
- checkpoint: <checkpoint>

你不能分配自己或其他顶层角色，不能唤醒/恢复其他角色，不能接第二个顶层角色。跨角色沟通必须写入 assignment manifest 指定的 outbox；由总控校验并导入共享通信总线。若 external control root 不可写，使用 worktree-local outbox，不得退化为隐藏聊天状态或自行扩大 sandbox。

注意：embedded worktree 中的治理文件可能是旧快照；external-git worktree 中可能根本没有治理文件。external/new-format embedded 必须核对 scope/epoch；legacy embedded 缺少 scope 时只在内存映射为 `default`，不得回写，也不得伪造缺失 epoch。任何现有 role/assignment/run 身份缺失或歧义都必须停止恢复。以本提示、assignment manifest 和 control root 中当前权威状态为依据。不要修改总控 tracked state。

允许写入：
<owned_scope>

禁止写入：
<forbidden_scope>

先从 `<control_root>` 读取：
1. 授权策略
2. 角色分配与当前 epoch 的机器状态
3. 任务登记
4. 总控指令
5. 本角色 inbox
6. 总控文档和状态快照
7. 最新相关事件与未完成 operation
8. <your-series-doc>

再从 `<product_worktree>` 读取任务相关产品规范、源码和测试。

如果存在点名你的 ACTIVE 指令或 blocking message，先处理它。

任务：
<specific assignment>

你可以按授权策略部署 worker/reviewer subagent。subagent 只属于你的角色，不拥有顶层角色。

若阻塞，必须写清：
blocked_by:
resume_when:
required_evidence:
wake_target:
safe_same_role_work_available:

完成后：
- 把交接和 outbox 写入 assignment manifest 指定的 runtime transport 路径；
- 汇报修改文件、验证证据、reviewer 结论、阻塞/恢复条件、建议总控回写；
- 不要等待总控聊天回复做隐藏状态。
```

## Worker Prompt Pattern

```text
你是 <role_id> 角色线程部署的 worker subagent，不是野蜂顶层角色。

你的唯一任务范围：
<task>

允许写入：
<scope>

禁止写入：
<forbidden>

你不是单独在工作区中工作，不要回退他人修改。完成后向 <role_id> 汇报：
- 修改文件
- 验证方式和结果
- 风险/冲突
- 是否需要 reviewer
```

## Reviewer Prompt Pattern

```text
你是 <role_id> 角色线程部署的独立 reviewer subagent。你不是作者，也不是野蜂顶层角色。

审查范围：
<scope>

检查：
- 是否符合授权策略和写入范围；
- 是否满足 checkpoint 目标；
- 是否有未登记跨角色契约变化；
- 测试/验证证据是否足够；
- 是否可以解锁 APPROVED / DONE / MERGE_READY。

输出最小审查结论：
- reviewer:
- scope:
- verdict: pass / fail / needs_changes
- required_fixes:
- re_review_needed:
- unlock_or_block_effect:
```

## Total-Control Launch Prompt Pattern

Only use this launch pattern after the project has recorded `LEVEL_3_FULL_PARALLEL_YEFENG`.

```text
作为野蜂总控线程，读取授权策略、角色分配、任务登记、总控指令、通信总线、状态快照和交接报告。

先解析并验证 `control_plane_mode`、`control_repo_id/control_root`、`scope_id/run_epoch`、产品 repo 映射和精确 baseline。external-git 下从控制仓读取治理状态，使用显式 `git -C` 操作产品仓；不得从当前目录或兄弟目录猜测根。

这是 LEVEL_3 执行轮次，不是只读计划。只有已记录启动档位允许、且操作已授权、未阻塞、容量允许时，才把角色分配并启动起来；不要让通用授权越过档位门槛。

目标：
<user goal>

请执行总控职责：
1. 选择下一批可并行角色，数量不超过 <max_parallel>；
2. 为实现型角色创建独立 worktree/branch；
3. 写入 docs/角色分配.md 和 .yefeng/state/roles.json；
4. 为每个角色生成 assignment.json 和 assigned role prompt；
5. 用 codex exec 启动后台角色会话；不要传 `-a/--ask-for-approval`；
6. 从 JSONL 的 `thread.started.thread_id` 解析 session_id；
7. 记录 run/session/process/log/last-message/prompt/assignment/sandbox；
8. 写 ROLE_ASSIGNED / ROLE_STARTED 事件；
9. 刷新 docs/总控状态快照.md，把未执行动作只保留在仍被阻塞或容量不足的队列中；
10. 给用户报告实际启动了什么、等待什么、仍阻塞什么。
```

## Total-Control Poll / Resume Prompt Pattern

```text
作为野蜂总控线程，检查后台角色会话、通信总线、阻塞条件、交接报告、reviewer 证据和 merge-ready 分支。

先取得唯一写者 fence，核对当前 epoch、预期 control HEAD、各 product HEAD 与所有未完成 operation。external-git 下分别报告控制仓和产品仓，不得把跨仓更新描述为原子提交。

先强制执行已记录启动档位。LEVEL_1 只排空治理初始化动作；不得分配/启动角色、创建实现 worktree、启动 heartbeat 或 merge。LEVEL_2 仅允许总控单线程范围。

这是执行轮次，不是只读巡检。除非用户明确说 read-only/dry-run/no launch/do not start/resume/merge，否则检查后必须进入排空循环：执行当前已授权、未阻塞、容量允许的控制动作；每完成一项就重新计算队列并继续，直到没有可执行动作、容量被运行角色占满、需要用户决策，或出现明确阻塞。

请执行：
1. 处理已完成 run；
2. 更新 roles.json、runs.json、docs/角色分配.md；
3. 导入角色 worktree 的 `.yefeng/outbox/*.json` 并路由 OPEN 消息；
4. 判断 BLOCKED 角色的 resume_when 是否满足；
5. 对 READY_TO_RESUME 角色，先更新其 worktree 基线，再从该 worktree 目录使用 session_id 恢复；
6. 对 MERGE_READY 角色检查 reviewer/验证证据，排除 `.yefeng/assignment.json` 和 `.yefeng/outbox/**` 后集成；
7. 集成后写 BASELINE_UPDATED 事件并唤醒受影响角色；
8. 如果本轮没有更高优先级工作消耗当前循环，读取状态快照/任务登记中的下一步待执行队列，执行所有当前安全且容量允许的动作：分配、启动、恢复、集成，或写出具体阻塞；
9. 每次状态变化后重新进入步骤 1；刷新 docs/总控状态快照.md 时，只把仍未满足条件、容量不足、依赖运行中角色、需要 ASK 或因时间预算明确延后的项目留在队列中；
10. 更新治理 JSON 时使用可重跑的属性更新方式；PowerShell 中不要假设 `ConvertFrom-Json` 后的对象能直接赋不存在的属性，必要时用 `[ordered]` hashtable 或 `Add-Member -Force`；
11. 生成 Markdown 治理视图时，避免双引号 here-string 吃掉反引号或 `$()`；优先用单引号 here-string + `__PLACEHOLDER__` 替换，并读回检查没有 `__PLACEHOLDER__`、`$sessionId`、`$roleCommit`、`$(` 等残留；
12. 将稳定治理事实以显式 allowlist 提交到控制仓：machine state、event/receipt、任务登记、角色分配、通信路由、指令、交接摘要和状态快照应形成同一稳定 snapshot；不得把未知 dirty 文件顺手提交；
13. 分别运行 control repo 和每个 affected product repo 的 diff/status 检查。只有被刻意忽略的运行运输文件可忽略；不得用一个笼统 clean 结论替代双仓事实；
14. 若没有任何可执行工作，报告 `IDLE_OK`，说明已检查 running roles、outbox、merge-ready、ready-to-resume、active directives、dirty governance；若已有当前档位授权的 heartbeat，则保持 active，否则报告 `not enabled by startup-level gate`；
15. 汇报本轮实际执行的动作、仍阻塞的问题、提交/合并 commit、工作区是否干净、heartbeat 档位状态和下一次触发条件；不要只汇报“下一步应做 X”。如果 X 已被当前档位授权、未阻塞且容量允许，本轮必须执行 X；不要因为空闲而删除/暂停已有且获授权的 heartbeat。
```

### PowerShell Governance Update Notes

```powershell
function Set-PropertyValue($object, [string] $name, $value) {
  if ($object.PSObject.Properties[$name]) {
    $object.$name = $value
  } else {
    $object | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
  }
}

$template = @'
# 总控状态快照

- session: `__SESSION_ID__`
- role commit: `__ROLE_COMMIT__`
'@

$text = $template.Replace('__SESSION_ID__', $sessionId).Replace('__ROLE_COMMIT__', $roleCommit)
if ($text -match '__[A-Z0-9_]+__|\$sessionId|\$roleCommit|\$\(') {
  throw 'Generated governance Markdown still contains unresolved placeholders or script fragments.'
}
```

## Series Proposal Header

```md
状态：DRAFT
所属阶段：
负责范围：
主要产物：
前置依赖：
阻塞对象：
写入范围：
审批门槛：
验证方式：
```
