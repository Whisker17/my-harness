# Review Context — WHI-234: Phase 6：验证代理（Agent subagent + 有界 prompt + fix-verify 循环）

## Implementation Summary

Added Phase 6 (Verification Agent) to the `harness-research-engineering` skill's multi-phase analysis pipeline. Phase 6 dispatches an independent Agent subagent as a Devil's Advocate reviewer to verify the top 10 claims from Phase 3's analysis. When disputes are found, a fix-verify loop (max 3 rounds) attempts resolution. The Phase 5 report generation was updated to consume verification data when available.

Key design decisions:
- Phase 6 is opt-in via the Phase 3 checkpoint ("Run verification first" option)
- Document ordering: Phase 6 precedes Phase 5 (matches data flow dependency)
- Verification subagent receives bounded ~8KB prompt, does NOT access the codebase
- Fix-verify loop dispatches Phase 3 recheck subagent WITH codebase access, then a new verification subagent
- Summary counts reflect initial reviewer assessments, not post-round resolution

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — the only file changed (+782/-758 net lines in round 1, +6/-6 in round 2)
  - Added `verification_agent` role definition with D2 design decision
  - Added `verification-report.json` schema with example and field reference
  - Added Phase 6 section (Steps 6.0-6.7): validation gate, claim selection, subagent dispatch, dispute detection, fix-verify loop, artifact assembly, user checkpoint
  - Updated Phase 5 to consume verification data: degradation table, data extraction, claim join logic, report template (Independent Verification section), validation checks
  - Updated Phase 3 checkpoint with Phase 6 invocation option
  - Updated TOC and document ordering (Phase 6 before Phase 5)
  - Updated error handling table with Phase 6 failure scenarios
  - Updated agent role and consumed-by metadata

## Adversarial Review Findings

### Round 1 — Addressed (Critical/High)

| # | Severity | Finding | Fix Applied |
|---|----------|---------|-------------|
| 1 | CRITICAL | Phase 6 never triggered — no invocation point | Added "Run verification first (Phase 6 — M2)" option to Phase 3 checkpoint |
| 2 | CRITICAL | TOC/document ordering inversion | Reordered Phase 6 before Phase 5 in TOC and document body |
| 3 | CRITICAL | ROUND counter off-by-one (total_rounds=4 fails validation) | Moved increment after cap check (`IF ROUND >= MAX_ROUNDS` before `ROUND += 1`) |
| 4 | HIGH | M2 label collision (Phase 4 vs Phase 6) | Disambiguated: comparison.json note says "when Phase 4 is implemented", Phase 6 labeled "M2 (verification)" |
| 5 | HIGH | summary.confirmed description contradicts validation math | Fixed to "Count of claims where reviewer_assessment == 'confirmed' (initial assessment)" |
| 6 | HIGH | Re-verify payload under-specified | Added recheck_context field to re-verify payload from Phase 3's recheck_notes |
| 7 | HIGH | Per-claim verification note format undefined | Added Verification field to Claims Analysis per-claim template |
| 8 | HIGH | Phase 3 recheck missing file-system paths | Added Context block with session_dir, clone_path, BASE_SHA, HEAD_SHA to recheck prompt |

### Round 1 — Also Addressed (Medium, fixed opportunistically)

| # | Finding | Fix Applied |
|---|---------|-------------|
| 9 | analysis.json/claims.json "Consumed by" missing Phase 6 | Updated both headers |
| 10 | Phase 5 abort condition says "three artifacts" | Changed to "three required artifacts" |
| 11 | D2 design decision referenced but never defined | Defined D2 in verification_agent role |
| 12 | Duplicate error handling paragraph | Removed duplicate |
| 13 | Clone cleanup comment says "Phase 5 in M1" | Updated for M2 lifetime |
| 14 | report_generation_agent role missing Independent Verification | Added to section list |
| 15 | Validation check #2 says "five" but lists six | Fixed to "5 or 6 depending on Phase 6" |
| 16 | summary.confirmed computation formula absent from Step 6.4 | Added explicit formula |
| 17-18 | "All claims verified" inconsistency | Standardized to "All reviewed claims verified" |

### Round 2 — Addressed (High)

| # | Severity | Finding | Fix Applied |
|---|----------|---------|-------------|
| 1 | HIGH | Example JSON: verification_status "verified" with disputes_unresolved=1 | Fixed summary to 0 unresolved disputes, consistent with "verified" status |
| 2 | HIGH | Example JSON: summary counts (10) don't match reviews array (2) | Fixed summary to match reviews array (1+1+0+0=2), added clarifying note |

### Remaining (Medium/Low — not auto-fixed)

| # | Severity | Description | Recommendation |
|---|----------|-------------|----------------|
| R2-3 | MEDIUM | clone_path/BASE_SHA/HEAD_SHA used in recheck prompt but not extracted in Step 6.0 | Step 6.0 extracts from analysis.json; diff-map.json vars need explicit extraction. Recommend adding CLONE_PATH extraction from diff-map.json in Step 6.0. |
| R2-4 | MEDIUM | reviewer_assessment_emoji placeholder used but never formally defined | Should define emoji mapping (✅ confirmed, ⚠️ partial, ❌ unconfirmed, 🔴 contradicted). Low impact — LLM will infer from context. |
| R2-5 | LOW | reviewer_concerns from re-verify rounds silently dropped | Loop accumulates reviews but doesn't merge concerns from subsequent rounds. Recommend appending re-verify concerns to reviewer_concerns array. |
| R1-19 | LOW | verification_status field name collision between schemas | Low impact — context makes clear which is per-claim vs aggregate. |

## PR

https://github.com/Whisker17/my-harness/pull/24

## Acceptance Criteria Status

- ✅ 使用 Agent tool 启动独立子代理，prompt 限制在 ~8KB — Step 6.2 dispatches via Agent tool with bounded prompt (~8KB budget documented)
- ✅ 子代理只接收 top 10 claims（按 significance 排序）— Step 6.1 implements significance-based selection with priority mapping table
- ✅ 子代理独立判定每个 claim 的 evidence 是否充分，输出 verification-report.md — Step 6.5 generates verification-report.md
- ✅ verification-report.md 包含：逐条 claim 的独立判定 + "Reviewer Concerns" section — Template includes both (Step 6.5)
- ✅ 如果子代理发现分歧（status 与 Phase 3 不同），标记为 dispute — Step 6.3 implements dispute detection with full status mapping table
- ✅ dispute 触发修正循环：Phase 3 重新检查 → 子代理 re-verify → 最多 3 轮 — Fix-verify loop with MAX_ROUNDS=3, ROUND incremented after cap check
- ✅ 3 轮后仍有分歧，保留双方意见，标记 verification_status: "partial" — Loop cap behavior documented in Step 6.3
- ✅ 无 dispute 时标记 verification_status: "verified" — Determination logic in Step 6.4
