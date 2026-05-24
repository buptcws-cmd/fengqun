# Yefeng Templates

Use these templates only when the project lacks equivalent local docs.

## Total-Control Document Skeleton

```md
# 系列提案：全周期总控

## 1. 文档目的

说明项目定位、当前推进模式，以及本文件是唯一协调面。

## 2. 顶层原则

- 最终架构先行 / MVP 迭代 / 研究探索 / 修复系列
- 先提案后实现
- 小 checkpoint 推进
- 并行不等于抢跑

## 3. 状态约定

| 状态 | 含义 | 是否可实现 |
| --- | --- | --- |
| DRAFT | 草案 | 否 |
| REVIEW | 审查中 | 否 |
| APPROVED | 已批准 | 是 |
| ACTIVE | 正在做 | 是 |
| BLOCKED | 阻塞 | 否 |
| DONE | 已完成 | 不需要 |
| PAUSED | 暂停 | 否 |

## 4. 文档维护约束

列出总控、授权策略、角色认领表、登记表、总控指令、交接报告收件箱和各系列提案。

## 5. 能力地图或范围边界

最终架构项目写最终能力地图；MVP 项目写范围边界。

## 6. 开发轨道

| 轨道 | 代号 | 负责内容 | 可并行性 |
| --- | --- | --- | --- |

## 7. 依赖约束

强依赖链、允许并行、禁止并行、工程初始化规则。

## 8. Checkpoint 池

当前建议先启动、第一批实现候选、深层能力候选。

## 9. 审批门槛

Proposal 通过标准、Implementation 完成标准、验证证据格式。

## 10. 冲突处理

写入范围冲突、契约冲突、目标变化处理顺序，以及总控指令下发/角色恢复机制。

## 11. 变更记录
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

## Authorization Policy Skeleton

```md
# 授权策略

## 1. 文档目的

本文件记录系列提案和后续开发中的操作授权。所有对话、协调者、subagent、reviewer 和最终整合者都必须先读取本文件，再决定是否可以自动执行、需要 agent 审核，还是必须询问用户。

## 2. 授权模式

| 模式 | 含义 |
| --- | --- |
| AUTO | 范围内自动执行 |
| SCOPED | 仅在指定范围内自动执行，越界转 ASK |
| AGENT_REVIEW | 需要独立 reviewer subagent 通过后自动推进 |
| ASK | 执行前询问用户 |
| FORBID | 禁止执行 |

审核路径由授权模式决定：`ASK` 表示用户或指定人工审核；`AGENT_REVIEW` 表示用户已授权当前系列协调者自行部署独立 reviewer subagent。最终整合者只整合 reviewer 已通过证据、处理冲突和回写共享状态，不作为常规默认 reviewer。

## 3. 默认授权矩阵

| 操作 | 授权模式 | 自动范围 | 需要证据 | 越界处理 |
| --- | --- | --- | --- | --- |
| 修改系列提案文档 | SCOPED | 本角色 owned proposal | diff + 交接报告 | ASK |
| 修改角色认领 | SCOPED | 仅本角色认领/状态字段 | 认领记录 | ASK |
| 修改总控指令 | SCOPED | 整合者创建/关闭指令；被指令点名的角色只能写入本角色确认/反馈字段 | 指令 ID + 来源报告 | ASK |
| 写交接报告 | AUTO | docs/交接报告/本角色报告 | 报告文件 | ASK |
| 部署 subagent | AUTO | 本角色子任务 | 子任务说明 | ASK |
| 管理本角色 heartbeat | SCOPED | 当前对话线程；有具体恢复条件且无可推进任务时启用，主动执行时暂停，角色完成后停止 | 当前 blocker 或恢复条件说明 | ASK |
| 刷新角色软租约 | AUTO | 本角色 `last_seen`、`lease_expires_at`、`heartbeat_status` | 进展或等待状态说明 | ASK |
| proposal 审核 | AGENT_REVIEW | 当前协调者部署独立 reviewer subagent | 最小审查结论 | 不通过则修复后重新送审 |
| proposal 进入 APPROVED | AGENT_REVIEW | reviewer 通过 + 无 BLOCKED | 最小审查结论 + 总控回写 | ASK |
| 实现 checkpoint | AGENT_REVIEW | 相关 proposal APPROVED 后 | 测试/验证证据 | 不通过则修复后重新送审 |
| worktree 创建/合并/清理 | AGENT_REVIEW | 本 checkpoint worktree | 测试 + 最小审查结论 | 不通过则修复后重新送审 |
| git 初始化/基线提交 | SCOPED | 当前项目根目录 | 命令输出 + 状态记录 | ASK |
| 安装依赖 | SCOPED | 已批准技术栈 | lockfile diff + 构建验证 | ASK |
| 使用真实密钥/外部账号 | ASK | 无 | 用户确认 | FORBID |
| 发布/云同步/外部写入 | ASK | 无 | 用户确认 | FORBID |
| 删除非本任务创建文件 | ASK | 无 | 用户确认 | FORBID |

