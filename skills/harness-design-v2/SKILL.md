---
name: harness-design-v2
version: 0.2.0
description: "Codex-powered design with Opus Linear translation. Full v2 design pipeline: gathers project context, invokes Codex in consult mode to produce a structured design brief, translates the brief into harness issue schema with [OPUS INFERRED] markers, presents the proposed structure for human approval, and creates Linear issues upon approval. Invoke with /harness-design-v2 <topic or Linear issue URL>."
triggers:
  - harness-design-v2
  - v2 design
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Skill
  - AskUserQuestion
  - mcp__linear-server__get_issue
  - mcp__linear-server__list_issues
  - mcp__linear-server__save_issue
  - mcp__linear-server__list_teams
  - mcp__linear-server__get_project
  - mcp__linear-server__list_milestones
  - mcp__linear-server__save_milestone
  - mcp__linear-server__get_user
---

# harness-design-v2

You are running the Codex-powered design skill. The user invoked this skill as `/harness-design-v2 <topic or Linear issue URL>` (or similar). Extract the argument from the invocation.

This skill runs the full v2 design pipeline:
1. Gathers project context that Codex cannot read directly (local files, Linear state)
2. Invokes Codex in consult mode to produce a structured design brief
3. Translates the brief into the harness issue schema (5 required sections per issue)
4. Marks gaps with [OPUS INFERRED] markers for human review
5. Presents the proposed issue structure for human approval (approve / revise / reject)
6. Creates parent issue + sub-issues in Linear upon approval

---

## Preamble

Before any steps, run these checks in a single bash block:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "not-a-git-repo")
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CLAUDE_MD_EXISTS=$([ -f "$REPO_ROOT/CLAUDE.md" ] && echo "yes" || echo "no")

echo "Branch:     $CURRENT_BRANCH"
echo "Repo root:  $REPO_ROOT"
echo "CLAUDE.md:  $CLAUDE_MD_EXISTS"

# STOP if not in a git repo — required for context gathering and Codex invocation
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: Not in a git repository. harness-design-v2 requires a git repo."
  exit 1
fi

# Verify Codex CLI is installed
if ! command -v codex &>/dev/null; then
  echo "CODEX: not-found"
else
  CODEX_VERSION=$(codex --version 2>&1 || echo "unknown")
  echo "CODEX: $CODEX_VERSION"
fi

# Verify Codex authentication (mirrors harness-review-v2 Step 1a-2)
if command -v codex &>/dev/null; then
  codex auth status 2>&1 || codex whoami 2>&1 || echo "CODEX_AUTH: failed"
fi

# Check .reviews/ is gitignored
if [ -f "$REPO_ROOT/.gitignore" ]; then
  grep -q '\.reviews/' "$REPO_ROOT/.gitignore" 2>/dev/null || echo "WARNING: .reviews/ may not be gitignored — design briefs may be committed."
fi
```

**If not in a git repo:**

```
ERROR: Not in a git repository.

harness-design-v2 requires a git repository for context gathering and Codex invocation.
```

STOP — do not proceed.

**If Codex CLI is not found:**

```
ERROR: Codex CLI not found.

The harness-design-v2 skill requires the Codex CLI for design consultation.

Fix: Install the Codex CLI:
  npm install -g @openai/codex

Then authenticate:
  codex login
```

STOP — do not proceed.

**If Codex authentication fails** (output contains "failed", "unauthorized", or "not logged in"):

```
ERROR: Codex CLI is not authenticated.

Fix: Run `codex login` to authenticate with your Codex account.
```

STOP — do not proceed.

**Note:** If neither `codex auth status` nor `codex whoami` is a valid subcommand, skip this check — authentication errors will surface during the Codex invocation in Step 3, where the error handler should also emit the `"Run codex login to authenticate"` message.

**If CLAUDE.md is missing:** Print a warning but continue — design can operate with reduced context:

```
Warning: No CLAUDE.md found. Proceeding with reduced project context.
(Run /harness-bootstrap to set up the project repo.)
```

---

## Step 1 — Parse Input

The user's input is either:

1. **A Linear issue URL** — matches regex: `linear\.app/.*/issue/WHI-\d+`
2. **Free text** — everything else; treated as the design topic

### 1a. Detect input type

```bash
INPUT="<user argument>"

# Check if input contains a Linear issue URL
if echo "$INPUT" | grep -qE 'linear\.app/.*/issue/WHI-[0-9]+'; then
  ISSUE_ID=$(echo "$INPUT" | grep -oE 'WHI-[0-9]+')
  echo "MODE: linear-issue"
  echo "ISSUE_ID: $ISSUE_ID"
else
  echo "MODE: free-text"
  echo "TOPIC: $INPUT"
fi
```

### 1b. If Linear issue URL — extract context

Use `mcp__linear-server__get_issue` with `id: "<ISSUE_ID>"` to read the issue.

Store the issue title and full description as `LINEAR_CONTEXT`. This will be embedded in the Codex prompt.

The design topic is derived from the issue title.

### 1c. Compute topic_slug

Compute a URL-safe slug from the topic text:

```bash
TOPIC="<topic text or issue title>"
TOPIC_SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
echo "TOPIC_SLUG: $TOPIC_SLUG"
```

Rules:
- Lowercase
- Replace spaces and non-alphanumeric characters (except hyphens) with hyphens
- Collapse multiple consecutive hyphens
- Strip leading/trailing hyphens
- Max 50 characters

---

## Step 2 — Gather Context

Collect all project context that Codex cannot read directly. Run these in a single bash block:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# 2a. Read CLAUDE.md
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
  CLAUDE_MD=$(cat "$REPO_ROOT/CLAUDE.md")
  echo "CLAUDE_MD: loaded ($(wc -c < "$REPO_ROOT/CLAUDE.md") bytes)"
else
  CLAUDE_MD="[No CLAUDE.md found — project context unavailable]"
  echo "CLAUDE_MD: not found"
fi

# 2b. Recent git activity
GIT_LOG=$(git log --oneline -20 2>/dev/null || echo "[No git history available]")
echo "GIT_LOG: $(echo "$GIT_LOG" | wc -l | tr -d ' ') commits"

# 2c. Active Linear issues will be fetched via MCP below
```

