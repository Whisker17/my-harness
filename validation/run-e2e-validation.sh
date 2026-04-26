#!/usr/bin/env bash
# run-e2e-validation.sh — E2E validation runner for harness-research-engineering pipeline
# Part of WHI-238: Base Azul E2E validation
#
# This script orchestrates the full E2E validation:
# 1. Sets up timing instrumentation
# 2. Invokes the pipeline via the skill
# 3. Validates output artifacts
# 4. Records metrics and produces a summary
#
# IMPORTANT: This script does NOT run the pipeline automatically.
# The pipeline is invoked manually via:
#   /harness-research-engineering analyze Optimism Isthmus <announcement_url> <repo_url>
#
# This script provides pre-flight checks, timing harness, and post-run validation.
#
# Usage:
#   ./run-e2e-validation.sh preflight    — Check prerequisites
#   ./run-e2e-validation.sh timing-start — Record pipeline start time
#   ./run-e2e-validation.sh timing-phase <phase_num> <status> — Record phase completion
#   ./run-e2e-validation.sh validate <session_dir> — Run artifact validation
#   ./run-e2e-validation.sh report <session_dir>   — Generate validation report

set -euo pipefail

VALIDATION_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMING_FILE="/tmp/e2e-validation-timing.json"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ═══════════════════════════════════════════
# PREFLIGHT
# ═══════════════════════════════════════════
preflight() {
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  E2E Validation — Pre-flight Checks (WHI-238)           ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  ERRORS=0

  # Check git
  if command -v git &>/dev/null; then
    echo -e "  ${GREEN}✅${NC} git available"
  else
    echo -e "  ${RED}❌${NC} git not found"
    ERRORS=$((ERRORS + 1))
  fi

  # Check python3
  if command -v python3 &>/dev/null; then
    echo -e "  ${GREEN}✅${NC} python3 available"
  else
    echo -e "  ${RED}❌${NC} python3 not found (needed for JSON validation)"
    ERRORS=$((ERRORS + 1))
  fi

  # Check research directories
  if [ -d "$HOME/.gstack/research" ]; then
    echo -e "  ${GREEN}✅${NC} ~/.gstack/research/ exists"
  else
    echo -e "  ${YELLOW}⚠️${NC}  ~/.gstack/research/ missing (will be created by pipeline)"
  fi

  if [ -d "$HOME/.gstack/research/sessions" ]; then
    echo -e "  ${GREEN}✅${NC} ~/.gstack/research/sessions/ exists"
  else
    echo -e "  ${YELLOW}⚠️${NC}  ~/.gstack/research/sessions/ missing (will be created by pipeline)"
  fi

  # Check SKILL.md exists
  if [ -f "$HOME/.claude/skills/harness-research-engineering/SKILL.md" ]; then
    echo -e "  ${GREEN}✅${NC} SKILL.md installed"
    LINES=$(wc -l < "$HOME/.claude/skills/harness-research-engineering/SKILL.md" | tr -d ' ')
    echo "     ($LINES lines)"
  else
    echo -e "  ${RED}❌${NC} SKILL.md not found at expected path"
    ERRORS=$((ERRORS + 1))
  fi

  # Check validation script
  if [ -x "$VALIDATION_DIR/validate-artifacts.sh" ]; then
    echo -e "  ${GREEN}✅${NC} validate-artifacts.sh is executable"
  else
    echo -e "  ${RED}❌${NC} validate-artifacts.sh not found or not executable"
    ERRORS=$((ERRORS + 1))
  fi

  # Check internet connectivity (for clone)
  if curl -s --max-time 5 "https://api.github.com" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✅${NC} Internet connectivity (GitHub API reachable)"
  else
    echo -e "  ${RED}❌${NC} Cannot reach GitHub API"
    ERRORS=$((ERRORS + 1))
  fi

  # Check disk space (need ~2GB for optimism monorepo clone)
  AVAIL_KB=$(df -k "$HOME" | tail -1 | awk '{print $4}')
  AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
  if [ "$AVAIL_GB" -ge 2 ]; then
    echo -e "  ${GREEN}✅${NC} Disk space: ${AVAIL_GB}GB available (need ~2GB)"
  else
    echo -e "  ${YELLOW}⚠️${NC}  Low disk space: ${AVAIL_GB}GB (recommend ≥2GB for repo clone)"
  fi

  echo ""
  if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ Pre-flight checks passed. Ready for E2E validation.${NC}"
    echo ""
    echo -e "${BOLD}Test configuration:${NC}"
    echo "  Chain:    Optimism (OP Stack)"
    echo "  Upgrade:  Isthmus"
    echo "  Specs:    https://github.com/ethereum-optimism/specs/tree/main/specs/protocol/isthmus"
    echo "  Repo:     https://github.com/ethereum-optimism/optimism"
    echo ""
    echo -e "${BOLD}To run the pipeline, invoke:${NC}"
    echo "  /harness-research-engineering analyze Optimism Isthmus \\"
    echo "    https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/isthmus/overview.md \\"
    echo "    https://github.com/ethereum-optimism/optimism"
    echo ""
    echo -e "${BOLD}After pipeline completes, validate with:${NC}"
    echo "  ./run-e2e-validation.sh validate <session_dir>"
    echo "  ./run-e2e-validation.sh report <session_dir>"
  else
    echo -e "${RED}❌ $ERRORS pre-flight check(s) failed. Fix before proceeding.${NC}"
  fi

  return $ERRORS
}