## 4. Agent 审核门槛

Proposal 通过：

- 若门槛为 `AGENT_REVIEW`，由当前系列协调者部署 reviewer；若门槛为 `ASK`，交给用户或指定人工审核；
- reviewer 不是 proposal 作者；
- 检查目标、范围、依赖、契约、验证方式、阻塞对象；
- 无未登记的跨模块冲突；
- 输出“通过/不通过/需修改”。
- 若不通过或需修改，协调者先修复并重新部署 reviewer；只有无法修复、缺少依赖、跨角色冲突或想无视 reviewer 继续时才转 `BLOCKED` / `ASK`。

Implementation 通过：

- 若门槛为 `AGENT_REVIEW`，由当前系列协调者部署 reviewer；若门槛为 `ASK`，交给用户或指定人工审核；
- reviewer 不是实现者；
- 检查 diff、测试、lint/build、手动路径、安全边界、文档回写；
- 无未授权写入或未登记契约变化；
- 输出“通过/不通过/需修改”。
- 若不通过或需修改，实现者先修复并重新部署 reviewer；只有无法修复、缺少依赖、跨角色冲突或想无视 reviewer 继续时才转 `BLOCKED` / `ASK`。

## 5. 用户介入条件

遇到以下情况必须 ASK：

- 扩大授权策略本身；
- 真实 API Key、外部账号、云服务、支付、发布；
- 删除或覆盖不属于本任务创建的文件；
- 冲突无法由总控、授权策略、登记表和总控指令裁决；
- reviewer subagent 给出不通过但协调者想继续。

## 6. 角色 heartbeat

每个系列协调者可以管理自己所在对话线程的 heartbeat。heartbeat 只能唤醒创建它的对话，不能跨对话唤醒其他角色，因此不需要单独的共享心跳文档。

- 仅在等待依赖、reviewer、其他角色必要产物、总控指令或用户/人工审核决策等具体恢复条件，且本角色无可推进任务时启用；
- 正在主动执行任务时暂停或不启动；
- 活跃任务用软租约续期，不用 heartbeat 打断执行；长任务可设置较长 `lease_expires_at`；
- 不因交接报告尚未被消化而单独启用；
- 醒来后读取授权策略、角色认领、任务登记、总控指令、总控、交接报告和本角色提案；
- 角色 DONE 后停止。
```

## Role Claim Board Skeleton

```md
# 角色认领

## 1. 文档目的

本文件记录多对话并行时的顶层角色认领情况。新对话使用 yefeng 时，如果用户未指定角色，应先读取本文件并自动认领一个 `OPEN` 角色。

`INTEGRATOR` 是最高优先级角色，优先级固定为 0。多对话执行开始前必须先有且只能有一个 `INTEGRATOR` 处于 `CLAIMED` 或 `ACTIVE`；如果没有，新执行对话应先认领 `INTEGRATOR`，而不是直接认领系列协调者。

角色认领表回答“谁是谁”；并行任务登记回答“谁正在做哪个 checkpoint”。两者不要混成一个表。

## 2. 状态约定

| 状态 | 含义 |
| --- | --- |
| OPEN | 尚未认领 |
| CLAIMED | 已认领，尚未正式推进 |
| ACTIVE | 正在推进 |
| REPORT_READY | 已完成本角色当前可推进工作，交接/证据已就绪 |
| BLOCKED | 因冲突、依赖或决策缺失暂停 |
| STALE_CANDIDATE | 软租约过期但尚未确认可接管；需要最终整合者或用户核对 |
| DONE | 本轮角色任务已完成 |
| COLLISION | 出现重复认领，需要整合者裁决 |

