---
name: harness-dev
version: 1.0.0
description: "Implements a single Linear issue through the full dev loop: quality gate, Sonnet implementation, adversarial review, fix loop, and Opus review handoff. Invoke with /harness-dev WHI-123."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - Agent
  - mcp__linear-server__get_issue
  - mcp__linear-server__save_issue
  - mcp__linear-server__save_comment
  - mcp__linear-server__list_comments
  - mcp__linear-server__list_issue_statuses
  - mcp__linear-server__list_issues
  - Skill
---

# harness-dev

You are implementing a single Linear issue through the full development pipeline. The user invoked this skill as `/harness-dev WHI-<N>` (or similar). Extract the issue ID from the invocation arguments.

## Preamble

Before any steps, run these checks in a single bash block:

```bash
# Detect current branch and repo root
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CLAUDE_MD_EXISTS=$([ -f "$REPO_ROOT/CLAUDE.md" ] && echo "yes" || echo "no")
WORKTREE_LIST=$(git worktree list 2>/dev/null || echo "")
REVIEW_MODE=$(cat ~/.gstack/config.json 2>/dev/null | jq -r '.review_mode // empty' 2>/dev/null || echo "")
REVIEW_MODE=${REVIEW_MODE:-adversarial-review}

echo "Branch: $CURRENT_BRANCH"
echo "Repo root: $REPO_ROOT"
echo "CLAUDE.md: $CLAUDE_MD_EXISTS"
echo "Review mode: $REVIEW_MODE"
echo "Worktrees:"
echo "$WORKTREE_LIST"
```

If the repo root is empty or CLAUDE.md is missing, warn the user and stop — harness-dev requires a properly configured project.

---

## Step 1 — Quality Gate

**Note:** This step always runs, even on re-invocation. This is intentional — it confirms the issue description hasn't been degraded since the last run and that blocked-by dependencies are still satisfied.

**Read the Linear issue:**

Use `mcp__linear-server__get_issue` with `id: "<issue-id>"` and `includeRelations: true`.

**Validate the issue description against the schema:**

The canonical schema is at `~/.claude/skills/harness-dev/schema.md`. The rules below are derived from it. If validation rules change, update schema.md first and align this section.

The issue description must contain all five required sections as level-2 headings. For each section, check:

1. The heading exists matching: `^## (Context|Acceptance Criteria|Architecture Notes|Dependencies|Scope Boundary)`
2. The section contains at least 20 characters of non-whitespace content below the heading
3. Lines matching `^\[.*\]$` (bracket-wrapped placeholders) do NOT count toward the character minimum

Run this validation for each of the five sections:
- `## Context`
- `## Acceptance Criteria`
- `## Architecture Notes`
- `## Dependencies`
- `## Scope Boundary`

**Check blocked-by dependencies:**

If the issue has `blockedBy` relations, check each blocking issue. If any blocking issue is NOT in `Done` state, the gate fails.

**On failure — output this checklist and STOP:**

```
Issue quality gate FAILED for WHI-xxx:

  ✅ ## Context
  ❌ ## Acceptance Criteria  — missing or insufficient content
  ✅ ## Architecture Notes
  ❌ ## Dependencies  — missing section
  ✅ ## Scope Boundary

  ❌ Blocked by: WHI-90 (In Progress) — must be Done before proceeding

Fix the issue description in Linear and re-invoke /harness-dev WHI-xxx.
```

Do NOT proceed to Step 2 if the quality gate fails.

---

## Step 2 — Setup

### 2a. Re-invocation check

Before creating a new worktree, check if one already exists for this issue:

```bash
git worktree list | grep "WHI-<N>[^0-9]"
```

If a worktree is found:
- Print: `Resuming existing worktree for WHI-<N> at <path>`
- Check for uncommitted changes: `git -C <worktree-path> status --porcelain`
- If uncommitted changes exist, warn the user and ask whether to continue or stash
- Skip to the appropriate step (Step 3 if no PR exists, Step 4/5 if PR already exists)

Check if a PR already exists for the branch:

```bash
gh pr view <branch-name> --json url,state 2>/dev/null
```

If a PR already exists and is open, skip Step 3.5 (PR creation) — go directly to Step 4.

### 2b. Move Linear issue to In Progress

Use `mcp__linear-server__save_issue` with `id: "<issue-id>", state: "In Progress"`.

Also move any sub-issues to In Progress: use `mcp__linear-server__list_issues` with `parentId: "<issue-id>"` to find them, then update each one.

### 2c. Read CLAUDE.md conventions

Read `CLAUDE.md` from the repo root. Extract:
- Branch naming convention
- Commit message format
- PR creation conventions
- Any project-specific build or test commands

### 2d. Infer branch type

Determine the branch type from the issue:

