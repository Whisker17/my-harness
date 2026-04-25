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
5. [Artifact Schemas](#artifact-schemas) — JSON schemas for intermediate artifacts and validation gates
6. [Phase 1: Source Ingestion](#phase-1-source-ingestion) — fallback chain fetch, claims extraction, source snapshot, user checkpoint
7. [Phase 2: Codebase Navigation](#phase-2-codebase-navigation) — clone, map, diff
8. [Phase 3: Implementation Analysis](#phase-3-implementation-analysis) — trace claims to code
9. [Phase 5: Report Generation](#phase-5-report-generation) — produce internal + public reports
10. [Failure and Abort](#failure-and-abort) — error handling and cleanup

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
- **Tools:** WebFetch, WebSearch, AskUserQuestion
- **Outputs:** `claims.json` — structured list of claims extracted from the source; `source-snapshot.md` — reproducible snapshot of raw fetched content
- **Behavior:**
  - Fetch source using 3-tier fallback chain: WebFetch → WebSearch → AskUserQuestion (D10)
  - Save raw fetched content as `source-snapshot.md` with YAML frontmatter before processing (D13)
  - Identify and extract discrete claims: "Feature X was added", "Removed dependency on Y", "Changed architecture of Z"
  - For each claim: extract id, text, source_section, category, confidence, and any referenced code artifacts (PRs, commits, files)
  - If claims exceed 15, re-extract in chunks of 5-8 claims per section and deduplicate (D1)
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

## Artifact Schemas

All intermediate artifacts are JSON files stored in the session directory (`~/.gstack/research/sessions/<chain>-<upgrade>-<date>/`). Each artifact has a defined schema that serves as both documentation and a runtime validation contract. Every schema includes a `schema_version` field for future migration support.

### Validation Gate — General Rules

Before each phase begins processing, validate the input artifact(s) from the previous phase:

1. **Parse check:** The file must be valid JSON (parseable without errors)
2. **Required fields:** All required fields listed in the schema must be present and non-null
3. **Non-empty arrays:** Array fields marked as "non-empty" must contain at least one element
4. **Type check:** Field values must match the expected type (string, number, array, object)

**Validation failure behavior:**

If validation fails at any phase boundary:

1. **Abort** the current phase immediately — do NOT proceed with partial/malformed input
2. **Save partial artifacts** to disk (whatever has been produced so far stays in the session directory)
3. **Print a clear error message** naming the specific failure:
   ```
   ❌ Validation failed: <artifact>.json
      Field: <field_name>
      Error: <missing | null | empty array | wrong type (expected <type>, got <type>)>
      Phase <N> aborted. Fix the artifact and re-run.
   ```
4. If multiple fields fail validation, report ALL failures (not just the first one)

### claims.json

**Produced by:** Phase 1 (Source Ingestion)
**Consumed by:** Phase 3 (Implementation Analysis), Phase 5 (Report Generation)

```json
{
  "schema_version": 1,
  "source_url": "https://blog.example.com/upgrade-announcement",
  "source_snapshot_path": "source-snapshot.md",
  "fetched_at": "2026-04-25T11:00:00Z",
  "claims": [
    {
      "id": "claim-001",
      "text": "Added independent derivation pipeline replacing OP Stack dependency",
      "source_section": "Architecture Changes",
      "category": "architecture",
      "confidence": "high",
      "referenced_artifacts": ["PR #1234", "commit abc123"]
    }
  ]
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `source_url` | string | ✅ | The announcement/blog URL that was fetched |
| `source_snapshot_path` | string | ✅ | Relative path (within session dir) to saved raw source content for reproducibility (per D13) |
| `fetched_at` | string (ISO 8601) | ✅ | Timestamp when the source was fetched |
| `claims` | array (non-empty) | ✅ | Extracted claims from the source |
| `claims[].id` | string | ✅ | Unique claim identifier (format: `claim-NNN`) |
| `claims[].text` | string | ✅ | The claim statement — what the source asserts |
| `claims[].source_section` | string | ✅ | Which section/heading of the source this claim was extracted from |
| `claims[].category` | string | ✅ | One of: `architecture`, `performance`, `security`, `governance`, `tooling`, `deprecation`, `other` |
| `claims[].confidence` | string | ✅ | Extraction confidence: `high` (explicit statement), `medium` (inferred), `low` (ambiguous) |
| `claims[].referenced_artifacts` | array | ❌ | PRs, commits, files, or specs mentioned alongside this claim |

**Phase boundary validation (before Phase 3):**
- `schema_version` must equal `1`
- `source_url` must be a non-empty string
- `source_snapshot_path` must be a non-empty string
- `claims` array must be non-empty
- Each claim must have non-null `id`, `text`, `source_section`, `category`, `confidence`
- `category` must be one of the allowed values
- `confidence` must be one of: `high`, `medium`, `low`

### diff-map.json

**Produced by:** Phase 2 (Codebase Navigation)
**Consumed by:** Phase 3 (Implementation Analysis), Phase 5 (Report Generation)

```json
{
  "schema_version": 1,
  "repo": "https://github.com/base-org/base-node",
  "base_sha": "a1b2c3d4e5f6...",
  "head_sha": "f6e5d4c3b2a1...",
  "base_ref": "v1.0.0",
  "head_ref": "v2.0.0-azul",
  "generated_at": "2026-04-25T11:30:00Z",
  "clone_path": "/Users/user/.gstack/tmp/research-base-azul/",
  "files": [
    {
      "path": "pkg/derivation/pipeline.go",
      "status": "modified",
      "category": "core",
      "lines_changed": 142,
      "lines_added": 98,
      "lines_deleted": 44
    },
    {
      "path": "pkg/governance/module.go",
      "status": "added",
      "category": "new_module",
      "lines_changed": 350,
      "lines_added": 350,
      "lines_deleted": 0
    }
  ],
  "summary": {
    "total_files": 47,
    "added": 12,
    "modified": 30,
    "deleted": 5,
    "total_lines_changed": 4200
  }
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `repo` | string | ✅ | Repository URL |
| `base_sha` | string | ✅ | Full SHA of the base commit |
| `head_sha` | string | ✅ | Full SHA of the head commit |
| `base_ref` | string | ✅ | Human-readable base ref (tag/branch name) |
| `head_ref` | string | ✅ | Human-readable head ref (tag/branch name) |
| `generated_at` | string (ISO 8601) | ✅ | Timestamp when the diff-map was generated |
| `clone_path` | string | ✅ | Absolute path to the local repo clone |
| `files` | array (non-empty) | ✅ | Per-file change details |
| `files[].path` | string | ✅ | File path relative to repo root |
| `files[].status` | string | ✅ | One of: `added`, `modified`, `deleted`, `renamed` |
| `files[].category` | string | ✅ | One of: `core`, `new_module`, `config`, `test`, `docs`, `dependency`, `other` |
| `files[].lines_changed` | number | ✅ | Total lines changed (added + deleted) |
| `files[].lines_added` | number | ✅ | Lines added |
| `files[].lines_deleted` | number | ✅ | Lines deleted |
| `summary` | object | ✅ | Aggregate statistics |
| `summary.total_files` | number | ✅ | Total files in the diff |
| `summary.added` | number | ✅ | Files added |
| `summary.modified` | number | ✅ | Files modified |
| `summary.deleted` | number | ✅ | Files deleted |
| `summary.total_lines_changed` | number | ✅ | Total lines changed across all files |

**Phase boundary validation (before Phase 3):**
- `schema_version` must equal `1`
- `repo`, `base_sha`, `head_sha` must be non-empty strings
- `files` array must be non-empty
- Each file must have non-null `path`, `status`, `category`, `lines_changed`
- `status` must be one of the allowed values
- `category` must be one of the allowed values
- `summary` must be present with all required sub-fields

### analysis.json

**Produced by:** Phase 3 (Implementation Analysis)
**Consumed by:** Phase 4 (Cross-Reference, v2 only), Phase 5 (Report Generation)

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-25T12:00:00Z",
  "claims_analyzed": [
    {
      "claim_id": "claim-001",
      "verification_status": "verified",
      "evidence": [
        {
          "file": "pkg/derivation/pipeline.go",
          "lines": "45-78",
          "description": "New DerivationPipeline struct replaces OPStackDeriver",
          "relevance": "high"
        }
      ],
      "code_snippets": [
        {
          "file": "pkg/derivation/pipeline.go",
          "start_line": 45,
          "end_line": 78,
          "content": "// ... code content ...",
          "annotation": "New pipeline struct implementing independent derivation"
        }
      ],
      "analysis_notes": "The implementation fully replaces the OP Stack dependency with a custom pipeline."
    }
  ],
  "unreported_changes": [
    {
      "file": "pkg/sequencer/batch.go",
      "status": "modified",
      "lines_changed": 85,
      "description": "Batch compression algorithm changed from zlib to zstd",
      "significance": "medium",
      "potential_category": "performance"
    }
  ],
  "summary": {
    "total_claims": 12,
    "verified": 10,
    "unverified": 2,
    "unreported_change_count": 3
  }
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `generated_at` | string (ISO 8601) | ✅ | Timestamp when analysis was completed |
| `claims_analyzed` | array (non-empty) | ✅ | Per-claim evidence mapping |
| `claims_analyzed[].claim_id` | string | ✅ | References `claims[].id` from claims.json |
| `claims_analyzed[].verification_status` | string | ✅ | One of: `verified`, `unverified`, `partially_verified` |
| `claims_analyzed[].evidence` | array | ✅ | Code evidence supporting or refuting the claim (empty array if unverified) |
| `claims_analyzed[].evidence[].file` | string | ✅ | File path relative to repo root |
| `claims_analyzed[].evidence[].lines` | string | ✅ | Line range (e.g., "45-78") |
| `claims_analyzed[].evidence[].description` | string | ✅ | What this evidence shows |
| `claims_analyzed[].evidence[].relevance` | string | ✅ | One of: `high`, `medium`, `low` |
| `claims_analyzed[].code_snippets` | array | ❌ | Extended code excerpts (20-30 lines) for the report |
| `claims_analyzed[].code_snippets[].file` | string | ✅ | File path |
| `claims_analyzed[].code_snippets[].start_line` | number | ✅ | Starting line number |
| `claims_analyzed[].code_snippets[].end_line` | number | ✅ | Ending line number |
| `claims_analyzed[].code_snippets[].content` | string | ✅ | The code content |
| `claims_analyzed[].code_snippets[].annotation` | string | ✅ | Explanation of what the snippet demonstrates |
| `claims_analyzed[].analysis_notes` | string | ❌ | Free-form notes from the analysis agent |
| `unreported_changes` | array | ✅ | Code changes NOT tied to any claim — discovered via code-first delta pass (per D12) |
| `unreported_changes[].file` | string | ✅ | File path |
| `unreported_changes[].status` | string | ✅ | One of: `added`, `modified`, `deleted`, `renamed` |
| `unreported_changes[].lines_changed` | number | ✅ | Lines changed |
| `unreported_changes[].description` | string | ✅ | What changed and why it matters |
| `unreported_changes[].significance` | string | ✅ | One of: `high`, `medium`, `low` |
| `unreported_changes[].potential_category` | string | ❌ | Suggested category for reporting |
| `summary` | object | ✅ | Aggregate statistics |
| `summary.total_claims` | number | ✅ | Total claims analyzed |
| `summary.verified` | number | ✅ | Claims with code evidence |
| `summary.unverified` | number | ✅ | Claims without code evidence |
| `summary.unreported_change_count` | number | ✅ | Number of code-first delta findings |

**Phase boundary validation (before Phase 5):**
- `schema_version` must equal `1`
- `claims_analyzed` array must be non-empty
- Each entry must have non-null `claim_id`, `verification_status`, `evidence`
- `verification_status` must be one of the allowed values
- `unreported_changes` must be present (may be empty array — empty is valid, missing is not)
- `summary` must be present with all required sub-fields
- `summary.total_claims` must equal `len(claims_analyzed)`

### comparison.json

**Produced by:** Phase 4 (Cross-Reference Agent — v2 only, skipped in M1)
**Consumed by:** Phase 5 (Report Generation — cross-chain sections)

> **Note:** This schema is defined now for completeness but is only used in M2 when Phase 4 is implemented. In M1, this artifact does not exist and Phase 5 omits cross-chain comparison sections.

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-25T13:00:00Z",
  "baseline": {
    "chain": "base",
    "upgrade": "azul",
    "session_dir": "sessions/base-azul-20260425"
  },
  "comparisons": [
    {
      "chain": "optimism",
      "upgrade": "ecotone",
      "session_dir": "sessions/optimism-ecotone-20260320",
      "index_entry_date": "2026-03-20T09:00:00Z"
    }
  ],
  "novel_features": [
    {
      "name": "Custom governance module",
      "description": "Base-specific governance not present in any compared chain",
      "files": ["pkg/governance/module.go", "pkg/governance/voting.go"],
      "significance": "high"
    }
  ],
  "borrowed_features": [
    {
      "name": "Derivation pipeline pattern",
      "description": "Similar architecture to Optimism's derivation but reimplemented independently",
      "source_chain": "optimism",
      "similarity": "structural",
      "files": ["pkg/derivation/pipeline.go"]
    }
  ],
  "divergent_features": [
    {
      "name": "Batch compression",
      "description": "Base uses zstd while Optimism uses zlib for batch compression",
      "chains_compared": ["base", "optimism"],
      "impact": "Performance trade-off — zstd is faster decompression, slightly larger compressed size"
    }
  ]
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `generated_at` | string (ISO 8601) | ✅ | Timestamp when comparison was completed |
| `baseline` | object | ✅ | The current analysis being compared against others |
| `baseline.chain` | string | ✅ | Chain name |
| `baseline.upgrade` | string | ✅ | Upgrade name |
| `baseline.session_dir` | string | ✅ | Relative path to the session directory |
| `comparisons` | array (non-empty) | ✅ | Prior analyses being compared against |
| `comparisons[].chain` | string | ✅ | Chain name |
| `comparisons[].upgrade` | string | ✅ | Upgrade name |
| `comparisons[].session_dir` | string | ✅ | Session directory of the compared analysis |
| `comparisons[].index_entry_date` | string (ISO 8601) | ✅ | When the compared analysis was indexed |
| `novel_features` | array | ✅ | Features unique to the baseline (may be empty) |
| `novel_features[].name` | string | ✅ | Feature name |
| `novel_features[].description` | string | ✅ | What makes it novel |
| `novel_features[].files` | array | ✅ | Relevant file paths |
| `novel_features[].significance` | string | ✅ | One of: `high`, `medium`, `low` |
| `borrowed_features` | array | ✅ | Features that exist in compared chains (may be empty) |
| `borrowed_features[].name` | string | ✅ | Feature name |
| `borrowed_features[].description` | string | ✅ | How it relates to the source |
| `borrowed_features[].source_chain` | string | ✅ | Which chain it was borrowed from |
| `borrowed_features[].similarity` | string | ✅ | One of: `identical`, `structural`, `conceptual` |
| `borrowed_features[].files` | array | ✅ | Relevant file paths |
| `divergent_features` | array | ✅ | Features that differ between chains (may be empty) |
| `divergent_features[].name` | string | ✅ | Feature name |
| `divergent_features[].description` | string | ✅ | How the implementations diverge |
| `divergent_features[].chains_compared` | array | ✅ | Which chains are being compared |
| `divergent_features[].impact` | string | ✅ | Why the divergence matters |

**Phase boundary validation (before Phase 5, v2 only):**
- `schema_version` must equal `1`
- `baseline` must be present with non-null `chain`, `upgrade`, `session_dir`
- `comparisons` array must be non-empty
- `novel_features`, `borrowed_features`, `divergent_features` must be present (may be empty arrays)

### Per-Phase Validation Summary

| Phase | Validates Before Processing | Artifacts Checked |
|-------|----------------------------|-------------------|
| Phase 1 | _(none — first phase)_ | — |
| Phase 2 | _(none — independent of Phase 1 output)_ | — |
| Phase 3 | claims.json, diff-map.json | Both must pass all validation rules |
| Phase 4 (v2) | analysis.json, knowledge index | analysis.json must pass; index must have ≥1 entry for a different chain |
| Phase 5 | claims.json, diff-map.json, analysis.json (+ comparison.json in v2) | All must pass validation |

---

## Phase 1: Source Ingestion

> **Implemented by:** WHI-229

Phase 1 fetches the announcement source, extracts structured claims, and saves a reproducible snapshot. This is the entry point of the pipeline — all subsequent phases depend on its output.

**Agent role:** `source_ingestion_agent` (see [Agent Roles](#1-source_ingestion_agent-phase-1))

### Step 1.1 — Source Fetching (Fallback Chain — D10)

Fetch the announcement content using a 3-tier fallback chain. Each tier is tried in order; proceed to the next only on failure.

**Tier 1: WebFetch**

```
Use WebFetch with:
  url: <announcement_url>
  prompt: "Extract the full text content of this page. Preserve section headings, bullet points,
           and any technical details. Include all code references, PR numbers, commit hashes,
           and links to specs or EIPs."
```

**Success criteria:** Response is non-empty AND contains at least 200 characters of meaningful content (not just error messages or login prompts).

If WebFetch succeeds → set `fetch_method = "webfetch"` → proceed to Step 1.2.

**Tier 2: WebSearch (fallback)**

If WebFetch returns an error, empty content, or content shorter than 200 characters:

```
Use WebSearch with:
  query: "<chain> <upgrade> upgrade announcement site:<domain-from-url>"
```

If no results from site-scoped search, broaden:

```
Use WebSearch with:
  query: "<chain> <upgrade> upgrade announcement blog post"
```

From the search results, fetch the most relevant result(s) using WebFetch. Combine content if multiple sources provide complementary information.

**Success criteria:** At least one search result is found AND the content fetched from the top result(s) meets the same 200-character meaningful content threshold as Tier 1. **Failure criteria:** No results returned from either search query, OR all fetched results contain only error messages, login prompts, or content shorter than 200 characters.

If WebSearch yields usable content → set `fetch_method = "websearch"` → proceed to Step 1.2.

**Tier 3: User paste (last resort)**

If both WebFetch and WebSearch fail:

```
Use AskUserQuestion:
  question: "I couldn't fetch the announcement at <url> and web search didn't find usable results.
             Could you paste the announcement content here?"
  options:
    - "I'll paste the content" (user pastes raw text)
    - "Try a different URL" (user provides alternate URL → restart from Tier 1)
    - "Skip Phase 1" (abort pipeline)
```

If user provides content → set `fetch_method = "user_paste"` → proceed to Step 1.2.
If user chooses "Try a different URL" → restart from Tier 1 with the new URL. **Limit: 3 alternate URL attempts.** After the third failure, only offer "I'll paste the content" and "Skip Phase 1".
If user chooses "Skip Phase 1" → abort with message: "Phase 1 skipped. Pipeline cannot continue without source content."

### Step 1.2 — Source Snapshot (D13)

Save the fetched content as a reproducible snapshot before any processing.

**File:** `{session_dir}/source-snapshot.md`

**Format:**

```markdown
---
url: <announcement_url>
fetched_at: <ISO 8601 timestamp>
fetch_method: <webfetch | websearch | user_paste>
content_length: <character count of raw content>
---

<raw content as fetched — no modifications>
```

Write this file using the Write tool. The snapshot preserves the exact content used for extraction, ensuring reproducibility regardless of future changes to the source URL.

### Step 1.3 — Claims Extraction

Extract structured claims from the fetched content. Each claim is a discrete, verifiable technical assertion from the announcement.

**Extraction prompt (dispatched via Agent tool):**

```
You are the Source Intelligence Analyst. Your job is to read a protocol upgrade
announcement and extract every concrete technical claim into a structured list.

Source content:
<insert fetched content>

For each claim, extract:
- id: Sequential identifier (claim-001, claim-002, ...)
- text: The specific technical assertion (what the source claims was done/changed)
- source_section: The heading or section where this claim appears
- category: One of: architecture, performance, security, governance, tooling, deprecation, other
- confidence: high (explicit statement), medium (inferred from context), low (ambiguous/vague)
- referenced_artifacts: Any PRs, commits, file paths, specs, or EIPs mentioned alongside this claim (empty array if none)

Rules:
- Extract EVERY concrete technical claim, not just major features
- Split compound claims into individual items (e.g., "Added X and removed Y" → two claims)
- Do NOT include marketing language, opinions, or non-technical statements
- Do NOT infer claims that aren't stated or strongly implied in the source
- Preserve the original technical terminology from the source

Output as a valid JSON array of claim objects. No prose, no commentary — just the JSON array.
```

### Step 1.4 — Chunked Extraction (D1)

If the initial extraction produces more than 15 claims, re-extract using chunked processing to improve quality:

1. **Split the source content** into logical sections (by heading or natural breaks)
2. **Process each chunk** independently with the same extraction prompt, targeting 5-8 claims per chunk
3. **Merge results:** Combine all chunks, then deduplicate:
   - For each pair of claims, if the `text` fields share >80% of key terms (nouns, verbs, technical terms), treat them as duplicates
   - Keep the claim with higher confidence; if tied, keep the one from the earlier chunk
   - Re-number IDs sequentially after deduplication (claim-001, claim-002, ...)

If initial extraction produces ≤15 claims, skip chunking — use the initial results directly.

### Step 1.5 — Build claims.json

Assemble the final `claims.json` artifact following the schema from [Artifact Schemas > claims.json](#claimsjson):

```json
{
  "schema_version": 1,
  "source_url": "<announcement_url>",
  "source_snapshot_path": "source-snapshot.md",
  "fetched_at": "<ISO 8601 timestamp>",
  "claims": [ <extracted claims array> ]
}
```

**Write to:** `{session_dir}/claims.json`

### Step 1.6 — Self-Validation Gate

Before presenting to the user, validate claims.json against the schema. **Note:** This is a pre-output self-validation, not a phase-boundary gate. Unlike the inter-phase validation rules in [Artifact Schemas > Validation Gate](#validation-gate--general-rules) (which abort immediately), Phase 1 self-validation allows one auto-fix attempt because the artifact hasn't been committed yet — the user hasn't seen it, and no downstream phase depends on it at this point.

Validation checks:

1. `schema_version` equals `1`
2. `source_url` is a non-empty string
3. `source_snapshot_path` is a non-empty string
4. `claims` array is non-empty
5. Each claim has non-null `id`, `text`, `source_section`, `category`, `confidence`
6. Each `category` is one of: `architecture`, `performance`, `security`, `governance`, `tooling`, `deprecation`, `other`
7. Each `confidence` is one of: `high`, `medium`, `low`

**On validation failure:**

```
❌ Validation failed: claims.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type | invalid enum value>
   Phase 1 self-validation failed. Attempting auto-fix...
```

Auto-fix attempt: Re-run the extraction prompt with the specific validation errors appended as constraints. If the second attempt also fails validation, abort Phase 1 with the error.

### Step 1.7 — User Checkpoint 🧑

Present the extracted claims to the user for confirmation. This is a mandatory checkpoint — do NOT proceed to Phase 2 without user approval.

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Phase 1 Complete — Claims Extracted

Source:  <announcement_url>
Method:  <webfetch | websearch | user_paste>
Claims:  <N> total

| # | Category | Confidence | Claim |
|---|----------|------------|-------|
| 1 | architecture | high | <claim text truncated to 80 chars> |
| 2 | performance | medium | <claim text truncated to 80 chars> |
| ... | ... | ... | ... |

Artifacts saved:
  • {session_dir}/claims.json
  • {session_dir}/source-snapshot.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Use AskUserQuestion:
  question: "Are these claims correct? Anything missing or incorrect?"
  options:
    - "Looks good — proceed to Phase 2"
    - "I have corrections" (user provides feedback → re-extract with corrections applied, re-validate, re-display)
    - "Add missing claims" (user provides additional claims → append to claims.json, re-validate, re-display)
    - "Abort pipeline"
```

If the user provides corrections or additions, update claims.json, re-run validation (Step 1.6), and re-display the updated summary. Repeat until the user approves.

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/claims.json
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/source-snapshot.md
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
