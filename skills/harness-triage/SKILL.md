---
name: harness-triage
version: 1.0.0
description: "Reactive course correction skill: formalizes mid-development findings as Linear issues with conflict detection. Creates, modifies, or cancels issues — never writes code. Invoke with /harness-triage <finding> or /harness-triage <project-id> <finding>."
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
  - mcp__linear-server__get_issue
  - mcp__linear-server__save_issue
  - mcp__linear-server__save_comment
  - mcp__linear-server__list_issues
  - mcp__linear-server__list_comments
  - mcp__linear-server__get_project
  - mcp__linear-server__list_projects
  - mcp__linear-server__list_teams
  - mcp__linear-server__list_issue_statuses
---

# harness-triage

You are formalizing a mid-development finding into Linear issues with conflict detection. The user invoked this skill as `/harness-triage <finding>` or `/harness-triage <project-id> <finding>`. Extract the arguments from the invocation.

This skill is **reactive** — it handles course corrections during development. It creates and modifies Linear issues but **never writes code**.

## Preamble

Before any steps, run these checks in a single bash block:

```bash
# Detect repo context
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CLAUDE_MD_EXISTS=$([ -f "$REPO_ROOT/CLAUDE.md" ] && echo "yes" || echo "no")

echo "Branch: $CURRENT_BRANCH"
echo "Repo root: $REPO_ROOT"
echo "CLAUDE.md: $CLAUDE_MD_EXISTS"
```

Read the schema for issue validation:

```bash
SCHEMA="$HOME/.claude/skills/harness-dev/schema.md"
if [ ! -s "$SCHEMA" ]; then
  echo "STOP: harness-dev schema not found or empty: $SCHEMA"
  exit 1
fi
echo "Schema: $SCHEMA (ok)"
```

If the schema is missing, print:

```
🛑  STOP: harness-dev schema not found at ~/.claude/skills/harness-dev/schema.md
    Install or repair the harness-dev skill before running harness-triage.
    (The schema is required to generate schema-compliant issue descriptions.)
```

Do NOT proceed without the schema.

**CLAUDE.md tolerance:** harness-triage tolerates a missing CLAUDE.md. If CLAUDE.md is absent, print a warning and continue — the branch/repo context is informational only and is not required for Linear mutations.

---

## Step 1 — Input Resolution

Parse the invocation arguments. Two cases:

### Case A: `<project-id> <finding>`

The first argument looks like a Linear project identifier (UUID, URL slug, or short name). Try to resolve it:

```
mcp__linear-server__get_project(query: "<first-argument>")
```

If it resolves:
- Record the project `id` and `name`
- The remaining text is the finding
- Print: `Resolved project: <name> (<id>)`

If it does NOT resolve, fall through to Case B — treat the entire argument as a finding.

### Case B: `<finding>` only (no explicit project)

Attempt to resolve the project from context:

1. **Check CLAUDE.md** for a project reference (look for `Linear`, `project:`, or project identifiers)
2. **Check the current Linear issue context** — if the user is inside a worktree for `WHI-<N>`, fetch that issue and use its project:

```bash
# Try to extract issue ID from current branch name
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
ISSUE_ID=$(echo "$BRANCH" | grep -oP 'WHI-\d+' | head -1)
echo "Branch issue: ${ISSUE_ID:-none}"
```

If an issue ID is found, fetch it to get the project:

```
mcp__linear-server__get_issue(id: "<issue-id>")
```

Use the issue's `project` and `projectId` fields.

3. **If no project can be resolved**, ask the user:

```
AskUserQuestion(
  "Which project does this finding belong to?
   Provide the project name, ID, or URL slug."
)
```

Try to resolve the user's answer with `mcp__linear-server__get_project`. If resolution fails after 2 attempts, STOP with:

```
🛑  Could not resolve a project after 2 attempts. Check the project name and re-invoke.
```

### Case C: No arguments provided

Use `AskUserQuestion`:

```
AskUserQuestion(
  "What did you discover that needs triage?

   Describe the finding — a bug, a design flaw, a missing requirement,
   or a new insight that requires adjusting the backlog."
)
```

