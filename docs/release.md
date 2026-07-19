# 发布流程

Ink 使用 GitHub tag 驱动 macOS 应用构建。普通提交、分支推送和 PR 合并都不会
触发发布。

## Tag 规范

发布标签固定为：

```text
vYYYY.MM.DD-N
```

- `YYYY.MM.DD` 是发布当天的有效日历日期。
- `N` 是当天的发布序号，从 `1` 开始。
- 同一天每创建一个新发布标签，`N` 加 `1`。
- 新的一天重新从 `1` 开始。

例如：

```text
v2026.07.19-1
v2026.07.19-2
v2026.07.20-1
```

失败的构建也已经消费对应标签。修复后重新发布时创建下一序号，不移动旧标签。

## 权限

只有仓库拥有者 `CheneyCh0u` 可以创建、更新或删除 `v*` 标签。这个约束有三层：

1. GitHub tag ruleset `release-tags-owner-only` 对 `refs/tags/v*` 限制创建、更新
   和删除，只给拥有者用户 ID `216640305` 永久 bypass。
2. `scripts/tag-release.sh` 比较当前 `gh` 登录账号与仓库拥有者。
3. GitHub Actions 再比较 `github.actor` 与 `github.repository_owner`。

远端 ruleset 的配置副本保存在
`.github/rulesets/release-tags.json`。修改远端规则时必须在同一个 PR 中同步这个
文件和本文档，不能只在 GitHub 网页上改。

## 创建发布标签

发布仍然属于显式动作。只有用户明确要求发布时才能运行以下命令：

```bash
scripts/tag-release.sh --dry-run
scripts/tag-release.sh
```

脚本会：

1. 确认当前仓库是 `CheneyCh0u/ink`。
2. 确认当前 GitHub 登录账号是仓库拥有者。
3. 拉取远端 `main` 和全部标签。
4. 查找当天已有的最大序号，计算下一个标签。
5. 将带注释的标签打在最新 `origin/main` 上并推送。

不要手工运行 `git tag`。脚本的序号计算和拥有者检查是发布流程的一部分。

## GitHub Actions

`.github/workflows/release.yml` 只监听符合日期标签外形的 tag push。工作流会再次
严格校验完整格式、日历日期、当天序号、触发者和 tag 所指提交，然后：

1. 在 `macos-15` runner 上运行全部测试。
2. 构建 `arm64 + x86_64` 通用二进制。
3. 组装标准结构的 `Ink.app`，复制运行时 Shader 与应用图标。
4. 对应用做签名验证。
5. 生成 `Ink-vYYYY.MM.DD-N.zip` 与 SHA-256 文件。
6. 上传 Actions artifact，并创建同名 GitHub Release。

当前仓库没有 Developer ID 和公证凭据，流水线使用 ad-hoc 签名。产物结构和签名
可验证，但从互联网下载后仍可能出现 Gatekeeper 提示。正式对外分发前需要另建
Issue，配置签名证书与 Apple notarization。

## 本地验证打包

本地可以使用任意有效格式的测试标签生成产物，不会创建 Git tag 或 GitHub
Release：

```bash
scripts/package-app.sh v2026.07.19-1 dist
```

输出：

```text
dist/Ink-v2026.07.19-1.zip
dist/Ink-v2026.07.19-1.zip.sha256
```
