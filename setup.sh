#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  My Harness — Setup Script
#  Installs harness skills and checks external dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$SCRIPT_DIR/skills"
SKILLS_DST="$HOME/.claude/skills"
GSTACK_DIR="$HOME/.gstack"

# Counters
PASS=0
WARN=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }

check_pass() { green "  ✅  $1"; PASS=$((PASS + 1)); }
check_warn() { yellow "  ⚠️   $1"; WARN=$((WARN + 1)); }
check_fail() { red "  ❌  $1"; FAIL=$((FAIL + 1)); }

header() {
  echo ""
  echo "━━━ $1 ━━━"
}

# ── Step 1: Prerequisites ───────────────────────────────

header "Step 1: Checking prerequisites"

# Claude Code
if command -v claude &>/dev/null; then
  CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
  check_pass "Claude Code installed ($CLAUDE_VERSION)"
else
  check_fail "Claude Code not found — install from https://claude.ai/code"
fi

# GitHub CLI
if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null; then
    check_pass "GitHub CLI installed and authenticated"
  else
    check_warn "GitHub CLI installed but NOT authenticated — run: gh auth login"
  fi
else
  check_fail "GitHub CLI (gh) not found — install from https://cli.github.com/"
fi

# Linear MCP server
LINEAR_MCP_FOUND=false
for f in "$HOME/.claude/settings.json" "$HOME/.claude.json" "$HOME/.config/claude/settings.json"; do
  if [ -f "$f" ] && grep -qi "linear" "$f" 2>/dev/null; then
    LINEAR_MCP_FOUND=true
    break
  fi
done
if $LINEAR_MCP_FOUND; then
  check_pass "Linear MCP server configured"
else
  check_warn "Linear MCP server not detected — see https://github.com/linear/linear-mcp for setup"
fi

# ── Step 2: Install harness skills ──────────────────────

header "Step 2: Installing harness skills"

mkdir -p "$SKILLS_DST"

HARNESS_SKILLS=("harness-dev" "harness-review" "harness-design" "harness-bootstrap" "harness-review-v2" "harness-design-v2" "harness-triage")