### 2c. Fetch active Linear issues

**Detect the project name** using this precedence:
1. If a Linear issue was fetched in Step 1b, use `issue.project` from the response
2. Else, read `.linear-project` at repo root (if it exists) for the project name
3. Else, default to `"My Harness"` with a visible warning: `"WARNING: Using default project name 'My Harness' — create .linear-project to configure."`

Use `mcp__linear-server__list_issues` to fetch issues in active states for the detected project:

1. Query with `project: "<detected project name>"`, `state: "In Progress"`
2. Query with `project: "<detected project name>"`, `state: "Todo"`
3. Query with `project: "<detected project name>"`, `state: "Backlog"`, `limit: 20`

Compile a concise list of active issues:

```
ACTIVE_ISSUES:
- WHI-XXX: <title> [In Progress]
- WHI-YYY: <title> [Todo]
- WHI-ZZZ: <title> [Backlog]
...
```

**If the Linear API fails:** Warn and continue with `ACTIVE_ISSUES="[Linear API unavailable — active issues not loaded]"`.

---

## Step 3 — Codex Consult Invocation

### 3a. Check for existing Codex session

```bash
cat .context/codex-session-id 2>/dev/null || echo "NO_SESSION"
```

If a session file exists (not `NO_SESSION`), use AskUserQuestion:

```
You have an active Codex conversation from earlier. Continue it or start fresh?
A) Continue the conversation (Codex remembers the prior context)
B) Start a new conversation
```

If the user chooses to continue, use the `resume` invocation pattern.

### 3b. Build the prompt

Assemble the full prompt with all gathered context.

**Size guard:** Before embedding, check the size of CLAUDE.md content. If it exceeds 8 KB (~8192 chars), truncate to the first 8 KB with a note: `[TRUNCATED — full CLAUDE.md is {N} bytes, showing first 8192]`. Similarly, if the Linear issue description exceeds 4 KB, truncate with a note. This prevents `E2BIG` errors and model context exhaustion.

The assembled prompt structure:

```
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are Claude Code skill definitions meant for a different AI system. Do NOT modify agents/openai.yaml. Stay focused on repository code only.

You are a senior systems architect designing a feature for the following project.

PROJECT CONTEXT (from CLAUDE.md):
{CLAUDE_MD content — truncated if >8KB}

RECENT ACTIVITY (last 20 commits):
{GIT_LOG output}

ACTIVE LINEAR ISSUES:
{ACTIVE_ISSUES list}

{If LINEAR_CONTEXT exists:}
LINEAR ISSUE CONTEXT:
Title: {issue title}
Description:
{issue description — truncated if >4KB}

DESIGN TOPIC: {topic text}

Produce a thorough design brief with the following sections. Be specific and concrete — reference actual file paths, function names, and patterns from the project context where applicable. Each section should be substantive (not placeholder text).

## Problem Statement
What problem are we solving? Why does it matter? What's the current state?

## Proposed Architecture
Technical design: components, data flow, key abstractions. Reference existing patterns from the project context. Include file paths where new code should live.

## Key Decisions and Tradeoffs
What are the major design choices? What alternatives were considered? Why this approach over others?

## Acceptance Criteria
Specific, testable criteria. Use checklist format:
- [ ] Concrete, observable outcome
- [ ] Another testable condition

## Risk Assessment
What could go wrong? What are the unknowns? What needs validation?

## Suggested Sub-task Breakdown
Ordered list of implementation sub-tasks. Each should be independently shippable. Include estimated complexity (S/M/L) for each.
```

**Prompt safety:** Write the assembled prompt to a temp file rather than interpolating it as a shell argument. This prevents shell injection from CLAUDE.md content, git log messages, or Linear issue descriptions that may contain backticks, `$()`, double quotes, or other shell metacharacters.

### 3c. Invoke Codex

**Architecture note:** This skill invokes `codex exec` directly (not via the gstack `/codex` Skill tool) because: (1) the prompt is pre-assembled with embedded context that the `/codex` skill's plan-detection logic would interfere with, (2) the skill needs direct control over the `--json` streaming parser to capture the session ID, and (3) the `/codex` skill's interactive mode (AskUserQuestion for review/challenge/consult) is not appropriate here. However, we mirror the `/codex` skill's timeout and hang-detection patterns for consistency.

Write the assembled prompt to a temp file and invoke Codex:

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel)
TMPPROMPT=$(mktemp /tmp/codex-prompt-XXXXXX.txt)
TMPRESP=$(mktemp /tmp/codex-resp-XXXXXX.txt)
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)

