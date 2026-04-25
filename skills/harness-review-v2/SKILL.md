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

This skill orchestrates Codex (adversarial reviewer) and Opus (acceptance reviewer) in a convergence loop. This file implements Steps 1-4: pre-flight checks, initial Codex invocation, findings normalization with `schema_version: 1`, re-raise detection, and round merge logic. Later sub-issues will add the Opus fix loop (WHI-221), convergence loop, and final report (WHI-222).

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

### 1a-2. Verify Codex authentication

After confirming the CLI is installed, verify that Codex is authenticated:

```bash
codex auth status 2>&1 || codex whoami 2>&1
```

If the command fails or indicates no active session:

```
ERROR: Codex CLI is not authenticated.

Fix: Run `codex login` to authenticate with your Codex account.
```

STOP — do not proceed.

**Note:** If neither `codex auth status` nor `codex whoami` is a valid subcommand, skip this check — authentication errors will surface during the Codex invocation in Step 2, where the error handler should also emit the `"Run codex login to authenticate"` message.

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

**Authentication failure handling:** If the Codex invocation fails with an authentication or authorization error (e.g., "unauthorized", "not logged in", "invalid token"), print:

```
ERROR: Codex authentication failed.

Fix: Run `codex login` to authenticate with your Codex account.
```

STOP — do not proceed. Do not retry auth failures.

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

## Step 4 — Findings Normalization

This step takes the parsed Codex output from Step 3 (`codex-findings-round-{N}.json`) and normalizes it into the harness findings protocol (`findings-round-{N}.json`) with `schema_version: 1`.

### 4a. Quick Exit Check

Before normalizing, check if the review can exit early:

```bash
VERDICT=$(jq -r '.verdict' ".reviews/${BRANCH_SAFE}/codex-findings-round-${ROUND_N}.json")
MEDIUM_PLUS=$(jq '[.findings[] | select(.severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM")] | length' ".reviews/${BRANCH_SAFE}/codex-findings-round-${ROUND_N}.json")
```

**If `VERDICT == "approve"` (case-insensitive) AND `MEDIUM_PLUS == 0`:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  QUICK EXIT — PASS
Codex verdict: approve
Medium+ findings: 0
Status: PASS — skip to report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Write a minimal findings file and skip to the report step (WHI-222):

```bash
cat > ".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json" <<'FINDINGS_EOF'
{
  "schema_version": 1,
  "round": <ROUND_N>,
  "status": "PASS",
  "verdict": "approve",
  "findings": []
}
FINDINGS_EOF
```

STOP further normalization — the convergence loop (WHI-222) will handle the report.

**Otherwise:** Proceed with full normalization below.

### 4b. Normalize Codex Findings

For each finding in the Codex output, map it to the harness findings schema:

**Normalization mapping (Codex → harness):**

```
codex.findings[i].severity       → finding.severity        (string, uppercase: CRITICAL/HIGH/MEDIUM/LOW)
codex.findings[i].title          → finding.claim_title      (string)
codex.findings[i].title + ": " + codex.findings[i].description → finding.claim  (concatenated string)
codex.findings[i].file           → finding.file             (string or null if missing/empty)
codex.findings[i].line_start     → finding.line_start       (integer or null if missing)
codex.findings[i].line_end       → finding.line_end         (integer or null if missing)
codex.findings[i].line           → finding.line_start       (fallback: if only "line" exists, use it as both line_start and line_end)
codex.findings[i].recommendation → finding.suggested_fix    (string, use "description" as fallback if recommendation is missing)
```

**ID generation:** Assign each finding a sequential ID in format `F-NNN` (zero-padded 3-digit):

- For round 1: start at `F-001`
- For round N+1: continue from the highest ID used in round N (see Step 4d for merge logic)

**Default field values for new findings:**

```json
{
  "id": "F-001",
  "severity": "HIGH",
  "claim_title": "Short finding title",
  "claim": "Short finding title: Detailed description of the issue",
  "file": "path/to/file.ts",
  "line_start": 42,
  "line_end": 42,
  "suggested_fix": "Recommendation text from Codex",
  "status": "open",
  "resolution": null,
  "round_opened": 1,
  "round_closed": null
}
```

**Nullable fields handling:**

- `file`: set to `null` if the Codex finding has no `file` field, or if the value is an empty string
- `line_start`: set to `null` if no line information is provided, or if `file` is null (line without file is meaningless)
- `line_end`: set to `null` if not provided; if only `line` or `line_start` is provided, mirror it to `line_end`

**Severity normalization:**

- Uppercase the severity string: `"high"` → `"HIGH"`, `"Critical"` → `"CRITICAL"`
- If severity is not one of `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, default to `"MEDIUM"` and log a warning

Use bash/jq to perform the normalization:

```bash
ROUND_N=${ROUND_N:-1}
CODEX_FILE=".reviews/${BRANCH_SAFE}/codex-findings-round-${ROUND_N}.json"

