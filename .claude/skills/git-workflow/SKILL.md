---
name: git-workflow
description: Enforce Scribe's issue-first GitHub workflow for every code, documentation, configuration, CI, build, test, refactor, fix, feature, core, or maintenance change. Use whenever starting, implementing, committing, pushing, reviewing, merging, or releasing a repository change so that work is tracked by an Issue, developed on an Issue-linked branch, merged through a closing PR, and released only when explicitly requested.
---

# Git Workflow

Use `gh` for GitHub operations and Git for local branch and commit operations.

## Hard rules

1. Create or reuse an open Issue before changing files.
2. Never implement on `main`. Create a branch containing the Issue ID first.
3. Merge every change into `main` through a PR, including owner-authored changes.
4. Put `Closes #<issue-id>` in the PR body. Do not put a closing keyword in commits.
5. Let only the repository owner merge PRs.
6. Never run `scripts/release.sh` or create a release tag unless the user explicitly requests a release.

## Workflow

### 1. Establish the Issue

- Search open Issues before creating a duplicate.
- Use `.github/ISSUE_TEMPLATE/change.yml` when creating through GitHub.
- When using `gh`, include the same fields: type, background, goal, acceptance criteria, impact, risk, and release intent.
- Record the Issue number for every later step.

### 2. Create the branch

Start from the current `origin/main` unless the user has explicitly chosen another base.

- Human branch: `<type>/<issue-id>-<short-slug>`
- Codex branch: `codex/issue-<issue-id>-<short-slug>`

Use lowercase ASCII slugs. Allowed types are `feat`, `fix`, `docs`, `core`, `refactor`, `test`, `perf`, `build`, `ci`, and `chore`.

If work already exists on `main`, create the Issue and switch to the Issue branch before making further edits. Preserve the existing worktree.

### 3. Implement and verify

- Keep the diff inside the Issue scope.
- Update required docs in the same change.
- Run verification proportional to the change.
- Do not mix unrelated cleanup into the branch.

### 4. Commit

Use Conventional Commit form:

```text
<type>(<optional-scope>): <imperative summary>

Refs #<issue-id>
```

Use `core` for foundational project policy or architecture changes that do not fit product features. Keep commit messages and code comments in English.

### 5. Push and open the PR

- Push the Issue branch, never `main`.
- Open a PR against `main` using `.github/pull_request_template.md`.
- Use a Conventional Commit title so squash merges keep a valid main history.
- Replace the template placeholder with exactly one closing reference such as `Closes #123`.
- Describe the change, verification, risks, docs, and release impact.

### 6. Review and merge

- Confirm the PR references the correct open Issue.
- Confirm required checks pass.
- Only the repository owner may merge.
- Prefer squash merge unless the Issue requires preserved commit history.
- After merging, verify that GitHub closed the Issue and delete the remote branch.

## Emergency changes

Still create an Issue first. A minimal Issue is acceptable during an incident, but complete its background, verification, and risk sections before merging.

## Release boundary

Ordinary branch pushes and PR merges must not create `yyyy.mm.dd-sn` tags. Releases remain a separate, explicitly requested operation using `scripts/release.sh` after `main` is verified.
