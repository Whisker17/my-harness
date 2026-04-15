---
name: harness-bootstrap
version: 1.0.0
description: "Bootstraps a new project with CLAUDE.md, AGENTS.md, git workflow, and Linear integration. Generates CLAUDE.md from the my-harness template with project-specific sections derived from the Linear project and detected tech stack. Invoke with /harness-bootstrap <linear-project-id> [remote-url]."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - AskUserQuestion
  - mcp__linear-server__get_project
  - mcp__linear-server__list_issues
  - mcp__linear-server__list_milestones
  - mcp__linear-server__list_issue_statuses
  - mcp__linear-server__list_teams
  - mcp__linear-server__save_comment
  - mcp__linear-server__get_issue
---

# harness-bootstrap

You are bootstrapping a new project's development environment. The user invoked this skill as
`/harness-bootstrap <linear-project-id> [remote-url]` (or similar). Extract the Linear project ID
and optional remote URL from the invocation arguments.

This skill is **idempotent**: if CLAUDE.md already exists, it asks whether to overwrite or abort.
Run it once at the start of a new project — not repeatedly.

## Preamble

Before any steps, run these checks in a single bash block:

```bash
# Detect repo context
CWD=$(pwd)
GIT_EXISTS=$([ -d ".git" ] && echo "yes" || echo "no")
CLAUDE_MD_EXISTS=$([ -f "CLAUDE.md" ] && echo "yes" || echo "no")
AGENTS_MD_EXISTS=$([ -f "AGENTS.md" ] && echo "yes" || echo "no")

# Detect tech stack from project files
HAS_PACKAGE_JSON=$([ -f "package.json" ] && echo "yes" || echo "no")
HAS_PYPROJECT=$([ -f "pyproject.toml" ] && echo "yes" || echo "no")
HAS_GO_MOD=$([ -f "go.mod" ] && echo "yes" || echo "no")
HAS_CARGO=$([ -f "Cargo.toml" ] && echo "yes" || echo "no")

echo "CWD: $CWD"
echo "Git repo: $GIT_EXISTS"
echo "CLAUDE.md: $CLAUDE_MD_EXISTS"
echo "AGENTS.md: $AGENTS_MD_EXISTS"
echo "package.json: $HAS_PACKAGE_JSON"
echo "pyproject.toml: $HAS_PYPROJECT"
echo "go.mod: $HAS_GO_MOD"
echo "Cargo.toml: $HAS_CARGO"

# Derive gstack slug from CWD
SLUG=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | tr -s '-' | sed 's/^-//;s/-$//')
echo "Slug: $SLUG"
```

Print the preamble results for the user to verify before proceeding.

---

## Step 1 — Project Detection

Read the Linear project details and discover the team's issue state names.

### 1a. Resolve the Linear project

Extract the project argument (first argument after `/harness-bootstrap`). Try to resolve it:

```
mcp__linear-server__get_project(query: "<argument>", includeMembers: false, includeMilestones: true)
```

If it resolves successfully:
- Record: project `id`, `name`, `description`, `teamId`, milestone list
- Print: `✅  Resolved Linear project: <name> (<id>)`

If `get_project` fails (project not found):
- Use `AskUserQuestion`:
  ```
  No Linear project found matching "<argument>".

  Please provide a Linear project ID, slug, or exact name to continue.
  (Or type "cancel" to abort.)
  ```
- Retry once with the user's answer. If still not found, STOP with:
  ```
  ❌  Cannot resolve Linear project after 2 attempts. Aborting.
  Run /harness-bootstrap again with a valid project ID.
  ```

If no argument was provided:
- Use `AskUserQuestion`:
  ```
  Which Linear project is this repo for?
  Provide a project ID, URL slug, or exact name.
  ```
- Then attempt `get_project` as above.

### 1b. Resolve the team

Use `list_teams` to find the team by ID (from the project object):

```
mcp__linear-server__list_teams()
```

Match the team using the project's `teamId`. Record the **team key** (e.g., `WHI`), **team name**,
and **team ID** — these are used in branch naming and Linear issue links in the generated CLAUDE.md.

Also derive the **workspace slug** from the team's URL. If the workspace slug cannot be derived
from the API response, use `AskUserQuestion` to ask the user:
```
What is your Linear workspace slug? (e.g., "my-company" from linear.app/my-company/...)
```

