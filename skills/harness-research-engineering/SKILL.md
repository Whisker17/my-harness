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
7. [Phase 2: Codebase Navigation](#phase-2-codebase-navigation) — treeless clone, fuzzy tag matching, SHA resolution, diff-map generation
8. [Phase 3: Implementation Analysis](#phase-3-implementation-analysis) — claim batching, evidence mapping, code-first delta pass, quality gates
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

- **Mission:** Cross-reference claims against code diffs; independently scan for unreported changes
- **Inputs:** `claims.json`, `diff-map.json`, cloned repo path
- **Tools:** Read, Grep, Bash, Agent (for sub-dispatches)
- **Outputs:** `analysis.json` — claim-to-code evidence mapping + unreported changes
- **Behavior:**
  - Batch claims 5-8 per group, prioritizing same-category claims together (D1)
  - For each batch: read relevant diff hunks, match claims to code evidence (file path, line range, code snippet)
  - Mark each claim as `verified` (code evidence found), `partially_verified` (partial evidence), or `unverified` (no matching code)
  - Collect extended code snippets (20-30 lines) for claims with strong evidence
  - After all claim batches: run code-first delta pass (D12) — independently scan all diffs to find changes NOT covered by any claim
  - Output `unreported_changes` array with file, change description, and significance (high/medium/low)
  - Machine gate: warn if confirmed+partial coverage < 30% (claims quality concern)
  - Progress output after each batch: "Batch N/M complete, X/Y claims processed"

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
      "lines_deleted": 44,
      "num_hunks": 8
    },
    {
      "path": "pkg/governance/module.go",
      "status": "added",
      "category": "new_module",
      "lines_changed": 350,
      "lines_added": 350,
      "lines_deleted": 0,
      "num_hunks": 1
    }
  ],
  "summary": {
    "total_files": 47,
    "added": 12,
    "modified": 30,
    "deleted": 5,
    "renamed": 0,
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
| `files[].num_hunks` | number | ✅ | Number of contiguous change regions (hunks) in the file |
| `summary` | object | ✅ | Aggregate statistics |
| `summary.total_files` | number | ✅ | Total files in the diff |
| `summary.added` | number | ✅ | Files added |
| `summary.modified` | number | ✅ | Files modified |
| `summary.deleted` | number | ✅ | Files deleted |
| `summary.renamed` | number | ✅ | Files renamed |
| `summary.total_lines_changed` | number | ✅ | Total lines changed across all files |

**Phase boundary validation (before Phase 3):**
- `schema_version` must equal `1`
- `repo`, `base_sha`, `head_sha` must be non-empty strings
- `files` array must be non-empty
- Each file must have non-null `path`, `status`, `category`, `lines_changed`, `num_hunks`
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

### Step 1.0 — Session Directory Bootstrap

Before any artifact writes, create a concrete session directory for this analysis run:

```bash
CHAIN_SLUG=$(echo "<chain>" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
UPGRADE_SLUG=$(echo "<upgrade>" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
SESSION_DIR="$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION_DIR"
echo "Session directory: $SESSION_DIR"
```

Store `SESSION_DIR` as the canonical path for all Phase 1 artifacts. All subsequent steps in Phase 1 write to this directory — `{session_dir}` in the instructions below refers to the value of `$SESSION_DIR` created here.

**On failure** (mkdir fails due to permissions, disk full, etc.): print `"ERROR: Cannot create session directory at $SESSION_DIR"` and abort Phase 1.

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

Write this file using the Write tool. The snapshot preserves the content as returned by the fetching tool — **note that this is tool-processed content** (WebFetch applies markdown conversion, WebSearch returns summaries, user paste is as-provided), not the raw HTML/PDF source. The `fetch_method` field in the frontmatter records which tool produced the content, enabling downstream consumers to assess fidelity. For Tier 2 (WebSearch), if multiple sources were combined, record all fetched URLs in a `source_urls` list in the frontmatter alongside the primary `url`.

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

Chunking is triggered by **either** of these conditions (first match wins):

1. **Source size trigger:** If the source content has 4 or more distinct sections (level-2 or level-3 headings) OR exceeds 5,000 characters, skip the single-pass extraction in Step 1.3 entirely and go directly to chunked extraction below. This prevents the initial pass from silently omitting claims on long/dense announcements.

2. **Output count trigger:** If a single-pass extraction (Step 1.3) was performed and produced more than 15 claims, re-extract using chunked processing to improve quality.

**Chunked extraction process:**

1. **Split the source content** into logical sections (by heading or natural breaks)
2. **Process each chunk** independently with the same extraction prompt, targeting 5-8 claims per chunk
3. **Reconciliation pass:** After merging all chunks, compare section coverage against the source snapshot. If any section with a heading in the source has zero extracted claims, flag it:
   ```
   WARNING: Section "<heading>" has 0 extracted claims. Review for potential omissions.
   ```
   Present flagged sections to the user in the Step 1.7 checkpoint for manual review.
4. **Deduplicate:** Combine all chunks, then:
   - For each pair of claims, if the `text` fields share >80% of key terms (nouns, verbs, technical terms), treat them as duplicates
   - Keep the claim with higher confidence; if tied, keep the one from the earlier chunk
   - Re-number IDs sequentially after deduplication (claim-001, claim-002, ...)

If the source has fewer than 4 sections AND fewer than 5,000 characters AND the initial extraction produces ≤15 claims, skip chunking — use the initial results directly.

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

> **Implemented by:** WHI-230

Phase 2 clones the target repository, identifies the git refs that bracket the upgrade, and produces a structured diff map of every file that changed. This bridges "what the announcement claimed" to "what the code actually changed."

**Agent role:** `codebase_navigation_agent` (see [Agent Roles](#2-codebase_navigation_agent-phase-2))

### Step 2.0 — Input Validation

Before cloning, validate that the required inputs are available:

| Input | Source | Required |
|-------|--------|----------|
| `repo` | Input Resolution (user-provided or Linear lookup) | ✅ |
| `base_ref` | User-provided OR auto-detected via fuzzy tag matching | ❌ (auto-detect) |
| `head_ref` | User-provided OR auto-detected via fuzzy tag matching | ❌ (auto-detect) |
| `session_dir` | Created in Phase 1, Step 1.0 | ✅ |

**Recovering `session_dir`:** Phase 2 runs in the same session as Phase 1. The `SESSION_DIR` variable set in Step 1.0 should still be available. If not (e.g., re-invocation), find the most recent matching session directory:
```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
```
If no session directory is found, abort: "No session directory found. Run Phase 1 first."

If `repo` is missing, use AskUserQuestion:

```
Use AskUserQuestion:
  question: "What's the git repository URL to analyze?"
  options:
    - "Enter URL" (user provides a git-cloneable URL)
    - "Use local path" (user provides a local path to an existing repo)
    - "Abort pipeline"
```

If user provides a local path → set `CLONE_DIR` to the local path, `REPO_URL` to the absolute local path (for the `repo` field in diff-map.json), `clone_method = "local"`, and skip to Step 2.2.

### Step 2.1 — Repository Clone (D6: Treeless Clone)

Clone the target repository using a treeless clone to avoid downloading full blob history.

**Assign `REPO_URL`** from the resolved `repo` input:
```bash
REPO_URL="<repo>"  # The resolved repo URL from Input Resolution
```

**Clone directory:**
```bash
CHAIN_SLUG=$(echo "<chain>" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
UPGRADE_SLUG=$(echo "<upgrade>" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
CLONE_DIR="$HOME/.gstack/tmp/research-${CHAIN_SLUG}-${UPGRADE_SLUG}"
```

If `CLONE_DIR` already exists from a previous run, verify it's the correct repo and reuse it:
```bash
clone_method=""
if [ -d "$CLONE_DIR/.git" ]; then
  EXISTING_URL=$(git -C "$CLONE_DIR" remote get-url origin 2>/dev/null)
  if [ "$EXISTING_URL" = "$REPO_URL" ]; then
    echo "Reusing existing clone at $CLONE_DIR"
    if ! git -C "$CLONE_DIR" fetch --tags --force 2>/dev/null; then
      echo "⚠️  Warning: Could not fetch latest tags (offline?). Using cached tags from previous clone."
    fi
    clone_method="reused"
  else
    echo "Existing clone is for a different repo ($EXISTING_URL). Removing and re-cloning."
    rm -rf "$CLONE_DIR"
    # Fall through to fresh clone below
  fi
fi
```

**If `clone_method` is already `"reused"`, skip the clone steps below and proceed to Step 2.2.**

**Primary clone strategy: treeless clone**

```bash
timeout 300 git clone --filter=blob:none --no-checkout "$REPO_URL" "$CLONE_DIR" 2>&1
```

The 300-second (5 minute) timeout prevents hanging on very large repositories. If the clone succeeds:

```bash
cd "$CLONE_DIR"
git checkout HEAD
clone_method="treeless"
```

**Known large repositories** — for these repos, add depth limiting to the treeless clone:

| Repository pattern | Extra flags |
|-------------------|-------------|
| `*op-geth*`, `*go-ethereum*` | `--depth=1000` |
| `*optimism*` (monorepo) | `--depth=1000` |
| `*reth*` | `--depth=1000` |
| `*prysm*`, `*lighthouse*` | `--depth=1000` |

Detection: match the repo URL against these patterns before cloning. If matched:
```bash
timeout 300 git clone --filter=blob:none --no-checkout --depth=1000 "$REPO_URL" "$CLONE_DIR" 2>&1
cd "$CLONE_DIR"
git checkout HEAD
clone_method="treeless"
```

**Fallback: shallow clone**

If the treeless clone fails (exit code ≠ 0, timeout, or the remote doesn't support partial clone):

```bash
# Clean up failed attempt
rm -rf "$CLONE_DIR"

# Fallback to shallow clone
timeout 300 git clone --depth=100 "$REPO_URL" "$CLONE_DIR" 2>&1
clone_method="shallow"
```

**If both strategies fail:** abort Phase 2 with:
```
❌ Phase 2 aborted: Could not clone repository.
   URL: <repo_url>
   Treeless clone: <error>
   Shallow clone: <error>
   
   Check: Is the URL correct? Is the repo public? Is git configured for this host?
```

**Cleanup on failure:** If `CLONE_DIR` was partially created, remove it:
```bash
[ -d "$CLONE_DIR" ] && rm -rf "$CLONE_DIR"
```

### Step 2.2 — Tag Listing and Fuzzy Matching (D3)

If `base_ref` and `head_ref` are already provided by the user, skip to Step 2.3 (SHA Resolution).

Otherwise, auto-detect the relevant tags using fuzzy matching.

**Step 2.2a — List all tags**

```bash
cd "$CLONE_DIR"
ALL_TAGS=$(git tag -l | sort -V)
TAG_COUNT=$(echo "$ALL_TAGS" | grep -c . || echo "0")
echo "Found $TAG_COUNT tags"
```

If `TAG_COUNT` is 0 or `ALL_TAGS` is empty:
```
Use AskUserQuestion:
  question: "No tags found in the repository. Please provide the base and head git refs manually (branch names, commit SHAs, or any valid git ref)."
  options:
    - "Enter refs" (user provides base_ref and head_ref)
    - "Abort pipeline"
```

**Step 2.2b — Fuzzy match algorithm**

For each user-provided version hint (the `<upgrade>` name, or explicit version strings), compute a similarity score against every tag.

**Levenshtein distance normalization:**

```
similarity(a, b) = 1 - (levenshtein_distance(a, b) / max(len(a), len(b)))
```

**Pre-processing before comparison — strip common prefixes:**

For each tag AND for the user input, apply these transformations before computing similarity:
1. Remove leading `v` (e.g., `v1.0.0` → `1.0.0`)
2. Remove leading `release-` or `release/` (e.g., `release-1.0` → `1.0`)
3. Remove leading `tag/` (e.g., `tag/v1.0.0` → `v1.0.0` → `1.0.0`)
4. Remove leading `<project-name>/` (e.g., `op-node/v1.7.0` → `v1.7.0` → `1.7.0`)

**Scoring strategy:**

Compute TWO scores for each tag and take the maximum:
1. **Full match:** `similarity(stripped_user_input, stripped_tag)`
2. **Substring containment:** If the stripped user input appears as a substring of the stripped tag (case-insensitive), boost the score: `score = max(score, 0.7 + 0.3 * (len(user_input) / len(tag)))`

This handles cases like user input "ecotone" matching tag "op-node/v1.7.0-rc.1-ecotone" (substring match gives ~0.85).

**Implementation approach:**

The fuzzy matching is implemented as inline logic within the SKILL.md instruction set, NOT as an external script. The orchestrating LLM (Claude) performs the matching by:

1. Reading the tag list via `git tag -l | sort -V`
2. Evaluating Levenshtein similarity mentally or via a bash one-liner for simple cases
3. For large tag lists (>100 tags), first filter to tags containing any token from the user input (case-insensitive substring), then compute similarity only on the filtered set

```bash
# Pre-filter: tags containing any token from the user input
USER_TOKENS=$(echo "<upgrade_name>" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | sort -u)
FILTERED_TAGS=""
for token in $USER_TOKENS; do
  if [ -n "$token" ] && [ ${#token} -ge 3 ]; then
    MATCHES=$(echo "$ALL_TAGS" | grep -i "$token" || true)
    if [ -n "$MATCHES" ]; then
      FILTERED_TAGS="${FILTERED_TAGS}${FILTERED_TAGS:+$'\n'}${MATCHES}"
    fi
  fi
done
FILTERED_TAGS=$(echo "$FILTERED_TAGS" | sort -V | uniq | grep -v '^$')
```

If `FILTERED_TAGS` is empty, fall through to scoring ALL tags.

**Step 2.2c — Confidence-based selection**

Rank all tags by similarity score. Apply these thresholds:

| Confidence | Score Range | Action |
|-----------|-------------|--------|
| **Auto-select** | ≥ 0.8 | Use the highest-scoring tag automatically. Print: `Auto-selected tag: <tag> (confidence: <score>)` |
| **Candidate list** | ≥ 0.5 and < 0.8 | Present top 5 candidates to user for confirmation |
| **Full list** | < 0.5 (all tags) | Present all tags for manual selection |

**For the candidate list (0.5-0.8):**

```
Use AskUserQuestion:
  question: "I found these candidate tags for '<user_input>'. Which one is correct?"
  options:
    - "<tag1> (score: 0.75)"
    - "<tag2> (score: 0.68)"
    - "<tag3> (score: 0.62)"
    - "None of these — show all tags"
```

**For the full list (<0.5):**

```
Use AskUserQuestion:
  question: "I couldn't find a confident match for '<user_input>'. Here are all available tags. Which one should I use for <base|head>?"
  options:
    - "<most recent tags — show last 10 by version sort>"
    - "Let me type the exact ref"
```

**Repeat for both `base_ref` and `head_ref`.**

If the user needs to identify which tag is "before" and which is "after" the upgrade, use commit dates to help:
```bash
git log -1 --format="%ai" "$TAG" 2>/dev/null
```

### Step 2.3 — SHA Resolution (D13)

Once `base_ref` and `head_ref` are determined (either user-provided or fuzzy-matched), resolve them to full SHAs:

```bash
cd "$CLONE_DIR"
BASE_SHA=$(git rev-parse "$BASE_REF" 2>/dev/null)
HEAD_SHA=$(git rev-parse "$HEAD_REF" 2>/dev/null)
```

**Validation:**
- If `git rev-parse` fails for either ref → attempt to deepen:
  ```bash
  # For shallow/depth-limited clones, the tag's commit may be outside the boundary
  # Deepen for whichever ref(s) failed
  if [ -z "$BASE_SHA" ]; then
    git fetch origin "$BASE_REF" --depth=500 2>/dev/null || true
    BASE_SHA=$(git rev-parse "$BASE_REF" 2>/dev/null)
  fi
  if [ -z "$HEAD_SHA" ]; then
    git fetch origin "$HEAD_REF" --depth=500 2>/dev/null || true
    HEAD_SHA=$(git rev-parse "$HEAD_REF" 2>/dev/null)
  fi
  ```
  If still fails after deepening → error:
  ```
  ❌ Cannot resolve ref: <ref>
     Available tags: <list first 10 tags>
     Did you mean: <closest fuzzy match>?
  ```
  Use AskUserQuestion to let the user correct the ref.

- Verify the refs are in the correct chronological order:
  ```bash
  BASE_DATE=$(git log -1 --format="%ct" "$BASE_SHA")
  HEAD_DATE=$(git log -1 --format="%ct" "$HEAD_SHA")
  if [ "$BASE_DATE" -gt "$HEAD_DATE" ]; then
    echo "⚠️  Warning: base ref ($BASE_REF) is NEWER than head ref ($HEAD_REF). Refs may be swapped."
  fi
  ```
  If swapped, ask the user to confirm or swap them.

Print the resolved refs:
```
Resolved refs:
  base: $BASE_REF → $BASE_SHA
  head: $HEAD_REF → $HEAD_SHA
```

### Step 2.4 — Diff Generation

Generate the file-level diff between `BASE_SHA` and `HEAD_SHA`.

**Step 2.4a — File list with stats**

```bash
cd "$CLONE_DIR"
git diff --stat "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff-stat.txt"
git diff --numstat "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff-numstat.txt"
git diff --name-status "$BASE_SHA..$HEAD_SHA" > "$SESSION_DIR/diff-name-status.txt"
```

**Step 2.4b — Parse diff data**

For each changed file, extract:
- `path`: file path relative to repo root (from `--name-status`)
- `status`: A (added), M (modified), D (deleted), R (renamed) → map to `added`, `modified`, `deleted`, `renamed`
- `lines_added`: from `--numstat` (column 1)
- `lines_deleted`: from `--numstat` (column 2)
- `lines_changed`: `lines_added + lines_deleted`
- `num_hunks`: count of hunk headers (`@@` lines) per file:
  ```bash
  git diff -U0 "$BASE_SHA..$HEAD_SHA" -- "$FILE_PATH" | grep -c "^@@" || echo "0"
  ```
  For added files (entire file is one hunk), set `num_hunks = 1`. For deleted files, set `num_hunks = 1`. For large diffs (>500 files), batch the hunk counting:
  ```bash
  git diff -U0 "$BASE_SHA..$HEAD_SHA" | grep -E "^diff --git|^@@" | awk '
    /^diff/{if(NR>1) print prev_file, count; prev_file=$0; count=0}
    /^@@/{count++}
    END{if(prev_file) print prev_file, count}
  '
  ```

**Step 2.4c — Categorize files**

Assign a category to each file based on its path patterns. **Evaluate in priority order** (first match wins):

| Category | Path patterns |
|----------|---------------|
| `test` | `*_test.*`, `*_test/*`, `*/test/*`, `*/tests/*`, `*_spec.*`, `*/spec/*`, `*/__tests__/*` |
| `docs` | `*.md`, `*.rst`, `*.txt` (in docs/ or root), `*/docs/*`, `*/documentation/*` |
| `dependency` | `go.mod`, `go.sum`, `package.json`, `package-lock.json`, `yarn.lock`, `Cargo.toml`, `Cargo.lock`, `requirements.txt`, `Pipfile*` |
| `config` | `*.yaml`, `*.yml`, `*.toml`, `*.ini`, `*.cfg`, `Makefile`, `Dockerfile`, `*.Dockerfile`, `docker-compose*`, `.github/*`, `.circleci/*` (excludes `*.json` files already matched by `dependency`) |
| `new_module` | File has status `added` AND the parent directory is also new (no files with status `modified` in the same directory) |
| `core` | Everything else (production source code) |

For `new_module` detection, check if the directory existed in the base commit:
```bash
git ls-tree --name-only "$BASE_SHA" "$(dirname "$FILE_PATH")" 2>/dev/null
```
If the directory didn't exist in the base commit and the file is `added`, it's a `new_module`. Otherwise, it's `core` for added files in existing directories.

### Step 2.5 — Build diff-map.json

Assemble the `diff-map.json` artifact following the schema from [Artifact Schemas > diff-map.json](#diff-mapjson):

```json
{
  "schema_version": 1,
  "repo": "<repo_url>",
  "base_sha": "<full_sha>",
  "head_sha": "<full_sha>",
  "base_ref": "<user-facing ref name>",
  "head_ref": "<user-facing ref name>",
  "generated_at": "<ISO 8601 timestamp>",
  "clone_path": "<absolute path to CLONE_DIR>",
  "files": [
    {
      "path": "pkg/example/file.go",
      "status": "modified",
      "category": "core",
      "lines_changed": 42,
      "lines_added": 30,
      "lines_deleted": 12,
      "num_hunks": 3
    }
  ],
  "summary": {
    "total_files": 47,
    "added": 12,
    "modified": 30,
    "deleted": 5,
    "renamed": 0,
    "total_lines_changed": 4200
  }
}
```

**Write to:** `{session_dir}/diff-map.json`

### Step 2.6 — Self-Validation Gate

Before presenting to the user, validate diff-map.json against the schema. This is a pre-output self-validation (same approach as Phase 1, Step 1.6).

Validation checks:

1. `schema_version` equals `1`
2. `repo` is a non-empty string
3. `base_sha`, `head_sha` are non-empty strings (must look like hex SHAs, 7-40 chars)
4. `base_ref`, `head_ref` are non-empty strings
5. `generated_at` is a valid ISO 8601 timestamp
6. `clone_path` is a non-empty string
7. `files` array is non-empty
8. Each file has non-null `path`, `status`, `category`, `lines_changed`, `lines_added`, `lines_deleted`, `num_hunks`
9. Each `status` is one of: `added`, `modified`, `deleted`, `renamed`
10. Each `category` is one of: `core`, `new_module`, `config`, `test`, `docs`, `dependency`, `other`
11. `summary` is present with all required sub-fields (`total_files`, `added`, `modified`, `deleted`, `renamed`, `total_lines_changed`)
12. `summary.total_files` equals `len(files)`
13. `summary.added + summary.modified + summary.deleted + summary.renamed` equals `summary.total_files`

**On validation failure:**

```
❌ Validation failed: diff-map.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type | invalid enum value>
   Phase 2 self-validation failed. Attempting auto-fix...
```

Auto-fix attempt: Re-generate the problematic field(s) from the raw git diff data. If the second attempt also fails validation, abort Phase 2 with the error.

### Step 2.7 — User Checkpoint 🧑

Present the diff map summary to the user for confirmation. This is a mandatory checkpoint — do NOT proceed to Phase 3 without user approval.

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📂 Phase 2 Complete — Codebase Navigation

Repo:       <repo_url>
Clone:      <clone_method> (<clone_path>)
Base ref:   <base_ref> → <base_sha (first 8 chars)>
Head ref:   <head_ref> → <head_sha (first 8 chars)>

Summary:
  Total files changed:  <N>
  Added:                <N>
  Modified:             <N>
  Deleted:              <N>
  Total lines changed:  <N>

Top changed files (by lines changed):
  1. <path> (+<added>/-<deleted>) [<category>]
  2. <path> (+<added>/-<deleted>) [<category>]
  3. <path> (+<added>/-<deleted>) [<category>]
  ... (top 10)

Category breakdown:
  core:        <N> files (<N> lines)
  new_module:  <N> files (<N> lines)
  test:        <N> files (<N> lines)
  config:      <N> files (<N> lines)
  docs:        <N> files (<N> lines)
  dependency:  <N> files (<N> lines)
  other:       <N> files (<N> lines)

Artifacts saved:
  • {session_dir}/diff-map.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Use AskUserQuestion:
  question: "Does the diff map look correct? Are the refs and file changes what you expected?"
  options:
    - "Looks good — proceed to Phase 3"
    - "Wrong refs — let me correct them" (user provides corrected refs → re-run from Step 2.3)
    - "Unexpected changes — let me investigate" (pause for manual review, resume when ready)
    - "Abort pipeline"
```

If the user provides corrections, update the relevant steps, re-generate diff-map.json, re-validate, and re-display.

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/diff-map.json
```

**Repo clone retained at:**
```
~/.gstack/tmp/research-<chain>-<upgrade>/
```

Cleanup: Clone is kept alive until the pipeline completes (Phase 5 in M1). Cleaned up via bash trap on exit. Stale directories (>24h) are cleaned by the preamble on next invocation.

---

## Phase 3: Implementation Analysis

> **Implemented by:** WHI-231

Phase 3 is the core analysis stage: cross-reference Phase 1 claims against Phase 2 diff data to verify which claims have code evidence, then independently scan the diff for important changes the announcement didn't mention.

**Agent role:** `implementation_analysis_agent` (see [Agent Roles > implementation_analysis_agent](#3-implementation_analysis_agent-phase-3))

### Step 3.0 — Input Validation Gate

Before processing, validate both input artifacts from previous phases.

**Recovering `session_dir` and `clone_path`:** Phase 3 runs in the same session as Phases 1-2. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Validate claims.json:**

```bash
CLAIMS_FILE="$SESSION_DIR/claims.json"
if [ ! -f "$CLAIMS_FILE" ]; then
  echo "❌ Validation failed: claims.json not found at $CLAIMS_FILE"
  echo "   Phase 3 aborted. Run Phase 1 first."
  exit 1
fi
```

Parse and check using the validation rules from [Artifact Schemas > claims.json](#claimsjson):

1. File must be valid JSON
2. `schema_version` must equal `1`
3. `source_url` must be a non-empty string
4. `source_snapshot_path` must be a non-empty string
5. `claims` array must be non-empty
6. Each claim must have non-null `id`, `text`, `source_section`, `category`, `confidence`
7. `category` must be one of: `architecture`, `performance`, `security`, `governance`, `tooling`, `deprecation`, `other`
8. `confidence` must be one of: `high`, `medium`, `low`

**Validate diff-map.json:**

```bash
DIFFMAP_FILE="$SESSION_DIR/diff-map.json"
if [ ! -f "$DIFFMAP_FILE" ]; then
  echo "❌ Validation failed: diff-map.json not found at $DIFFMAP_FILE"
  echo "   Phase 3 aborted. Run Phase 2 first."
  exit 1
fi
```

Parse and check using the validation rules from [Artifact Schemas > diff-map.json](#diff-mapjson):

1. File must be valid JSON
2. `schema_version` must equal `1`
3. `repo`, `base_sha`, `head_sha` must be non-empty strings
4. `files` array must be non-empty
5. Each file must have non-null `path`, `status`, `category`, `lines_changed`, `num_hunks`
6. `status` must be one of: `added`, `modified`, `deleted`, `renamed`
7. `category` must be one of: `core`, `new_module`, `config`, `test`, `docs`, `dependency`, `other`
8. `summary` must be present with all required sub-fields

**On any validation failure:**

```
❌ Validation failed: <artifact>.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type (expected <type>, got <type>)>
   Phase 3 aborted. Fix the artifact and re-run.
```

Report ALL failures (not just the first one), then abort.

**Extract working variables after validation passes:**

```bash
CLONE_PATH=$(cat "$DIFFMAP_FILE" | jq -r '.clone_path')
BASE_SHA=$(cat "$DIFFMAP_FILE" | jq -r '.base_sha')
HEAD_SHA=$(cat "$DIFFMAP_FILE" | jq -r '.head_sha')
TOTAL_CLAIMS=$(cat "$CLAIMS_FILE" | jq '.claims | length')
TOTAL_FILES=$(cat "$DIFFMAP_FILE" | jq '.files | length')

echo "Clone path: $CLONE_PATH"
echo "Diff range: ${BASE_SHA:0:8}..${HEAD_SHA:0:8}"
echo "Claims to analyze: $TOTAL_CLAIMS"
echo "Files in diff: $TOTAL_FILES"
```

Verify the clone path still exists:
```bash
if [ ! -d "$CLONE_PATH/.git" ]; then
  echo "❌ Clone directory not found at $CLONE_PATH"
  echo "   The repository clone from Phase 2 may have been cleaned up."
  echo "   Re-run Phase 2 to re-clone the repository."
  exit 1
fi
```

### Step 3.1 — Claim Batching (D1)

Group claims into batches of 5-8 for processing. Prioritize grouping by `category` to maximize diff relevance per batch.

**Batching algorithm:**

1. Read all claims from `claims.json`
2. Group claims by `category`
3. For each category group:
   - If the group has ≤8 claims → it becomes one batch
   - If the group has >8 claims → split into sub-batches of 5-8
4. If any category group has <5 claims, merge it with the next smallest group (up to 8 total)
5. Assign batch IDs: `batch-001`, `batch-002`, ...

**Batch context preparation:**

For each batch, identify the relevant diff hunks:

1. Read the claims in the batch — extract any file references from `text` and `referenced_artifacts`
2. Cross-reference with `diff-map.json` to identify candidate files:
   - Files explicitly named in claims
   - Files whose `path` contains keywords from the claim text (function names, module names, feature names)
   - For `architecture` claims: prioritize `core` and `new_module` category files
   - For `performance` claims: prioritize files with high `lines_changed`
   - For `security` claims: include all files regardless of category
3. For each candidate file, fetch the diff hunks:
   ```bash
   cd "$CLONE_PATH"
   git diff "$BASE_SHA..$HEAD_SHA" -- "<file_path>"
   ```

**Context budget per batch (D1):**
- Claims text: ~2KB
- Diff hunks: ~4KB (truncate long diffs to the most relevant hunks — first 200 lines per file, prioritize files matching claim keywords)
- Instructions: ~2KB
- Total: ~8KB per batch

If the total diff hunks for a batch exceed 4KB, prioritize files by relevance:
1. Files explicitly mentioned in claim text → always include (full diff)
2. Files matching claim keywords → include (truncated to 100 lines)
3. Remaining candidate files → include file path and summary only (no diff content)

### Step 3.2 — Batch Analysis (Claim-to-Code Matching)

Process each batch by dispatching the `implementation_analysis_agent` via the Agent tool.

**Per-batch prompt:**

```
You are the Implementation Analyst. Your job is to read code diffs and determine
whether each claimed change actually exists in the codebase, collecting file paths
and line numbers as evidence.

## Claims to analyze (Batch <batch_id>)

<JSON array of claims in this batch>

## Relevant code diffs

<diff hunks for candidate files, with file paths as headers>

## Instructions

For each claim, determine its verification status:
- **verified**: Code evidence directly confirms the claim. The diff clearly shows
  the described change was implemented.
- **partially_verified**: Some evidence exists but the claim is only partly supported.
  Part of the described change is present, or the implementation differs from the
  claim's description in non-trivial ways.
- **unverified**: No code evidence found in the diff that supports this claim.
  The described change may not exist, may be in a different location, or may not
  be captured in this diff range.

For each claim, collect evidence:
- file: path relative to repo root
- lines: line range as string (e.g., "45-78")
- description: what this code evidence shows
- relevance: high (direct evidence), medium (indirect/supporting), low (tangential)

Optionally collect extended code snippets (20-30 lines) for claims with strong evidence.
These will be used in the final report:
- file: path relative to repo root
- start_line: starting line number
- end_line: ending line number
- content: the code content
- annotation: explanation of what the snippet demonstrates

Also provide analysis_notes for each claim — free-form notes explaining your reasoning,
especially for partially_verified or unverified claims.

Output as a valid JSON array of objects, one per claim:
{
  "claim_id": "<claim id>",
  "verification_status": "verified | partially_verified | unverified",
  "evidence": [{ "file": "...", "lines": "...", "description": "...", "relevance": "..." }],
  "code_snippets": [{ "file": "...", "start_line": N, "end_line": N, "content": "...", "annotation": "..." }],
  "analysis_notes": "..."
}

No prose, no commentary — just the JSON array.
```

**Progress output after each batch:**

```
Batch <N>/<total> complete, <claims_processed>/<total_claims> claims processed
  - verified: <count>
  - partially_verified: <count>
  - unverified: <count>
```

**Accumulate results:** After each batch, merge the results into a running `claims_analyzed` array.

### Step 3.3 — Code-First Delta Pass (D12)

After all claim batches are processed, run an independent scan of the entire diff to find changes NOT covered by claims.

**Purpose:** Discover unreported changes — important code modifications that the announcement didn't mention. This is a critical integrity check.

**Input:** `diff-map.json` files list (all changed files)

**Process:**

1. **Collect all claimed files:** Build a set of file paths that appeared as evidence in Step 3.2 results
2. **Identify unclaimed files:** Files in `diff-map.json` that are NOT in the claimed files set
3. **Filter for significance:** From unclaimed files, exclude:
   - `test` category files (test changes without claims are normal)
   - `docs` category files (doc changes without claims are normal)
   - `dependency` category files with ≤10 `lines_changed` (minor version bumps)
4. **Analyze remaining unclaimed files:** For each file, fetch its diff and assess:
   ```bash
   cd "$CLONE_PATH"
   git diff "$BASE_SHA..$HEAD_SHA" -- "<file_path>" | head -100
   ```

**Delta analysis prompt (dispatched via Agent tool):**

```
You are the Code Delta Analyst. Your job is to scan code diffs for changes that
were NOT mentioned in the project's announcement/claims. You are looking for
"unreported changes" — things the announcement missed or didn't talk about.

## Changed files NOT covered by any claim

<For each unclaimed file: path, status, lines_changed, first 100 lines of diff>

## Instructions

For each file, determine:
1. What changed (new feature? parameter change? bug fix? refactor? config change?)
2. How significant is this change:
   - **high**: Involves security, consensus, state migration, or breaking API changes
   - **medium**: Non-trivial functional change (new behavior, modified logic, error handling)
   - **low**: Refactor, cleanup, formatting, minor config, or boilerplate changes

3. Suggest a potential_category for each: architecture, performance, security,
   governance, tooling, deprecation, other

Output as a valid JSON array:
[{
  "file": "<path>",
  "status": "<added|modified|deleted|renamed>",
  "lines_changed": <number>,
  "description": "<what changed and why it matters>",
  "significance": "<high|medium|low>",
  "potential_category": "<category>"
}]

Include ALL files provided. Filter nothing — the orchestrator will decide what's relevant.
No prose, no commentary — just the JSON array.
```

**Also check claimed files for additional unreported changes:**

For files that DID appear as evidence for claims, check whether the diff contains OTHER significant changes beyond what the claims described. This catches cases where a file was partially analyzed for one claim but contains additional unreported modifications.

For each such file:
1. Read the full diff (not just the hunks matched to claims)
2. Compare the full set of hunks against the evidence already recorded
3. If there are significant hunks not covered by any claim's evidence, add them to `unreported_changes`

### Step 3.4 — Build analysis.json

Assemble the `analysis.json` artifact following the schema from [Artifact Schemas > analysis.json](#analysisjson):

```json
{
  "schema_version": 1,
  "generated_at": "<ISO 8601 timestamp>",
  "claims_analyzed": [
    <merged results from all batch processing in Step 3.2>
  ],
  "unreported_changes": [
    <results from Step 3.3 code-first delta pass>
  ],
  "summary": {
    "total_claims": <total claims analyzed>,
    "verified": <count of verified>,
    "unverified": <count of unverified>,
    "unreported_change_count": <count of unreported changes>
  }
}
```

**Compute summary statistics:**
```
total_claims = len(claims_analyzed)
verified = count where verification_status == "verified"
partially_verified_count = count where verification_status == "partially_verified"
unverified = count where verification_status == "unverified"
unreported_change_count = len(unreported_changes)
```

**Write to:** `{session_dir}/analysis.json`

### Step 3.5 — Machine Quality Gate

After writing `analysis.json`, run automated quality checks.

**Gate 1 — Evidence coverage warning (D7):**

```
confirmed_and_partial = verified + partially_verified_count
coverage_ratio = confirmed_and_partial / total_claims
```

If `coverage_ratio < 0.30` (less than 30% of claims have any evidence):
```
⚠️  Machine gate WARNING: Only <N>% of claims (<confirmed_and_partial>/<total_claims>)
    have code evidence (verified or partially_verified).
    This may indicate:
    - Claims are about changes outside the analyzed diff range
    - The announcement describes planned (not yet implemented) changes
    - The wrong git refs were selected in Phase 2
    
    Consider re-running Phase 2 with different refs before proceeding.
```

**Gate 2 — Majority unverified warning:**

If more than 50% of claims are `unverified`:
```
⚠️  Machine gate WARNING: >50% of claims are unverified (<unverified>/<total_claims>).
    The analysis may be unreliable. Review the claims and diff range carefully.
```

**Gate 3 — High-significance unreported changes alert:**

```
high_sig_count = count of unreported_changes where significance == "high"
```

If `high_sig_count > 0`:
```
⚠️  Machine gate ALERT: <high_sig_count> high-significance unreported changes found.
    These are important code changes NOT mentioned in the announcement.
    Review them carefully in the analysis output.
```

**These gates produce warnings only — they do NOT abort the pipeline.** The user checkpoint in Step 3.6 will present these warnings for human judgment.

### Step 3.6 — Self-Validation Gate

Before presenting to the user, validate `analysis.json` against the schema. This is a pre-output self-validation (same approach as Phase 1 Step 1.6 and Phase 2 Step 2.6).

Validation checks:

1. `schema_version` equals `1`
2. `generated_at` is a valid ISO 8601 timestamp
3. `claims_analyzed` array is non-empty
4. Each entry has non-null `claim_id`, `verification_status`, `evidence`
5. `verification_status` must be one of: `verified`, `unverified`, `partially_verified`
6. `evidence` must be an array (may be empty for unverified claims)
7. Each evidence entry (if present) must have non-null `file`, `lines`, `description`, `relevance`
8. `relevance` must be one of: `high`, `medium`, `low`
9. `unreported_changes` must be present (may be empty array — empty is valid, missing is not)
10. Each unreported change (if present) must have non-null `file`, `status`, `lines_changed`, `description`, `significance`
11. `significance` must be one of: `high`, `medium`, `low`
12. `summary` must be present with all required sub-fields
13. `summary.total_claims` must equal `len(claims_analyzed)`
14. `summary.verified + summary.unverified` plus count of `partially_verified` must equal `summary.total_claims`

**On validation failure:**

```
❌ Validation failed: analysis.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type | invalid enum value>
   Phase 3 self-validation failed. Attempting auto-fix...
```

Auto-fix attempt: Re-process the problematic entries. If the second attempt also fails validation, abort Phase 3 with the error.

### Step 3.7 — User Checkpoint

Present the analysis results to the user for confirmation. This is a mandatory checkpoint — do NOT proceed to Phase 5 without user approval.

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 Phase 3 Complete — Implementation Analysis

Claims analyzed:    <total_claims>
  Verified:         <verified> ✅
  Partially verified: <partially_verified_count> ⚠️
  Unverified:       <unverified> ❌

Evidence coverage:  <coverage_ratio as percentage>%
<if coverage_ratio < 0.30: show Gate 1 warning>
<if unverified > 50%: show Gate 2 warning>

Unreported changes: <unreported_change_count>
  High significance:   <high_sig_count>
  Medium significance: <medium_sig_count>
  Low significance:    <low_sig_count>
<if high_sig_count > 0: show Gate 3 alert>

Claim-by-Claim Summary:
| # | Claim (truncated) | Status | Evidence Files |
|---|-------------------|--------|----------------|
| 1 | <claim text, 60 chars> | ✅ verified | file1.go, file2.go |
| 2 | <claim text, 60 chars> | ⚠️ partial | file3.go |
| 3 | <claim text, 60 chars> | ❌ unverified | — |
| ... | ... | ... | ... |

<if unreported_changes is non-empty:>
Top Unreported Changes:
| # | File | Significance | Description (truncated) |
|---|------|-------------|------------------------|
| 1 | pkg/sequencer/batch.go | 🔴 high | <description, 60 chars> |
| 2 | pkg/config/defaults.go | 🟡 medium | <description, 60 chars> |
| ... | ... | ... | ... |

Artifacts saved:
  • {session_dir}/analysis.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Use AskUserQuestion:
  question: "Does the analysis look correct? Any claims need re-investigation or manual override?"
  options:
    - "Looks good — proceed to Phase 5"
    - "Re-investigate specific claims" (user identifies claims to re-analyze with broader file search)
    - "Override claim statuses" (user manually sets verification_status for specific claims)
    - "Abort pipeline"
```

If the user requests re-investigation:
1. For each flagged claim, broaden the file search — include ALL `core` and `new_module` files from `diff-map.json`
2. Re-run the analysis prompt for those claims only
3. Merge updated results into `analysis.json`
4. Re-validate and re-display

If the user overrides claim statuses:
1. Update the specified claims' `verification_status` in `analysis.json`
2. Add `"manual_override": true` to each overridden claim entry
3. Re-compute summary statistics
4. Re-validate and save

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
# CLONE_DIR must be set by Phase 2 using the same slugification as Step 2.1
# e.g., CLONE_DIR="$HOME/.gstack/tmp/research-${CHAIN_SLUG}-${UPGRADE_SLUG}"
cleanup() {
  if [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ]; then
    rm -rf "$CLONE_DIR"
    echo "Cleaned up temp clone: $CLONE_DIR"
  fi
}
trap cleanup EXIT
```
