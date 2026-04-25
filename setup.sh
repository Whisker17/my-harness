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

HARNESS_SKILLS=("harness-dev" "harness-review" "harness-design" "harness-bootstrap" "harness-review-v2" "harness-design-v2" "harness-triage" "harness-research-engineering")

for skill in "${HARNESS_SKILLS[@]}"; do
  src="$SKILLS_SRC/$skill"
  dst="$SKILLS_DST/$skill"

  if [ ! -d "$src" ]; then
    check_fail "$skill — source not found at $src"
    continue
  fi

  mkdir -p "$dst"
  cp -r "$src"/* "$dst"/ 2>/dev/null || true
  check_pass "$skill installed → $dst"
done

# Copy shared schema (required by harness-dev quality gate)
if [ -f "$SKILLS_SRC/harness-dev/schema.md" ]; then
  cp "$SKILLS_SRC/harness-dev/schema.md" "$SKILLS_DST/harness-dev/schema.md" 2>/dev/null || true
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

# codex-plugin-cc (Claude Code plugin, NOT an npm package)
CODEX_PLUGIN_FOUND=false
CODEX_PLUGIN_VERSION=""
CODEX_PLUGIN_CACHE="$HOME/.claude/plugins/cache/openai-codex"
if [ -d "$CODEX_PLUGIN_CACHE" ]; then
  CODEX_PLUGIN_FOUND=true
  # Extract version from the cache directory structure (e.g., openai-codex/codex/1.0.2/)
  CODEX_PLUGIN_VERSION=$(ls -1 "$CODEX_PLUGIN_CACHE/codex/" 2>/dev/null | sort -V | tail -1)
fi
if $CODEX_PLUGIN_FOUND; then
  check_pass "codex-plugin-cc installed (v${CODEX_PLUGIN_VERSION:-unknown})"
else
  check_warn "codex-plugin-cc not found (optional, required for v2 pipeline)"
  echo "         This is a Claude Code plugin, NOT an npm package."
  echo "         Install: In Claude Code, run /install-plugin codex-plugin-cc"
  echo "         Or see:  https://github.com/openai/codex-plugin-cc"
fi

# gstack (also used by v1 design, but required for v2 codex invocation)
if command -v gstack &>/dev/null || [ -d "$GSTACK_DIR" ]; then
  check_pass "gstack directory found"
else
  check_warn "gstack not found (optional, required for v2 pipeline)"
fi

# ── Step 6: Patch plugin settings for v2 compatibility ─

header "Step 6: Patching plugin settings for v2 pipeline"

# codex:adversarial-review has disable-model-invocation: true by default,
# which prevents harness-review-v2 from invoking it via the Skill tool.
# Patch it to false so the v2 pipeline can call Codex programmatically.
CODEX_AR_CMD=$(find "$HOME/.claude/plugins/cache/openai-codex" -path "*/commands/adversarial-review.md" 2>/dev/null | head -1)
if [ -n "$CODEX_AR_CMD" ] && [ -f "$CODEX_AR_CMD" ]; then
  if grep -q "disable-model-invocation: true" "$CODEX_AR_CMD"; then
    sed -i '' 's/disable-model-invocation: true/disable-model-invocation: false/' "$CODEX_AR_CMD"
    check_pass "codex:adversarial-review patched (disable-model-invocation → false)"
  else
    check_pass "codex:adversarial-review already allows model invocation"
  fi
else
  check_warn "codex:adversarial-review command not found (codex plugin not installed?)"
  echo "         Install the codex plugin first, then re-run setup.sh"
fi

# ── Step 7: Check for v2 dependency updates ────────────

header "Step 7: Checking for v2 dependency updates"

# codex-plugin-cc — check installed version from plugin cache
CODEX_PLUGIN_CACHE="$HOME/.claude/plugins/cache/openai-codex"
if [ -d "$CODEX_PLUGIN_CACHE" ]; then
  INSTALLED_CC=$(ls -1 "$CODEX_PLUGIN_CACHE/codex/" 2>/dev/null | sort -V | tail -1)
  if [ -n "$INSTALLED_CC" ]; then
    check_pass "codex-plugin-cc v$INSTALLED_CC (Claude Code plugin)"
    echo "         To update: In Claude Code, the plugin auto-updates or reinstall via /install-plugin codex-plugin-cc"
  else
    check_warn "codex-plugin-cc cache found but version unknown"
  fi
else
  check_warn "codex-plugin-cc not installed"
  echo "         This is a Claude Code plugin, NOT an npm package."
  echo "         Install: In Claude Code, run /install-plugin codex-plugin-cc"
fi

# @openai/codex CLI — check installed vs latest version
if command -v npm &>/dev/null; then
  INSTALLED_CODEX=$(npm list -g @openai/codex --depth=0 2>/dev/null | grep @openai/codex | sed 's/.*@openai\/codex@//')
  if [ -n "$INSTALLED_CODEX" ]; then
    LATEST_CODEX=$(npm view @openai/codex version 2>/dev/null || echo "")
    if [ -n "$LATEST_CODEX" ] && [ "$INSTALLED_CODEX" != "$LATEST_CODEX" ]; then
      check_warn "Codex CLI outdated: $INSTALLED_CODEX → $LATEST_CODEX"
      echo "         Update: npm update -g @openai/codex"
    else
      check_pass "Codex CLI up to date ($INSTALLED_CODEX)"
    fi
  fi
else
  check_warn "npm not found — cannot check for updates"
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
  echo "    /harness-research-engineering analyze [chain] [upgrade]"
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
  echo "    /harness-research-engineering analyze [chain] [upgrade]"
  echo ""
  echo "  V2 pipeline:"
  echo "    /harness-design-v2         — Codex-powered design"
  echo "    /harness-review-v2         — Codex↔Opus convergence review"
  echo ""
  exit 0
fi
