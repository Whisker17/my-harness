# Review Context — WHI-220: findings normalization and re-raise detection

## Implementation Summary

Added Step 4 (Findings Normalization) to the harness-review-v2 SKILL.md. This step takes raw Codex review output and normalizes it into a structured `schema_version: 1` findings format with sequential `F-NNN` IDs. Key features include:

- Normalization mapping from Codex output fields to harness findings schema
- Nullable file/line fields for architectural findings
- Quick exit path when Codex approves with no medium+ findings
- Re-raise detection via exact title match OR same file + overlapping line range (±15 lines)
- Round N+1 merge logic with full status transition coverage (confirmed_fixed, reopened, disputed)
- `mktemp`-based temp files instead of fixed paths

## Files Changed

- `skills/harness-review-v2/SKILL.md` — Added Step 4 (findings normalization, re-raise detection, round merge, quick exit), updated intro, output contract, error recovery reference, and scope boundary

## Adversarial Review Findings

### Addressed (Critical/High → fixed in round 1)

| Finding | Severity | Fix Applied |
|---------|----------|-------------|
| F1: Quick-exit severity gate misses lowercase Codex output | Major | Added `ascii_upcase` to severity comparison in quick-exit check |
| F2: Heredoc emits literal `<ROUND_N>` (invalid JSON) | Major | Replaced heredoc with `jq -n --argjson round` |
| F3: Merge uses stale verdict/summary from previous round | Major | Extract verdict/summary from `NEW_CODEX` via `--arg` |
| F4: `confirmed_fixed→open` doesn't clear `round_closed` | Major | Added `| .round_closed = null` to regression reopen branch |
| M1: Re-raise map overwrites when two findings match same existing | Major | Added `claimed` array tracking; already-claimed findings excluded from match |

### Also Fixed (Minor/Nit — addressed proactively)

| Finding | Severity | Fix Applied |
|---------|----------|-------------|
| F5: Intermediate normalization skips severity validation | Minor | Added full severity validation guard to merge intermediate step |
| F6: `null == null` title match false positive | Minor | Added non-null guards to Match 1 in re-raise detection |
| F7: Validation echoes error but doesn't halt | Minor | Replaced misleading comment with `exit 1` |
| M2: `claim_title=null` corrupts future re-raise detection | Minor | Default to empty string: `(.value.title // "")` |
| M3: `/tmp/new_normalized.json` fixed clobber-prone path | Nit | Use `mktemp` for temp file |

### Remaining (Medium/Low — not auto-fixed)

None — all findings were addressed.

## PR

https://github.com/Whisker17/my-harness/pull/11

## Acceptance Criteria Status

- ✅ Codex output mapped to findings.json with `schema_version: 1`
- ✅ Each finding has: id (F-001 sequential), severity, claim (title + body), file (nullable), line_start (nullable), line_end (nullable), suggested_fix, status ("open"), resolution (null), round_opened, round_closed (null)
- ✅ File and line fields are null for architectural findings
- ✅ Findings written to `.reviews/{branch_safe}/findings-round-{N}.json`
- ✅ Quick exit: if Codex verdict = "approve" AND 0 medium+ findings → status PASS
- ✅ Round N+1 merge logic: resolved→confirmed_fixed if not re-raised; re-raised→open
- ✅ Re-raise detection: exact title match OR (same file AND overlapping line range ±15 lines)
- ✅ Previously rebutted findings re-raised by Codex → status becomes "disputed"
- ✅ New findings not in previous rounds get new sequential IDs continuing from last used
