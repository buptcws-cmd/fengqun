# __SCOPE_ID__ 通信投影

本目录只保存总控已经校验、去重并提交回执后的紧凑人类视图。角色 outbox 和 broker runtime event 是不可信运输输入，不是权威状态。

- 机器导入与去重状态：`.yefeng/series/__SCOPE_ID__/state/transport.json`
- 权威事件：`.yefeng/series/__SCOPE_ID__/events.jsonl`
- ignored runtime journal/inbox/receipt：`.yefeng/broker/__SCOPE_ID__/`
- 无效、迟到或旧 epoch 输入：忽略的 `.yefeng/quarantine/__SCOPE_ID__/`
- Level 3 control-spool 角色用 `publish-role-message.ps1` 发布、用 `receive-role-message.ps1` 加 broker sequence cursor 收取；不得直接写 shared journal/inbox/receipt。
- broker 接受不等于治理接受。总控必须按 message ID、digest、assignment/run/epoch 和 sequence 幂等提升，把事件、回执、机器状态和本投影纳入同一控制仓提交。
- BLOCKER/QUESTION/CONTRACT/REVIEW/HANDOFF 在事实发生时立即发；CHECKPOINT/PROGRESS 在有意义边界发；runner HEARTBEAT 不应唤醒模型。
