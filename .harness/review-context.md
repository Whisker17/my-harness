# Review Context — WHI-196: Add issue-driven development workflow to CLAUDE.md

## Implementation Summary

Added a new "Issue-Driven Development" section to CLAUDE.md that establishes Linear as the single source of truth for all code changes. The section includes three core principles (issues before code, no cowboy coding, living backlog), a 4-step Course Correction Workflow with conflict detection, and guidance for when/how to update issue descriptions. The section is placed after "Linear Workflow" and before "Schema Reference" as specified.

Key design decisions:
- All Linear mutations require explicit user approval (no auto-creation or auto-updates)
- Conflict detection queries 4 states: In Progress, Todo, Backlog, In Review
- API failure is handled by warning the user and waiting (not silently skipping)
- Course correction trigger is narrowed to explicit user requests (not casual observations)

## Files Changed

- `CLAUDE.md` — Added ~75 lines: "Issue-Driven Development" section with principles, course correction workflow (Steps 1-4), conflict detection table, and description update guidance

## Adversarial Review Findings

### Addressed (Critical/High) — Round 1

| Finding | Severity | Fix |
|---------|----------|-----|
| Invalid Linear state values (`started`/`unstarted`) | CRITICAL | Changed to `In Progress`, `Todo`, `In Review` |
| Unguarded mass issue mutation without user confirmation | CRITICAL | All mutations now require explicit user approval; "propose" language throughout |
| No API failure handling | CRITICAL | Added fallback: warn user and wait for decision |
| Scope overlap detection based on files (impossible) | HIGH | Changed to text-based detection against Architecture Notes/Acceptance Criteria |
| Confirmation contradiction (Principle 2 vs Step 2.3) | HIGH | Both now consistently require user confirmation |
| No-conflict report path undefined | HIGH | Step 3 explicitly states "no conflicts detected" when none found |
| Invalidation action contradicts no-unilateral-action principle | HIGH | All conflict actions are now proposals requiring approval |
| Over-broad trigger phrases | HIGH | Narrowed to explicit user requests with concrete examples |

### Addressed (High/Medium) — Round 2

| Finding | Severity | Fix |
|---------|----------|-----|
| API fallback violates core principle (silently proceeds) | HIGH | Changed to warn+wait instead of skip |
| Backlog state excluded from conflict detection | HIGH | Added `Backlog` to query list |
| No post-approval guidance (workflow ends at Step 3) | MEDIUM | Added Step 4 with execution and re-entry guidance |
| Heading levels wrong for Steps 1-3 | MEDIUM | Changed from `###` to `####` sub-headings |
| Deletion rule vs invalidation conflict | MEDIUM | Reconciled: superseded content is replaced, not just deleted |

### Remaining (Medium/Low — not auto-fixed)

| Finding | Severity | Recommendation |
|---------|----------|----------------|
| "Casual observation" exemption is subjective | MEDIUM | Inherently requires judgment; consider adding more trigger examples in a future iteration |
| Race condition: two concurrent sessions | MEDIUM | Architectural limitation of Claude Code; not fixable at CLAUDE.md level |
| PR body format lacks course correction audit trail | MEDIUM | Consider adding a "Course Corrections" section to PR template in a future issue |
| Living backlog principle overlaps with Course Correction Workflow | MEDIUM | Principle 3 is the general rule; Course Correction is the specific process — cross-reference could help but risks over-documentation |
| `<project-name>` origin unclear | LOW | Context-dependent; Claude infers from current Linear issue |
| Principle 2 confirmation is optional with no decision rule | LOW | Now moot — Principle 2 rewritten to always require confirmation |
| "Factually wrong" is undefined | LOW | Intentionally flexible; overly prescriptive rules would cause more harm |
| Hardcoded project name removed | LOW | Changed to `<project-name>` placeholder — resolved |

## PR

https://github.com/Whisker17/my-harness/pull/7

## Acceptance Criteria Status

- [x] CLAUDE.md contains a new "Issue-Driven Development" section establishing Linear as the single source of truth
- [x] A "Course Correction Workflow" subsection documents the process (expanded to 4 steps: user requests change, Claude checks conflicts and proposes, Claude reports and waits for approval, execute approved changes)
- [x] Conflict detection rules are documented: scope overlap, invalidation, dependency change, description staleness — with concrete proposed actions for each
- [x] The principles are clear: no cowboy coding, issues before code, living backlog
- [x] The section integrates naturally with the existing "Linear Workflow" section (placed after it, before "Schema Reference")
