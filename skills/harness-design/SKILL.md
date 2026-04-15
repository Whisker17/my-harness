---
name: harness-design
version: 1.0.0
description: "Transforms a raw idea into a fully scoped Linear project with milestones, phases, and schema-compliant issues. Invokes /office-hours and /plan-eng-review interactively, then decomposes the resulting design doc into a complete Linear issue hierarchy. Invoke with /harness-design <project-id-or-idea>."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - Agent
  - Skill
  - AskUserQuestion
  - mcp__linear-server__get_project
  - mcp__linear-server__save_project
  - mcp__linear-server__list_milestones
  - mcp__linear-server__save_milestone
  - mcp__linear-server__save_issue
  - mcp__linear-server__list_issues
  - mcp__linear-server__list_teams
---

# harness-design

You are transforming a raw idea into a fully scoped Linear project. The user invoked this skill as `/harness-design <project-id-or-idea>` (or similar). Extract the argument from the invocation.

This skill runs interactively. It orchestrates two sessions with the user (/office-hours and /plan-eng-review) before doing any autonomous work. Do NOT skip or pre-answer those sessions — the user's participation is required.

## Preamble

Before any steps, run these checks in a single bash block:

```bash
# Detect repo context and gstack slug
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CLAUDE_MD_EXISTS=$([ -f "$REPO_ROOT/CLAUDE.md" ] && echo "yes" || echo "no")

# Derive gstack slug
eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)" 2>/dev/null || true
SLUG="${SLUG:-unknown}"

echo "Branch:     $CURRENT_BRANCH"
echo "Repo root:  $REPO_ROOT"
echo "CLAUDE.md:  $CLAUDE_MD_EXISTS"
echo "Slug:       $SLUG"

# Schema sanity check — must pass before Step 2
SCHEMA="$HOME/.claude/skills/harness-dev/schema.md"
if [ ! -s "$SCHEMA" ]; then
  echo "🛑  STOP: harness-dev schema not found or empty: $SCHEMA"
  echo "   Install or repair the harness-dev skill before running harness-design."
  echo "   (The schema is required to generate schema-compliant issue descriptions in Step 6.)"
  exit 1
fi
echo "Schema:     $SCHEMA (ok)"
```

**harness-design tolerates a missing CLAUDE.md** — unlike harness-dev, it operates at the project-planning layer, before a repo may exist. If CLAUDE.md is absent, print:

```
⚠️  No CLAUDE.md found. Proceeding without repo context.
    (Run /harness-bootstrap after /harness-design to set up the project repo.)
```

Do NOT stop. Continue to Step 1.

---

## Re-entry Detection

Before running Step 1, check whether a prior run already produced artifacts. This lets you skip the long interactive sessions when the user re-invokes after a Step 7 failure.

```bash
SLUG="<slug-from-preamble>"
DESIGN_DOC=$(ls -t ~/.gstack/projects/"$SLUG"/*-design-*.md 2>/dev/null | head -1)
echo "Re-entry check — design doc: ${DESIGN_DOC:-not found}"
```

Also check whether milestones already exist in Linear for the resolved project (requires the project ID from Step 1 — do this check immediately after Step 1 resolves the project, before Step 2):

```
mcp__linear-server__list_milestones(project: "<project-id>")
```

**Decision table:**

| Design doc exists? | Milestones in Linear? | Entry point |
|---|---|---|
| No | No | Full run — Steps 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 |
| Yes | No | Skip /office-hours and /plan-eng-review — jump to Step 5 (reuse existing doc); Step 7 creates milestones normally |
| Yes | Yes | Skip /office-hours, /plan-eng-review, and milestone creation — jump to Step 5; Step 7c creates only missing issues (dedup check already handles this) |
| No | Yes | Full run — design doc is the authoritative source; milestones without a doc are stale |

When skipping sessions, print:

```
⏩  Re-entry detected: design doc found at <path>.
    Skipping /office-hours and /plan-eng-review — resuming from Step 5.
    (Re-run /office-hours manually if you want to revise the design.)
```

---

## Step 1 — Input Resolution

Extract the argument the user passed to `/harness-design`. Three cases:

