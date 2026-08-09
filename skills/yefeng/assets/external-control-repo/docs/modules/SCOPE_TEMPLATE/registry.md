# __SCOPE_ID__ 任务登记

| ID | 状态 | Claim | 依赖 | Product Repo / Branch / Worktree | 写入范围 | 验证 | Review Gate | Claimant Next Action | Coordinator Action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GOV-001 | planned | 无 | 无 | __PRODUCT_REPO_ID__ / __PRODUCT_BRANCH__ / 无 | 控制仓治理文件 | 结构、身份与 Git 校验 | 独立治理复核 | 无角色可执行 | 完成治理初始化并冻结首个授权 checkpoint 输入 |
| NEXT-001 | blocked | 无 | GOV-001 | 待决定 | 待批准的首个产品 checkpoint | 按产品仓约定 | 独立评审与用户审批 | 等待总控分配 | GOV-001 通过后再定义，不预设实现形态 |

`done` 仅表示候选 worktree 已验证和评审；`merged` 才表示进入产品集成线；`closed` 还要求证据和执行容器完成清理。
