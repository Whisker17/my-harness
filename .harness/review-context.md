# Review Context — WHI-230: Phase 2 Codebase Navigation

## Implementation Summary

Implemented the full Phase 2 (Codebase Navigation) section in SKILL.md, replacing the placeholder with detailed step-by-step instructions for:
- Treeless clone with timeout, known-large-repo depth limiting, and shallow clone fallback
- Fuzzy tag matching using Levenshtein distance with confidence-based thresholds
- SHA resolution with chronological order validation and shallow-clone deepening
- Diff-map generation with file categorization and hunk counting
- Self-validation gate against WHI-228 schema
- User checkpoint with summary display

Also updated the Artifact Schemas section to add `num_hunks` and `summary.renamed` fields to the diff-map.json schema, and fixed the cleanup trap in the Failure and Abort section.

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — replaced Phase 2 placeholder (~15 lines) with full implementation (~480 lines); updated artifact schema, validation rules, Table of Contents, and cleanup trap

## Adversarial Review Findings

### Addressed (Critical/High)

**Round 1:**
- CRITICAL: `REPO_URL` never assigned in bash code → added explicit assignment at top of Step 2.1
- CRITICAL: `--no-checkout` without `git checkout` → added `git checkout HEAD` after treeless clone
- CRITICAL: `TAG_COUNT=0` check broken (`echo "" | wc -l` = 1) → switched to `grep -c .`
- CRITICAL: `summary.renamed` missing from schema → added to schema, JSON examples, field reference, and validation
- HIGH: No URL integrity check on reused clone → added `remote get-url` comparison with mismatch handling
- HIGH: `/tmp/` paths for diff output → changed to write to `$SESSION_DIR`
- HIGH: `git rev-parse` fails on shallow clones → added `git fetch --depth=500` fallback
- HIGH: `FILTERED_TAGS` string concatenation corruption → rewrote with proper newline handling
- HIGH: AC-6 hunks not implemented → added `num_hunks` field to schema, extraction logic with per-file and batch counting
- HIGH: Local path never sets `REPO_URL` → documented in Step 2.0
- HIGH: Cleanup trap uses unslugified variables → trap now references `$CLONE_DIR` directly

**Round 2:**
- CRITICAL: Reused clone falls through to re-clone → added `clone_method` skip guard
- CRITICAL: Batch awk hunk counter always outputs 0 → fixed count/reset ordering
- HIGH: SHA deepen fallback only covers BASE_REF → added HEAD_REF deepen
- HIGH: Large-repo clone missing `git checkout HEAD` → added checkout step

### Remaining (Medium/Low — not auto-fixed)

- MEDIUM (NEW-6): `other` category is unreachable but appears in validation/display — cosmetic, no data integrity impact. Suggestion: either add a path pattern for `other` or remove from categorization enum.
- MEDIUM: `new_module` detection for root-level files always returns non-empty from `git ls-tree` — minor categorization quirk for files in repo root.
- MEDIUM: D13 label reused for two different concepts (source snapshot vs SHA resolution) — documentation clarity issue.
- LOW (NEW-7): Shallow-clone fallback missing `cd $CLONE_DIR` — Step 2.2 re-cd's immediately, so no functional impact.
- LOW: Substring containment boost can produce scores near 1.0 for short inputs — rare edge case.
- LOW: Phase 2 checkpoint uses different emoji vs Phase 1 — cosmetic only.

## PR

https://github.com/Whisker17/my-harness/pull/21

## Acceptance Criteria Status

- ✅ AC-1: Treeless clone (`--filter=blob:none --no-checkout`) — Step 2.1
- ✅ AC-2: Clone timeout (5 min) + cleanup — Step 2.1 with `timeout 300`
- ✅ AC-3: Fuzzy tag matching with similarity scoring — Step 2.2
- ✅ AC-4: Confidence thresholds (≥0.8 auto, ≥0.5/<0.8 candidates, <0.5 full list) — Step 2.2c
- ✅ AC-5: `base_sha`/`head_sha` via `git rev-parse` in diff-map.json — Step 2.3
- ✅ AC-6: diff-map.json with additions/deletions/hunks per file — Step 2.4b with `num_hunks`
- ✅ AC-7: diff-map.json matches WHI-228 schema — Step 2.6 self-validation + schema updates
- ✅ AC-8: Local repo path skips clone — Step 2.0 with `clone_method = "local"`
