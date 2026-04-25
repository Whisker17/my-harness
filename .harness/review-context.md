# Review Context — WHI-219: feat(v2): skill skeleton, pre-flight checks, and Codex invocation

## Implementation Summary

Created `skills/harness-review-v2/SKILL.md` — the foundational skill file for the cross-model convergence review pipeline (harness-review-v2). The skill implements:

1. **Frontmatter** — name, version, description, triggers (`harness-review-v2`, `v2 review`), and allowed-tools (Bash, Read, Write, Edit, Agent, Skill, plus Linear MCP tools)
2. **Pre-flight checks** — Codex CLI verification, clean working tree check, branch-safe name computation with nested slash handling, `.reviews/` artifacts directory creation, PR detection via `gh pr view` with local diff fallback
3. **Codex invocation** — PR mode via `codex:adversarial-review` Skill tool, local diff fallback via `codex:rescue` with embedded diff, 5-minute timeout with 1 retry
4. **Output parsing** — JSON extraction from Codex output (verdict, summary, findings[], next_steps[]), parse failure recovery with raw output archiving
5. **Error recovery table** — actionable error messages for every failure mode
6. **Output contract** — defines artifact paths consumed by downstream sub-issues (WHI-220, WHI-222)

No deviations from the spec. The Architecture Notes in the issue were followed precisely.

## Files Changed

- `skills/harness-review-v2/SKILL.md` — new file (305 lines). Complete skill skeleton with frontmatter, preamble, pre-flight checks (Steps 1a-1d), Codex invocation (Steps 2a-2b), output parsing (Steps 3a-3c), output contract, error recovery reference, and scope boundary.

## Adversarial Review Findings

### Addressed (Critical/High)

None — adversarial review found no Critical or High findings. Escalation score was -10 (docs-only change), resulting in Skip depth.

### Remaining (Medium/Low — not auto-fixed)

None.

## PR

https://github.com/Whisker17/my-harness/pull/10

## Acceptance Criteria Status

- [x] `skills/harness-review-v2/SKILL.md` created with proper frontmatter (name, version, description, triggers, allowed-tools) — lines 1-21
- [x] Pre-flight checks: `codex --version` succeeds, `git status --porcelain` is empty, `.reviews/{branch_safe}/` directory created — Steps 1a, 1b, 1c
- [x] PR detection: `gh pr view --json number,url,baseRefName` succeeds -> store PR metadata — Step 1d
- [x] Local diff fallback: when `gh pr view` fails, fall back to `git diff dev...HEAD`, emit warning — Step 1d
- [x] Codex invocation: Skill tool -> `codex:adversarial-review` with no args (auto-detects PR) — Step 2a
- [x] For local diff fallback: alternative Codex invocation path that passes diff content — Step 2b
- [x] Codex output parsed as JSON: extract verdict, summary, findings[], next_steps[] — Step 3a
- [x] Timeout: 5-minute limit, retry once on timeout, ERROR after 2 failures — Steps 2a, 2b
- [x] Error messages are actionable: install, authenticate, no PR warnings — Steps 1a, 1b, 1d, 2a
- [x] Raw Codex output saved to `.reviews/{branch_safe}/codex-raw-round-{N}.txt` on parse failure — Step 3b
