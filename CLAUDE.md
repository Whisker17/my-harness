# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Workflow

- **`main`** — release/deploy only, not for daily development
- **`dev`** — primary development branch, all feature work branches from here
- Every development task MUST use a git worktree branched from `dev`
- Branch naming: `<type>/WHI-<N>-<short-desc>` where type is `feat`, `fix`, or `chore` (e.g., `feat/WHI-58-data-fetcher`, `fix/WHI-60-eip-lookup`)
- Development happens in the feature worktree first, then reviewed via GitHub PR
- Every feature branch MUST be merged to `dev` through a GitHub PR (no direct `git merge`)
- Do NOT merge a PR until the user explicitly says the review is finished and there are no remaining issues
- PR merge strategy: **merge commit** (no squash, no rebase) — use `gh pr merge --merge`
- After PR merge, clean up the local worktree
- After worktree removal, delete the local feature branch: `git branch -d <branch-name>`
- **Remote branch cleanup:** `--delete-branch` on `gh pr merge` is unreliable when run inside a worktree (git cannot checkout the base branch since `dev` is occupied by the main worktree, causing the remote delete to silently fail). Always verify and fallback:
  ```
  git ls-remote --heads origin <branch-name> | grep -q <branch-name> && git push origin --delete <branch-name>
  ```

### Worktree Lifecycle

```
1. git worktree add .worktrees/<name> -b <type>/WHI-<N>-<name> dev
2. Work in .worktrees/<name>/
3. Implement and verify in the feature worktree
4. Commit with message: "feat(WHI-<N>): description"
5. Verify build passes (if applicable)
6. Push feature branch: git push -u origin <type>/WHI-<N>-<name>
7. Create PR: gh pr create --base dev --title "feat(WHI-<N>): description" --body "..."
8. Run reviews on the PR (adversarial review, human review, Opus review)
9. Address review feedback, push fixes to the same branch
10. After approval: gh pr merge --merge --delete-branch
11. git checkout dev && git pull origin dev
12. git worktree remove .worktrees/<name>
13. git branch -d <type>/WHI-<N>-<name>   # clean up local branch
14. git ls-remote --heads origin <type>/WHI-<N>-<name> | grep -q . && git push origin --delete <type>/WHI-<N>-<name>  # verify remote branch deleted
```

> **Why step 14?** `gh pr merge --delete-branch` silently fails to delete the remote branch
> when run inside a worktree, because git cannot checkout the base branch (`dev` is occupied
> by the main worktree). Always verify with `git ls-remote` and fallback to explicit delete.

### Task Transition

When the user says "继续下一个任务" or similar, follow this sequence before starting the next task:

1. Ensure the current task has passed review and the user has explicitly approved merge
2. Ensure all changes are committed and pushed on the current feature branch
3. Merge the PR: `gh pr merge --merge --delete-branch`
4. Switch to `dev` and sync: `cd <project-root> && git checkout dev && git pull origin dev`
5. Remove the worktree: `git worktree remove .worktrees/<name>`
6. Delete the local feature branch: `git branch -d <type>/WHI-<N>-<name>`
7. Verify remote branch deleted, fallback if not: `git ls-remote --heads origin <branch> | grep -q . && git push origin --delete <branch>`
8. **Update Linear**: move the completed issue to `Done` state (see Linear Workflow below)
9. Create a new worktree for the next task (per Worktree Lifecycle above)
10. **Update Linear**: move the next issue to `In Progress` state

## PR Workflow

### PR Creation

- Every feature branch MUST have a PR before review begins
- Create PR after implementation is committed and pushed:
  ```
  gh pr create --base dev --title "<type>(WHI-<N>): description" --body "..."
  ```
- PR body format:
  ```markdown
  ## Summary
  <1-3 bullet points describing what changed>

  ## Linear Issue
  [WHI-<N>](https://linear.app/whisker-personal/issue/WHI-<N>)

  ## Test Plan
  - [ ] Build passes
  - [ ] <specific verification steps>
  ```
- Add labels for risk signals when applicable: `security`, `breaking-change`, `migration`

### PR Review Flow

1. After PR creation, run `/adversarial-review:run` (uses PR as review surface)
2. Fix Critical/Major findings, push to the same branch
3. Human review or Opus `/harness-review` on the PR
4. All reviews pass → user approves merge

### PR Merge

- Merge strategy: merge commit (`gh pr merge --merge`), NOT squash or rebase
- `--delete-branch` is unreliable in worktree contexts — always verify after merge:
  ```
  git ls-remote --heads origin <branch> | grep -q . && git push origin --delete <branch>
  ```
- After merge, sync local: `git checkout dev && git pull origin dev`
- Clean up worktree locally: `git worktree remove .worktrees/<name>`
- Delete the local feature branch: `git branch -d <type>/WHI-<N>-<name>`

## Linear Workflow

### Issue State Transitions

```
Backlog ──► Todo ──► In Progress ──► In Review ──► Done
```

- **Starting a task**: move issue + its sub-issues to `In Progress`
- **Submitting for review**: move issue to `In Review`
- **Review approved + merged**: move issue to `Done`
- **Review has feedback**: keep in `In Review`, address feedback, re-submit

### Mandatory Linear Updates

1. **Before starting implementation**: move the parent issue and all its sub-issues to `In Progress`
2. **As each sub-issue is completed**: move that sub-issue to `Done`
3. **When implementation is done, before requesting review**: move the parent issue to `In Review`
4. **After review is approved and code is merged to dev**: move the parent issue to `Done`
5. **If blocked**: add a comment on the Linear issue explaining what's blocking

## Schema Reference

The shared issue schema is at `~/.claude/skills/harness-dev/schema.md`.
