# 清单契约：`git-transferable-state-v1`

审计脚本生成 JSON 清单，并比较两个清单的“可迁移状态”。版本 1 的唯一覆盖范围是 `single-git-working-tree-portable-state-only`：一个普通 Git working tree 的已定义状态。它不是任意文件系统、多 worktree、秘密值、外部数据或应用可运行性的证明。

## 顶层字段

```text
format: cross-machine-project-handoff-manifest
format_version: 1.0
comparison_profile: git-transferable-state-v1
created_at: UTC 时间
tool: 生成工具与版本
portable: 必须精确比较的状态
coverage:
  scope: single-git-working-tree-portable-state-only
  complete: 此比较面是否完整
  limitations: 无法表达的状态
machine_local: 仅诊断的本机状态
```

未知主版本、未知比较配置/覆盖范围、缺失/多余 portable 字段、非法相对路径或畸形嵌套记录都会得到结构化 `inconclusive`，CLI 退出码为 `2`，不应抛 traceback。

`coverage.complete=true` 只表示这个窄比较面没有已知 limitation；它不表示“可以切换电脑”。

## `portable`

### `portable.git`

- `object_format`：Git 对象格式，当前支持 `sha1` 与 `sha256`。
- `head`：HEAD OID 与符号引用；unborn branch 的 OID 可为 `null`，detached HEAD 的引用可为 `null`。
- `refs.heads`：所有当地分支的完整 ref 名称与 OID。
- `refs.tags`：所有当地标签引用与 OID。
- `refs.stashes`：按 Stash 栈位置记录的 OID。
- `refs.other`：除 heads、tags、stash、remote-tracking refs 外的当地 refs，例如 notes、replace 或工具自定义 refs。
- `index_flags`：`assume-unchanged` 与 `skip-worktree` 路径及标志。
- `worktree`：每个非敏感 dirty/隐藏-index 路径的 index/working 状态、Git OID 或 SHA-256、文件类型、执行语义和重命名前路径。

相同路径和 porcelain 状态不足以判定一致；非敏感工作字节、untracked 文件的 executable 语义、index flags 和本地 refs 也必须一致。脚本不比较普通 clean tracked 文件的工作字节，因为相同 HEAD/Git 对象已定义其版本化内容与 Git mode。

脚本始终用 Git/文件系统返回的原始路径做 I/O，只把清单键规范化为 `/` 与 Unicode NFC；若两个原始路径会归并到同一规范化/大小写键，覆盖范围必须变为不完整。

remote-tracking refs、remote URL 与 upstream 是可能陈旧且机器专属的连接诊断，不参与 portable 等价判断。

### `portable.dependency_manifests`

记录常见依赖锁文件的相对路径与 SHA-256。锁文件不同视为可迁移状态不匹配；依赖目录本身属于可重建机器状态。

### `portable.sensitive_paths`

只有内置规则或 `--sensitive-path` / `--sensitive-glob` 明确识别的路径进入此列表；显式 sensitive path 匹配自身及全部后代，显式 path/Glob 即使位于 `build`、`dist`、`.venv` 等默认可重建目录下也必须优先枚举。目录枚举只读取路径元数据，不读取文件内容。每项只能包含：

```json
{"path": ".env", "exists": true, "ignored": true}
```

已知但不存在的路径可表示为：

```json
{"path": ".env", "exists": false, "ignored": null}
```

对已识别路径，脚本不读取、散列、比较或输出内容。

- 源 `exists=true`、目标 `exists=false` 或缺记录：`mismatch`。
- 任一实际存在侧 `ignored=false`：`mismatch`。
- 两侧存在且被忽略：只确认边界，产生 warning；内容仍需安全通道和运行验证。
- 目标多出一个被忽略的敏感路径：warning，不自动失败。

文件名启发式无法识别任意秘密。审计前必须补充项目专属规则；未声明的普通 untracked 文件会被视为非敏感现场并散列。

## `coverage`

`complete` 与 `limitations` 必须一致：完整时限制列表为空，不完整时至少有一个限制。以下状态会让验证为 `inconclusive`：

- 当前仓库有额外 worktree；
- merge、rebase、cherry-pick、revert、sequencer、bisect 等 Git 操作尚在进行；
- 存在未解决冲突的多阶段 Git index；
- dirty 子模块或子模块状态不完整；
- dirty 特殊文件、不可读路径或不可读锁文件；
- 所有 tracked/dirty 路径中存在大小写或 Unicode NFC 正规化碰撞；
- 敏感路径带有无法安全表达的 index flags；
- 清单字段、摘要、版本、比较配置或覆盖范围无效。

发生限制时应使用项目专门流程补充证据，不得手工把 `complete` 改为 `true`。

## `machine_local`

