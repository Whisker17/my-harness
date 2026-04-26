#!/usr/bin/env bash
# validate-artifacts.sh — Validate pipeline output artifacts against schemas
# Part of WHI-238: Base Azul E2E validation
#
# Usage: ./validate-artifacts.sh <session_dir>
#
# Validates:
#   - claims.json (Phase 1 output)
#   - source-snapshot.md (Phase 1 output)
#   - diff-map.json (Phase 2 output)
#   - analysis.json (Phase 3 output / evidence-map)
#   - internal-report.md (Phase 5 output)
#
# Exit codes:
#   0 = all validations passed
#   1 = one or more validations failed
#   2 = usage error (missing session dir, etc.)

set -euo pipefail

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── Counters ───
PASS=0
FAIL=0
WARN=0
TOTAL=0

# ─── Functions ───
pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${GREEN}✅ PASS${NC}: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${RED}❌ FAIL${NC}: $1"
}

warn() {
  WARN=$((WARN + 1))
  echo -e "  ${YELLOW}⚠️  WARN${NC}: $1"
}

section() {
  echo ""
  echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

check_file_exists() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    pass "$label exists"
    return 0
  else
    fail "$label missing: $file"
    return 1
  fi
}

check_json_valid() {
  local file="$1"
  local label="$2"
  if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
    pass "$label is valid JSON"
    return 0
  else
    fail "$label is NOT valid JSON"
    return 1
  fi
}

