---
name: cross-machine-project-handoff
description: Safely audit, package, restore, and verify an in-progress Git project across computers or operating systems, including local refs, dirty-state boundaries, ignored sensitive configuration, tracked private-data review, machine-level Codex skills/plugins, validation evidence, and new-session context. Use when the user asks to 跨电脑迁移项目、换电脑继续开发、打包被 gitignore 的配置、生成新对话交接提示词、验证恢复后的仓库，or retire a source machine.
---

# 跨电脑项目交接

把目标定义为“另一台电脑可以安全、可验证地继续工作”，而不是“文件已经复制过去”。Git 状态、敏感边界、机器级工具、验证证据和认知上下文都是交接状态。

## 安全边界

- 默认先 `audit`；用户只要求审查或建议时，不执行打包、恢复、推送、清理或凭据操作。
- 在 `pack` / `restore` 会产生文件或工作区前，明确告诉用户本 Skill 正在执行该动作及其范围。
- 对已识别敏感路径，不读取、回显、散列或比较值；只记录相对路径、存在性和 Git ignore 状态。
- 密码、令牌、私钥和解密口令不得作为命令行参数、提示词、日志或收据字段。工具只接受用户确认“已经加密”的敏感归档，永远不接收其口令，也不会伪称已做密码学验证。
- 凭据一旦出现在聊天、终端历史、日志、截图或命令行中，即视为已泄露；只记录非秘密标签，先轮换，再制作可交付包。不要因为它被写入 `.gitignore` 就继续使用。
- `.docx`、PDF、图片、压缩包、数据库等 tracked 文件可能含个人或业务数据。`pack` 前逐项确认授权，并通过显式审批开关记录决定；文件名检查不是内容扫描或合规判断。
- 清单、收据和 bundle 仍可能暴露目录结构、提交历史或版本化私密数据。保存在仓库外的受限位置，并通过私有/加密通道传输。
- 不自动删除源副本。目标验证完成、用户确认切换且回退窗口明确后，才讨论源电脑退役。
- 本 Skill 不替代生产数据库迁移、云部署、整机克隆或企业凭据管理流程。

## 选择工作模式

1. `audit`：只读盘点 Git、敏感边界、私有数据候选、机器工具和迁移风险。
2. `pack`：为**干净、单 worktree、无 Stash/隐藏 index/未知 ignored 状态**的仓库制作 Git bundle、源清单、结构化收据、交接胶囊和新会话提示词。
3. `restore`：校验载荷摘要，把 clean bundle 恢复到不存在或空目录；不自动解密敏感归档。
4. `verify`：在敏感状态和依赖补齐后比较源/目标清单，再运行项目验证。

内置 `pack/restore` 是可证明的 clean-Git 闭环。Dirty worktree 可以被 `audit` 精确记录，但必须按 [迁移协议](references/transfer-protocol.md) 使用经用户批准的专门载荷；不要把尚未实现的 dirty 自动恢复描述成工具能力。

## 执行流程

### 1. 读取权威上下文并冻结写入

先读取仓库级 AGENTS、活跃规格、任务登记、交接文档和当前代码事实。识别：

- 当前目标、非目标、完成证据、阻塞与唯一下一步；
- 正在写入的 Agent、IDE、格式化器、数据库、开发服务器或同步进程；
- 多 worktree、子模块、Git LFS、嵌套仓库和仓库外数据；
- 项目内 Skill/插件要求，以及新电脑必须重装的机器级 Codex Skill/插件。

协调或停止持续写入者再打包；只读审计不要求清理 dirty 状态。

### 2. 生成源审计清单

从本 Skill 目录运行（Windows 默认编码环境建议显式使用 UTF-8）：

```powershell
python -X utf8 "<skill-dir>\scripts\audit_project_transfer.py" audit --workspace "<source-workspace>" --output "<private-source-manifest.json>"
```

在审计前从项目文档和 `.gitignore` 补充专属敏感规则：

```text
--sensitive-path .secrets/deployment-server.env
--sensitive-glob "config/private-*.json"
```

如果某凭据已经在聊天/日志/命令行中暴露，只传非秘密标签：

```text
--compromised-credential-label deployment-server-password
```

该标签会形成 blocking risk；不要把真实值传给参数。

审计会记录 HEAD、本地分支、标签、其他 refs、Stash、隐藏 index 位、非敏感 dirty 内容摘要、依赖锁、机器级 Codex Skill/插件清单、tracked 私有数据候选和 unknown ignored 路径。机器级清单只读取 Skill frontmatter 与插件 manifest，不读取 Codex 配置、登录会话或凭据文件。

`coverage.complete=true` 只表示单 working tree 的 `git-transferable-state-v1` 比较面完整，不表示应用可运行或可以切换。

### 3. 分类迁移状态

| 状态桶 | 示例 | 原则 |
|---|---|---|
| Git 历史 | HEAD、分支、标签、其他 refs | bundle/push；校验 OID |
| 活跃现场 | staged、unstaged、untracked、Stash | 不擅自 reset/clean；内置 pack 会拒绝 |
| 敏感/本机状态 | `.env`、`.secrets`、证书、本地工具配置 | 独立加密通道；不记录值 |
| 可重建状态 | 依赖目录、缓存、构建产物 | 依据锁文件在目标重建 |
| 外部与认知状态 | 数据库、上传文件、工具链、验证、下一步 | 专门导出并写入交接胶囊 |

任何 `ignored_nonrebuildable_paths` 未分类时都不能声称 clone 足够。tracked 文档/归档候选必须判断是否授权进入 Git 历史和 bundle。

### 4. 制作 clean-Git 交接包

先准备不含日志正文和秘密值的验证证据 JSON：