### 1c. Fetch issue state names

```
mcp__linear-server__list_issue_statuses(team: "<team-name>")
```

Build the ordered state flow by sorting the returned states by their workflow type:

| Type | Typical order |
|------|--------------|
| `backlog` | Backlog |
| `unstarted` | Todo |
| `started` (first by name sort) | In Progress |
| `started` (second, if exists) | In Review |
| `completed` | Done |
| `canceled` | _(excluded from flow diagram)_ |

**Multiple states of the same type:** If the API returns more than one state for a given type
(e.g., two `canceled` states: "Canceled" and "Duplicate"), include only the first by name sort
in the flow diagram. Extra `canceled` and `completed` states are excluded from the forward flow.

**Ordering caveat:** Sorting `started` states alphabetically works for default English names
("In Progress" < "In Review") but may produce incorrect order for custom names. The Linear MCP
API does not expose a `position` field. After building the flow, **always confirm with the user**:

Use `AskUserQuestion`:
```
The detected state flow for your team is:

  <constructed-flow-string>

States used in workflow references:
  - Starting work → "<first-started-state>"
  - Submitting for review → "<second-started-state>"
  - Completed → "<completed-state>"

Is this order correct?
  1. Yes — looks correct
  2. No — let me reorder
```

If the user picks **2**, ask them to provide the correct order of `started` states and use that.

Produce a flow string like:
```
Backlog ──► Todo ──► In Progress ──► In Review ──► Done
```

Store the ordered state names — they will be embedded verbatim in the generated CLAUDE.md.

**Important:** Use state NAMES only, never hardcode IDs. IDs change when teams reconfigure their
workflow. State names are stable and human-readable.

### 1d. Fetch project issues (for dependency context)

```
mcp__linear-server__list_issues(project: "<project-id>", limit: 50)
```

Store the issue list for use in Step 4 (Active Issues section of CLAUDE.md).

### 1e. Check for design doc

```bash
SLUG="<slug-from-preamble>"
DESIGN_DOC=$(ls -t ~/.gstack/projects/"$SLUG"/*-design-*.md 2>/dev/null | head -1)
echo "Design doc: ${DESIGN_DOC:-not found}"
```

If a design doc is found, read its "Architecture Notes", "Recommended Approach", or key technical
sections for use in Step 4's Architecture section. If not found, the Architecture section will be
a placeholder for the user to fill in.

---

## Step 2 — Repo Detection

Decide whether to initialize a new git repo or use the existing one.

### 2a. Existing repo (`.git` present)

If `GIT_EXISTS` is `yes` (from the preamble):
- Print: `✅  Using existing git repo at $CWD`
- Verify the default branch structure:
  ```bash
  git branch -a 2>/dev/null | grep -E "(main|dev)"
  ```
- If neither `main` nor `dev` branch exists yet, proceed as if this is a new repo (Step 2b)
  but skip the `git init`.

### 2b. New repo (`.git` absent)

If `GIT_EXISTS` is `no`:
- Initialize:
  ```bash
  git init
  git checkout -b main
  ```
- Create an initial empty commit so the `main` branch has a ref:
  ```bash
  git commit --allow-empty -m "chore: initial commit"
  ```
- Create the `dev` branch from `main`:
  ```bash
  git checkout -b dev
  ```
- Print: `✅  Initialized new git repo with main + dev branches`

### 2c. Remote URL handling

Extract the second argument (if provided): `REMOTE_URL`.

If `REMOTE_URL` is provided:
- Validate the URL format: must match `^(https://[a-zA-Z0-9._/-]+|git@[a-zA-Z0-9._:/-]+)$`
- Add the remote (use single quotes to prevent shell expansion):
  ```bash
  git remote add origin '<REMOTE_URL>'
  ```
- If `git remote add` fails (remote already exists), print:
  `⚠️  Remote 'origin' already exists: <current-remote>. Skipping remote add.`
- Do NOT push yet — pushing happens in Step 6 (GitHub setup).

If `REMOTE_URL` is not provided:
- Print: `ℹ️  No remote URL provided. Skipping remote setup. Run Step 6 manually or re-invoke with a URL.`
- Continue to Step 3.

---

## Step 3 — Tech Stack Detection

