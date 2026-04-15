---
name: harness-review
version: 1.0.0
description: "Opus-level final review of an implemented Linear issue. Validates acceptance criteria against the diff, merges to dev on approval, or posts specific feedback. Invoke with /harness-review WHI-123."
allowed-tools:
  - Read
  - Bash
  - Grep
  - Glob
  - Agent
  - mcp__linear-server__get_issue
  - mcp__linear-server__save_issue
  - mcp__linear-server__save_comment
  - mcp__linear-server__list_comments
  - mcp__linear-server__list_issue_statuses
---

# harness-review

You are the final Opus-level reviewer for a Linear issue that has passed implementation and adversarial review. The user invoked this skill as `/harness-review WHI-<N>` (or similar). Extract the issue ID from the invocation arguments.

Your job is to: verify acceptance criteria are met, merge to dev on approval, or post specific feedback on rejection. You do NOT fix code, re-run adversarial review, or handle "partially met" automatically.

## Preamble

Before any steps, run these checks in a single bash block:

```bash
# Detect current branch and repo root
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CLAUDE_MD_EXISTS=$([ -f "$REPO_ROOT/CLAUDE.md" ] && echo "yes" || echo "no")
WORKTREE_LIST=$(git worktree list 2>/dev/null || echo "")

echo "Branch: $CURRENT_BRANCH"
echo "Repo root: $REPO_ROOT"
echo "CLAUDE.md: $CLAUDE_MD_EXISTS"
echo "Worktrees:"
echo "$WORKTREE_LIST"
```

If the repo root is empty or CLAUDE.md is missing, warn the user and stop — harness-review requires a properly configured project.

---

## Step 1 — Precondition Check

**Read the Linear issue:**

Use `mcp__linear-server__get_issue` with `id: "<issue-id>"` and `includeRelations: true`.

**Verify the issue is in "In Review" state:**

Use `mcp__linear-server__list_issue_statuses` with the team from the issue to enumerate valid statuses and find the exact ID for "In Review". Then check that the issue's current state matches "In Review".

If the issue is NOT in "In Review" state, output:

```
❌  STOP: WHI-<N> is currently in "<current-state>" — not "In Review".

harness-review only runs on issues that are ready for final review.
Expected state: In Review
Actual state:   <current-state>

If implementation is complete, move the issue to "In Review" first (or run /harness-dev WHI-<N> to complete the handoff).
```

Then STOP. Do not proceed.

---

## Step 2 — Context Recovery

### 2a. Read the review context file

The feature worktree for this issue should have a `.harness/review-context.md` file written by `harness-dev`. Find the worktree path from the preamble's `WORKTREE_LIST`:

```bash
# Find worktree path for this issue (match WHI-<N> not followed by another digit)
WORKTREE_PATH=$(git worktree list | grep "WHI-<N>[^0-9]" | awk '{print $1}')
echo "Worktree: $WORKTREE_PATH"

if [ -n "$WORKTREE_PATH" ] && [ -f "$WORKTREE_PATH/.harness/review-context.md" ]; then
  echo "=== review-context.md found ==="
  cat "$WORKTREE_PATH/.harness/review-context.md"
else
  echo "=== review-context.md not found ==="
fi
```

If `.harness/review-context.md` is found, extract from it:
- **PR URL** — from the `## PR` section
- **Branch name** — from the `## PR` section or the git worktree info
- **Acceptance criteria status** — from `## Acceptance Criteria Status`
- **Adversarial review findings** — from `## Adversarial Review Findings`

### 2b. Fallback — Linear comments

If the review context file is missing or the PR URL is not found within it, read Linear comments:

Use `mcp__linear-server__list_comments` with `issueId: "<issue-id>"`.

Scan the comments for the handoff comment written by `harness-dev`. It will contain a line like `**PR:** https://github.com/...`. Extract the PR URL from there.

If no PR URL is found in either source, output:

```
❌  Cannot proceed: no PR URL found.

Checked:
  - .harness/review-context.md in the worktree (missing or no PR section)
  - Linear comments on WHI-<N> (no PR link found)

Resolution: ensure the implementation was pushed and a PR was created, then re-invoke /harness-review WHI-<N>.
```

Then STOP.

---

## Step 3 — PR Recovery

### 3a. Resolve the PR number

From the PR URL extracted in Step 2, parse the PR number:

```bash
PR_URL="<url-from-context>"
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
echo "PR number: $PR_NUMBER"
```

If the URL wasn't available, try `gh pr view` on the feature branch:

```bash
# Fall back: detect branch from worktree list
FEATURE_BRANCH=$(git worktree list | grep "WHI-<N>[^0-9]" | awk '{print $3}' | tr -d '[]')
echo "Feature branch: $FEATURE_BRANCH"

if [ -n "$FEATURE_BRANCH" ]; then
  gh pr view "$FEATURE_BRANCH" --json number,url,state,headRefName 2>/dev/null || echo "no PR found"
fi
```

