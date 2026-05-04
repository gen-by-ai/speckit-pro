#!/usr/bin/env bash
# =============================================================================
# SpecKit Pro — Checkpoint Script
# pro-checkpoint.sh
#
# Creates a named checkpoint: stages all changes, commits, and logs state.
#
# Usage:
#   pro-checkpoint.sh [--spec-dir <path>] [--label <label>] [--feature <name>]
# =============================================================================

set -euo pipefail

SPEC_DIR=""
LABEL=""
FEATURE_NAME=""
TRIGGERED_BY="manual"

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-dir)    SPEC_DIR="$2";    shift 2 ;;
    --label)       LABEL="$2";       shift 2 ;;
    --feature)     FEATURE_NAME="$2"; shift 2 ;;
    --triggered-by) TRIGGERED_BY="$2"; shift 2 ;;
    *)             echo "Unknown argument: $1"; exit 1 ;;
  esac
done

log_info()    { echo -e "[Pro] $*"; }
log_success() { echo -e "${GREEN}[Pro] ✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[Pro] ⚠${RESET} $*"; }

# ─── Count tasks ─────────────────────────────────────────────────────────────
count_tasks() {
  local tasks_file="$1"
  [[ ! -f "$tasks_file" ]] && echo "0 0" && return
  local completed total
  completed=$(grep -cE '^\s*- \[[xX]\]' "$tasks_file" 2>/dev/null || echo 0)
  total=$(grep -cE '^\s*- \[[ xX]\]' "$tasks_file" 2>/dev/null || echo 0)
  echo "$completed $total"
}

# ─── Get current phase from session ──────────────────────────────────────────
current_phase() {
  local session_file="$1"
  [[ ! -f "$session_file" ]] && echo "unknown" && return
  grep -oE '\*\*Phase\*\*: [^|]+' "$session_file" | tail -1 | \
    sed 's/\*\*Phase\*\*: //' | xargs || echo "unknown"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Auto-detect spec dir if not provided
  if [[ -z "$SPEC_DIR" ]]; then
    SPEC_DIR=$(find specs/ .specify/specs/ -maxdepth 2 -name "tasks.md" 2>/dev/null \
      | xargs -I{} dirname {} | head -1 || echo "")
  fi

  local tasks_file="$SPEC_DIR/tasks.md"
  local session_file="$SPEC_DIR/session.md"
  local progress_file="$SPEC_DIR/progress.md"

  local completed=0 total=0 phase="unknown"

  if [[ -n "$SPEC_DIR" && -d "$SPEC_DIR" ]]; then
    read -r completed total <<< "$(count_tasks "$tasks_file")"
    phase=$(current_phase "$session_file")
  fi

  # Generate label if not provided
  if [[ -z "$LABEL" ]]; then
    LABEL="${phase}-$(date +%Y%m%d%H%M)"
  fi

  # Calculate percentage
  local percentage=0
  [[ "$total" -gt 0 ]] && percentage=$(( (completed * 100) / total ))

  # Git operations
  local commit_hash="N/A"
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    git add . 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      local commit_msg="[Pro] Checkpoint: $LABEL ($completed/$total tasks)"
      [[ -n "$FEATURE_NAME" ]] && commit_msg="$commit_msg [feature: $FEATURE_NAME]"
      git commit -m "$commit_msg" 2>/dev/null
      commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
      log_success "Committed checkpoint: $LABEL ($commit_hash)"
    else
      log_warn "No uncommitted changes — skipping commit"
      commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "current")
    fi
  else
    log_warn "Git not available — skipping commit"
  fi

  # Log to session.md
  if [[ -n "$SPEC_DIR" && -d "$SPEC_DIR" ]]; then
    # Ensure session file exists
    if [[ ! -f "$session_file" ]]; then
      cat > "$session_file" << EOF
# Session State
Feature: $FEATURE_NAME
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)

---
EOF
    fi

    cat >> "$session_file" << EOF

## Checkpoint — $(date -u +%Y-%m-%dT%H:%M:%SZ)

- **Label**: $LABEL
- **Commit**: $commit_hash
- **Phase**: $phase
- **Tasks**: $completed/$total ($percentage%)
- **Triggered by**: $TRIGGERED_BY
EOF

    # Log to progress.md
    if [[ -f "$progress_file" ]]; then
      cat >> "$progress_file" << EOF

### Checkpoint ✓ — $LABEL
Commit: \`$commit_hash\` | $(date -u +%Y-%m-%dT%H:%M:%SZ)
Tasks: $completed/$total ($percentage%) | Phase: $phase
EOF
    fi
  fi

  # Summary output
  echo ""
  echo -e "${GREEN}[Pro] Checkpoint created ✓${RESET}"
  echo "  Label:    $LABEL"
  echo "  Commit:   $commit_hash"
  echo "  Tasks:    $completed/$total ($percentage%)"
  echo "  Phase:    $phase"
  echo ""
  echo "  To resume: /speckit.pro.resume"
  echo "  To view:   /speckit.pro.status"
}

main "$@"