# ═══════════════════════════════════════════
# TIMING
# ═══════════════════════════════════════════
timing_start() {
  python3 -c "
import json, time
data = {
    'start_time': time.time(),
    'start_iso': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'phases': {}
}
json.dump(data, open('$TIMING_FILE', 'w'), indent=2)
print('Timing started at', data['start_iso'])
"
}

timing_phase() {
  local phase="$1"
  local status="$2"
  python3 -c "
import json, time
data = json.load(open('$TIMING_FILE'))
now = time.time()
phase_data = {
    'end_time': now,
    'end_iso': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'duration_seconds': round(now - (data['phases'].get('phase_${phase}_start', {}).get('start_time', data['start_time'])), 1),
    'status': '$status'
}
data['phases']['phase_$phase'] = phase_data
json.dump(data, open('$TIMING_FILE', 'w'), indent=2)
print(f'Phase $phase: {phase_data[\"duration_seconds\"]}s ($status)')
"
}

timing_end() {
  python3 -c "
import json, time
data = json.load(open('$TIMING_FILE'))
now = time.time()
data['end_time'] = now
data['end_iso'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
data['total_duration_seconds'] = round(now - data['start_time'], 1)
data['total_duration_minutes'] = round((now - data['start_time']) / 60, 1)
json.dump(data, open('$TIMING_FILE', 'w'), indent=2)
print(f'Total duration: {data[\"total_duration_minutes\"]} minutes')
"
}

# ═══════════════════════════════════════════
# VALIDATE
# ═══════════════════════════════════════════
validate() {
  local session_dir="$1"
  "$VALIDATION_DIR/validate-artifacts.sh" "$session_dir"
}

# ═══════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════
generate_report() {
  local session_dir="$1"
  local report_file="$VALIDATION_DIR/validation-report.md"

  # Collect timing data if available
  local timing_info=""
  if [ -f "$TIMING_FILE" ]; then
    timing_info=$(python3 -c "
import json
data = json.load(open('$TIMING_FILE'))
print(f'Total: {data.get(\"total_duration_minutes\", \"?\"):.1f} minutes')
for phase, info in sorted(data.get('phases', {}).items()):
    print(f'  {phase}: {info.get(\"duration_seconds\", \"?\")}s ({info.get(\"status\", \"?\")})')
" 2>/dev/null || echo "Timing data unavailable")
  fi

  # Run validation and capture output
  local validation_output
  validation_output=$("$VALIDATION_DIR/validate-artifacts.sh" "$session_dir" 2>&1 || true)

  # Count pass/fail from validation output
  local pass_count fail_count warn_count
  pass_count=$(echo "$validation_output" | grep -c "✅ PASS" || echo "0")
  fail_count=$(echo "$validation_output" | grep -c "❌ FAIL" || echo "0")
  warn_count=$(echo "$validation_output" | grep -c "⚠️  WARN" || echo "0")

  # Collect artifact stats
  local claims_count files_count confirmed_rate unreported_count report_lines
  claims_count=$(python3 -c "import json; print(len(json.load(open('$session_dir/claims.json'))['claims']))" 2>/dev/null || echo "?")
  files_count=$(python3 -c "import json; print(len(json.load(open('$session_dir/diff-map.json'))['files']))" 2>/dev/null || echo "?")
  confirmed_rate=$(python3 -c "
import json
data = json.load(open('$session_dir/analysis.json'))
claims = data.get('claims_analyzed', data.get('evidence_map', []))
if isinstance(claims, list):
    total = len(claims)
    confirmed = sum(1 for c in claims if c.get('verification_status') in ('verified','partially_verified'))
    print(f'{confirmed/total*100:.1f}' if total > 0 else '0')
else:
    print('?')
" 2>/dev/null || echo "?")
  unreported_count=$(python3 -c "import json; print(len(json.load(open('$session_dir/analysis.json')).get('unreported_changes',[])))" 2>/dev/null || echo "?")
  report_lines=$(wc -l < "$session_dir/internal-report.md" 2>/dev/null | tr -d ' ' || echo "?")

  cat > "$report_file" << REPORT_EOF
# E2E Validation Report — WHI-238

**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Session:** $(basename "$session_dir")
**Session path:** $session_dir

## Test Configuration

| Field | Value |
|-------|-------|
| Chain | Optimism (OP Stack) |
| Upgrade | Isthmus |
| Source URL | https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/isthmus/overview.md |
| Repo | https://github.com/ethereum-optimism/optimism |
| Pipeline | M1 (Phase 1 → 2 → 3 → 5) |

## Timing

\`\`\`
$timing_info
\`\`\`

## Validation Summary

| Metric | Value |
|--------|-------|
| Checks passed | $pass_count |
| Checks failed | $fail_count |
| Warnings | $warn_count |

## Artifact Metrics

| Artifact | Metric | Value | AC Target |
|----------|--------|-------|-----------|
| claims.json | Total claims | $claims_count | > 0 |
| diff-map.json | Files changed | $files_count | > 0 |
| analysis.json | Confirmed rate | ${confirmed_rate}% | > 50% |
| analysis.json | Unreported changes | $unreported_count | ≥ 1 |
| internal-report.md | Lines | $report_lines | All sections non-empty |

## Acceptance Criteria Checklist

- [ ] 使用真实的升级公告 URL 作为输入
- [ ] 完整运行 Phase 1 → 2 → 3 → 5（M1 管线）
- [ ] Phase 1：成功提取 claims，源快照保存正确
- [ ] Phase 2：treeless clone 仓库，fuzzy tag 正确匹配相关 refs
- [ ] Phase 3：evidence-map 有 > 50% confirmed claims ($confirmed_rate%)
- [ ] Phase 3：code-first delta 发现至少 1 个未声明变更 ($unreported_count found)
- [ ] Phase 5：internal report 结构完整，所有 section 非空
- [ ] 记录端到端运行时间、各阶段耗时
- [ ] 产出验证报告

## Issues Found

<!-- Record issues encountered during the run -->

\`\`\`markdown
## Issue: [标题]
- Phase: [哪个阶段]
- Severity: [blocking / degraded / cosmetic]
- Description: [具体问题]
- Resolution: [如何修复或规避]
\`\`\`

## Quality Assessment

### 报告对研究员是否有价值？

<!-- Evaluate after reviewing internal-report.md -->

### 哪些 claims 类型分析得最好？

<!-- Evaluate category-by-category -->

### 哪些 claims 类型分析得最差？

<!-- Evaluate problematic categories -->

## Full Validation Output

\`\`\`
$validation_output
\`\`\`
REPORT_EOF

  echo -e "${GREEN}✅ Validation report generated: $report_file${NC}"
  echo "   Review and fill in the assessment sections manually."
}

# ═══════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════
case "${1:-help}" in
  preflight)
    preflight
    ;;
  timing-start)
    timing_start
    ;;
  timing-phase)
    timing_phase "${2:-?}" "${3:-done}"
    ;;
  timing-end)
    timing_end
    ;;
  validate)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 validate <session_dir>"
      exit 2
    fi
    validate "$2"
    ;;
  report)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 report <session_dir>"
      exit 2
    fi
    generate_report "$2"
    ;;
  help|*)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  preflight              — Run pre-flight checks"
    echo "  timing-start           — Start timing"
    echo "  timing-phase <N> <ok>  — Record phase N completion"
    echo "  timing-end             — End timing"
    echo "  validate <session_dir> — Validate pipeline artifacts"
    echo "  report <session_dir>   — Generate validation report"
    echo ""
    echo "Workflow:"
    echo "  1. ./run-e2e-validation.sh preflight"
    echo "  2. ./run-e2e-validation.sh timing-start"
    echo "  3. Run the pipeline manually via /harness-research-engineering"
    echo "  4. ./run-e2e-validation.sh timing-end"
    echo "  5. ./run-e2e-validation.sh validate <session_dir>"
    echo "  6. ./run-e2e-validation.sh report <session_dir>"
    ;;
esac