### Case A: Argument looks like a Linear project identifier

A Linear project identifier is a UUID, a URL slug, or a short name that matches an existing project. Try to resolve it:

```
mcp__linear-server__get_project(query: "<argument>")
```

If it resolves successfully:
- Use the project's `name` as the working project name
- Use the project's `description` as the seed idea
- Record the project `id` — this is the target project for all issue creation in Step 7
- Print: `✅  Resolved Linear project: <name> (<id>). Using project description as seed.`

If `get_project` fails (project not found), fall through to Case B.

### Case B: Argument is a free-form idea string

The argument doesn't match a Linear project. Use `AskUserQuestion` to ask:

```
No Linear project found matching "<argument>".

Options:
  1. Create a new Linear project for this idea and continue
  2. Proceed without a Linear project (issues will be attached to an existing project you specify)
  3. Cancel

Which would you prefer?
```

- If the user picks **1**: use `mcp__linear-server__list_teams` to find the team, then `mcp__linear-server__save_project` to create the project. Record the new project `id`.
- If the user picks **2**: use a retry loop (up to 3 attempts total) to resolve the existing project:

  ```
  for attempt in 1..3:
    answer = AskUserQuestion("Which existing project? Provide its ID, URL slug, or exact name.")
    result = mcp__linear-server__get_project(query: answer)
    if result resolves successfully:
      record project id
      break
    else:
      print "⚠️  Project not found: \"<answer>\" (attempt <attempt>/3). Check the name and try again."
  
  if all 3 attempts fail:
    AskUserQuestion(
      "Could not resolve a project after 3 attempts.\n\nOptions:\n" +
      "  1. Cancel the skill cleanly\n" +
      "  2. Create a new project instead (fall through to Case B option 1)\n\n" +
      "Which would you prefer?"
    )
    → If user picks 1: STOP gracefully.
    → If user picks 2: proceed as Case B option 1 (create new project).
  ```

  Surface the Linear error on each failure so the user can correct the typo.
- If the user picks **3**: STOP gracefully.

In either continuing case, treat the argument string as the seed idea.

### Case C: No argument provided

Use `AskUserQuestion`:

```
What would you like to design?

Provide either:
  • A Linear project ID or name (e.g., "WHI-payments", "forkcast-cli")
  • A free-form idea description (e.g., "a CLI tool that syncs GitHub issues to Notion")
```

Then re-enter Case A or Case B based on the answer.

---

## Step 2 — Design Session via /office-hours

**This is an interactive session. Do NOT pre-answer the questions /office-hours asks. The user must participate.**

Invoke /office-hours using the `Skill` tool:

```
Skill("office-hours", args: "<seed idea>")
```

Pass the seed idea from Step 1 as the argument. If the seed came from a Linear project description, summarize it in 1-2 sentences before passing.

While /office-hours runs:
- Do NOT interrupt
- Do NOT attempt to answer on behalf of the user
- Wait for it to complete before continuing

After /office-hours completes, print:
```
✅  /office-hours session complete. Proceeding to architecture review.
```

---

## Step 3 — Architecture Review via /plan-eng-review

**This is also an interactive session. Do NOT pre-answer anything.**

Invoke /plan-eng-review using the `Skill` tool:

```
Skill("plan-eng-review")
```

/plan-eng-review reads the design doc produced by /office-hours and walks through architecture decisions interactively with the user.

While /plan-eng-review runs:
- Do NOT interrupt
- Do NOT attempt to answer on behalf of the user
- Wait for it to complete before continuing

After /plan-eng-review completes, print:
```
✅  /plan-eng-review session complete. Checking for design artifacts.
```

---

## Step 4 — Design Doc Presence Check

Before doing any decomposition, verify that /office-hours actually produced a design doc. If the user abandoned the session mid-way, no doc was written — proceeding without it would produce hallucinated issue descriptions.

Derive the slug from the preamble's `SLUG` variable. If `SLUG` is `unknown`, try to derive from the project name (lowercase, hyphens, max 30 chars).