check_json_field() {
  local file="$1"
  local field="$2"
  local label="$3"
  local value
  value=$(python3 -c "
import json, sys
data = json.load(open('$file'))
keys = '$field'.split('.')
obj = data
for k in keys:
    if isinstance(obj, dict) and k in obj:
        obj = obj[k]
    else:
        print('__MISSING__')
        sys.exit(0)
if obj is None:
    print('__NULL__')
else:
    print(obj if isinstance(obj, (str, int, float, bool)) else json.dumps(obj))
" 2>/dev/null)

  if [ "$value" = "__MISSING__" ]; then
    fail "$label: field '$field' is missing"
    return 1
  elif [ "$value" = "__NULL__" ]; then
    fail "$label: field '$field' is null"
    return 1
  else
    pass "$label: field '$field' present"
    return 0
  fi
}

check_json_array_nonempty() {
  local file="$1"
  local field="$2"
  local label="$3"
  local count
  count=$(python3 -c "
import json
data = json.load(open('$file'))
keys = '$field'.split('.')
obj = data
for k in keys:
    obj = obj[k]
print(len(obj) if isinstance(obj, list) else -1)
" 2>/dev/null)

  if [ "$count" = "-1" ]; then
    fail "$label: '$field' is not an array"
    return 1
  elif [ "$count" = "0" ]; then
    fail "$label: '$field' is empty array"
    return 1
  else
    pass "$label: '$field' has $count items"
    return 0
  fi
}

check_json_enum() {
  local file="$1"
  local field="$2"
  local allowed="$3"  # comma-separated
  local label="$4"
  local result
  result=$(python3 -c "
import json
data = json.load(open('$file'))
keys = '$field'.split('.')
obj = data
for k in keys:
    obj = obj[k]
allowed = set('$allowed'.split(','))
if str(obj) in allowed:
    print('OK')
else:
    print(f'INVALID: {obj} not in {allowed}')
" 2>/dev/null)

  if [[ "$result" == "OK" ]]; then
    pass "$label: '$field' = valid enum"
    return 0
  else
    fail "$label: '$field' $result"
    return 1
  fi
}

# ─── Main ───
if [ $# -lt 1 ]; then
  echo "Usage: $0 <session_dir>"
  echo "  session_dir: path to the pipeline session directory"
  echo "  e.g., ~/.gstack/research/sessions/optimism-isthmus-20260426-120000"
  exit 2
fi

SESSION_DIR="$1"

if [ ! -d "$SESSION_DIR" ]; then
  echo -e "${RED}ERROR: Session directory does not exist: $SESSION_DIR${NC}"
  exit 2
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Pipeline Artifact Validation — E2E Test (WHI-238)      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Session directory: $SESSION_DIR"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ═══════════════════════════════════════════
# 1. SOURCE SNAPSHOT (Phase 1)
# ═══════════════════════════════════════════
section "Phase 1: source-snapshot.md"

SNAPSHOT="$SESSION_DIR/source-snapshot.md"
if check_file_exists "$SNAPSHOT" "source-snapshot.md"; then
  # Check YAML frontmatter
  if head -1 "$SNAPSHOT" | grep -q "^---"; then
    pass "source-snapshot.md has YAML frontmatter"

    # Check frontmatter fields
    if grep -q "^url:" "$SNAPSHOT"; then
      pass "frontmatter has 'url' field"
    else
      fail "frontmatter missing 'url' field"
    fi

    if grep -q "^fetched_at:" "$SNAPSHOT"; then
      pass "frontmatter has 'fetched_at' field"
    else
      fail "frontmatter missing 'fetched_at' field"
    fi

    if grep -q "^fetch_method:" "$SNAPSHOT"; then
      pass "frontmatter has 'fetch_method' field"
      METHOD=$(grep "^fetch_method:" "$SNAPSHOT" | head -1 | awk '{print $2}')
      if echo "$METHOD" | grep -qE "^(webfetch|websearch|user_paste)$"; then
        pass "fetch_method is valid: $METHOD"
      else
        fail "fetch_method invalid: $METHOD (expected webfetch|websearch|user_paste)"
      fi
    else
      fail "frontmatter missing 'fetch_method' field"
    fi
  else
    fail "source-snapshot.md missing YAML frontmatter (no --- delimiter)"
  fi

  # Check content length
  CONTENT_LEN=$(wc -c < "$SNAPSHOT" | tr -d ' ')
  if [ "$CONTENT_LEN" -gt 200 ]; then
    pass "source-snapshot.md has meaningful content ($CONTENT_LEN chars)"
  else
    fail "source-snapshot.md too short ($CONTENT_LEN chars, need >200)"
  fi
fi

# ═══════════════════════════════════════════
# 2. CLAIMS.JSON (Phase 1)
# ═══════════════════════════════════════════
section "Phase 1: claims.json"

CLAIMS="$SESSION_DIR/claims.json"
if check_file_exists "$CLAIMS" "claims.json"; then
  if check_json_valid "$CLAIMS" "claims.json"; then
    # Schema version
    check_json_field "$CLAIMS" "schema_version" "claims.json"
    check_json_enum "$CLAIMS" "schema_version" "1" "claims.json"

    # Required top-level fields
    check_json_field "$CLAIMS" "source_url" "claims.json"
    check_json_field "$CLAIMS" "source_snapshot_path" "claims.json"
    check_json_field "$CLAIMS" "fetched_at" "claims.json"

    # Claims array
    check_json_array_nonempty "$CLAIMS" "claims" "claims.json"

    # Validate individual claims
    CLAIM_COUNT=$(python3 -c "import json; print(len(json.load(open('$CLAIMS'))['claims']))" 2>/dev/null)
    echo "  📊 Total claims: $CLAIM_COUNT"

    # Check each claim has required fields
    CLAIM_ERRORS=$(python3 -c "
import json
data = json.load(open('$CLAIMS'))
errors = []
valid_categories = {'architecture','performance','security','governance','tooling','deprecation','other'}
valid_confidence = {'high','medium','low'}
for i, claim in enumerate(data['claims']):
    for field in ['id','text','source_section','category','confidence']:
        if field not in claim or claim[field] is None:
            errors.append(f'claim[{i}] missing {field}')
    if claim.get('category') and claim['category'] not in valid_categories:
        errors.append(f'claim[{i}] invalid category: {claim[\"category\"]}')
    if claim.get('confidence') and claim['confidence'] not in valid_confidence:
        errors.append(f'claim[{i}] invalid confidence: {claim[\"confidence\"]}')
for e in errors:
    print(e)
if not errors:
    print('__ALL_OK__')
" 2>/dev/null)

    if [ "$CLAIM_ERRORS" = "__ALL_OK__" ]; then
      pass "All $CLAIM_COUNT claims have valid required fields"
    else
      echo "$CLAIM_ERRORS" | while read -r err; do
        fail "claims.json: $err"
      done
    fi

    # Category distribution
    echo ""
    echo "  📊 Category distribution:"
    python3 -c "
import json
from collections import Counter
data = json.load(open('$CLAIMS'))
cats = Counter(c.get('category','unknown') for c in data['claims'])
for cat, count in sorted(cats.items(), key=lambda x: -x[1]):
    print(f'     {cat}: {count}')
" 2>/dev/null

    # Confidence distribution
    echo "  📊 Confidence distribution:"
    python3 -c "
import json
from collections import Counter
data = json.load(open('$CLAIMS'))
confs = Counter(c.get('confidence','unknown') for c in data['claims'])
for conf, count in sorted(confs.items(), key=lambda x: -x[1]):
    print(f'     {conf}: {count}')
" 2>/dev/null
  fi
fi

# ═══════════════════════════════════════════
# 3. DIFF-MAP.JSON (Phase 2)
# ═══════════════════════════════════════════
section "Phase 2: diff-map.json"

DIFFMAP="$SESSION_DIR/diff-map.json"
if check_file_exists "$DIFFMAP" "diff-map.json"; then
  if check_json_valid "$DIFFMAP" "diff-map.json"; then
    # Schema version
    check_json_field "$DIFFMAP" "schema_version" "diff-map.json"
    check_json_enum "$DIFFMAP" "schema_version" "1" "diff-map.json"

    # Required top-level fields
    check_json_field "$DIFFMAP" "repo" "diff-map.json"
    check_json_field "$DIFFMAP" "base_sha" "diff-map.json"
    check_json_field "$DIFFMAP" "head_sha" "diff-map.json"
    check_json_field "$DIFFMAP" "base_ref" "diff-map.json"
    check_json_field "$DIFFMAP" "head_ref" "diff-map.json"
    check_json_field "$DIFFMAP" "generated_at" "diff-map.json"
    check_json_field "$DIFFMAP" "clone_path" "diff-map.json"

    # Files array
    check_json_array_nonempty "$DIFFMAP" "files" "diff-map.json"

    # Summary
    check_json_field "$DIFFMAP" "summary" "diff-map.json"
    check_json_field "$DIFFMAP" "summary.total_files" "diff-map.json"
    check_json_field "$DIFFMAP" "summary.added" "diff-map.json"
    check_json_field "$DIFFMAP" "summary.modified" "diff-map.json"
    check_json_field "$DIFFMAP" "summary.deleted" "diff-map.json"
    check_json_field "$DIFFMAP" "summary.total_lines_changed" "diff-map.json"

    # Validate individual files
    FILE_COUNT=$(python3 -c "import json; print(len(json.load(open('$DIFFMAP'))['files']))" 2>/dev/null)
    echo "  📊 Total files in diff: $FILE_COUNT"

    FILE_ERRORS=$(python3 -c "
import json
data = json.load(open('$DIFFMAP'))
errors = []
valid_status = {'added','modified','deleted','renamed'}
valid_category = {'core','new_module','config','test','docs','dependency','other'}
for i, f in enumerate(data['files']):
    for field in ['path','status','category','lines_changed','num_hunks']:
        if field not in f or f[field] is None:
            errors.append(f'files[{i}] missing {field}')
    if f.get('status') and f['status'] not in valid_status:
        errors.append(f'files[{i}] invalid status: {f[\"status\"]}')
    if f.get('category') and f['category'] not in valid_category:
        errors.append(f'files[{i}] invalid category: {f[\"category\"]}')
for e in errors[:10]:  # limit output
    print(e)
if len(errors) > 10:
    print(f'... and {len(errors)-10} more errors')
if not errors:
    print('__ALL_OK__')
" 2>/dev/null)

    if [ "$FILE_ERRORS" = "__ALL_OK__" ]; then
      pass "All $FILE_COUNT files have valid required fields"
    else
      echo "$FILE_ERRORS" | while read -r err; do
        fail "diff-map.json: $err"
      done
    fi

    # Summary stats
    echo ""
    echo "  📊 Diff summary:"
    python3 -c "
import json
data = json.load(open('$DIFFMAP'))
s = data.get('summary', {})
print(f'     Total files: {s.get(\"total_files\", \"?\")}')
print(f'     Added: {s.get(\"added\", \"?\")}')
print(f'     Modified: {s.get(\"modified\", \"?\")}')
print(f'     Deleted: {s.get(\"deleted\", \"?\")}')
print(f'     Total lines changed: {s.get(\"total_lines_changed\", \"?\")}')
" 2>/dev/null

    # Verify SHA format (should be 40-char hex)
    SHA_CHECK=$(python3 -c "
import json, re
data = json.load(open('$DIFFMAP'))
base = data.get('base_sha','')
head = data.get('head_sha','')
if re.match(r'^[0-9a-f]{40}$', base):
    print(f'base_sha OK: {base[:12]}...')
else:
    print(f'base_sha INVALID: {base}')
if re.match(r'^[0-9a-f]{40}$', head):
    print(f'head_sha OK: {head[:12]}...')
else:
    print(f'head_sha INVALID: {head}')
" 2>/dev/null)
    echo "  📊 SHA verification:"
    echo "$SHA_CHECK" | while read -r line; do
      if echo "$line" | grep -q "OK"; then
        pass "diff-map.json: $line"
      else
        fail "diff-map.json: $line"
      fi
    done
  fi
fi

# ═══════════════════════════════════════════
# 4. ANALYSIS.JSON / EVIDENCE-MAP (Phase 3)
# ═══════════════════════════════════════════
section "Phase 3: analysis.json (evidence-map)"

# The schema calls it analysis.json but the issue may use evidence-map.json
ANALYSIS=""
if [ -f "$SESSION_DIR/analysis.json" ]; then
  ANALYSIS="$SESSION_DIR/analysis.json"
elif [ -f "$SESSION_DIR/evidence-map.json" ]; then
  ANALYSIS="$SESSION_DIR/evidence-map.json"
  warn "Using evidence-map.json (expected analysis.json per schema)"
fi

if [ -n "$ANALYSIS" ]; then
  check_file_exists "$ANALYSIS" "analysis artifact"
  if check_json_valid "$ANALYSIS" "analysis artifact"; then
    # Schema version
    check_json_field "$ANALYSIS" "schema_version" "analysis"

    # Required fields
    check_json_field "$ANALYSIS" "generated_at" "analysis"
    check_json_array_nonempty "$ANALYSIS" "claims_analyzed" "analysis"

    # Unreported changes (must be present, can be empty)
    check_json_field "$ANALYSIS" "unreported_changes" "analysis"

    # Summary
    check_json_field "$ANALYSIS" "summary" "analysis"
    check_json_field "$ANALYSIS" "summary.total_claims" "analysis"
    check_json_field "$ANALYSIS" "summary.verified" "analysis"
    check_json_field "$ANALYSIS" "summary.partially_verified" "analysis"
    check_json_field "$ANALYSIS" "summary.unverified" "analysis"

    # Validate claims
    ANALYSIS_RESULT=$(python3 -c "
import json
data = json.load(open('$ANALYSIS'))
claims = data.get('claims_analyzed', [])
unreported = data.get('unreported_changes', [])
summary = data.get('summary', {})

total = len(claims)
verified = sum(1 for c in claims if c.get('verification_status') == 'verified')
partial = sum(1 for c in claims if c.get('verification_status') == 'partially_verified')
unverified = sum(1 for c in claims if c.get('verification_status') == 'unverified')

confirmed_rate = (verified + partial) / total * 100 if total > 0 else 0

print(f'TOTAL:{total}')
print(f'VERIFIED:{verified}')
print(f'PARTIAL:{partial}')
print(f'UNVERIFIED:{unverified}')
print(f'CONFIRMED_RATE:{confirmed_rate:.1f}')
print(f'UNREPORTED:{len(unreported)}')

# Check summary consistency
s_total = summary.get('total_claims', -1)
s_verified = summary.get('verified', -1)
s_partial = summary.get('partially_verified', -1)
s_unverified = summary.get('unverified', -1)

if s_total == total:
    print('SUMMARY_TOTAL_MATCH:yes')
else:
    print(f'SUMMARY_TOTAL_MATCH:no ({s_total} vs {total})')

if s_verified + s_partial + s_unverified == s_total:
    print('SUMMARY_SUM_MATCH:yes')
else:
    print(f'SUMMARY_SUM_MATCH:no ({s_verified}+{s_partial}+{s_unverified} != {s_total})')

# Check claim evidence quality
claims_with_evidence = sum(1 for c in claims if c.get('evidence') and len(c['evidence']) > 0)
print(f'CLAIMS_WITH_EVIDENCE:{claims_with_evidence}')

# Check for code-first delta
if len(unreported) > 0:
    high_sig = sum(1 for u in unreported if u.get('significance') == 'high')
    print(f'UNREPORTED_HIGH:{high_sig}')
else:
    print('UNREPORTED_HIGH:0')
" 2>/dev/null)

    # Parse and display
    TOTAL_CLAIMS=$(echo "$ANALYSIS_RESULT" | grep "^TOTAL:" | cut -d: -f2)
    VERIFIED=$(echo "$ANALYSIS_RESULT" | grep "^VERIFIED:" | cut -d: -f2)
    PARTIAL=$(echo "$ANALYSIS_RESULT" | grep "^PARTIAL:" | cut -d: -f2)
    UNVERIFIED_CNT=$(echo "$ANALYSIS_RESULT" | grep "^UNVERIFIED:" | cut -d: -f2)
    CONFIRMED_RATE=$(echo "$ANALYSIS_RESULT" | grep "^CONFIRMED_RATE:" | cut -d: -f2)
    UNREPORTED=$(echo "$ANALYSIS_RESULT" | grep "^UNREPORTED:" | cut -d: -f2)
    UNREPORTED_HIGH=$(echo "$ANALYSIS_RESULT" | grep "^UNREPORTED_HIGH:" | cut -d: -f2)

    echo ""
    echo "  📊 Analysis quality metrics:"
    echo "     Total claims analyzed: $TOTAL_CLAIMS"
    echo "     Verified: $VERIFIED"
    echo "     Partially verified: $PARTIAL"
    echo "     Unverified: $UNVERIFIED_CNT"
    echo "     Confirmed rate: ${CONFIRMED_RATE}%"
    echo "     Unreported changes: $UNREPORTED (high-significance: $UNREPORTED_HIGH)"

    # AC: evidence-map has > 50% confirmed claims
    if python3 -c "exit(0 if float('$CONFIRMED_RATE') > 50 else 1)" 2>/dev/null; then
      pass "Confirmed+partial rate > 50% (${CONFIRMED_RATE}%)"
    else
      fail "Confirmed+partial rate ≤ 50% (${CONFIRMED_RATE}%) — AC requires > 50%"
    fi

    # AC: code-first delta found at least 1 unreported change
    if [ "$UNREPORTED" -gt 0 ]; then
      pass "Code-first delta found $UNREPORTED unreported changes (AC: ≥1)"
    else
      fail "Code-first delta found 0 unreported changes (AC requires ≥1)"
    fi

    # Summary consistency
    SUMMARY_TOTAL=$(echo "$ANALYSIS_RESULT" | grep "^SUMMARY_TOTAL_MATCH:" | cut -d: -f2)
    SUMMARY_SUM=$(echo "$ANALYSIS_RESULT" | grep "^SUMMARY_SUM_MATCH:" | cut -d: -f2)

    if [ "$SUMMARY_TOTAL" = "yes" ]; then
      pass "Summary total_claims matches actual count"
    else
      fail "Summary total_claims mismatch: $SUMMARY_TOTAL"
    fi

    if [ "$SUMMARY_SUM" = "yes" ]; then
      pass "Summary verified+partial+unverified = total"
    else
      fail "Summary arithmetic mismatch: $SUMMARY_SUM"
    fi
  fi
else
  fail "No analysis artifact found (expected analysis.json or evidence-map.json)"
fi

# ═══════════════════════════════════════════
# 5. INTERNAL REPORT (Phase 5)
# ═══════════════════════════════════════════
section "Phase 5: internal-report.md"

REPORT="$SESSION_DIR/internal-report.md"
if check_file_exists "$REPORT" "internal-report.md"; then
  REPORT_LEN=$(wc -c < "$REPORT" | tr -d ' ')
  REPORT_LINES=$(wc -l < "$REPORT" | tr -d ' ')
  echo "  📊 Report size: $REPORT_LEN chars, $REPORT_LINES lines"

  # Check required sections
  REQUIRED_SECTIONS=("Executive Summary" "Claims Analysis" "Unclaimed Changes" "Methodology")
  for sect in "${REQUIRED_SECTIONS[@]}"; do
    if grep -qi "## $sect\|# $sect" "$REPORT"; then
      pass "Report has '$sect' section"
    else
      fail "Report missing '$sect' section"
    fi
  done

  # Check metadata header
  if grep -qi "Repo:\|repo:" "$REPORT" || grep -qi "Repository:" "$REPORT"; then
    pass "Report has repo URL in header"
  else
    warn "Report may be missing repo URL in metadata header"
  fi

  if grep -qE "[0-9a-f]{8,}" "$REPORT"; then
    pass "Report contains SHA references"
  else
    fail "Report missing SHA references (base/head commit hashes)"
  fi

  if grep -qi "Generated:\|Timestamp:\|generated_at" "$REPORT"; then
    pass "Report has generation timestamp"
  else
    warn "Report may be missing generation timestamp"
  fi

  # Check that sections are non-empty
  for sect in "${REQUIRED_SECTIONS[@]}"; do
    SECT_CONTENT=$(python3 -c "
import re
content = open('$REPORT').read()
pattern = r'#+\s*$sect\s*\n(.*?)(?=\n#+\s|\Z)'
match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
if match:
    text = match.group(1).strip()
    print(len(text))
else:
    print('0')
" 2>/dev/null)
    if [ "$SECT_CONTENT" -gt 50 ]; then
      pass "'$sect' section has content ($SECT_CONTENT chars)"
    elif [ "$SECT_CONTENT" -gt 0 ]; then
      warn "'$sect' section is sparse ($SECT_CONTENT chars)"
    else
      fail "'$sect' section is empty or unparseable"
    fi
  done

  # Check for claim verification status markers
  CONFIRMED_MARKS=$(grep -c "✅\|Confirmed\|confirmed\|verified" "$REPORT" 2>/dev/null || echo "0")
  UNCONFIRMED_MARKS=$(grep -c "❌\|Unconfirmed\|unconfirmed\|unverified" "$REPORT" 2>/dev/null || echo "0")
  echo "  📊 Verification markers in report: $CONFIRMED_MARKS confirmed, $UNCONFIRMED_MARKS unconfirmed"

  if [ "$CONFIRMED_MARKS" -gt 0 ]; then
    pass "Report contains verification status markers"
  else
    warn "Report may be missing claim verification status markers"
  fi
fi

# ═══════════════════════════════════════════
# 6. OPTIONAL: Verification Report (M2)
# ═══════════════════════════════════════════
section "Phase 6: verification-report.json (M2 — optional)"

VERIFICATION="$SESSION_DIR/verification-report.json"
if [ -f "$VERIFICATION" ]; then
  echo "  ℹ️  Verification report found — validating M2 artifact"
  if check_json_valid "$VERIFICATION" "verification-report.json"; then
    check_json_field "$VERIFICATION" "schema_version" "verification"
    check_json_field "$VERIFICATION" "verification_status" "verification"
    check_json_array_nonempty "$VERIFICATION" "reviews" "verification"
    check_json_field "$VERIFICATION" "summary" "verification"
  fi
else
  echo "  ℹ️  Not found (expected — M2 scope)"
fi

# ═══════════════════════════════════════════
# 7. OPTIONAL: Knowledge Index Entry (Phase 7)
# ═══════════════════════════════════════════
section "Phase 7: research-index.jsonl (M2 — optional)"

INDEX="$HOME/.gstack/research/research-index.jsonl"
if [ -f "$INDEX" ]; then
  ENTRY_COUNT=$(wc -l < "$INDEX" | tr -d ' ')
  echo "  ℹ️  Knowledge index found with $ENTRY_COUNT entries"

  # Check if there's an entry matching this session
  SESSION_NAME=$(basename "$SESSION_DIR")
  MATCHING=$(grep -c "$SESSION_NAME\|$(basename "$SESSION_DIR" | cut -d- -f1-2)" "$INDEX" 2>/dev/null || echo "0")
  if [ "$MATCHING" -gt 0 ]; then
    pass "Knowledge index has entry for this session"
  else
    echo "  ℹ️  No matching entry found (expected if Phase 7 not run)"
  fi
else
  echo "  ℹ️  Not found (expected — M2 scope)"
fi

# ═══════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Validation Summary                                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Passed${NC}: $PASS / $TOTAL"
echo -e "  ${RED}Failed${NC}: $FAIL / $TOTAL"
echo -e "  ${YELLOW}Warnings${NC}: $WARN"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}🎉 All validations passed!${NC}"
  exit 0
else
  echo -e "${RED}⚠️  $FAIL validation(s) failed.${NC}"
  exit 1
fi
