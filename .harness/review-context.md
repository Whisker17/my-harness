# Review Context — WHI-100: Build harness-bootstrap SKILL.md

## Implementation Summary

Implemented the full `harness-bootstrap` SKILL.md at two locations:
- **User-level**: `~/.claude/skills/harness-bootstrap/SKILL.md` (where Claude Code loads skills from)
- **Repo-tracked**: `skills/harness-bootstrap/SKILL.md` (canonical source in the my-harness repo)

The skill encodes a 7-step one-shot bootstrapping workflow for new projects. It reads a Linear
project, detects the repo state and tech stack, generates a project-specific CLAUDE.md from the
my-harness template skeleton, creates AGENTS.md for Codex compatibility, optionally sets up a
private GitHub repo, and commits the generated files.

Key design decisions:
- **Idempotent by design**: all steps have guards (overwrite prompt for CLAUDE.md, skip if AGENTS.md
  exists, skip git init if .git present, graceful "nothing to commit" handling)
- **State names, not IDs**: the skill queries `list_issue_statuses` at runtime and embeds state
  NAMES (not IDs) in the generated CLAUDE.md, matching the design doc requirement
- **PR Workflow section is part of the template**: the generated CLAUDE.md includes the full PR
  creation format, review flow, and merge strategy from day one, per the issue spec
- **Fail-safe GitHub setup**: GitHub repo creation/push failures warn but don't abort — CLAUDE.md
  and AGENTS.md are the critical outputs
- **Template fidelity**: the static skeleton in the SKILL.md is derived directly from the
  my-harness CLAUDE.md (108 lines), preserving all sections verbatim

## Files Changed

- `skills/harness-bootstrap/SKILL.md` — new file, 776 lines, complete SKILL.md
- `~/.claude/skills/harness-bootstrap/SKILL.md` — updated from stub (17 lines) to full implementation

## Adversarial Review Findings

### Addressed (Critical/High)

None found — no adversarial review run yet (this context file is pre-review).

### Remaining (Medium/Low — not auto-fixed)

To be populated after adversarial review runs.

## PR

https://github.com/Whisker17/my-harness/pull/5

## Acceptance Criteria Status

- [x] `~/.claude/skills/harness-bootstrap/SKILL.md` contains complete workflow instructions
- [x] YAML frontmatter with name, version, description, allowed-tools (including Linear MCP tools)
- [x] **Step 1 - Project detection:** Reads Linear project details (team, issues, milestones) via MCP — Steps 1a through 1e
- [x] **Step 2 - Repo detection:** Checks if `.git` exists; handles new/existing repo; processes remote URL — Steps 2a, 2b, 2c
- [x] **Step 3 - Tech stack detection:** Checks for package.json/pyproject.toml/go.mod/Cargo.toml; asks user via AskUserQuestion for "Other"; generates minimal CLAUDE.md placeholder for "Other" stack — Step 3
- [x] **Step 4 - CLAUDE.md generation:** All required sections present — Project Overview, Git Workflow, PR Workflow, Linear Workflow (state NAMES from MCP), Task Transition, Build Commands, Architecture, Active Issues — Step 4
- [x] **Step 5 - AGENTS.md generation:** Creates AGENTS.md linking to CLAUDE.md — Step 5
- [x] **Step 6 - GitHub setup:** Creates private GitHub repo via `gh repo create --private`, pushes main + dev, sets main as default — Step 6
- [x] **Step 7 - Commit:** Commits CLAUDE.md and AGENTS.md to dev branch — Step 7
- [x] Template base is the my-harness CLAUDE.md generic skeleton (git workflow, PR workflow, Linear workflow, worktree lifecycle, task transition) — Section 4f
- [x] Project-specific sections appended based on detected stack and Linear project data — Steps 4c, 4d, 4e
- [x] Commit message format `<type>(WHI-<N>): <description>` is documented in generated CLAUDE.md — Worktree Lifecycle section of the template
