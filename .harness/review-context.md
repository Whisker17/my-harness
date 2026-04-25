# Review Context — WHI-239: harness-review-v2 Approval/Rejection Path

## Implementation Summary

Added Steps 9 (Approval Path) and Step 10 (Rejection Path) to `skills/harness-review-v2/SKILL.md`, completing the v2 review pipeline's full lifecycle to match v1's harness-review behavior.

**Step 9 (Approval Path)** — triggered when `LOOP_STATUS` is `PASS` or `PASS_WITH_NOTES`:
- 9-pre: Precondition checks (REVIEW_MODE gate, FEATURE_BRANCH capture, ISSUE_ID extraction, PR state idempotency check)
- 9a: CI check via `gh pr checks` — failing CI blocks merge, pending CI asks user (with "do not infer consent from silence" guard for auto mode)
- 9b: PR merge via `gh pr merge --merge --delete-branch`
- 9c: Sync dev branch from main repo root (uses `git rev-parse --git-common-dir` to escape worktree)
- 9d: Remove worktree (with bracketed branch format detection)
- 9d-2: Delete local feature branch
- 9d-3: Verify and delete remote feature branch (git ls-remote fallback per CLAUDE.md)
- 9e: Move Linear issue to Done (with sub-issue handling)
- 9f: Success output message

**Step 10 (Rejection Path)** — triggered when `LOOP_STATUS` is `ESCALATED`:
- 10-pre: Branch context capture and guards (REVIEW_MODE gate, ISSUE_ID gate)
- 10a: Post GitHub PR review with `--request-changes` (includes verdict, findings table, unresolved details, next steps)
- 10b: Post Linear comment (review summary, unresolved findings, next steps)
- 10c: Rejection output message

Key design decisions:
- Reused v1 patterns (merge commit strategy, worktree cleanup chain, remote branch verification) adapted to v2's convergence loop semantics
- Added precondition blocks (9-pre, 10-pre) to capture branch context before any `git checkout` changes state
- REVIEW_MODE gate prevents merge attempts when running in local-diff mode (no PR exists)
- PR state check provides idempotency on re-invocation (already-merged PR skips merge)

## Files Changed

- `skills/harness-review-v2/SKILL.md` — Added Steps 9-10 (approval/rejection paths), updated output contract table, updated error recovery table, updated scope boundary, updated state machine diagram

## Adversarial Review Findings

### Addressed (Critical/High)

1. **CRITICAL — No PR gate on merge path:** Step 9 assumed a PR always exists. Fixed: added `REVIEW_MODE == "pr"` check in Step 9-pre; if local-diff mode, skip merge and output warning.
2. **CRITICAL — No issue ID extraction:** Steps 9/10 referenced `$ISSUE_ID` without extracting it. Fixed: added `grep -oE 'WHI-[0-9]+'` extraction with empty check and error message.
3. **HIGH — Auto-mode silence consent:** CI pending path asked user to decide but didn't handle autonomous/auto mode. Fixed: added "do not infer consent from silence" instruction.
4. **HIGH — Worktree root vs main repo root:** `cd "$REPO_ROOT"` inside a worktree stays in the worktree. Fixed: use `git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel` to find the real repo root.
5. **HIGH — No idempotency on re-invocation:** Re-running after a successful merge would attempt to merge again. Fixed: added `gh pr view --json state` check; if MERGED, skip merge.
6. **HIGH — Ambiguous worktree grep:** `grep "$FEATURE_BRANCH"` could match substrings. Fixed: match `"\[${FEATURE_BRANCH}\]"` (bracketed format from `git worktree list`).

### Remaining (Medium/Low — not auto-fixed)

1. **MEDIUM — Duplicate reviews on re-invoke (M-3):** If skill is re-invoked after rejection, it re-runs the entire convergence loop from scratch rather than resuming. Not fixed — matches v2's existing no-retry/no-resume scope boundary.
2. **LOW — Output contract table not updated (L-1):** The output contract table at the top of SKILL.md may not reflect all new outputs from Steps 9-10. Human reviewer should verify.
3. **LOW — Template variable fallbacks (L-2):** Some bash variables in Steps 9-10 don't have `${VAR:-default}` fallback syntax. Low risk since precondition checks catch missing values early.

## PR

https://github.com/Whisker17/my-harness/pull/17

## Acceptance Criteria Status

- [x] PASS / PASS_WITH_NOTES triggers Approval Path: merge → sync dev → cleanup worktree/branch → verify remote branch → Linear Done — Step 9 (9a-9f)
- [x] ESCALATED triggers Rejection Path: `gh pr review --request-changes` with findings → Linear comment → issue stays In Review — Step 10 (10a-10c)
- [x] Approval Path includes CI check; CI failure blocks merge — Step 9a
- [x] Rejection Path PR comment includes verdict, findings table, unresolved details, next steps — Step 10a template
- [x] Linear comment format consistent with v1 (Approval: merged + Done; Rejection: changes requested + specific gaps) — Steps 9e and 10b
- [x] Error recovery: merge failure warns + preserves worktree; worktree deletion failure warns + doesn't block; Linear failure doesn't rollback merge — Step 9 error handling and updated error recovery table