for skill in "${HARNESS_SKILLS[@]}"; do
  src="$SKILLS_SRC/$skill"
  dst="$SKILLS_DST/$skill"

  if [ ! -d "$src" ]; then
    check_fail "$skill — source not found at $src"
    continue
  fi

  mkdir -p "$dst"
  cp -r "$src"/* "$dst"/
  check_pass "$skill installed → $dst"
done

# Copy shared schema (required by harness-dev quality gate)
if [ -f "$SKILLS_SRC/harness-dev/schema.md" ]; then
  cp "$SKILLS_SRC/harness-dev/schema.md" "$SKILLS_DST/harness-dev/schema.md"
  check_pass "schema.md copied to $SKILLS_DST/harness-dev/"
fi

# ── Step 3: Check external skill dependencies ───────────

header "Step 3: Checking external skill dependencies"

# adversarial-review (required by harness-dev)
AR_FOUND=false
if [ -d "$HOME/.claude/plugins/cache/adversarial-review" ]; then
  AR_FOUND=true
fi
# Also check if it shows up as a Claude Code plugin via settings
for f in "$HOME/.claude/settings.json" "$HOME/.claude.json" "$HOME/.config/claude/settings.json"; do
  if [ -f "$f" ] && grep -qi "adversarial-review" "$f" 2>/dev/null; then
    AR_FOUND=true
    break
  fi
done
if $AR_FOUND; then
  check_pass "adversarial-review plugin found"
else
  check_warn "adversarial-review plugin not found"
  echo "         Required by: /harness-dev (Step 4 — adversarial review)"
  echo "         Install:     In Claude Code, run /install-plugin adversarial-review"
  echo "         Or see:      https://github.com/anthropics/claude-code-plugins"
  echo "         Note:        harness-dev falls back to Agent-based review if unavailable"
fi

# office-hours (optional — only for harness-design)
if [ -d "$SKILLS_DST/office-hours" ] && [ -f "$SKILLS_DST/office-hours/SKILL.md" ]; then
  check_pass "office-hours skill found"
else
  check_warn "office-hours skill not found (optional)"
  echo "         Required by: /harness-design (Step 2 — office hours session)"
  echo "         Without it:  /harness-design will not work; other skills are unaffected"
fi

# plan-eng-review (optional — only for harness-design)
if [ -d "$SKILLS_DST/plan-eng-review" ] && [ -f "$SKILLS_DST/plan-eng-review/SKILL.md" ]; then
  check_pass "plan-eng-review skill found"
else
  check_warn "plan-eng-review skill not found (optional)"
  echo "         Required by: /harness-design (Step 3 — engineering review)"
  echo "         Without it:  /harness-design will not work; other skills are unaffected"
fi

# ── Step 4: gstack tooling ──────────────────────────────

header "Step 4: Checking gstack tooling"

# ~/.gstack/ directory
if [ -d "$GSTACK_DIR" ]; then
  check_pass "~/.gstack/ directory exists"
else
  mkdir -p "$GSTACK_DIR/projects"
  check_pass "~/.gstack/ directory created"
fi

# ~/.gstack/projects/
if [ -d "$GSTACK_DIR/projects" ]; then
  check_pass "~/.gstack/projects/ directory exists"
else
  mkdir -p "$GSTACK_DIR/projects"
  check_pass "~/.gstack/projects/ directory created"
fi

# ~/.gstack/config.json
if [ -f "$GSTACK_DIR/config.json" ]; then
  check_pass "~/.gstack/config.json exists"
else
  cat > "$GSTACK_DIR/config.json" <<'CONF'
{
  "review_mode": "adversarial-review"
}
CONF
  check_pass "~/.gstack/config.json created (default: review_mode=adversarial-review)"
fi

# gstack-slug binary
if [ -x "$SKILLS_DST/gstack/bin/gstack-slug" ]; then
  check_pass "gstack-slug binary found"
else
  check_warn "gstack-slug binary not found"
  echo "         Required by: /harness-design (preamble — project slug generation)"
  echo "         Without it:  /harness-design will not work; other skills are unaffected"
fi

# ── Step 5: V2 pipeline prerequisites (optional) ──────

header "Step 5: Checking v2 pipeline prerequisites (optional)"

# Codex CLI
if command -v codex &>/dev/null; then
  CODEX_VERSION=$(codex --version 2>/dev/null || echo "unknown")
  check_pass "Codex CLI found ($CODEX_VERSION)"

  # Check Codex authentication
  if codex auth status &>/dev/null 2>&1; then
    check_pass "Codex CLI authenticated"
  else
    check_warn "Codex CLI installed but may not be authenticated — run: codex login"
  fi
else
  check_warn "Codex CLI not found (optional, required for v2 pipeline)"
  echo "         Install: npm install -g @openai/codex"
  echo "         Auth:    codex login"
fi

# codex-plugin-cc
CODEX_PLUGIN_FOUND=false
if npm list -g codex-plugin-cc &>/dev/null 2>&1; then
  CODEX_PLUGIN_FOUND=true
fi
if $CODEX_PLUGIN_FOUND; then
  check_pass "codex-plugin-cc installed"
else
  check_warn "codex-plugin-cc not found (optional, required for v2 pipeline)"
  echo "         Install: npm install -g codex-plugin-cc"
fi

# gstack (also used by v1 design, but required for v2 codex invocation)
if command -v gstack &>/dev/null || [ -d "$GSTACK_DIR" ]; then
  check_pass "gstack directory found"
else
  check_warn "gstack not found (optional, required for v2 pipeline)"
fi

# ── Summary ─────────────────────────────────────────────

header "Summary"

echo ""
green "  Passed:   $PASS"
if [ $WARN -gt 0 ]; then
  yellow "  Warnings: $WARN"
fi
if [ $FAIL -gt 0 ]; then
  red "  Failed:   $FAIL"
fi
echo ""

if [ $FAIL -gt 0 ]; then
  red "  Some required checks failed. Fix the issues above and re-run this script."
  exit 1
elif [ $WARN -gt 0 ]; then
  yellow "  Setup complete with warnings. Core skills are installed."
  echo "  The warnings above are for optional dependencies — fix them if you need those features."
  echo ""
  echo "  You can now use:"
  echo "    /harness-dev WHI-123       — implement a Linear issue"
  echo "    /harness-review WHI-123    — final review + merge"
  echo "    /harness-bootstrap <proj>  — bootstrap a new project"
  echo ""
  echo "  V2 pipeline (if prerequisites installed):"
  echo "    /harness-design-v2         — Codex-powered design"
  echo "    /harness-review-v2         — Codex↔Opus convergence review"
  echo ""
  exit 0
else
  green "  All checks passed. You're ready to go!"
  echo ""
  echo "  Get started:"
  echo "    /harness-design            — design a new project"
  echo "    /harness-bootstrap <proj>  — bootstrap a project repo"
  echo "    /harness-dev WHI-123       — implement a Linear issue"
  echo "    /harness-review WHI-123    — final review + merge"
  echo ""
  echo "  V2 pipeline:"
  echo "    /harness-design-v2         — Codex-powered design"
  echo "    /harness-review-v2         — Codex↔Opus convergence review"
  echo ""
  exit 0
fi
