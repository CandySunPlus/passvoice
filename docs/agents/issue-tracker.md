# GitHub Issues

规格和工单使用 `CandySunPlus/passvoice` 的 GitHub Issues。使用 `gh` 操作。写入前用 `gh repo view --json nameWithOwner` 核对目标。如果当前检出指向其他仓库，用 `-R CandySunPlus/passvoice` 显式指定目标。

## 工单操作

- 创建规格或工单：`gh issue create --title "标题" --body-file <文件>`。
- 读取工单：`gh issue view <编号> --json number,title,body,labels,comments`。
- 列出工单：`gh issue list --state open --json number,title,body,labels,comments`。按任务需要指定 `--label` 和 `--state`。
- 添加评论：`gh issue comment <编号> --body "评论"`。多行内容用 `--body-file`。
- 更新标签：`gh issue edit <编号> --add-label <标签>` 或 `--remove-label <标签>`。角色与标签的对应关系见 [分诊标签](triage-labels.md)。
- 关闭工单：先用评论记录原因，再运行 `gh issue close <编号>`。
- 建立子工单：创建时用 `gh issue create --parent <父工单编号> …`，或用 `gh issue edit <父工单编号> --add-sub-issue <子工单编号>` 关联现有工单。若仓库无法使用子工单功能，在子工单开头写 `Part of #<父工单编号>`。
- 建立阻塞关系：创建时用 `gh issue create --blocked-by <编号> …`，或用 `gh issue edit <被阻塞工单编号> --add-blocked-by <阻塞工单编号>`。若仓库无法使用原生依赖，在工单开头用 `Blocked by: #<编号>, #<编号>` 记录。全部阻塞工单关闭后即可开始。
- 统计未关闭的阻塞工单：`gh issue view <编号> --json blockedBy --jq '[.blockedBy.nodes[] | select(.state == "OPEN")] | length'`。

技能要求发布到问题跟踪器时，创建 GitHub Issue。技能要求读取工单时，按给定的编号或链接使用上述读取命令。

## Pull requests

**PRs as a request surface: no.**

此配置项供 `triage` 读取。设为 `yes` 后，外部 PR 也使用相同的分诊标签和状态。用 `gh pr view <编号> --comments` 和 `gh pr diff <编号>` 查看上下文，用 `gh pr comment`、`gh pr edit` 和 `gh pr close` 处理。通过以下命令列出外部提交者的开放 PR：

```sh
gh api --paginate 'repos/CandySunPlus/passvoice/pulls?state=open' \
  --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | .number'
```

Issue 和 PR 共用编号。需要判定类型时，先用 `gh pr view <编号>` 查询 PR，再用 `gh issue view <编号>` 查询工单。

## Wayfinder

- 创建带 `wayfinder:map` 标签的总工单，在正文记录笔记、已确认的决定和待解决问题。
- 每个待解决问题建一张子工单，用 `wayfinder:<type>` 标记类型。若仓库无法使用子工单功能，在总工单正文用任务列表链接子工单。
- 按总工单中的顺序寻找第一张开放、无未关闭阻塞项且无人认领的子工单。
- 用 `gh issue edit <编号> --add-assignee @me` 认领后开始处理。
- 用 `gh issue comment <编号> --body-file <文件>` 记录答案，再运行 `gh issue close <编号>`。最后在总工单的已确认决定部分补充结论和链接。
