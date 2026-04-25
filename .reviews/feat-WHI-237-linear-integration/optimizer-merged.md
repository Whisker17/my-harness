# Optimizer Findings — feat/WHI-237-linear-integration

## Summary

This PR adds an opt-in Linear progress-tracking integration to the `harness-research-engineering` pipeline skill. It introduces a new `## Linear Integration` section with state variables, four lifecycle steps (L.1–L.4), and injects `linear_phase_start / linear_phase_complete / linear_phase_failed` hooks at the start and end of every pipeline phase. The overall design is sound — graceful degradation on every API call, lazy sub-issue creation, and no pipeline interruption on Linear failures — but three substantive correctness gaps were found alongside three minor specification quality issues.

---

## Findings

### Finding 1: Parent issue marked Done before Phase 7 executes (M2 pipeline)

- **File**: `skills/harness-research-engineering/SKILL.md:3891` and `3944`
- **Severity**: 🔴 Critical
- **Category**: Correctness
- **Problem**: Step L.4 (triggered at Phase 5 completion) calls `save_issue(state: "Done")` on `LINEAR_PARENT_ISSUE_ID`. However, Phase 5 is explicitly described as "the M1 terminal phase" — in M2 pipelines, Phase 7 (Knowledge Index Management) still runs after Phase 5. Phase 7 calls `linear_phase_start(7, ...)` which creates a sub-issue with `parentId = LINEAR_PARENT_ISSUE_ID`. The result is a sub-issue in "In Progress" state whose parent is already "Done" — an invalid Linear state and confusing to any human reading the project. Phase 7's completion hook (`linear_phase_complete(7)`) then tries to update the sub-issue to "Done" but the parent remains Done regardless.
- **Suggested fix**: Move Step L.4 (final report comment + parent → Done) to after Phase 7 completes, not after Phase 5. For M1 pipelines (no Phase 7), trigger L.4 at Phase 5 completion. For M2 pipelines, trigger L.4 at Phase 7 completion. Concretely: replace the inline `linear_final_report_comment()` call in Phase 5's approval path with a conditional — "if Phase 7 will run (M2), defer; otherwise call now" — and add the L.4 call to Phase 7's completion hook.

---

### Finding 2: Enabling condition 2 is unreachable under current Input Resolution spec

- **File**: `skills/harness-research-engineering/SKILL.md:202–207` and `160`
- **Severity**: 🟡 Major
- **Category**: Correctness
- **Problem**: The `### Enabling Linear Integration` section lists two conditions that enable Linear: (1) user passes `--linear <project>` and (2) `linear_project` was resolved during Input Resolution. However, Input Resolution Step 1 (line 160) states: *"If `--linear` is not present, set `LINEAR_ENABLED = false`"* — this assignment happens during Step 1 parsing, before Step 2 (Linear project description lookup) executes. There is no subsequent instruction to set `LINEAR_ENABLED = true` from Step 2's output. Condition 2 is therefore unreachable: Step 2 can look up a project for URL extraction, but nothing ever sets `LINEAR_ENABLED = true` from that path. An LLM following this spec would set `LINEAR_ENABLED = false` unconditionally unless `--linear` is present, making condition 2 dead text.
- **Suggested fix**: Either (a) remove condition 2 from the Enabling section and document that `--linear` is the only activation path, or (b) add an explicit instruction in Input Resolution Step 2: *"If the user invocation references a Linear project and `linear_project` was resolved, also set `LINEAR_ENABLED = true` and `LINEAR_PROJECT = <resolved project name or ID>`."*

---

### Finding 3: Phase 7 has no failure hook

- **File**: `skills/harness-research-engineering/SKILL.md:4360` and `4364–4374`
- **Severity**: 🟡 Major
- **Category**: Completeness
- **Problem**: Every other phase with a start hook also has both a completion hook and a failure hook (or an explicit note that failure is rare). Phase 7 has `linear_phase_start(7, ...)` (line 3946) and `linear_phase_complete(7)` (line 4360) but no `linear_phase_failed(7, ...)` hook. Phase 7 has at least two hard-abort paths: (1) `internal-report.md` missing — aborts at Step 7.0, and (2) index directory creation fails — aborts with an error. In either case the Phase 7 sub-issue remains stuck in "In Progress" permanently with no indication of what happened.
- **Suggested fix**: Add `linear_phase_failed` hooks to the two abort paths in Phase 7:
  - In Step 7.0 when `internal-report.md` is not found: call `linear_phase_failed(7, "Phase 7 aborted: internal-report.md not found — Phase 5 must be completed first")`.
  - In the index directory creation failure path: call `linear_phase_failed(7, "Phase 7 aborted: index directory creation failed — <error>")`.

---

### Finding 4: Step L.4 error message is ambiguous when only the state-change call fails

