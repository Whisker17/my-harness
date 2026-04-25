---
name: harness-review-v2
version: 0.1.0
description: "Cross-model review using Codex and Opus convergence loop. Validates acceptance criteria against the diff using multiple AI models. Invoke with /harness-review-v2 WHI-123."
triggers:
  - harness-review-v2
  - v2 review
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Agent
  - Skill
  - mcp__linear-server__get_issue
  - mcp__linear-server__save_issue
  - mcp__linear-server__save_comment
  - mcp__linear-server__list_comments
  - mcp__linear-server__list_issue_statuses
  - mcp__linear-server__list_issues
---

# harness-review-v2

You are running a cross-model convergence review for a Linear issue. The user invoked this skill as `/harness-review-v2 WHI-<N>` (or similar). Extract the issue ID from the invocation arguments.

This skill orchestrates Codex (adversarial reviewer) and Opus (acceptance reviewer) in a convergence loop. This file implements Step 1: pre-flight checks and initial Codex invocation. Later sub-issues will add findings normalization, convergence loop, and final report.

---

## Preamble

Before any steps, run these checks in a single bash block:

```bash
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

If the repo root is empty or CLAUDE.md is missing, warn the user and stop — this skill requires a properly configured project.

---

## Step 1 — Pre-flight Checks

Run the following pre-flight checks sequentially. If any check fails, print the error with an actionable fix message and STOP.

### 1a. Verify Codex CLI is installed

```bash
codex --version 2>&1
```

**On failure:**

```
ERROR: Codex CLI not found.

Fix: Run `codex:setup` to install and configure the Codex CLI.
```

STOP — do not proceed.

### 1b. Verify working tree is clean

```bash
git status --porcelain
```

**If output is non-empty:**

```
ERROR: Working tree has uncommitted changes.

Fix: Commit or stash your changes before running the review.
Uncommitted files:
<list the files from git status>
```

STOP — do not proceed.

### 1c. Compute branch-safe name and create artifacts directory

```bash
BRANCH_SAFE=$(git branch --show-current | tr '/' '-')
echo "branch_safe: $BRANCH_SAFE"
mkdir -p ".reviews/${BRANCH_SAFE}"
echo "Artifacts directory: .reviews/${BRANCH_SAFE}/"
```

Store `BRANCH_SAFE` for use throughout the rest of the skill.

**Note on branch_safe naming:** Nested slashes are handled by `tr '/' '-'`, so `feat/WHI-58/sub-task` becomes `feat-WHI-58-sub-task`.

### 1d. Detect PR or fall back to local diff

**Try PR detection first:**

```bash
gh pr view --json number,url,baseRefName 2>&1
```

**If successful:** Parse the JSON output and store:
- `PR_NUMBER` — the PR number
- `PR_URL` — the PR URL
- `PR_BASE` — the base ref name (e.g., `dev`)
- Set `REVIEW_MODE=pr`

**If `gh pr view` fails:** Fall back to local diff mode.

```bash
echo "WARNING: No PR found — reviewing local diff against dev"
REVIEW_MODE="local-diff"
git diff dev...HEAD > ".reviews/${BRANCH_SAFE}/local-diff.patch"
DIFF_SIZE=$(wc -l < ".reviews/${BRANCH_SAFE}/local-diff.patch")
echo "Local diff saved: .reviews/${BRANCH_SAFE}/local-diff.patch ($DIFF_SIZE lines)"
```

If the local diff is empty (0 lines), print:

```
ERROR: No changes detected between current branch and dev.

Fix: Ensure you have committed changes on this branch before running the review.
```

STOP — do not proceed.

---

## Step 2 — Codex Invocation

### 2a. PR mode (REVIEW_MODE=pr)

Invoke Codex via the Skill tool:

```
Skill(skill: "codex:adversarial-review")
```

The `codex:adversarial-review` plugin reads `GITHUB_TOKEN` and calls `gh pr view --json` internally to auto-detect the PR context. No arguments are needed.

**Timeout handling:** The Codex invocation should complete within 5 minutes. If the Skill tool call appears to hang or returns a timeout error:

1. Log the timeout: `echo "Codex invocation timed out (attempt 1/2)" >> ".reviews/${BRANCH_SAFE}/codex-invocation.log"`
2. Retry once with the same invocation
3. If the second attempt also times out, print:

```
ERROR: Codex invocation timed out after 2 attempts (5 minutes each).

