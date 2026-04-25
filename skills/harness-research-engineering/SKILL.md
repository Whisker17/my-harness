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
9. [Phase 6: Verification](#phase-6-verification) — independent claim verification via Agent subagent, dispute detection, fix-verify loop
10. [Phase 4: Cross-Reference Analysis](#phase-4-cross-reference-analysis) — knowledge index query, chain association mapping, cross-version comparison
11. [Phase 5: Report Generation](#phase-5-report-generation) — artifact validation with graceful degradation, internal report synthesis, user checkpoint
12. [Phase 7: Knowledge Index Management](#phase-7-knowledge-index-management) — dedup check, public/internal separation, append-only JSONL, malformed line handling
13. [Phase 8: Public Summary Output](#phase-8-public-summary-output) — public field filtering, language config (en/zh), section-by-section approval gating
14. [Failure and Abort](#failure-and-abort) — error handling and cleanup

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

Seven agent roles across the pipeline. Each role is a behavioral directive dispatched via the Agent tool (not a separate process). Roles use compact bullet-list format.

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

### 4. comparison_agent (Phase 4 — M2)

- **Mission:** Compare the current upgrade analysis against prior research on related chains and versions, identifying patterns, regressions, and novel changes
- **Inputs:** `analysis.json`, `claims.json`, knowledge index entries (`~/.gstack/research/research-index.jsonl`) for the same chain, same repo, and related chains
- **Tools:** Read, Bash (grep), Write
- **Outputs:** `comparison.json` — cross-version architectural delta map
- **Behavior:**
  - Query the knowledge index for related entries by chain, repo, and associated chains (hardcoded mapping)
  - Compare current claims against historical claims at summary/category level
  - Identify which files are repeatedly modified across upgrades
  - Classify differences into schema arrays: `novel_features` (new capabilities), `divergent_features` (modified behavior AND removed capabilities), `borrowed_features` (unchanged/similar). Features present in historical analyses but absent from the current upgrade are classified as `divergent_features` with `impact` describing the removal (e.g., "Previously present in optimism/ecotone; not found in current upgrade — possible removal or consolidation"). This mapping covers all four acceptance criteria diff types: new_capability → novel_features, modified_behavior → divergent_features, removed → divergent_features (with removal-specific impact), unchanged → borrowed_features.
  - Output `novel_features`, `borrowed_features`, `divergent_features` arrays
  - When no historical data exists, output an empty comparison.json with empty arrays and log "no prior research found"

### 5. report_generation_agent (Phase 5)

- **Mission:** Synthesize all upstream artifacts into a structured internal technical report
- **Inputs:** `claims.json`, `diff-map.json`, `analysis.json` (all optional — handles partial availability)
- **Tools:** Write, Read
- **Outputs:** `internal-report.draft.md` → promoted to `internal-report.md` after user approval (M1 only generates internal report; public summary is M3 scope per D15)
- **Behavior:**
  - Report sections: Executive Summary, Claims Analysis (per-claim with evidence), Unclaimed Changes, Independent Verification (if verification-report.json available), Cross-Chain Comparison (if comparison.json available with data), Methodology, Raw Data References
  - Every claim references its verification status from `analysis.json` (or marked `[DATA UNAVAILABLE]` if analysis is missing)
  - Internal report uses full code snippets (20-30 lines) from `analysis.json` code_snippets
  - Unclaimed Changes section lists all code-first delta findings from `analysis.json` unreported_changes
  - Metadata header includes repo URL, base/head SHA, source URL, generation timestamp
  - Graceful degradation: if any upstream artifact is missing, generate partial report with `[DATA UNAVAILABLE]` markers (D9)
  - Cross-chain comparison sections are included when comparison.json is available from Phase 4 (omitted when knowledge index was empty)

### 6. verification_agent (Phase 6 — M2)

- **Mission:** Devil's advocate — independently verify whether evidence supports each claim, flag hallucinations and mismatches
- **Inputs:** `analysis.json` (top 10 claims by significance + their evidence), `claims.json` (for claim text/category)
- **Tools:** Dispatched as independent Agent subagent (not same context)
- **Outputs:** `verification-report.json` — structured per-claim assessment with disputes; `verification-report.md` — human-readable summary
- **Behavior:**
  - D2: Significance-based top-N selection and bounded-prompt subagent dispatch — select claims by significance tier, enforce ~8KB prompt budget, dispatch as independent Agent subagent
  - Receives ONLY the top 10 claims (selected by significance priority: security > consensus > feature > parameter) and their evidence from `analysis.json`
  - Does NOT access the original codebase — judges solely from the evidence snippets provided
  - For each claim, independently assesses whether the evidence actually supports the claim
  - Outputs assessment per claim: `confirmed` (evidence fully supports), `partial` (evidence partly supports), `unconfirmed` (evidence insufficient), `contradicted` (evidence contradicts claim)
  - When assessment disagrees with Phase 3's `verification_status`, marks a dispute
  - Disputes trigger a fix-verify loop: Phase 3 rechecks → new subagent re-verifies → max 3 rounds
  - After max rounds, unresolved disputes are preserved with both assessments
  - Prompt is bounded to ~8KB (role ~200B, claims+evidence ~6KB, instructions ~1KB, output format ~800B)
  - Generates `verification-report.md` with per-claim judgments + "Reviewer Concerns" section

### 7. knowledge_index_agent (Phase 7)

- **Mission:** Persist analysis results to the knowledge index for future cross-reference
- **Inputs:** `internal-report.md`, `claims.json`, `diff-map.json`, `analysis.json`, session metadata
- **Tools:** Read, Write, Bash, AskUserQuestion
- **Outputs:** Appended entry in `~/.gstack/research/research-index.jsonl`
- **Behavior:**
  - Read the final internal report and upstream artifacts to extract index entry fields
  - Build a structured index entry with `public` and `internal` field sets (D15)
  - Compute the dedup composite key: `chain:upgrade_name:repo` (D4)
  - Read the existing knowledge index, checking for duplicate entries
  - If a duplicate is found: present the user with three choices via AskUserQuestion — overwrite, keep-both, or skip
  - Handle malformed JSON lines gracefully: skip the line, log a warning with the line number, continue reading
  - Auto-create `~/.gstack/research/` directory if it does not exist
  - Append the entry as a single-line JSON record to the JSONL file

### 8. public_communications_writer (Phase 8)

- **Mission:** Distill the internal technical analysis into a clear, professional public summary suitable for external stakeholders
- **Inputs:** `internal-report.md`, knowledge index `public` fields, language configuration
- **Tools:** Read, Write
- **Outputs:** `public-summary.md` — public-safe summary with no code, file paths, or internal analysis details
- **Behavior:**
  - Reads `internal-report.md` and extracts only public-safe content (no code snippets, file paths, line numbers, internal analysis notes)
  - Optionally reads knowledge index `public` field set for supplementary data (executive_summary, claims_summary)
  - Transforms code references into natural language descriptions (e.g., "withdrawal proof mechanism" not "contracts/src/L2/OptimismPortal2.sol:L345")
  - Transforms file paths into component names (e.g., "L2 bridge contracts" not "contracts/src/L2/")
  - Summary structure: Overview → Key Changes → Impact Assessment → Verification Status
  - Language is configurable: English (default) or Chinese (`--lang zh`)
  - Appends a disclaimer at the end of every summary
  - Section-by-section user approval: each section is presented individually for confirmation before the full summary is finalized

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
**Consumed by:** Phase 3 (Implementation Analysis), Phase 5 (Report Generation), Phase 6 (Verification)

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
**Consumed by:** Phase 4 (Cross-Reference), Phase 5 (Report Generation), Phase 6 (Verification)

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
    "partially_verified": 0,
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
| `claims_analyzed[].manual_override` | boolean | ❌ | Set to `true` when the user manually overrode this claim's `verification_status` at the Phase 3 checkpoint |
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
| `summary.partially_verified` | number | ✅ | Claims with partial code evidence |
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
- `summary.verified + summary.partially_verified + summary.unverified` must equal `summary.total_claims`

### comparison.json

**Produced by:** Phase 4 (Cross-Reference Agent — M2)
**Consumed by:** Phase 5 (Report Generation — cross-chain sections)

> **Note:** When the knowledge index is empty (no prior analyses), Phase 4 outputs a comparison.json with empty `comparisons`, `novel_features`, `borrowed_features`, and `divergent_features` arrays. Phase 5 detects empty comparisons and omits cross-chain sections from the report.

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
| `comparisons` | array | ✅ | Prior analyses being compared against (empty when no relevant entries in knowledge index) |
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

**Phase boundary validation (before Phase 5, when comparison.json exists):**
- `schema_version` must equal `1`
- `baseline` must be present with non-null `chain`, `upgrade`, `session_dir`
- `comparisons` array must be present (may be empty — empty signals no historical data available)
- `novel_features`, `borrowed_features`, `divergent_features` must be present (may be empty arrays)
- When `comparisons` is empty, Phase 5 omits the Cross-Chain Comparison section

### verification-report.json

**Produced by:** Phase 6 (Verification Agent — M2)
**Consumed by:** Phase 5 (Report Generation — verification section, when Phase 6 data is available)

Phase 6 outputs a structured JSON artifact containing the independent reviewer's per-claim assessments, dispute tracking, and final verification status. The example below shows 2 reviews for brevity; a real run would have up to 10 (matching `claims_reviewed`). Summary counts must equal `len(reviews)`.

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-25T14:00:00Z",
  "verification_status": "verified",
  "total_rounds": 1,
  "claims_reviewed": 2,
  "claims_total": 24,
  "selection_criteria": "top 10 by significance (security > consensus > feature > parameter)",
  "reviews": [
    {
      "claim_id": "claim-001",
      "original_status": "verified",
      "reviewer_assessment": "confirmed",
      "reasoning": "The evidence at contracts/L2/OptimismPortal.sol:142-168 directly implements the described withdrawal proof mechanism. The code snippet clearly shows the new function signature and logic.",
      "agrees_with_original": true,
      "dispute": false,
      "rounds": []
    },
    {
      "claim_id": "claim-003",
      "original_status": "verified",
      "reviewer_assessment": "partial",
      "reasoning": "The evidence shows the function exists but the implementation only covers 2 of the 3 cases described in the claim.",
      "agrees_with_original": false,
      "dispute": true,
      "rounds": [
        {
          "round": 1,
          "recheck_notes": "Re-examined with broader file search. Found additional handler in batch.go covering the third case.",
          "updated_status": "verified",
          "reviewer_reassessment": "confirmed",
          "resolved": true
        }
      ]
    }
  ],
  "reviewer_concerns": [
    {
      "severity": "medium",
      "description": "claim-007 references a 'governance module' but the evidence points to a config file, not a governance implementation.",
      "affected_claims": ["claim-007"]
    }
  ],
  "summary": {
    "confirmed": 1,
    "partial": 1,
    "unconfirmed": 0,
    "contradicted": 0,
    "disputes_found": 1,
    "disputes_resolved": 1,
    "disputes_unresolved": 0
  }
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `generated_at` | string (ISO 8601) | ✅ | Timestamp when verification completed |
| `verification_status` | string | ✅ | Final status: `verified` (no unresolved disputes), `partial` (unresolved disputes remain after max rounds) |
| `total_rounds` | number | ✅ | Total fix-verify rounds executed (0 = no disputes, max 3) |
| `claims_reviewed` | number | ✅ | Number of claims sent to verification (top 10 or fewer) |
| `claims_total` | number | ✅ | Total claims in the analysis (for context) |
| `selection_criteria` | string | ✅ | Description of how claims were selected for verification |
| `reviews` | array (non-empty) | ✅ | Per-claim verification assessments |
| `reviews[].claim_id` | string | ✅ | References `claims[].id` from claims.json |
| `reviews[].original_status` | string | ✅ | The `verification_status` from analysis.json for this claim |
| `reviews[].reviewer_assessment` | string | ✅ | Independent assessment: `confirmed`, `partial`, `unconfirmed`, `contradicted` |
| `reviews[].reasoning` | string | ✅ | 1-3 sentence explanation of the reviewer's judgment |
| `reviews[].agrees_with_original` | boolean | ✅ | Whether the reviewer agrees with Phase 3's assessment |
| `reviews[].dispute` | boolean | ✅ | Whether this claim triggered a dispute (disagreement with original) |
| `reviews[].rounds` | array | ✅ | Fix-verify round history (empty array if no dispute) |
| `reviews[].rounds[].round` | number | ✅ | Round number (1-based) |
| `reviews[].rounds[].recheck_notes` | string | ✅ | What Phase 3 rechecked and found |
| `reviews[].rounds[].updated_status` | string | ✅ | Phase 3's updated `verification_status` after recheck |
| `reviews[].rounds[].reviewer_reassessment` | string | ✅ | Reviewer's new assessment after seeing updated evidence |
| `reviews[].rounds[].resolved` | boolean | ✅ | Whether this round resolved the dispute |
| `reviewer_concerns` | array | ✅ | General concerns raised by the reviewer (may be empty) |
| `reviewer_concerns[].severity` | string | ✅ | One of: `high`, `medium`, `low` |
| `reviewer_concerns[].description` | string | ✅ | Description of the concern |
| `reviewer_concerns[].affected_claims` | array | ✅ | Claim IDs related to this concern |
| `summary` | object | ✅ | Aggregate verification statistics |
| `summary.confirmed` | number | ✅ | Count of claims where `reviewer_assessment == "confirmed"` (initial assessment, before any round resolution) |
| `summary.partial` | number | ✅ | Count of claims where `reviewer_assessment == "partial"` (initial assessment) |
| `summary.unconfirmed` | number | ✅ | Count of claims where `reviewer_assessment == "unconfirmed"` (initial assessment) |
| `summary.contradicted` | number | ✅ | Count of claims where `reviewer_assessment == "contradicted"` (initial assessment) |
| `summary.disputes_found` | number | ✅ | Total disputes triggered |
| `summary.disputes_resolved` | number | ✅ | Disputes resolved during fix-verify loop |
| `summary.disputes_unresolved` | number | ✅ | Disputes remaining after max rounds |

**Phase boundary validation (before Phase 5, when Phase 6 data exists):**
- `schema_version` must equal `1`
- `verification_status` must be one of: `verified`, `partial`
- `reviews` array must be non-empty
- Each review must have non-null `claim_id`, `original_status`, `reviewer_assessment`, `reasoning`, `agrees_with_original`, `dispute`
- `reviewer_assessment` must be one of: `confirmed`, `partial`, `unconfirmed`, `contradicted`
- `summary` must be present with all required sub-fields
- `summary.confirmed + summary.partial + summary.unconfirmed + summary.contradicted` must equal `len(reviews)`
- `summary.disputes_resolved + summary.disputes_unresolved` must equal `summary.disputes_found`

### research-index.jsonl (Knowledge Index Entry)

**Produced by:** Phase 7 (Knowledge Index Management)
**Consumed by:** Phase 4 (Cross-Reference Agent), M3 public summary generation

Each line in `~/.gstack/research/research-index.jsonl` is a standalone JSON object representing one completed analysis. Entries have two field sets: `public` (safe to share externally) and `internal` (full evidence, local paths, detailed data).

```json
{
  "schema_version": 1,
  "id": "base-azul-20260425-120000",
  "dedup_key": "base:azul:base-org/base-contracts",
  "public": {
    "chain": "base",
    "upgrade_name": "Azul",
    "source_url": "https://blog.base.org/azul-upgrade",
    "executive_summary": "Base Azul introduces independent derivation pipeline, governance module, and zstd batch compression...",
    "claims_summary": {
      "total": 12,
      "confirmed": 8,
      "partial": 2,
      "unconfirmed": 1,
      "contradicted": 1
    },
    "generated_at": "2026-04-25T12:00:00Z"
  },
  "internal": {
    "repo": "base-org/base-contracts",
    "base_sha": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "head_sha": "f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5",
    "base_ref": "v0.8.0",
    "head_ref": "v0.9.0-azul",
    "full_claims": [
      {
        "id": "claim-001",
        "text": "Added independent derivation pipeline",
        "category": "architecture",
        "verification_status": "verified"
      }
    ],
    "evidence_map_path": "sessions/base-azul-20260425-120000/analysis.json",
    "verification_status": "verified",
    "unclaimed_changes_count": 3
  }
}
```

**Field reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | number | ✅ | Always `1` for v1 |
| `id` | string | ✅ | Unique entry ID: `{chain_slug}-{upgrade_slug}-{YYYYMMDD}-{HHMMSS}` |
| `dedup_key` | string | ✅ | Composite key for dedup: `{chain}:{upgrade_name}:{repo}` (D4) |
| **public fields** | | | |
| `public.chain` | string | ✅ | Blockchain name (lowercase) |
| `public.upgrade_name` | string | ✅ | Upgrade/hardfork name |
| `public.source_url` | string | ✅ | Announcement URL |
| `public.executive_summary` | string | ✅ | 2-3 sentence summary of the analysis findings |
| `public.claims_summary` | object | ✅ | Aggregate claim verification stats |
| `public.claims_summary.total` | number | ✅ | Total claims analyzed |
| `public.claims_summary.confirmed` | number | ✅ | Claims with status `verified` |
| `public.claims_summary.partial` | number | ✅ | Claims with status `partially_verified` |
| `public.claims_summary.unconfirmed` | number | ✅ | Claims with status `unverified` |
| `public.claims_summary.contradicted` | number | ✅ | Claims with contradictory evidence (0 in M1/M2 — reserved for future use) |
| `public.generated_at` | string (ISO 8601) | ✅ | Timestamp when the analysis was completed |
| **internal fields** | | | |
| `internal.repo` | string | ✅ | Repository identifier (org/repo format) |
| `internal.base_sha` | string | ✅ | Full SHA of the base commit (D13) |
| `internal.head_sha` | string | ✅ | Full SHA of the head commit (D13) |
| `internal.base_ref` | string | ✅ | Human-readable base ref (tag/branch name) |
| `internal.head_ref` | string | ✅ | Human-readable head ref (tag/branch name) |
| `internal.full_claims` | array | ✅ | Compact claim array: id, text, category, verification_status for each |
| `internal.evidence_map_path` | string | ✅ | Relative path (from `~/.gstack/research/`) to the analysis.json |
| `internal.verification_status` | string | ✅ | Overall verification status: `verified` (>70% confirmed+partial), `partial` (30-70%), `low_confidence` (<30%) |
| `internal.unclaimed_changes_count` | number | ✅ | Count of unreported changes from code-first delta pass |

**Dedup key construction (D4):**

The dedup key is a composite of three fields joined by colons, **all lowercased** for case-insensitive matching:
```
dedup_key = "{chain}:{upgrade_name_lower}:{repo}"
```
Where:
- `chain` = `public.chain` (already lowercase)
- `upgrade_name_lower` = `public.upgrade_name` converted to lowercase (original case preserved in `public.upgrade_name`, but the dedup key always uses lowercase to prevent case-variant duplicates like `Azul` vs `azul` vs `AZUL`)
- `repo` = `internal.repo` (org/repo format, no protocol prefix, no `.git` suffix — see normalization rules below)

Example: `base:azul:base-org/base-contracts`

**`repo` normalization rules:**

When extracting `repo_short` from a full repository URL, apply these transformations in order:
1. Strip protocol prefix: `https://`, `http://`, `git://`, `ssh://`
2. Strip `git@` prefix and replace `:` with `/` (SSH URLs: `git@github.com:org/repo` → `github.com/org/repo`)
3. Strip the hostname: remove `github.com/`, `gitlab.com/`, or any `<host>/` prefix
4. Strip trailing `.git` suffix
5. Strip trailing `/`
6. The result should be `org/repo` format (e.g., `base-org/base-contracts`)

```
Examples:
  "https://github.com/base-org/base-contracts"       → "base-org/base-contracts"
  "https://github.com/base-org/base-contracts.git"    → "base-org/base-contracts"
  "git@github.com:base-org/base-contracts.git"        → "base-org/base-contracts"
  "https://github.com/base-org/base-contracts/"       → "base-org/base-contracts"
```

**Overall verification_status computation:**

```
confirmed_and_partial = claims_summary.confirmed + claims_summary.partial
total = claims_summary.total

if total == 0:
  verification_status = "low_confidence"
elif confirmed_and_partial / total > 0.70:
  verification_status = "verified"
elif confirmed_and_partial / total >= 0.30:
  verification_status = "partial"
else:
  verification_status = "low_confidence"
```

### Per-Phase Validation Summary

| Phase | Validates Before Processing | Artifacts Checked |
|-------|----------------------------|-------------------|
| Phase 1 | _(none — first phase)_ | — |
| Phase 2 | _(none — independent of Phase 1 output)_ | — |
| Phase 3 | claims.json, diff-map.json | Both must pass all validation rules |
| Phase 4 | analysis.json, knowledge index | analysis.json must pass; knowledge index read with graceful handling (empty index → skip comparison, output empty comparison.json) |
| Phase 5 | claims.json, diff-map.json, analysis.json (+ comparison.json if Phase 4 ran, + verification-report.json in M2) | All must pass validation |
| Phase 6 (verification) | analysis.json, claims.json | Both must pass all validation rules |
| Phase 7 | internal-report.md, claims.json, diff-map.json, analysis.json | At least internal-report.md must exist; other artifacts used for field extraction |

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

Cleanup: Clone is kept alive until the pipeline completes (Phase 5 in M1; Phase 5 in M2 since Phase 6's fix-verify recheck also requires the clone). Cleaned up via bash trap on exit. Stale directories (>24h) are cleaned by the preamble on next invocation.

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
4. If any category group has <5 claims, attempt to merge it with the next-smallest group. If the merged result is ≤8 claims, merge them into one batch. If the merged result would exceed 8, keep the small group as its own batch (batches with <5 claims are allowed when no valid merge target exists). Never create a batch exceeding 8 claims.
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

**Batch completeness check:** After all batches are processed, verify `len(claims_analyzed) == TOTAL_CLAIMS`. If any claims are missing (batch agent truncated output or dropped claims), identify which `claim_id`s from `claims.json` are absent and re-dispatch those specific claims as a recovery batch. If the recovery batch also fails to produce results for the missing claims, mark them as `unverified` with `analysis_notes: "Claim could not be analyzed — batch processing failed to produce a result for this claim."` to ensure `claims_analyzed` always has exactly one entry per input claim.

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
    "partially_verified": <count of partially_verified>,
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

If `unverified / total_claims > 0.50` (more than 50% of all claims are `unverified`):
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
11. `status` must be one of: `added`, `modified`, `deleted`, `renamed`
12. `significance` must be one of: `high`, `medium`, `low`
13. `summary` must be present with all required sub-fields
14. `summary.total_claims` must equal `len(claims_analyzed)`
15. `summary.verified + summary.partially_verified + summary.unverified` must equal `summary.total_claims`

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
<if (unverified / total_claims) > 0.50: show Gate 2 warning>

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
    - "Run verification first (Phase 6 — M2)" (dispatch independent Devil's Advocate verification before report generation)
    - "Skip verification — proceed to Phase 5" (go directly to report generation without independent verification)
    - "Re-investigate specific claims" (user identifies claims to re-analyze with broader file search)
    - "Override claim statuses" (user manually sets verification_status for specific claims)
    - "Abort pipeline"
```

If the user selects "Run verification first (Phase 6 — M2)":
1. Proceed to Phase 6 (Verification). After Phase 6 completes, the Phase 6 checkpoint will route through Phase 4, then to Phase 5.

If the user selects "Skip verification — proceed to Phase 5":
1. Run Phase 4 (Cross-Reference Analysis) — this is non-interactive and runs automatically.
2. Proceed to Phase 5. The report will not include Independent Verification data but will include Cross-Chain Comparison data if the knowledge index had relevant entries.

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

## Phase 6: Verification

> **Implemented by:** WHI-234

Phase 6 is the pipeline's quality assurance layer: an independent Agent subagent acting as Devil's Advocate re-examines the top 10 claims from Phase 3, challenging whether the evidence actually supports each conclusion. It does NOT trust Phase 3's judgment — it forms its own opinion from the evidence alone. When the reviewer disagrees with Phase 3, a fix-verify loop attempts resolution (max 3 rounds).

**Agent role:** `verification_agent` (see [Agent Roles > verification_agent](#6-verification_agent-phase-6--m2))

### Step 6.0 — Input Validation Gate

Before processing, validate the required input artifacts.

**Recovering `session_dir`:** Phase 6 runs in the same session as Phases 1-5. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Validate analysis.json:**

```bash
ANALYSIS_FILE="$SESSION_DIR/analysis.json"
if [ ! -f "$ANALYSIS_FILE" ]; then
  echo "❌ Validation failed: analysis.json not found at $ANALYSIS_FILE"
  echo "   Phase 6 aborted. Run Phase 3 first."
  exit 1
fi
```

Parse and check using the validation rules from [Artifact Schemas > analysis.json](#analysisjson):

1. File must be valid JSON
2. `schema_version` must equal `1`
3. `claims_analyzed` array must be non-empty
4. Each entry must have non-null `claim_id`, `verification_status`, `evidence`
5. `verification_status` must be one of: `verified`, `unverified`, `partially_verified`
6. `summary` must be present with all required sub-fields

**Validate claims.json:**

```bash
CLAIMS_FILE="$SESSION_DIR/claims.json"
if [ ! -f "$CLAIMS_FILE" ]; then
  echo "❌ Validation failed: claims.json not found at $CLAIMS_FILE"
  echo "   Phase 6 aborted. Run Phase 1 first."
  exit 1
fi
```

Parse and check using the validation rules from [Artifact Schemas > claims.json](#claimsjson):

1. File must be valid JSON
2. `schema_version` must equal `1`
3. `claims` array must be non-empty
4. Each claim must have non-null `id`, `text`, `category`

**On any validation failure:**

```
❌ Validation failed: <artifact>.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type (expected <type>, got <type>)>
   Phase 6 aborted. Fix the artifact and re-run.
```

Report ALL failures (not just the first one), then abort.

**Validate diff-map.json** (required for fix-verify loop repository context):

```bash
DIFFMAP_FILE="$SESSION_DIR/diff-map.json"
if [ ! -f "$DIFFMAP_FILE" ]; then
  echo "⚠️  diff-map.json not found at $DIFFMAP_FILE"
  echo "   Fix-verify loop will be disabled — disputed claims cannot be rechecked without repo context."
  DIFFMAP_AVAILABLE=false
else
  DIFFMAP_AVAILABLE=true
fi
```

If `DIFFMAP_AVAILABLE=true`, validate:

1. File must be valid JSON
2. `clone_path` must be a non-empty string
3. The directory at `clone_path` must exist and contain a `.git` directory
4. `base_sha` and `head_sha` must be non-empty strings

```bash
if [ "$DIFFMAP_AVAILABLE" = true ]; then
  CLONE_PATH=$(jq -r '.clone_path // empty' "$DIFFMAP_FILE")
  BASE_SHA=$(jq -r '.base_sha // empty' "$DIFFMAP_FILE")
  HEAD_SHA=$(jq -r '.head_sha // empty' "$DIFFMAP_FILE")

  DIFFMAP_VALID=true
  if [ -z "$CLONE_PATH" ]; then
    echo "⚠️  diff-map.json: clone_path is missing or empty"
    DIFFMAP_VALID=false
  elif [ ! -d "$CLONE_PATH/.git" ]; then
    echo "⚠️  diff-map.json: clone_path ($CLONE_PATH) is not a valid git repository"
    DIFFMAP_VALID=false
  fi
  if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ]; then
    echo "⚠️  diff-map.json: base_sha or head_sha is missing"
    DIFFMAP_VALID=false
  fi

  if [ "$DIFFMAP_VALID" = false ]; then
    echo "   Fix-verify loop will be disabled — repo context is incomplete."
    DIFFMAP_AVAILABLE=false
  else
    echo "Repository context: $CLONE_PATH ($BASE_SHA..$HEAD_SHA)"
  fi
fi
```

> **Impact of missing diff-map.json:** Phase 6 claim selection and initial verification proceed normally (they only need analysis.json and claims.json). Only the fix-verify loop in Step 6.3 is affected — if `DIFFMAP_AVAILABLE=false`, disputed claims are marked as unresolved instead of entering the recheck cycle.

**Extract working variables after validation passes:**

```bash
TOTAL_CLAIMS=$(cat "$CLAIMS_FILE" | jq '.claims | length')
TOTAL_ANALYZED=$(cat "$ANALYSIS_FILE" | jq '.claims_analyzed | length')

echo "Total claims: $TOTAL_CLAIMS"
echo "Total analyzed: $TOTAL_ANALYZED"
echo "Diff-map available: $DIFFMAP_AVAILABLE"
```

### Step 6.1 — Top 10 Claim Selection (D2)

Select the top 10 claims for verification, sorted by significance. The significance priority order is:

```
security > consensus > feature > parameter
```

**Mapping from claim `category` to significance tier:**

| Claim category | Significance tier | Priority |
|---------------|-------------------|----------|
| `security` | security | 1 (highest) |
| `architecture` | consensus | 2 |
| `governance` | consensus | 2 |
| `performance` | feature | 3 |
| `tooling` | feature | 3 |
| `deprecation` | feature | 3 |
| `other` | parameter | 4 (lowest) |

**Selection algorithm:**

1. Join `claims.json` claims with `analysis.json` claims_analyzed by `claim_id`
2. Assign each joined claim a significance tier based on its `category`
3. Within each tier, sort by `verification_status` priority: `unverified` > `partially_verified` > `verified` (unverified claims are more valuable to verify independently)
4. Within the same status, sort by evidence count (ascending — fewer evidence items = more scrutiny needed)
5. Take the top 10 claims from this sorted list

If there are fewer than 10 claims total, use all claims.

**Build the verification payload:**

For each selected claim, assemble:

```json
{
  "claim_id": "<claim.id>",
  "claim_text": "<claim.text>",
  "category": "<claim.category>",
  "original_status": "<analysis.verification_status>",
  "evidence": [<analysis.evidence array>],
  "code_snippets": [<analysis.code_snippets array, if available>],
  "analysis_notes": "<analysis.analysis_notes>"
}
```

**Prompt budget check (~8KB):**

```
Role: ~200 bytes
Instructions: ~1KB
Output format: ~800 bytes
Claims + evidence: remaining budget (~6KB)
```

Estimate the byte size of the claims payload. If the 10 claims exceed ~6KB:
1. Truncate `code_snippets[].content` to first 20 lines per snippet
2. If still over budget, truncate `evidence[].description` to 100 characters each
3. If still over budget, reduce to 8 claims, then 6, then 5 (minimum)

Print: `Selected <N> claims for verification (significance: <tier distribution>)`

### Step 6.2 — Agent Subagent Dispatch (D2)

Dispatch the verification as an independent Agent subagent. The subagent has no access to the current conversation context — it receives only the bounded prompt.

**Verification prompt:**

```
You are the Devil's Advocate Reviewer. Your job is to independently verify whether
the evidence actually supports each claim. Be skeptical. Do not defer to the original
analysis — form your own judgment from the evidence provided.

## Claims to Verify

<JSON array of verification payload from Step 6.1>

## Instructions

For each claim:

1. Read the claim text carefully.
2. Read ALL evidence items and code snippets provided.
3. Independently assess whether the evidence supports the claim:
   - **confirmed**: The evidence clearly and directly supports the claim. The code
     snippets show the described change was implemented as stated.
   - **partial**: Some evidence exists but it only partly supports the claim. Key
     aspects of the claim are unsupported or the evidence is indirect/ambiguous.
   - **unconfirmed**: The evidence provided does not adequately support this claim.
     The code snippets don't show what the claim describes, or the connection is
     too tenuous.
   - **contradicted**: The evidence actively contradicts the claim. The code shows
     something different from what was claimed.

4. Provide your reasoning (1-3 sentences). Be specific about what evidence you
   examined and why you reached your conclusion.

5. State whether you agree with the original assessment.

6. If you have general concerns about the analysis methodology or evidence quality,
   note them separately.

## Output Format

Return a JSON object with this exact structure:

{
  "reviews": [
    {
      "claim_id": "<claim id>",
      "reviewer_assessment": "confirmed | partial | unconfirmed | contradicted",
      "reasoning": "<1-3 sentences>",
      "agrees_with_original": true | false
    }
  ],
  "reviewer_concerns": [
    {
      "severity": "high | medium | low",
      "description": "<concern description>",
      "affected_claims": ["<claim_id>", ...]
    }
  ]
}

IMPORTANT:
- Output ONLY valid JSON. No prose, no markdown, no commentary.
- You MUST include an entry for EVERY claim provided.
- Be genuinely skeptical — your value comes from catching mistakes, not confirming them.
- "confirmed" should mean you would stake your reputation on this claim being true.
```

**Dispatch via Agent tool:**

```
Agent({
  description: "Verification of upgrade analysis claims",
  prompt: <assembled prompt from above>
})
```

**Parse the subagent response:**

1. Extract the JSON from the response (handle cases where the agent wraps JSON in markdown code fences)
2. Validate the response structure:
   - `reviews` array must be present and non-empty
   - Each review must have `claim_id`, `reviewer_assessment`, `reasoning`, `agrees_with_original`
   - `reviewer_assessment` must be one of: `confirmed`, `partial`, `unconfirmed`, `contradicted`
3. Verify completeness: every claim_id from the input payload must appear in the response
4. If any claims are missing from the response, log a warning and mark them as `unconfirmed` with reasoning: "Verification agent did not produce an assessment for this claim."

### Step 6.3 — Dispute Detection and Fix-Verify Loop

**Detect disputes:**

For each reviewed claim, compare the reviewer's assessment with the original `verification_status`:

| Original status | Reviewer assessment | Dispute? |
|----------------|--------------------|---------:|
| `verified` | `confirmed` | No |
| `verified` | `partial` | **Yes** |
| `verified` | `unconfirmed` | **Yes** |
| `verified` | `contradicted` | **Yes** |
| `partially_verified` | `confirmed` | No (upgrade) |
| `partially_verified` | `partial` | No |
| `partially_verified` | `unconfirmed` | **Yes** |
| `partially_verified` | `contradicted` | **Yes** |
| `unverified` | `confirmed` | **Yes** (Phase 3 may have missed evidence) |
| `unverified` | `partial` | **Yes** |
| `unverified` | `unconfirmed` | No |
| `unverified` | `contradicted` | No |

A dispute occurs when `agrees_with_original == false` AND the status mapping above indicates disagreement. The explicit `agrees_with_original` field takes precedence — if the reviewer says they agree despite a status difference (e.g., they consider "partial" close enough to "verified"), it is NOT a dispute.

**Fix-verify loop:**

> **Pre-condition:** The fix-verify loop requires `DIFFMAP_AVAILABLE=true` (set in Step 6.0). If `DIFFMAP_AVAILABLE=false`, skip the loop entirely — mark all disputed claims as unresolved and set `verification_status = "partial"` with a note: "Fix-verify loop skipped — repository context unavailable (diff-map.json missing or invalid)."

```
IF DIFFMAP_AVAILABLE == false AND DISPUTES is non-empty:
  Print: "⚠️  Skipping fix-verify loop — diff-map.json unavailable. <len(DISPUTES)> disputes remain unresolved."
  Mark verification_status = "partial"
  SKIP to Step 6.4

DISPUTES = [claims where dispute == true]
ROUND = 0
MAX_ROUNDS = 3
ALL_REVIEWS = <initial reviews from Step 6.2>

LOOP:
  IF DISPUTES is empty:
    BREAK — all claims verified or agreed upon

  IF ROUND >= MAX_ROUNDS:
    Print: "⚠️  Fix-verify loop cap reached (3 rounds). <len(DISPUTES)> unresolved disputes remain."
    FOR each unresolved dispute:
      Print: "  - <claim_id>: Phase 3 says <original_status>, reviewer says <reviewer_assessment>"
    Mark verification_status = "partial"
    BREAK

  ROUND += 1

  Print: "Fix-verify round <ROUND>/<MAX_ROUNDS>: <len(DISPUTES)> disputes to resolve"

  ## Phase 3 Recheck
  For each disputed claim:
    - Re-read the claim and evidence from analysis.json
    - Fetch broader context from the code at <clone_path> (from diff-map.json):
      expand the file search to include files in the same directory as existing
      evidence, and files matching additional keywords from the claim text
    - Re-assess the verification_status with the new evidence

  Dispatch recheck via Agent tool:

    "You are the Implementation Analyst performing a targeted recheck.

    The following claims had their evidence challenged by an independent reviewer.
    For each claim, the reviewer's concern is provided. Your job is to search for
    additional evidence that addresses the reviewer's specific concern.

    ## Context
    - Session directory: <SESSION_DIR>
    - Repository clone: <clone_path> (from diff-map.json)
    - Diff range: <BASE_SHA>..<HEAD_SHA>

    Use Bash and Read to search for additional evidence in the repository clone directory.

    Claims to recheck:
    <For each disputed claim: claim_id, claim_text, original evidence,
     reviewer's assessment, reviewer's reasoning>

    For each claim:
    1. Consider the reviewer's specific objection.
    2. Search the repository clone at <clone_path> for additional evidence:
       - Look in the same directories as existing evidence files
       - Search for files matching keywords from the claim text
       - Use git diff <BASE_SHA>..<HEAD_SHA> with broader file patterns
    3. Determine if there is additional evidence that addresses the concern.
    4. Provide an updated verification_status and explanation.

    Output as JSON array:
    [{
      'claim_id': '<id>',
      'updated_status': 'verified | partially_verified | unverified',
      'recheck_notes': '<what you found that addresses or fails to address the concern>'
    }]"

  ## Re-verify with new subagent
  For each rechecked claim, assemble updated payload containing:
    - Original claim data (claim_id, claim_text, category)
    - Original evidence from analysis.json
    - The recheck subagent's recheck_notes as a "recheck_context" field
    - The recheck subagent's updated_status
  Dispatch a NEW Agent subagent with the same verification prompt from Step 6.2,
  but only for the disputed claims, and with the recheck_context appended to each
  claim's data so the reviewer can see what Phase 3 found on recheck.

  Parse the new reviewer response.

  ## Check resolution
  For each dispute:
    IF new reviewer agrees with updated status:
      Mark dispute as resolved
      Record round details in reviews[].rounds[]
    ELSE:
      Dispute persists — will be retried in next round (if rounds remain)

  Update DISPUTES = [still-unresolved disputes]

  GOTO LOOP
```

### Step 6.4 — Build verification-report.json

Assemble the `verification-report.json` artifact following the schema from [Artifact Schemas > verification-report.json](#verification-reportjson):

```json
{
  "schema_version": 1,
  "generated_at": "<ISO 8601 timestamp>",
  "verification_status": "<verified | partial>",
  "total_rounds": <ROUND>,
  "claims_reviewed": <number of claims sent to verification>,
  "claims_total": <TOTAL_CLAIMS>,
  "selection_criteria": "top <N> by significance (security > consensus > feature > parameter)",
  "reviews": [
    <merged review data with round history for each claim>
  ],
  "reviewer_concerns": [
    <concerns from the initial and any subsequent verification rounds>
  ],
  "summary": {
    "confirmed": <count>,
    "partial": <count>,
    "unconfirmed": <count>,
    "contradicted": <count>,
    "disputes_found": <count>,
    "disputes_resolved": <count>,
    "disputes_unresolved": <count>
  }
}
```

**Determine `verification_status`:**
- `"verified"`: No unresolved disputes remain (all disputes resolved or no disputes were found)
- `"partial"`: At least one dispute remains unresolved after max rounds

**Compute summary counts:** Count from the **initial** `reviewer_assessment` for each review (before any round resolution). `confirmed` = count where `reviews[].reviewer_assessment == "confirmed"`, `partial` = count where initial assessment == `"partial"`, `unconfirmed` = count where initial assessment == `"unconfirmed"`, `contradicted` = count where initial assessment == `"contradicted"`. Round resolution changes are tracked in `reviews[].rounds[]` only — they do not update summary counts.

**Write to:** `{session_dir}/verification-report.json`

### Step 6.5 — Generate verification-report.md

Generate a human-readable markdown report from the structured JSON data.

**File:** `{session_dir}/verification-report.md`

**Template:**

```markdown
# Verification Report

**Generated:** <ISO 8601 timestamp>
**Status:** <verification_status> (<"All reviewed claims verified" | "N unresolved disputes">)
**Claims reviewed:** <N> / <total> (selection: top by significance)
**Fix-verify rounds:** <total_rounds>

## Summary

| Metric | Count |
|--------|-------|
| Confirmed | <N> |
| Partial | <N> |
| Unconfirmed | <N> |
| Contradicted | <N> |
| Disputes found | <N> |
| Disputes resolved | <N> |
| Disputes unresolved | <N> |

## Per-Claim Verification

### <claim_id>: <claim_text (truncated to 80 chars)>

- **Category:** <category>
- **Original assessment:** <original_status>
- **Reviewer assessment:** <reviewer_assessment_emoji> <reviewer_assessment>
- **Agreement:** <✅ Agrees | ❌ Disagrees>
- **Reasoning:** <reasoning>

<if dispute:>
#### Dispute Resolution

<for each round:>
**Round <N>:**
- Recheck: <recheck_notes>
- Updated status: <updated_status>
- Reviewer reassessment: <reviewer_reassessment>
- Resolved: <✅ Yes | ❌ No>

<end for>
<end if>

---

<repeat for each claim>

## Reviewer Concerns

<if reviewer_concerns is non-empty:>
<for each concern:>
- **[<severity>]** <description>
  - Affected claims: <affected_claims as comma-separated list>
<end for>
<else:>
No additional concerns raised.
<end if>
```

**Write to:** `{session_dir}/verification-report.md`

### Step 6.6 — Self-Validation Gate

Before presenting to the user, validate `verification-report.json` against the schema.

Validation checks:

1. `schema_version` equals `1`
2. `generated_at` is a valid ISO 8601 timestamp
3. `verification_status` is one of: `verified`, `partial`
4. `total_rounds` is a number between 0 and 3
5. `reviews` array is non-empty
6. Each review has non-null `claim_id`, `original_status`, `reviewer_assessment`, `reasoning`, `agrees_with_original`, `dispute`
7. `reviewer_assessment` must be one of: `confirmed`, `partial`, `unconfirmed`, `contradicted`
8. Each review's `rounds` is an array (may be empty)
9. Each round (if present) has non-null `round`, `recheck_notes`, `updated_status`, `reviewer_reassessment`, `resolved`
10. `reviewer_concerns` must be present (may be empty array)
11. Each concern (if present) has non-null `severity`, `description`, `affected_claims`
12. `summary` must be present with all required sub-fields
13. `summary.confirmed + summary.partial + summary.unconfirmed + summary.contradicted` must equal `len(reviews)`
14. `summary.disputes_resolved + summary.disputes_unresolved` must equal `summary.disputes_found`

**On validation failure:**

```
❌ Validation failed: verification-report.json
   Field: <field_name>
   Error: <missing | null | empty array | wrong type | invalid enum value>
   Phase 6 self-validation failed. Attempting auto-fix...
```

Auto-fix attempt: Recalculate summary statistics from the reviews data. If structural issues exist (missing fields in reviews), re-dispatch the verification agent for the affected claims. If the second attempt also fails validation, abort Phase 6 with the error.

### Step 6.7 — User Checkpoint 🧑

Present the verification results to the user for confirmation. This is a mandatory checkpoint.

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔎 Phase 6 Complete — Independent Verification

Status:     <verification_status> (<"All reviewed claims verified" | "N unresolved disputes">)
Claims reviewed:  <N> / <total>
Fix-verify rounds: <total_rounds>

Verification Summary:
  Confirmed:      <N> ✅
  Partial:        <N> ⚠️
  Unconfirmed:    <N> ❌
  Contradicted:   <N> 🔴

Disputes:
  Found:          <N>
  Resolved:       <N> ✅
  Unresolved:     <N> ❌

Per-Claim Results:
| # | Claim (truncated) | Original | Reviewer | Agreement |
|---|-------------------|----------|----------|-----------|
| 1 | <claim text, 50 chars> | ✅ verified | ✅ confirmed | ✅ |
| 2 | <claim text, 50 chars> | ✅ verified | ⚠️ partial | ❌ dispute |
| ... | ... | ... | ... | ... |

<if reviewer_concerns is non-empty:>
Reviewer Concerns:
  <for each: [severity] description>
<end if>

<if unresolved disputes exist:>
⚠️  Unresolved disputes — both Phase 3 and reviewer assessments are preserved.
    The report will present both perspectives for human judgment.
<end if>

Artifacts saved:
  • {session_dir}/verification-report.json
  • {session_dir}/verification-report.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Use AskUserQuestion:
  question: "Does the verification look correct? Ready to proceed to report generation?"
  options:
    - "Looks good — proceed to report generation"
    - "Re-verify specific claims" (user identifies claims to re-run through verification)
    - "Override verification results" (user manually sets reviewer_assessment for specific claims)
    - "Abort pipeline"
```

If the user requests re-verification:
1. For each flagged claim, re-dispatch the verification agent with broader context
2. Merge updated results into `verification-report.json`
3. Re-validate and re-display

If the user overrides verification results:
1. Update the specified claims' `reviewer_assessment` in `verification-report.json`
2. Set `agrees_with_original` accordingly
3. Re-evaluate `dispute` status and `verification_status`
4. Recalculate summary statistics
5. Re-validate and save

If the user selects "Looks good — proceed to report generation":
1. Run Phase 4 (Cross-Reference Analysis) — this is non-interactive and runs automatically.
2. Proceed to Phase 5 (Report Generation).

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/verification-report.json
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/verification-report.md
```

---

## Phase 4: Cross-Reference Analysis

> **Implemented by:** WHI-233

Phase 4 queries the knowledge index for prior analyses on the same chain, same repo, or related chains, and compares them against the current analysis. This is the "research compound interest" mechanism — each new analysis builds on previous findings to detect cross-version evolution patterns.

Phase 4 runs after Phase 6 (verification) and before Phase 5 (report generation). When the knowledge index is empty or contains no relevant entries, Phase 4 outputs an empty comparison.json and logs a skip message — the pipeline continues normally.

**Agent role:** `comparison_agent` (see [Agent Roles > comparison_agent](#4-comparison_agent-phase-4--m2))

### Step 4.0 — Input Validation

Phase 4 requires `analysis.json` from Phase 3 and the knowledge index from `~/.gstack/research/research-index.jsonl`.

**Recovering `session_dir`:** Phase 4 runs in the same session as Phases 1-3/6. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Validate analysis.json:**

```
ANALYSIS_FILE = "{session_dir}/analysis.json"
IF analysis.json does not exist OR is not valid JSON:
  Log warning: "⚠️  analysis.json not found or corrupt — Phase 4 will produce empty comparison"
  ANALYSIS_AVAILABLE = false
ELSE:
  Run schema validation (same rules as Phase 3 output validation)
  IF validation fails:
    Log warning: "⚠️  analysis.json fails validation — proceeding with available data"
  ANALYSIS_AVAILABLE = true
```

**Validate claims.json (needed for claim text and category in comparison prompt):**

```
CLAIMS_FILE = "{session_dir}/claims.json"
IF claims.json does not exist OR is not valid JSON:
  Log warning: "⚠️  claims.json not found — comparison prompt will use claim IDs only (no text/category)"
  CLAIMS_AVAILABLE = false
ELSE:
  CLAIMS_AVAILABLE = true
  claims_list = claims.claims  // array of claim objects with id, text, category, confidence
```

**Check knowledge index:**

```bash
INDEX_FILE="$HOME/.gstack/research/research-index.jsonl"
if [ ! -f "$INDEX_FILE" ]; then
  echo "ℹ️  Knowledge index not found at $INDEX_FILE — no prior research to compare"
  INDEX_AVAILABLE=false
  INDEX_ENTRIES=0
else
  INDEX_ENTRIES=$(wc -l < "$INDEX_FILE" | tr -d ' ')
  echo "Knowledge index: $INDEX_FILE ($INDEX_ENTRIES entries)"
  INDEX_AVAILABLE=true
fi
```

**Early exit guards:**

Before proceeding to Step 4.1, check whether both required data sources are available:

```
IF NOT INDEX_AVAILABLE:
  Log: "ℹ️  Knowledge index not found — skipping comparison, writing empty comparison.json"
  → Jump to Step 4.4 (write empty comparison.json)

IF NOT ANALYSIS_AVAILABLE:
  Log: "⚠️  analysis.json unavailable — skipping comparison, writing empty comparison.json"
  → Jump to Step 4.4 (write empty comparison.json)
```

### Step 4.1 — Query Knowledge Index

Read the knowledge index and filter for relevant entries. Use three query dimensions:

**Chain association mapping (hardcoded):**

```
CHAIN_ASSOCIATIONS = {
  "base":      ["optimism"],
  "optimism":  ["base"],
  "arbitrum":  ["nitro"],
  "nitro":     ["arbitrum"],
  "polygon":   ["zkevm"],
  "zkevm":     ["polygon"]
}
```

**Query dimensions:**

1. **Same chain:** entries where `public.chain` matches the current chain (case-insensitive)
2. **Same repo:** entries where `internal.repo` matches the current repo (normalized, case-insensitive)
3. **Related chain:** entries where `public.chain` is in `CHAIN_ASSOCIATIONS[current_chain]`

**Reading the index with malformed line handling:**

```
relevant_entries = []
current_chain = <lowercase chain from session>
current_repo = <normalized repo from diff-map.json, or "[UNAVAILABLE]">
related_chains = CHAIN_ASSOCIATIONS.get(current_chain, [])

# Normalize current_repo using the same rules as Phase 7 dedup key construction:
# Strip protocol prefix, git@ prefix, hostname, trailing .git, trailing /
# Result should be "org/repo" format (e.g., "base-org/base-contracts")
# See: [Artifact Schemas > research-index.jsonl > repo normalization rules]
IF current_repo != "[UNAVAILABLE]":
  current_repo = normalize_repo(current_repo)  // apply repo normalization rules

current_upgrade_lower = UPGRADE_SLUG  // UPGRADE_SLUG is already lowercase from session setup

For each line (1-indexed) in INDEX_FILE:
  TRY: parse line as JSON
  CATCH (malformed JSON):
    Log: "⚠️  Malformed JSON at line <N> in research-index.jsonl — skipping."
    CONTINUE

  entry = parsed JSON
  entry_chain = entry.public.chain (lowercase)
  entry_repo = entry.internal.repo (lowercase)

  # Skip the current analysis if it's already indexed (same dedup_key)
  current_dedup_key = "{current_chain}:{current_upgrade_lower}:{current_repo}"
  IF entry.dedup_key == current_dedup_key:
    CONTINUE  # don't compare against self

  match = false
  match_reason = []

  IF entry_chain == current_chain:
    match = true
    match_reason.append("same_chain")

  IF current_repo != "[UNAVAILABLE]" AND entry_repo == current_repo.lowercase:
    match = true
    match_reason.append("same_repo")

  IF entry_chain IN related_chains:
    match = true
    match_reason.append("related_chain")

  IF match:
    relevant_entries.append({
      "entry": entry,
      "match_reasons": match_reason
    })
```

**Limit to most recent 5 entries** (sorted by `public.generated_at` descending):

```
relevant_entries.sort(by: entry.public.generated_at, descending)
relevant_entries = relevant_entries[:5]
```

**If no relevant entries found:**

```
IF len(relevant_entries) == 0:
  Log: "ℹ️  No prior research found for chain '{current_chain}' or related chains — skipping comparison"
  → Jump to Step 4.4 (write empty comparison.json)
```

### Step 4.2 — Compare Current Analysis Against Historical Entries

Dispatch the `comparison_agent` via the Agent tool for the actual comparison work.

**Comparison prompt:**

```
You are the Cross-Reference Analyst. Your job is to compare the current upgrade
analysis against prior research on related chains and versions, identifying
patterns, regressions, and novel changes.

## Current Analysis

Chain: <current_chain>
Upgrade: <current_upgrade>
Repo: <current_repo>
Session: <session_dir relative path>

### Current Claims Summary
Total claims: <analysis_summary.total_claims>
Verified: <analysis_summary.verified>
Partially verified: <analysis_summary.partially_verified>
Unverified: <analysis_summary.unverified>

### Current Claims (compact)
<Build a merged claims list by joining claims.json on claim_id with analysis.claims_analyzed:>
<For each claim in claims_list (from claims.json), find matching entry in analysis.claims_analyzed where entry.claim_id == claim.id:>
- [<claim.id>] <claim.text, first 100 chars> | category: <claim.category> | status: <matched_entry.verification_status or "not_analyzed">
<end for>
<If CLAIMS_AVAILABLE is false, fall back to analysis.claims_analyzed only:>
<For each entry in analysis.claims_analyzed:>
- [<entry.claim_id>] [text unavailable] | status: <entry.verification_status>
<end for>

### Current Unreported Changes
<For each change in analysis.unreported_changes:>
- <file>: <description> (significance: <significance>)
<end for>

## Historical Analyses (from knowledge index)

<For each entry in relevant_entries:>
### Entry: <entry.public.chain> — <entry.public.upgrade_name>
Match reasons: <match_reasons as comma-separated>
Generated: <entry.public.generated_at>
Repo: <entry.internal.repo>
Executive summary: <entry.public.executive_summary>
Claims summary: <entry.public.claims_summary as JSON>
Historical claims:
<For each claim in entry.internal.full_claims:>
- [<claim.id>] <claim.text, first 100 chars> | category: <claim.category> | status: <claim.verification_status>
<end for>
<end for>

## Instructions

Compare the current analysis against each historical entry. Produce a JSON
object with the following structure. Output ONLY valid JSON — no markdown
fences, no commentary.

{
  "novel_features": [
    // Features in the current upgrade that do NOT appear in any historical analysis.
    // Each: { "name": string, "description": string, "files": [string], "significance": "high"|"medium"|"low" }
  ],
  "borrowed_features": [
    // Features that clearly correspond to something seen in a historical analysis.
    // Each: { "name": string, "description": string, "source_chain": string, "similarity": "identical"|"structural"|"conceptual", "files": [string] }
  ],
  "divergent_features": [
    // Features where the current upgrade takes a different approach than historical analyses.
    // Each: { "name": string, "description": string, "chains_compared": [string], "impact": string }
  ]
}

Rules:
- Compare at claim/category level — NOT deep code comparison
- "files" arrays should reference file paths from the current analysis claims or unreported changes
- If a feature appears in both current and historical but with different behavior, it's divergent
- If a feature appears in current but NOT in any historical, it's novel
- If a feature clearly maps to a historical feature, it's borrowed
- Significance for novel_features: "high" = security/consensus, "medium" = feature/architecture, "low" = parameter/config
- If a feature appears in historical analyses but NOT in the current upgrade, classify it as divergent with impact describing the removal or consolidation (e.g., "Previously present in <chain>; not found in current upgrade — possible removal or consolidation")
- Empty arrays are valid — not every comparison has all three categories
```

**Parse the agent response:**

```
TRY: parse response as JSON
CATCH (invalid JSON):
  # Recovery: strip markdown code fences, re-parse
  stripped = remove leading/trailing ``` and any language hint
  TRY: parse stripped as JSON
  CATCH:
    Log: "⚠️  comparison_agent returned invalid JSON — writing empty comparison.json"
    → Jump to Step 4.4 (write empty comparison.json)

comparison_result = parsed JSON
```

### Step 4.3 — Validate Comparison Result

Validate the agent output before writing:

```
REQUIRED_ARRAYS = ["novel_features", "borrowed_features", "divergent_features"]
For each array_name in REQUIRED_ARRAYS:
  IF array_name NOT in comparison_result:
    comparison_result[array_name] = []
    Log: "⚠️  comparison_agent omitted '{array_name}' — defaulting to empty array"

For each item in comparison_result.novel_features:
  IF item missing "name" or "description": remove item, log warning
  IF item missing "files": set item.files = []
  IF item missing "significance" or item.significance NOT in ["high", "medium", "low"]:
    item.significance = "medium"

For each item in comparison_result.borrowed_features:
  IF item missing "name" or "description" or "source_chain": remove item, log warning
  IF item missing "files": set item.files = []
  IF item missing "similarity" or item.similarity NOT in ["identical", "structural", "conceptual"]:
    item.similarity = "conceptual"

For each item in comparison_result.divergent_features:
  IF item missing "name" or "description": remove item, log warning
  IF item missing "chains_compared": set item.chains_compared = [current_chain]
  IF item missing "impact": set item.impact = "Impact not assessed"
```

### Step 4.4 — Write comparison.json

Assemble the full comparison.json following the schema:

```
comparison_json = {
  "schema_version": 1,
  "generated_at": <current ISO 8601 timestamp>,
  "baseline": {
    "chain": current_chain,
    "upgrade": current_upgrade,
    "session_dir": <relative session dir path from ~/.gstack/research/>
  },
  "comparisons": [
    // For each entry in relevant_entries:
    {
      "chain": entry.public.chain,
      "upgrade": entry.public.upgrade_name,
      "session_dir": <extract from entry.internal.evidence_map_path, parent dir>,
      "index_entry_date": entry.public.generated_at
    }
  ],
  "novel_features": comparison_result.novel_features,    // or [] if no comparison ran
  "borrowed_features": comparison_result.borrowed_features, // or [] if no comparison ran
  "divergent_features": comparison_result.divergent_features // or [] if no comparison ran
}
```

**Empty comparison case** (no relevant entries found or agent failed):

When `relevant_entries` is empty or the agent returned invalid output, write a minimal comparison.json:

```json
{
  "schema_version": 1,
  "generated_at": "<current ISO 8601 timestamp>",
  "baseline": {
    "chain": "<current_chain>",
    "upgrade": "<current_upgrade>",
    "session_dir": "<relative session dir>"
  },
  "comparisons": [],
  "novel_features": [],
  "borrowed_features": [],
  "divergent_features": []
}
```

> **Note:** An empty `comparisons` array is valid and signals to Phase 5 that no historical data was available — the Cross-Chain Comparison report section will be omitted.

Write to disk:

```bash
# Write comparison.json using the Write tool
# File: {session_dir}/comparison.json
```

### Step 4.5 — Summary Output

Print the Phase 4 summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 Phase 4 Complete — Cross-Reference Analysis

Session:    {session_dir}
Index:      <INDEX_ENTRIES> entries in knowledge index
Relevant:   <len(relevant_entries)> entries matched

<if relevant_entries is empty:>
  ℹ️  No prior research found — comparison.json written with empty arrays

<else:>
  Compared against:
  <for each entry in relevant_entries:>
    - <entry.public.chain> / <entry.public.upgrade_name> (<match_reasons>)
  <end for>

  Novel features:    <count> items
  Borrowed features: <count> items
  Divergent features: <count> items

<end if>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Per-Phase Error Handling

| Failure Scenario | Recovery Action |
|-----------------|-----------------|
| analysis.json missing/corrupt | Produce empty comparison.json, log warning, continue to Phase 5 |
| Knowledge index missing | Produce empty comparison.json, log "no prior research found", continue |
| Knowledge index has malformed lines | Skip malformed lines with warning, process valid lines |
| comparison_agent returns invalid JSON | Strip markdown fences, retry parse. If still invalid, produce empty comparison.json |
| comparison_agent omits required arrays | Default to empty arrays |
| No relevant entries in index | Produce empty comparison.json (comparisons=[]), continue |

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/comparison.json
```

---

## Phase 5: Report Generation

> **Implemented by:** WHI-232

Phase 5 synthesizes all upstream artifacts into a structured internal technical report. This is the M1 terminal phase — the report is the primary deliverable that answers "is this tool useful for researchers?"

**Agent role:** `report_generation_agent` (see [Agent Roles > report_generation_agent](#5-report_generation_agent-phase-5))

### Step 5.0 — Input Validation and Graceful Degradation (D9)

Phase 5 is the pipeline's endpoint and must handle partial upstream failures. Unlike Phases 2-3 which abort on invalid input, Phase 5 generates a **partial report** when artifacts are missing or malformed, annotating each missing section with `[DATA UNAVAILABLE]`.

**Recovering `session_dir`:** Phase 5 runs in the same session as Phases 1-3, 4, and 6. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Artifact availability check:**

For each upstream artifact, attempt to load and validate. Track availability status:

```
ARTIFACTS_STATUS = {}

For each artifact in [claims.json, diff-map.json, analysis.json, comparison.json, verification-report.json]:
  1. Check file exists: {session_dir}/<artifact>
  2. If exists: parse JSON, run schema validation (same rules as Phase 3 Step 3.0 / Phase 6 Step 6.6)
  3. Record status:
     - "available": file exists AND passes validation
     - "partial": file exists but fails some validation checks (use what's valid)
     - "missing": file does not exist
     - "corrupt": file exists but is not valid JSON
```

**Per-artifact degradation behavior:**

| Artifact | Status | Report Behavior |
|----------|--------|-----------------|
| `claims.json` | available | Full Claims Analysis section |
| `claims.json` | missing/corrupt | Claims Analysis section shows `[DATA UNAVAILABLE — claims.json not found or corrupt. Phase 1 may not have run.]` |
| `diff-map.json` | available | Full metadata header (repo, SHAs), Unclaimed Changes section uses file data |
| `diff-map.json` | missing/corrupt | Metadata header shows `[DATA UNAVAILABLE]` for repo/SHA fields. Unclaimed Changes section degraded. |
| `analysis.json` | available | Full Claims Analysis with verification status, evidence, code snippets. Full Unclaimed Changes. |
| `analysis.json` | missing/corrupt | Claims listed without verification status (`[ANALYSIS UNAVAILABLE]`). Unclaimed Changes section shows `[DATA UNAVAILABLE]`. |
| `analysis.json` | partial — `claims_analyzed` valid, `unreported_changes` missing | Claims Analysis section uses available verification data normally. Unclaimed Changes section shows `[DATA UNAVAILABLE — unreported_changes field missing from analysis.json]`. |
| `analysis.json` | partial — `claims_analyzed` missing, `unreported_changes` valid | Claims listed without verification status (`[ANALYSIS UNAVAILABLE]`). Unclaimed Changes section uses available data normally. |
| `analysis.json` | partial — other validation failures | Use all parseable fields; mark each invalid/missing sub-section with `[DATA UNAVAILABLE]` and note the specific validation failure. |
| `verification-report.json` | available | Add "Independent Verification" section to report with per-claim reviewer assessments, disputes, and concerns |
| `verification-report.json` | missing | Omit "Independent Verification" section entirely (Phase 6 is optional — M1 pipelines won't have this artifact) |
| `verification-report.json` | corrupt/partial | Add "Independent Verification" section with `[DATA PARTIALLY AVAILABLE]` markers for corrupt fields; use whatever is parseable |
| `comparison.json` | available with non-empty `comparisons` | Add "Cross-Chain Comparison" section with novel, borrowed, and divergent features from Phase 4 |
| `comparison.json` | available with empty `comparisons` | Omit "Cross-Chain Comparison" section (no historical data was available for comparison) |
| `comparison.json` | missing | Omit "Cross-Chain Comparison" section entirely (Phase 4 may not have run or knowledge index was empty) |
| `comparison.json` | corrupt/partial | Add "Cross-Chain Comparison" section with `[DATA PARTIALLY AVAILABLE]` markers; use whatever is parseable |

**If ALL three required artifacts** (`claims.json`, `diff-map.json`, `analysis.json`) **are missing or corrupt (no required artifact has status "available" or "partial"):** abort Phase 5 with:
```
❌ Phase 5 aborted: No usable upstream artifacts found in {session_dir}.
   Expected: claims.json, diff-map.json, analysis.json
   Status: claims.json=<status>, diff-map.json=<status>, analysis.json=<status>
   At least one artifact must be loadable to generate a report.
   Run Phases 1-3 first.
```

**If at least one artifact has status "available" or "partial":** proceed with partial report generation. Print a warning:
```
⚠️  Partial artifacts detected:
   claims.json:   <status>
   diff-map.json: <status>
   analysis.json: <status>
   
   Report will be generated with available data. Missing sections will be marked [DATA UNAVAILABLE].
```

### Step 5.1 — Extract Report Data

Load validated data from available artifacts into working variables.

**From `claims.json` (if available):**
```
source_url = claims.source_url
fetched_at = claims.fetched_at
claims_list = claims.claims  // array of claim objects
```

**From `diff-map.json` (if available):**
```
repo_url = diff_map.repo
base_sha = diff_map.base_sha
head_sha = diff_map.head_sha
base_ref = diff_map.base_ref
head_ref = diff_map.head_ref
clone_path = diff_map.clone_path
total_files = diff_map.summary.total_files
total_lines_changed = diff_map.summary.total_lines_changed
```

**From `analysis.json` (if available):**
```
claims_analyzed = analysis.claims_analyzed  // array with verification results
unreported_changes = analysis.unreported_changes  // array of code-first delta findings
analysis_summary = analysis.summary  // aggregate stats
```

**From `verification-report.json` (if available — Phase 6 M2 only):**
```
verification_status = verification.verification_status  // "verified" or "partial"
verification_reviews = verification.reviews  // per-claim reviewer assessments
reviewer_concerns = verification.reviewer_concerns  // general concerns
verification_summary = verification.summary  // aggregate verification stats
total_rounds = verification.total_rounds  // fix-verify rounds executed
```

**From `comparison.json` (if available — Phase 4 M2):**
```
comparison_baseline = comparison.baseline  // current analysis metadata
comparison_entries = comparison.comparisons  // prior analyses compared against
novel_features = comparison.novel_features  // features unique to current upgrade
borrowed_features = comparison.borrowed_features  // features seen in prior analyses
divergent_features = comparison.divergent_features  // features that differ across chains

COMPARISON_HAS_DATA = len(comparison_entries) > 0
// When comparisons is empty, the knowledge index had no relevant entries — omit cross-chain section
```

**Cross-reference claims with analysis and verification:** If `claims.json`, `analysis.json`, and optionally `verification-report.json` are available, join claims with their analysis and verification results by `claim_id`:

```
For each claim in claims_list:
  Find matching entry in claims_analyzed where claim_id == claim.id
  IF match found:
    Merge: claim text + category + confidence FROM claims.json
           verification_status + evidence + code_snippets + analysis_notes FROM analysis.json
    IF verification_reviews is available:
      Find matching review in verification_reviews where claim_id == claim.id
      IF match found:
        Add: reviewer_assessment, reasoning, agrees_with_original, dispute, rounds FROM verification-report.json
  IF no match found (claim exists in claims.json but not in analysis.json):
    Set verification_status = "not_analyzed"
    Set analysis_notes = "This claim has no corresponding entry in analysis.json. Phase 3 may not have processed it."
    Log warning: "⚠️  Claim <claim.id> has no analysis entry — marking as not_analyzed"

After join, check for orphaned analysis entries:
  For each entry in claims_analyzed:
    IF entry.claim_id does NOT match any claim.id in claims_list:
      Log warning: "⚠️  analysis.json contains entry for <claim_id> which does not exist in claims.json — skipping (stale analysis)"
      Do NOT include orphaned entries in the report
```

### Step 5.2 — Generate Internal Report (D15)

Dispatch the `report_generation_agent` via the Agent tool to synthesize the report content.

**Report generation prompt:**

```
You are the Research Report Compiler. Your job is to synthesize all analysis
artifacts into a clear, well-structured internal technical report that a
blockchain researcher can act on.

## Input Data

### Metadata
- Repo URL: <repo_url or "[DATA UNAVAILABLE]">
- Base ref: <base_ref> (<base_sha or "[DATA UNAVAILABLE]">)
- Head ref: <head_ref> (<head_sha or "[DATA UNAVAILABLE]">)
- Source URL: <source_url or "[DATA UNAVAILABLE]">
- Analysis timestamp: <current ISO 8601 timestamp>

### Claims (<N total> or "[DATA UNAVAILABLE]")
<JSON array of merged claim+analysis objects, or "[DATA UNAVAILABLE]">

### Unreported Changes (<N total> or "[DATA UNAVAILABLE]")
<JSON array of unreported_changes, or "[DATA UNAVAILABLE]">

### Verification Data (if Phase 6 was executed, otherwise "[NOT AVAILABLE]")
<verification_status, verification_reviews, reviewer_concerns, verification_summary, or "[NOT AVAILABLE]">

### Cross-Chain Comparison Data (if Phase 4 produced data, otherwise "[NOT AVAILABLE]")
<if COMPARISON_HAS_DATA:>
Compared against: <comparison_entries as JSON>
Novel features: <novel_features as JSON>
Borrowed features: <borrowed_features as JSON>
Divergent features: <divergent_features as JSON>
<else:>
[NOT AVAILABLE — no prior research in knowledge index]
<end if>

### Diff Summary
<diff-map summary stats, or "[DATA UNAVAILABLE]">

## Report Template

Generate the report in the following structure. For any section where the
input data is marked [DATA UNAVAILABLE], include the section heading but
replace the content with "[DATA UNAVAILABLE — <reason>]".

---

# Protocol Upgrade Analysis: <upgrade_name>

**Repo:** <repo_url>
**Commits:** <base_sha>..<head_sha>
**Source:** <source_url>
**Generated:** <ISO 8601 timestamp>
**Pipeline:** harness-research-engineering v1 (<"M2" if verification-report.json available OR comparison.json available with non-empty comparisons, else "M1">)
**Artifacts:** <list which artifacts were available vs missing>

## Executive Summary

Write 2-3 paragraphs covering:
- What the upgrade does (high-level, based on claims)
- Key findings: how many claims were verified vs unverified
- Notable unreported changes (if any high-significance ones exist)
- Overall assessment: how well does the announcement match the code?

## Claims Analysis

For each claim, output a subsection:

### Claim <N>: <claim_text>
- **Category:** <category>
- **Source confidence:** <confidence>
- **Status:** <status_emoji> <verification_status>
  - ✅ Confirmed = verified
  - ⚠️ Partial = partially_verified
  - ❌ Unconfirmed = unverified
  - 🔴 Contradicted = (if analysis_notes indicate contradiction)
- **Evidence:**
  <For each evidence item: file:lines — description>
- **Code:**
  <If code_snippets exist, include the most relevant snippet (fenced code block with file path and line range)>
- **Notes:** <analysis_notes>
- **Verification:** <if claim was in top-10 and reviewed: reviewer_assessment_emoji reviewer_assessment — reasoning (truncated to 80 chars) [✅ Agrees | ❌ Disputes]> <if claim was not in top-10: "(not reviewed — outside top 10 by significance)"> <if Phase 6 was not executed: omit this field entirely>

If claims data is unavailable: "[DATA UNAVAILABLE — claims.json was not found or could not be parsed. Phase 1 (Source Ingestion) may not have completed.]"

## Unclaimed Changes

List all unreported changes from the code-first delta pass, ordered by
significance (high → medium → low):

For each change:
- **File:** <file path>
- **Change:** <description>
- **Significance:** <emoji> <level>
  - 🔴 High
  - 🟡 Medium  
  - 🟢 Low
- **Suggested category:** <potential_category>

If unreported_changes data is unavailable: "[DATA UNAVAILABLE — analysis.json was not found or the code-first delta pass did not complete.]"

## Independent Verification

<if verification-report.json is available:>

**Status:** <verification_status> (<"All reviewed claims verified" | "N unresolved disputes">)
**Claims reviewed:** <claims_reviewed> / <claims_total>
**Fix-verify rounds:** <total_rounds>

For each reviewed claim, add a verification note to the claim's section in Claims Analysis above,
AND list a summary here:

| Claim | Original | Reviewer | Agreement | Notes |
|-------|----------|----------|-----------|-------|
| <claim_id> | <original_status> | <reviewer_assessment> | <✅/❌> | <reasoning, truncated> |

### Reviewer Concerns

<for each concern: severity, description, affected claims>

### Unresolved Disputes

<for each unresolved dispute: claim_id, both assessments, round history summary>

<else:>
[Phase 6 (Independent Verification) was not executed for this analysis. Claims Analysis reflects Phase 3 assessments only.]
<end if>

## Cross-Chain Comparison

<if comparison.json is available AND COMPARISON_HAS_DATA:>

**Compared against:** <count> prior analyses
<for each entry in comparison_entries:>
- <chain> / <upgrade> (indexed: <index_entry_date>)
<end for>

### Novel Features

Features in this upgrade not found in any prior analysis:

<for each feature in novel_features:>
- **<name>** (<significance>) — <description>
  Files: <files as comma-separated>
<end for>
<if novel_features is empty:> No novel features identified. <end if>

### Borrowed Features

Features that correspond to prior analyses on related chains:

<for each feature in borrowed_features:>
- **<name>** — <description>
  Source: <source_chain> | Similarity: <similarity>
  Files: <files as comma-separated>
<end for>
<if borrowed_features is empty:> No borrowed features identified. <end if>

### Divergent Features

Features where this upgrade takes a different approach than prior analyses:

<for each feature in divergent_features:>
- **<name>** — <description>
  Chains compared: <chains_compared as comma-separated>
  Impact: <impact>
<end for>
<if divergent_features is empty:> No divergent features identified. <end if>

<else:>
[Phase 4 (Cross-Chain Comparison) was not executed or no prior research was available for comparison.]
<end if>

## Methodology

Document the pipeline execution:
- Pipeline version: harness-research-engineering v1 (<"M2" if Phase 6 was executed OR Phase 4 produced non-empty comparisons, else "M1">)
- Phases executed: <list which phases ran successfully>
- Artifacts status: <for each artifact, state available/partial/missing>
- Errors or skipped steps: <document any degradation>
- Source fetch method: <webfetch/websearch/user_paste or unknown>
- Clone method: <treeless/shallow/reused/local or unknown>

## Raw Data References

- Session directory: <session_dir>
- Claims: <session_dir>/claims.json
- Diff map: <session_dir>/diff-map.json
- Analysis: <session_dir>/analysis.json
- Comparison: <session_dir>/comparison.json (if Phase 4 was executed)
- Verification: <session_dir>/verification-report.json (if Phase 6 was executed)
- Source snapshot: <session_dir>/source-snapshot.md

---

## Output Rules

- Begin your output IMMEDIATELY with the line: # Protocol Upgrade Analysis: <upgrade_name>
- Do NOT wrap the output in a code fence (no ``` before or after)
- Do NOT add any preamble, commentary, or explanation before the heading
- Output the FULL markdown report content — nothing else
- Use the exact section structure above
- Every claim from the input must appear in the Claims Analysis section
- Every unreported change must appear in the Unclaimed Changes section
- For [DATA UNAVAILABLE] sections, always include a brief explanation of WHY the data is missing
- Code snippets within the report should use fenced code blocks with appropriate language hints
- Keep the Executive Summary concise but substantive (not generic platitudes)
```

### Step 5.3 — Write Draft Report to Disk

**File:** `{session_dir}/internal-report.draft.md`

Write the generated report content to the **draft** path using the Write tool. The draft file is NOT the final deliverable — it is promoted to `internal-report.md` only after user approval in Step 5.5. This ensures the mandatory user checkpoint cannot be bypassed by a premature write.

### Step 5.4 — Self-Validation Gate

Validate the draft report at `{session_dir}/internal-report.draft.md` before presenting to the user.

**Validation checks:**

1. **Metadata header present:** The first non-empty line of the report must be `# Protocol Upgrade Analysis:` (prefix match). If the agent prepended commentary or a code fence, this check catches it.
2. **Required sections present:** All required sections exist as level-2 headings (exact string match at start of line) — 5 base sections, plus optional sections when Phase 6 or Phase 4 data is available:
   - `## Executive Summary`
   - `## Claims Analysis`
   - `## Unclaimed Changes`
   - `## Methodology`
   - `## Raw Data References`
   - `## Independent Verification` — check this heading ONLY if `verification-report.json` was available. Omit this check entirely if Phase 6 was not executed.
   - `## Cross-Chain Comparison` — check this heading ONLY if `comparison.json` was available AND had non-empty `comparisons` array. Omit this check entirely if Phase 4 was not executed or knowledge index was empty.
3. **No duplicate sections:** Each required level-2 heading appears exactly once. Duplicate headings indicate a splicing error.
4. **Metadata fields present:** Report contains `**Repo:**`, `**Commits:**`, `**Source:**`, `**Generated:**`
5. **Claims completeness:** If `claims.json` was available, count the number of `### Claim ` sub-headings (note trailing space — match `### Claim \d+:` pattern to avoid false positives from claim text). The count must equal the number of input claims. If any claims are missing from the report, list the missing claim IDs.
6. **No empty sections:** Each section has at least 20 characters of non-whitespace content below its heading. `[DATA UNAVAILABLE ...]` and `[Phase 6 ... was not executed ...]` markers count as valid content (they are the expected output for degraded/skipped sections).
7. **Unreported changes completeness:** If `analysis.json` was available and had `unreported_changes`, verify they appear in the report
8. **Verification completeness:** If `verification-report.json` was available, verify that the `## Independent Verification` section contains the verification summary table and reviewer concerns
9. **Comparison completeness:** If `comparison.json` was available and had non-empty `comparisons`, verify that the `## Cross-Chain Comparison` section exists and contains at least the "Novel Features", "Borrowed Features", and "Divergent Features" sub-sections

**On validation failure:**

```
❌ Report validation failed:
   <list of failures>
   Attempting regeneration of failed sections...
```

**Auto-fix strategy:** Re-dispatch the agent with a section-specific prompt that includes:
- The section heading to generate
- The relevant input data for that section only
- Instruction: "Output ONLY the content for this section, starting with the `## <heading>` line."

Then replace the content between the failed section's heading and the next `## ` heading (or end of file) with the regenerated content. If the section heading itself is missing, insert it at the correct position (maintaining the section order from the template).

If the second attempt also fails validation, proceed with the report as-is and append a validation failure note to the Methodology section:
```
### Validation Notes
The following validation checks failed and could not be auto-fixed:
- <check>: <failure description>
```

### Step 5.5 — User Checkpoint 🧑

Present the report summary to the user for confirmation. This is a mandatory checkpoint — the draft report at `{session_dir}/internal-report.draft.md` is NOT promoted to the final path until the user approves.

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📄 Phase 5 Complete — Internal Report Generated

Report:     {session_dir}/internal-report.draft.md (pending approval)
Artifacts:  <N available> / 3 total
<if any missing: list missing artifacts>

Report Structure:
  ✅ Executive Summary (<word count> words)
  <✅ or ⚠️> Claims Analysis (<N claims> / <N expected>)
  <✅ or ⚠️> Unclaimed Changes (<N changes>)
  ✅ Methodology
  ✅ Raw Data References

Claims Breakdown:
  Confirmed:    <N> ✅
  Partial:      <N> ⚠️
  Unconfirmed:  <N> ❌
  Unavailable:  <N> 🔲

Unreported Changes: <N total> (<N high> 🔴, <N medium> 🟡, <N low> 🟢)

<if verification-report.json was available:>
Independent Verification:
  Status:     <verification_status>
  Reviewed:   <N> / <total> claims
  Disputes:   <N found> → <N resolved> ✅ / <N unresolved> ❌
  Rounds:     <total_rounds>
<end if>

<if comparison.json was available AND COMPARISON_HAS_DATA:>
Cross-Chain Comparison:
  Compared:   <N> prior analyses
  Novel:      <N> features
  Borrowed:   <N> features
  Divergent:  <N> features
<end if>
```

**Claims Breakdown computation:**
- **Confirmed** = claims with `verification_status == "verified"`
- **Partial** = claims with `verification_status == "partially_verified"`
- **Unconfirmed** = claims with `verification_status == "unverified"` AND analysis.json was available (i.e., the claim was analyzed but not confirmed)
- **Unavailable** = claims with `verification_status == "not_analyzed"` (set during Step 5.1 when analysis.json was missing or when the claim had no matching entry in `claims_analyzed`)

```

<if any degradation occurred:>
⚠️  Degradation Notes:
  <list which artifacts were missing/partial and how the report adapted>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then ask:

```
Use AskUserQuestion:
  question: "Review the internal report. Should I save it as the final version?"
  options:
    - "Looks good — save and finish"
    - "I have edits" (user provides specific corrections → apply edits, re-save, re-display)
    - "Regenerate specific sections" (user identifies sections to redo → re-dispatch agent for those sections only)
    - "Abort — discard report"
```

If the user provides edits:
1. Apply the requested changes to the report content
2. Re-write `{session_dir}/internal-report.draft.md`
3. Re-validate (Step 5.4)
4. Re-display the summary

If the user requests section regeneration:
1. Ask which sections to regenerate
2. For each section, use the same auto-fix strategy as Step 5.4: dispatch the agent with a section-specific prompt containing the relevant input data and the instruction to output only that section
3. Replace the section content in the report (between heading and next `## ` heading)
4. Re-write `{session_dir}/internal-report.draft.md`
5. Re-validate (Step 5.4)
6. Re-display the summary

If the user approves:
1. Rename the draft to the final path: move `{session_dir}/internal-report.draft.md` → `{session_dir}/internal-report.md`
2. Delete the draft file if it still exists (the rename should have removed it)
3. The report at `{session_dir}/internal-report.md` is the final deliverable
4. Print confirmation and proceed to pipeline completion

If the user aborts:
1. Delete `{session_dir}/internal-report.draft.md`
2. Print: "Draft report discarded. No final report was saved."
3. The session directory retains upstream artifacts but has no `internal-report.md`

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/internal-report.md
```

### Per-Phase Error Handling Reference (D9)

The following error handling framework applies across all pipeline phases. Phase 5 is responsible for incorporating any upstream error states into the report's Methodology section.

| Phase | Failure Scenario | Recovery Action |
|-------|-----------------|-----------------|
| Phase 1 | WebFetch + WebSearch both fail | AskUserQuestion; record `fetch_method: user_paste` |
| Phase 1 | Claims extraction yields 0 claims | Warn user, ask whether to continue |
| Phase 2 | Clone timeout | Fall back to shallow clone; if still fails, request local path |
| Phase 2 | Fuzzy match returns 0 results | Show all tags, user selects manually |
| Phase 3 | A batch of claims fails processing | Skip batch, mark claims as `unverified` with `analysis_notes` indicating batch failure, continue remaining |
| Phase 4 | analysis.json missing/corrupt | Produce empty comparison.json, log warning, continue to Phase 5 |
| Phase 4 | Knowledge index missing or empty | Produce empty comparison.json, log "no prior research found", continue |
| Phase 4 | Malformed JSON lines in knowledge index | Skip malformed lines with warning, process valid lines |
| Phase 4 | comparison_agent returns invalid JSON | Strip markdown fences, retry parse. If still invalid, produce empty comparison.json |
| Phase 5 | Upstream artifact missing | Generate partial report, mark missing sections `[DATA UNAVAILABLE]` |
| Phase 5 | Upstream artifact corrupt (invalid JSON) | Treat as missing; note corruption in Methodology section |
| Phase 5 | Report generation agent produces incomplete output | Auto-fix: regenerate failed sections (max 1 retry) |
| Phase 6 | Verification subagent returns invalid JSON | Parse recovery: strip markdown fences, re-parse. If still invalid, re-dispatch once. If second attempt fails, abort Phase 6 with warning — pipeline continues without verification. |
| Phase 6 | Verification subagent drops claims from response | Mark missing claims as `unconfirmed` with reasoning noting agent failure |
| Phase 6 | Fix-verify loop cap reached (3 rounds) | Preserve both assessments, mark `verification_status: "partial"`, proceed to report |
| Phase 6 | analysis.json or claims.json missing/corrupt | Abort Phase 6 — verification cannot proceed without upstream analysis. Pipeline continues to Phase 5 without verification data. |
| Phase 6 | diff-map.json missing/corrupt or clone_path invalid | Skip fix-verify loop only — initial verification (Steps 6.1-6.2) proceeds normally. Disputed claims remain unresolved, `verification_status: "partial"`. |
| Phase 7 | `internal-report.md` missing | Abort Phase 7; report must be approved in Phase 5 first |
| Phase 7 | Other upstream artifacts missing | Extract from available artifacts; use `"[UNAVAILABLE]"` for missing fields |
| Phase 7 | Malformed JSON in existing index | Skip the malformed line, log warning, continue reading |
| Phase 7 | Duplicate entry detected | AskUserQuestion: overwrite / keep-both / skip |
| Phase 7 | Index directory creation fails | Abort with clear error message |
| Phase 8 | `internal-report.md` missing | Abort Phase 8; Phase 5 must complete first |
| Phase 8 | Knowledge index missing | Proceed without supplementary data; use internal report only |
| Phase 8 | Agent fails to generate summary or returns malformed markdown | Retry once with simplified prompt; if still fails, abort |
| Phase 8 | Code leak detected in validation | Auto-fix: re-dispatch agent for offending section with stricter prompt |
| Phase 8 | User aborts mid-approval | Preserve draft at `public-summary.draft.md`; do not create final `public-summary.md` |

**Error handling philosophy:** Phase 5 always attempts to produce output. The only condition that aborts Phase 5 is ALL upstream artifacts being missing. Any other combination of missing/partial/corrupt artifacts results in a degraded but functional report.

---

## Phase 7: Knowledge Index Management

> **Implemented by:** WHI-235

Phase 7 persists the analysis results to the knowledge index — an append-only JSONL file at `~/.gstack/research/research-index.jsonl`. This is the "research compound interest" storage layer: as analyses accumulate, cross-referencing (Phase 4) becomes increasingly valuable.

Phase 7 runs after Phase 5 (report generation) and after the user has approved the final report. It is the last phase in the M2 pipeline.

**Agent role:** `knowledge_index_agent` (see [Agent Roles > knowledge_index_agent](#7-knowledge_index_agent-phase-7))

### Step 7.0 — Input Validation

Phase 7 requires the final report and upstream artifacts to extract index entry fields. Validate availability:

**Recovering `session_dir`:** Phase 7 runs in the same session as Phases 1-5. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Required artifact: internal-report.md**

```bash
REPORT_FILE="$SESSION_DIR/internal-report.md"
if [ ! -f "$REPORT_FILE" ]; then
  echo "❌ Phase 7 aborted: internal-report.md not found at $REPORT_FILE"
  echo "   Phase 5 must complete and the user must approve the report before Phase 7 can run."
  exit 1
fi
```

**Optional artifacts (used for field extraction):**

For each of `claims.json`, `diff-map.json`, `analysis.json`:
1. Check file exists in `$SESSION_DIR`
2. If exists: parse JSON and extract needed fields
3. If missing: use fallback values derived from the internal report content or mark as `"[UNAVAILABLE]"`

```
ARTIFACTS_STATUS = {}
For each artifact in [claims.json, diff-map.json, analysis.json]:
  Check existence and parsability
  Record: "available" or "missing"
```

### Step 7.1 — Directory Bootstrap

Ensure the knowledge index directory exists:

```bash
RESEARCH_DIR="$HOME/.gstack/research"
INDEX_FILE="$RESEARCH_DIR/research-index.jsonl"
mkdir -p "$RESEARCH_DIR"
```

If `mkdir -p` fails (permissions, disk full): abort with `"❌ Cannot create research directory at $RESEARCH_DIR"`.

### Step 7.2 — Extract Index Entry Fields

Build the index entry by extracting fields from available artifacts.

**From `diff-map.json` (if available):**
```
repo = diff_map.repo  // e.g., "https://github.com/base-org/base-contracts"
repo_short = extract org/repo from URL  // e.g., "base-org/base-contracts"
base_sha = diff_map.base_sha
head_sha = diff_map.head_sha
base_ref = diff_map.base_ref
head_ref = diff_map.head_ref
```

If `diff-map.json` is missing: set all fields to `"[UNAVAILABLE]"`. These fields will be present in the index entry but with placeholder values.

**From `claims.json` (if available):**
```
source_url = claims.source_url
```

If `claims.json` is missing: set `source_url = "[UNAVAILABLE]"`.

**From `analysis.json` (if available):**
```
claims_analyzed = analysis.claims_analyzed
unreported_changes = analysis.unreported_changes
analysis_summary = analysis.summary
```

**Compute `claims_summary`:**

Cross-reference: these field names correspond to `analysis.json` > `summary` fields as defined in the [analysis.json schema](#analysisjson). The mapping is:

| Index entry field | analysis.json summary field |
|-------------------|---------------------------|
| `confirmed` | `summary.verified` |
| `partial` | `summary.partially_verified` |
| `unconfirmed` | `summary.unverified` |

```
IF analysis.json is available:
  # Validate expected fields exist before extracting
  REQUIRED_FIELDS = ["total_claims", "verified", "partially_verified", "unverified"]
  For each field in REQUIRED_FIELDS:
    IF field is missing from analysis_summary:
      Log warning: "⚠️  analysis.json summary missing field '<field>' — defaulting to 0"

  claims_summary = {
    "total": analysis_summary.total_claims or 0,
    "confirmed": analysis_summary.verified or 0,
    "partial": analysis_summary.partially_verified or 0,
    "unconfirmed": analysis_summary.unverified or 0,
    "contradicted": 0  // reserved for future use
  }
ELSE:
  claims_summary = {
    "total": 0,
    "confirmed": 0,
    "partial": 0,
    "unconfirmed": 0,
    "contradicted": 0
  }
```

**Compute `full_claims` (compact claim array for internal fields):**

Join key: match `claims.json` entries by `claims[].id` against `analysis.json` entries by `claims_analyzed[].claim_id`. These are the same identifier (format: `claim-NNN`), assigned in Phase 1 and carried through to Phase 3.

```
IF analysis.json is available AND claims.json is available:
  For each claim in claims.json.claims:
    Find matching entry in analysis.claims_analyzed WHERE entry.claim_id == claim.id
    IF match found:
      full_claims.append({
        "id": claim.id,
        "text": claim.text,
        "category": claim.category,
        "verification_status": matched_entry.verification_status
      })
    ELSE:
      Log warning: "⚠️  Claim <claim.id> has no matching entry in analysis.claims_analyzed — marking as not_analyzed"
      full_claims.append({
        "id": claim.id,
        "text": claim.text,
        "category": claim.category,
        "verification_status": "not_analyzed"
      })
ELSE:
  full_claims = []
```

**Extract `executive_summary` from the internal report:**

Read the Executive Summary section from `internal-report.md`:
```bash
# Extract text between "## Executive Summary" and the next "## " heading
sed -n '/^## Executive Summary$/,/^## /{/^## Executive Summary$/d;/^## /d;p}' "$REPORT_FILE" | head -20
```

Truncate to 500 characters if longer. If the section contains `[DATA UNAVAILABLE]`, use that as the summary.

**Compute overall `verification_status`:**
```
confirmed_and_partial = claims_summary.confirmed + claims_summary.partial
total = claims_summary.total

if total == 0:
  verification_status = "low_confidence"
elif confirmed_and_partial / total > 0.70:
  verification_status = "verified"
elif confirmed_and_partial / total >= 0.30:
  verification_status = "partial"
else:
  verification_status = "low_confidence"
```

**Build the `evidence_map_path`:**
```
# Relative path from ~/.gstack/research/ to the analysis.json
# e.g., "sessions/base-azul-20260425-120000/analysis.json"
evidence_map_path = relative path from RESEARCH_DIR to SESSION_DIR/analysis.json
```

**Compute `unclaimed_changes_count`:**
```
IF analysis.json is available:
  unclaimed_changes_count = len(analysis.unreported_changes)
ELSE:
  unclaimed_changes_count = 0
```

### Step 7.3 — Build Index Entry

Assemble the complete index entry following the schema from [Artifact Schemas > research-index.jsonl](#research-indexjsonl-knowledge-index-entry):

```
TIMESTAMP = current ISO 8601 timestamp
CHAIN_SLUG = lowercase chain name
UPGRADE_SLUG = lowercase upgrade name
DATE_SLUG = YYYYMMDD-HHMMSS from TIMESTAMP

entry = {
  "schema_version": 1,
  "id": "{CHAIN_SLUG}-{UPGRADE_SLUG}-{DATE_SLUG}",
  "dedup_key": "{CHAIN_SLUG}:{UPGRADE_SLUG}:{repo_short}",
  "public": {
    "chain": CHAIN_SLUG,
    "upgrade_name": "<upgrade name, original case>",
    "source_url": source_url,
    "executive_summary": "<extracted from report>",
    "claims_summary": claims_summary,
    "generated_at": TIMESTAMP
  },
  "internal": {
    "repo": repo_short,
    "base_sha": base_sha,
    "head_sha": head_sha,
    "base_ref": base_ref,
    "head_ref": head_ref,
    "full_claims": full_claims,
    "evidence_map_path": evidence_map_path,
    "verification_status": verification_status,
    "unclaimed_changes_count": unclaimed_changes_count
  }
}
```

### Step 7.4 — Dedup Check (D4)

Before appending, check the existing index for duplicate entries.

**Read and parse the existing index:**

```bash
INDEX_FILE="$HOME/.gstack/research/research-index.jsonl"
```

If the file does not exist: no duplicates possible — skip to Step 7.5.

If the file exists:

1. Read the file line by line
2. For each line, attempt to parse as JSON:
   - **Success:** Extract `dedup_key` field, add to the known-keys set
   - **Failure (malformed JSON):** Log a warning and skip the line:
     ```
     ⚠️  Malformed JSON at line <N> in research-index.jsonl — skipping.
         Content: <first 80 chars of the line>
     ```
     Continue processing remaining lines. Do NOT abort.

3. Check if the new entry's `dedup_key` matches any existing entry's `dedup_key`

**If no duplicate found:** Proceed to Step 7.5.

**If duplicate found:**

Present the user with three choices via AskUserQuestion:

```
Use AskUserQuestion:
  question: "A previous analysis with the same key already exists in the knowledge index.
             Existing: <existing_entry.id> (generated <existing_entry.public.generated_at>)
             New:      <new_entry.id> (generated <new_entry.public.generated_at>)
             Key:      <dedup_key>
             
             How should I handle this?"
  options:
    - "Overwrite" — replace the old entry with the new one
    - "Keep both" — append the new entry alongside the old one (both will appear in queries)
    - "Skip" — do not write the new entry (keep the existing one)
```

**On "Overwrite":**
1. Read the entire index file
2. Filter out all lines whose parsed `dedup_key` matches the new entry's `dedup_key`
3. Append the new entry to the filtered output (atomic: remove + add in one operation)
4. Write the combined result back to the file atomically via temp file + mv
5. Skip Step 7.5 (the new entry is already included)

```bash
# Atomic overwrite: filter out old entry AND append new entry in one pass,
# then atomically replace the file. This avoids the corruption window where
# the old entry is removed but the new entry hasn't been appended yet.
DEDUP_KEY="<the computed dedup_key>"
NEW_ENTRY_JSON='<the new entry as single-line JSON>'
TEMP_FILE=$(mktemp "${INDEX_FILE}.tmp.XXXXXX")
trap 'rm -f "$TEMP_FILE"' EXIT  # Clean up temp file on any failure

# Filter out old entries and write remaining to temp file
while IFS= read -r line; do
  KEY=$(echo "$line" | jq -r '.dedup_key // empty' 2>/dev/null)
  if [ "$KEY" != "$DEDUP_KEY" ]; then
    echo "$line"
  fi
done < "$INDEX_FILE" > "$TEMP_FILE"

# Append the new entry to the temp file
echo "$NEW_ENTRY_JSON" >> "$TEMP_FILE"

# Atomically replace the index file
mv "$TEMP_FILE" "$INDEX_FILE" || {
  trap - EXIT  # Disable cleanup so temp file is preserved for recovery
  echo "❌ Atomic replace failed: $INDEX_FILE not updated."
  echo "   Temp file preserved at $TEMP_FILE for manual recovery."
  echo "   To recover: mv $TEMP_FILE $INDEX_FILE"
  echo "   Phase 7 aborted."
  exit 1
}
trap - EXIT  # Clear the cleanup trap on success
```

**Key safety properties:**
- The temp file is created in the same directory as the index file (`${INDEX_FILE}.tmp.XXXXXX`) to ensure `mv` is atomic (same filesystem)
- A `trap` ensures the temp file is cleaned up on any signal or error during filtering/appending, preventing data leakage
- On `mv` failure, the trap is disabled BEFORE `exit 1` so the temp file is preserved for manual recovery
- The new entry is appended to the temp file BEFORE the `mv`, so the replacement is all-or-nothing: either both the removal and addition happen, or neither does

**On "Keep both":** Proceed to Step 7.5 (append normally — both entries coexist).

**On "Skip":** Print `"Skipping index write. Existing entry preserved."` and skip Steps 7.5-7.6 entirely. Phase 7 is complete.

### Step 7.5 — Append Entry

Write the index entry as a single-line JSON record appended to the JSONL file.

```bash
# Serialize the entry as compact single-line JSON and append
WRITE_OK=false
echo '<entry as single-line JSON>' >> "$INDEX_FILE"
APPEND_STATUS=$?
```

**Validation after write:**

First, check that the append command itself succeeded (terminal on failure). Then verify the written entry matches what we intended using both `dedup_key` and `generated_at` (the combination uniquely identifies the entry, preventing false matches against older same-key entries):
```bash
# Step 1: Check append exit status — TERMINAL on failure
if [ $APPEND_STATUS -ne 0 ]; then
  echo "❌ Append command failed (exit $APPEND_STATUS): entry was NOT written to $INDEX_FILE."
  echo "   Check disk space, permissions, and filesystem health."
  echo "   Phase 7 aborted. Re-run to retry."
  # Skip ALL remaining steps — do NOT proceed to Step 7.6
  return 1  # or exit 1 if not in a function context
fi

# Step 2: Read back the last line and verify it matches the new entry
LAST_LINE=$(tail -1 "$INDEX_FILE")
LAST_DEDUP_KEY=$(echo "$LAST_LINE" | jq -r '.dedup_key // empty' 2>/dev/null)
LAST_GENERATED_AT=$(echo "$LAST_LINE" | jq -r '.generated_at // empty' 2>/dev/null)
if [ "$LAST_DEDUP_KEY" != "$DEDUP_KEY" ] || [ "$LAST_GENERATED_AT" != "$GENERATED_AT" ]; then
  echo "❌ Write verification failed: last line does not match the entry we just wrote."
  echo "   Expected dedup_key='$DEDUP_KEY', generated_at='$GENERATED_AT'"
  echo "   Got      dedup_key='$LAST_DEDUP_KEY', generated_at='$LAST_GENERATED_AT'"
  echo "   The index file may be corrupted or the append was silently lost."
  echo "   Phase 7 aborted. Re-run to retry."
  # Skip ALL remaining steps — do NOT proceed to Step 7.6
  return 1  # or exit 1 if not in a function context
fi

WRITE_OK=true
```

**Gate on WRITE_OK:** Step 7.6 MUST check `WRITE_OK == true` before displaying any success output. If `WRITE_OK` is not `true`, Step 7.6 displays the error banner instead.

**If `WRITE_OK` is not `true` (write verification failed or append failed):** Do NOT display the success banner in Step 7.6. The error path above already printed the abort message and returned/exited. Step 7.6 should not be reachable in this case, but as a defense-in-depth guard:
```
⚠️  Phase 7 completed with errors — index entry write could not be verified.
    Manual inspection of ~/.gstack/research/research-index.jsonl is required.
    The last line may be malformed. Remove it and re-run Phase 7 to retry.
```

**If write verification succeeds,** print confirmation:
```
✅ Knowledge index updated: <entry.id>
   File: ~/.gstack/research/research-index.jsonl
   Key:  <dedup_key>
   Total entries: <line count of parseable entries in INDEX_FILE>
```

**Note on entry counting:** The "total entries" count should reflect the number of *parseable* JSON lines, not the raw line count. Count lines where `jq -e '.' >/dev/null 2>&1` succeeds.

### Step 7.6 — User Checkpoint 🧑

**Only execute if write verification succeeded in Step 7.5.** If write verification failed, the error message from Step 7.5 is the terminal output — do NOT display the success banner below.

Present the index entry summary to the user for confirmation. This checkpoint is informational — the entry has already been written (it's append-only, and the user already approved the report in Phase 5).

**Display format:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📚 Phase 7 Complete — Knowledge Index Updated

Entry ID:    <entry.id>
Dedup key:   <dedup_key>
Index file:  ~/.gstack/research/research-index.jsonl
Total entries: <count>

Public fields:
  Chain:      <chain>
  Upgrade:    <upgrade_name>
  Source:     <source_url>
  Summary:    <first 100 chars of executive_summary>...
  Claims:     <total> total (<confirmed> confirmed, <partial> partial, <unconfirmed> unconfirmed)

Internal fields:
  Repo:       <repo>
  Refs:       <base_ref> → <head_ref>
  SHAs:       <base_sha first 8>...<head_sha first 8>
  Verification: <verification_status>
  Unclaimed changes: <unclaimed_changes_count>

Session:     <session_dir>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

After displaying the success banner, offer to proceed to Phase 8 (M3 public summary):

```
Use AskUserQuestion:
  question: "Phase 7 complete. Generate a public-facing summary for external stakeholders (Phase 8)?"
  options:
    - "Yes — generate public summary (Phase 8)"
    - "No — pipeline complete"
```

If "Yes": proceed to Phase 8.
If "No": print `"Pipeline complete. Session artifacts at: <session_dir>"` and stop.

### Per-Phase Error Handling (Phase 7)

| Phase 7 Scenario | Recovery Action |
|-------------------|-----------------|
| `internal-report.md` missing | Abort — report must be approved first |
| Other artifacts missing | Extract fields from available artifacts; use `"[UNAVAILABLE]"` for missing fields |
| Index directory cannot be created | Abort with clear error message |
| Malformed JSON lines in existing index | Skip the line, log warning with line number, continue reading |
| Dedup found + user chooses "skip" | Do not write; Phase 7 completes without index mutation |
| Dedup found + user chooses "overwrite" | Remove old entry, append new entry |
| Write verification fails (last line not valid JSON) | Warn user; manual inspection required |
| Index file does not exist | Create it; no dedup check needed |

---

## Phase 8: Public Summary Output

> **Implemented by:** WHI-236

Phase 8 generates a public-facing summary from the internal report and knowledge index public fields. The public summary is designed for external stakeholders — team members, partners, community — and explicitly excludes all code snippets, file paths, line numbers, and internal analysis notes.

Phase 8 runs after Phase 7 (knowledge index management) or after Phase 5 (report generation) if the knowledge index phase was skipped. It is an M3 feature.

**Agent role:** `public_communications_writer` (see [Agent Roles > public_communications_writer](#8-public_communications_writer-phase-8))

### Step 8.0 — Input Validation

Phase 8 requires the approved internal report. The knowledge index is optional but used for supplementary public field data.

**Recovering `session_dir`:** Phase 8 runs in the same session as earlier phases. The `SESSION_DIR` variable should still be available. If not (e.g., re-invocation), recover:

```bash
SESSION_DIR=$(ls -dt "$HOME/.gstack/research/sessions/${CHAIN_SLUG}-${UPGRADE_SLUG}-"* 2>/dev/null | head -1)
if [ -z "$SESSION_DIR" ]; then
  echo "❌ No session directory found. Run Phase 1 first."
  exit 1
fi
echo "Session directory: $SESSION_DIR"
```

**Required artifact: internal-report.md**

```bash
REPORT_FILE="$SESSION_DIR/internal-report.md"
if [ ! -f "$REPORT_FILE" ]; then
  echo "❌ Phase 8 aborted: internal-report.md not found at $REPORT_FILE"
  echo "   Phase 5 must complete and the user must approve the report before Phase 8 can run."
  exit 1
fi
```

**Optional artifact: knowledge index**

```bash
INDEX_FILE="$HOME/.gstack/research/research-index.jsonl"
INDEX_AVAILABLE="no"
if [ -f "$INDEX_FILE" ]; then
  INDEX_AVAILABLE="yes"
fi
echo "Knowledge index: $INDEX_AVAILABLE"
```

**Detect language configuration:**

Check if the user specified a language flag during pipeline invocation:

```
IF user input contains "--lang zh" or "--lang chinese":
  LANG = "zh"
ELSE:
  LANG = "en"  // default
```

### Step 8.1 — Extract Public-Safe Content

Extract content from available sources, filtering out all internal/sensitive details.

**From `internal-report.md`:**

Read the internal report and extract content section by section. For each section, apply the public field filter:

```
FILTER RULES (applied to all extracted content):
  1. Code snippets (fenced code blocks with file paths) → natural language description
     Example: "```solidity\nfunction verifyWithdrawal(...)\n```" → "The withdrawal proof verification mechanism"
  2. File paths → component names
     Example: "contracts/src/L2/OptimismPortal2.sol:L345" → "L2 portal contract"
     Example: "op-node/rollup/derive/pipeline.go" → "derivation pipeline"
  3. Line numbers → remove entirely
  4. Internal analysis notes (text containing "analysis_notes", debug references) → remove
  5. SHA references → remove or generalize ("commit abc123" → "the relevant commit")
  6. Raw Data References section → do NOT include in public summary
  7. Methodology section → extract only "Phases executed" and "Pipeline version", omit technical details
```

**Sections to extract from internal report:**

```
1. Executive Summary → becomes "Overview" (rewrite for non-technical audience)
2. Claims Analysis → becomes "Key Changes" (high-level descriptions only, no code)
3. Unclaimed Changes → contributes to "Impact Assessment" (summarize significance, no file details)
4. Independent Verification (if present) → contributes to "Verification Status"
5. Cross-Chain Comparison (if present) → contributes to "Impact Assessment"
6. Metadata header → extract chain, upgrade name, source URL, timestamp
```

**From knowledge index (if available):**

```
IF INDEX_AVAILABLE == "yes":
  Read research-index.jsonl
  
  # Use the same dedup_key as Phase 7 for robust matching:
  DEDUP_KEY = "{CHAIN_SLUG}:{UPGRADE_SLUG_LOWER}:{REPO_SHORT}"
  # Where REPO_SHORT is extracted from the internal report metadata header (repo field)
  # and UPGRADE_SLUG_LOWER is the lowercased, hyphenated upgrade name.
  
  Find the entry where dedup_key == DEDUP_KEY
  
  IF no exact match found:
    # Fallback: try chain + upgrade_name (case-insensitive) but warn about ambiguity
    MATCHES = entries where chain matches AND upgrade_name matches (case-insensitive)
    IF len(MATCHES) == 0:
      Print: "ℹ️ No matching knowledge index entry found. Proceeding with internal report only."
      INDEX_ENTRY = null
    ELIF len(MATCHES) == 1:
      INDEX_ENTRY = MATCHES[0]
    ELSE:
      Print: "⚠️ Multiple knowledge index entries match (chain + upgrade_name). Using the most recent."
      INDEX_ENTRY = entry with latest public.generated_at
  ELSE:
    INDEX_ENTRY = matched entry
  
  IF INDEX_ENTRY != null:
    Extract public fields:
      - public.executive_summary (may supplement the Overview)
      - public.claims_summary (total, confirmed, partial, unconfirmed, contradicted)
      - public.source_url
      - public.generated_at
```

### Step 8.2 — Generate Public Summary

Dispatch the `public_communications_writer` via the Agent tool to synthesize the summary.

**Language-specific prompt prefix:**

```
IF LANG == "zh":
  LANG_INSTRUCTION = "Write the entire summary in Chinese (简体中文). Use professional, clear language suitable for Chinese-speaking stakeholders. Technical terms may remain in English where conventional (e.g., L2, rollup, EIP)."
  DISCLAIMER = "⚠️ 免责声明：本摘要由自动化协议分析管线生成。关键决策建议进行人工验证。"
ELSE:
  LANG_INSTRUCTION = "Write the entire summary in English. Use clear, professional language suitable for non-technical stakeholders."
  DISCLAIMER = "⚠️ Disclaimer: Generated by automated protocol analysis pipeline. Manual verification recommended for critical decisions."
```

**Summary generation prompt:**

```
You are the Public Communications Writer. Your job is to distill the internal
technical analysis into a clear, professional summary suitable for external
stakeholders. You must NOT include any code, file paths, or internal analysis details.

<LANG_INSTRUCTION>

## Input Data

### Metadata
- Chain: <chain>
- Upgrade: <upgrade_name>
- Source: <source_url>
- Analysis date: <generated_at>

### Executive Summary (from internal report)
<executive_summary_text>

### Claims Summary
- Total claims analyzed: <total>
- Confirmed: <confirmed>
- Partially confirmed: <partial>
- Unconfirmed: <unconfirmed>

### Key Changes (extracted from Claims Analysis, filtered)
<For each claim: claim text and verification status only — NO code, NO file paths>

### Unreported Changes Summary
<Count and significance distribution only — NO file paths, NO code>

### Verification Data (if available)
<verification_status, claims_reviewed count, disputes count>

### Cross-Chain Comparison (if available)
<novel_features count, borrowed_features count, divergent_features count — high-level only>

## Output Template

Generate the public summary using this exact structure:

---

# <upgrade_name> Upgrade Analysis — Public Summary

**Chain:** <chain>
**Source:** <source_url>
**Analysis Date:** <generated_at>

## Overview

Write 2-3 paragraphs for a non-technical audience:
- What is this upgrade about? (plain language, no jargon)
- Why does it matter? (impact on users, ecosystem)
- What is the overall assessment?

## Key Changes

For each significant change, write a bullet point:
- **<Change name>** — <1-2 sentence plain-language description>
  Status: <✅ Confirmed | ⚠️ Partially confirmed | ❌ Unconfirmed>

Do NOT include:
- Code snippets or code references
- File paths or directory structures
- Line numbers
- Technical implementation details (function names, variable names, etc.)

DO include:
- What the change does from a user/ecosystem perspective
- Why it matters
- Whether it was verified in the code

## Impact Assessment

Summarize the overall impact:
- Number of announced changes and their verification status
- Unreported changes found (count and significance — e.g., "3 unreported changes were found, including 1 of high significance")
- Cross-chain context (if Phase 4 data available): how this upgrade compares to similar upgrades on other chains
- Risk areas or concerns (if any unverified claims or high-significance unreported changes)

## Verification Status

Summary of the verification results:
- Overall confidence level (verified / partial / low_confidence)
- Claims breakdown: N confirmed, N partial, N unconfirmed out of N total
- Independent verification results (if Phase 6 was executed)
- Any unresolved disputes or reviewer concerns (high-level only)

<DISCLAIMER>

---

## Output Rules

- Begin your output IMMEDIATELY with the line: # <upgrade_name> Upgrade Analysis — Public Summary
- Do NOT wrap the output in a code fence
- Do NOT add any preamble or commentary before the heading
- Output the FULL markdown summary — nothing else
- NEVER include code snippets, file paths, line numbers, or function/variable names
- Transform all technical references into plain language
- Keep the tone professional and accessible
```

### Step 8.3 — Write Draft Summary to Disk

**File:** `{session_dir}/public-summary.draft.md`

Write the generated summary to the **draft** path using the Write tool. The draft is NOT the final deliverable — it is promoted to `public-summary.md` only after the section-by-section user approval in Step 8.5.

### Step 8.4 — Self-Validation Gate

Validate the draft summary at `{session_dir}/public-summary.draft.md` before presenting to the user.

**Validation checks:**

1. **Header present:** The first non-empty line must start with `# ` and contain "Public Summary" (or the Chinese equivalent "公开摘要").
2. **Required sections present:** All four required sections exist as level-2 headings:
   - `## Overview` (or `## 概览` if `LANG == "zh"`)
   - `## Key Changes` (or `## 关键变更`)
   - `## Impact Assessment` (or `## 影响评估`)
   - `## Verification Status` (or `## 验证状态`)
3. **No code leaks:** Scan the entire summary for patterns that indicate leaked internal details. **Exclude** content inside `**Source:**` metadata lines and `https?://` URLs when checking path patterns.
   - Fenced code blocks (` ``` `) — FAIL if found
   - Multi-segment file paths outside URLs: regex `(?<!https?://\S*)\b[a-zA-Z0-9_\-]+/[a-zA-Z0-9_\-]+/[a-zA-Z0-9_.\-]+` — FAIL if found (matches patterns like `contracts/src/L2/file.sol` but not `https://example.com/path`)
   - Source code file extensions in path context: regex `\b\w+\.(sol|go|ts|js|py|rs|cpp|c|yaml|toml)\b` when NOT inside a URL — FAIL if found
   - Line number references: `:L\d+` or `at line \d+` or `lines \d+[-–]\d+` — FAIL if found (plain English "line" followed by a number in narrative context is allowed)
   - SHA hashes (40-character hex strings): regex `\b[0-9a-f]{40}\b` — FAIL if found
   - Internal field names: `analysis_notes`, `code_snippets`, `evidence_map_path` — FAIL if found
4. **Disclaimer present:** The summary ends with the appropriate disclaimer text (last non-empty paragraph).
5. **No empty sections:** Each section has at least 20 characters of non-whitespace content.
6. **No duplicate sections:** Each required heading appears exactly once.

**On validation failure:**

```
❌ Public summary validation failed:
   <list of failures>
   Attempting auto-fix...
```

**Auto-fix strategy:**

- **Code leak detected:** Re-dispatch the agent with a section-specific prompt emphasizing the "no code" constraint. Include the offending text and instruct: "Rewrite this section. The following text was flagged as containing internal details: <offending text>. Replace all code references with natural language descriptions."
- **Missing section:** Re-dispatch with the section-specific prompt.
- **Missing disclaimer:** Append the disclaimer to the end of the file.

If auto-fix also fails validation after **2 attempts**, STOP and print:

```
🛑 Code-leak validation failed after auto-fix. Cannot proceed with public summary.
   Remaining issues:
   <list of unresolved validation failures>

   Manual intervention required. Review the draft at {session_dir}/public-summary.draft.md
   and re-invoke Phase 8 after correcting the source data.
```

Do NOT proceed to Step 8.5 while any code-leak check (check 3) fails. Non-leak validation failures (checks 1, 2, 4, 5, 6) may proceed with a warning note in the approval step.

### Step 8.5 — User Checkpoint 🧑 (Section-by-Section Approval)

This is the key differentiator from Phase 5's checkpoint. Instead of approving the entire summary at once, the user reviews and approves each section individually.

**Approval flow:**

```
SECTIONS = ["Overview", "Key Changes", "Impact Assessment", "Verification Status"]
// For Chinese: ["概览", "关键变更", "影响评估", "验证状态"]

APPROVED_SECTIONS = {}

For each SECTION in SECTIONS:
  1. Extract the section content from the draft summary
     (text from and INCLUDING the "## <SECTION>" heading line,
      up to but NOT INCLUDING the next "## " heading or the disclaimer separator "---")
     The extracted content INCLUDES the heading — this is important for reassembly in Step 8.6.
  
  2. Display the section to the user:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📝 Section Review: <SECTION> (<current>/<total>)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     
     <section content>
     
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
  
  3. Ask for approval:
     ```
     Use AskUserQuestion:
       question: "Approve this section for the public summary?"
       options:
         - "Approve ✅"
         - "Edit — I want to modify this section"
         - "Regenerate — rewrite this section"
         - "Abort — stop the public summary process"
     ```
  
  4. Handle response:
     IF "Approve ✅":
       APPROVED_SECTIONS[SECTION] = current content
       Continue to next section
     
     IF "Edit":
       Ask user for their edits (free-text input via AskUserQuestion)
       Apply edits to the section content
       ⚠️ RE-VALIDATE: Run Step 8.4 checks 3 (code leaks) on the edited section content only.
         If code leak detected → display warning and re-ask for edits (do NOT approve a section with leaks)
       Re-display the modified section
       Loop back to step 3 for this section (re-ask approval)
     
     IF "Regenerate":
       Re-dispatch the agent with a section-specific prompt:
         "Regenerate ONLY the '<SECTION>' section. Context: <provide relevant input data for this section>.
          Previous version was rejected by the reviewer. Write a new version.
          Output ONLY the section content, starting with '## <SECTION>'."
       Replace section in the draft
       ⚠️ RE-VALIDATE: Run Step 8.4 checks 3 (code leaks) on the regenerated section content.
         If code leak detected → auto-fix once (re-dispatch with leak emphasis), then display result.
         If still leaking after auto-fix → display warning and ask user to Edit manually or Abort.
       Re-display the regenerated section
       Loop back to step 3 for this section (re-ask approval)
     
     IF "Abort":
       Print: "Public summary aborted. Draft preserved at {session_dir}/public-summary.draft.md"
       Do NOT create public-summary.md
       STOP Phase 8

After ALL sections approved:
  APPROVED_SECTIONS contains the final content for each section
```

### Step 8.6 — Assemble and Finalize

After all sections are approved:

1. **Assemble the final summary:** Combine the metadata header, all approved sections, and the disclaimer. Each `APPROVED_SECTIONS[...]` value already includes its `## <Heading>` line (see Step 8.5 extraction rule) — do NOT add extra headings.

```
FINAL_CONTENT = """
# <upgrade_name> Upgrade Analysis — Public Summary

**Chain:** <chain>
**Source:** <source_url>
**Analysis Date:** <generated_at>
**Publication Status:** approved

<APPROVED_SECTIONS["Overview"]>

<APPROVED_SECTIONS["Key Changes"]>

<APPROVED_SECTIONS["Impact Assessment"]>

<APPROVED_SECTIONS["Verification Status"]>

---

<DISCLAIMER>
"""
```

2. **Final validation pass:** Before writing, run Step 8.4 check 3 (code leak detection) on the entire assembled `FINAL_CONTENT`. This is a safety net — individual sections were validated during approval, but the assembly step (metadata header, section concatenation) could introduce new leak vectors.

   If any code leak is found in the assembled content:
   ```
   🛑 Final assembly validation FAILED — code leak detected in assembled content:
      <offending patterns>
   
   The public summary will NOT be written. Review the flagged content and re-run Phase 8.
   Draft preserved at {session_dir}/public-summary.draft.md
   ```
   Do NOT write `public-summary.md`. STOP Phase 8.

3. **Write the final file:**

```bash
# Write to final path
Write {session_dir}/public-summary.md with FINAL_CONTENT
```

4. **Delete the draft:**

```bash
rm -f {session_dir}/public-summary.draft.md
```

5. **Output confirmation:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Phase 8 Complete — Public Summary Approved

File:    {session_dir}/public-summary.md
Status:  publication_status: approved
Language: <en or zh>
Sections: <N>/<N> approved

Summary Stats:
  Overview:              <word count> words
  Key Changes:           <N> items
  Impact Assessment:     <word count> words
  Verification Status:   <word count> words
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Output artifacts:**
```
~/.gstack/research/sessions/<chain>-<upgrade>-<date>/public-summary.md
```

### Per-Phase Error Handling (Phase 8)

| Failure | Recovery |
|---------|----------|
| `internal-report.md` missing | Abort Phase 8 with clear message; Phase 5 must run first |
| Knowledge index missing | Proceed without supplementary data; use internal report only |
| Agent fails to generate summary | Retry once with simplified prompt (fewer input sections); if still fails, abort |
| Code leak detected in validation | Auto-fix by re-dispatching agent for offending section with stricter prompt |
| User aborts mid-approval | Preserve draft at `public-summary.draft.md`; do not create final `public-summary.md` |
| Language flag unrecognized | Default to English; warn: "Unrecognized language flag — defaulting to English" |

---

## Failure and Abort

If the skill is interrupted, errors out, or the user aborts mid-pipeline:

- **Phases 1-4, 6:** Partial artifacts are saved to disk. No knowledge index entry is created. v1 does NOT support resume-from-phase. If interrupted, re-run from scratch. Partial artifacts remain on disk for manual reference.
- **Phase 7:** If interrupted after the append but before confirmation, the index entry is already written (append-only). On re-invocation, the dedup check (Step 7.4) will detect the existing entry and offer overwrite/keep-both/skip. If interrupted before the append, no index entry exists — re-run Phase 7 after ensuring the report is approved.
- **Phase 8:** If interrupted mid-approval, the draft is preserved at `{session_dir}/public-summary.draft.md`. The final `public-summary.md` is NOT created until all sections are approved. On re-invocation, Phase 8 starts fresh (reads internal-report.md again). The draft file can be manually reviewed or deleted.
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