Determine the tech stack from project files detected in the preamble.

### Detection priority (in order)

1. **Node/TypeScript**: `package.json` present → stack = `node`
2. **Python**: `pyproject.toml` present → stack = `python`
3. **Go**: `go.mod` present → stack = `go`
4. **Rust**: `Cargo.toml` present → stack = `rust`
5. **None detected**: → ask user

### If no stack file detected

Use `AskUserQuestion`:

```
No tech stack files found (package.json, pyproject.toml, go.mod, Cargo.toml).

What is your tech stack?
  1. TypeScript / Node.js
  2. Python
  3. Go
  4. Rust
  5. Other

Enter a number (1-5):
```

- For choices 1-4: map to the corresponding stack name above
- For choice 5 ("Other"): set `stack = other`

### Stack-specific build command templates

| Stack | Build command | Test command | Dev command |
|-------|--------------|--------------|-------------|
| `node` | `npm run build` (or `pnpm build` / `yarn build`) | `npm test` | `npm run dev` |
| `python` | `pip install -e .` (or `uv sync`) | `pytest` | `python -m <package>` |
| `go` | `go build ./...` | `go test ./...` | `go run .` |
| `rust` | `cargo build` | `cargo test` | `cargo run` |
| `other` | _(placeholder — user fills in)_ | _(placeholder)_ | _(placeholder)_ |

For `node` projects: check whether `pnpm-lock.yaml` or `yarn.lock` exists and use the
corresponding package manager instead of `npm`.

For `python` projects: check whether `uv.lock` exists and prefer `uv sync` over `pip install -e .`.

Print: `✅  Detected stack: <stack>. Build: <build-cmd>, Test: <test-cmd>`

---

## Step 4 — CLAUDE.md Generation

Generate the CLAUDE.md file. This is the primary output of harness-bootstrap.

The structure uses the my-harness CLAUDE.md as the **static skeleton** (generic workflow sections)
with project-specific sections prepended and appended.

### 4a. Check for existing CLAUDE.md

If `CLAUDE_MD_EXISTS` is `yes` (from the preamble):
- Use `AskUserQuestion`:
  ```
  CLAUDE.md already exists in this directory.

  Options:
    1. Overwrite — regenerate CLAUDE.md from the harness template (existing file will be replaced)
    2. Abort — keep the existing CLAUDE.md and stop

  Which would you prefer?
  ```
- If user picks **2**: print `Aborted — existing CLAUDE.md preserved.` and STOP.
- If user picks **1**: proceed with generation (the Write step will overwrite).

### 4b. Compose the issue prefix

From the team key and project name, derive the issue prefix used in branch naming.

Example: team key `WHI` → issue IDs are `WHI-<N>`.

Store as `ISSUE_PREFIX` (e.g., `WHI`).

### 4c. Compose build commands section

