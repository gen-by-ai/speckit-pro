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

# ─── Script-relative paths ────────────────────────────────────────────────────
# Resolve the directory this script lives in so we can find sibling helpers
# (pro-report.sh — the single telemetry writer, D6).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRO_REPORT="$SCRIPT_DIR/pro-report.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────
MAX_ITERATIONS=20
CHECKPOINT_FREQUENCY=3
MODEL="claude-sonnet-4.6"
SUBAGENT_MODEL=""          # when set, exported as CLAUDE_CODE_SUBAGENT_MODEL
AGENT_CLI="copilot"
RESUME=false
FEATURE_NAME=""
TASKS_PATH=""
SPEC_DIR=""
FEATURE_KNOWLEDGE_DIR=""  # derived after arg parsing if not provided

# Effort levels per phase (Opus 4.7+ adaptive thinking)
EFFORT_PLANNING="xhigh"
EFFORT_EXECUTION="high"
EFFORT_VERIFICATION="xhigh"
EFFORT_EXPLORATORY="medium"

# Evaluator (generator/evaluator split — Anthropic harness pattern)
ENABLE_EVALUATOR=false
EVAL_THRESHOLD=70       # minimum score (0-100) for PASS
MAX_REVISIONS=2         # max generator revision attempts per sprint before FAIL

# ─── Headless CLI controls (claude branch only; copilot/gemini ignore these) ──
# All default to today's effective behavior — the copilot path injects NONE of
# them, so default runs (agent_cli=copilot, in-harness) stay byte-for-byte the
# same (FR-007 / SC-005). Every optional flag is capability-gated (cli_has_cap).
PERMISSION_MODE="acceptEdits"                                  # D2
ALLOWED_TOOLS="Read Edit Write Bash(git *) Grep Glob"          # D2 generator/revision set
EVALUATOR_ALLOWED_TOOLS="Read Grep Glob"                       # D10 read-only evaluator set
DISALLOWED_TOOLS=""                                            # optional explicit deny-list
DANGEROUS_SKIP=false                                           # opt-in --dangerously-skip-permissions
MAX_BUDGET_USD="10.00"                                         # D4 cumulative per-RUN cap (empty=unlimited)
FALLBACK_MODEL=""                                              # optional --fallback-model
OUTPUT_FORMAT="json"                                           # D3 defensive parse engine
SESSION_PERSISTENCE=true                                       # D5 (false => --no-session-persistence)
EVALUATOR_MODEL=""                                             # D10 (empty => shared primary model)
SHARED_MODEL_WARN=true                                         # emit SHARED-MODEL disclosure when gen==eval
RUN_ID=""                                                      # telemetry correlation key (NOT a session UUID)
SELF_STAMPED=0                                                 # 1 when this script stamped its own run (terminal entry, no --run-id)

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
    --knowledge-feature-dir) FEATURE_KNOWLEDGE_DIR="$2"; shift 2 ;;
    --max-iterations)   MAX_ITERATIONS="$2";   shift 2 ;;
    --checkpoint-frequency) CHECKPOINT_FREQUENCY="$2"; shift 2 ;;
    --model)            MODEL="$2";            shift 2 ;;
    --subagent-model)   SUBAGENT_MODEL="$2";   shift 2 ;;
    --effort-planning)  EFFORT_PLANNING="$2";  shift 2 ;;
    --effort-execution) EFFORT_EXECUTION="$2"; shift 2 ;;
    --effort-verification) EFFORT_VERIFICATION="$2"; shift 2 ;;
    --effort-exploratory)  EFFORT_EXPLORATORY="$2";  shift 2 ;;
    --agent-cli)        AGENT_CLI="$2";        shift 2 ;;
    --resume)           RESUME=true;           shift ;;
    --enable-evaluator) ENABLE_EVALUATOR=true; shift ;;
    --eval-threshold)   EVAL_THRESHOLD="$2";   shift 2 ;;
    --max-revisions)    MAX_REVISIONS="$2";    shift 2 ;;
    --permission-mode)  PERMISSION_MODE="$2";  shift 2 ;;
    --allowed-tools)    ALLOWED_TOOLS="$2";    shift 2 ;;
    --evaluator-allowed-tools) EVALUATOR_ALLOWED_TOOLS="$2"; shift 2 ;;
    --disallowed-tools) DISALLOWED_TOOLS="$2"; shift 2 ;;
    --dangerously-skip-permissions) DANGEROUS_SKIP=true; shift ;;
    --max-budget-usd)   MAX_BUDGET_USD="$2";   shift 2 ;;
    --fallback-model)   FALLBACK_MODEL="$2";   shift 2 ;;
    --output-format)    OUTPUT_FORMAT="$2";    shift 2 ;;
    --session-persistence) SESSION_PERSISTENCE="$2"; shift 2 ;;
    --evaluator-model)  EVALUATOR_MODEL="$2";  shift 2 ;;
    --no-shared-model-warn) SHARED_MODEL_WARN=false; shift ;;
    --run-id)           RUN_ID="$2";           shift 2 ;;
    *)                  echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Derive FEATURE_KNOWLEDGE_DIR ──────────────────────────────────────────────
if [[ -z "$FEATURE_KNOWLEDGE_DIR" ]]; then
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  FEATURE_KNOWLEDGE_DIR="$PROJECT_ROOT/.knowledge/features/$FEATURE_NAME"
fi
mkdir -p "$FEATURE_KNOWLEDGE_DIR/contracts" "$FEATURE_KNOWLEDGE_DIR/evaluations"

# ─── Export Sub-Agent Model (when configured) ─────────────────────────────
# Allows specialist sub-agents to run on a lighter model while the orchestrator
# uses the primary model. See: claudefa.st/blog/guide/agents/sub-agent-best-practices
if [[ -n "$SUBAGENT_MODEL" ]]; then
  export CLAUDE_CODE_SUBAGENT_MODEL="$SUBAGENT_MODEL"
fi

