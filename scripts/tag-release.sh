#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
elif [[ $# -gt 0 ]]; then
    echo "用法：scripts/tag-release.sh [--dry-run]" >&2
    exit 1
fi

for command in gh git; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "错误：缺少命令：$command" >&2
        exit 1
    fi
done

repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
owner="$(gh repo view --json owner --jq '.owner.login')"
actor="$(gh api user --jq '.login')"
owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
actor_lower="$(printf '%s' "$actor" | tr '[:upper:]' '[:lower:]')"

if [[ "$repository" != "CheneyCh0u/ink" ]]; then
    echo "错误：当前仓库不是 CheneyCh0u/ink：$repository" >&2
    exit 1
fi
if [[ "$actor_lower" != "$owner_lower" ]]; then
    echo "错误：只有仓库拥有者 $owner 可以创建发布标签，当前账号：$actor" >&2
    exit 1
fi

git fetch origin main --tags --prune
main_commit="$(git rev-parse origin/main)"

release_date="$(date "+%Y.%m.%d")"
prefix="v${release_date}-"
highest=0
while IFS= read -r existing_tag; do
    sequence="${existing_tag#"$prefix"}"
    if [[ "$sequence" =~ ^[1-9][0-9]*$ ]] && (( sequence > highest )); then
        highest="$sequence"
    fi
done < <(git tag --list "${prefix}*")

next_sequence=$((highest + 1))
next_tag="${prefix}${next_sequence}"

if "$dry_run"; then
    echo "$next_tag"
    exit 0
fi

git tag -a "$next_tag" "$main_commit" -m "发布 $next_tag"
if ! git push origin "refs/tags/$next_tag"; then
    git tag -d "$next_tag" >/dev/null
    echo "错误：标签推送失败，本地临时标签已清理；请重新运行获取下一序号" >&2
    exit 1
fi

echo "已推送 ${next_tag}，GitHub Actions 将开始构建 macOS 应用"