# Write the assembled prompt to a temp file to avoid shell injection
cat > "$TMPPROMPT" << 'PROMPT_EOF'
<assembled prompt content — Claude writes the full prompt here>
PROMPT_EOF
```

**For a new session:**

```bash
# Use timeout wrapper (10 min) matching the codex skill pattern
# If _gstack_codex_timeout_wrapper is available, use it; otherwise fall back to timeout/gtimeout
if type _gstack_codex_timeout_wrapper &>/dev/null; then
  TIMEOUT_CMD="_gstack_codex_timeout_wrapper 600"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout 600"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout 600"
else
  TIMEOUT_CMD=""
  echo "WARNING: No timeout command available. Codex may hang indefinitely."
fi

$TIMEOUT_CMD codex exec "$(cat "$TMPPROMPT")" \
  -C "$_REPO_ROOT" \
  -s read-only \
  -c 'model_reasoning_effort="medium"' \
  --enable web_search_cached \
  --json < /dev/null 2>"$TMPERR" | PYTHONUNBUFFERED=1 python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type','')
        if t == 'thread.started':
            tid = obj.get('thread_id','')
            if tid: print(f'SESSION_ID:{tid}', flush=True)
        elif t == 'item.completed' and 'item' in obj:
            item = obj['item']
            itype = item.get('type','')
            text = item.get('text','')
            if itype == 'reasoning' and text:
                print(f'[codex thinking] {text}', flush=True)
                print(flush=True)
            elif itype == 'agent_message' and text:
                print(text, flush=True)
            elif itype == 'command_execution':
                cmd = item.get('command','')
                if cmd: print(f'[codex ran] {cmd}', flush=True)
        elif t == 'turn.completed':
            usage = obj.get('usage',{})
            tokens = usage.get('input_tokens',0) + usage.get('output_tokens',0)
            if tokens: print(f'\ntokens used: {tokens}', flush=True)
    except: pass
" | tee "$TMPRESP"

_CODEX_EXIT=${PIPESTATUS[0]}
if [ "$_CODEX_EXIT" = "124" ]; then
  echo "ERROR: Codex stalled past 10 minutes. Common causes: model API stall, long prompt, network issue."
  echo "Try re-running. If persistent, split the prompt or check ~/.codex/logs/."
fi

# Clean up prompt temp file
rm -f "$TMPPROMPT"
```

**For a resumed session** (user chose "Continue" in Step 3a):

Read the session ID from the file, then invoke with `resume`:

```bash
EXISTING_SESSION_ID=$(cat .context/codex-session-id)

# Use the same timeout wrapper as the new-session path
if type _gstack_codex_timeout_wrapper &>/dev/null; then
  TIMEOUT_CMD="_gstack_codex_timeout_wrapper 600"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout 600"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout 600"
else
  TIMEOUT_CMD=""
  echo "WARNING: No timeout command available. Codex may hang indefinitely."
fi

$TIMEOUT_CMD codex exec resume "$EXISTING_SESSION_ID" "$(cat "$TMPPROMPT")" \
  -C "$_REPO_ROOT" \
  -s read-only \
  -c 'model_reasoning_effort="medium"' \
  --enable web_search_cached \
  --json < /dev/null 2>"$TMPERR" | PYTHONUNBUFFERED=1 python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        t = obj.get('type','')
        if t == 'thread.started':
            tid = obj.get('thread_id','')
            if tid: print(f'SESSION_ID:{tid}', flush=True)
        elif t == 'item.completed' and 'item' in obj:
            item = obj['item']
            itype = item.get('type','')
            text = item.get('text','')
            if itype == 'reasoning' and text:
                print(f'[codex thinking] {text}', flush=True)
                print(flush=True)
            elif itype == 'agent_message' and text:
                print(text, flush=True)
            elif itype == 'command_execution':
                cmd = item.get('command','')
                if cmd: print(f'[codex ran] {cmd}', flush=True)
        elif t == 'turn.completed':
            usage = obj.get('usage',{})
            tokens = usage.get('input_tokens',0) + usage.get('output_tokens',0)
            if tokens: print(f'\ntokens used: {tokens}', flush=True)
    except: pass
" | tee "$TMPRESP"

_CODEX_EXIT=${PIPESTATUS[0]}
if [ "$_CODEX_EXIT" = "124" ]; then
  echo "ERROR: Codex stalled past 10 minutes. Common causes: model API stall, long prompt, network issue."
  echo "Try re-running. If persistent, split the prompt or check ~/.codex/logs/."
fi

# Clean up prompt temp file
rm -f "$TMPPROMPT"
```

**Timeout:** 10-minute timeout via `_gstack_codex_timeout_wrapper`, `gtimeout`, or `timeout` (in that precedence). If Codex stalls, print the error and STOP.

**Authentication failure:** If Codex output (in `$TMPERR` or `$TMPRESP`) contains "unauthorized", "not logged in", or "invalid token":

```
ERROR: Codex authentication failed.

Fix: Run `codex login` to authenticate with your Codex account.
```

STOP — do not proceed.

### 3d. Save session ID

Extract the session ID from the streamed output. The Python parser emits `SESSION_ID:<id>` from the `thread.started` event. Use a specific pattern to avoid matching reasoning traces:

```bash
# Wait for tee to finish flushing before reading
sync 2>/dev/null || true

SESSION_ID=$(grep -m1 "^SESSION_ID:[A-Za-z0-9_-]" "$TMPRESP" | head -1 | cut -d: -f2-)
if [ -n "$SESSION_ID" ]; then
  mkdir -p .context
  echo "$SESSION_ID" > .context/codex-session-id
  echo "Session saved: $SESSION_ID"