- **File**: `skills/harness-research-engineering/SKILL.md:357–360`
- **Severity**: 🟢 Minor
- **Category**: Specification Quality
- **Problem**: Step L.4 makes two sequential MCP calls — `save_comment` (post analysis summary) and `save_issue(state: "Done")` (mark parent Done). The failure handler covers "either call" with a single error message: `"[LINEAR WARNING] Failed to post final report comment: <error>"`. If only the second call (`save_issue` state change) fails, the comment was already posted successfully, but the warning message says "Failed to post final report comment" — which is incorrect. A reader (human or LLM) would diagnose the wrong call. Additionally, when this failure occurs the parent issue silently stays "In Progress" with no note in the logged warning about that consequence.
- **Suggested fix**: Use separate error messages per call:
  - Comment failure: `"[LINEAR WARNING] Failed to post final report comment on parent issue <ID>: <error>"`
  - State-change failure: `"[LINEAR WARNING] Failed to mark parent issue <ID> as Done: <error>. Issue remains In Progress — manual update required."`

---

### Finding 5: `linear_final_report_comment()` is referenced as a function but never defined as one

- **File**: `skills/harness-research-engineering/SKILL.md:3891`
- **Severity**: 🟢 Minor
- **Category**: Specification Quality
- **Problem**: Phase 5's approval path (line 3891) instructs: *"Call `linear_final_report_comment()` (Step L.4 from the Linear Integration section)"*. Step L.4 is a prose block of instructions, not a named callable function. While a skilled LLM may infer the mapping, this introduces a naming gap: the function `linear_final_report_comment()` is named by analogy to `linear_phase_start()` / `linear_phase_complete()` / `linear_phase_failed()`, but unlike those three, it has no formal definition block with that name. Under close reading, a reader has to trust the parenthetical cross-reference.
- **Suggested fix**: Add a header to Step L.4 that formally introduces the function name: e.g., *"**On report approved (success)**, call `linear_final_report_comment()`:"* — mirroring the pattern used in Step L.3 for `linear_phase_start`, `linear_phase_complete`, and `linear_phase_failed`.

---

### Finding 6: `\n` escape sequences in Step L.2 `description` field violate MCP tool contract

- **File**: `skills/harness-research-engineering/SKILL.md:251`
- **Severity**: 🟢 Minor
- **Category**: Correctness
- **Problem**: The `description` field template in Step L.2 uses `\n` escape sequences:
  ```
  description: "Automated protocol analysis run.\n\nChain: <chain>\nUpgrade: <upgrade_name>\nSource: <announcement_url>\nRepo: <repo>\n\nCreated by harness-research-engineering v1."
  ```
  The MCP server instructions for `linear-server` explicitly state: *"When passing string values to tools, send the content directly without escape sequences. For example, use real newlines in markdown content rather than literal backslash-n (`\n`) characters."* An LLM following this spec literally would produce a description with literal `\n` characters rather than actual line breaks in Linear.
- **Suggested fix**: Rewrite the description template using actual line breaks (markdown block or multi-line literal form), consistent with how `body:` content is specified in Step L.4's `save_comment` call (which correctly uses `|` block scalar style).

---

### Finding 7: Three unused tools declared in `allowed-tools`

- **File**: `skills/harness-research-engineering/SKILL.md:16–21`
- **Severity**: 🟢 Minor
- **Category**: Completeness
- **Problem**: The frontmatter declares six Linear MCP tools in `allowed-tools`. Three of them are never referenced anywhere in the specification body:
  - `mcp__linear-server__get_issue` — not called in any step
  - `mcp__linear-server__list_issues` — not called in any step
  - `mcp__linear-server__save_project` — not called in any step
  This inflates the permission surface unnecessarily. If these were intended for future steps, they should be added when those steps are specified.
- **Suggested fix**: Remove `mcp__linear-server__get_issue`, `mcp__linear-server__list_issues`, and `mcp__linear-server__save_project` from `allowed-tools`. Only `get_project`, `save_issue`, and `save_comment` are actually used.

---

## Statistics

- **Total findings**: 7
- **By severity**:
  - 🔴 Critical: 1 (Finding 1 — premature parent Done in M2)
  - 🟡 Major: 2 (Finding 2 — unreachable condition 2; Finding 3 — Phase 7 no failure hook)
  - 🟢 Minor: 4 (Findings 4–7)

---

## Overall Verdict

- **Correctness**: patch is **incorrect**
- **Explanation**: Finding 1 is a behavioral correctness bug with real observable consequences in M2 runs: the parent Linear issue will be marked Done while Phase 7 is still executing and its sub-issue is In Progress — an inconsistent and misleading state for any team monitoring the project. Finding 2 means condition 2 of the enabling logic is dead text that an LLM following the spec strictly cannot reach, which may cause confusion if condition 2 is ever intended to be meaningful (e.g., allowing Linear integration when the user passes a project name without `--linear`). Finding 3 leaves Phase 7 sub-issues permanently stuck In Progress on abort with no recovery signal. The three minor findings are quality improvements rather than blockers, but Findings 1–3 should be resolved before merge.
