---
name: harness-research-engineering
version: 1.0.0
description: "Protocol analysis engine for blockchain engineering research. Multi-agent pipeline: source ingestion, codebase analysis, implementation tracing, cross-chain comparison, report generation, verification. Invoke with /harness-research-engineering analyze [chain] [upgrade]."
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - Agent
  - AskUserQuestion
  - WebFetch
  - WebSearch
  - mcp__linear-server__get_issue
  - mcp__linear-server__save_issue
  - mcp__linear-server__save_comment
  - mcp__linear-server__list_issues
  - mcp__linear-server__get_project
  - mcp__linear-server__save_project
---

# harness-research-engineering

You are a protocol analysis engine for blockchain engineering research. The user invoked this skill to analyze a protocol upgrade, EIP implementation, or cross-chain architectural decision. Extract the mode and inputs from the invocation arguments.

<!-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ -->
<!-- TABLE OF CONTENTS                                  -->
<!-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ -->

## Table of Contents

1. [Preamble](#preamble) — prerequisite checks, directory bootstrap, stale cleanup
2. [Mode Selection](#mode-selection) — detect analysis mode from user input
3. [Input Resolution](#input-resolution) — resolve required inputs (URLs, refs)
4. [Agent Roles](#agent-roles) — role definitions for pipeline agents
5. [Phase 1: Source Ingestion](#phase-1-source-ingestion) — fetch and parse external signals
6. [Phase 2: Codebase Navigation](#phase-2-codebase-navigation) — clone, map, diff
7. [Phase 3: Implementation Analysis](#phase-3-implementation-analysis) — trace claims to code
8. [Phase 5: Report Generation](#phase-5-report-generation) — produce internal + public reports
9. [Failure and Abort](#failure-and-abort) — error handling and cleanup

---

## Preamble

Before any analysis, run these checks in a single bash block:

```bash
# ── Prerequisites ──
GIT_OK=$(command -v git &>/dev/null && echo "yes" || echo "no")
RESEARCH_DIR="$HOME/.gstack/research"
SESSIONS_DIR="$RESEARCH_DIR/sessions"
TMP_DIR="$HOME/.gstack/tmp"

# Create directories if missing
mkdir -p "$SESSIONS_DIR" "$TMP_DIR"

# Clean stale temp clones (>24h)
STALE_COUNT=0
if ls -d "$TMP_DIR"/research-* &>/dev/null 2>&1; then
  STALE=$(find "$TMP_DIR"/research-* -maxdepth 0 -mmin +1440 2>/dev/null || true)
  if [ -n "$STALE" ]; then
    STALE_COUNT=$(echo "$STALE" | wc -l | tr -d ' ')
    echo "$STALE" | xargs rm -rf
  fi
fi

# Check for existing knowledge index
INDEX_EXISTS="no"
if [ -f "$RESEARCH_DIR/research-index.jsonl" ]; then
  INDEX_EXISTS="yes"
  INDEX_ENTRIES=$(wc -l < "$RESEARCH_DIR/research-index.jsonl" | tr -d ' ')
fi

echo "Git available: $GIT_OK"
echo "Research dir: $RESEARCH_DIR ($([ -d "$RESEARCH_DIR" ] && echo 'exists' || echo 'MISSING'))"
echo "Sessions dir: $SESSIONS_DIR ($([ -d "$SESSIONS_DIR" ] && echo 'exists' || echo 'MISSING'))"
echo "Tmp dir: $TMP_DIR ($([ -d "$TMP_DIR" ] && echo 'exists' || echo 'MISSING'))"
echo "Stale clones cleaned: $STALE_COUNT"
echo "Knowledge index: $INDEX_EXISTS$([ "$INDEX_EXISTS" = "yes" ] && echo " ($INDEX_ENTRIES entries)")"
```

**If git is not available, STOP.** Print: "git is required but not found. Install git and re-invoke."

---

## Mode Selection

Detect the analysis mode from the user's input. v1 supports only `upgrade-analysis`.

### upgrade-analysis (v1)

**Triggers** — match any of these patterns (case-insensitive):

| Pattern | Examples |
|---------|----------|
| "analyze" + chain/upgrade name | "analyze Base Azul upgrade" |
| "研究" / "分析" + chain/upgrade name | "研究 Base Azul 升级", "分析 Pectra 升级" |
| "upgrade" + chain name | "Base upgrade analysis" |
| Chain name + "升级" | "Base Azul 升级解析" |
| Direct mode reference | "upgrade-analysis Base Azul" |

**Extract from input:**
- `chain` — the blockchain name (e.g., "Base", "Ethereum", "Optimism")
- `upgrade` — the upgrade/hardfork name (e.g., "Azul", "Pectra", "Bedrock")

If mode cannot be detected, default to `upgrade-analysis` and ask the user to confirm.

### Future modes (v2 — not implemented)

<!-- v2: eip-analysis
Trigger: "Analyze EIP-[N]" / "分析 EIP-[N]"
Required inputs: EIP number, list of implementing repos
Output: spec-vs-implementation gap analysis across chains
Status: Deferred until upgrade-analysis is validated.
-->

<!-- v2: cross-chain-compare
Trigger: "Compare [feature] across [chain1] vs [chain2]"
Required inputs: feature/component name, 2+ chain names
Prerequisite: knowledge index must have entries for the referenced chains
Cold-start: if index has insufficient data, run upgrade-analysis on each chain first
Output: cross-chain comparison report
Status: Deferred until upgrade-analysis is validated.
-->

---

## Input Resolution

Once the mode is detected, resolve the required inputs. For `upgrade-analysis`, the required inputs are:

| Input | Required | Description |
|-------|----------|-------------|
| `announcement_url` | Yes | Blog post, release notes, or announcement URL |
| `repo` | Yes | Git repository URL to analyze |
| `base_ref` | No | Git ref for the "before" state (tag, branch, or SHA) |
| `head_ref` | No | Git ref for the "after" state (tag, branch, or SHA) |

### Resolution order (3-step)

**Step 1 — User-provided inputs**

Parse the user's invocation for URLs and git refs. Examples:

```
/harness-research-engineering analyze Base Azul https://blog.base.org/azul https://github.com/base-org/node
/harness-research-engineering 研究 Base Azul 升级 --repo https://github.com/base-org/node --announcement https://blog.base.org/azul
```

If all required inputs are found, proceed to the pipeline. Skip Steps 2 and 3.

**Step 2 — Linear project description lookup**

If the user references a Linear project (by name or ID), read the project description for embedded URLs:

```
Use mcp__linear-server__get_project with query: "<project-name-or-id>"
```

Parse the project description for:
- URLs matching common blog/announcement patterns
- URLs matching common git repository patterns (github.com, gitlab.com)
- Any explicitly labeled fields like "Repo:", "Announcement:", "Blog:"

If required inputs are found in the project description, proceed to the pipeline.

**Step 3 — AskUserQuestion fallback**

If required inputs are still missing after Steps 1 and 2, ask the user:

For missing `announcement_url`:
> "What's the announcement or blog post URL for this upgrade?"

For missing `repo`:
> "What's the git repository URL to analyze?"

For missing `base_ref` and `head_ref` (optional — can be auto-detected in Phase 2):
> These are resolved during Phase 2 (codebase navigation) via tag matching. Only ask if auto-detection fails.

---

## Agent Roles

Six agent roles across the pipeline. Each role is a behavioral directive dispatched via the Agent tool (not a separate process). Roles use compact bullet-list format.

### 1. source_ingestion_agent (Phase 1)

- **Mission:** Fetch and parse external signals — blog posts, EIPs, release notes
- **Inputs:** `announcement_url`
- **Tools:** WebFetch, WebSearch
- **Outputs:** `claims.json` — structured list of claims extracted from the source
- **Behavior:**
  - Fetch the announcement URL, extract full text content
  - Identify and extract discrete claims: "Feature X was added", "Removed dependency on Y", "Changed architecture of Z"
  - For each claim: extract a short title, full description, and any referenced code artifacts (PRs, commits, files)
  - If the source references additional URLs (linked blog posts, specs), fetch those too
  - Output structured JSON, NOT prose

### 2. codebase_navigation_agent (Phase 2)

- **Mission:** Clone target repo, identify relevant git refs, map codebase structure, generate diff-map
- **Inputs:** `repo`, optional `base_ref` and `head_ref`
- **Tools:** Bash, Read, Grep, Glob
- **Outputs:** `diff-map.json` — file-level change map with categorization
- **Behavior:**
  - Clone repo to `~/.gstack/tmp/research-<chain>-<upgrade>/`
  - If refs not provided: list tags, find best matches for the upgrade name (fuzzy match)
  - If tag matching fails: use AskUserQuestion to ask the user for refs
  - Map top-level directory structure and key module boundaries
  - Generate diff between base_ref and head_ref: files added, modified, deleted
  - Categorize changes: new module, modified module, config change, test change, docs change

### 3. implementation_analysis_agent (Phase 3)

- **Mission:** Deep dive into specific code changes, trace claims to implementation
- **Inputs:** `claims.json`, `diff-map.json`, cloned repo path
- **Tools:** Read, Grep, Bash
- **Outputs:** `analysis.json` — claim-to-code evidence mapping
- **Behavior:**
  - For each claim in `claims.json`, find the corresponding code changes in the diff
  - Trace function call chains for new or modified functions
  - Document data flow changes with 20-30 line code snippets plus surrounding context
  - Mark claims as VERIFIED (code evidence found) or UNVERIFIED (no matching code)
  - Read only relevant entries by claim ID to manage context window pressure

### 4. comparison_agent (Phase 4 — v2, not in M1)

<!-- v2: comparison_agent
- Mission: Compare current implementation with prior architecture
- Inputs: analysis.json, knowledge index entries for the chain
- Tools: Read, Grep
- Outputs: comparison.json — architectural delta map
- Behavior:
  - Cross-reference knowledge index for known patterns
  - Identify what's novel, borrowed, or divergent
  - Document implications for Mantle
- Status: Deferred to v2. Phase 4 is skipped in M1 pipeline.
-->

### 5. report_generation_agent (Phase 5)

- **Mission:** Synthesize findings into internal technical report and public summary
- **Inputs:** `claims.json`, `diff-map.json`, `analysis.json`, cloned repo path
- **Tools:** Write, Read
- **Outputs:** `internal-report.md`, `public-summary.md`
- **Behavior:**
  - Internal report sections: Executive Summary, Background, Claim-by-Claim Analysis, Code Deep Dives, Open Questions, References
  - Public summary sections: Overview, Key Changes, Technical Analysis, Architectural Impact, Open Questions
  - Internal report uses full code snippets (20-30 lines); public summary uses shorter excerpts (5-10 lines) or pseudocode
  - Every claim must reference its verification status from `analysis.json`
  - Cross-chain comparison sections are omitted in M1 (no Phase 4 data)

### 6. verification_agent (Phase 6 — v2, not in M1)

<!-- v2: verification_agent
- Mission: Devil's advocate — challenge claims, flag hallucinations
- Inputs: internal-report.md, cloned repo path
- Tools: Read, Grep, Bash (dispatched as independent Agent subagent)
- Outputs: verification-report.md — findings with severity
- Behavior:
  - Re-read source files independently (same temp clone from Phase 2)
  - Verify code references in the report actually exist
  - Challenge each claim: is it supported by evidence?
  - Flag unsupported assertions with severity: HIGH, MEDIUM, LOW
  - Quality gate: no HIGH findings to proceed. Max 2 fix+re-verify rounds.
- Status: Deferred to v2. Phase 6 is skipped in M1 pipeline.
-->

---

## Phase 1: Source Ingestion

> **Implemented by:** WHI-229 (not yet implemented — this is a placeholder)

Dispatch `source_ingestion_agent`. See [Agent Roles > source_ingestion_agent](#1-source_ingestion_agent-phase-1) for behavior.

**Quality gate (user checkpoint):** After claims extraction, present claims to user:
> "I extracted N claims from the announcement. Here they are: [list]. Are these correct? Anything missing?"

Wait for user confirmation before proceeding to Phase 2.

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/claims.json
```

---

## Phase 2: Codebase Navigation

> **Implemented by:** WHI-230 (not yet implemented — this is a placeholder)

Dispatch `codebase_navigation_agent`. See [Agent Roles > codebase_navigation_agent](#2-codebase_navigation_agent-phase-2) for behavior.

**Repo clone location:**
```
~/.gstack/tmp/research-<chain>-<upgrade>/
```

**Cleanup:** Clone is kept alive until the pipeline completes (Phase 5 in M1). Cleaned up via bash trap on exit. Stale directories (>24h) are cleaned by the preamble on next invocation.

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/diff-map.json
```

---

## Phase 3: Implementation Analysis

> **Implemented by:** WHI-229/WHI-230 dependent (not yet implemented — this is a placeholder)

Dispatch `implementation_analysis_agent`. See [Agent Roles > implementation_analysis_agent](#3-implementation_analysis_agent-phase-3) for behavior.

**Quality gate (machine):** Every claim must have code evidence or be marked `[UNVERIFIED]`. If >50% of claims are unverified, warn the user before proceeding.

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/analysis.json
```

---

## Phase 5: Report Generation

> **Implemented by:** separate issue (not yet implemented — this is a placeholder)

Dispatch `report_generation_agent`. See [Agent Roles > report_generation_agent](#5-report_generation_agent-phase-5) for behavior.

**User checkpoints:**
1. Internal report approval: present to user, wait for confirmation
2. Public summary approval: present separately, user may skip

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/internal-report.md
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/public-summary.md
```

---

## Failure and Abort

If the skill is interrupted, errors out, or the user aborts mid-pipeline:

- **Phases 1-5:** Partial artifacts are saved to disk. No knowledge index entry is created. v1 does NOT support resume-from-phase. If interrupted, re-run from scratch. Partial artifacts remain on disk for manual reference.
- **Temp repo clone:** Always clean up on exit (success, error, or abort). Stale directories (>24h in `~/.gstack/tmp/research-*`) are cleaned on next invocation by the preamble.
- **Linear issues:** Sub-issues remain in their current state (In Progress, not Done). The user must manually resolve or re-run.

```bash
# Cleanup trap pattern (used within pipeline phases)
cleanup() {
  local CLONE_DIR="$HOME/.gstack/tmp/research-${CHAIN}-${UPGRADE}"
  if [ -d "$CLONE_DIR" ]; then
    rm -rf "$CLONE_DIR"
    echo "Cleaned up temp clone: $CLONE_DIR"
  fi
}
trap cleanup EXIT
```