else
  echo "WARNING: No session ID captured — follow-up conversations won't resume."
fi
```

---

## Step 4 — Write Brief

### 4a. Extract the brief content

Parse the Codex response to extract the design brief. Strip metadata lines from the output to produce clean brief content:

```bash
# Strip metadata lines from Codex output
grep -v '^SESSION_ID:' "$TMPRESP" | \
grep -v '^\[codex thinking\]' | \
grep -v '^\[codex ran\]' | \
grep -v '^tokens used:' | \
grep -v '^$' > /tmp/codex-brief-clean.txt
```

**Output validation:** Check that the brief contains at least 3 of the 6 required section headings:

```bash
SECTION_COUNT=$(grep -cE '^## (Problem Statement|Proposed Architecture|Key Decisions|Acceptance Criteria|Risk Assessment|Suggested Sub-task)' /tmp/codex-brief-clean.txt)
echo "Sections found: $SECTION_COUNT / 6"
```

If fewer than 3 sections are found, warn the user:

```
WARNING: Codex response contains only {N}/6 expected sections.
The brief may be incomplete or malformed.
```

Use AskUserQuestion:
```
A) Write the brief as-is (review and supplement manually)
B) Retry the Codex invocation
C) Abort
```

If the user chooses B, re-run Step 3c. If C, STOP.

### 4b. Write to file

```bash
TOPIC_SLUG="<computed slug>"
mkdir -p .reviews/design/"$TOPIC_SLUG"
```

Write the brief to `.reviews/design/{topic_slug}/brief.md`:

```markdown
# Design Brief — {topic}

> Generated by harness-design-v2 via Codex consult
> Date: {YYYY-MM-DD}
> Topic slug: {topic_slug}
{If from Linear issue:}
> Source: [WHI-{N}]({issue URL})

{clean brief content from Codex}
```

### 4c. Present output and transition

Display the brief to the user:

```
CODEX DESIGN BRIEF:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{brief content}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Brief saved to: .reviews/design/{topic_slug}/brief.md
Session saved — run /codex to continue the conversation with Codex.

Proceeding to brief-to-schema translation (Step 5)...
```

**If Claude disagrees with any of Codex's analysis,** flag it clearly:

```
Note: Claude Code disagrees on X because Y.
```

Continue immediately to Step 5 — do NOT stop here.

---

## Step 5 — Brief-to-Schema Translation

This step translates the Codex design brief into the harness issue schema (5 required sections per issue). Opus reads the brief, maps sections to the schema, detects gaps, and marks inferred content.

### 5a. Read the brief

Read the brief from `.reviews/design/{topic_slug}/brief.md`:

```bash
TOPIC_SLUG="<computed slug from Step 1c>"
BRIEF_PATH=".reviews/design/$TOPIC_SLUG/brief.md"
cat "$BRIEF_PATH"
```

Also read the harness issue schema for reference:

```bash
cat ~/.claude/skills/harness-dev/schema.md
```

### 5b. Detect the Linear project context

The translation needs a target project and user for issue creation. Detect using this precedence:

1. If a Linear issue was fetched in Step 1b, use `issue.project` and `issue.assignee`
2. Else, read `.linear-project` at repo root for the project name
3. Else, default to `"My Harness"` with a visible warning

```
mcp__linear-server__get_project(query: "<detected project name>")
mcp__linear-server__get_user(query: "me")
```

Record: `PROJECT_ID`, `PROJECT_NAME`, `USER_ID`, `USER_NAME`.

If the project cannot be resolved, use `AskUserQuestion`:

```
Which Linear project should issues be created in?
A) My Harness
B) Specify a different project name
C) Cancel
```

### 5c. Map brief sections to parent issue schema

Apply the following mapping from the Codex brief to the harness 5-section schema:

```
Brief "## Problem Statement"            → Issue "## Context"
Brief "## Acceptance Criteria"           → Issue "## Acceptance Criteria"
Brief "## Proposed Architecture"         → Issue "## Architecture Notes" (first half)
Brief "## Key Decisions and Tradeoffs"   → Issue "## Architecture Notes" (second half)
Brief "## Risk Assessment"               → Informs "## Dependencies" (risks that are blockers)
                                           and "## Scope Boundary" (risks that are out of scope)
Brief "## Suggested Sub-task Breakdown"  → Sub-issues (see Step 5d)
```

**Heading detection — fuzzy matching with priority:** Codex may use slightly different heading names than instructed (e.g., "## Architecture" instead of "## Proposed Architecture"). Use **keyword-based matching** with explicit priority ordering. **Process headings in the order listed below** — the first matching row wins. This prevents ambiguity when a heading matches multiple rows.

| Priority | Target section | Match if heading contains (case-insensitive) | Excludes |
|----------|----------------|----------------------------------------------|----------|
| 1 | Acceptance Criteria | "acceptance criteria" OR ("criteria" AND NOT "design") | — |
| 2 | Key Decisions | "decision" OR "tradeoff" OR "trade-off" | — |
| 3 | Risk Assessment | "risk" OR "assessment" | — |
| 4 | Sub-task Breakdown | "sub-task" OR "breakdown" OR "subtask" OR "implementation steps" | — |
| 5 | Problem Statement | "problem" OR "statement" OR "context" OR "overview" | "architectural overview" |
| 6 | Proposed Architecture | "architecture" OR "technical design" | — |
| 7 (catch-all) | — | Any remaining unmatched `##` heading | — |

