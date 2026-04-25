---
name: harness-design-v2
version: 0.1.0
description: "Codex-powered design with Opus Linear translation. Gathers project context, invokes Codex in consult mode to produce a structured design brief. First step of the two-step v2 design pipeline. Invoke with /harness-design-v2 <topic or Linear issue URL>."
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
---

# harness-design-v2

You are running the Codex-powered design skill. The user invoked this skill as `/harness-design-v2 <topic or Linear issue URL>` (or similar). Extract the argument from the invocation.

This skill gathers project context that Codex cannot read directly (local files, Linear state), embeds it in a structured prompt, and asks Codex to produce a design brief. This is the "Codex thinks" step of the v2 design pipeline.

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

### 4c. Present output

Display the brief to the user:

```
CODEX DESIGN BRIEF:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{brief content}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Brief saved to: .reviews/design/{topic_slug}/brief.md
Session saved — run /codex to continue the conversation with Codex.
```

**If Claude disagrees with any of Codex's analysis,** flag it clearly:

```
Note: Claude Code disagrees on X because Y.
```

---

## Error Handling Reference

| Failure Point | Recovery Action |
|---------------|-----------------|
| Codex CLI not found | ERROR with install instructions, STOP |
| Codex authentication failed | ERROR with `codex login` instructions, STOP |
| Codex invocation timeout (10 min) | ERROR with retry suggestion, STOP |
| Linear API unavailable | Warn, continue with reduced context |
| CLAUDE.md not found | Warn, continue with reduced context |
| No git history | Continue with empty git log section |
| Topic slug collision (dir exists) | Overwrite — design briefs are iterative artifacts |

---

## Scope Boundary

This skill ONLY handles:
- Input parsing (free text or Linear URL)
- Context gathering (CLAUDE.md, git log, active Linear issues)
- Codex consult invocation
- Brief output to `.reviews/design/{topic_slug}/brief.md`

This skill does NOT:
- Translate the brief to Linear issue schema (that is the next sub-issue, WHI-225)
- Create any Linear issues
- Modify any existing code or issues
- Run multi-turn Codex design sessions beyond the initial consult
