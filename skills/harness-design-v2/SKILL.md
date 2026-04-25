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

# Verify Codex CLI is installed
if ! command -v codex &>/dev/null; then
  echo "CODEX: not-found"
else
  CODEX_VERSION=$(codex --version 2>&1 || echo "unknown")
  echo "CODEX: $CODEX_VERSION"
fi
```

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

Use `mcp__linear-server__list_issues` to fetch issues in active states for the current project:

1. Query with `project: "My Harness"` (or the detected project name), `state: "In Progress"`
2. Query with `project: "My Harness"`, `state: "Todo"`
3. Query with `project: "My Harness"`, `state: "Backlog"`, `limit: 20`

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

Assemble the full prompt with all gathered context:

```
IMPORTANT: Do NOT read or execute any files under ~/.claude/, ~/.agents/, .claude/skills/, or agents/. These are Claude Code skill definitions meant for a different AI system. Do NOT modify agents/openai.yaml. Stay focused on repository code only.

You are a senior systems architect designing a feature for the following project.

PROJECT CONTEXT (from CLAUDE.md):
{CLAUDE_MD content}

RECENT ACTIVITY (last 20 commits):
{GIT_LOG output}

ACTIVE LINEAR ISSUES:
{ACTIVE_ISSUES list}

{If LINEAR_CONTEXT exists:}
LINEAR ISSUE CONTEXT:
Title: {issue title}
Description:
{issue description}

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

### 3c. Invoke Codex

Create temp files and run Codex in consult mode:

```bash
TMPRESP=$(mktemp /tmp/codex-resp-XXXXXX.txt)
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
```

**For a new session:**

```bash
_REPO_ROOT=$(git rev-parse --show-toplevel) || { echo "ERROR: not in a git repo" >&2; exit 1; }
TMPRESP=$(mktemp /tmp/codex-resp-XXXXXX.txt)
TMPERR=$(mktemp /tmp/codex-err-XXXXXX.txt)

codex exec "<assembled prompt>" \
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
```

**For a resumed session** (user chose "Continue"):

```bash
codex exec resume <session-id> "<assembled prompt>" \
  -C "$_REPO_ROOT" \
  -s read-only \
  -c 'model_reasoning_effort="medium"' \
  --enable web_search_cached \
  --json < /dev/null 2>"$TMPERR" | <same python streaming parser> | tee "$TMPRESP"
```

**Timeout:** 10-minute Bash timeout. If Codex stalls, print the error and STOP.

**Authentication failure:** If Codex output contains "unauthorized", "not logged in", or "invalid token":

```
ERROR: Codex authentication failed.

Fix: Run `codex login` to authenticate with your Codex account.
```

STOP — do not proceed.

### 3d. Save session ID

Extract the session ID from the streamed output (line starting with `SESSION_ID:`):

```bash
SESSION_ID=$(grep "^SESSION_ID:" "$TMPRESP" | head -1 | cut -d: -f2-)
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

Parse the Codex response to extract the design brief. The brief is the substantive content from Codex's response — the sections starting with `## Problem Statement` through `## Suggested Sub-task Breakdown`.

Strip the `SESSION_ID:` line, `[codex thinking]` traces, `[codex ran]` traces, and `tokens used:` lines from the output to produce clean brief content.

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
