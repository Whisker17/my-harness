# Review Context — WHI-222: convergence loop and final report generation

## Implementation Summary

Added Steps 6-8 to the harness-review-v2 SKILL.md, completing the v2 review pipeline:
- **Step 6 (Convergence Loop):** Orchestrates the outer loop — after Opus fixes, re-invoke Codex on the full branch diff, normalize with round merge, run Opus fix again, check convergence. Max 3 rounds.
- **Step 7 (Convergence Check):** Evaluates PASS → PASS_WITH_NOTES → STALE → MAX_ROUNDS → CONTINUE in order. Both stale and max-rounds produce ESCALATED status.
- **Step 8 (Final Report):** Generates review-report.md with branch, date, rounds, status, summary counts, findings detail table, and unresolved section (ESCALATED only).

Updated all existing placeholder references to WHI-222 with direct step references. Updated intro, output contract, error recovery table, and scope boundary.

Key design decisions:
- STALE is not a separate enum value — both stale and max-rounds produce `ESCALATED`. The distinction is logged for debugging.
- Report template intentionally extends the AC's minimal template with separate "Disputed" and "Open" lines for more granularity.
- `PREV_ACTIVE_IDS` is mutated inside Step 7b (convergence check) to update the outer loop state from Step 6a. This cross-step mutation is explicitly documented.

## Files Changed

- `skills/harness-review-v2/SKILL.md` — Added Steps 6-8 (convergence loop, convergence check, final report). Updated intro text, Step 4a quick exit reference, Step 5a reference, output contract, error recovery table, and scope boundary.

## Adversarial Review Findings

### Addressed (Critical/High)

1. **STALE ambiguity** — Clarified in Step 7c that both stale and max-rounds produce `ESCALATED`, not a separate enum value. Updated Scope Boundary.
2. **PREV_ACTIVE_IDS state mutation** — Added explicit comments in Step 6a (initialization) and Step 7b (update) documenting the cross-step state mutation.
3. **Round 3 diagram** — Fixed to say "exits ESCALATED unless PASS or PASS_WITH_NOTES" (was missing PASS_WITH_NOTES).
4. **Severity case mismatch** — Added note in Step 7c that severity values are uppercase per Step 4b normalization.
5. **Stale branch invariant** — Added comment that the stale branch is only reached when ACTIVE_COUNT > 0.
6. **Broken markdown fence** — Restructured Step 8c to avoid unclosed code fences.
7. **LOW_ONLY_COUNT undefined** — Added computation in Step 8a for the PASS_WITH_NOTES console banner.
8. **claim_title empty string** — Fixed jq fallback to handle empty string claim_title.

### Remaining (Medium/Low — not auto-fixed)

1. **Minor** — Step 4a quick-exit uses `$ROUND_N` before Step 6a initializes it (pre-existing from WHI-219, mitigated by `${ROUND_N:-1}` default in Step 4b)
2. **Minor** — Step 3b hardcodes `round-1` filename in parse-failure handler (pre-existing from WHI-219, affects round 2+ reuse)
3. **Minor** — Loop diagram doesn't show PREV_ACTIVE_IDS state update for every round (partially addressed by adding to Round 1/2)

## PR

https://github.com/Whisker17/my-harness/pull/13

## Acceptance Criteria Status

- [x] After Opus commits fixes, re-invoke `codex:adversarial-review` for the updated diff — Step 6c
- [x] Codex re-reviews the FULL branch diff (git diff dev...HEAD), not just the fix commit — Step 6c explicitly states this
- [x] Convergence check evaluates in order: PASS → PASS_WITH_NOTES → STALE → MAX_ROUNDS → continue — Step 7b if-elif chain
- [x] PASS: 0 active findings with severity in (critical, high, medium); active = status in (open, disputed) — Step 7b
- [x] PASS_WITH_NOTES: 0 medium+ active, but low-severity findings remain open — Step 7b
- [x] STALE: set of active finding IDs identical to previous round's active IDs; only evaluated from round 2+ — Step 7b with ROUND_N >= 2 guard
- [x] MAX_ROUNDS: current round >= 3 — Step 7b with ROUND_N >= MAX_ROUNDS
- [x] STALE and MAX_ROUNDS produce ESCALATED status — Step 7b and 7c note
- [x] Loop orchestration: round 1 → fix → round 2 → fix → round 3 → final — Step 6d diagram
- [x] Final report at .reviews/{branch_safe}/review-report.md with all required fields — Step 8b template
- [x] ESCALATED prints console message with unresolved count and report path — Step 8d
- [x] PASS/PASS_WITH_NOTES prints summary and exits successfully — Step 8d