Then resolve the project using Case B logic.

**After input resolution, you must have:**
- `PROJECT_ID` — the Linear project ID
- `PROJECT_NAME` — the Linear project name
- `TEAM_ID` — the Linear team ID (extracted from the project's `team`/`teamId` fields, or resolved via `mcp__linear-server__list_teams` and user selection)
- `FINDING` — the natural language finding text

Print:

```
Project: <PROJECT_NAME> (<PROJECT_ID>)
Team: <TEAM_ID>
Finding: <FINDING>
```

---

## Step 2 — Fetch Existing Issues

Fetch all non-Done issues in the project to build the conflict detection surface. Use `PROJECT_ID` (not name) for precise matching. Set `limit: 250` to maximize coverage. Query across all active states:

```
mcp__linear-server__list_issues(project: "<PROJECT_ID>", state: "In Progress", limit: 250)
mcp__linear-server__list_issues(project: "<PROJECT_ID>", state: "Todo", limit: 250)
mcp__linear-server__list_issues(project: "<PROJECT_ID>", state: "Backlog", limit: 250)
mcp__linear-server__list_issues(project: "<PROJECT_ID>", state: "In Review", limit: 250)
```

**Note:** Conflict detection scans up to 250 active issues per state. For projects with >250 issues per state, warn the user: "Large project — conflict scan may be incomplete. Manual verification recommended."

**If any Linear API call fails:**
- Print: `⚠️  Linear API unavailable — cannot check for conflicts. Please verify manually or retry.`
- Use `AskUserQuestion` to ask whether the user wants to retry or abort
- Do NOT silently skip conflict detection

Collect all returned issues into `EXISTING_ISSUES`. For each issue, record:
- `id` (e.g., `WHI-123`)
- `title`
- `description` (full text)
- `status` (current state)
- `priority`

Print:

```
Fetched <N> active issues in <PROJECT_NAME>.
```

---

## Step 3 — Conflict Detection

Analyze the finding against every issue in `EXISTING_ISSUES`. Check for four conflict categories:

### 3a. Scope Overlap

The finding describes work that touches the same area as an existing issue.

**Detection heuristics:**
- Extract key terms from the finding: file paths, component names, feature names, function names, API endpoints — terms longer than 5 characters that are not common stop words (e.g., ignore "should", "update", "create", "implement", "handle")
- For each existing issue, scan its `## Architecture Notes` and `## Acceptance Criteria` sections for the same key terms. Skip `@@DEP:...@@` placeholder lines during scanning.
- Overlap threshold: 2+ matching key terms in the same issue signals potential scope overlap

**If detected:** Record as `SCOPE_OVERLAP` with the conflicting issue ID and the overlapping terms.

### 3b. Invalidation

The finding makes an existing issue's approach wrong or unnecessary.

**Detection heuristics:**
- The finding explicitly contradicts an existing issue's `## Architecture Notes` (different approach to the same problem)
- The finding renders an existing issue's `## Acceptance Criteria` moot (the criteria no longer apply)
- The finding describes a discovery that makes an existing issue's `## Context` outdated

**If detected:** Record as `INVALIDATION` with the affected issue ID and what is invalidated.

### 3c. Dependency Change

The finding introduces a new prerequisite or removes an existing one.

**Detection heuristics:**
- The finding describes work that must be done before an existing issue can proceed
- The finding removes a blocker that was previously assumed necessary
- The finding changes the order of execution between issues

**If detected:** Record as `DEPENDENCY_CHANGE` with the affected issue IDs and the new dependency relationship.

### 3d. Description Staleness

The finding reveals that an existing issue's description no longer matches reality.

**Detection heuristics:**
- The finding describes the current state of the system differing from what an existing issue assumes
- Implementation has progressed past what an existing issue's description expects
- External factors have changed (API deprecation, library update, etc.)

**If detected:** Record as `DESCRIPTION_STALENESS` with the affected issue ID and what is stale.

### Ambiguity handling

If a conflict classification is ambiguous (could be scope overlap OR invalidation), do NOT guess. Record both possibilities and surface them to the user in Step 4.

---

## Step 4 — Draft Proposed Changes

Based on the conflict analysis, draft a plan of Linear changes. The plan consists of three categories:

### 4a. Issues to Create

If the finding represents genuinely new work not covered by any existing issue, draft a new issue description using all five schema sections.

**Issue description generation rules** (same as harness-design Step 6):

The five required headings (verbatim, as level-2 markdown headings):
- `## Context`
- `## Acceptance Criteria`
- `## Architecture Notes`
- `## Dependencies`
- `## Scope Boundary`

**`## Context`** — What this issue is about, why it matters, where it fits. Minimum 2-3 sentences.

**`## Acceptance Criteria`** — Checklist format: `- [ ] Concrete, testable criterion`. Minimum 3 criteria. Each must be independently verifiable.

**`## Architecture Notes`** — Key files, function signatures, error handling, patterns to follow. Be specific.

**`## Dependencies`** — List blocking issues by `WHI-<N>` ID. Write `None — no blocking dependencies.` if none.

**`## Scope Boundary`** — What is explicitly NOT in scope. Minimum 2 exclusions.

**Self-validation (REQUIRED):**

Before presenting any issue description to the user, validate:

1. All five headings present (regex: `^## (Context|Acceptance Criteria|Architecture Notes|Dependencies|Scope Boundary)`)
2. Strip placeholder lines matching `^\[.*\]$` (square-bracket placeholders only — matches the canonical schema at `~/.claude/skills/harness-dev/schema.md` and harness-dev's quality gate)
3. Remaining non-whitespace chars >= 20 per section

If validation fails, regenerate. If regeneration fails twice, warn and present anyway with a note about which section is weak.

### 4b. Issues to Modify

For each conflict detected in Step 3, draft the proposed modification:

| Conflict Type | Proposed Modification |
|---------------|----------------------|
| Scope overlap | Add a comment on the existing issue explaining the overlap; optionally propose splitting scope by updating `## Scope Boundary` |
| Invalidation | Update the affected sections (`## Architecture Notes`, `## Acceptance Criteria`, or `## Context`) with corrected content; or propose cancelling the issue |
| Dependency change | Add/remove `blockedBy` relations; update `## Dependencies` section |
| Description staleness | Update the stale sections with current information |

For each modification, prepare:
- The issue ID and title
- Which sections will change
- The exact new content for each changed section (preserving all five required sections)

### 4c. Issues to Cancel

If the finding makes an existing issue entirely unnecessary:
- Draft a cancellation comment explaining why
- The issue will be moved to `Canceled` state (not deleted)

---

## Step 5 — Confirmation Gate

Present the complete triage plan to the user via `AskUserQuestion`. This is a **hard gate** — no Linear writes happen until the user approves.

### Plan presentation format

Print the plan in structured form:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋  Triage Plan for: <PROJECT_NAME>

Finding: "<FINDING>"

## Conflicts Detected

<For each conflict, or "No conflicts detected.">

  <CONFLICT_TYPE>: WHI-<N> "<title>"
    Impact: <what the conflict means>
    Proposed action: <what will be changed>

## Proposed Changes

### New Issues (<count> or "None")

  1. "<proposed title>" [priority: <X>]
     Context: <1-sentence summary>
     Blocked by: <WHI-N or "none">

### Issue Modifications (<count> or "None")

  WHI-<N>: "<title>"
    Change: <description of what will be updated>
    Sections affected: <list of sections>

### Issue Cancellations (<count> or "None")

  WHI-<N>: "<title>"
    Reason: <why this issue is no longer needed>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
AskUserQuestion(
  "Proceed with the triage plan above?",
  options: [
    "Yes — execute all proposed changes",
    "Modify — I want to adjust the plan before executing",
    "Cancel — do not make any changes"
  ]
)
```

**If "Yes":** Continue to Step 6.

**If "Modify":** Ask:

```
AskUserQuestion(
  "What would you like to change about the plan?
   (Describe the adjustments — e.g., 'skip the cancellation of WHI-45',
   'change the priority of the new issue to Normal',
   'don't modify WHI-50, just add a comment instead')"
)
```

Apply the user's adjustments to the plan, then re-present the full updated plan and issue the **same three-option `AskUserQuestion`** again:

```
AskUserQuestion(
  "Proceed with the updated triage plan above?",
  options: [
    "Yes — execute all proposed changes",
    "Modify — I want to adjust the plan further",
    "Cancel — do not make any changes"
  ]
)
```

**Do NOT proceed to Step 6 without a "Yes" answer.** This cycle repeats for a maximum of 3 modification rounds. If the user hasn't approved after 3 rounds, print:

```
⚠️  Modification limit reached. To proceed:
    1. Manually apply the desired changes in Linear, then re-invoke to verify no remaining conflicts
    2. Re-invoke /harness-triage with a more focused finding that targets only the specific change you need
```

STOP.

**If "Cancel":** Print `Aborted — no changes made to Linear.` and STOP.

---

## Step 6 — Execute Approved Changes

Execute the approved plan in this order:

### 6a. Create new issues

For each new issue in the plan:

```
mcp__linear-server__save_issue(
  team: "<TEAM_ID>",
  project: "<PROJECT_ID>",
  title: "<issue title>",
  description: "<validated schema-compliant description>",
  state: "Backlog",
  priority: <0-4>,
  blockedBy: ["<WHI-N>", ...]  // if any
)
```

Record the returned issue ID. Print: `Created: WHI-<N> "<title>"`

**If creation fails:**
- Print: `⚠️  Failed to create issue "<title>": <error>`
- Continue with remaining changes — do NOT abort
- Record the failure for the summary

### 6b. Modify existing issues

For each issue modification in the plan:

1. **Read the current issue description** first:

```
mcp__linear-server__get_issue(id: "<issue-id>")
```

2. **Validate the fetched description** before modifying. Check that all five required section headings (`## Context`, `## Acceptance Criteria`, `## Architecture Notes`, `## Dependencies`, `## Scope Boundary`) are present in the fetched description. If any are missing, abort the modification for this issue:
   - Print: `⚠️  Skipping modification of WHI-<N>: fetched description missing required sections (possible API issue). Verify manually.`
   - Record as a failure in the summary
   - Continue with the next change

3. **Apply the approved changes** to the description, preserving all five required sections. Only modify the sections that were flagged for change.

4. **Update the issue:**

```
mcp__linear-server__save_issue(
  id: "<issue-id>",
  description: "<updated description>"
)
```

5. **Add an explanatory comment** (idempotency check first):

Before posting a comment, call `mcp__linear-server__list_comments(issueId: "<issue-id>")` and check for an existing comment containing `*Updated by /harness-triage*` with the same finding text. If found, skip the comment (a prior triage run already annotated this issue).

If no prior comment exists:

```
mcp__linear-server__save_comment(
  issueId: "<issue-id>",
  body: "### Triage Update

> <FINDING>

**What changed:**
<bullet list of changes made to this issue>

**Why:**
<brief explanation of why this change was necessary>

*Updated by /harness-triage*"
)
```

Print: `Modified: WHI-<N> "<title>" — <sections changed>`

If `blockedBy` relations need to change, update them in the same `save_issue` call.

### 6c. Cancel issues

For each issue cancellation in the plan:

1. **Add an explanatory comment first** (idempotency check):

Check for an existing comment containing `*Canceled by /harness-triage*` on this issue via `mcp__linear-server__list_comments(issueId: "<issue-id>")`. Skip if found.

If no prior cancellation comment exists:

```
mcp__linear-server__save_comment(
  issueId: "<issue-id>",
  body: "### Canceled by Triage

> <FINDING>

**Reason:** <why this issue is no longer needed>

*Canceled by /harness-triage*"
)
```

2. **Move to Canceled state:**

Before the first cancellation in a triage run, verify the exact state name by calling `mcp__linear-server__list_issue_statuses(team: "<TEAM_ID>")` and finding the state with `type: "canceled"`. Use the returned state name verbatim (it may be "Canceled", "Cancelled", or a custom name).

```
mcp__linear-server__save_issue(
  id: "<issue-id>",
  state: "<verified-canceled-state-name>"
)
```

Print: `Canceled: WHI-<N> "<title>"`

---

## Step 7 — Summary Output

After all changes are executed, print the structured summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  Triage complete for <PROJECT_NAME>

Finding: "<FINDING>"

Conflicts detected:    <N>
Issues created:        <M>
Issues modified:       <K>
Issues canceled:       <J>
Failures:              <F>

## Changes Made

### Created
<For each created issue>
  WHI-<N>: "<title>" [Backlog, priority: <X>]

### Modified
<For each modified issue>
  WHI-<N>: "<title>" — <sections changed>

### Canceled
<For each canceled issue>
  WHI-<N>: "<title>" — <reason>

### Failed (if any)
<For each failure>
  ❌ "<title>" — <error>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Recovery Reference

| Failure point | Recovery action |
|---------------|-----------------|
| Step 1 — project not found after 2 attempts | STOP with explicit message |
| Step 1 — no arguments and user provides no finding | STOP gracefully |
| Step 1 — team cannot be resolved from project | Call `list_teams`, ask user to select; STOP if still unresolved |
| Step 2 — Linear API unavailable | Warn, ask user to retry or abort; do NOT skip conflict detection |
| Step 3 — conflict classification ambiguous | Surface both possibilities to the user in Step 5 |
| Step 5 — modification limit reached (3 rounds) | STOP with manual-fix or re-invoke guidance |
| Step 6 — issue creation fails | Log failure, continue with remaining changes |
| Step 6 — issue modification fails (including stale description) | Log failure, continue with remaining changes |
| Step 6 — issue cancellation fails | Log failure, continue with remaining changes |
| Step 6 — partial execution (some changes succeed, some fail) | Report what succeeded and what failed in summary; triage comments serve as idempotency markers for safe re-invocation |
| Any step — unexpected exception | Print the error, report what was changed so far, STOP |

**Never silently skip conflict detection.** If the Linear API is unavailable, the skill must either retry or stop — proceeding without conflict detection defeats the purpose of triage.

**Never make Linear writes without user confirmation.** The confirmation gate in Step 5 is a hard requirement, not a soft suggestion.

---

## State Machine

```
Invoke ──[Step 1]──► Input resolved ──[Step 2]──► Issues fetched
                                                        │
                                                  [Step 3] Conflict
                                                  detection
                                                        │
                                                  [Step 4] Draft
                                                  proposed changes
                                                        │
                                                  [Step 5] Confirmation
                                                  gate (AskUserQuestion)
                                                   │    │       │
                                              Yes  │    │ Mod   │ No
                                                   │    │       │
                                                   │    └──► [adjust plan]
                                                   │         (max 3 rounds)
                                                   │              │
                                                   │    ◄─────────┘
                                                   ▼
                                            [Step 6]      Aborted —
                                            Execute       no changes
                                            changes
                                                   │
                                                   ▼
                                            [Step 7] Summary
```

**Linear states managed by this skill:**
- New issues are created in `Backlog` state
- Modified issues retain their current state (only description/dependencies change)
- Canceled issues are moved to `Canceled` state

**Linear states NOT managed by this skill:**
- `Backlog -> In Progress` — managed by `/harness-dev`
- All subsequent transitions — managed by `/harness-dev` and `/harness-review`

---

## Scope Boundary

This skill **only**:
- Accepts a natural language finding from the user
- Resolves the target Linear project from context or explicit argument
- Fetches and analyzes existing issues for conflicts
- Drafts new issues with schema-compliant descriptions (self-validated)
- Presents a triage plan and waits for user confirmation
- Creates, modifies, or cancels issues in Linear after approval
- Reports a structured summary of all changes

This skill **does NOT**:
- Write or modify code — it only manages Linear issues
- Run /office-hours or /plan-eng-review — this is a lightweight, reactive skill
- Handle multi-project scenarios — one project per invocation
- Auto-merge or auto-cancel issues without user confirmation
- Replace harness-design for greenfield projects — harness-triage is for course corrections
- Implement code changes based on created issues — that is `/harness-dev`'s job
- Transition issues to `In Progress` — that is `/harness-dev`'s job
