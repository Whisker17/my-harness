# My Harness

A suite of Claude Code skills that automate the full software development lifecycle — from idea to deployed code — using Linear for project management and GitHub for code review.

## What It Does

My Harness turns Linear issues into merged pull requests with a single command. It orchestrates the entire dev loop: design, project bootstrap, implementation, adversarial code review, and final approval.

```
Idea  ──►  /harness-design  ──►  Linear project + issues
Repo  ──►  /harness-bootstrap  ──►  CLAUDE.md + git + GitHub
Issue ──►  /harness-dev WHI-N  ──►  Worktree + code + PR + review
PR    ──►  /harness-review WHI-N  ──►  Approve + merge (or reject)
```

## Skills

| Skill | Command | Purpose |
|-------|---------|---------|
| **harness-design** | `/harness-design` | Transforms an idea into a Linear project with milestones, phases, and schema-conforming issues |
| **harness-bootstrap** | `/harness-bootstrap <project>` | One-shot project setup: generates CLAUDE.md, AGENTS.md, initializes git branches, optionally creates a GitHub repo |
| **harness-dev** | `/harness-dev WHI-123` | Implements a single Linear issue through the full dev loop: quality gate, worktree, implementation, PR creation, adversarial review |
| **harness-review** | `/harness-review WHI-123` | Opus-level final review: validates acceptance criteria against the diff, merges on approval or posts feedback |

## Quick Start

### Prerequisites

- [Claude Code](https://claude.ai/code) installed
- [Linear MCP server](https://github.com/linear/linear-mcp) configured in Claude Code
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- A Linear workspace with a team configured

### Installation

```bash
# Clone the repo
git clone https://github.com/Whisker17/my-harness.git
cd my-harness

# Run the setup script
./setup.sh
```

The setup script will:
1. Check prerequisites (Claude Code, GitHub CLI, Linear MCP)
2. Install all four harness skills to `~/.claude/skills/`
3. Check external skill dependencies and report what's missing
4. Initialize `~/.gstack/` directory and config

After setup, the skills are available as slash commands in any Claude Code session.

<details>
<summary>Manual installation (alternative)</summary>

```bash
# Copy skills to Claude Code's skill directory
cp -r skills/harness-dev ~/.claude/skills/
cp -r skills/harness-review ~/.claude/skills/
cp -r skills/harness-design ~/.claude/skills/
cp -r skills/harness-bootstrap ~/.claude/skills/

# Copy the shared schema (required by harness-dev)
cp skills/harness-dev/schema.md ~/.claude/skills/harness-dev/schema.md

# Create gstack directories
mkdir -p ~/.gstack/projects
echo '{"review_mode": "adversarial-review"}' > ~/.gstack/config.json
```

</details>

### Usage

**New project from scratch:**

```bash
# 1. Design — interactive session that produces a Linear project
/harness-design

# 2. Bootstrap — generates CLAUDE.md + git setup
mkdir my-project && cd my-project
/harness-bootstrap my-project

# 3. Develop — one command per issue
/harness-dev PRJ-1

# 4. Review — Opus-level final approval
/harness-review PRJ-1
```

**Existing project, pick up an issue:**

```bash
cd my-project
/harness-dev WHI-42
```

## Architecture

### Workflow

```
                 ┌─────────────────────────────────────────────┐
                 │              /harness-design                 │
                 │  office-hours → eng-review → Linear issues   │
                 └──────────────────┬──────────────────────────┘
                                    │
                 ┌──────────────────▼──────────────────────────┐
                 │            /harness-bootstrap                │
                 │  Linear project → CLAUDE.md + AGENTS.md      │
                 │  + git init + GitHub repo                    │
                 └──────────────────┬──────────────────────────┘
                                    │
          ┌─────────────────────────▼─────────────────────────┐
          │                  /harness-dev                       │
          │  1. Quality gate (validate issue schema)            │
          │  2. Create worktree + branch from dev               │
          │  3. Implement the issue                             │
          │  4. Push + create PR against dev                    │
          │  5. Run /adversarial-review on the PR               │
          │  6. Update Linear (In Progress → In Review)         │
          └─────────────────────────┬─────────────────────────┘
                                    │
          ┌─────────────────────────▼─────────────────────────┐
          │                /harness-review                      │
          │  1. Read PR diff + acceptance criteria              │
          │  2. Verify each criterion against the code          │
          │  3. Approve → merge PR + cleanup + Done             │
          │     OR reject → post feedback + keep In Review      │
          └───────────────────────────────────────────────────┘
```

### Issue Schema

Every Linear issue must contain five sections to pass the quality gate:

1. **Context** — Why this issue exists
2. **Acceptance Criteria** — Checkboxes defining "done"
3. **Architecture Notes** — Technical approach and constraints
4. **Dependencies** — What blocks this and what this blocks
5. **Scope Boundary** — What is explicitly NOT in scope

The schema is defined in [`~/.claude/skills/harness-dev/schema.md`](skills/harness-dev/schema.md) and enforced by harness-dev's quality gate.

### Git Workflow

- **`main`** — release/deploy only
- **`dev`** — primary development branch
- Feature branches via worktrees: `.worktrees/<name>` branched from `dev`
- Branch naming: `<type>/WHI-<N>-<short-desc>` (e.g., `feat/WHI-42-user-auth`)
- PR merge strategy: **merge commit** (no squash, no rebase)
- Every feature branch merges to `dev` via GitHub PR

### Linear Integration

State transitions are automated:

```
Backlog ──► Todo ──► In Progress ──► In Review ──► Done
                     (harness-dev)   (harness-dev)  (harness-review)
```

## External Dependencies

The harness skills depend on a few external tools and skills. The `setup.sh` script checks all of these automatically.

### Required (core workflow)

| Dependency | Used By | Purpose |
|------------|---------|---------|
| [Claude Code](https://claude.ai/code) | All skills | Runtime environment |
| [GitHub CLI](https://cli.github.com/) (`gh`) | harness-dev, harness-review | PR creation, merge, CI checks |
| [Linear MCP server](https://github.com/linear/linear-mcp) | All skills | Issue management, state transitions |
| [adversarial-review](https://github.com/anthropics/claude-code-plugins) plugin | harness-dev | Adversarial code review (falls back to Agent-based review if missing) |

### Optional (design workflow only)

These are only needed if you use `/harness-design` to create new projects from scratch. The core dev/review loop (`/harness-dev` + `/harness-review`) works without them.

| Dependency | Used By | Purpose |
|------------|---------|---------|
| `office-hours` skill | harness-design | Interactive requirements gathering |
| `plan-eng-review` skill | harness-design | Engineering review of design docs |
| `gstack-slug` binary | harness-design | Project slug generation |
| `~/.gstack/` directory | harness-design, harness-bootstrap | Design doc storage and project config |

## Repository Structure

```
my-harness/
├── CLAUDE.md                              # Project conventions for Claude Code
├── README.md                              # This file
├── setup.sh                               # Interactive setup script
├── skills/
│   ├── harness-dev/
│   │   └── SKILL.md                       # Dev loop skill (449 lines)
│   ├── harness-review/
│   │   └── SKILL.md                       # Final review skill (481 lines)
│   ├── harness-design/
│   │   └── SKILL.md                       # Design pipeline skill (644 lines)
│   └── harness-bootstrap/
│       └── SKILL.md                       # Project bootstrap skill (839 lines)
└── references/
    └── *.md                               # Design docs from /harness-design
```

## License

Private project. Not licensed for redistribution.