# ─── Export Effort Levels ─────────────────────────────────────────────────
# Agents read these to calibrate reasoning depth per phase.
# See: claudefa.st/blog/guide/development/opus-4-7-best-practices
export SPECKIT_EFFORT_PLANNING="$EFFORT_PLANNING"
export SPECKIT_EFFORT_EXECUTION="$EFFORT_EXECUTION"
export SPECKIT_EFFORT_VERIFICATION="$EFFORT_VERIFICATION"
export SPECKIT_EFFORT_EXPLORATORY="$EFFORT_EXPLORATORY"

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
PROGRESS_FILE="$FEATURE_KNOWLEDGE_DIR/progress.md"  # persistent audit trail
SESSION_FILE="$SPEC_DIR/session.md"             # transient pipeline state
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
  # `grep -c` ALWAYS prints a single number (0 on no match). Do NOT append
  # `|| echo 0` — on a no-match grep -c exits 1, firing the echo and producing a
  # two-line "0\n0" value that breaks the `-eq` arithmetic downstream (caught in
  # eval: completion was never detected on a fully-done tasks.md). Anchor both the
  # x and X branches so an inline `- [X]` in prose can't inflate the count.
  #
  # Race-free counting (audit C6): read tasks.md ONCE and count both patterns
  # from the same snapshot — two separate file greps could straddle a concurrent
  # agent write and report an impossible completed/total pair.
  local content completed total
  content=$(cat "$TASKS_PATH" 2>/dev/null) || content=""
  completed=$(printf '%s\n' "$content" | grep -cE '^[[:space:]]*- \[[xX]\]') || true
  completed=${completed:-0}
  total=$(printf '%s\n' "$content" | grep -cE '^[[:space:]]*- \[[ xX]\]') || true
  total=${total:-0}
  echo "$completed $total"
}

all_tasks_done() {
  local incomplete
  incomplete=$(grep -cE '^[[:space:]]*- \[ \]' "$TASKS_PATH" 2>/dev/null); incomplete=${incomplete:-0}
  [[ "$incomplete" -eq 0 ]]
}

# Reads commit.commit_artifacts from pro-config (awk section walker — same
# no-dependency pattern as pro-resume-detect.sh; pro-report.sh's python walker
# is overkill for one boolean). Precedence mirrors report_resolve_config.
# Returns 0 (true) only on an explicit `commit_artifacts: true`; default false.
# NOTE: PROJECT_ROOT is only set when --knowledge-feature-dir was NOT passed,
# so resolve the root locally here.
commit_artifacts_enabled() {
  local root cfg v
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  for cfg in "$root/.specify/extensions/pro/pro-config.local.yml" \
             "$root/.specify/extensions/pro/pro-config.yml" \
             "$root/pro-config.yml"; do
    if [[ -f "$cfg" ]]; then
      v=$(awk '/^commit:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^[[:space:]]*commit_artifacts:/{gsub(/["'"'"']/,"",$2); print $2; exit}' "$cfg" 2>/dev/null)
      if [[ -n "$v" ]]; then
        [[ "$v" == "true" ]] && return 0
        return 1
      fi
    fi
  done
  return 1
}

checkpoint_commit() {
  local label="$1" completed="$2" total="$3"
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    # Scoped staging (audit B3 / FR-007): never a blanket `git add .` — workspace
    # state must stay out of feature-branch commits. .knowledge/features and
    # .knowledge/metrics are ALWAYS excluded (machine-generated, per the
    # commit.commit_artifacts config contract); specs/ is excluded unless the
    # operator opted in with commit_artifacts: true.
    local stage_rc=0
    if commit_artifacts_enabled; then
      git add -A -- . ':(exclude).knowledge/features' ':(exclude).knowledge/metrics' 2>/dev/null || stage_rc=$?
    else
      git add -A -- . ':(exclude)specs' ':(exclude).knowledge/features' ':(exclude).knowledge/metrics' 2>/dev/null || stage_rc=$?
    fi
    if [[ "$stage_rc" -ne 0 ]]; then
      log_error "checkpoint staging failed: $(git status -s 2>/dev/null | head -1)"
      return 1
    fi
    if ! git diff --cached --quiet 2>/dev/null; then
      # Verified commit (audit B4): check the exit code — a silent `2>/dev/null`
      # commit failure used to be followed by an unconditional log_success.
      local hash commit_rc=0
      git commit -m "[Pro] Checkpoint: $label ($completed/$total tasks, feature: $FEATURE_NAME)" \
        2>/dev/null || commit_rc=$?
      if [[ "$commit_rc" -ne 0 ]]; then
        local status_snippet
        status_snippet=$(git status -s 2>/dev/null | head -3 | tr '\n' ' ')
        log_error "Checkpoint commit failed (rc $commit_rc): $status_snippet"
        # Best-effort error event — telemetry must never abort the loop.
        [ -f "$PRO_REPORT" ] && bash "$PRO_REPORT" event skip "${RUN_ID:--}" checkpoint loop error "git commit failed: $status_snippet" >/dev/null 2>&1 || true
        return 1
      fi
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
    # Guard the parent dir (audit B9) — degrade with a warning, never abort.
    mkdir -p "$(dirname "$PROGRESS_FILE")" 2>/dev/null \
      || log_warn "Could not create $(dirname "$PROGRESS_FILE") — progress logging degraded"
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
  # Guard the parent dir (audit B9) — degrade with a warning, never abort.
  mkdir -p "$(dirname "$SESSION_FILE")" 2>/dev/null \
    || log_warn "Could not create $(dirname "$SESSION_FILE") — session logging degraded"
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

# ─── CLI capability profile (contract: cli-invocation.md) ─────────────────────
# Echoes the space-delimited capabilities of a given agent CLI. Every optional
# headless flag is gated on cli_has_cap; a missing cap means skip the flag, log
# an honest note, and NEVER abort. copilot stays a pure agent-file invocation.
cli_capabilities() {
  case "$1" in
    claude)  echo "sysprompt permissions budget json session" ;;
    copilot) echo "sysprompt" ;;
    gemini)  echo "sysprompt" ;;
    *)       echo "" ;;
  esac
}

