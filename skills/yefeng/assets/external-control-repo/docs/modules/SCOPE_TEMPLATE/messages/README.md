# __SCOPE_ID__ 通信投影

本目录只保存总控已经校验、去重并提交回执后的紧凑人类视图。角色 outbox 是不可信运输输入，不是权威状态。

- 机器导入与去重状态：`.yefeng/series/__SCOPE_ID__/state/transport.json`
- 权威事件：`.yefeng/series/__SCOPE_ID__/events.jsonl`
- 无效、迟到或旧 epoch 输入：忽略的 `.yefeng/quarantine/__SCOPE_ID__/`
- 清理源消息前，必须把事件、回执、机器状态和本投影纳入同一控制仓提交。
