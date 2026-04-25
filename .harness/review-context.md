# Review Context — WHI-232: Phase 5 internal report generation (M1 deliverable + per-phase error handling)

## Implementation Summary

Replaced the Phase 5 placeholder in `skills/harness-research-engineering/SKILL.md` with a complete report generation specification. The implementation covers:

- **Graceful degradation (D9):** Phase 5 validates all three upstream artifacts (claims.json, diff-map.json, analysis.json) and generates partial reports when any are missing/corrupt, marking unavailable sections with `[DATA UNAVAILABLE]` markers.
- **Report template:** Structured internal report with Executive Summary, Claims Analysis (per-claim with evidence), Unclaimed Changes, Methodology, and Raw Data References sections.
- **User checkpoint:** Mandatory approval step before finalizing the report, with options to edit, regenerate sections, or abort.
- **Agent role update:** Updated `report_generation_agent` definition to M1 scope (internal report only, no public summary per D15).
- **Error handling reference table (D9):** Comprehensive table documenting failure scenarios and recovery actions across all pipeline phases.

Key design decisions:
- Phase 5 NEVER aborts unless ALL artifacts are missing/corrupt (always attempts to produce output)
- Claim-to-analysis join explicitly handles mismatches (orphaned analysis entries skipped, unmatched claims marked `not_analyzed`)
- Validation gate uses regex pattern matching for claim counting to avoid false positives
- Auto-fix uses heading-to-heading replacement strategy for section splicing

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — Major update: replaced Phase 5 placeholder with ~350 lines of implementation; updated agent role definition; updated ToC entry

## Adversarial Review Findings

### Addressed (Critical/High)

1. **CRITICAL — All-corrupt bypass:** Abort condition now checks for any artifact with status "available" or "partial", not just "missing" count. Fixed.
2. **CRITICAL — Claim-to-analysis join mismatches:** Added explicit handling for orphaned analysis entries (skipped with warning) and unmatched claims (marked `not_analyzed`). Fixed.
3. **CRITICAL — Agent output code fence wrapping:** Strengthened output instructions to explicitly say "Begin your output IMMEDIATELY with the heading" and "Do NOT add any preamble". Fixed.
4. **HIGH — analysis.json partial status underspecified:** Added explicit degradation rows for each sub-field combination (claims_analyzed valid/missing, unreported_changes valid/missing). Fixed.
5. **HIGH — Validation claim count false positives:** Changed to regex pattern `### Claim \d+:` matching instead of plain string match. Fixed.
6. **HIGH — Auto-fix section splicing underspecified:** Specified heading-to-heading replacement strategy with fallback to insert at correct position. Added no-duplicate-sections check. Fixed.
7. **HIGH — Section regeneration underspecified:** User checkpoint now references the same auto-fix strategy from Step 5.4. Fixed.

### Remaining (Medium/Low — not auto-fixed)

1. **MEDIUM — Session directory recovery requires CHAIN_SLUG/UPGRADE_SLUG:** These variables may not be defined on re-invocation. The skill's general architecture already requires these from Mode Selection, and Phase 5 runs in-session, so this is an edge case that should be documented but doesn't block M1 validation.
2. **MEDIUM — Contradicted status requires semantic analysis:** The Contradicted status is derived from analysis_notes content with no threshold defined. Acceptable for M1 — the LLM will use judgment, and the user checkpoint catches misclassifications.
3. **MEDIUM — Heading matching is exact string:** Validation checks use exact heading strings. Minor heading variations by the agent would trigger unnecessary auto-fix. Acceptable for M1 — the prompt template is very explicit about heading text.
4. **MEDIUM — Claims breakdown display when analysis.json missing:** Counts may show as 0/0/0/N when N is also uncertain. Acceptable — the degradation notes section in the display already explains what's missing.
5. **MEDIUM — Agent preamble risk:** If agent emits text before the heading, validation check 1 catches it immediately. This is the intended behavior.
6. **MEDIUM — Error table omits "Phase 3 never ran" case:** This is implicitly covered by the analysis.json "missing" status in the degradation table. Could be made more explicit in a future iteration.
7. **LOW — ToC anchor for Failure and Abort:** Anchor is unchanged and remains valid.
8. **LOW — D15 not cross-referenced:** D15 refers to the engineering review decision documented in the Linear issue description. Adding a formal anchor would be a nice-to-have.

## PR

https://github.com/Whisker17/my-harness/pull/23

## Acceptance Criteria Status

- [x] Reads claims.json, diff-map.json, analysis.json (evidence-map.json in issue = analysis.json in schema) — Step 5.0 + 5.1
- [x] Report structure: Executive Summary -> Claims Analysis -> Unclaimed Changes -> Methodology -> Raw Data References — Step 5.2 template
- [x] Per-claim display: text, status (confirmed/partial/unconfirmed/contradicted), evidence, code location — Step 5.2 template Claims Analysis section
- [x] Unclaimed Changes section lists code-first delta findings — Step 5.2 template
- [x] Report writes to `{workdir}/internal-report.md` — Step 5.3
- [x] Graceful degradation for partial upstream failures with [DATA UNAVAILABLE] markers — Step 5.0 degradation table
- [x] User checkpoint with approval before save — Step 5.5
- [x] Metadata header: repo URL, base/head SHA, source URL, generation time — Step 5.2 template header
