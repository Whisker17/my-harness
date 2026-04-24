# Review Context — WHI-197: Build harness-triage SKILL.md

## Implementation Summary

Built the `skills/harness-triage/SKILL.md` skill definition — the reactive course correction counterpart to harness-design. The skill formalizes mid-development findings into Linear issues with 4-category conflict detection (scope overlap, invalidation, dependency change, description staleness). Key design decisions: lightweight (no /office-hours or /plan-eng-review), hard confirmation gate before any Linear mutations, schema-compliant issue generation with self-validation, and idempotency guards on triage comments.

## Files Changed

- `skills/harness-triage/SKILL.md` — New file. Full skill definition with frontmatter, 7-step workflow (input resolution, fetch existing issues, conflict detection, draft changes, confirmation gate, execute changes, summary), error recovery table, state machine diagram, and scope boundary.

## Adversarial Review Findings

### Addressed (Critical/High)

**Round 1:**
- CRITICAL: Confirmation gate bypass via "Modify" loop — Fixed: explicit re-ask with same 3-option AskUserQuestion after every adjustment
- CRITICAL: Step 6b modifies issues without validating fetched description — Fixed: validates all 5 sections present before any modification
- CRITICAL: No team resolution — Fixed: added TEAM_ID to required variables with explicit resolution procedure in Step 1
- HIGH: Conflict detection keyword heuristic vague — Fixed: defined "substantive" as >5 chars, skip placeholder lines
- HIGH: Schema validation placeholder-stripping diverged from schema.md — Fixed: uses `^\[.*\]$` only (matching canonical schema)
- HIGH: No idempotency guard on triage comments — Fixed: checks list_comments before posting
- HIGH: AskUserQuestion / unused Grep/Glob in allowed-tools — Fixed: removed unused tools, added list_comments/list_teams/list_issue_statuses
- HIGH: Partial execution no re-entry detection — Fixed: idempotency markers in comments serve as re-entry guards

**Round 2:**
- CRITICAL: list_issues doesn't return full descriptions — Fixed: added per-issue get_issue calls (capped at 50) for conflict detection
- HIGH: list_projects unused in allowed-tools — Fixed: removed
- HIGH: TEAM_ID fallback only in error table — Fixed: added full resolution procedure in Step 1 body
- HIGH: 6b blockedBy instruction after code block — Fixed: integrated into save_issue code block
- HIGH: Step 2 retry has no bound — Fixed: max 2 retries (3 total attempts)
- HIGH: Case B "2 attempts" counter not mechanically defined — Fixed: explicit loop with ATTEMPT counter

### Remaining (Medium/Low — not auto-fixed)

- MEDIUM: Comment idempotency matching uses "same finding text" without exact match spec — Recommend exact first-line substring match in implementation
- MEDIUM: No "nothing to do" exit path when finding is purely informational — Low risk; Step 5 plan would show "No conflicts, no new issues" and user would cancel
- MEDIUM: 6c save_issue(state: canceled) no idempotency on re-invocation — Harmless: setting same state is a no-op
- MEDIUM: 3-round modification trigger boundary slightly ambiguous — Recommend clarifying: trigger STOP when 4th "Modify" would start
- LOW: State machine diagram "No" label fixed to "Cancel"
- LOW: "same as harness-design Step 6" coupling replaced with canonical schema reference

## PR

https://github.com/Whisker17/my-harness/pull/8

## Acceptance Criteria Status

- [x] `skills/harness-triage/SKILL.md` exists with full skill frontmatter (name, version, description, allowed-tools)
- [x] Skill accepts a finding as natural language input (with optional project ID prefix) — Case A/B/C in Step 1
- [x] Skill resolves the target project from CLAUDE.md context or explicit argument — Step 1 Cases A-C with branch detection
- [x] Skill fetches all non-Done issues in the project and analyzes conflicts — Step 2 with per-issue get_issue for full descriptions
- [x] Conflict detection covers 4 categories: scope overlap, invalidation, dependency change, description staleness — Step 3 sections 3a-3d
- [x] New issues are generated with all 5 schema sections and self-validated — Step 4a with validation rules matching schema.md
- [x] A confirmation gate (AskUserQuestion) is presented BEFORE any Linear writes — Step 5 with hard gate, explicit re-ask on Modify
- [x] Conflicting issues are updated with comments explaining what changed and why — Step 6b with idempotency-guarded triage comments
- [x] Summary output lists all created/modified/canceled issues with IDs and reasons — Step 7 structured output
- [x] Error recovery table covers: project not found, issue creation failure, conflict detection ambiguity — 11-row error recovery table
- [x] Skill does NOT auto-implement — only creates/modifies issues — Explicit in frontmatter, preamble, and scope boundary
