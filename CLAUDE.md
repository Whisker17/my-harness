# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Workflow

- **`main`** — release/deploy only, not for daily development
- **`dev`** — primary development branch, all feature work branches from here
- Every development task MUST use a git worktree branched from `dev`
- Branch naming: `<type>/WHI-<N>-<short-desc>` where type is `feat`, `fix`, or `chore` (e.g., `feat/WHI-58-data-fetcher`, `fix/WHI-60-eip-lookup`)
- Development happens in the feature worktree first, then the user performs peer review
- Do NOT merge a phase back to `dev` until the user explicitly says the review is finished and there are no remaining issues
- When task is complete and review is approved, commit the feature branch, then merge back to `dev` using **merge commit** (no squash, no rebase)
- After merge, clean up the worktree and its branch

### Worktree Lifecycle

```
1. git worktree add .worktrees/<name> -b <type>/WHI-<N>-<name> dev
2. Work in .worktrees/<name>/
3. Implement and verify in the feature worktree
4. Wait for user peer review and address review feedback there
5. After user approval, commit with message: "feat(WHI-<N>): description"
6. Verify build passes: npm run build
7. git checkout dev && git merge --no-ff <type>/WHI-<N>-<name>
8. git worktree remove .worktrees/<name>
9. git branch -d <type>/WHI-<N>-<name>
```

### Task Transition

When the user says "继续下一个任务" or similar, follow this sequence before starting the next task:

1. Ensure the current task has passed peer review and the user has explicitly approved merge/cleanup
2. Ensure all changes are committed on the current feature branch
3. Switch to `dev`: `cd <project-root> && git checkout dev`
4. Merge the feature branch: `git merge --no-ff <current-branch>`
5. Remove the worktree: `git worktree remove .worktrees/<name>`
6. Delete the feature branch: `git branch -d <type>/WHI-<N>-<name>`
7. **Update Linear**: move the completed issue to `Done` state (see Linear Workflow below)
8. Create a new worktree for the next task (per Worktree Lifecycle above)
9. **Update Linear**: move the next issue to `In Progress` state

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