```bash
SLUG="<slug>"
DESIGN_DOC=$(ls -t ~/.gstack/projects/"$SLUG"/*-design-*.md 2>/dev/null | head -1)
echo "Design doc: ${DESIGN_DOC:-NOT FOUND}"
```

**If no design doc is found — STOP with this error:**

```
🛑  STOP: No design doc found in ~/.gstack/projects/<slug>/

This means /office-hours did not complete successfully (the user may have
abandoned the session before the doc was written).

Resolution:
  1. Re-invoke /office-hours and complete the full session
  2. Then re-invoke /harness-design <project-id-or-idea>

Do NOT proceed without the design doc — issue descriptions would be fabricated.
```

**If the design doc is found:**

```bash
# Also look for eng review artifacts
ENG_REVIEW=$(ls -t ~/.gstack/projects/"$SLUG"/*-eng-review-*.md 2>/dev/null | head -1)
PLAN_REVIEW=$(ls -t ~/.gstack/projects/"$SLUG"/*-plan-eng-review-*.md 2>/dev/null | head -1)
ENG_ARTIFACT="${ENG_REVIEW:-$PLAN_REVIEW}"
echo "Eng review: ${ENG_ARTIFACT:-not found (will fall back to design doc)}"
```

Record both paths. If no eng review artifact is found, fall back to the design doc only in Step 5 — do NOT stop.

---

## Step 5 — Decomposition

Read the design doc in full. Read the eng review artifact if found.

```bash
cat "<DESIGN_DOC_PATH>"
# If eng review exists:
cat "<ENG_ARTIFACT_PATH>"
```

Internally extract the following structured information:

1. **Project name and one-paragraph summary** — from the design doc header or Problem Statement section
2. **Major phases** — sections like "Phase 0", "Phase 1", "Skill 1", numbered milestones, or other top-level groupings. Each major phase becomes a Linear milestone.
3. **Features / deliverables within each phase** — sub-sections, bullet lists, or named components. Each becomes a Linear issue (or a parent issue with sub-issues for large phases).
4. **Dependencies between deliverables** — explicit "depends on", "after X", ordering language, or logical data-flow dependencies.
5. **Technical decisions** — from Architecture Notes, Eng Review, or "Recommended Approach" sections. Note the source heading so you can cite it in issue descriptions.

Then produce a **Decomposition Plan** as a markdown nested list:

```
## Decomposition Plan

Project: <project name>

Milestone 1: <Phase name>
  Issue: <title> [priority: Urgent/High/Normal/Low] [no blockers]
  Issue: <title> [priority: Normal] [blocks: issue above]
  ...

Milestone 2: <Phase name>
  Issue: <title> [priority: Normal] [blocked by: last issue of Milestone 1]
  ...

Large phases (5+ issues):
  Parent Issue: <phase name overview>
    Sub-issue: <title>
    Sub-issue: <title>
    ...
```

Print the Decomposition Plan to the user, then ask for explicit confirmation before proceeding:

```
AskUserQuestion("Proceed with creating these N issues in Linear?")
```

Replace `N` with the actual count of issues in the plan.

- If the user answers **Yes** (or equivalent): continue to Step 6.
- If the user answers **No** (or equivalent): print `Aborted — no changes made to Linear.` and exit cleanly. Do NOT create any milestones, issues, or other Linear objects.

---

## Step 6 — Issue Generation

For each issue in the Decomposition Plan, construct a complete description using all five schema sections. The schema is at `~/.claude/skills/harness-dev/schema.md`.

The five required headings (verbatim, as level-2 markdown headings):
- `## Context`
- `## Acceptance Criteria`
- `## Architecture Notes`
- `## Dependencies`
- `## Scope Boundary`

### Writing each section

**`## Context`**
- What this issue is about, why it matters, where it fits in the project
- Cite the specific design doc section by heading name: e.g., "See design doc §Target User & Narrowest Wedge"
- Minimum: 2-3 sentences with concrete, project-specific content

**`## Acceptance Criteria`**
- Use checklist format: `- [ ] Concrete, testable criterion`
- Each criterion must be independently verifiable — no vague phrasing like "works correctly"
- Prefer: "returns X for input Y", "file Z exists at path P", "command C outputs D"
- Minimum: 3 criteria