## 3. 自认领流程

1. 读取授权策略、本文件、总控、并行任务登记、总控指令和交接报告 README。
2. 确认存在 `INTEGRATOR` 行，且优先级为 0；缺失时先补入。
3. 如果 `INTEGRATOR` 为 `OPEN`，且当前对话是执行对话，先认领 `INTEGRATOR`。
4. 如果 `INTEGRATOR` 已 `CLAIMED` / `ACTIVE`，选择优先级最高且状态为 `OPEN` 的系列协调者。
5. 确认该角色写入范围没有与 `CLAIMED` / `ACTIVE` 任务冲突。
6. 读取当前对话可感知的 `CODEX_THREAD_ID`；若不存在，则生成一次 UUID fallback 并持久写入。生成唯一 `role_instance_id`，将该角色改为 `CLAIMED`，写入 owner、thread_id、认领时间、目标 checkpoint、`last_seen`、`lease_expires_at`、`heartbeat_status`，以及实现阶段才需要的 branch/worktree。
7. 开始工作时改为 `ACTIVE`。
8. 完成本轮后写入交接报告，并把角色改为 `REPORT_READY`；交接报告是证据包，不是阻塞锁。
9. 软租约过期只表示 `STALE_CANDIDATE`，不得自动释放或接管；最终整合者应核对交接、登记、git 活动、heartbeat 和总控指令后再处理。
10. 如果 `INTEGRATOR` 和所有必需系列协调者均不再是 `OPEN`，最终整合者应报告“角色已认领完毕”。

## 4. 角色池

Owner 命名规则：

- 不使用“本对话”“当前线程”等临时描述作为 owner。
- 优先使用当前环境可感知的 `CODEX_THREAD_ID` 区分对话；没有时生成 UUID fallback。
- 使用 `<ROLE_ID>@thread-<thread_id_or_uuid>`。
- branch/worktree 只用于实现阶段隔离文件改动，不参与对话身份命名。
- 创建 branch/worktree 后，在登记表或交接报告中写明 branch 和 worktree path。
- 历史 owner 若把 worktree/proposal slug 混进身份，所属角色下次恢复前必须改为 thread_id 身份格式。
- 历史 owner 若缺少 thread_id，或把 worktree/proposal slug 混进身份，所属角色下次恢复前必须先回写自己的 `CODEX_THREAD_ID` 并改为 thread 身份格式。

示例：

- `INTEGRATOR@thread-019e4a8c-1bf9-7ca2-8b6d-984aa15e98cf`
- `COORD-P@thread-019e4b19-4109-7250-b682-8afa4bfe75b2`
- `COORD-D@thread-019e4c20-8a77-7000-9123-example000001`