此部分用于制定恢复计划，不要求源/目标相同：

- workspace 名称与绝对根路径；
- OS、架构、Python 与常用工具是否存在；
- upstream、ahead/behind、Git 配置，以及只保留协议/主机的 remote 诊断；
- worktree、子模块和 Git LFS 诊断；
- 大文件、可重建目录是否存在；
- `ignored_nonrebuildable_paths`：未识别为秘密、也未归入常见重建目录的 ignored 路径，只记录路径/类型，不读内容；
- `collaboration.codex`：机器级 Skill 名称和插件 id/version；只读 frontmatter/manifest，不读 Codex 配置或登录凭据；
- `data_review.tracked_sensitive_candidates`：按扩展名列出的 tracked 文档、图片、归档和数据库候选，只含路径、扩展名、大小；这不是内容扫描；
- `security.compromised_credential_labels`：已在聊天/日志/命令行等位置暴露、必须轮换的凭据非秘密标签；
- tracked 文本中的机器专属绝对路径位置，只记录文件/行/类型，不输出匹配文本；
- dirty、Stash、秘密、ignored 本机状态与路径风险摘要。

unknown ignored 路径不进入 portable 比较，因为工具不知道它是应迁移数据、秘密还是可丢弃状态；在切换前必须人工分类。机器信息、创建时间和工具版本也不参与 portable 比较。

## 交接收据契约

`pack` 另行生成 `cross-machine-project-handoff-receipt` 1.0。它不是 portable 清单，不参与 `verify` 等价比较；它负责证明控制载荷和交接意图：

```text
format / format_version / created_at / tool
transfer_state
source:
  workspace_name / object_format / head_oid / head_ref
  codex_environment
intent:
  objective / non_goals / next_action
requirements:
  skills / plugins / docs
validation:
  name / status / 可选 command_label、exit_code、duration_seconds、summary、evidence_label
approvals:
  tracked_data_review / tracked_sensitive_candidates
artifacts:
  repository_bundle / source_manifest / 可选 encrypted_secret_archive
security:
  secret_values_recorded=false
  encrypted_secret_archive_auto_extract=false
  encrypted_secret_archive_user_attested=true/false
  encrypted_secret_archive_cryptographic_verification=not_performed
  credential_rotation_required=false
```

每个 artifact 只包含通用文件名、大小和 SHA-256。收据不接收密码、令牌、解密口令、完整测试日志或秘密文件内容。`user_attested=true` 只表示用户确认它来自独立加密流程；工具明确记录 `cryptographic_verification=not_performed`。验证状态只允许：

- `passed`
- `failed`
- `timed_out`
- `skipped`
- `inconclusive`

`transfer_state=ready_code_sensitive_archive_pending` 表示 Git 控制包已生成，但敏感归档尚未随包提供；不能据此宣称目标可运行。

## 恢复报告契约

`restore` 生成 `cross-machine-project-handoff-restore` 1.0，记录恢复后的 HEAD/ref、完整清单比较和待补状态。状态为：

| 状态 | 含义 |
|---|---|
| `restored_and_manifest_match` | clean Git 比较面一致 |
| `awaiting_sensitive_restore` | 源端存在的敏感路径尚未恢复 |
| `awaiting_toolchain_restore` | 必需机器级 Skill/插件缺失 |
| `restore_verification_incomplete` | 存在其他差异或覆盖不完整 |

恢复报告中的 `encrypted_secret_archive_extracted=false` 是强制安全事实；内置恢复器不处理口令或解密。

## 比较结果与退出码

| 状态 | 含义 | 退出码 |
|---|---|---:|
| `match` | portable 精确一致且无警告 | `0` |
| `match_with_warnings` | portable 一致，但存在已识别秘密边界或机器差异警告 | `0` |
| `mismatch` | portable 存在差异或敏感边界不安全 | `1` |
| `inconclusive` | 无法依据 v1 契约可靠比较 | `2` |

自动化必须区分 `1` 与 `2`。`2` 不是“弱通过”；`0` 也只通过清单层，不能跳过外部状态与运行验证。

## 清单版本 1 非目标

- portable 清单本身不导出或恢复文件；配套 `pack/restore` 只处理满足前置条件的 clean Git bundle；
- 不推断任意文件是否包含秘密，也不验证秘密值；
- 不迁移 ignored/仓库外数据、生产数据库、云资源或登录会话；
- 不完整表达多个 worktree、未解决冲突的所有 index stage、子模块内部 dirty 内容或任意特殊文件；这些状态会令覆盖不完整；
- 不证明依赖可安装或应用能运行。

因此清单匹配后仍需 `git fsck`、ignored/外部状态对账、依赖/测试检查和真实产品路径 smoke test。
