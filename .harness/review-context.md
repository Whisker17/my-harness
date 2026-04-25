# Review Context — WHI-235: Phase 7 Knowledge Index Management

## Implementation Summary

Added the complete Phase 7 (Knowledge Index Management) section to `harness-research-engineering/SKILL.md`. Phase 7 persists analysis results to `~/.gstack/research/research-index.jsonl` as append-only JSONL entries with public/internal field separation. Implementation includes dedup check with composite key, malformed JSON resilience, atomic overwrite operations, and comprehensive error handling.

Key decisions:
- Dedup key uses all-lowercase fields for case-insensitive matching (addresses D4)
- Repo URL normalization is explicit with 5-step rules (strip protocol, hostname, .git, trailing slash)
- Overwrite operation is atomic: filter + append + mv in single pass with cleanup trap
- Write verification failure blocks the success checkpoint (no false success)
- Claims summary field names are explicitly cross-referenced with analysis.json schema

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — Added Phase 7 section (Steps 7.0-7.6), knowledge_index_agent role, research-index.jsonl schema, updated ToC, validation summary table, D9 error handling table, and Failure/Abort section

## Adversarial Review Findings

### Addressed (Critical/High)

| ID | Severity | Description | Fix |
|----|----------|-------------|-----|
| C1 | CRITICAL | Non-atomic overwrite creates corruption window | Made overwrite atomic: filter + append in temp file, then single mv |
| C2 | CRITICAL | mktemp temp file leaks on failure | Added trap for cleanup, temp file in same directory as index |
| H1 | HIGH | Dedup key case-sensitive on upgrade_name | Lowercase all components in dedup_key |
| H2 | HIGH | No repo URL normalization algorithm | Added explicit 5-step normalization rules with examples |
| H3 | HIGH | Write verification non-fatal, shows success after corruption | Verification failure now blocks Step 7.6 success banner |
| H4 | HIGH | claims_summary field name mismatch not cross-validated | Added explicit mapping table and missing-field warnings |
| H5 | HIGH | full_claims join key unspecified | Specified join on claim.id == claims_analyzed[].claim_id |
| H6 | HIGH | trap cleared before confirming mv success | Added mv failure guard with abort and recovery info |

### Remaining (Medium/Low — not auto-fixed)

| ID | Severity | Description | Recommendation |
|----|----------|-------------|----------------|
| M1 | MEDIUM | Phase numbering gap in ToC (1,2,3,5,7) | Cosmetic — matches the actual phase numbers used in the project |
| M2 | MEDIUM | Session dir recovery glob injection | Mitigated by Phase 1 slugification which strips special chars |
| M3 | MEDIUM | Executive summary truncation at non-sentence boundary | Consider adding sentence-boundary detection in future |
| M4 | MEDIUM | contradicted field forward-compatibility hazard | Document in schema when Phase 6 verification is implemented |
| M5 | MEDIUM | Informational checkpoint can't rollback | By design — append-only. Dedup handles re-runs. |
| M6 | MEDIUM | ARTIFACTS_STATUS variable defined but unused | Remove or reference in Step 7.2; low impact |
| M7 | MEDIUM | executive_summary truncation byte-unsafe for UTF-8 | Specify "500 Unicode characters" in future |
| M8 | MEDIUM | evidence_map_path base not guaranteed consistent | RESEARCH_DIR is hardcoded; document if made configurable |
| L1 | LOW | schema_version has no migration path | Document when schema v2 is needed |
| L2 | LOW | Total entry count includes malformed lines | Fixed — now counts parseable entries only |
| L3 | LOW | generated_at semantics inconsistent | The "current time at Phase 7" interpretation is simpler and documented |
| L4 | LOW | Overwrite bash snippet used placeholder notation | Fixed — uses bash variables |
| L5 | LOW | total_claims may under-count if Phase 3 truncated | Pre-existing limitation from Phase 3 spec |
| L6 | LOW | Step 7.6 had no explicit skip guard | Fixed — added explicit guard |

## PR

https://github.com/Whisker17/my-harness/pull/25

## Acceptance Criteria Status

- [x] 索引文件位于 `~/.gstack/research/research-index.jsonl` — Step 7.1 defines this path
- [x] 每次分析完成后 append 一条 JSONL 记录 — Step 7.5 appends single-line JSON
- [x] dedup 检查：写入前查找 chain+upgrade_name+repo — Step 7.4 with composite key
- [x] 发现重复时提供三选一：overwrite/keep-both/skip — Step 7.4 AskUserQuestion
- [x] 索引条目包含 public 字段集和 internal 字段集 — Schema + Step 7.3
- [x] public 字段：chain, upgrade_name, source_url, executive_summary, claims_summary, generated_at — Schema field reference table
- [x] internal 字段：repo, base_sha, head_sha, base_ref, head_ref, full_claims, evidence_map_path, verification_status, unclaimed_changes_count — Schema field reference table
- [x] 读取时能处理 malformed JSON 行（跳过 + 警告） — Step 7.4 malformed JSON handling
- [x] 目录不存在时自动创建 `~/.gstack/research/` — Step 7.1 mkdir -p