**Priority rules:**
- More specific matches (e.g., "acceptance criteria") are tested before generic keywords (e.g., "design")
- "Key Decisions" is matched before "Proposed Architecture" to prevent "Design Decisions" from being captured by an "architecture" or "design" keyword
- The `Excludes` column prevents false positives (e.g., "Non-functional Requirements" → does NOT match Acceptance Criteria)
- **Catch-all (priority 7):** Unmatched sections are logged and appended to Architecture Notes: `Unmatched brief section: "## {heading}" — content appended to Architecture Notes.`

**Construct the parent issue:**

- **Title:** Derive from the design topic. Format: `feat(v2): <topic>` or use the topic text directly if it already has a meaningful title.
- **Description:** Build a 5-section schema description:

```markdown
## Context
{Content mapped from brief "Problem Statement"}
{If [OPUS INFERRED]: mark the section}

## Acceptance Criteria
{Content mapped from brief "Acceptance Criteria"}
{Each criterion must be in checklist format: - [ ] ...}
{If [OPUS INFERRED]: mark the section}

## Architecture Notes
{Content mapped from brief "Proposed Architecture"}

{Content mapped from brief "Key Decisions and Tradeoffs"}
{If [OPUS INFERRED]: mark the section}

## Dependencies
{Derived from brief "Risk Assessment" — extract items that are genuine blockers}
{If no blockers: "None — no blocking dependencies."}
{If [OPUS INFERRED]: mark the section}

## Scope Boundary
{Derived from brief "Risk Assessment" — extract items that are out-of-scope risks}
{Add standard exclusions based on project patterns}
{If [OPUS INFERRED]: mark the section}
```

### 5d. Map sub-task breakdown to sub-issues

Parse the brief's "## Suggested Sub-task Breakdown" section. For each sub-task:

1. Extract: title, description, estimated complexity (S/M/L)
2. Generate a full 5-section schema description for each sub-issue

**Sub-issue schema generation:**

For each sub-task, construct:

```markdown
## Context
{Derived from sub-task description and parent context. 2-3 sentences minimum.}
{Reference the parent issue for broader context.}

## Acceptance Criteria
{Derive testable criteria from the sub-task description.}
{Each in checklist format: - [ ] Concrete, observable outcome}
{Minimum 3 criteria.}

## Architecture Notes
{Derive from parent Architecture Notes — scoped to this sub-task.}
{Include specific file paths, function signatures where inferrable from the brief.}
{Reference patterns from CLAUDE.md where applicable.}

## Dependencies
{If this sub-task depends on a prior sub-task, reference it by title using @@DEP:<title>@@ placeholder.}
{IMPORTANT: The <title> inside @@DEP@@ must exactly match the sub-issue title as generated in this step. Copy-paste the title verbatim to avoid mismatches. Step 7e resolves these using case-insensitive, whitespace-normalized matching, but exact titles are preferred.}
{If no dependencies: "None — no blocking dependencies."}

## Scope Boundary
{What this sub-issue does NOT cover — reference other sub-issues for deferred work.}
{Minimum 2 exclusions.}
```

### 5e. Apply [OPUS INFERRED] markers

After constructing all issue descriptions, scan each section for gaps. Apply the `[OPUS INFERRED]` marker when:

| Condition | Section | Action |
|-----------|---------|--------|
| Brief has no "Problem Statement" or it's < 50 chars | `## Context` | Opus generates context from topic + project patterns, marks with `[OPUS INFERRED]` |
| Brief has no "Acceptance Criteria" or criteria are not testable (no checklist format, no verifiable conditions) | `## Acceptance Criteria` | Opus generates testable criteria, marks with `[OPUS INFERRED]` |
| Brief has no file paths or function signatures in "Proposed Architecture" | `## Architecture Notes` | Opus infers from codebase (reading CLAUDE.md, existing skills), marks with `[OPUS INFERRED]` |
| Brief has no "Risk Assessment" or it's < 30 chars | `## Dependencies` and `## Scope Boundary` | Opus generates based on project patterns, marks with `[OPUS INFERRED]` |
| Brief has no explicit scope exclusions | `## Scope Boundary` | Opus generates based on project patterns, marks with `[OPUS INFERRED]` |

**Marker format:** Insert at the top of the affected section:

```markdown
> [OPUS INFERRED] This section was not covered in the Codex brief and was generated by Opus based on project context.
```

If only part of a section was inferred (e.g., Codex provided architecture but no file paths):

```markdown
> [OPUS INFERRED] File paths and function signatures below were not in the Codex brief — inferred from existing codebase patterns.
```

### 5f. Self-validate all issue descriptions

Before proceeding to the approval loop, validate every generated description against the harness schema:

```
VALIDATION RULES (from schema.md):
1. All five headings present:
   regex: ^## (Context|Acceptance Criteria|Architecture Notes|Dependencies|Scope Boundary)
   → check each of the five exists

2. Strip placeholder lines and enforce minimum content:
   → strip lines matching ^\[.*\]$ (square-bracket placeholders)
   → remaining non-whitespace chars must be >= 20 per section

3. [OPUS INFERRED] markers do NOT count as placeholder lines
   (they are legitimate content markers, not empty placeholders)
```

If validation fails for any issue:
- Regenerate the failing section by re-reading the brief and the codebase context
- Re-validate after regeneration
- If second attempt fails, mark the section with `[VALIDATION WARNING]` and proceed — the human reviewer will see it in the approval loop

### 5g. Write translated schemas to review directory

Save the complete translation output for reference:

```bash
mkdir -p .reviews/design/"$TOPIC_SLUG"
```