jq --argjson round "$ROUND_N" '
{
  schema_version: 1,
  round: $round,
  status: (if .verdict == "approve" then "PASS" else "FAIL" end),
  verdict: .verdict,
  summary: .summary,
  findings: [
    .findings | to_entries[] |
    {
      id: ("F-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end)),
      severity: (.value.severity | ascii_upcase | if . == "CRITICAL" or . == "HIGH" or . == "MEDIUM" or . == "LOW" then . else "MEDIUM" end),
      claim_title: .value.title,
      claim: (.value.title + ": " + (.value.description // .value.body // "")),
      file: (if (.value.file // "") == "" then null else .value.file end),
      line_start: (if (.value.file // "") == "" then null elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
      line_end: (if (.value.file // "") == "" then null elif .value.line_end then .value.line_end elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
      suggested_fix: (.value.recommendation // .value.description // .value.body // ""),
      status: "open",
      resolution: null,
      round_opened: $round,
      round_closed: null
    }
  ]
}' "$CODEX_FILE" > ".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"
```

### 4c. Validate Normalized Output

After writing the findings file, validate its structure:

```bash
FINDINGS_FILE=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"

# Validate schema_version
SCHEMA_VER=$(jq -r '.schema_version' "$FINDINGS_FILE")
if [ "$SCHEMA_VER" != "1" ]; then
  echo "ERROR: findings-round-${ROUND_N}.json has invalid schema_version: $SCHEMA_VER (expected 1)"
  # Attempt to fix by re-running normalization
fi

# Validate all findings have required fields
INVALID_COUNT=$(jq '[.findings[] | select(
  .id == null or .severity == null or .claim == null or
  .status == null or .round_opened == null
)] | length' "$FINDINGS_FILE")

if [ "$INVALID_COUNT" -gt 0 ]; then
  echo "WARNING: $INVALID_COUNT findings have missing required fields"
  jq '.findings[] | select(
    .id == null or .severity == null or .claim == null or
    .status == null or .round_opened == null
  ) | .id' "$FINDINGS_FILE"
fi

# Report summary
TOTAL=$(jq '.findings | length' "$FINDINGS_FILE")
CRITICALS=$(jq '[.findings[] | select(.severity == "CRITICAL")] | length' "$FINDINGS_FILE")
HIGHS=$(jq '[.findings[] | select(.severity == "HIGH")] | length' "$FINDINGS_FILE")
MEDIUMS=$(jq '[.findings[] | select(.severity == "MEDIUM")] | length' "$FINDINGS_FILE")
LOWS=$(jq '[.findings[] | select(.severity == "LOW")] | length' "$FINDINGS_FILE")

echo ""
echo "Findings Normalization Complete (Round ${ROUND_N})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Schema version: 1"
echo "Total findings: $TOTAL"
echo "  CRITICAL: $CRITICALS"
echo "  HIGH:     $HIGHS"
echo "  MEDIUM:   $MEDIUMS"
echo "  LOW:      $LOWS"
echo "Output: $FINDINGS_FILE"
```

### 4d. Round Merge (Round N+1 only)

**This section applies only when `ROUND_N > 1`.** For round 1, skip to Step 4e.

When processing round N+1, merge the new Codex findings with the findings from round N. The merge uses re-raise detection to determine which previous findings are confirmed fixed vs. re-opened.

#### Re-raise Detection Algorithm

For each new Codex finding in round N+1, check it against every finding from round N:

**Match 1 — Exact title match:**

```
new_finding.claim_title == existing_finding.claim_title
```

If matched → this is a re-raise of the existing finding.

**Match 2 — Same file + overlapping line range (±15 lines):**

```
new_finding.file == existing_finding.file
AND new_finding.file is not null
AND new_finding.line_start - 15 <= existing_finding.line_end
AND new_finding.line_end + 15 >= existing_finding.line_start
```

Both `new_finding` and `existing_finding` must have non-null `file` and non-null `line_start`/`line_end` for this match to apply.

If matched → this is a re-raise of the existing finding.

**No match → genuinely new finding.** Assign a new sequential ID continuing from the highest used in round N.

#### Merge Logic

Use jq (or equivalent) to perform the merge. The algorithm:

```bash
PREV_FINDINGS=".reviews/${BRANCH_SAFE}/findings-round-$((ROUND_N - 1)).json"
NEW_CODEX=".reviews/${BRANCH_SAFE}/codex-findings-round-${ROUND_N}.json"
MERGED_OUTPUT=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"

# The merge script reads the previous findings and new Codex output,
# applies re-raise detection, and produces the merged findings file.
```

**Step-by-step merge process:**

1. **Load previous findings** from `findings-round-{N-1}.json`
2. **Normalize new Codex findings** using the same mapping as Step 4b (but do NOT assign IDs yet)
3. **For each new Codex finding**, run re-raise detection against all previous findings:
   - If re-raised: mark the new finding with `reraise_of: <existing_id>`
   - If not matched: mark as genuinely new
4. **Build the merged findings list:**

   For each finding from round N-1:

   | Previous status | Re-raised in N? | New status | Additional changes |
   |-----------------|-----------------|------------|-------------------|
   | `open` | Yes | `open` | Keep as-is (still open) |
   | `open` | No | `open` | Keep as-is (reviewer hasn't addressed it) |
   | `resolved` | No | `confirmed_fixed` | Set `round_closed: N` |
   | `resolved` | Yes | `open` | Clear `resolution`, set `round_opened: N` |
   | `rebutted` | No | `rebutted` | Keep as-is (rebuttal stands) |
   | `rebutted` | Yes | `disputed` | The reviewer disagreed but Codex insists |
   | `confirmed_fixed` | No | `confirmed_fixed` | Keep as-is |
   | `confirmed_fixed` | Yes | `open` | Regression detected, reopen |
   | `disputed` | No | `disputed` | Keep as-is |
   | `disputed` | Yes | `disputed` | Keep as-is (still contested) |

5. **Append genuinely new findings** with new sequential IDs:
   - Find the highest existing ID number: `MAX_ID = max(all finding IDs as integers)`
   - New findings get `F-{MAX_ID + 1}`, `F-{MAX_ID + 2}`, etc.
   - Set `round_opened: N`, `status: "open"`, `resolution: null`, `round_closed: null`

6. **Write the merged output** to `findings-round-{N}.json` with `schema_version: 1`

**Merge implementation using jq:**

```bash
# Extract max ID from previous round
MAX_ID=$(jq '[.findings[].id | ltrimstr("F-") | tonumber] | max // 0' "$PREV_FINDINGS")

# Normalize new findings from Codex (temporary, for matching)
jq --argjson round "$ROUND_N" '
  .findings | to_entries | map({
    idx: .key,
    severity: (.value.severity | ascii_upcase),
    claim_title: .value.title,
    claim: (.value.title + ": " + (.value.description // .value.body // "")),
    file: (if (.value.file // "") == "" then null else .value.file end),
    line_start: (if (.value.file // "") == "" then null elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
    line_end: (if (.value.file // "") == "" then null elif .value.line_end then .value.line_end elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
    suggested_fix: (.value.recommendation // .value.description // .value.body // ""),
    round: $round
  })
' "$NEW_CODEX" > "/tmp/new_normalized.json"

# Run the merge with re-raise detection
jq -s --argjson round "$ROUND_N" --argjson max_id "$MAX_ID" '
  .[0] as $prev | .[1] as $new_findings |

  # For each new finding, check if it re-raises an existing one
  # Build a map of re-raises: existing_id → new_finding
  (reduce $new_findings[] as $nf (
    {};
    . as $acc |
    ($prev.findings | to_entries | map(
      select(
        # Match 1: exact title match
        (.value.claim_title == $nf.claim_title)
        or
        # Match 2: same file + overlapping lines ±15
        (
          .value.file != null and $nf.file != null and
          .value.file == $nf.file and
          .value.line_start != null and .value.line_end != null and
          $nf.line_start != null and $nf.line_end != null and
          ($nf.line_start - 15) <= .value.line_end and
          ($nf.line_end + 15) >= .value.line_start
        )
      )
    ) | first // null) as $match |
    if $match != null then
      $acc + {($match.value.id): $nf}
    else
      $acc + {("__new_" + ($nf.idx | tostring)): $nf}
    end
  )) as $reraise_map |

  # Build merged findings
  {
    schema_version: 1,
    round: $round,
    status: $prev.status,
    verdict: $prev.verdict,
    summary: $prev.summary,
    findings: (
      # Process existing findings
      [
        $prev.findings[] |
        . as $existing |
        if $reraise_map[$existing.id] != null then
          # This finding was re-raised
          if .status == "resolved" then
            .status = "open" | .resolution = null | .round_opened = $round
          elif .status == "rebutted" then
            .status = "disputed"
          elif .status == "confirmed_fixed" then
            .status = "open" | .resolution = null | .round_opened = $round
          else
            .
          end
        else
          # Not re-raised
          if .status == "resolved" then
            .status = "confirmed_fixed" | .round_closed = $round
          else
            .
          end
        end
      ] +
      # Append genuinely new findings (re-index for sequential IDs)
      [
        [ $reraise_map | to_entries[] |
          select(.key | startswith("__new_")) |
          .value
        ] | to_entries[] |
        ($max_id + .key + 1) as $new_id |
        .value |
        {
          id: ("F-" + ($new_id | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end)),
          severity: .severity,
          claim_title: .claim_title,
          claim: .claim,
          file: .file,
          line_start: .line_start,
          line_end: .line_end,
          suggested_fix: .suggested_fix,
          status: "open",
          resolution: null,
          round_opened: $round,
          round_closed: null
        }
      ]
    )
  }
' "$PREV_FINDINGS" "/tmp/new_normalized.json" > "$MERGED_OUTPUT"

rm -f /tmp/new_normalized.json
```

### 4e. Display Findings Summary

After normalization (or merge), display the findings summary:

```
Findings Normalization Complete (Round N)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Schema version: 1
Total findings:     <total>
  CRITICAL:         <count>
  HIGH:             <count>
  MEDIUM:           <count>
  LOW:              <count>
Open:               <open_count>
Confirmed fixed:    <confirmed_count>
Disputed:           <disputed_count>
New this round:     <new_count>
Re-raised:          <reraised_count>

Output: .reviews/{branch_safe}/findings-round-{N}.json
```

For round 1, skip the "Confirmed fixed", "Disputed", "New this round", and "Re-raised" lines (they only apply to round N+1 merges).

---

## Output Contract

After completing Steps 1-4, the skill has produced:

| Artifact | Path | Description |
|----------|------|-------------|
| Codex findings JSON | `.reviews/{branch_safe}/codex-findings-round-{N}.json` | Raw structured Codex findings |
| Normalized findings | `.reviews/{branch_safe}/findings-round-{N}.json` | Harness-format findings with `schema_version: 1` |
| Raw output (on parse failure) | `.reviews/{branch_safe}/codex-raw-round-{N}.txt` | Unprocessed Codex output |
| Local diff (if no PR) | `.reviews/{branch_safe}/local-diff.patch` | Git diff against dev |
| Invocation log | `.reviews/{branch_safe}/codex-invocation.log` | Timeout/retry tracking |

The normalized findings file (`findings-round-{N}.json`) is the primary artifact consumed by the convergence loop (WHI-222) and the Opus fix loop (WHI-221).

**Findings JSON schema (`schema_version: 1`):**

```json
{
  "schema_version": 1,
  "round": 1,
  "status": "PASS" | "FAIL",
  "verdict": "approve" | "fail",
  "summary": "Review summary text",
  "findings": [
    {
      "id": "F-001",
      "severity": "CRITICAL" | "HIGH" | "MEDIUM" | "LOW",
      "claim_title": "Short finding title",
      "claim": "Short finding title: Detailed description",
      "file": "path/to/file.ts" | null,
      "line_start": 42 | null,
      "line_end": 50 | null,
      "suggested_fix": "Recommendation text",
      "status": "open" | "resolved" | "confirmed_fixed" | "rebutted" | "disputed",
      "resolution": "Description of how it was fixed" | null,
      "round_opened": 1,
      "round_closed": null | 2
    }
  ]
}
```

---

## Error Recovery Reference

| Failure point | Error message | Recovery action |
|---------------|---------------|-----------------|
| Codex CLI not found | "Run `codex:setup` to install" | Install Codex, re-invoke |
| Codex not authenticated | "Run `codex login` to authenticate" | Authenticate, re-invoke |
| Dirty working tree | "Commit or stash changes first" | Clean working tree, re-invoke |
| No PR + no local diff | "No changes detected" | Ensure commits exist on branch |
| Codex timeout (2x) | "Codex invocation timed out" | Check connectivity, retry manually |
| Codex auth failure during invocation | "Run `codex login` to authenticate" | Re-authenticate, re-invoke |
| JSON parse failure | "Could not parse Codex output" | Inspect raw output, retry |
| Normalization validation failure | "findings has invalid schema_version" | Re-run normalization step |
| Merge conflict (round N+1) | "Failed to merge findings" | Inspect previous round file, re-run |

**Never proceed past a STOP error.** Each error is terminal for this invocation. Fix the issue and re-invoke the skill.

---

## Scope Boundary

This skill file covers:
- Pre-flight checks (Codex CLI, clean tree, branch_safe, PR detection)
- Codex invocation (PR mode and local diff fallback)
- Raw output capture and JSON parsing
- Findings normalization to `schema_version: 1` format
- Re-raise detection (exact title match OR same file + overlapping lines ±15)
- Round merge logic (confirmed_fixed, reopened, disputed states)
- Quick exit path (approve + 0 medium+ → PASS)

This skill file does NOT cover (handled by later sub-issues):
- Convergence loop and final report generation (WHI-222)
- Opus fix loop — resolve, rebut, defer handling (WHI-221)
- Fix loop orchestration
