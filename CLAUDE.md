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

## Issue-Driven Development

**Core principle: every code change — new feature, bug fix, or course correction — MUST start with a Linear issue.** No cowboy coding. Linear is the single source of truth for what work is planned, in progress, and done.

### Why This Matters

- Issues capture intent before implementation — the "why" doesn't get lost
- Conflict detection is impossible without a written record of planned work
- The backlog stays alive: new discoveries update it rather than bypassing it
- Review is meaningful because reviewers can compare implementation against spec

### Principles

1. **Issues before code.** When the user describes a problem, a feature idea, or a course correction, Claude's first action is to check Linear — not start coding. Search for existing issues that might already cover the request.
2. **No cowboy coding.** If there is no Linear issue for the work, always confirm with the user before creating a new issue or modifying an existing one. Never create or mutate Linear issues without explicit user approval.
3. **Living backlog.** Issue descriptions are not write-once documents. When implementation reveals new information, propose updates to the issue description and apply them after user confirmation.

### Course Correction Workflow

When the user explicitly requests a change to the plan — describing a bug, a design flaw, a missing requirement, or a new insight that requires modifying existing issues or creating new ones:

**Important:** This workflow activates when the user clearly indicates the current plan needs to change (e.g., "我发现这个设计有问题", "we need to change the approach", "this requirement is wrong"). It does NOT activate for casual observations or minor comments during implementation.

#### Step 1 — User requests a change

The user describes something that changes the plan. Claude acknowledges and begins the conflict check — no code changes yet.

#### Step 2 — Claude checks for conflicts and proposes changes

Before making any code or Linear changes, Claude:

1. **Search existing issues** for potential conflicts (query the current project across all active states):
   ```
   list_issues(project: "<project-name>", state: "In Progress")
   list_issues(project: "<project-name>", state: "Todo")
   list_issues(project: "<project-name>", state: "Backlog")
   list_issues(project: "<project-name>", state: "In Review")
   ```
   Use the project name from the current Linear issue context. If the Linear API call fails, warn the user ("Linear API unavailable — cannot check for conflicts. Please verify manually or retry.") and wait for the user to decide how to proceed. Do not silently skip conflict detection.

2. **Check for conflicts** against the returned issues. Look for:

   | Conflict Type | Detection | Proposed Action (requires user approval) |
   |---------------|-----------|------------------------------------------|
   | **Scope overlap** | New work touches the same area described in an existing issue's Architecture Notes or Acceptance Criteria | Report the overlap to the user; recommend adding a comment on the existing issue or splitting scope |
   | **Invalidation** | New finding makes an existing issue's approach wrong or unnecessary | Report to the user; recommend updating or replacing the affected sections of the existing issue description, or cancelling the issue |
   | **Dependency change** | New work must be done before an existing issue can proceed | Report to the user; recommend adding a `blockedBy` relation and updating the Dependencies section |
   | **Description staleness** | Current implementation reveals that an issue's description no longer matches reality | Report to the user; recommend updating the issue description |

3. **Propose the issue change** (do NOT execute yet):
   - If the finding maps to an existing issue → propose the description update
   - If it's genuinely new work → propose creating a new issue following the schema (`~/.claude/skills/harness-dev/schema.md`)
   - If it affects the current in-progress issue → propose updating its Acceptance Criteria or Architecture Notes

#### Step 3 — Claude reports back and waits for approval

Claude presents a summary to the user:

- What conflicts were found (if any), or explicitly state "no conflicts detected"
- What Linear changes are proposed (new issue creation, description updates, relation changes)
- What the recommended next step is (continue current work, switch to the new issue, re-prioritize)

**Claude does not create, update, or delete any Linear issues until the user approves.** The user decides what changes to make and in what order.

#### Step 4 — Execute approved changes

After the user approves specific changes:

1. Apply the approved Linear mutations (create issues, update descriptions, add relations)
2. If the user chose to continue current work → resume the current task's implementation
3. If the user chose to switch tasks → follow the normal Task Transition workflow (commit current work, switch worktrees)
4. If the user chose to re-prioritize → update issue priorities as approved, then resume current work

### When to Update an Issue Description

Update a Linear issue description (with user approval) when any of these are true:

- Implementation reveals that the Architecture Notes are wrong or incomplete
- A new acceptance criterion is discovered during development
- A scope boundary needs to be added or adjusted
- Dependencies have changed (new blocker discovered, or blocker resolved)

Always read the full current issue description before updating. Preserve the five required sections (`## Context`, `## Acceptance Criteria`, `## Architecture Notes`, `## Dependencies`, `## Scope Boundary`). When updating, add new information alongside existing content. Outdated content that has been superseded by the current change should be replaced with the corrected version — mark what changed and why in the update.

## V2 Pipeline (Multi-Model, optional)

The v2 pipeline introduces cross-model review using Codex (GPT-5.4) alongside Opus. It runs as a parallel alternative to the v1 pipeline — all v1 skills remain unchanged.

### V2 Skills

| Skill | Command | Purpose |
|-------|---------|---------|
| **harness-design-v2** | `/harness-design-v2` | Codex designs the architecture, Opus translates to Linear issues |
| **harness-dev** | `/harness-dev WHI-N` | Unchanged — same dev loop for both v1 and v2 |
| **harness-review-v2** | `/harness-review-v2` | Codex reviews code, Opus fixes, loop until consensus (max 3 rounds) |

### V2 Flow

```
Idea  ──►  /harness-design-v2  ──►  Codex brief → Opus schema → Linear issues
Issue ──►  /harness-dev WHI-N  ──►  (same as v1)
PR    ──►  /harness-review-v2  ──►  Codex↔Opus convergence review
```

### V2 Prerequisites

The v2 pipeline requires additional tools beyond the v1 prerequisites:

- **Codex CLI**: `npm install -g @openai/codex`
- **Codex Plugin**: `npm install -g codex-plugin-cc`
- **Codex Authentication**: `codex login`
- **gstack**: Must be installed (provides `/codex` skill used by v2 skills)

Run `./setup.sh` to check all prerequisites — it detects v2 dependencies automatically.

### When to use v1 vs v2

Use **v2** when:
- PR touches authentication, authorization, or security-sensitive code
- PR introduces new data models or modifies existing schemas
- PR adds new external integrations or API endpoints
- PR is a significant new feature (not a minor enhancement)

Use **v1** when:
- Documentation changes, README updates
- Configuration changes, environment variable additions
- Small bug fixes with clear scope
- Refactors that don't change behavior
- Style/formatting changes

**Note:** v2 is explicit invocation only — there is no auto-routing between v1 and v2. You choose which pipeline to use for each task.

## Schema Reference

The shared issue schema is at `~/.claude/skills/harness-dev/schema.md`.
