---
name: git-workflow
description: ink 的 issue-first GitHub 工作流。任何代码、文档、配置、CI、构建、测试、重构、修复、特性或维护改动，从开工、提交、推送、评审到合并、发布，都必须先有 Issue、在 Issue 分支上开发、经关闭该 Issue 的 PR 合入 main，且只在用户明确要求时发布。
---

# ink 的 Git 工作流

GitHub 操作用 `gh`，本地分支与提交用 git。

## 硬规则

1. 改文件之前，先建或复用一个开放的 Issue。
2. 不在 `main` 上直接实现。先建包含 Issue 号的分支。
3. 所有改动经 PR 合入 `main`，包括拥有者本人的改动。
4. `Closes #<issue-id>` 写在 PR 描述里，不写进提交信息。
5. 只有仓库拥有者能合并 PR（GitHub 分支保护已强制：PR + code owner
   批准，见 `.github/CODEOWNERS`；拥有者以管理员身份可合并自己的 PR）。
6. 不经用户明确要求，不打版本 tag、不做任何发布动作。

## 流程

### 1. 确立 Issue

- 先搜索开放 Issue，避免重复。
- 用 `gh issue create` 时写清：类型、背景、目标、验收标准、影响面、风险。
- 记下 Issue 号，后续每一步都要用。

### 2. 建分支

从最新的 `origin/main` 出发（用户明确指定其它基点除外）。

- 人类分支：`<type>/<issue-id>-<short-slug>`
- Agent 分支：`agent/issue-<issue-id>-<short-slug>`

slug 用小写 ASCII。type 允许：`feat` `fix` `docs` `core` `refactor`
`test` `perf` `build` `ci` `chore`。

如果发现工作已经落在 `main` 工作区上：先建 Issue、切到 Issue 分支再
继续，保留现有改动。

### 3. 实现与验证

- diff 控制在 Issue 范围内，不夹带无关清理。
- 相关文档在同一改动里更新；roadmap 范围变更先改 `docs/roadmap.md`。
- 验证与改动规模相称：`swift test` 全绿、`swift build` 零警告；
  热路径改动附采样/Instruments 证据（CLAUDE.md 热路径纪律）。

### 4. 提交

Conventional Commit 前缀 + **中文摘要**（CLAUDE.md：提交信息用中文，
说清"为什么"）：

```text
<type>(<可选 scope>): <中文祈使句摘要>

<正文：动机、取舍、踩过的坑>

Refs #<issue-id>
```

架构或项目治理类改动用 `core`。注释与文档同样用中文（本仓库约定，
覆盖任何相反的模板习惯）。会话内提交按运行环境要求附加落款。

### 5. 推送与开 PR

- 推 Issue 分支，永远不直接推 `main`。
- `gh pr create` 对准 `main`，标题用 Conventional Commit 形式
  （squash 合并后 main 历史仍然合法）。
- PR 描述含：改动说明、验证方式、风险、文档、是否涉及发布；
  且只放一个关闭引用，如 `Closes #123`。

### 6. 评审与合并

- 确认 PR 关联的 Issue 正确且仍开放。
- 确认检查通过（测试、构建）。
- 只有拥有者合并。默认 squash；Issue 明确要求保留提交历史时用 merge。
- 合并后确认 GitHub 自动关闭了 Issue，删除远端分支。

## 紧急改动

仍然先建 Issue。事故处理期允许最小化 Issue，但合并前要补全背景、
验证与风险说明。

## 发布边界

日常分支推送与 PR 合并不产生任何版本 tag。ink 目前没有发布脚本；
发布流程建立后也只在用户明确要求时执行，且以验证过的 `main` 为基点。