The review could not be completed automatically.
Fix: Check Codex CLI connectivity with `codex --version` and retry, or run the review manually.
```

Save any partial output to `.reviews/${BRANCH_SAFE}/codex-raw-round-1.txt` and STOP.

### 2b. Local diff fallback (REVIEW_MODE=local-diff)

When no PR exists, invoke Codex in review mode with the diff content. Use the gstack `/codex` skill with the diff embedded in the prompt:

```
Skill(skill: "codex:rescue", args: "Review this diff for security issues, logic errors, edge cases, race conditions, resource leaks, and failure modes. Think like an attacker and chaos engineer. Classify each finding as CRITICAL, HIGH, MEDIUM, or LOW. Output structured JSON with fields: verdict (pass/fail), summary (string), findings (array of {severity, title, description, file, line}), next_steps (array of strings). Here is the diff:\n\n<contents of .reviews/${BRANCH_SAFE}/local-diff.patch>")
```

Apply the same timeout handling as PR mode (retry once, then ERROR).

---

## Step 3 — Parse Codex Output

### 3a. Extract structured JSON

The Codex output should contain a JSON object with these fields:

```json
{
  "verdict": "pass" | "fail",
  "summary": "One-paragraph summary of the review",
  "findings": [
    {
      "severity": "CRITICAL" | "HIGH" | "MEDIUM" | "LOW",
      "title": "Short finding title",
      "description": "Detailed description of the issue",
      "file": "path/to/file",
      "line": 42
    }
  ],
  "next_steps": [
    "Specific action item"
  ]
}
```

Attempt to parse the Codex output as JSON. The JSON may be embedded in markdown code fences or surrounded by other text.

**Parsing strategy:**

1. Look for a JSON code block: content between `` ```json `` and `` ``` `` markers
2. If not found, look for content between `{` and the last `}` that forms valid JSON
3. Try to parse the extracted content with `jq` or equivalent validation

```bash
# Example validation
echo '<extracted_json>' | jq -e '.verdict and .summary and .findings' > /dev/null 2>&1
```

### 3b. Handle parse failure

If JSON parsing fails:

1. Save the raw Codex output to `.reviews/${BRANCH_SAFE}/codex-raw-round-1.txt`:

```bash
echo '<raw_codex_output>' > ".reviews/${BRANCH_SAFE}/codex-raw-round-1.txt"
echo "WARNING: Failed to parse Codex output as JSON."
echo "Raw output saved to .reviews/${BRANCH_SAFE}/codex-raw-round-1.txt"
```

2. Attempt to extract findings manually by scanning the raw output for severity keywords (CRITICAL, HIGH, MEDIUM, LOW) and constructing a best-effort findings list.

3. If manual extraction also fails, print:

```
ERROR: Could not parse Codex review output.

Raw output saved to: .reviews/${BRANCH_SAFE}/codex-raw-round-1.txt
Fix: Inspect the raw output and re-run, or invoke codex:adversarial-review manually.
```

STOP — do not proceed.

### 3c. Store parsed results

On successful parse, save the structured JSON to:

```bash
echo '<parsed_json>' > ".reviews/${BRANCH_SAFE}/codex-findings-round-1.json"
```

Extract and display a summary:

```
Codex Review Complete (Round 1)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Verdict:  <verdict>
Summary:  <summary>
Findings: <N> total (<criticals> critical, <highs> high, <mediums> medium, <lows> low)

Next steps from Codex:
  - <next_step_1>
  - <next_step_2>
```

---

## Output Contract

After completing Steps 1-3, the skill has produced:

| Artifact | Path | Description |
|----------|------|-------------|
| Findings JSON | `.reviews/{branch_safe}/codex-findings-round-{N}.json` | Structured Codex findings |
| Raw output (on parse failure) | `.reviews/{branch_safe}/codex-raw-round-{N}.txt` | Unprocessed Codex output |
| Local diff (if no PR) | `.reviews/{branch_safe}/local-diff.patch` | Git diff against dev |
| Invocation log | `.reviews/{branch_safe}/codex-invocation.log` | Timeout/retry tracking |

These artifacts are consumed by the findings normalization step (WHI-220) and the convergence loop (WHI-222).

---

## Error Recovery Reference

| Failure point | Error message | Recovery action |
|---------------|---------------|-----------------|
| Codex CLI not found | "Run `codex:setup` to install" | Install Codex, re-invoke |
| Dirty working tree | "Commit or stash changes first" | Clean working tree, re-invoke |
| No PR + no local diff | "No changes detected" | Ensure commits exist on branch |
| Codex timeout (2x) | "Codex invocation timed out" | Check connectivity, retry manually |
| JSON parse failure | "Could not parse Codex output" | Inspect raw output, retry |

**Never proceed past a STOP error.** Each error is terminal for this invocation. Fix the issue and re-invoke the skill.

---

## Scope Boundary

This skill file covers ONLY:
- Pre-flight checks (Codex CLI, clean tree, branch_safe, PR detection)
- Codex invocation (PR mode and local diff fallback)
- Raw output capture and JSON parsing

This skill file does NOT cover (handled by later sub-issues):
- Findings normalization and re-raise detection (WHI-220)
- Convergence loop and final report generation (WHI-222)
- Opus acceptance review integration
- Fix loop orchestration
