#!/usr/bin/env bash
# =============================================================================
# SpecKit Pro — Autonomous Implementation Orchestrator
# pro-orchestrate.sh
#
# Drives the autonomous implementation loop: spawns fresh agent iterations,
# tracks progress, checkpoints, and applies circuit-breaker logic.
#
# Usage:
#   pro-orchestrate.sh \
#     --feature-name <name> \
#     --tasks-path <path/to/tasks.md> \
#     --spec-dir <path/to/spec/dir> \
#     [--max-iterations 20] \
#     [--checkpoint-frequency 3] \
#     [--model claude-sonnet-4.6] \
#     [--agent-cli copilot] \
#     [--resume]
# =============================================================================

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
MAX_ITERATIONS=20
CHECKPOINT_FREQUENCY=3
MODEL="claude-sonnet-4.6"
AGENT_CLI="copilot"
RESUME=false
FEATURE_NAME=""
TASKS_PATH=""
SPEC_DIR=""

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-name)     FEATURE_NAME="$2";     shift 2 ;;
    --tasks-path)       TASKS_PATH="$2";       shift 2 ;;
    --spec-dir)         SPEC_DIR="$2";         shift 2 ;;
    --max-iterations)   MAX_ITERATIONS="$2";   shift 2 ;;
    --checkpoint-frequency) CHECKPOINT_FREQUENCY="$2"; shift 2 ;;
    --model)            MODEL="$2";            shift 2 ;;
    --agent-cli)        AGENT_CLI="$2";        shift 2 ;;
    --resume)           RESUME=true;           shift ;;
    *)                  echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Validation ──────────────────────────────────────────────────────────────
if [[ -z "$FEATURE_NAME" || -z "$TASKS_PATH" || -z "$SPEC_DIR" ]]; then
  echo -e "${RED}Error: --feature-name, --tasks-path, and --spec-dir are required.${RESET}"
  exit 1
fi

if [[ ! -f "$TASKS_PATH" ]]; then
  echo -e "${RED}Error: tasks.md not found at: $TASKS_PATH${RESET}"
  exit 1
fi

# ─── Paths ───────────────────────────────────────────────────────────────────
PROGRESS_FILE="$SPEC_DIR/progress.md"
SESSION_FILE="$SPEC_DIR/session.md"
CONTEXT_SUMMARY="$SPEC_DIR/context-summary.md"

# ─── Helper Functions ────────────────────────────────────────────────────────

log_info()    { echo -e "${CYAN}[Pro]${RESET} $*"; }
log_success() { echo -e "${GREEN}[Pro] ✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[Pro] ⚠${RESET} $*"; }
log_error()   { echo -e "${RED}[Pro] ✗${RESET} $*"; }

banner() {
  local phase="$1" iter="$2" total="$3"
  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  SpecKit Pro │ Loop Iteration ${iter}/${MAX_ITERATIONS}${RESET}"
  echo -e "${BLUE}  Feature: ${FEATURE_NAME}  │  Phase: ${phase}${RESET}"
  echo -e "${BLUE}  Progress: ${iter}/${total} tasks${RESET}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${RESET}"
  echo ""
}

count_tasks() {
  local completed total
  completed=$(grep -cE '^\s*- \[x\]|\s*- \[X\]' "$TASKS_PATH" 2>/dev/null || echo 0)
  total=$(grep -cE '^\s*- \[[ xX]\]' "$TASKS_PATH" 2>/dev/null || echo 0)
  echo "$completed $total"
}

all_tasks_done() {
  local counts incomplete
  counts=$(count_tasks)
  incomplete=$(grep -cE '^\s*- \[ \]' "$TASKS_PATH" 2>/dev/null || echo 0)
  [[ "$incomplete" -eq 0 ]]
}

checkpoint_commit() {
  local label="$1" completed="$2" total="$3"
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    git add . 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      local hash
      git commit -m "[Pro] Checkpoint: $label ($completed/$total tasks, feature: $FEATURE_NAME)" \
        2>/dev/null
      hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
      log_success "Checkpoint committed: $label ($hash)"
      echo "### Checkpoint ✓ — $label" >> "$PROGRESS_FILE"
      echo "Commit: \`$hash\` | $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PROGRESS_FILE"
      echo "State: $completed/$total tasks complete." >> "$PROGRESS_FILE"
      echo "" >> "$PROGRESS_FILE"
    else
      log_info "Checkpoint skipped — no uncommitted changes"
    fi
  else
    log_warn "Git not available — skipping checkpoint commit"
  fi
}