**`## Architecture Notes`**
- Key files to create or modify (with paths relative to repo root)
- Function signatures or interface shapes where known
- Error handling expectations
- Patterns to follow (reference existing files where applicable)
- Cite specific eng review decisions using a heading that appears in the `/plan-eng-review` output — e.g., `"See eng review §Key Interactions to Verify"` or `"See eng review §Critical Paths"`. If no relevant test-plan heading applies, cite a heading from the design doc instead.
- If no eng review exists, derive from design doc architecture sections

**`## Dependencies`**
- List blocking issues by their intended title using the placeholder tag `@@DEP:<Issue title>@@`
- Format: `- @@DEP:<Issue title>@@`
- These placeholder tags are rewritten to actual `WHI-<N>` references in Step 7d after all issues are created. Do NOT leave `(to be resolved in Step 7)` or similar prose in the live description.
- Write `None — no blocking dependencies.` if no dependencies (the sentinel must be long enough to clear the ≥20 non-whitespace-char minimum)

**`## Scope Boundary`**
- What is explicitly NOT in scope for this issue
- Minimum: 2 explicit exclusions
- Prevents scope creep and over-engineering

### Self-validation (REQUIRED before creating any issue in Linear)

Apply this validation to every issue description BEFORE calling any Linear API:

```
VALIDATION RULES:
1. All five headings present:
   regex: ^## (Context|Acceptance Criteria|Architecture Notes|Dependencies|Scope Boundary)
   → check each of the five exists

2. Strip placeholder lines and enforce minimum content:
   → strip lines matching `^[\[<].*[\]>]$` (square- or angle-bracket placeholders)
   → remaining non-whitespace chars must be ≥ 20 per section
   → this catches both "[fill in later]" and "<TBD>" patterns; 20 chars matches
     harness-dev's quality gate and rejects one-liner placeholder sections
   Example: `[details TBD]` and `<blocking milestone or "None">` are both stripped
            before the char count is evaluated
```

**If validation fails for an issue:**
- **Before regenerating, re-read the relevant design doc section** using `Read(file_path=<design-doc-path>, offset=<start-line>, limit=<line-count>)` so the regeneration is grounded in the actual source text. Do NOT regenerate from memory — on long projects the design doc content may have fallen out of context.
- Regenerate that issue's description — do NOT skip, do NOT create a partial description in Linear
- Re-validate the regenerated description before proceeding
- If regeneration fails twice, print a warning and skip that specific issue (log the title for the summary)

**If validation passes:**
- Record the validated description
- Continue to next issue

For phases with 5 or more issues, group those issues under a parent index issue with sub-issues. (The threshold is per-phase, not total-project. A project with two 4-issue phases does not trigger grouping; a single 5-issue phase does.) The parent issue's description is a brief index still in schema format:

```markdown
## Context
Phase overview: <1-2 sentences>. This parent tracks the following sub-issues:
- <sub-issue title 1>
- <sub-issue title 2>

## Acceptance Criteria
- [ ] All sub-issues in this phase are in Done state

## Architecture Notes
See sub-issues for individual technical details. Phase depends on: <preceding phase name>.

## Dependencies
<!-- Fill in: list the @@DEP:<Issue title>@@ placeholder tags for blocking issues, or write "None — no blocking dependencies." -->
None — no blocking dependencies.

## Scope Boundary
This issue is an index only. All implementation is in the sub-issues below.
```

---

## Step 7 — Linear Creation

Create all Linear objects in this order: milestones first, then issues in dependency order (blockers before blocked), then sub-issues.

### 7a. Ensure milestones exist

```
mcp__linear-server__list_milestones(project: "<project-id>")
```

For each milestone in the Decomposition Plan, check if one with that name already exists. If not, create it:

```
mcp__linear-server__save_milestone(
  project: "<project-id>",
  name: "<milestone name>",
  description: "<1-sentence summary of the phase>"
)
```

Record the returned milestone ID for each. Map milestone name → milestone ID.

### 7b. Determine team

If the project was resolved in Step 1, the team is known from the project. Otherwise:

```
mcp__linear-server__list_teams()
```

Ask the user (via AskUserQuestion) which team to assign issues to, if not determinable from context.

### 7c. Create issues in dependency order

Process issues in this order:
1. Issues with no blockers (within their milestone, sorted by priority)
2. Issues whose blockers have been created (and their IDs recorded)
3. Continue until all issues are created

**Dedup check before each create.** On re-invocation (or if a prior run partially succeeded), avoid double-creating an issue that already exists:

```
mcp__linear-server__list_issues(
  project: "<project-id>",
  query: "<issue title>"
)
```

If the returned list contains an issue whose `title` is an exact match, skip `save_issue` — record the existing issue ID in the title → ID map and proceed. Report it in the summary as `existing` (not `created`). If no exact match, continue with `save_issue` below.

For each issue, call:

```
mcp__linear-server__save_issue(
  team: "<team-id>",
  project: "<project-id>",
  title: "<issue title>",
  description: "<validated description from Step 6>",
  milestone: "<milestone-id for this phase>",
  state: "Backlog",
  priority: <0=None|1=Urgent|2=High|3=Normal|4=Low>,
  blockedBy: ["<id-of-blocking-issue>", ...]   // only if blockers have been created
)
```

**As each issue is created:**
- Record the returned Linear issue ID
- Map: intended title → Linear issue ID
- Update the `blockedBy` field of any subsequent issues that depend on this one

**For sub-issues:**
- Create the parent issue first (no `blockedBy` within the phase yet)
- Create each sub-issue with BOTH `parentId: "<parent-issue-id>"` AND `milestone: "<milestone-id for this phase>"` — sub-issues do NOT auto-inherit the parent's milestone; it must be set explicitly
- All other fields (`team`, `project`, `state: "Backlog"`, `description`, `priority`) follow the standard `save_issue` call template above

**If a Linear API call fails:**
- Print: `⚠️  Failed to create issue "<title>": <error>`
- Continue creating remaining issues — do NOT abort the entire run
- Record failed issues for the summary
- Do NOT silently retry more than once (one retry on network error is acceptable)

### 7d. Resolve dependency placeholders (second pass)

After ALL issues are created and the title → Linear ID map is complete, rewrite each description to replace `@@DEP:<title>@@` placeholder tags with actual `WHI-<N>` references:

1. For every issue in the title → ID map whose description contains `@@DEP:...@@` tags:
   - Build the final Dependencies section text: replace each `@@DEP:<title>@@` tag with the resolved `WHI-<N>` reference from the map (or drop the line if the referenced title failed to create — noting this in the summary).
   - Call `mcp__linear-server__save_issue(id: "<issue-id>", description: "<rewritten description>")` to update the issue in place.
2. Do not leave any `@@DEP:...@@` tags in the live Linear descriptions — validate with a final grep of the rewritten descriptions before proceeding.
3. If a referenced title was skipped or failed to create, replace the tag with `(dependency <title> — not created; see summary)` so the description stays valid and informative.

This two-pass approach keeps the description self-contained once Step 7 completes — no meta-comments about unresolved IDs remain.

### 7e. Issues created in Backlog state

**harness-design creates all issues in `Backlog` state.** Do NOT transition issues to In Progress — that is `/harness-dev`'s job when implementation begins.

---

## Step 8 — Summary Output

After all creation is complete, print the structured summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  harness-design complete for <project-name>

Milestones created:   N
Issues created:       M
Sub-issues created:   K
Issues failed:        F  ← (0 if all succeeded)

Dependency chain:
  <Milestone 1 name>
    WHI-<a>: <title>
    WHI-<b>: <title> (blocked by WHI-<a>)
  <Milestone 2 name>
    WHI-<c>: <title> (blocked by WHI-<b>)
    WHI-<d>: <title> (blocked by WHI-<c>)
    ...

Failed issues (if any):
  ❌ <title> — <error or validation failure reason>

Next step:  /harness-dev WHI-<first-unblocked-issue-id>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The "first unblocked issue" is the lowest-numbered issue with no `blockedBy` dependencies (i.e., the natural starting point for implementation).