| 优先级 | 角色ID | 角色 | 状态 | owner / role_instance_id | thread_id | last_seen | lease_expires_at | heartbeat_status | branch/worktree | 负责范围 | 允许写入 | 禁止写入 | 当前 checkpoint | 认领时间 | 交接报告 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | INTEGRATOR | 最终总控整合者 | OPEN |  |  |  |  |  |  | 整合、冲突、登记、总控、授权策略执行 | docs/并行任务登记.md; docs/总控指令.md; docs/系列提案-全周期总控.md; docs/交接报告/** | 源码直接实现；缺少最小审查结论时推进 APPROVED/DONE |  |  |  |
| 1 | COORD-P | 产品与信息架构协调者 | OPEN |  |  |  |  |  |  | P0/P1/P2 | docs/系列提案-产品与信息架构.md | 总控、登记表、源码 |  |  |  |
| 2 | COORD-D | 数据与存储协调者 | OPEN |  |  |  |  |  |  | D0/D1/D2 | docs/系列提案-数据与存储.md | 总控、登记表、源码 |  |  |  |
| 3 | COORD-EV | 编辑器与版本协调者 | OPEN |  |  |  |  |  |  | E0/V0/E1/V1/V2 | docs/系列提案-编辑器与版本.md | 总控、登记表、源码 |  |  |  |
| 4 | COORD-A | AI 调度与上下文协调者 | OPEN |  |  |  |  |  |  | A0/A1/A2/A3/A4 | docs/系列提案-AI调度与上下文.md | 总控、登记表、源码 |  |  |  |
| 5 | COORD-K | 知识库深化协调者 | OPEN |  |  |  |  |  |  | K0-K7 | docs/系列提案-知识库深化.md | 总控、登记表、源码 |  |  |  |
| 6 | COORD-G | 工程化与发布协调者 | OPEN |  |  |  |  |  |  | G0-G4 | docs/系列提案-工程化与发布.md | 总控、登记表、源码 |  |  |  |
| 7 | COORD-Q | 质量与验证协调者 | OPEN |  |  |  |  |  |  | Q0-Q3 | docs/系列提案-质量与验证.md | 总控、登记表、源码 |  |  |  |

## 5. 全部认领判定

当前结论：尚未全部认领。

当 `INTEGRATOR` 和所有必需系列协调者状态均不为 `OPEN` 时，最终整合者将本节改为：角色已认领完毕，并列出 owner。
```

## Parallel Task Registry Skeleton

```md
# 并行任务登记

## 1. 文档目的

记录多对话、多角色、多 subagent 并行推进时的认领状态、写入范围、阻塞关系和交接说明。总控给角色的冲突裁决和恢复指令放在 `docs/总控指令.md`。

## 2. 使用原则

- 主线可见。
- 先认领，后工作。
- 写入范围优先。
- 跨模块契约回主线。

## 3. 状态约定

| 状态 | 含义 | 谁可设置 |
| --- | --- | --- |
| OPEN | 可认领 | 协调者 |
| CLAIMED | 已认领 | 协调者 |
| ACTIVE | 正在做 | 协调者 |
| REVIEW_REQUESTED | 等待审查 | 协调者 |
| REVIEW | 审查中 | 协调者 |
| BLOCKED | 阻塞 | 协调者 |
| DONE | 完成 | 协调者 |
| PAUSED | 暂停 | 协调者 |

## 4. 当前任务登记

| ID | checkpoint | 类型 | 状态 | owner | 写入范围 | 禁止范围 | 前置依赖 | 影响契约 | 预期产物 | 验证方式 | 交接说明 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

## 5. 开放任务池

| ID | checkpoint | 类型 | 状态 | 建议 owner | 写入范围 | 禁止范围 | 前置依赖 | 预期产物 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

## 6. 并行角色启动提示词

请使用 yefeng。先阅读授权策略、角色认领、并行任务登记、总控指令和总控。如果未指定角色，自动认领一个 OPEN 角色。认领前读取 `$env:CODEX_THREAD_ID` 作为 thread_id；若不存在则生成 UUID fallback。认领时生成 `<ROLE_ID>@thread-<thread_id_or_uuid>` 格式的 role_instance_id。worktree 只在实现阶段作为隔离目录单独登记，不用于区分对话。认领后先检查是否有点名本角色的 ACTIVE 总控指令，再按授权策略推进自己的 checkpoint。
```

## Control Directive Board Skeleton

Use this persistent document when the final integrator needs to send conflict rulings, repair strategy, or resume instructions back to series coordinators. It is a downward instruction board, not a handoff inbox and not a second total-control document.

```md
# 总控指令

## 1. 文档目的

本文件记录最终整合者发给各系列协调者的当前有效指令。系列协调者每次接取 checkpoint、启动 subagent、从 heartbeat 醒来或恢复阻塞任务前，都必须先读取本文件。

本文件只保存仍需执行或刚刚关闭的指令。稳定事实应回写到 `docs/系列提案-全周期总控.md`、`docs/并行任务登记.md` 或对应子提案；已关闭且已回写的详细指令可清理，避免形成第二套事实来源。

## 2. 状态约定

| 状态 | 含义 |
| --- | --- |
| ACTIVE | 总控已下发，相关角色必须先处理 |
| ACKNOWLEDGED | 角色已确认收到，尚未完成 |
| APPLIED | 角色已按指令完成修改或反馈，等待整合者关闭 |
| SUPERSEDED | 被新指令替代 |
| CLOSED | 稳定事实已回写，指令结束 |

## 3. 执行规则

1. 角色发现无法自动裁决的总控/授权/登记/契约冲突时，停止受影响工作，写交接报告，并按授权策略标记阻塞；只有本角色无其他未阻塞任务且总控指令是具体恢复条件时，才启用本线程 heartbeat。
2. 最终整合者读取交接报告和权威文档后，在本文件创建或更新指令。
3. 被点名角色在接取任何新任务前，必须先处理 `ACTIVE` 指令。
4. 指令只给出修复策略和恢复条件，不替代 reviewer 审核，也不自动批准 checkpoint。
5. 角色完成指令后，通过交接报告或本指令允许的反馈字段报告；最终整合者回写稳定事实后关闭或清理指令。

## 4. 当前指令

| ID | 状态 | 创建时间 | 来源 | 目标角色 | 目标 checkpoint | 涉及契约/文件 | 总控裁决 | 要求动作 | 允许写入范围 | 恢复条件 | 角色反馈/交接 | 关闭条件 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

## 5. 指令模板

| INT-YYYYMMDD-NN | ACTIVE | YYYY-MM-DD HH:MM | 交接报告或冲突来源 | COORD-X | X0 | 契约/文件 | 裁决摘要 | 具体修复步骤 | 允许写入文件 | 达成后可恢复的条件 | 待角色填写或交接报告路径 | 总控/登记表已回写 |
```

## Handoff Inbox Pattern

Use this pattern when multiple conversations or subagents need to report back to a final integrator through files.

```md
# 交接报告收件箱

本目录只保存尚未整合的临时交接报告。整合者处理报告后，必须把稳定事实回写到 `docs/角色认领.md`、`docs/并行任务登记.md`、`docs/总控指令.md`、`docs/系列提案-全周期总控.md` 或对应子提案，然后删除或清空已处理报告。状态推进和清理应先读取 `docs/授权策略.md`。

交接报告是证据包和临时记录，不是角色锁。未整合报告不阻止同一角色继续推进未阻塞工作，也不能单独作为 heartbeat blocker。若 `AGENT_REVIEW` 证据缺失，最终整合者应退回协调者部署 reviewer。

持久文件：

- `README.md`：说明规则和模板。

临时文件：

- `YYYYMMDD-HHMM-<role>-<checkpoint>.md`

清理规则：

- 已整合：删除临时报告。
- 仍阻塞：把阻塞事实写入登记表；临时报告只保留到下一轮整合。
- 需要用户决策：把问题写入登记表或总控的待决策区域；临时报告不作为长期依据。

消化摘要规则：

- 整合者不得把交接报告全文复制进登记表或总控。
- 每份已处理报告只保留一条短摘要：角色/checkpoint、报告文件、处理时间、状态变化、变更范围、稳定事实、阻塞/指令、下一责任人。
- reviewer 过程材料不长期保留；登记表只保留最小审查结论：reviewer、范围、结论、返工项、是否重审、解锁/阻塞影响。
- 长细节留在对应子提案、git diff/commit 或源码中；登记表只保留恢复工作所需的最小事实。
- 已处理报告在摘要和权威文档回写完成后删除或清空。
```

## Handoff Report Template

```md
# 交接报告：<role> / <checkpoint>

状态：待整合
角色：
checkpoint：
本轮目标：
生成时间：

## 1. 已完成修改

- 修改文件：
- 涉及章节：
- 新增或调整的关键内容：

## 2. Checkpoint 状态建议

- 可进入 REVIEW：
- 仍保持 DRAFT：
- 建议 BLOCKED：
- 理由：
- 最小审查结论：

## 3. 跨模块契约影响

- 影响契约：
- 涉及其他系列：
- 是否需要总控统一定义：

## 4. 发现的冲突

- 与总控冲突：
- 与其他子提案冲突：
- 术语冲突：
- 依赖冲突：

## 5. 总控回写建议

- 建议写入内容：
- 原因：
- 影响范围：

## 6. 登记表建议

- 建议状态变化：
- 原因：

## 7. 下一步建议

- 需要继续的角色：
- 需要用户决策的问题：
- 具体恢复条件：
- 是否只是等待交接被消化：

## 8. 建议消化摘要

- 一句话摘要：
- 状态变化：
- 必须登记的稳定事实：
- 可删除的临时细节：
```

## Worker Prompt Pattern

```text
请使用 yefeng。工作目录是 <path>。

你不是单独在工作区中工作：会有多个角色并行推进不同系列。你的唯一写入范围是：<scope>。
不要修改总控、总控指令、并行登记、项目总览或代码，除非授权策略或本任务明确授权。

先阅读：
1. docs/授权策略.md
2. docs/并行任务登记.md
3. docs/总控指令.md
4. docs/系列提案-全周期总控.md
5. <your-series-doc>

如果 `docs/总控指令.md` 中存在点名你的角色、checkpoint、写入范围或契约的 ACTIVE 指令，先按指令处理；处理不了就写交接报告并保持阻塞，不要继续新任务。

任务：
<specific assignment>

完成后汇报：
- 修改文件
- 覆盖 checkpoint
- 关键依赖
- 冲突或阻塞
- 总控回写建议
- 如果项目启用了文件交接，请写入 docs/交接报告/YYYYMMDD-HHMM-<role>-<checkpoint>.md；该文件是临时收件箱内容，整合后会被清理。
```

## Self-Claiming Coordinator Prompt Pattern

Use this as the minimal prompt for a new top-level conversation. It avoids manually assigning roles while still explicitly authorizing subagent delegation.

```text
请使用 yefeng。工作目录是 <path>。

按项目已有的角色认领表自动认领一个 OPEN 角色并推进。若 `INTEGRATOR` 仍为 OPEN，先认领总控整合者；否则认领最高优先级的系列协调者。你是顶层执行对话，可以按 yefeng 约定部署 subagent 做边界清晰的子任务。

先读取：
1. docs/授权策略.md
2. docs/角色认领.md
3. docs/并行任务登记.md
4. docs/总控指令.md
5. docs/系列提案-全周期总控.md
6. docs/交接报告/README.md
7. 与你认领角色相关的系列提案

认领后请报告：
- 认领角色
- role_instance_id
- thread_id
- branch / worktree（若有）
- 写入范围
- 禁止范围
- 将部署哪些 subagent 或为什么暂不部署
- 本线程 heartbeat 状态；主动执行时暂停/不启动，只有等待具体恢复条件且本角色无可推进任务时启用
- 本轮 checkpoint
- 是否存在点名本角色的 ACTIVE 总控指令；若存在，先处理该指令

完成后把交接报告写入 docs/交接报告/，并只修改授权策略允许的文件。若授权策略允许 AGENT_REVIEW，创建 proposal 或实现后由当前协调者部署独立 reviewer subagent；通过后按策略推进状态、继续实现、合并或清理。交接报告未被消化本身不是阻塞或 heartbeat 理由。
```

## Heartbeat Prompt Pattern

```text
作为最终整合者，检查项目文档中的并行任务登记、总控和各系列提案。
先读取 docs/授权策略.md，按授权策略决定是否可以自动推进 REVIEW、APPROVED、DONE、worktree 合并和清理。
先读取 docs/角色认领.md，判断是否所有必需角色已认领；若已全部认领，报告“角色已认领完毕”。
读取 docs/总控指令.md，检查是否有 ACTIVE/APPLIED/SUPERSEDED 指令需要下发、回写、关闭或清理。
识别新进展、写入范围冲突、跨模块契约冲突、总控回写建议、可进入 REVIEW 的 checkpoint、应 BLOCKED 的 checkpoint。
读取 docs/交接报告/ 中尚未处理的临时报告。只有授权策略允许且最小审查结论满足门槛时，才可推进 checkpoint 到 APPROVED/DONE 或执行合并/清理；若 AGENT_REVIEW 最小审查结论缺失，退回对应协调者部署 reviewer，不把最终整合者当作常规 reviewer。
如发现总控、授权策略、登记表之间无法自动裁决的冲突，写入或更新 docs/总控指令.md，给出目标角色、修复策略、允许写入范围和恢复条件。
如果已经被授权修改文件，请在把稳定事实回写到登记表或总控后，给每份已处理交接报告写一条短消化摘要，然后删除或清空已处理的交接报告，避免报告累计成第二套事实来源。
```
