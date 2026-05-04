#!/usr/bin/env bash
# =============================================================================
# SpecKit Pro — Status Reporter
# pro-status.sh
#
# Outputs a rich status dashboard for the active SpecKit Pro run.
#
# Usage:
#   pro-status.sh [--feature <name>] [--json] [--verbose]
# =============================================================================

set -euo pipefail

FEATURE_NAME=""
SPEC_DIR=""
JSON_OUTPUT=false
VERBOSE=false

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature)  FEATURE_NAME="$2"; shift 2 ;;
    --json)     JSON_OUTPUT=true; shift ;;
    --verbose)  VERBOSE=true; shift ;;
    *)          echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Detection ───────────────────────────────────────────────────────────────
detect_feature_dir() {
  # Try specified feature first
  if [[ -n "$FEATURE_NAME" ]]; then
    for dir in specs/"$FEATURE_NAME" .specify/specs/"$FEATURE_NAME"; do
      if [[ -d "$dir" ]]; then
        echo "$dir"
        return 0
      fi
    done
    echo ""
    return 0
  fi

  # Auto-detect: find most recently modified spec directory
  local latest
  latest=$(find specs/ .specify/specs/ -maxdepth 2 -name "tasks.md" 2>/dev/null \
    | xargs -I{} dirname {} \
    | xargs ls -td 2>/dev/null \
    | head -1 || echo "")
  echo "$latest"
}

count_tasks() {
  local tasks_file="$1"
  local completed total
  completed=$(grep -cE '^\s*- \[[xX]\]' "$tasks_file" 2>/dev/null || echo 0)
  total=$(grep -cE '^\s*- \[[ xX]\]' "$tasks_file" 2>/dev/null || echo 0)
  echo "$completed $total"
}

progress_bar() {
  local completed="$1" total="$2" width=20
  local filled empty percentage

  if [[ "$total" -eq 0 ]]; then
    percentage=0; filled=0
  else
    percentage=$(( (completed * 100) / total ))
    filled=$(( (completed * width) / total ))
  fi
  empty=$(( width - filled ))

  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  echo "${bar} ${completed}/${total} (${percentage}%)"
}

phase_icon() {
  local phase_file="$1"
  [[ -f "$phase_file" ]] && echo "✓" || echo "○"
}

current_phase_from_session() {
  local session_file="$1"
  [[ ! -f "$session_file" ]] && echo "unknown" && return
  grep -oE '\*\*Phase\*\*: [^|]+' "$session_file" | tail -1 | sed 's/\*\*Phase\*\*: //' | xargs
}

last_commit_info() {
  git log -1 --format="%h %s" 2>/dev/null || echo "No commits"
}

git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A"
}

uncommitted_changes() {
  git status --short 2>/dev/null | wc -l | xargs
}

extract_feature_name() {
  local spec_file="$1"
  [[ ! -f "$spec_file" ]] && echo "Unknown" && return
  grep -m1 "^# " "$spec_file" | sed 's/^# //' | head -1
}

blocked_tasks() {
  local tasks_file="$1"
  grep -c "BLOCKED:" "$tasks_file" 2>/dev/null || echo 0
}