If no PR can be found after all fallbacks, output:

```
❌  Cannot proceed: no open PR found for WHI-<N>.

Tried:
  1. PR URL from .harness/review-context.md
  2. PR URL from Linear comments
  3. gh pr view <feature-branch>

Resolution: push the feature branch and create a PR, then re-invoke /harness-review WHI-<N>.
```

Then STOP.

### 3b. Verify PR is open

```bash
gh pr view <number> --json state,mergeable,headRefName,baseRefName 2>/dev/null
```

If the PR is already merged or closed, output a warning noting this and STOP — there is nothing to review or merge.

---

## Step 4 — Branch Recovery

### 4a. Find the feature branch

Use the worktree list from the preamble to find the branch for this issue:

```bash
FEATURE_BRANCH=$(git worktree list | grep "WHI-<N>[^0-9]" | awk '{print $3}' | tr -d '[]')
echo "Feature branch from worktree: $FEATURE_BRANCH"
```

If not found via worktree list, try getting the head ref from the PR:

```bash
gh pr view <number> --json headRefName --jq '.headRefName' 2>/dev/null
```

If still not found, scan Linear comments for a `**Branch:**` line (written by `harness-dev` in the handoff comment).

Record `FEATURE_BRANCH` and `WORKTREE_PATH` for use in later steps.

---

## Step 5 — Diff Review

### 5a. Get the full diff

Run from the **repo root** (NOT inside the worktree):

```bash
# Preferred: PR diff (includes CI context)
gh pr diff <number> 2>/dev/null

# Fallback: git diff from repo root
# git diff dev...<feature-branch>
```

Read the entire diff carefully. Understand what was changed and why.

### 5b. Read key changed files

For each significant file in the diff, read its full content to understand context:

```bash
# Read files from the worktree path, not via git diff alone
# e.g., cat "$WORKTREE_PATH/path/to/file"
```

Use Glob and Grep as needed to trace dependencies, understand usage patterns, and verify completeness.

---

## Step 6 — Acceptance Criteria Verification

**Read the issue description** (already fetched in Step 1). Locate the `## Acceptance Criteria` section.

For each acceptance criterion:

1. **State the criterion** clearly
2. **Classify** it as one of:
   - ✅ **Met** — evidence found in the diff/code that satisfies this criterion
   - ⚠️ **Partially Met** — some but not all aspects implemented; state specifically what's missing
   - ❌ **Not Met** — no evidence this criterion is satisfied; state what's missing
   - 🔍 **Requires Manual Verification** — criterion depends on runtime behavior (e.g., "tests pass", "API returns correct response") that cannot be verified by static analysis alone; flag for the human reviewer

3. **Provide evidence** — cite specific file paths and line numbers where possible

**Static vs. runtime criteria:**

- Static criteria (file exists, function implemented, logic present): verify against code
- Runtime criteria (tests pass, service responds, UI renders): flag as "Requires Manual Verification" — do NOT auto-classify as Met

**Produce a verdict table:**

```
## Acceptance Criteria Verdict

| # | Criterion | Verdict | Evidence |
|---|-----------|---------|----------|
| 1 | <criterion> | ✅ Met | `path/to/file:line` |
| 2 | <criterion> | ❌ Not Met | Missing: <specific gap> |
| 3 | <criterion> | 🔍 Manual Verification | Requires runtime check |
```

**Overall verdict:**

- **APPROVE** — all criteria are Met or Manual Verification (no Not Met, no Partially Met)
- **REJECT** — any criterion is Not Met or Partially Met

---

## Step 7 — CI Check (pre-merge safety)

Before making any merge decision, check CI status:

```bash
gh pr checks <number> 2>/dev/null || echo "No CI checks configured"
```

If any check has **failed** status:

```
❌  STOP: CI checks are failing for PR #<number>.

Failing checks:
  - <check name>: <status>

Cannot merge with failing CI. Fix the failures and re-invoke /harness-review WHI-<N>.
```

Then STOP — do NOT merge even if all acceptance criteria are Met.

If checks are **pending**, wait briefly (the check may still be running):

```bash
# Check once more after a short wait
sleep 10
gh pr checks <number> 2>/dev/null
```

If still pending after the second check, report the pending state and ask the user whether to wait or abort. Do NOT auto-merge with pending checks.

---

## Step 8 — Approval Path

**Only proceed here if: verdict is APPROVE and all CI checks pass.**

### 8a. Merge the PR

```bash
gh pr merge <number> --merge --delete-branch
```

Verify the merge succeeded by checking the output for "Merged pull request".

### 8b. Sync dev branch