cli_has_cap() {
  # cli_has_cap <cli> <cap> — predicate, returns 0 if <cli> advertises <cap>.
  local caps cap
  caps=" $(cli_capabilities "$1") "
  cap="$2"
  case "$caps" in
    *" $cap "*) return 0 ;;
    *)          return 1 ;;
  esac
}

# ─── Cumulative per-run budget helpers (D4 / FR-003) ──────────────────────────
# RUN_COST_USD is a float accumulator (awk). MAX_BUDGET_USD is the cumulative
# per-RUN cap; the --max-budget-usd flag is per-INVOCATION, so we pass the
# REMAINING budget on each call to keep total spend under the cap.
RUN_COST_USD=0

budget_remaining() {
  # Echoes remaining budget; empty string ⇒ unlimited (omit the flag).
  if [[ -z "$MAX_BUDGET_USD" ]]; then
    echo ""
    return 0
  fi
  awk -v cap="$MAX_BUDGET_USD" -v spent="$RUN_COST_USD" \
    'BEGIN { r = cap - spent; if (r < 0) r = 0; printf "%.2f", r }'
}

budget_exhausted() {
  # Returns 0 (true) when the cumulative cap is set and has been reached.
  [[ -z "$MAX_BUDGET_USD" ]] && return 1
  awk -v cap="$MAX_BUDGET_USD" -v spent="$RUN_COST_USD" \
    'BEGIN { exit !(spent >= cap) }'
}

budget_accumulate() {
  # Adds the last call cost (LAST_COST, possibly empty/null) to RUN_COST_USD.
  local add="${1:-0}"
  case "$add" in ''|null|NULL) add=0 ;; esac
  RUN_COST_USD=$(awk -v a="$RUN_COST_USD" -v b="$add" \
    'BEGIN { printf "%.6f", a + b }')
}

# ─── Telemetry hand-off (D6 — pro-report.sh is the single writer) ─────────────
# All calls are best-effort (|| true) and self-skip when reporting is disabled
# or the script is absent. We pass ONLY the metric flags whose values were
# actually obtained (empty ⇒ omitted ⇒ stored null downstream).
reporting_active() {
  [[ -n "$RUN_ID" && -f "$PRO_REPORT" ]]
}

report_phase() {
  # report_phase <start|stop> <phase> [status]
  # cmd_phase signature is POSITIONAL: `phase <start|stop> <run_id> <phase_name>`
  # (pro-report.sh validates arg1 ∈ {start,stop}). The optional status is not part
  # of a phase marker, so it is intentionally not forwarded.
  reporting_active || return 0
  local action="$1" phase="$2"
  bash "$PRO_REPORT" phase "$action" "$RUN_ID" "$phase" >/dev/null 2>&1 || true
}

