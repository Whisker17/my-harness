# Review Context — WHI-237: Linear 集成（opt-in + lazy issue 创建 + graceful degradation）

## Implementation Summary

Added opt-in Linear progress tracking to the harness-research-engineering pipeline. The integration creates a parent Linear issue and lazy sub-issues per phase, with graceful degradation on all API failures. Key design decisions: `--linear` flag is the only activation path (D14), sub-issues are created lazily as each phase starts (D5), and all Linear API calls are wrapped with warning logs that never block the pipeline.

## Files Changed

- `skills/harness-research-engineering/SKILL.md` — Added new `## Linear Integration` section with 4 lifecycle steps (L.1–L.4), added `linear_project` to Input Resolution table, inserted `linear_phase_start/complete/failed` hooks at all 7 phase boundaries, updated Methodology section to include Linear status, updated Failure and Abort section with Linear cleanup behavior.

## Adversarial Review Findings

### Addressed (Critical/High)

1. **Finding 1 — Parent issue marked Done before Phase 7 (Critical)**: Fixed by deferring Step L.4 from Phase 5 to Phase 7 completion in M2 pipelines. Phase 5 now only triggers L.4 when Phase 7 won't run.

2. **Finding 2 — Unreachable enabling condition 2 (Major)**: Fixed by removing condition 2 entirely. `--linear` flag is now documented as the single activation path.

3. **Finding 3 — Phase 7 missing failure hook (Major)**: Fixed by adding `linear_phase_failed` calls + `linear_final_report_comment()` to Phase 7's two abort paths in the error handling table.

4. **Finding 4 — Ambiguous Step L.4 error message (Minor)**: Fixed by splitting into separate messages for comment failure vs state-change failure.

5. **Finding 5 — `linear_final_report_comment()` not formally defined (Minor)**: Fixed by adding formal function name in Step L.4 header.

6. **Finding 6 — `\n` escape sequences violating MCP contract (Minor)**: Fixed by replacing with block scalar (`|`) style.

### Remaining (Medium/Low — not auto-fixed)

1. **Finding 7 — Three unused tools in allowed-tools (Minor)**: `get_issue`, `list_issues`, `save_project` were present before this PR (from WHI-227). Out of scope for WHI-237.

## PR

https://github.com/Whisker17/my-harness/pull/28

## Acceptance Criteria Status

- [x] 默认关闭 — only enabled with `--linear` flag; `LINEAR_ENABLED = false` by default
- [x] 不传 Linear 参数时管线正常运行 — all hooks check `LINEAR_ENABLED == false` → no-op
- [x] 启用时创建父 issue — Step L.2 creates "Protocol Analysis: {chain} {upgrade_name}"
- [x] 每个 Phase 开始时 lazy 创建 sub-issue — Step L.3 `linear_phase_start()` at all 7 phases
- [x] sub-issue 状态跟踪 — `linear_phase_complete()` → Done, `linear_phase_failed()` → In Progress + comment
- [x] 最终报告完成后在父 issue 添加评论 — Step L.4 at M1 Phase 5 / M2 Phase 7 terminal
- [x] Linear API 调用失败时不阻断管线 — every call has try-catch, logs `[LINEAR WARNING]`, continues