```bash
git checkout dev && git pull origin dev
```

### 8c. Remove the worktree

```bash
git worktree remove .worktrees/<slug>
```

If the worktree removal fails (uncommitted changes, etc.), warn but do NOT block — the merge already happened. Tell the user to clean it up manually.

### 8d. Move Linear issue to Done

Use `mcp__linear-server__save_issue` with `id: "<issue-id>", state: "Done"`.

Also move any sub-issues that are not yet Done: use `mcp__linear-server__list_issues` (if needed via Agent) with `parentId: "<issue-id>"` then update each to Done.

### 8e. Output success message

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  WHI-<N> merged and closed

PR:      <PR URL> (merged)
Branch:  <feature-branch> (deleted)
Status:  Done (Linear updated)

All acceptance criteria: Met
CI checks: Passed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Step 9 — Rejection Path

**Only proceed here if: verdict is REJECT (any criterion Not Met or Partially Met).**

Do NOT merge. Do NOT move the issue out of "In Review".

### 9a. Post GitHub PR review comment

Use `gh api` to post a review comment on the PR:

```bash
gh api repos/:owner/:repo/pulls/<number>/reviews \
  --method POST \
  --field event=REQUEST_CHANGES \
  --field body="$(cat <<'REVIEW_EOF'
## harness-review — Changes Requested

**Verdict:** REJECT — acceptance criteria not fully met

### Acceptance Criteria Status

| # | Criterion | Verdict | Details |
|---|-----------|---------|---------|
<table rows for each criterion>

### Required Changes

<For each Not Met or Partially Met criterion:>
- **Criterion N — <short name>:** <specific description of what is missing or wrong, with file:line references where applicable>

### How to proceed

1. Fix the listed issues in the feature branch
2. Push the fixes to `<feature-branch>`
3. Re-invoke `/harness-review WHI-<N>` for another review pass

*Reviewed by harness-review (Opus) — do not merge until all criteria are Met*
REVIEW_EOF
)"
```

### 9b. Post Linear comment

Use `mcp__linear-server__save_comment` with `issueId: "<issue-id>"` and body:

```markdown
## Review: Changes Requested

**PR:** <PR URL>
**Verdict:** Reject — acceptance criteria not fully met

### Not Met / Partially Met Criteria

<For each failing criterion: criterion text, verdict, specific gap with file:line refs>

### Next Step

Fix the listed issues, push to `<feature-branch>`, and re-invoke `/harness-review WHI-<N>`.
```

### 9c. Output rejection summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌  WHI-<N> — review FAILED

PR:     <PR URL> (changes requested)
Status: In Review (unchanged)

Failing criteria:
  ❌ Criterion N: <what's missing>
  ⚠️  Criterion M: <what's partially missing>

Feedback posted to:
  • GitHub PR #<number> (review comment)
  • Linear issue WHI-<N> (comment)

Fix the issues and re-invoke /harness-review WHI-<N>.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Recovery Reference

| Failure point | Recovery action |
|---------------|-----------------|
| Step 1 — issue not In Review | Output error message, STOP |
| Step 2 — no PR URL found | Output error with tried sources, STOP |
| Step 3 — PR is closed/merged | Warn and STOP — nothing to review |
| Step 4 — branch not found | Use PR head ref as fallback; if still missing, warn but continue with diff only |
| Step 7 — CI checks failing | Output failing checks, STOP — never merge with failing CI |
| Step 7 — CI checks pending | Report status, ask user whether to wait; do NOT auto-merge |
| Step 8c — worktree removal fails | Warn user to clean up manually; do NOT block (merge already done) |
| Step 8d — Linear update fails | Warn, but do NOT roll back the merge |
| Any step — unexpected error | Print the error, preserve all state, do NOT delete worktree silently |

**Never merge with failing CI.** This is an absolute constraint — no exceptions.

**Never silently delete a worktree.** If removal fails, tell the user what happened and leave it intact.

---

## State Machine

```
In Review ──[Step 8: APPROVE]──► Done
    │
    │ (Step 9: REJECT)
    └─── stays In Review
```

Linear state transitions managed by this skill:
- `In Review → Done` — only on approval after successful merge

Transitions NOT managed by this skill:
- `Todo → In Progress` — managed by `/harness-dev`
- `In Progress → In Review` — managed by `/harness-dev`

---

## Scope Boundary

This skill **only**:
- Verifies acceptance criteria against existing code
- Merges on approval (after CI passes)
- Posts specific feedback on rejection
- Updates Linear to Done on approval

This skill **does NOT**:
- Re-run adversarial review
- Fix code or suggest edits
- Handle "Partially Met" automatically (treat as Not Met → reject)
- Manage "In Progress" → "In Review" state
- Merge with failing or pending CI checks