| Signal | Type |
|--------|------|
| Label "Bug" OR title contains "fix" or "bug" (case-insensitive) | `fix` |
| Label "Chore" or "Maintenance" OR title contains "chore" or "refactor" (case-insensitive) | `chore` |
| Everything else (default) | `feat` |

### 2e. Create worktree

Extract a short slug from the issue title (lowercase, hyphens, max 30 chars).

```bash
git worktree add .worktrees/<slug> -b <type>/WHI-<N>-<slug> dev
```

Example: `git worktree add .worktrees/data-fetcher -b feat/WHI-58-data-fetcher dev`

**On failure:** Do NOT proceed. Print the error. Do NOT attempt to delete any existing worktree silently. Roll back the Linear state: `mcp__linear-server__save_issue(id: "<issue-id>", state: "Todo")`.

---

## Step 3 — Implementation

Work inside the worktree at `.worktrees/<slug>/`.

**Use the issue description as your spec.** The `## Acceptance Criteria` section defines what done means. The `## Architecture Notes` section is your technical guide.

### 3a. Implement the acceptance criteria

- Read the issue description carefully
- Read CLAUDE.md for conventions (patterns, file locations, error handling expectations)
- Implement each acceptance criterion
- Follow existing code patterns — read relevant existing files before writing new ones

### 3b. Build and test

```bash
cd .worktrees/<slug>

# Run build if a build command exists (check package.json, Makefile, etc.)
# Run tests if they exist
```

If the build or tests fail, fix the failures before committing.

### 3c. Commit

Stage and commit all changes:

```bash
git -C .worktrees/<slug> add -A
git -C .worktrees/<slug> commit -m "<type>(WHI-<N>): <description>"
```

**Staging safety:** Prefer staging specific files when possible. If using `git add -A`, ensure `.gitignore` covers sensitive files. Never stage `.env`, credentials, API keys, or large binaries.

The description should be a concise summary of what was implemented (not "implement acceptance criteria").

---

## Step 3.5 — Push & PR Creation

### Push the feature branch

```bash
git -C .worktrees/<slug> push -u origin <type>/WHI-<N>-<slug>
```

**If push fails** (no remote, auth error, etc.):
- Warn: `Push failed: <error>. Falling back to local-only adversarial review.`
- Proceed to Step 4 using the Agent subagent fallback (not `/adversarial-review:run`)

### Create the GitHub PR

```bash
gh pr create \
  --base dev \
  --title "<type>(WHI-<N>): <description>" \
  --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing what changed>

## Linear Issue
[WHI-<N>](https://linear.app/whisker-personal/issue/WHI-<N>)

## Test Plan
- [ ] Build passes
- [ ] <specific verification steps based on acceptance criteria>
EOF
)"
```

Add relevant labels if applicable: `security`, `breaking-change`, `migration`.

**If PR creation fails:**
- Warn: `PR creation failed: <error>. Adversarial review will run against local diff only.`
- Store the fact that no PR exists — Step 4 will use the Agent subagent fallback

---

## Step 4 — Adversarial Review

Use the `REVIEW_MODE` detected in the preamble to decide the review strategy. Default is `adversarial-review`.

### Primary path: `/adversarial-review:run` (when REVIEW_MODE is `adversarial-review`)

If `/adversarial-review:run` is available, a PR exists, and `REVIEW_MODE` is `adversarial-review`, invoke it:

```
/adversarial-review:run
```

This skill uses the PR as the review surface (PR metadata, inline comments, CI status). Wait for it to complete and collect the findings.

### Fallback path: Agent subagent

If `/adversarial-review:run` is unavailable OR no PR was created, dispatch an Agent subagent:

```
Invoke the Agent tool with this prompt:

"Read the diff with `git diff dev...HEAD` (run from inside the worktree).
Think like an attacker and chaos engineer. Find: edge cases, race conditions,
security holes, resource leaks, failure modes, silent data corruption, logic
errors, error handling that swallows failures. Classify each finding as
CRITICAL, HIGH, MEDIUM, or LOW. No compliments, just the problems."
```

### Collect findings

Parse the adversarial review output into a structured list:
- Each finding has: severity (CRITICAL/HIGH/MEDIUM/LOW), description, location (file:line if known)
- Store this list as `ROUND_1_FINDINGS`

---

## Step 5 — Fix Loop

**Maximum 2 iterations.** Step 4 already produced the initial findings (`ROUND_1_FINDINGS`). This loop consumes those findings first, fixes them, then re-reviews.

### Loop logic