report_call() {
  # report_call <phase> <signal> [extra-flags...]
  # Appends the LAST_* metric flags that were actually obtained, then any extras
  # passed by the caller (e.g. --rework, --cb-trip).
  reporting_active || return 0
  local phase="$1" signal="$2"; shift 2
  # Normalize the raw control signal to the documented lowercase status enum so the
  # headless and in-harness producers write ONE vocabulary (telemetry-schema.md).
  local status
  case "$signal" in
    COMPLETE)         status="complete" ;;
    CONTINUE)         status="continue" ;;
    BLOCKED*)         status="blocked" ;;
    PASS*)            status="complete" ;;
    NEEDS_REVISION*)  status="blocked" ;;
    BUDGET_STOP|ERROR*|FAIL*) status="error" ;;
    *)                status="$signal" ;;
  esac
  local args
  args=(call "$RUN_ID" --phase "$phase" --status "$status")
  [[ -n "${LAST_COST:-}"      && "$LAST_COST"     != "null" ]] && args+=(--cost-usd "$LAST_COST")
  [[ -n "${LAST_IN_TOK:-}"    && "$LAST_IN_TOK"   != "null" ]] && args+=(--input-tokens "$LAST_IN_TOK")
  [[ -n "${LAST_OUT_TOK:-}"   && "$LAST_OUT_TOK"  != "null" ]] && args+=(--output-tokens "$LAST_OUT_TOK")
  [[ -n "${LAST_CACHE_R:-}"   && "$LAST_CACHE_R"  != "null" ]] && args+=(--cache-read-tokens "$LAST_CACHE_R")
  [[ -n "${LAST_CACHE_C:-}"   && "$LAST_CACHE_C"  != "null" ]] && args+=(--cache-creation-tokens "$LAST_CACHE_C")
  [[ -n "${LAST_TURNS:-}"     && "$LAST_TURNS"    != "null" ]] && args+=(--turns "$LAST_TURNS")
  [[ -n "${LAST_DUR_MS:-}"    && "$LAST_DUR_MS"   != "null" ]] && args+=(--duration-ms "$LAST_DUR_MS")
  [[ -n "${LAST_SESSION_ID:-}" ]] && args+=(--session-id "$LAST_SESSION_ID")
  [[ -n "${LAST_SOURCE:-}" ]]     && args+=(--source "$LAST_SOURCE")
  # Caller-supplied extras (--rework / --cb-trip)
  while [[ $# -gt 0 ]]; do args+=("$1"); shift; done
  bash "$PRO_REPORT" "${args[@]}" >/dev/null 2>&1 || true
}

# ─── Headless claude flag assembly (contract: build_claude_flags) ─────────────
# Builds a positional bash-3.2 array CLAUDE_FLAGS for a claude --print call.
#   build_claude_flags <agentfile> <role>   role ∈ generator|revision|evaluator
# Every optional flag is capability-gated. The system prompt is injected as the
# LITERAL FILE CONTENTS via --append-system-prompt "$(cat FILE)" — the FR-001
# fix: NEVER a path, and there is NO --system-prompt-file in claude 2.1.116.
CLAUDE_FLAGS=()
build_claude_flags() {
  local agentfile="$1" role="$2"
  local tools remaining
  CLAUDE_FLAGS=()

  # Always present.
  CLAUDE_FLAGS+=(--print --model "$CLAUDE_FLAGS_MODEL")
  # FR-001 fix: inject the agent definition as the LITERAL system-prompt contents,
  # never a path. Guard the read — under `set -euo pipefail` a missing/dangling
  # agent file would otherwise abort the orchestrator mid-substitution with a bare
  # `cat:` error and no actionable [Pro] diagnostic.
  if [[ ! -r "$agentfile" ]]; then
    log_error "Agent definition not found/readable: $agentfile (extension not materialized / broken symlink?)"
    exit 1
  fi
  CLAUDE_FLAGS+=(--append-system-prompt "$(cat "$agentfile")")

  # Permissions (capability-gated).
  if cli_has_cap claude permissions; then
    # The evaluator is an independent, READ-ONLY grader — it must NEVER receive the
    # permission bypass, even when the operator opts the generator into it. Gating
    # the dangerous-skip on role!=evaluator forces the evaluator down the
    # permission-mode + read-only-tools branch unconditionally (FR-015/FR-016).
    if [[ "$DANGEROUS_SKIP" == "true" && "$role" != "evaluator" ]]; then
      CLAUDE_FLAGS+=(--dangerously-skip-permissions)
    else
      CLAUDE_FLAGS+=(--permission-mode "$PERMISSION_MODE")
      if [[ "$role" == "evaluator" ]]; then
        tools="$EVALUATOR_ALLOWED_TOOLS"
      else
        tools="$ALLOWED_TOOLS"
      fi
      # --allowedTools accepts a single space- OR comma-separated value
      # (claude 2.1.116 help: example "Bash(git *) Edit"). Pass it as ONE quoted
      # argument so multi-word tool specs like "Bash(git *)" stay intact and the
      # bare "*" never glob-expands against the cwd.
      CLAUDE_FLAGS+=(--allowedTools "$tools")
      [[ -n "$DISALLOWED_TOOLS" ]] && CLAUDE_FLAGS+=(--disallowedTools "$DISALLOWED_TOOLS")
    fi
  fi

  # Budget — pass REMAINING per-invocation (D4).
  if cli_has_cap claude budget; then
    remaining=$(budget_remaining)
    if [[ -n "$remaining" ]]; then
      awk -v r="$remaining" 'BEGIN { exit !(r > 0) }' && CLAUDE_FLAGS+=(--max-budget-usd "$remaining")
    fi
  fi

  # Fallback model (rides the session cap-set).
  if cli_has_cap claude session && [[ -n "$FALLBACK_MODEL" ]]; then
    CLAUDE_FLAGS+=(--fallback-model "$FALLBACK_MODEL")
  fi

  # Structured output.
  if cli_has_cap claude json; then
    CLAUDE_FLAGS+=(--output-format "$OUTPUT_FORMAT")
  fi

  # Session persistence / continuity (D5). The evaluator is an INDEPENDENT grader:
  # it never resumes the generator's session (which would inject the generator's
  # transcript + rationalizations into the grader, and mismatch --evaluator-model
  # against a session minted under the generator model) and never persists its own
  # session — each evaluation is a cold, context-free judgment of the end state
  # (FR-015/FR-016).
  if [[ "$SESSION_PERSISTENCE" == "false" || "$role" == "evaluator" ]]; then
    CLAUDE_FLAGS+=(--no-session-persistence)
  fi
  # First call ⇒ omit --session-id entirely (run-id is NOT a UUID); on later
  # generator/revision calls resume the CLI-minted session UUID from prior JSON.
  if cli_has_cap claude session && [[ -n "$SESSION_ID" && "$role" != "evaluator" ]]; then
    CLAUDE_FLAGS+=(--resume "$SESSION_ID")
  fi
}

# ─── Defensive result parse (contract: parse_agent_result) ────────────────────
# parse_agent_result <cli> <stdout> <stderr> <exit> <tag>
#   <tag> = pro-status (generator) | pro-eval (evaluator)
# Captures stdout/stderr SEPARATELY (no 2>&1 on the json path). Ladder:
# python3-JSON → text <tag>-scrape. Exports LAST_* and echoes the control
# signal. Malformed JSON on a json-capable CLI ⇒ ERROR (never silent success).
# It sets the global PARSE_SIGNAL (NOT echoed) so the LAST_* exports survive into
# the caller's shell — a $(...) command substitution would discard them.
parse_agent_result() {
  local cli="$1" out="$2" err="$3" exit_code="$4" tag="$5"
  local result is_error signal
  PARSE_SIGNAL=""

  # Reset metric exports for this call.
  LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
  LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
  export LAST_COST LAST_IN_TOK LAST_OUT_TOK LAST_CACHE_R LAST_CACHE_C \
         LAST_TURNS LAST_DUR_MS LAST_SESSION_ID LAST_SOURCE

  # ── Ladder rung 1: JSON via python3 (only when the CLI advertises json) ──
  if cli_has_cap "$cli" json && command -v python3 >/dev/null 2>&1; then
    local parsed
    parsed=$(
      printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("PYJSON_FAIL"); sys.exit(0)
if not isinstance(d, dict):
    print("PYJSON_FAIL"); sys.exit(0)
def g(k, default=""):
    v = d.get(k, default)
    return "" if v is None else v
u = d.get("usage") or {}
def gu(k):
    v = u.get(k)
    return "" if v is None else v
fields = [
    "OK",
    str(g("result")).replace("\n", "\\n").replace("\t", " "),
    "true" if d.get("is_error") else "false",
    str(g("total_cost_usd")),
    str(gu("input_tokens")),
    str(gu("output_tokens")),
    str(gu("cache_read_input_tokens")),
    str(gu("cache_creation_input_tokens")),
    str(g("num_turns")),
    str(g("duration_ms")),
    str(g("session_id")),
]
print("\t".join(fields))
' 2>/dev/null
    )

    if [[ "$parsed" == OK$'\t'* ]]; then
      # Tab-split the python output.
      local ok rest
      ok="${parsed%%$'\t'*}"
      rest="${parsed#*$'\t'}"
      result="${rest%%$'\t'*}";        rest="${rest#*$'\t'}"
      is_error="${rest%%$'\t'*}";      rest="${rest#*$'\t'}"
      LAST_COST="${rest%%$'\t'*}";     rest="${rest#*$'\t'}"
      LAST_IN_TOK="${rest%%$'\t'*}";   rest="${rest#*$'\t'}"
      LAST_OUT_TOK="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
      LAST_CACHE_R="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
      LAST_CACHE_C="${rest%%$'\t'*}";  rest="${rest#*$'\t'}"
      LAST_TURNS="${rest%%$'\t'*}";    rest="${rest#*$'\t'}"
      LAST_DUR_MS="${rest%%$'\t'*}";   rest="${rest#*$'\t'}"
      LAST_SESSION_ID="$rest"
      LAST_SOURCE="json"

      if [[ "$is_error" == "true" ]]; then
        # is_error → budget marker first (clean stop), else a circuit-breaker ERROR.
        if printf '%s' "$result" | grep -qiE 'budget|max-budget|spend (limit|cap)|cost limit'; then
          signal="BUDGET_STOP"
        else
          local detail
          detail=$(printf '%s' "$result" | tr '\n' ' ')
          [[ -z "$detail" ]] && detail=$(printf '%s' "$err" | tr '\n' ' ' | head -c 200)
          [[ -z "$detail" ]] && detail="agent reported is_error"
          signal="ERROR:$detail"
        fi
      else
        # Scrape the control tag out of .result.
        signal=$(printf '%s' "$result" | grep -oE "<$tag>[^<]+</$tag>" | tail -1 | sed 's/<[^>]*>//g')
        [[ -z "$signal" ]] && signal="ERROR:no-status-tag"
      fi
      PARSE_SIGNAL="$signal"
      return 0
    fi

    # JSON capable but unparseable/partial → ERROR (counts toward breaker).
    # Distinguish a hard non-zero exit (process crash) from malformed output.
    if [[ "${exit_code:-0}" -ne 0 ]]; then
      local crash
      crash=$(printf '%s' "$err" | tr '\n' ' ' | head -c 200)
      [[ -z "$crash" ]] && crash="exit $exit_code"
      LAST_SOURCE="json"
      PARSE_SIGNAL="ERROR:$crash"
      return 0
    fi
    LAST_SOURCE="json"
    PARSE_SIGNAL="ERROR:malformed-json"
    return 0
  fi

  # ── Ladder rung 2: text fallback — scrape <tag> over stdout ──
  # Capability gap (no json cap / python3 absent): logged, NOT a failure.
  LAST_SOURCE="text-fallback"
  signal=$(printf '%s' "$out" | grep -oE "<$tag>[^<]+</$tag>" | tail -1 | sed 's/<[^>]*>//g')
  if [[ -z "$signal" ]]; then
    if [[ "${exit_code:-0}" -ne 0 ]]; then
      local tdetail
      tdetail=$(printf '%s' "$err" | tr '\n' ' ' | head -c 200)
      [[ -z "$tdetail" ]] && tdetail="exit $exit_code"
      PARSE_SIGNAL="ERROR:$tdetail"
    else
      PARSE_SIGNAL="UNKNOWN"
    fi
    return 0
  fi
  PARSE_SIGNAL="$signal"
  return 0
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

  local agent_output agent_err agent_exit=0
  local agentfile=".github/agents/speckit.pro.loop.agent.md"

  # Invoke the agent — run speckit.pro.loop command.
  # Different CLIs have different invocation patterns. Only the claude branch is
  # capability-driven (flags + separate stdout/stderr + defensive JSON parse);
  # copilot/gemini/generic stay byte-for-byte the existing agent-file invocation
  # (FR-007) and are routed through the text-fallback parse rung.
  case "$resolved_cli" in
    copilot)
      agent_output=$(
        "$resolved_cli" agent --model "$MODEL" \
          ".github/agents/speckit.pro.loop.agent.md" \
          "$prompt_args" 2>&1
      ) || agent_exit=$?
      agent_err=""
      ;;
    claude)
      # FR-001 fix: inject the agent file as the LITERAL system prompt contents,
      # not a path. Capture stdout/stderr SEPARATELY (no 2>&1 on the json path).
      CLAUDE_FLAGS_MODEL="$MODEL"
      build_claude_flags "$agentfile" generator
      local tmp_err
      tmp_err=$(mktemp 2>/dev/null || echo "/tmp/pro-orch-gen-$$.err")
      agent_output=$(
        "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$prompt_args" 2>"$tmp_err"
      ) || agent_exit=$?
      agent_err=$(cat "$tmp_err" 2>/dev/null || echo "")
      rm -f "$tmp_err" 2>/dev/null || true
      ;;
    gemini)
      agent_output=$(
        "$resolved_cli" run \
          --model "$MODEL" \
          ".github/agents/speckit.pro.loop.agent.md" \
          "$prompt_args" 2>&1
      ) || agent_exit=$?
      agent_err=""
      ;;
    *)
      # Generic fallback — run with the command as first arg
      agent_output=$(
        "$resolved_cli" ".github/agents/speckit.pro.loop.agent.md" "$prompt_args" 2>&1
      ) || agent_exit=$?
      agent_err=""
      ;;
  esac

  # Normalize to a control signal. parse_agent_result sets PARSE_SIGNAL and the
  # LAST_* exports IN THIS SHELL (no $(...) — a command substitution would discard
  # the LAST_* metrics). The caller reads the AGENT_SIGNAL global afterwards.
  parse_agent_result "$resolved_cli" "$agent_output" "$agent_err" "$agent_exit" "pro-status"
  AGENT_SIGNAL="$PARSE_SIGNAL"
}