**Note:** The code examples below use `\`` to escape backticks inside markdown code blocks for
SKILL.md rendering purposes only. When writing the actual CLAUDE.md to disk, use real triple
backticks (` ``` `). Do NOT include backslashes in the generated output.

For `other` stack, use this placeholder block:

```markdown
## Build & Development Commands

<!-- TODO: Fill in your project's build, test, and dev commands -->

\`\`\`bash
# Build
<your build command here>

# Test
<your test command here>

# Dev / run
<your dev command here>
\`\`\`
```

For all other stacks, use the concrete commands from Step 3.

Example for `node` with `pnpm`:

```markdown
## Build & Development Commands

\`\`\`bash
# Install dependencies
pnpm install

# Build
pnpm build

# Test
pnpm test

# Dev (watch mode)
pnpm dev
\`\`\`
```

### 4d. Compose architecture section

If a design doc was found in Step 1e:
- Read the technical sections from the design doc
- Summarize the key architectural decisions into 3-5 bullet points

If no design doc was found:

```markdown
## Architecture

<!-- TODO: Fill in your project's architecture overview -->
<!-- Reference: ~/.gstack/projects/<slug>/ if you have a design doc from /harness-design -->

Key components:
- (to be documented)
```

### 4e. Compose Active Issues section

From the issues fetched in Step 1d:

If there are 0 issues: omit this section entirely.

If there are 1-10 issues: list all of them.

If there are >10 issues: list the 10 most recently updated.

Format:

```markdown
## Active Issues

| ID | Title | Status |
|----|-------|--------|
| WHI-N | <title> | <status-name> |
```

### 4f. Write CLAUDE.md

Assemble the complete CLAUDE.md and write it to `CLAUDE.md` in the current working directory.

**Substitution map** (replace each placeholder with the actual value):

| Placeholder | Value source |
|-------------|--------------|
| `<project-name>` | Linear project `name` |
| `<project-url>` | Linear project `url` field from `get_project` response (use verbatim — do NOT derive from name) |
| `<workspace>` | Workspace slug (from team URL or `AskUserQuestion` if not derivable) |
| `<team-name>` | Team `name` from Step 1b |
| `<ISSUE_PREFIX>` | Team key from Step 1b (e.g., `WHI`) |
| `<project-description>` | Project `description` from Linear (first 300 chars, truncated with "..." if longer) |
| `<STATE_FLOW_STRING>` | State flow from Step 1c |
| `<STATE_STARTED>` | Name of the first `started`-type state (e.g., "In Progress") from Step 1c |
| `<STATE_REVIEW>` | Name of the second `started`-type state (e.g., "In Review") from Step 1c |
| `<STATE_COMPLETED>` | Name of the `completed`-type state (e.g., "Done") from Step 1c |

If the project description in Linear is empty or a one-liner, add this note in the Project
Overview section:

```
<!-- TODO: Expand this description in Linear to give Claude more project context. -->
```

**Full CLAUDE.md content to write** (use actual values, not placeholders, when writing to disk):

```
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Project:** <project-name>
**Linear Project:** [<project-name>](<project-url>)
**Team:** <team-name> (issue prefix: `<ISSUE_PREFIX>-<N>`)

<project-description>

## Git Workflow

- **`main`** — release/deploy only, not for daily development
- **`dev`** — primary development branch, all feature work branches from here
- Every development task MUST use a git worktree branched from `dev`
- Branch naming: `<type>/<ISSUE_PREFIX>-<N>-<short-desc>` where type is `feat`, `fix`, or `chore` (e.g., `feat/<ISSUE_PREFIX>-58-data-fetcher`, `fix/<ISSUE_PREFIX>-60-bug-name`)
- Development happens in the feature worktree first, then reviewed via GitHub PR
- Every feature branch MUST be merged to `dev` through a GitHub PR (no direct `git merge`)
- Do NOT merge a PR until the user explicitly says the review is finished and there are no remaining issues
- PR merge strategy: **merge commit** (no squash, no rebase) — use `gh pr merge --merge`
- After PR merge, clean up the local worktree

### Worktree Lifecycle

```
1. git worktree add .worktrees/<name> -b <type>/<ISSUE_PREFIX>-<N>-<name> dev
2. Work in .worktrees/<name>/
3. Implement and verify in the feature worktree
4. Commit with message: "<type>(<ISSUE_PREFIX>-<N>): description"
5. Verify build passes (if applicable)
6. Push feature branch: git push -u origin <type>/<ISSUE_PREFIX>-<N>-<name>
7. Create PR: gh pr create --base dev --title "<type>(<ISSUE_PREFIX>-<N>): description" --body "..."
8. Run reviews on the PR (adversarial review, human review, Opus review)
9. Address review feedback, push fixes to the same branch
10. After approval: gh pr merge --merge --delete-branch
11. git checkout dev && git pull origin dev
12. git worktree remove .worktrees/<name>
```

### Task Transition

When the user says "继续下一个任务" or similar, follow this sequence before starting the next task:

1. Ensure the current task has passed review and the user has explicitly approved merge
2. Ensure all changes are committed and pushed on the current feature branch
3. Merge the PR: `gh pr merge --merge --delete-branch`
4. Switch to `dev` and sync: `cd <project-root> && git checkout dev && git pull origin dev`
5. Remove the worktree: `git worktree remove .worktrees/<name>`
6. **Update Linear**: move the completed issue to `Done` state (see Linear Workflow below)
7. Create a new worktree for the next task (per Worktree Lifecycle above)
8. **Update Linear**: move the next issue to `In Progress` state

## PR Workflow

### PR Creation

- Every feature branch MUST have a PR before review begins
- Create PR after implementation is committed and pushed:
  ```
  gh pr create --base dev --title "<type>(<ISSUE_PREFIX>-<N>): description" --body "..."
  ```
- PR body format:
  ```markdown
  ## Summary
  <1-3 bullet points describing what changed>

  ## Linear Issue
  [<ISSUE_PREFIX>-<N>](https://linear.app/<workspace>/issue/<ISSUE_PREFIX>-<N>)

  ## Test Plan
  - [ ] Build passes
  - [ ] <specific verification steps>
  ```
- Add labels for risk signals when applicable: `security`, `breaking-change`, `migration`

### PR Review Flow

1. After PR creation, run `/adversarial-review:run` (uses PR as review surface)
2. Fix Critical/Major findings, push to the same branch
3. Human review or Opus `/harness-review` on the PR
4. All reviews pass → user approves merge

### PR Merge

- Merge strategy: merge commit (`gh pr merge --merge`), NOT squash or rebase
- Use `--delete-branch` to auto-clean the remote branch
- After merge, sync local: `git checkout dev && git pull origin dev`
- Clean up worktree locally: `git worktree remove .worktrees/<name>`

## Linear Workflow

### Issue State Transitions

```
<STATE_FLOW_STRING>
```

- **Starting a task**: move issue + its sub-issues to `<STATE_STARTED>`
- **Submitting for review**: move issue to `<STATE_REVIEW>`
- **Review approved + merged**: move issue to `<STATE_COMPLETED>`
- **Review has feedback**: keep in `<STATE_REVIEW>`, address feedback, re-submit

### Mandatory Linear Updates

1. **Before starting implementation**: move the parent issue and all its sub-issues to `<STATE_STARTED>`
2. **As each sub-issue is completed**: move that sub-issue to `<STATE_COMPLETED>`
3. **When implementation is done, before requesting review**: move the parent issue to `<STATE_REVIEW>`
4. **After review is approved and code is merged to dev**: move the parent issue to `<STATE_COMPLETED>`
5. **If blocked**: add a comment on the Linear issue explaining what's blocking

## Schema Reference

The shared issue schema is at `~/.claude/skills/harness-dev/schema.md`.
```

After the schema reference line, append the following sections in order:

1. Build & Development Commands section (Step 4c)
2. Architecture section (Step 4d)
3. Active Issues section (Step 4e, only if issues exist)

Print: `✅  Generated CLAUDE.md`

---

## Step 5 — AGENTS.md Generation

### 5a. Check for existing AGENTS.md

If `AGENTS_MD_EXISTS` is `yes` (from the preamble):
- Print: `ℹ️  AGENTS.md already exists. Skipping — harness-bootstrap does not overwrite AGENTS.md.`
- Continue to Step 6 without writing AGENTS.md.

### 5b. Write AGENTS.md

Write the following content to `AGENTS.md`:

```markdown
# AGENTS.md

See [CLAUDE.md](./CLAUDE.md) for project context, development workflow, and coding standards.
Follow all instructions in CLAUDE.md when working on this project.
```

This is intentionally minimal. AGENTS.md exists for Codex compatibility — Codex reads AGENTS.md
while Claude Code reads CLAUDE.md. Both tools should follow the same CLAUDE.md conventions.

Print: `✅  Generated AGENTS.md`

---

## Step 6 — GitHub Setup

This step is **conditional**: it only runs if a remote URL was provided as an argument, OR if
the user requests GitHub setup after being prompted.

If a remote URL was already added in Step 2c: skip Step 6a and go directly to Step 6b.

If no remote URL was provided AND this is a new repo (from Step 2b):
- Use `AskUserQuestion`:
  ```
  No GitHub remote was set up. Would you like to create a private GitHub repo now?

  Options:
    1. Yes — create a private GitHub repo and push (requires `gh` CLI)
    2. No — I'll set up the remote manually later

  Which would you prefer?
  ```
- If user picks **2**: print `Skipping GitHub setup.` and continue to Step 7.
- If user picks **1**: proceed with Step 6a.

If no remote URL was provided AND this is an existing repo (from Step 2a):
- Skip this step entirely (existing repo presumably already has a remote or the user manages it).
- Print: `ℹ️  Existing repo — skipping GitHub setup. Remote configuration unchanged.`
- Continue to Step 7.

### 6a. Create private GitHub repo (if no remote yet)

First, verify `gh` is installed and authenticated:

```bash
which gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
```

If the `gh` CLI is not found:
- Print: `` ⚠️  `gh` CLI not found. Install it from https://cli.github.com/ to enable GitHub repo creation. ``
- Skip the rest of Step 6. Continue to Step 7.

If `gh auth status` fails (not authenticated):
- Print: `⚠️  GitHub CLI is not authenticated. Run 'gh auth login' first to enable repo creation.`
- Skip the rest of Step 6. Continue to Step 7.

If both checks pass, create the repo:

```bash
# Derive repo name from project name (lowercase, hyphens, max 100 chars)
REPO_NAME=$(echo "<project-name>" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | tr -s '-' | sed 's/^-//;s/-$//')
gh repo create "$REPO_NAME" --private --source=. --push
```

If `gh repo create` fails:
- Print: `⚠️  GitHub repo creation failed: <error>. Skipping remote push.`
- Continue to Step 7 — do NOT abort the bootstrap.

If `gh repo create` succeeds:
- Print: `✅  Created private GitHub repo: <repo-url>`
- Record the remote URL for the Step 8 summary.

### 6b. Push main and dev branches

If the remote already existed (set in Step 2c) OR was just created (Step 6a):

```bash
# Push main branch
git push -u origin main

# Push dev branch
git push -u origin dev

# Set main as the default branch (GitHub CLI)
gh repo edit --default-branch main 2>/dev/null || true
```

If push fails (e.g., no authentication, no network):
- Print: `⚠️  Push failed: <error>.`
- Print: `    Push manually with: git push -u origin main && git push -u origin dev`
- Continue to Step 7 — the commit is the critical action, not the push.

If push succeeds:
- Print: `✅  Pushed main + dev to origin. Default branch set to main.`

---

## Step 7 — Commit

Commit the generated files to the `dev` branch.

### 7a. Check current branch

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "Current branch: $CURRENT_BRANCH"
```

If the current branch is NOT `dev`:
- Print: `⚠️  Currently on $CURRENT_BRANCH branch. Switching to dev before committing.`
- ```bash
  git checkout dev 2>/dev/null || git checkout -b dev
  ```

### 7b. Stage and commit

Before staging, ensure `.gitignore` includes harness transient directories:

```bash
# Append to .gitignore if entries are missing (create file if absent)
touch .gitignore
grep -qxF '.harness/' .gitignore || echo '.harness/' >> .gitignore
grep -qxF '.reviews/' .gitignore || echo '.reviews/' >> .gitignore
grep -qxF '.worktrees/' .gitignore || echo '.worktrees/' >> .gitignore
```

```bash
git add CLAUDE.md AGENTS.md .gitignore
git status --short
git commit -m "chore: bootstrap project with CLAUDE.md and AGENTS.md"
```

If the commit exits with "nothing to commit":
- Print: `ℹ️  Nothing to commit — CLAUDE.md and AGENTS.md are unchanged.`
- Continue to Step 8.

If the commit succeeds:
- Print: `✅  Committed CLAUDE.md and AGENTS.md to dev`

### 7c. Push dev (if remote exists)

If a remote URL is configured (check with `git remote get-url origin 2>/dev/null`):

```bash
git push origin dev 2>/dev/null || echo "⚠️  Push failed — push manually with: git push origin dev"
```

---

## Step 8 — Output Summary

Print the final bootstrap summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  harness-bootstrap complete for <project-name>

Project:    <project-name> (<project-id>)
Team:       <team-name> (<ISSUE_PREFIX>-*)
Stack:      <stack>
Repo:       <CWD>
Remote:     <remote-url or "none (set up manually)">

Generated:
  ✅ CLAUDE.md   — project overview, git workflow, Linear workflow, build commands
  ✅ AGENTS.md   — Codex compatibility pointer to CLAUDE.md
  <✅ / ⚠️ / ℹ️> GitHub repo — <result from Step 6>
  ✅ Committed to dev

State flow embedded in CLAUDE.md:
  <STATE_FLOW_STRING>

Next steps:
  1. Review CLAUDE.md and fill in any TODO placeholder sections
  2. Run /harness-design <project-id> to populate Linear with issues (if not already done)
  3. Run /harness-dev <ISSUE_PREFIX>-<N> to start implementing the first issue
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Error Recovery Reference

| Failure point | Recovery action |
|---------------|-----------------|
| Step 1 — project not found | Ask user for correct project ID; retry once; STOP on second failure |
| Step 1 — team resolution fails | List all teams and ask user to pick; do NOT use a default |
| Step 2 — `git init` fails | Print error with full output; STOP — repo state is unknown |
| Step 2 — remote add fails (already exists) | Warn and continue with existing remote |
| Step 3 — stack detection returns "Other" | Ask user; use placeholder build section in CLAUDE.md |
| Step 4 — CLAUDE.md overwrite | Ask user explicitly; overwrite only on confirmation |
| Step 4 — Write fails (permissions, etc.) | Print error with full path; STOP — cannot bootstrap without CLAUDE.md |
| Step 6 — `gh` CLI not found | Print install URL; skip Step 6 entirely |
| Step 6 — repo creation fails | Warn and continue — the commit in Step 7 is the critical action |
| Step 6 — push fails | Warn with manual push instructions; continue |
| Step 7 — commit fails (nothing to commit) | Treat as success — files are already correct |
| Any step — unexpected error | Print the error and current state; do NOT silently swallow failures |

**Do NOT abort the entire bootstrap on GitHub setup failures.** The critical outputs are
CLAUDE.md and AGENTS.md. Git branch setup and remote push are best-effort.

---

## Idempotency Notes

harness-bootstrap is designed to be safe to re-run:

- **CLAUDE.md**: asks before overwriting (Step 4a gate)
- **AGENTS.md**: skips if already exists (Step 5a guard)
- **`git init`**: only runs if `.git` is absent (Step 2b guard)
- **`git remote add`**: skips if `origin` already exists (Step 2c guard)
- **Commit**: gracefully handles "nothing to commit" (Step 7b)
- **`gh repo create`**: If the repo already exists, creation errors — but the error is caught and a warning is printed. The bootstrap continues without GitHub setup. This is error recovery, not true idempotency.

---

## Generated CLAUDE.md Quality Checklist

Before writing CLAUDE.md to disk, verify:

- [ ] Issue prefix is correct: `<ISSUE_PREFIX>-<N>` appears in the Worktree Lifecycle and PR
      Creation sections (not the my-harness `WHI-` prefix if the project uses a different prefix)
- [ ] State flow uses **actual state names** from `list_issue_statuses`, not hardcoded placeholders
- [ ] State references in the Linear Workflow bullets (`<STATE_STARTED>`, `<STATE_REVIEW>`,
      `<STATE_COMPLETED>`) are resolved to actual state names, matching the flow diagram
- [ ] Linear project URL (`<project-url>`) is the verbatim URL from `get_project`, not a derived slug
- [ ] Build commands are concrete (not `<your build command>`) for known stacks (`node`, `python`, `go`, `rust`)
- [ ] Project description in the Project Overview section is non-empty and informative
- [ ] Schema reference at the bottom points to `~/.claude/skills/harness-dev/schema.md`
- [ ] No `<placeholder>` tokens remain in the final output (except intentional TODO comments)
- [ ] Code blocks in Build & Development Commands use real triple backticks (no backslash escapes)

If any item fails, fix it before writing. For the "Other" stack, placeholder build commands are
acceptable — add a clear TODO comment so the user knows to fill them in.

---

## Scope Boundary

This skill **only**:
- Reads a Linear project and team configuration
- Detects the repo state and tech stack
- Generates CLAUDE.md (from the my-harness template with project-specific substitutions)
- Generates AGENTS.md (minimal Codex compatibility pointer)
- Sets up `main` + `dev` git branches if they don't exist
- Optionally creates a private GitHub repo and pushes `main` + `dev`
- Commits CLAUDE.md and AGENTS.md to `dev`

This skill **does NOT**:
- Create Linear issues or milestones — that is `/harness-design`'s job
- Install harness skills — skills are user-level (`~/.claude/skills/`), not project-level
- Generate project code, tests, or implementation files
- Handle monorepo scenarios — one CLAUDE.md per repo root, one invocation per repo
- Run `/harness-dev` — bootstrapping and development are separate concerns
- Configure Linear webhooks, integrations, or team settings
- Modify existing Linear issues or project state
