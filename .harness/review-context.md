# Review Context — WHI-236: 公开摘要输出（public 字段过滤 + 独立审批门控）

## Implementation Summary

Added Phase 8 (Public Summary Output) to the harness-research-engineering pipeline SKILL.md. Phase 8 generates a public-facing summary from the internal report and knowledge index public fields, suitable for external stakeholders. Key design decisions:

- Follows the same step structure as existing phases (input validation → extraction → agent dispatch → validation gate → user checkpoint → finalize)
- Uses a `public_communications_writer` agent role with strict "no code" constraints
- Section-by-section approval gating (unlike Phase 5's whole-report approval) to give users fine-grained control
- Language configuration (en/zh) via `--lang` flag
- Code-leak validation gate with precise regex patterns to prevent accidentally leaking internal details

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — Added:
  - Table of Contents entry for Phase 8
  - Agent role #8 (`public_communications_writer`)
  - Full Phase 8 section (Steps 8.0–8.6) with input validation, public-safe extraction, summary generation, draft validation, section-by-section approval, assembly and finalization
  - Phase 8 error handling table
  - Phase 8 rows in the global D9 error handling reference table
  - Phase 8 entry in the Failure and Abort section
  - Routing from Phase 7 Step 7.6 to Phase 8
  - Updated agent count from "Six" to "Seven"

## Adversarial Review Findings

### Addressed (Critical/High)

| Finding | Description | Fix Applied |
|---------|-------------|-------------|
| #1 Phase 8 never triggered | No routing from Phase 7 to Phase 8 | Added AskUserQuestion at end of Phase 7 Step 7.6 offering to proceed to Phase 8 |
| #2 Missing from D9 table + stale count | Phase 8 absent from global error table; "Six agent roles" stale | Added Phase 8 rows to D9 table; updated count to "Seven" |
| #3 Code-leak validator false positives | Ambiguous file-path check would fire on source URLs | Replaced with precise regex patterns excluding URLs; added more file extensions (.rs, .yaml, .toml, etc.) |
| #4 Section assembly heading ambiguity | Unclear whether extracted sections include `##` heading line | Made explicit: extraction INCLUDES heading; assembly template documented not to add extra headings |

### Remaining (Medium/Low — not auto-fixed)

| Finding | Severity | Description | Recommendation |
|---------|----------|-------------|----------------|
| #5 Language not persisted | 🟢 Minor | `--lang zh` flag lost on re-invocation | Consider persisting to `$SESSION_DIR/lang.cfg` |
| #6 Chinese header validation | 🟢 Minor | Validator hardcodes "公开摘要" but template doesn't specify Chinese title | Add explicit Chinese title template or loosen validation |
| #7 Knowledge index lookup | 🟢 Minor | Uses chain+upgrade_name but not full dedup_key | Reuse Phase 7's dedup_key for robust matching |
| #8 `line \d+` false positives | ⚪ Nit | Pattern may match natural language use of "line" near numbers | Tighten to `:L\d+` or `at line \d+` only |
| #9 Missing malformed markdown scenario | ⚪ Nit | Error table omits "agent returns malformed markdown" | Add row for structural malformation handling |

## PR

https://github.com/Whisker17/my-harness/pull/27

## Acceptance Criteria Status

- [x] From internal-report.md and knowledge index public fields generate public summary (Step 8.1, 8.2)
- [x] Summary structure: Overview → Key Changes → Impact Assessment → Verification Status (Step 8.2 template, validation check 2)
- [x] No code snippets, file paths, line numbers, internal analysis notes (filter rules + validation gate with precise regex)
- [x] Language configurable (en/zh) via `--lang` flag (Step 8.0, 8.2 LANG_INSTRUCTION)
- [x] User checkpoint: section-by-section approval gating (Step 8.5)
- [x] Output `{workdir}/public-summary.md` (Step 8.6)
- [x] Disclaimer at end (DISCLAIMER variable, validation check 4)