# ─── Evaluator Functions ─────────────────────────────────────────────────────

run_evaluator() {
  local sprint="$1" resolved_cli="$2"
  # Contract-path alignment (critique R12 / D9): point the evaluator at the SAME
  # path /pro.contract writes and the seal is verified against — the feature
  # knowledge dir, NOT $SPEC_DIR/contracts.
  local contract_path="$FEATURE_KNOWLEDGE_DIR/contracts/sprint-${sprint}.md"
  local eval_output eval_err eval_exit=0
  local agentfile=".github/agents/speckit.pro.evaluate.agent.md"

  # Read-only evaluator + model independence (D10). Empty → primary model with a
  # SHARED-MODEL disclosure (the grader cannot then be claimed independent).
  local eval_model shared_model=false
  eval_model="${EVALUATOR_MODEL:-$MODEL}"
  if [[ -z "$EVALUATOR_MODEL" || "$eval_model" == "$MODEL" ]]; then
    if [[ "$SHARED_MODEL_WARN" == "true" ]]; then
      log_warn "SHARED-MODEL: evaluator and generator share model '$eval_model' — independence is reduced; set --evaluator-model to separate them."
      shared_model=true
    fi
  fi

  local eval_args="feature=$FEATURE_NAME spec-dir=$SPEC_DIR sprint=$sprint"
  eval_args="$eval_args contract=$contract_path tasks=$TASKS_PATH model=$eval_model shared-model=$shared_model"

  log_info "Spawning evaluator for sprint $sprint..."

  case "$resolved_cli" in
    copilot)
      eval_output=$(
        "$resolved_cli" agent --model "$MODEL" \
          ".github/agents/speckit.pro.evaluate.agent.md" \
          "$eval_args" 2>&1
      ) || true
      eval_err=""
      ;;
    claude)
      # Evaluator role ⇒ read-only tool set; --model is the evaluator model.
      CLAUDE_FLAGS_MODEL="$eval_model"
      build_claude_flags "$agentfile" evaluator
      local tmp_err
      tmp_err=$(mktemp 2>/dev/null || echo "/tmp/pro-orch-eval-$$.err")
      eval_output=$(
        "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$eval_args" 2>"$tmp_err"
      ) || eval_exit=$?
      eval_err=$(cat "$tmp_err" 2>/dev/null || echo "")
      rm -f "$tmp_err" 2>/dev/null || true
      ;;
    *)
      eval_output=$(
        "$resolved_cli" ".github/agents/speckit.pro.evaluate.agent.md" "$eval_args" 2>&1
      ) || true
      eval_err=""
      ;;
  esac

  # Normalize via the shared defensive parser. parse_agent_result sets
  # PARSE_SIGNAL and LAST_* IN THIS SHELL (no $(...)). The caller reads EVAL_SIGNAL.
  parse_agent_result "$resolved_cli" "$eval_output" "$eval_err" "$eval_exit" "pro-eval"
  EVAL_SIGNAL="$PARSE_SIGNAL"
}

