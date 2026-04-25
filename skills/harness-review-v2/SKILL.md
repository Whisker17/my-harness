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

This skill orchestrates Codex (adversarial reviewer) and Opus (acceptance reviewer) in a convergence loop. The skill implements the complete review pipeline: pre-flight checks, Codex invocation, findings normalization with `schema_version: 1`, re-raise detection, round merge logic, the Opus fix loop (resolve/rebut/defer handling with git commit/push), the convergence loop (max 3 rounds with stale detection), and final report generation.

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
MEDIUM_PLUS=$(jq '[.findings[] | select((.severity | ascii_upcase) == "CRITICAL" or (.severity | ascii_upcase) == "HIGH" or (.severity | ascii_upcase) == "MEDIUM")] | length' ".reviews/${BRANCH_SAFE}/codex-findings-round-${ROUND_N}.json")
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

Write a minimal findings file and skip to Step 8 (Final Report Generation):

```bash
jq -n --argjson round "$ROUND_N" \
  '{schema_version:1, round:$round, status:"PASS", verdict:"approve", findings:[]}' \
  > ".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"
```

STOP further normalization — proceed directly to Step 8 (Final Report Generation) with `LOOP_STATUS="PASS"`.

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
      claim_title: (.value.title // ""),
      claim: ((.value.title // "") + ": " + (.value.description // .value.body // "")),
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
  exit 1
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

**Match 1 — Exact title match (non-null only):**

```
new_finding.claim_title is not null
AND existing_finding.claim_title is not null
AND new_finding.claim_title == existing_finding.claim_title
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

# Extract verdict and summary from the NEW Codex round (not previous)
NEW_VERDICT=$(jq -r '.verdict' "$NEW_CODEX")
NEW_SUMMARY=$(jq -r '.summary' "$NEW_CODEX")

# Normalize new findings from Codex (temporary, for matching)
TMP_NORM=$(mktemp)
jq --argjson round "$ROUND_N" '
  .findings | to_entries | map({
    idx: .key,
    severity: (.value.severity | ascii_upcase | if . == "CRITICAL" or . == "HIGH" or . == "MEDIUM" or . == "LOW" then . else "MEDIUM" end),
    claim_title: (.value.title // ""),
    claim: ((.value.title // "") + ": " + (.value.description // .value.body // "")),
    file: (if (.value.file // "") == "" then null else .value.file end),
    line_start: (if (.value.file // "") == "" then null elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
    line_end: (if (.value.file // "") == "" then null elif .value.line_end then .value.line_end elif .value.line_start then .value.line_start elif .value.line then .value.line else null end),
    suggested_fix: (.value.recommendation // .value.description // .value.body // ""),
    round: $round
  })
' "$NEW_CODEX" > "$TMP_NORM"

# Run the merge with re-raise detection
jq -s --argjson round "$ROUND_N" --argjson max_id "$MAX_ID" --arg new_verdict "$NEW_VERDICT" --arg new_summary "$NEW_SUMMARY" '
  .[0] as $prev | .[1] as $new_findings |

  # For each new finding, check if it re-raises an existing one
  # Build a map of re-raises: existing_id → new_finding
  # For each new finding, check if it re-raises an existing one
  # Build a map of re-raises: existing_id → new_finding
  # Guard: only match if the existing finding hasn't already been claimed by a prior new finding
  (reduce $new_findings[] as $nf (
    {"map": {}, "claimed": []};
    . as $acc |
    ($prev.findings | to_entries | map(
      select(
        # Skip already-claimed existing findings (prevents overwrite when two new findings match the same existing one)
        ([.value.id] | inside($acc.claimed) | not)
        and
        (
          # Match 1: exact title match (guard against null == null)
          (.value.claim_title != null and $nf.claim_title != null and .value.claim_title == $nf.claim_title)
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
      )
    ) | first // null) as $match |
    if $match != null then
      {map: ($acc.map + {($match.value.id): $nf}), claimed: ($acc.claimed + [$match.value.id])}
    else
      {map: ($acc.map + {("__new_" + ($nf.idx | tostring)): $nf}), claimed: $acc.claimed}
    end
  ) | .map) as $reraise_map |

  # Build merged findings
  {
    schema_version: 1,
    round: $round,
    status: (if $new_verdict == "approve" then "PASS" else "FAIL" end),
    verdict: $new_verdict,
    summary: $new_summary,
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
            .status = "open" | .resolution = null | .round_opened = $round | .round_closed = null
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
' "$PREV_FINDINGS" "$TMP_NORM" > "$MERGED_OUTPUT"

rm -f "$TMP_NORM"
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

## Step 5 — Opus Fix Loop

This step presents the normalized findings from Step 4 to Opus, which resolves each finding by choosing RESOLVE, REBUT, or DEFER. After Opus acts on all findings, the skill verifies the changes, updates the findings JSON, and commits/pushes.

### 5a. Load Open Findings

Load the findings file from Step 4 and filter to open findings with severity CRITICAL, HIGH, or MEDIUM:

```bash
FINDINGS_FILE=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"

# Extract open findings that need Opus attention
OPEN_FINDINGS=$(jq '[.findings[] | select(.status == "open" and (.severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM"))]' "$FINDINGS_FILE")
OPEN_COUNT=$(echo "$OPEN_FINDINGS" | jq 'length')

echo "Open findings requiring Opus attention: $OPEN_COUNT"
```

**If `OPEN_COUNT == 0`:** No findings need fixing. Print:

```
No open CRITICAL/HIGH/MEDIUM findings — skipping Opus fix loop.
```

Skip to Step 6 (Convergence Loop) for convergence evaluation.

### 5b. Present Findings to Opus

Present the following **exact prompt text** to Opus. This is the literal prompt — do NOT paraphrase, summarize, or restructure it:

```
The following findings were identified by Codex adversarial review (Round {N}).
For each finding, you must take ONE action:

- RESOLVE: Fix the code. After fixing, the skill will verify the file was
  actually modified (git diff --name-only must include the file).
- REBUT: Explain with specific evidence why this finding is invalid.
  You must provide:
  - evidence_type: one of "code_reference", "test_reference", "doc_reference"
  - evidence_detail: the specific code snippet, test name, or doc section
    that proves the finding is wrong.
  "This is fine" is NOT a valid rebuttal.
- DEFER: Acknowledge the issue but explain why it's out of scope for this PR.
  Provide a justification. Deferred findings are recorded as notes for human
  review — no Linear issues are auto-created.

Findings:
[list each finding with id, severity, claim, file, lines, suggested_fix]
```

Replace `{N}` with the current round number. Replace the `[list each finding...]` placeholder with the actual findings formatted as:

```
- F-001 [CRITICAL] claim: "..." | file: path/to/file.ts:42-50 | suggested_fix: "..."
- F-002 [HIGH] claim: "..." | file: null | suggested_fix: "..."
```

For findings where `file` is null, display `file: null` (no line numbers). For findings where `file` is present but lines are null, display `file: path/to/file.ts` (no line range).

### 5c. Process Opus Responses

Opus will respond with an action for each finding. For each finding, extract the action and validate it:

#### RESOLVE action

1. Opus edits the code to fix the finding.
2. **Verify the fix:** Run `git diff --name-only` and confirm that at least one of the files associated with the finding appears in the diff. If the finding has `file: null` (architectural finding), accept any file change as valid.

```bash
MODIFIED_FILES=$(git diff --name-only)
```

3. **If verification passes:** Update the finding in the JSON:
   - `status`: `"resolved"`
   - `resolution`: A brief description of the fix applied (from Opus's response)
   - `round_closed`: current round number `N`

4. **If verification fails** (no file was actually modified): Log a warning and keep the finding as `open`:

```
WARNING: RESOLVE claimed for F-001 but git diff --name-only does not include the expected file(s).
Finding F-001 remains open.
```

#### REBUT action

1. Opus provides a rebuttal with:
   - `evidence_type`: Must be one of `"code_reference"`, `"test_reference"`, `"doc_reference"`
   - `evidence_detail`: A specific quote, path, test name, or doc section — NOT a generic dismissal

2. **Validate the rebuttal:**
   - `evidence_type` must be one of the three allowed values
   - `evidence_detail` must be a non-empty string with at least 10 characters (prevents "this is fine" rebuttals)

3. **If validation passes:** Update the finding in the JSON:
   - `status`: `"rebutted"`
   - `resolution`: `"REBUT ({evidence_type}): {evidence_detail}"`
   - `round_closed`: current round number `N`

4. **If validation fails** (invalid evidence_type or insufficient evidence_detail): Log a warning and keep the finding as `open`:

```
WARNING: REBUT for F-002 has invalid evidence. evidence_type must be one of: code_reference, test_reference, doc_reference. evidence_detail must be >= 10 characters.
Finding F-002 remains open.
```

#### DEFER action

1. Opus provides a justification for why this finding is out of scope.
2. **Validate:** The justification must be a non-empty string with at least 20 characters (prevents empty deferrals).

3. **If validation passes:** Update the finding in the JSON:
   - `status`: `"deferred"`
   - `resolution`: `"DEFER: {justification}"`
   - `round_closed`: current round number `N`

4. **If validation fails:** Log a warning and keep the finding as `open`:

```
WARNING: DEFER for F-003 has insufficient justification (< 20 characters).
Finding F-003 remains open.
```

**Important:** Deferred findings are recorded as notes only. Do NOT auto-create Linear issues for deferred findings (per design decision D9).

### 5d. Update Findings JSON

After processing all Opus responses, write the updated findings back to the same file:

```bash
FINDINGS_FILE=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"
```

Use jq to update each finding in-place based on the Opus responses. The structure of the findings file remains the same — only `status`, `resolution`, and `round_closed` fields are modified for findings that Opus acted on.

Example update for a single finding:

```bash
jq --arg fid "F-001" --arg status "resolved" --arg resolution "Fixed null check in validator" --argjson round_closed "$ROUND_N" '
  .findings = [.findings[] |
    if .id == $fid then
      .status = $status | .resolution = $resolution | .round_closed = $round_closed
    else . end
  ]
' "$FINDINGS_FILE" > "${FINDINGS_FILE}.tmp" && mv "${FINDINGS_FILE}.tmp" "$FINDINGS_FILE"
```

For batch updates (multiple findings in one pass), construct a jq filter that handles all findings at once:

```bash
# Build an update map: {"F-001": {"status": "resolved", "resolution": "...", "round_closed": N}, ...}
# Then apply it in a single jq pass:
jq --argjson updates "$UPDATES_JSON" '
  .findings = [.findings[] |
    . as $f |
    if $updates[$f.id] then
      .status = $updates[$f.id].status |
      .resolution = $updates[$f.id].resolution |
      .round_closed = $updates[$f.id].round_closed
    else . end
  ]
' "$FINDINGS_FILE" > "${FINDINGS_FILE}.tmp" && mv "${FINDINGS_FILE}.tmp" "$FINDINGS_FILE"
```

### 5e. Git Commit and Push

After updating the findings JSON and code fixes are in place, stage and commit all changes:

```bash
# Stage all modified files (Opus may have touched files beyond those in findings)
git add -A

# Build commit message with resolved finding IDs
# RESOLVED_IDS is a comma-separated list of finding IDs that were resolved in this round
# Example: "F-001, F-003"
git commit -m "fix(WHI-${ISSUE_N}): address codex review round ${ROUND_N} — ${RESOLVED_IDS}"
```

The commit message format is: `fix(WHI-N): address codex review round {N} — F-001, F-003`

- `WHI-N` is extracted from the branch name
- `{N}` is the current round number
- The finding IDs listed are ONLY those with action RESOLVE (not REBUT or DEFER)
- If no findings were resolved (all rebutted/deferred), use: `chore(WHI-N): update findings round {N} — rebuttals and deferrals only`

**Push to the feature branch:**

```bash
BRANCH_NAME=$(git branch --show-current)
git push origin "$BRANCH_NAME"
```

### 5f. Error Recovery — Git Commit Failure

If the git commit fails (merge conflict, pre-commit hook failure, empty commit, etc.):

1. **Capture the error:**

```bash
COMMIT_OUTPUT=$(git commit -m "..." 2>&1)
COMMIT_EXIT=$?

if [ "$COMMIT_EXIT" -ne 0 ]; then
  echo "ERROR: Git commit failed (exit code $COMMIT_EXIT)"
  echo "$COMMIT_OUTPUT"
fi
```

2. **Do NOT clean up the findings JSON.** The user needs the updated findings for manual retry.

3. **Print the failure message:**

```
Git commit failed: {stderr}.
Findings are preserved at .reviews/{branch_safe}/findings-round-{N}.json
```

4. **STOP.** Do not push. Do not proceed to the next round. The user must manually resolve the commit failure and re-invoke the skill.

### 5g. Round Summary

After a successful commit and push, display:

```
Opus Fix Loop Complete (Round {N})
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Resolved:  {resolved_count} findings (code fixed)
Rebutted:  {rebutted_count} findings (with evidence)
Deferred:  {deferred_count} findings (out of scope)
Still open: {still_open_count} findings (validation failed)

Committed: fix(WHI-{N}): address codex review round {ROUND_N} — {RESOLVED_IDS}
Pushed to: {branch_name}

Findings: .reviews/{branch_safe}/findings-round-{ROUND_N}.json
```

---

## Step 6 — Convergence Loop

This step orchestrates the outer loop: after Step 5 (Opus fix), re-invoke Codex for the full branch diff, normalize findings with round merge, run Opus fix again, and check convergence. Maximum 3 rounds.

### 6a. Loop Initialization

Initialize loop state before entering the convergence loop:

```bash
ROUND_N=1
MAX_ROUNDS=3
PREV_ACTIVE_IDS=""
LOOP_STATUS="CONTINUE"
```

**Round 1** is the initial invocation (Steps 2-5) which has already completed by the time Step 6 runs. The convergence check starts evaluating from the findings produced by round 1.

### 6b. Convergence Check (after each round)

After each round's Opus fix loop (Step 5) completes, evaluate convergence. Run the check defined in Step 7 below.

```
LOOP_STATUS = evaluate_convergence(ROUND_N, findings, PREV_ACTIVE_IDS)
```

**If `LOOP_STATUS` is `PASS`, `PASS_WITH_NOTES`, or `ESCALATED`:** Break out of the loop and proceed to Step 8 (Final Report).

**If `LOOP_STATUS` is `CONTINUE`:** Proceed to the next round (Step 6c).

### 6c. Next Round — Re-invoke Codex

When the loop continues, increment the round and re-invoke Codex on the **full branch diff** (not just the fix commit):

```bash
ROUND_N=$((ROUND_N + 1))
```

**Important:** Codex must re-review the FULL branch diff (`git diff dev...HEAD`), not just the changes from the fix commit. This ensures Codex evaluates the complete state of the branch.

1. **Re-invoke Codex** using the same mechanism as Step 2 (PR mode or local diff fallback). The Skill tool invocation is identical — Codex auto-detects the PR and reviews the full diff.

2. **Parse and normalize** the new Codex output using Steps 3-4. Because `ROUND_N > 1`, Step 4d (Round Merge) activates, performing re-raise detection against `findings-round-{N-1}.json`.

3. **Run Opus fix loop** (Step 5) on the merged findings for this round.

4. **Return to Step 6b** to re-evaluate convergence.

### 6d. Loop Orchestration Summary

The complete loop flow:

```
Round 1:
  Step 2 → Codex invocation
  Step 3 → Parse output
  Step 4 → Normalize findings (round 1, no merge)
  Step 5 → Opus fix loop
  Step 6b → Convergence check
    → CONTINUE? → Step 6c (Round 2)
    → PASS/PASS_WITH_NOTES/ESCALATED? → Step 8

Round 2:
  Step 6c → Re-invoke Codex (full branch diff)
  Step 3 → Parse output
  Step 4 → Normalize + merge with round 1 findings (re-raise detection)
  Step 5 → Opus fix loop
  Step 6b → Convergence check
    → CONTINUE? → Step 6c (Round 3)
    → PASS/PASS_WITH_NOTES/ESCALATED? → Step 8

Round 3:
  Step 6c → Re-invoke Codex (full branch diff)
  Step 3 → Parse output
  Step 4 → Normalize + merge with round 2 findings
  Step 5 → Opus fix loop
  Step 6b → Convergence check (MAX_ROUNDS forces ESCALATED if not PASS)
    → Step 8
```

---

## Step 7 — Convergence Check

Evaluate whether the review loop has converged. This check runs after each round's Opus fix loop completes.

### 7a. Compute Active Findings

Load the current round's findings and compute the active sets:

```bash
FINDINGS_FILE=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"

# Active findings: status in (open, disputed) AND severity in (critical, high, medium)
ACTIVE=$(jq '[.findings[] | select(
  (.status == "open" or .status == "disputed") and
  (.severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM")
)]' "$FINDINGS_FILE")
ACTIVE_COUNT=$(echo "$ACTIVE" | jq 'length')
ACTIVE_IDS=$(echo "$ACTIVE" | jq -r '[.[].id] | sort | join(",")')

# Low-only findings: status in (open, disputed) AND severity == low
LOW_ONLY=$(jq '[.findings[] | select(
  (.status == "open" or .status == "disputed") and
  .severity == "LOW"
)]' "$FINDINGS_FILE")
LOW_ONLY_COUNT=$(echo "$LOW_ONLY" | jq 'length')
```

### 7b. Evaluate Convergence (first match wins)

Evaluate the following conditions in order. The **first** matching condition determines the loop status:

```bash
if [ "$ACTIVE_COUNT" -eq 0 ] && [ "$LOW_ONLY_COUNT" -eq 0 ]; then
  LOOP_STATUS="PASS"
  echo "Convergence: PASS — 0 active findings, 0 low-only findings"

elif [ "$ACTIVE_COUNT" -eq 0 ] && [ "$LOW_ONLY_COUNT" -gt 0 ]; then
  LOOP_STATUS="PASS_WITH_NOTES"
  echo "Convergence: PASS_WITH_NOTES — 0 medium+ active, $LOW_ONLY_COUNT low-severity remain"

elif [ "$ROUND_N" -ge 2 ] && [ "$ACTIVE_IDS" = "$PREV_ACTIVE_IDS" ]; then
  LOOP_STATUS="ESCALATED"
  echo "Convergence: ESCALATED (stale) — active finding IDs identical to previous round"
  echo "Active IDs: $ACTIVE_IDS"

elif [ "$ROUND_N" -ge "$MAX_ROUNDS" ]; then
  LOOP_STATUS="ESCALATED"
  echo "Convergence: ESCALATED (max rounds) — reached round $ROUND_N of $MAX_ROUNDS"
  echo "Remaining active findings: $ACTIVE_COUNT"

else
  LOOP_STATUS="CONTINUE"
  echo "Convergence: CONTINUE — $ACTIVE_COUNT active findings remain, round $ROUND_N of $MAX_ROUNDS"
fi

# Store current active IDs for next round's stale detection
PREV_ACTIVE_IDS="$ACTIVE_IDS"
```

### 7c. Convergence Rules Reference

| Condition | Status | Description |
|-----------|--------|-------------|
| 0 active (medium+) AND 0 low-only | `PASS` | All findings resolved, rebutted, deferred, or confirmed fixed |
| 0 active (medium+) AND >0 low-only | `PASS_WITH_NOTES` | Only low-severity findings remain open |
| Round >= 2 AND active IDs == previous round's active IDs | `ESCALATED` (stale) | Loop is not making progress — same findings persist |
| Round >= 3 (MAX_ROUNDS) | `ESCALATED` (max rounds) | Hard cap reached |
| None of the above | `CONTINUE` | More rounds needed |

**Stale detection detail:**
- Compare `sorted(active_finding_ids_this_round)` vs `sorted(active_finding_ids_prev_round)`
- If identical, the loop is not making progress — Opus is unable to resolve or Codex keeps re-raising the same issues
- Only evaluated when `ROUND_N >= 2` (round 1 can never be stale — there's no previous round)
- Active findings = those with `status in ("open", "disputed")` AND `severity in ("CRITICAL", "HIGH", "MEDIUM")`

---

## Step 8 — Final Report Generation

After the convergence loop exits (PASS, PASS_WITH_NOTES, or ESCALATED), generate the final review report.

### 8a. Compute Report Data

Load the final round's findings and compute summary statistics:

```bash
FINAL_FINDINGS=".reviews/${BRANCH_SAFE}/findings-round-${ROUND_N}.json"
BRANCH_NAME=$(git branch --show-current)
REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Summary counts
TOTAL_FINDINGS=$(jq '.findings | length' "$FINAL_FINDINGS")
RESOLVED_COUNT=$(jq '[.findings[] | select(.status == "resolved")] | length' "$FINAL_FINDINGS")
CONFIRMED_FIXED_COUNT=$(jq '[.findings[] | select(.status == "confirmed_fixed")] | length' "$FINAL_FINDINGS")
REBUTTED_COUNT=$(jq '[.findings[] | select(.status == "rebutted")] | length' "$FINAL_FINDINGS")
DEFERRED_COUNT=$(jq '[.findings[] | select(.status == "deferred")] | length' "$FINAL_FINDINGS")
DISPUTED_COUNT=$(jq '[.findings[] | select(.status == "disputed")] | length' "$FINAL_FINDINGS")
OPEN_COUNT=$(jq '[.findings[] | select(.status == "open")] | length' "$FINAL_FINDINGS")
UNRESOLVED_COUNT=$((DISPUTED_COUNT + OPEN_COUNT))
```

### 8b. Write Report File

Write the report to `.reviews/{branch_safe}/review-report.md`:

```bash
REPORT_FILE=".reviews/${BRANCH_SAFE}/review-report.md"
```

**Report content:**

```markdown
# Harness Review v2 Report
Branch: {BRANCH_NAME} (path: .reviews/{BRANCH_SAFE}/)
Date: {REPORT_DATE}
Rounds: {ROUND_N}
Status: {LOOP_STATUS}

## Summary
- Total findings: {TOTAL_FINDINGS}
- Resolved: {RESOLVED_COUNT} | Rebutted: {REBUTTED_COUNT} | Deferred: {DEFERRED_COUNT}
- Confirmed fixed: {CONFIRMED_FIXED_COUNT}
- Disputed (unresolved): {DISPUTED_COUNT}
- Open (unresolved): {OPEN_COUNT}

## Findings Detail
| ID | Severity | Claim | Status | Resolution | Opened | Closed |
|----|----------|-------|--------|------------|--------|--------|
```

For each finding in the final findings JSON, append a row to the table:

```bash
jq -r '.findings[] | "| \(.id) | \(.severity) | \(.claim_title // .claim | .[0:60]) | \(.status) | \(.resolution // "—" | .[0:40]) | \(.round_opened) | \(.round_closed // "—") |"' "$FINAL_FINDINGS"
```

**Truncation:** Truncate `claim` to 60 characters and `resolution` to 40 characters in the table for readability. The full details are available in the findings JSON files.

### 8c. Unresolved Section (ESCALATED only)

If `LOOP_STATUS == "ESCALATED"`, append the Unresolved Issues section to the report:

```markdown
## Unresolved Issues

The following findings remain unresolved after {ROUND_N} rounds:

```

For each finding with `status in ("open", "disputed")` and `severity in ("CRITICAL", "HIGH", "MEDIUM")`, write a detailed entry:

```markdown
### {finding.id} [{finding.severity}] — {finding.claim_title}

**Status:** {finding.status}
**File:** {finding.file}:{finding.line_start}-{finding.line_end}
**Claim:** {finding.claim}
**Suggested fix:** {finding.suggested_fix}
**Resolution attempts:** {finding.resolution or "None"}
**Rounds:** opened in round {finding.round_opened}
```

If a finding has `file: null`, display `File: (architectural — no specific file)` instead.

### 8d. Console Output

After writing the report, print the appropriate console message based on the loop status:

**On PASS:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  REVIEW PASSED
Rounds: {ROUND_N}
Total findings: {TOTAL_FINDINGS}
Resolved: {RESOLVED_COUNT} | Confirmed fixed: {CONFIRMED_FIXED_COUNT}
Rebutted: {REBUTTED_COUNT} | Deferred: {DEFERRED_COUNT}
Review report: .reviews/{BRANCH_SAFE}/review-report.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**On PASS_WITH_NOTES:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  REVIEW PASSED (with notes)
Rounds: {ROUND_N}
Total findings: {TOTAL_FINDINGS}
Resolved: {RESOLVED_COUNT} | Confirmed fixed: {CONFIRMED_FIXED_COUNT}
Rebutted: {REBUTTED_COUNT} | Deferred: {DEFERRED_COUNT}
Low-severity remaining: {LOW_ONLY_COUNT} (documented in report)
Review report: .reviews/{BRANCH_SAFE}/review-report.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**On ESCALATED:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  REVIEW ESCALATED
Review loop did not converge after {ROUND_N} rounds. {UNRESOLVED_COUNT} findings remain unresolved.
Review report: .reviews/{BRANCH_SAFE}/review-report.md
Please review the disputed findings and decide how to proceed.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Output Contract

After completing Steps 1-8, the skill has produced:

| Artifact | Path | Description |
|----------|------|-------------|
| Codex findings JSON | `.reviews/{branch_safe}/codex-findings-round-{N}.json` | Raw structured Codex findings (one per round) |
| Normalized findings | `.reviews/{branch_safe}/findings-round-{N}.json` | Harness-format findings with `schema_version: 1`, updated with Opus resolutions (one per round) |
| Final review report | `.reviews/{branch_safe}/review-report.md` | Summary report with status, counts, findings table, and unresolved section (if ESCALATED) |
| Raw output (on parse failure) | `.reviews/{branch_safe}/codex-raw-round-{N}.txt` | Unprocessed Codex output |
| Local diff (if no PR) | `.reviews/{branch_safe}/local-diff.patch` | Git diff against dev |
| Invocation log | `.reviews/{branch_safe}/codex-invocation.log` | Timeout/retry tracking |

The final review report (`review-report.md`) is the primary artifact for human reviewers. The normalized findings files (`findings-round-{N}.json`) contain the full audit trail of each round's findings and Opus resolutions.

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
      "status": "open" | "resolved" | "confirmed_fixed" | "rebutted" | "disputed" | "deferred",
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
| RESOLVE verification failed | "git diff --name-only does not include file" | Finding stays open, Opus can retry next round |
| REBUT validation failed | "invalid evidence_type or insufficient evidence_detail" | Finding stays open, Opus can retry next round |
| DEFER validation failed | "insufficient justification" | Finding stays open, Opus can retry next round |
| Git commit failed (Step 5) | "Git commit failed: {stderr}" | Findings JSON preserved, fix manually and re-invoke |
| Git push failed (Step 5) | "Git push failed: {stderr}" | Commit exists locally, push manually or re-invoke |
| Codex re-review failed (Step 6) | Same as Step 2 errors | Fix the underlying issue and re-invoke the skill |
| Stale loop detected (Step 7) | "ESCALATED (stale)" | Review disputed findings in report, resolve manually |
| Max rounds reached (Step 7) | "ESCALATED (max rounds)" | Review unresolved findings in report, resolve manually |
| Report write failure (Step 8) | "Failed to write review report" | Check .reviews/ directory permissions, re-invoke |

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
- Opus fix loop: literal Opus prompt, RESOLVE/REBUT/DEFER handling, findings JSON update, git commit/push, error recovery
- Convergence loop: outer loop orchestration driving Codex re-review → Opus fix → convergence check (max 3 rounds)
- Convergence check: PASS, PASS_WITH_NOTES, STALE detection, MAX_ROUNDS → ESCALATED
- Final report generation: review-report.md with status, summary counts, findings detail table, unresolved section

This skill file does NOT cover (deferred to v3):
- Retry/resume (if the skill crashes mid-loop, user re-runs from scratch)
- Convergence metrics collection
- PR comment posting (the report is a local file only)
- Cost tracking
- Rebuttal quality enforcement beyond prompt guidance
- Rival branch spawning
- Auto-routing between v1/v2
- Codex model selection configuration