---

## Error Recovery Reference

| Failure point | Recovery action |
|---------------|-----------------|
| Step 1 — Linear project not found | Fall through to free-form idea path (Case B); ask user for target project |
| Step 1 — user-supplied project name doesn't resolve (Case B opt 2) | Retry up to 3 attempts surfacing the Linear error; on 3rd failure offer cancel or fall through to create-new-project |
| Step 1 — user cancels project creation | STOP gracefully |
| Step 4 — design doc missing | 🛑 STOP with explicit instructions to re-run /office-hours; do NOT proceed |
| Step 5 — eng review artifact not found | Fall back to design doc only; warn but continue |
| Step 6 — issue description fails validation | Regenerate description; if second attempt also fails, skip and log |
| Step 7 — milestone creation fails | Print error, STOP — issues cannot reference a milestone that doesn't exist |
| Step 7 — individual issue creation fails | Print warning, continue with remaining issues; report in summary |
| Step 7 — partial creation (some issues created, some not) | Report what succeeded and what failed in the summary; do NOT roll back created issues silently |
| User answers "No" at Step 5 confirmation gate | No Linear changes made; exit cleanly |
| Any step — unexpected error | Print the error and current state; do NOT silently swallow failures |

**On partial failure:** always report exactly which issues were created (with their IDs) and which failed. The user needs this information to decide whether to re-run or fix manually. Never leave the user guessing about the state of Linear.

---

## State Machine

```
(no Linear state)  ──[Step 1]──►  Project resolved/created
                                          │
                                    Re-entry check
                                    (design doc? milestones?)
                                          │
                     ┌────────────────────┼────────────────────────┐
                     │ neither            │ doc only               │ both
                     ▼                   │                        │
             [Step 2] /office-hours      │ ⏩ skip Steps 2-4       │ ⏩ skip Steps 2-4
             (interactive)               │   resume at Step 5     │   resume at Step 5
                     │                   │                        │   (Step 7 skips
                     ▼                   │                        │    milestone create)
             [Step 3] /plan-eng-review   ▼                        ▼
             (interactive)        [Steps 5-6]               [Steps 5-6]
                     │            Decompose +               Decompose +
                     ▼            generate issues           generate issues
             [Step 4] Design                │                        │
             doc check                      └──────────┬─────────────┘
               │             │                         │
          found │    not found│                        ▼
               ▼             ▼              AskUserQuestion: Proceed?
         [Steps 5-6]       🛑 STOP            │               │
         Decompose +                        Yes │           No │
         generate issues                       ▼             ▼
               │                       [Step 7] Create   Aborted —
               ▼                       in Linear         no Linear
    AskUserQuestion: Proceed?          (Backlog)         changes made
      │               │                       │
    Yes │           No │                      ▼
        ▼             ▼                 [Step 8] Summary
  [Step 7] Create   Aborted —
  in Linear         no Linear
  (Backlog)         changes made
        │
        ▼
  [Step 8] Summary
```

**Linear states managed by this skill:**
- All issues are created in `Backlog` state
- No state transitions happen after creation

**Linear states NOT managed by this skill:**
- `Backlog → In Progress` — managed by `/harness-dev` when implementation begins
- All subsequent transitions (`In Progress → In Review → Done`) — managed by `/harness-dev` and `/harness-review`

---

## Scope Boundary

This skill **only**:
- Reads a Linear project or accepts a free-form idea
- Invokes /office-hours and /plan-eng-review interactively (user participates)
- Reads the resulting design doc and eng review artifacts
- Decomposes the design into milestones, phases, and issues
- Generates schema-compliant issue descriptions (self-validated)
- Creates milestones and issues in Linear in `Backlog` state

This skill **does NOT**:
- Automate or pre-answer /office-hours or /plan-eng-review — they are interactive sessions
- Generate code or implementation artifacts — only Linear project structure and issue descriptions
- Modify existing Linear issues — only creates new ones
- Handle multi-project scenarios — one project per invocation
- Transition issues to `In Progress` — that is `/harness-dev`'s job
- Run adversarial review, implement features, or manage worktrees