handle_eval_result() {
  local eval_tag="$1" sprint="$2" revision="$3"
  local verdict score_or_issues

  # ── Rubric-seal tamper (D9) ── A rubric-mutated/rubric-unsealed verdict means
  # the committed sprint contract seal failed to verify. This is a hard,
  # un-retryable failure: loud operator alarm, return 2 (no revision retry).
  if printf '%s' "$eval_tag" | grep -qiE 'rubric-mutated|rubric-unsealed'; then
    log_error "════════════════════════════════════════════════════════════"
    log_error "RUBRIC TAMPER — operator review required"
    log_error "Sprint $sprint: the contract seal failed verification ($eval_tag)."
    log_error "The evaluation rubric was mutated or unsealed during the run."
    log_error "Halting: this is a hard fail with NO automatic retry."
    log_error "════════════════════════════════════════════════════════════"
    update_session "evaluate" "tamper" "Sprint $sprint: rubric seal verification failed ($eval_tag)"
    return 2  # hard fail, un-retryable
  fi

  # Parse VERDICT:details from tag
  verdict=$(echo "$eval_tag" | cut -d: -f1)
  score_or_issues=$(echo "$eval_tag" | cut -d: -f2-)

  case "$verdict" in
    PASS)
      local score="$score_or_issues"
      log_success "Evaluator: PASS (score: ${score}%)"
      if [[ "$score" -lt "$EVAL_THRESHOLD" ]] 2>/dev/null; then
        log_warn "Score ${score}% below threshold ${EVAL_THRESHOLD}% — requesting revision"
        return 1  # needs revision
      fi
      return 0  # accepted
      ;;
    NEEDS_REVISION)
      log_warn "Evaluator: NEEDS_REVISION — $score_or_issues"
      log_warn "Revision $revision/$MAX_REVISIONS — generator will fix and retry"
      return 1  # needs revision
      ;;
    FAIL)
      log_error "Evaluator: FAIL — $score_or_issues"
      log_error "Sprint $sprint failed evaluation after $revision revision(s)"
      update_session "evaluate" "failed" "Sprint $sprint: $score_or_issues"
      return 2  # hard fail
      ;;
    *)
      log_warn "Evaluator returned unknown verdict '$verdict' — treating as PASS"
      return 0
      ;;
  esac
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
  # Session continuity (D5): first call omits --session-id; we capture the
  # CLI-minted session UUID and --resume it thereafter. RUN_COST_USD is the
  # cumulative per-run budget accumulator (declared at file scope, reset here).
  SESSION_ID=""
  RUN_COST_USD=0

  # Resolve the agent CLI
  resolved_cli=$(detect_agent_cli)

  # Initialize tracking files
  init_progress_file

  # Self-stamp a run for telemetry when invoked directly from a terminal (pro.resume /
  # pro.pickup pass no --run-id). Without this, RUN_ID is empty, reporting_active() is
  # false, and the headless path records NO per-call cost/tokens — the very telemetry
  # this path uniquely provides. A matching `finish` fires from the EXIT trap below.
  if [[ -z "$RUN_ID" && -f "$PRO_REPORT" ]]; then
    RUN_ID="$(bash "$PRO_REPORT" start --feature "$FEATURE_NAME" 2>/dev/null | tail -1)"
    [[ -n "$RUN_ID" ]] && SELF_STAMPED=1
  fi

  # Determine starting iteration (resume mode)
  if [[ "$RESUME" == "true" && -f "$PROGRESS_FILE" ]]; then
    local last_iter
    # checkpoint_commit persists labels like `iter3` / `circuit-breaker-iter5` to
    # PROGRESS_FILE (the "Loop Iteration N" banner is stdout-only), so resume must
    # read the label form that is actually written, not the banner text.
    last_iter=$(grep -oE 'iter[0-9]+' "$PROGRESS_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    last_iter=${last_iter:-0}
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
  echo -e "${GREEN}║  Evaluator:  $([[ $ENABLE_EVALUATOR == true ]] && echo "enabled (threshold: ${EVAL_THRESHOLD}%, revisions: ${MAX_REVISIONS})" || echo 'disabled')${RESET}"
  echo -e "${GREEN}║  Model:      $MODEL${RESET}"
  echo -e "${GREEN}║  Sub-agent:  ${SUBAGENT_MODEL:-"(same as model)"}${RESET}"
  echo -e "${GREEN}║  Effort:     plan=${EFFORT_PLANNING} exec=${EFFORT_EXECUTION} verify=${EFFORT_VERIFICATION}${RESET}"
  echo -e "${GREEN}║  Agent CLI:  $resolved_cli${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""

  # ─── Resolved capability banner (contract: cli-invocation.md) ───────────────
  local resolved_caps
  resolved_caps=$(cli_capabilities "$resolved_cli")
  if [[ -n "$resolved_caps" ]]; then
    log_info "CLI capabilities ($resolved_cli): $resolved_caps"
  else
    log_info "CLI capabilities ($resolved_cli): (none — pure agent-file invocation)"
  fi
  # Honest degraded note for each headless feature the resolved CLI cannot do.
  if ! cli_has_cap "$resolved_cli" permissions; then
    log_warn "Degraded: '$resolved_cli' has no headless permission/tool gating — --permission-mode/--allowed-tools ignored."
  fi
  if ! cli_has_cap "$resolved_cli" budget; then
    log_warn "Degraded: '$resolved_cli' has no headless budget cap — --max-budget-usd ignored (cumulative cap not enforced at the CLI)."
  fi
  if ! cli_has_cap "$resolved_cli" json; then
    log_warn "Degraded: '$resolved_cli' emits no structured JSON — falling back to text <tag> scrape (metrics will be null)."
  fi
  if ! cli_has_cap "$resolved_cli" session; then
    log_warn "Degraded: '$resolved_cli' has no headless session continuity — each iteration is independent."
  fi
  if [[ -n "$RUN_ID" && -f "$PRO_REPORT" ]]; then
    log_info "Telemetry: per-call metrics → pro-report.sh (run-id $RUN_ID)."
  fi
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

    # ── Cumulative per-run budget gate (D4 / FR-003) ──────────────────────
    # The CLI's --max-budget-usd is per-invocation; we enforce the per-RUN cap
    # here. If the cumulative cap is already reached, stop cleanly (checkpoint),
    # NOT via the ERROR circuit breaker.
    if budget_exhausted; then
      log_warn "Cumulative budget cap ($MAX_BUDGET_USD USD) reached after spending ~${RUN_COST_USD} — stopping (clean checkpoint)."
      read -r completed total <<< "$(count_tasks)"
      checkpoint_commit "stopped-budget-iter${iteration}" "$completed" "$total"
      update_session "implement" "stopped_budget" "Cumulative budget cap reached (~${RUN_COST_USD}/${MAX_BUDGET_USD} USD) at iteration $iteration"
      # Budget-stop marker (no metric flags — no agent call happened this pass).
      LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
      LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
      report_call implement BUDGET_STOP --cb-trip
      exit 0
    fi

    # ── Generator sprint ───────────────────────────────────────────────────
    log_info "Spawning generator iteration $iteration/$MAX_ITERATIONS..."
    local agent_status
    report_phase start implement
    run_agent_iteration "$iteration" "$resolved_cli"
    agent_status="$AGENT_SIGNAL"
    log_info "Generator status: $agent_status"

    # Thread session continuity + accumulate cumulative cost (D4/D5), then hand
    # off per-call metrics to the single telemetry writer (D6, best-effort).
    [[ -n "${LAST_SESSION_ID:-}" ]] && SESSION_ID="$LAST_SESSION_ID"
    budget_accumulate "${LAST_COST:-0}"
    report_call implement "$agent_status"
    report_phase stop implement "$agent_status"

    # A BUDGET_STOP from the CLI is a clean checkpoint+record, routed away from
    # the ERROR circuit breaker.
    if [[ "$agent_status" == "BUDGET_STOP" ]]; then
      log_warn "Generator hit the per-invocation budget cap — stopping (clean checkpoint)."
      read -r completed total <<< "$(count_tasks)"
      checkpoint_commit "stopped-budget-iter${iteration}" "$completed" "$total"
      update_session "implement" "stopped_budget" "CLI reported budget stop at iteration $iteration (~${RUN_COST_USD}/${MAX_BUDGET_USD} USD)"
      exit 0
    fi

    # ── Evaluator cycle (if enabled) ───────────────────────────────────────
    if [[ "$ENABLE_EVALUATOR" == true ]] && [[ "$agent_status" != "COMPLETE" ]] && [[ "$agent_status" != "ERROR:"* ]]; then
      local revision=1 eval_result
      while [[ "$revision" -le "$MAX_REVISIONS" ]]; do
        local eval_tag
        report_phase start evaluate
        run_evaluator "$iteration" "$resolved_cli"
        eval_tag="$EVAL_SIGNAL"
        log_info "Evaluator tag: $eval_tag"
        # Telemetry hand-off for the evaluator call (best-effort).
        report_call evaluate "$eval_tag"
        report_phase stop evaluate "$eval_tag"

        handle_eval_result "$eval_tag" "$iteration" "$revision"
        eval_result=$?

        if [[ "$eval_result" -eq 0 ]]; then
          break  # Evaluator passed
        elif [[ "$eval_result" -eq 2 ]]; then
          # Hard fail (incl. rubric tamper) — circuit breaker, un-retryable.
          read -r completed total <<< "$(count_tasks)"
          checkpoint_commit "eval-fail-sprint${iteration}" "$completed" "$total"
          report_call evaluate "$eval_tag" --cb-trip
          exit 1
        fi

        # NEEDS_REVISION — give generator another pass
        revision=$(( revision + 1 ))
        if [[ "$revision" -le "$MAX_REVISIONS" ]]; then
          log_info "Generator revision $revision/$MAX_REVISIONS..."
          local rev_args rev_output rev_err rev_exit=0
          local rev_agentfile=".github/agents/speckit.pro.loop.agent.md"
          rev_args="feature=$FEATURE_NAME tasks=$TASKS_PATH spec-dir=$SPEC_DIR"
          rev_args="$rev_args iteration=$iteration max=$MAX_ITERATIONS"
          # Read evaluator feedback from where the evaluator agent actually writes it
          # (FEATURE_KNOWLEDGE_DIR/evaluations — the only evaluations dir created at
          # L119), not SPEC_DIR/evaluations which never exists (revision-loop path fix).
          rev_args="$rev_args revision=$revision eval-feedback=$FEATURE_KNOWLEDGE_DIR/evaluations/sprint-${iteration}.md"
          # Run generator revision inline (brief pass — fix evaluator issues only)
          report_phase start revision
          case "$resolved_cli" in
            copilot)
              "$resolved_cli" agent --model "$MODEL" \
                ".github/agents/speckit.pro.loop.agent.md" \
                "$rev_args" &>/dev/null || true
              rev_output=""; rev_err=""
              ;;
            claude)
              # Capability-driven revision pass — separate stdout/stderr + parse.
              CLAUDE_FLAGS_MODEL="$MODEL"
              build_claude_flags "$rev_agentfile" revision
              local rev_tmp_err
              rev_tmp_err=$(mktemp 2>/dev/null || echo "/tmp/pro-orch-rev-$$.err")
              rev_output=$(
                "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$rev_args" 2>"$rev_tmp_err"
              ) || rev_exit=$?
              rev_err=$(cat "$rev_tmp_err" 2>/dev/null || echo "")
              rm -f "$rev_tmp_err" 2>/dev/null || true
              ;;
            *)
              "$resolved_cli" ".github/agents/speckit.pro.loop.agent.md" "$rev_args" &>/dev/null || true
              rev_output=""; rev_err=""
              ;;
          esac
          # Parse revision result, thread session, accumulate cost, hand off
          # the rework telemetry call (best-effort).
          parse_agent_result "$resolved_cli" "$rev_output" "$rev_err" "$rev_exit" "pro-status"
          [[ -n "${LAST_SESSION_ID:-}" ]] && SESSION_ID="$LAST_SESSION_ID"
          budget_accumulate "${LAST_COST:-0}"
          report_call revision "$PARSE_SIGNAL" --rework
          report_phase stop revision "$PARSE_SIGNAL"
        else
          log_warn "Max revisions ($MAX_REVISIONS) reached for sprint $iteration — moving on"
        fi
      done
    fi

    # ── Status processing ──────────────────────────────────────────────────
    case "$agent_status" in
      COMPLETE)
        log_success "Agent confirmed all tasks complete!"
        read -r completed total <<< "$(count_tasks)"
        checkpoint_commit "final-complete" "$completed" "$total"
        update_session "implement" "completed" "All tasks complete after $iteration iterations"
        break
        ;;
      CONTINUE)
        log_success "Sprint $iteration complete — continuing..."
        consecutive_failures=0
        ;;
      BLOCKED:*)
        local reason="${agent_status#BLOCKED:}"
        log_warn "Task blocked: $reason"
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: $consecutive_failures consecutive blocks"
          read -r completed total <<< "$(count_tasks)"
          update_session "implement" "blocked" "Circuit breaker triggered: $reason"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          # cb-trip marker (no metric flags — the call's metrics were already sent).
          LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
          LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
          report_call implement "$agent_status" --cb-trip
          exit 1
        fi
        ;;
      ERROR:*)
        local err_msg="${agent_status#ERROR:}"
        log_error "Generator error: $err_msg"
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: 3 consecutive failures"
          read -r completed total <<< "$(count_tasks)"
          update_session "implement" "failed" "Circuit breaker: $err_msg"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          # cb-trip marker (no metric flags — the call's metrics were already sent).
          LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
          LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
          report_call implement "$agent_status" --cb-trip
          exit 1
        fi
        log_warn "Retrying... ($consecutive_failures/3 failures)"
        ;;
      *)
        log_warn "Unknown generator status: '$agent_status' — treating as CONTINUE"
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
    echo ""
    log_info "Next (chat pipeline): run pro.go Phase 7 in the agent —"
    log_info "  /speckit.pro.reconcile → /speckit.pro.local-review → /speckit.pro.evaluate → /speckit.pro.knowledge-sync (sync on PASS)"
    log_info "Hooks may also fire this chain on native /speckit.implement; /pro.go must not rely on hooks alone."
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
# Close a self-stamped run on ANY exit (success, failure, circuit-breaker, budget,
# or Ctrl-C) so the terminal path always produces a run-report + runs.jsonl line.
# Runs at most once; no-op when --run-id was supplied (the caller owns finish then).
finish_self_stamped() {
  [[ "${SELF_STAMPED:-0}" -eq 1 && -f "$PRO_REPORT" ]] || return 0
  SELF_STAMPED=0
  bash "$PRO_REPORT" finish --feature "$FEATURE_NAME" --run-id "$RUN_ID" \
    --max-iterations "$MAX_ITERATIONS" --no-stdout >/dev/null 2>&1 || true
}
trap finish_self_stamped EXIT
trap 'echo ""; log_warn "Interrupted by user. Run /speckit.pro.resume to continue."; exit 130' INT

main "$@"