```
CURRENT_FINDINGS = ROUND_1_FINDINGS (from Step 4)
FIX_ROUND = 0

LOOP:
  CRITICALS = CURRENT_FINDINGS where severity == CRITICAL
  HIGHS = CURRENT_FINDINGS where severity == HIGH
  MEDIUMS_AND_LOWS = CURRENT_FINDINGS where severity in [MEDIUM, LOW]

  Log MEDIUMS_AND_LOWS — do NOT auto-fix these

  IF CRITICALS + HIGHS is empty:
    BREAK — no more fixes needed

  FIX_ROUND += 1

  IF FIX_ROUND > 2:
    Print: "⚠️  Fix loop cap reached (2 iterations). Unresolved findings:"
    List each unresolved CRITICAL and HIGH
    IF any CRITICALS remain:
      Print: "🛑 STOP: Unresolved CRITICAL findings. Do not proceed to handoff."
      Print: "Manually fix the CRITICAL findings, push to the branch, and re-invoke /harness-dev WHI-<N>"
      STOP
    ELSE:
      Print: "Proceeding to handoff with unresolved HIGH findings (documented in review context)."
    BREAK

  Fix CRITICALS and HIGHS:
    - Edit the relevant files
    - Stage changes: `git -C .worktrees/<slug> add -A`
    - Commit: `git -C .worktrees/<slug> commit -m "fix(WHI-<N>): address adversarial review findings (round <FIX_ROUND>)"`
    - Push: `git -C .worktrees/<slug> push`

  Re-run adversarial review (same approach as Step 4) → NEW_FINDINGS
  DEDUPLICATE NEW_FINDINGS against CURRENT_FINDINGS
  CURRENT_FINDINGS = NEW_FINDINGS

  GOTO LOOP
```

**Important:** Only fix Critical and High findings. Log Medium/Low items in `.harness/review-context.md` for the human reviewer to assess.

---

## Step 6 — Handoff

### 6a. Move issue to In Review

Use `mcp__linear-server__save_issue` with `id: "<issue-id>", state: "In Review"`.

### 6b. Write review context file

Create `.harness/review-context.md` inside the worktree:

```bash
mkdir -p .worktrees/<slug>/.harness
```

Write the following content to `.worktrees/<slug>/.harness/review-context.md`:

```markdown
# Review Context — WHI-<N>: <issue title>

## Implementation Summary

<What was built, key decisions made, any deviations from the spec and why>

## Files Changed

<List of files created or modified, with a one-line description of each>

## Adversarial Review Findings

### Addressed (Critical/High)

<For each finding that was fixed: description, fix applied>

### Remaining (Medium/Low — not auto-fixed)

<For each medium/low finding: description, severity, recommendation>

## PR

<PR URL>

## Acceptance Criteria Status

<For each criterion from the issue, mark ✅ or ❌ with a note>
```

Commit this file:

```bash
git -C .worktrees/<slug> add .harness/review-context.md
git -C .worktrees/<slug> commit -m "chore(WHI-<N>): add harness review context"
git -C .worktrees/<slug> push
```

### 6c. Post Linear comment

Use `mcp__linear-server__save_comment` with `issueId: "<issue-id>"` and body:

```markdown
## Implementation Complete — Ready for Review

**PR:** <PR URL>
**Branch:** <branch name>

### What was implemented
<1-3 sentence summary>

### Adversarial review
- **Round(s) run:** <N>
- **Criticals found/fixed:** <count>
- **Highs found/fixed:** <count>
- **Medium/Low remaining:** <count> (documented in `.harness/review-context.md`)

### Next step
Invoke `/harness-review WHI-<N>` with Opus to run the final acceptance review.
```

### 6d. Output handoff message

Print to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  WHI-<N> is ready for Opus review

PR:      <PR URL>
Branch:  <branch name>
Status:  In Review (Linear updated)

Run:  /harness-review WHI-<N>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Recovery Reference

| Failure point | Recovery action |
|---------------|-----------------|
| Step 2 — worktree creation fails | Roll back Linear to "Todo", print error, STOP |
| Step 3.5 — push fails | Warn, continue with local-only adversarial review |
| Step 3.5 — PR creation fails | Warn, continue with Agent subagent for review |
| Step 5 — cap reached with Criticals | STOP with explicit message, do NOT proceed to handoff |
| Step 5 — cap reached with Highs only | Proceed to handoff, document in review context |
| Any step — unexpected exception | Print the error, preserve the worktree, do NOT delete silently |

**Never silently delete a worktree.** If something goes wrong, leave the worktree intact and tell the user what happened.

---

## State Machine

```
Backlog/Todo ──[Step 2]──► In Progress ──[Step 6]──► In Review ──[/harness-review]──► Done
                                │                         │
                                │ (fix loop cap w/ Crits) │ (Opus rejects)
                                └─── stays In Progress    └─── stays In Review
```

Linear state is only advanced, never skipped:
- Step 2: `Todo → In Progress`
- Step 6: `In Progress → In Review`
- `In Review → Done` is handled by `/harness-review` (NOT by this skill)
