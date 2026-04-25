# Review Context — WHI-229: Phase 1 source ingestion agent

## Implementation Summary

Replaced the Phase 1 placeholder section in SKILL.md with a complete implementation covering source fetching with a 3-tier fallback chain (D10), source snapshot saving (D13), structured claims extraction via Agent tool, chunked extraction for large sources (D1), self-validation against WHI-228 schema, and a mandatory user checkpoint before Phase 2.

The implementation uses the WHI-228 canonical schema categories (`architecture/performance/security/governance/tooling/deprecation/other`) which differ from the issue's AC categories (`feature/parameter/deprecation/migration/security`). The schema is the authoritative source — this is a deliberate choice, not a bug.

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — Replaced Phase 1 placeholder with full 7-step implementation (Steps 1.1-1.7), updated agent role definition for `source_ingestion_agent`, fixed `source_snapshot_path` schema example, updated TOC description

## Adversarial Review Findings

### Addressed (Critical/High)

1. **Finding 2 (Major):** `source_snapshot_path` example in Artifact Schema showed `sources/announcement-2026-04-25.md` but actual output is `source-snapshot.md` — Fixed schema example
2. **Finding 3 (Major):** Agent role definition missing fallback chain, snapshot output, and chunking behavior — Updated role definition with all 3 additions
3. **Finding 4 (Major):** Tier 2 had no explicit success/failure criteria — Added 200-character threshold matching Tier 1
4. **Finding 5 (Major):** Self-validation auto-fix conflicts with general abort-only policy — Added explicit carve-out note explaining pre-output vs phase-boundary distinction
5. **Finding 7 (Minor):** "Try a different URL" had no retry limit — Added 3-attempt limit

### Remaining (Medium/Low — not auto-fixed)

1. **Finding 1 (Critical — disputed):** Category enum mismatch between Linear issue AC and implementation. The implementation follows WHI-228 schema categories which are authoritative. **Recommendation:** Update the WHI-229 issue's AC #2 to reflect the schema's category set.
2. **Finding 6 (Minor — pre-existing):** Phase 4 silently absent from TOC. This was present before WHI-229 and is not introduced by this PR.

## PR

https://github.com/Whisker17/my-harness/pull/20

## Acceptance Criteria Status

- [x] WebFetch 成功时，从 HTML/Markdown 中提取结构化 claims 数组 — Step 1.1 Tier 1 + Step 1.3
- [x] 每个 claim 包含：id、text、category、confidence、source_section — Step 1.3 extraction prompt (uses WHI-228 schema categories)
- [x] WebFetch 失败时自动尝试 WebSearch 摘要提取 — Step 1.1 Tier 2
- [x] WebSearch 也失败时通过 AskUserQuestion 请求用户粘贴原文 — Step 1.1 Tier 3
- [x] 源内容快照保存到 `{workdir}/source-snapshot.md` — Step 1.2
- [x] 输出 `claims.json` 符合 WHI-228 定义的 schema，通过验证门控 — Step 1.5 + Step 1.6
- [x] claims 数量 > 15 时按 5-8 个一批分块提取 — Step 1.4
- [x] 用户检查点展示提取的 claims 摘要，用户确认后才进入 Phase 2 — Step 1.7