Write to `.reviews/design/{topic_slug}/schema-proposal.md`:

```markdown
# Schema Proposal — {topic}

> Generated by harness-design-v2 (Opus translation step)
> Date: {YYYY-MM-DD}
> Source brief: .reviews/design/{topic_slug}/brief.md

## Parent Issue

**Title:** {parent issue title}

{parent issue description — full 5-section schema}

---

## Sub-issue 1: {sub-issue title}

**Complexity:** {S/M/L}

{sub-issue description — full 5-section schema}

---

## Sub-issue 2: {sub-issue title}

...
```

---

## Step 6 — Approval Loop

Present the proposed issue structure to the user for review. The user MUST explicitly approve before any Linear mutations occur.

### 6a. Present the proposal

Display a structured summary of what will be created:

```
PROPOSED LINEAR ISSUE STRUCTURE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Project: {PROJECT_NAME}
Assignee: {USER_NAME}
State: Backlog (all issues)

Parent Issue: {parent title}
  {Show [OPUS INFERRED] sections if any: "⚠️ [OPUS INFERRED] sections: Context, Scope Boundary"}
  {Show [VALIDATION WARNING] sections if any: "🛑 [VALIDATION WARNING] sections: Architecture Notes — requires manual review"}

Sub-issues:
  1. {sub-issue title} ({complexity}) {[OPUS INFERRED] / [VALIDATION WARNING] markers if any}
  2. {sub-issue title} ({complexity}) {[OPUS INFERRED] / [VALIDATION WARNING] markers if any}
  ...

Dependencies:
  {sub-issue 2} blocked by {sub-issue 1}
  ...

Total issues to create: {N} (1 parent + {N-1} sub-issues)

{If any [VALIDATION WARNING] sections exist:}
🛑  WARNING: {count} section(s) failed schema validation and are marked [VALIDATION WARNING].
    Review the full schema proposal carefully before approving.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Full schema proposal saved to: .reviews/design/{topic_slug}/schema-proposal.md
Review it for complete descriptions before approving.
```

### 6b. Approval question

Use `AskUserQuestion` with these options:

```
Review the proposed issue structure above. What would you like to do?

A) Approve — create all issues in Linear as proposed
B) Revise — provide feedback to adjust the proposal
C) Reject — exit without creating any issues
```

### 6c. Handle each response

**Approve:**
- Proceed to Step 7 (Linear issue creation)

**Revise:**
- The user selects "Revise" which indicates they want changes. Check if the user provided notes in the AskUserQuestion response first.
- **If the user provided notes** (non-empty text in the response): use those notes directly as the revision instructions. Do NOT ask a follow-up question.
- **If the user selected "Revise" without providing notes:** Use a **follow-up AskUserQuestion** to collect specific feedback:

  ```
  What changes would you like to the proposal? Select the areas to revise:
  A) Parent issue title or description
  B) Sub-issue structure (add, remove, or rename sub-issues)
  C) Dependencies between sub-issues
  D) Other (describe in the text field below)
  ```

  After the user selects a category, interpret the response and apply changes:
  - **A (Parent issue):** Re-read the brief and regenerate the parent issue description. If the user provided specific notes with the category selection, incorporate those notes.
  - **B (Sub-issue structure):** Re-read the brief's Sub-task Breakdown and regenerate sub-issues. If notes say "add X" or "remove Y", apply those specific edits.
  - **C (Dependencies):** Adjust the `@@DEP:` graph based on the user's input. If no specific input, show the current dependency list and ask which to change.
  - **D (Other):** Apply the user's free-text instructions directly to the schema proposal.

- Apply the requested changes to the schema proposal
- Re-validate affected descriptions (Step 5f)
- Re-write the updated schema-proposal.md to disk (so re-entry picks up revisions)
- Re-present the updated proposal (go back to 6a)
- Track the revision round number

**Reject:**
- Print: `Rejected — no Linear issues created. Brief preserved at .reviews/design/{topic_slug}/brief.md`
- STOP — do not create any Linear issues

### 6d. Revision round cap

Maximum 3 revision rounds. Track with `REVISION_ROUND` counter (starts at 0, increments on each Revise).

```
REVISION_ROUND = 0

LOOP:
  Present proposal (6a)
  Ask approval (6b)

  IF Approve: BREAK → proceed to Step 7
  IF Reject: STOP

  REVISION_ROUND += 1

  IF REVISION_ROUND > 3:
    AskUserQuestion:
      "You've revised the proposal 3 times. Would you like to:"
      A) Proceed with the current structure anyway
      B) Abort — no issues created

    IF A: BREAK → proceed to Step 7
    IF B: STOP
  
  Apply user feedback
  Re-validate
  GOTO LOOP
```

---

## Step 7 — Linear Issue Creation

Create the parent issue and all sub-issues in Linear. This step ONLY executes after explicit user approval in Step 6.

### 7a. Determine team

Resolve the team for issue creation:

```
mcp__linear-server__list_teams()
```

If the project context already provides a team (from Step 5b), use that. Otherwise, if only one team exists, use it automatically. If multiple teams exist, ask the user via `AskUserQuestion`.

### 7b. Check for existing milestone