```json
[
  {
    "name": "unit-tests",
    "status": "passed",
    "command_label": "python -m unittest",
    "exit_code": 0,
    "summary": "34 tests passed"
  },
  {
    "name": "server-smoke",
    "status": "timed_out",
    "summary": "No completion evidence was captured"
  }
]
```

合法状态只有 `passed`、`failed`、`timed_out`、`skipped`、`inconclusive`。后四种不得改写成通过。

若确有敏感文件，先用用户批准的密码管理器或加密工具在独立流程中制作归档；口令通过不同通道传递。然后运行：

```powershell
python -X utf8 "<skill-dir>\scripts\audit_project_transfer.py" pack `
  --workspace "<source-workspace>" `
  --output-dir "<private-empty-handoff-dir>" `
  --objective "<current objective>" `
  --non-goal "<explicit non-goal>" `
  --next-action "<first target action>" `
  --validation-file "<validation.json>" `
  --required-skill "cross-machine-project-handoff" `
  --required-doc "AGENTS.md" `
  --encrypted-secret-archive "<already-encrypted-secrets.7z>" `
  --confirm-secret-archive-encrypted
```

确认开关是用户对独立加密流程的明确声明；脚本只校验归档文件的传输摘要，无法在不知道口令的前提下证明加密强度或内容。

存在 tracked 文档/数据库/归档候选时，只有人工复核且确认授权后才添加：

```text
--approve-tracked-data-review
```

`pack` 会拒绝 dirty worktree、Stash、index flags、覆盖不完整、未分类 ignored 状态、未轮换凭据、额外 worktree、子模块状态和 Git LFS 对象。输出目录必须位于仓库外且为空。产物包括：

- `repository.bundle`
- `source-manifest.json`
- `handoff-receipt.json`
- `handoff-capsule.txt`
- `new-session-prompt.txt`
- 可选的通用名 `encrypted-secrets.<suffix>`

### 5. 在目标恢复

先安装兼容的 Git、语言运行时、SDK 和收据列出的 Skill/插件。不要复制另一操作系统的虚拟环境或缓存。

```powershell
python -X utf8 "<skill-dir>\scripts\audit_project_transfer.py" restore `
  --receipt "<handoff-dir>\handoff-receipt.json" `
  --target "<empty-or-absent-target-workspace>" `
  --output-dir "<private-empty-restore-evidence-dir>"
```

`restore` 会先校验 bundle、源清单和可选加密归档的大小/SHA-256，再恢复本地 heads、tags、其他 refs、HEAD，运行 `git fsck` 并生成目标清单。它拒绝覆盖非空目录，不解密敏感归档。

状态解释：

- `restored_and_manifest_match`：clean Git 比较面一致；仍需依赖和产品验证。
- `awaiting_sensitive_restore`：代码已恢复，但源端存在的敏感路径尚未通过独立通道补齐。
- `awaiting_toolchain_restore`：收据要求的机器级 Skill/插件缺失。
- `restore_verification_incomplete`：恢复后仍有非预期差异或覆盖限制。

### 6. 补齐敏感状态并最终验证

通过独立安全通道恢复敏感文件，确认其仍被 Git 忽略；再按锁文件重建依赖。然后重新生成目标清单并比较：

```powershell
python -X utf8 "<skill-dir>\scripts\audit_project_transfer.py" audit --workspace "<target-workspace>" --output "<private-target-manifest.json>"
python -X utf8 "<skill-dir>\scripts\audit_project_transfer.py" verify --source "<handoff-dir>\source-manifest.json" --target "<private-target-manifest.json>" --output "<private-verification.json>"
```

- `match` / `match_with_warnings`：清单层通过；继续做运行验证。
- `mismatch`：可迁移状态不同，退出码 `1`。
- `inconclusive`：清单无效或覆盖不完整，退出码 `2`；绝不是通过。

至少再执行：

- HEAD/分支/refs/status 对照与 `git fsck`；
- 依赖安装、静态分析和关键测试；
- 一个真实产品关键路径 smoke test；
- 外部服务、数据库、证书和登录状态的最小验证。

具体字段见 [清单与收据契约](references/manifest-schema.md)，跨平台与敏感状态见 [跨平台与敏感状态](references/cross-platform-and-secrets.md)。

### 7. 切换与回退

直接使用包内 `new-session-prompt.txt` 启动新对话，并让目标 Agent 先读取收据、AGENTS 和列出的权威文档。不要用聊天全文替代持久化胶囊。

只有同时满足以下条件才宣称交接完成：

- 清单为 `match` 或 `match_with_warnings`；
- 结构化验证没有被误报；
- 真实产品路径通过；
- 目标成为唯一写入端；
- 用户确认并保留明确回退窗口。

## 必须停止并报告

- 用户未授权产生状态的 `pack/restore/cutover`；
- 有持续写入者，无法取得一致快照；
- 凭据曾暴露但尚未轮换；
- tracked 私有数据候选未完成授权复核；
- unknown ignored、仓库外数据、子模块/LFS/多 worktree 无法完整迁移；
- 需要传输秘密却没有批准的独立安全通道；
- 目标为 `mismatch`、`inconclusive` 或任何 awaiting/incomplete 状态；
- 用户准备删除源副本，但运行验证和回退确认尚未完成。

## 向用户报告

依次说明：

1. 当前是否可安全打包/切换；
2. 已确认携带的精确状态与产物摘要；
3. clone/bundle 不会携带的敏感、外部和机器级状态；
4. 审批、阻塞、未通过/超时/未运行的验证；
5. 唯一下一步；
6. 只有实际完成后才给出最终清单与产品验证结论。

不要用“应该都复制了”“看起来没问题”代替证据。