init_progress_file() {
  if [[ ! -f "$PROGRESS_FILE" ]]; then
    cat > "$PROGRESS_FILE" << EOF
# Implementation Progress Log

Feature: $FEATURE_NAME
Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)

---
EOF
    log_info "Created progress.md"
  fi
}

update_session() {
  local phase="$1" status="$2" notes="$3"
  if [[ ! -f "$SESSION_FILE" ]]; then
    cat > "$SESSION_FILE" << EOF
# Session State

Feature: $FEATURE_NAME
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)

---
EOF
  fi
  cat >> "$SESSION_FILE" << EOF

## Session Entry — $(date -u +%Y-%m-%dT%H:%M:%SZ)

- **Phase**: $phase
- **Status**: $status
- **Notes**: $notes
EOF
}

detect_agent_cli() {
  # Try configured agent CLI first
  if command -v "$AGENT_CLI" &>/dev/null; then
    echo "$AGENT_CLI"
    return 0
  fi

  # Auto-detect fallbacks
  for cli in copilot claude gemini codex; do
    if command -v "$cli" &>/dev/null; then
      log_warn "Agent CLI '$AGENT_CLI' not found; using '$cli'"
      echo "$cli"
      return 0
    fi
  done

  log_error "No agent CLI found. Install one of: copilot, claude, gemini, codex"
  exit 1
}

run_agent_iteration() {
  local iter="$1" resolved_cli="$2"
  local counts completed total prompt_args

  # Load task counts
  read -r completed total <<< "$(count_tasks)"

  # Build the iteration prompt
  prompt_args="feature=$FEATURE_NAME tasks=$TASKS_PATH spec-dir=$SPEC_DIR iteration=$iter max=$MAX_ITERATIONS checkpoint-freq=$CHECKPOINT_FREQUENCY"

  # Determine if we should load context summary (for later iterations)
  local context_flag=""
  if [[ -f "$CONTEXT_SUMMARY" && "$iter" -gt 5 ]]; then
    context_flag="context-summary=$CONTEXT_SUMMARY"
    prompt_args="$prompt_args $context_flag"
  fi

  local agent_output agent_exit status_tag

  # Invoke the agent — run speckit.pro.loop command
  # Different CLIs have different invocation patterns
  case "$resolved_cli" in
    copilot)
      agent_output=$(
        "$resolved_cli" agent --model "$MODEL" \
          ".github/agents/speckit.pro.loop.agent.md" \
          "$prompt_args" 2>&1
      ) || agent_exit=$?
      ;;
    claude)
      agent_output=$(
        "$resolved_cli" --model "$MODEL" \
          --print \
          --system-prompt ".github/agents/speckit.pro.loop.agent.md" \
          "$prompt_args" 2>&1
      ) || agent_exit=$?
      ;;
    gemini)
      agent_output=$(
        "$resolved_cli" run \
          --model "$MODEL" \
          ".github/agents/speckit.pro.loop.agent.md" \
          "$prompt_args" 2>&1
      ) || agent_exit=$?
      ;;
    *)
      # Generic fallback — run with the command as first arg
      agent_output=$(
        "$resolved_cli" ".github/agents/speckit.pro.loop.agent.md" "$prompt_args" 2>&1
      ) || agent_exit=$?
      ;;
  esac

  echo "$agent_output"

  # Extract status tag from agent output
  status_tag=$(echo "$agent_output" | grep -oE '<pro-status>[^<]+</pro-status>' | tail -1 | sed 's/<[^>]*>//g' || echo "UNKNOWN")

  echo "$status_tag"
}

print_progress_bar() {
  local completed="$1" total="$2"
  local bar_width=20 filled empty percentage

  if [[ "$total" -eq 0 ]]; then
    percentage=0
    filled=0
  else
    percentage=$(( (completed * 100) / total ))
    filled=$(( (completed * bar_width) / total ))
  fi
  empty=$(( bar_width - filled ))

  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  echo -e "  Progress: ${CYAN}${bar}${RESET} ${completed}/${total} (${percentage}%)"
}

# ─── Main Loop ───────────────────────────────────────────────────────────────