If the parent issue specifies a milestone (e.g., from the brief's phase structure), check if it exists:

```
mcp__linear-server__list_milestones(project: "<PROJECT_ID>")
```

If a matching milestone exists, record its ID. If not, and the brief suggests a phase/milestone, **ask the user for confirmation before creating:**

```
AskUserQuestion:
  "The brief suggests milestone '{name}' but it doesn't exist in project {PROJECT_NAME}."
  A) Create the milestone
  B) Skip milestone assignment (issues will have no milestone)
  C) Assign to an existing milestone (list the existing ones)
```

Only create the milestone after explicit user approval:

```
mcp__linear-server__save_milestone(
  project: "<PROJECT_ID>",
  name: "<milestone name>",
  description: "<1-sentence summary>"
)
```

If no milestone is suggested by the brief, skip milestone assignment — issues will be created without a milestone.

### 7c. Create parent issue

**Dedup check first:**

```
mcp__linear-server__list_issues(
  project: "<PROJECT_ID>",
  query: "<parent issue title>"
)
```

Compare returned issue titles against the parent title using **case-insensitive, whitespace-normalized** comparison (see 7d for details). If an exact match exists:

1. Record its ID as `PARENT_ISSUE_ID`
2. **Compare descriptions:** Read the existing issue's full description via `get_issue`. If the existing description differs from the newly generated description (beyond whitespace differences), warn the user:

   ```
   ⚠️  Existing parent issue WHI-{id} found with a different description than the current proposal.
   ```

   Use `AskUserQuestion`:
   ```
   A) Update the existing issue's description to match the current proposal
   B) Keep the existing description as-is
   ```

   If the user picks A, call `save_issue(id: ..., description: "<new description>")` to update.

3. Print: `Existing parent issue found: WHI-{id}. Skipping creation.`

**If no match — create:**

```
mcp__linear-server__save_issue(
  team: "<TEAM_ID>",
  project: "<PROJECT_ID>",
  title: "<parent issue title>",
  description: "<validated parent issue description>",
  state: "Backlog",
  assignee: "me",
  milestone: "<MILESTONE_ID>"   // if available
)
```

Record the returned issue ID as `PARENT_ISSUE_ID`.

**If creation fails:**
- Print: `ERROR: Failed to create parent issue: <error>`
- STOP — sub-issues cannot be created without a parent

### 7d. Create sub-issues in dependency order

**Topological sort:** Before creating any sub-issues, build a dependency graph from the `@@DEP:<title>@@` placeholders and perform a topological sort. Use Kahn's algorithm (BFS-based):

1. Build adjacency list: for each sub-issue, record which other sub-issues it depends on
2. Compute in-degree for each sub-issue
3. Start with sub-issues that have in-degree 0 (no dependencies)
4. Process queue: create issue, decrement in-degree of dependents, enqueue newly-zero dependents
5. **Cycle detection:** If the queue empties but not all sub-issues are processed, a dependency cycle exists

**If a cycle is detected:**
- Print: `ERROR: Dependency cycle detected among sub-issues: {list of titles in the cycle}`
- Print: `Breaking cycle by removing the dependency from the last sub-issue in the cycle.`
- Remove one edge to break the cycle and retry the topological sort
- Warn the user which dependency was dropped

Process sub-issues in topological order:

**Dedup check before each create:**

```
mcp__linear-server__list_issues(
  project: "<PROJECT_ID>",
  query: "<sub-issue title>"
)
```

Compare returned issue titles using **case-insensitive, whitespace-normalized** comparison: lowercase both, collapse whitespace to single spaces, trim. If a normalized match exists:
- Record the existing ID in the title → ID map
- **Compare descriptions:** If the existing description differs from the newly generated one, print `NOTE: Sub-issue "{title}" already exists (WHI-{id}) with a different description. Keeping existing description.` (Sub-issue descriptions are not auto-updated to avoid disrupting in-progress work; the user can manually update via Linear if needed.)
- Skip creation

If multiple partial matches are returned but none is an exact normalized match, proceed with creation (do not skip on fuzzy matches).

**For each sub-issue:**

```
mcp__linear-server__save_issue(
  team: "<TEAM_ID>",
  project: "<PROJECT_ID>",
  title: "<sub-issue title>",
  description: "<validated sub-issue description>",
  state: "Backlog",
  assignee: "me",
  parentId: "<PARENT_ISSUE_ID>",
  milestone: "<MILESTONE_ID>"   // if available — sub-issues do NOT inherit parent milestone
)
```

Record each returned issue ID. Map: sub-issue title → Linear issue ID.

**If a sub-issue creation fails:**
- Print: `WARNING: Failed to create sub-issue "<title>": <error>`
- Continue creating remaining sub-issues — do NOT abort
- Record failed sub-issues for the summary

### 7e. Resolve dependency placeholders (second pass)

After ALL issues are created, rewrite descriptions to replace `@@DEP:<title>@@` placeholders with actual `WHI-<N>` references.

**Scope:** This pass covers ALL issues in the title → ID map — both newly created and pre-existing (found via dedup check). Pre-existing issues from prior failed runs may still have stale `@@DEP:` tags that need resolution.

1. For every issue in the title → ID map whose description contains `@@DEP:...@@` tags:
   - Read the current description from Linear (not from the in-memory version) to catch any manual edits: `mcp__linear-server__get_issue(id: "<issue-id>")`
   - Build the final Dependencies section: replace each `@@DEP:<title>@@` with the resolved `WHI-<N>` from the title → ID map. Use **case-insensitive, whitespace-normalized** matching for the title lookup.
   - **Two-step update (description first, then relation):**
     1. Call `mcp__linear-server__save_issue(id: "<issue-id>", description: "<rewritten description>")` to update the description text
     2. Call `mcp__linear-server__save_issue(id: "<issue-id>", blockedBy: ["<blocking-issue-id>"])` to set the blocking relation
   - **If the description update fails:** Print `WARNING: Failed to update description for "<title>": <error>`. The `@@DEP:` tags remain in the live description — on re-entry, this issue will be retried (tags still present → eligible for resolution).
   - **If the `blockedBy` relation fails:** Print `WARNING: Description updated for "<title>" but blocking relation to WHI-{N} was NOT set. You must add this relation manually in Linear.` This ensures the user knows the relation is missing even though the description text looks correct.
2. If a referenced title was not created (failed or skipped), replace the tag with `(dependency "<title>" — not created; see schema-proposal.md)` and print `WARNING: Unresolvable dependency "<title>" in issue "<issue title>".`
3. **Final validation:** After the pass, re-read all issue descriptions from Linear (not in-memory) and check for any remaining `@@DEP:...@@` tags. If any remain, print a final warning listing the issue IDs and the unresolved tags. Also verify that every resolved `blockedBy` relation is actually set by checking `get_issue(includeRelations: true)` for each issue that should have a blocking relation.

### 7f. All issues in Backlog state

All issues are created in `Backlog` state. Do NOT transition to any other state — that is `/harness-dev`'s job when implementation begins.

---

## Step 8 — Summary Output

After all creation is complete, print the structured summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  harness-design-v2 complete for {topic}

Project:              {PROJECT_NAME}
Parent issue:         WHI-{parent_id}: {parent_title}
Sub-issues created:   {N}
Sub-issues failed:    {F}  ← (0 if all succeeded)
[OPUS INFERRED]:      {count of sections marked}
Revision rounds:      {REVISION_ROUND}

Issue hierarchy:
  WHI-{parent}: {parent title} (parent)
    WHI-{a}: {sub-issue title} [no blockers]
    WHI-{b}: {sub-issue title} [blocked by WHI-{a}]
    ...

Failed issues (if any):
  ❌ {title} — {error}

Artifacts:
  Brief:    .reviews/design/{topic_slug}/brief.md
  Schema:   .reviews/design/{topic_slug}/schema-proposal.md

Next step:  /harness-dev WHI-{first-unblocked-sub-issue-id}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Handling Reference

| Failure Point | Recovery Action |
|---------------|-----------------|
| Codex CLI not found | ERROR with install instructions, STOP |
| Codex authentication failed | ERROR with `codex login` instructions, STOP |
| Codex invocation timeout (10 min) | ERROR with retry suggestion, STOP |
| Linear API unavailable (context gathering) | Warn, continue with reduced context |
| CLAUDE.md not found | Warn, continue with reduced context |
| No git history | Continue with empty git log section |
| Topic slug collision (dir exists) | Overwrite — design briefs are iterative artifacts |
| Brief has < 3/6 sections (Step 4a) | Warn, offer retry/write-as-is/abort |
| Schema validation fails (Step 5f) | Regenerate; if 2nd attempt fails, mark [VALIDATION WARNING] |
| User rejects proposal (Step 6) | STOP cleanly, preserve brief |
| Revision cap reached (Step 6d) | Ask: proceed anyway or abort |
| Parent issue creation fails (Step 7c) | STOP — sub-issues need a parent |
| Sub-issue creation fails (Step 7d) | Warn, continue with remaining sub-issues |
| Dependency placeholder unresolvable (Step 7e) | Replace with descriptive fallback text |

---

## Re-entry Detection

Before running Step 1, check whether a prior run already produced artifacts:

```bash
TOPIC_SLUG="<slug>"

# Check for existing brief
BRIEF_EXISTS=$([ -f ".reviews/design/$TOPIC_SLUG/brief.md" ] && echo "yes" || echo "no")

# Check for existing schema proposal
SCHEMA_EXISTS=$([ -f ".reviews/design/$TOPIC_SLUG/schema-proposal.md" ] && echo "yes" || echo "no")

echo "Brief: $BRIEF_EXISTS"
echo "Schema proposal: $SCHEMA_EXISTS"
```

**Decision table:**

| Brief exists? | Schema exists? | Entry point |
|---|---|---|
| No | No | Full run — Steps 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 |
| Yes | No | Skip Codex invocation — jump to Step 5 (reuse existing brief) |
| Yes | Yes | Skip to Step 5f (re-validate existing schema), then proceed to Step 6 |

**Important:** On re-entry with existing schema-proposal.md, always re-run Step 5f (schema validation) before entering the approval loop. The on-disk schema may be stale, corrupted, or from a partially failed prior run. Never skip validation.

When skipping steps, print:

```
⏩  Re-entry detected: {brief/schema} found at {path}.
    Re-validating schema (Step 5f) before proceeding to approval...
    Resuming from Step {N}.
```

---

## Scope Boundary

This skill handles the **full v2 design pipeline**:
- Input parsing (free text or Linear URL)
- Context gathering (CLAUDE.md, git log, active Linear issues)
- Codex consult invocation and brief generation
- Brief-to-schema translation with [OPUS INFERRED] markers
- Human approval loop (approve / revise / reject)
- Linear issue creation (parent + sub-issues in Backlog)

This skill does NOT:
- Modify any v1 skills (harness-design, harness-dev, etc.)
- Auto-approve without human confirmation
- Create milestone/phase structure beyond what the brief suggests
- Run multi-turn Codex design sessions beyond the initial consult
- Transition issues to `In Progress` — that is `/harness-dev`'s job
- Run adversarial review, implement features, or manage worktrees