last_n_iterations() {
  local progress_file="$1" n="$2"
  [[ ! -f "$progress_file" ]] && return
  grep -A1 "^## Iteration" "$progress_file" | grep -v "^--$" | tail -$(( n * 2 )) \
    | paste - - | sed 's/\t/: /'
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  local spec_dir
  spec_dir=$(detect_feature_dir)

  if [[ -z "$spec_dir" || ! -d "$spec_dir" ]]; then
    echo "[Pro] No active feature found."
    echo "  Start a new pipeline: /speckit.pro.run <description>"
    exit 0
  fi

  local tasks_file="$spec_dir/tasks.md"
  local session_file="$spec_dir/session.md"
  local progress_file="$spec_dir/progress.md"
  local spec_file="$spec_dir/spec.md"

  local feature_name branch last_commit uncommitted completed total phase bar_str blocked

  feature_name=$(extract_feature_name "$spec_file")
  branch=$(git_branch)
  last_commit=$(last_commit_info)
  uncommitted=$(uncommitted_changes)
  read -r completed total <<< "$(count_tasks "$tasks_file")"
  phase=$(current_phase_from_session "$session_file")
  bar_str=$(progress_bar "$completed" "$total")
  blocked=$(blocked_tasks "$tasks_file")

  # Phase status
  local s_specify s_clarify s_plan s_tasks s_analyze
  s_specify=$(phase_icon "$spec_dir/spec.md")
  s_clarify=$(phase_icon "$spec_dir/clarifications.md")
  s_plan=$(phase_icon "$spec_dir/plan.md")
  s_tasks=$(phase_icon "$spec_dir/tasks.md")
  s_analyze=$(phase_icon "$spec_dir/analysis.md")

  # JSON output
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    cat << EOF
{
  "feature": "$feature_name",
  "branch": "$branch",
  "spec_dir": "$spec_dir",
  "pipeline": {
    "specify": "$s_specify",
    "clarify": "$s_clarify",
    "plan": "$s_plan",
    "tasks": "$s_tasks",
    "analyze": "$s_analyze",
    "current_phase": "$phase"
  },
  "tasks": {
    "completed": $completed,
    "total": $total,
    "blocked": $blocked
  },
  "git": {
    "branch": "$branch",
    "uncommitted": $uncommitted,
    "last_commit": "$last_commit"
  }
}
EOF
    exit 0
  fi

  # Rich text output
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${BLUE}║  SpecKit Pro — Status Dashboard                              ║${RESET}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  printf "${BLUE}║  %-60s ║${RESET}\n" "Feature:  $feature_name"
  printf "${BLUE}║  %-60s ║${RESET}\n" "Branch:   $branch"
  printf "${BLUE}║  %-60s ║${RESET}\n" "Phase:    $phase"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  echo -e "${BLUE}║  PIPELINE PHASE PROGRESS                                     ║${RESET}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  printf "${BLUE}║  %-60s ║${RESET}\n" "$s_specify specify  $s_clarify clarify  $s_plan plan"
  printf "${BLUE}║  %-60s ║${RESET}\n" "$s_tasks tasks    $s_analyze analyze  ⟳ implement"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  echo -e "${BLUE}║  IMPLEMENTATION PROGRESS                                     ║${RESET}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  printf "${BLUE}║  Tasks: %-53s ║${RESET}\n" "$bar_str"
  printf "${BLUE}║  %-60s ║${RESET}\n" "Blocked: $blocked task(s)"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  echo -e "${BLUE}║  HEALTH SIGNALS                                              ║${RESET}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"

  if [[ "$blocked" -eq 0 ]]; then
    printf "${GREEN}║  ✓ %-59s ║${RESET}\n" "No blocked tasks"
  else
    printf "${YELLOW}║  ⚠ %-59s ║${RESET}\n" "$blocked blocked task(s) detected"
  fi

  if [[ "$uncommitted" -eq 0 ]]; then
    printf "${GREEN}║  ✓ %-59s ║${RESET}\n" "No uncommitted changes"
  else
    printf "${YELLOW}║  ⚠ %-59s ║${RESET}\n" "$uncommitted uncommitted file(s)"
  fi

  printf "${BLUE}║  %-60s ║${RESET}\n" "Last commit: $last_commit"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  echo -e "${BLUE}║  NEXT ACTIONS                                                ║${RESET}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
  printf "${CYAN}║  %-60s ║${RESET}\n" "• /speckit.pro.resume    — continue the autonomous loop"
  printf "${CYAN}║  %-60s ║${RESET}\n" "• /speckit.pro.checkpoint — save a manual checkpoint"
  printf "${CYAN}║  %-60s ║${RESET}\n" "• /speckit.pro.compress  — reduce context token usage"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""

  # Verbose: show recent iterations
  if [[ "$VERBOSE" == "true" && -f "$progress_file" ]]; then
    echo -e "${DIM}─── Recent Iterations ─────────────────────────────────────────${RESET}"
    grep -A3 "^## Iteration" "$progress_file" | tail -30 || true
    echo ""
  fi
}

main "$@"