main() {
  local resolved_cli consecutive_failures=0 iteration=1

  # Resolve the agent CLI
  resolved_cli=$(detect_agent_cli)

  # Initialize tracking files
  init_progress_file

  # Determine starting iteration (resume mode)
  if [[ "$RESUME" == "true" && -f "$PROGRESS_FILE" ]]; then
    local last_iter
    last_iter=$(grep -oE 'Iteration [0-9]+' "$PROGRESS_FILE" | tail -1 | grep -oE '[0-9]+' || echo 0)
    if [[ "$last_iter" -gt 0 ]]; then
      iteration=$(( last_iter + 1 ))
      log_info "Resuming from iteration $iteration (previous: $last_iter)"
    fi
  fi

  # Check if already complete
  if all_tasks_done; then
    log_success "All tasks already complete — nothing to do!"
    log_info "Run /speckit.pro.status for a summary."
    exit 0
  fi

  update_session "implement" "started" "Autonomous loop starting at iteration $iteration"

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║  SpecKit Pro — Autonomous Implementation Loop        ║${RESET}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════╣${RESET}"
  echo -e "${GREEN}║  Feature:    $FEATURE_NAME${RESET}"
  echo -e "${GREEN}║  Max iter:   $MAX_ITERATIONS | Checkpoints every $CHECKPOINT_FREQUENCY${RESET}"
  echo -e "${GREEN}║  Model:      $MODEL${RESET}"
  echo -e "${GREEN}║  Agent CLI:  $resolved_cli${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""

  # ─── Loop ──────────────────────────────────────────────────────────────────
  while [[ "$iteration" -le "$MAX_ITERATIONS" ]]; do

    # Pre-iteration: check if done
    if all_tasks_done; then
      break
    fi

    local counts completed total
    read -r completed total <<< "$(count_tasks)"

    banner "implement" "$iteration" "$total"
    print_progress_bar "$completed" "$total"
    echo ""

    # Run agent iteration
    log_info "Spawning agent iteration $iteration/$MAX_ITERATIONS..."
    local agent_status
    agent_status=$(run_agent_iteration "$iteration" "$resolved_cli" | tail -1)

    log_info "Agent status: $agent_status"

    # Process status tag
    case "$agent_status" in
      COMPLETE)
        log_success "Agent confirmed all tasks complete!"
        checkpoint_commit "final-complete" "$completed" "$total"
        update_session "implement" "completed" "All tasks complete after $iteration iterations"
        break
        ;;
      CONTINUE)
        log_success "Iteration $iteration complete — continuing..."
        consecutive_failures=0
        ;;
      BLOCKED:*)
        local reason="${agent_status#BLOCKED:}"
        log_warn "Task blocked: $reason"
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: $consecutive_failures consecutive blocks/failures"
          update_session "implement" "blocked" "Circuit breaker triggered: $reason"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          exit 1
        fi
        ;;
      ERROR:*)
        local err_msg="${agent_status#ERROR:}"
        log_error "Agent error: $err_msg"
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: 3 consecutive failures"
          update_session "implement" "failed" "Circuit breaker: $err_msg"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          exit 1
        fi
        log_warn "Retrying... ($consecutive_failures/3 failures)"
        ;;
      *)
        # Unknown status — treat as continue but track
        log_warn "Unknown agent status: '$agent_status' — treating as CONTINUE"
        consecutive_failures=0
        ;;
    esac

    # Periodic checkpoint
    if (( iteration % CHECKPOINT_FREQUENCY == 0 )); then
      read -r completed total <<< "$(count_tasks)"
      checkpoint_commit "iter${iteration}" "$completed" "$total"
    fi

    iteration=$(( iteration + 1 ))
  done

  # ─── Post-loop summary ─────────────────────────────────────────────────────
  local final_completed final_total
  read -r final_completed final_total <<< "$(count_tasks)"

  if all_tasks_done; then
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}║  SpecKit Pro — Implementation Complete ✓             ║${RESET}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${RESET}"
    echo -e "${GREEN}║  Feature: $FEATURE_NAME${RESET}"
    echo -e "${GREEN}║  Tasks:   $final_completed/$final_total completed (100%)${RESET}"
    echo -e "${GREEN}║  Iterations used: $((iteration - 1))/$MAX_ITERATIONS${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"

    checkpoint_commit "implementation-complete" "$final_completed" "$final_total"
    update_session "implement" "completed" "All $final_total tasks complete in $((iteration - 1)) iterations"
    exit 0
  else
    local remaining=$(( final_total - final_completed ))
    echo ""
    log_warn "Maximum iterations ($MAX_ITERATIONS) reached. $remaining tasks remain."
    print_progress_bar "$final_completed" "$final_total"
    log_info "Resume with: /speckit.pro.resume"
    log_info "Check status: /speckit.pro.status"

    checkpoint_commit "max-iterations-reached" "$final_completed" "$final_total"
    update_session "implement" "paused" "$remaining tasks remain after max iterations"
    exit 1
  fi
}

# ─── Trap for clean exit on Ctrl+C ───────────────────────────────────────────
trap 'echo ""; log_warn "Interrupted by user. Run /speckit.pro.resume to continue."; exit 130' INT

main "$@"
