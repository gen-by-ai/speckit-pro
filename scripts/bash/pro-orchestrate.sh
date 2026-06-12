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
# Every operational knob honors a SPECKIT_PRO_* env override. Precedence:
# CLI flag > SPECKIT_PRO_* env > built-in default (flags are parsed below and
# simply overwrite these values).
MAX_ITERATIONS="${SPECKIT_PRO_MAX_ITERATIONS:-20}"
CHECKPOINT_FREQUENCY="${SPECKIT_PRO_CHECKPOINT_FREQUENCY:-3}"
MODEL="${SPECKIT_PRO_MODEL:-claude-sonnet-4.6}"
SUBAGENT_MODEL="${SPECKIT_PRO_SUBAGENT_MODEL:-}"  # when set, exported as CLAUDE_CODE_SUBAGENT_MODEL
AGENT_CLI="${SPECKIT_PRO_AGENT_CLI:-copilot}"
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
ENABLE_EVALUATOR="${SPECKIT_PRO_ENABLE_EVALUATOR:-false}"
EVAL_THRESHOLD="${SPECKIT_PRO_EVAL_THRESHOLD:-70}"  # minimum score (0-100) for PASS
MAX_REVISIONS="${SPECKIT_PRO_MAX_REVISIONS:-2}"     # max generator revision attempts per sprint before FAIL

# ─── Reliability knobs (v1.24 — survive-the-night hardening) ──────────────────
ITERATION_TIMEOUT="${SPECKIT_PRO_ITERATION_TIMEOUT:-1800}"  # seconds per agent/evaluator call; 0 = no timeout
MAX_WALL_SECONDS="${SPECKIT_PRO_MAX_WALL_SECONDS:-}"        # whole-run wall-clock budget; empty = unlimited
NO_PROGRESS_LIMIT="${SPECKIT_PRO_NO_PROGRESS_LIMIT:-3}"     # CONTINUE iterations w/o checkbox delta before watchdog stop; 0 = off
# Explicitness trackers for the three knobs above: pro-config loop.* values may
# only fill the gap when NEITHER a CLI flag NOR a SPECKIT_PRO_* env var set the
# knob (documented precedence: flag > env > config > default). Flags flip these
# to 1 in the arg parser; resolve_loop_knobs (called after arg parsing, once
# PROJECT_ROOT and cfg_get are usable) reads them.
ITERATION_TIMEOUT_SET=0; [[ -n "${SPECKIT_PRO_ITERATION_TIMEOUT:-}" ]] && ITERATION_TIMEOUT_SET=1
MAX_WALL_SECONDS_SET=0;  [[ -n "${SPECKIT_PRO_MAX_WALL_SECONDS:-}" ]]  && MAX_WALL_SECONDS_SET=1
NO_PROGRESS_LIMIT_SET=0; [[ -n "${SPECKIT_PRO_NO_PROGRESS_LIMIT:-}" ]] && NO_PROGRESS_LIMIT_SET=1
DOCTOR=false                                                # --doctor: print resolved config + environment diagnosis, exit 0
FORCE_LOCK=false                                            # --force-lock: steal a live lock (only after a confirmed crash)
WEBHOOK_URL="${SPECKIT_PRO_WEBHOOK_URL:-}"                  # overrides notify.webhook_url from pro-config
NOTIFY_ON_FAILURE="${SPECKIT_PRO_NOTIFY_ON_FAILURE:-}"      # true/false; empty = read notify.on_failure from pro-config
NOTIFY_ON_COMPLETE="${SPECKIT_PRO_NOTIFY_ON_COMPLETE:-}"    # true/false; empty = read notify.on_complete from pro-config
CURRENT_ITERATION=0                                         # global mirror of the loop counter (traps/notify read it)

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
    --iteration-timeout) ITERATION_TIMEOUT="$2"; ITERATION_TIMEOUT_SET=1; shift 2 ;;
    --max-wall-seconds) MAX_WALL_SECONDS="$2"; MAX_WALL_SECONDS_SET=1; shift 2 ;;
    --no-progress-limit) NO_PROGRESS_LIMIT="$2"; NO_PROGRESS_LIMIT_SET=1; shift 2 ;;
    --webhook-url)      WEBHOOK_URL="$2";      shift 2 ;;
    --doctor)           DOCTOR=true;           shift ;;
    --force-lock)       FORCE_LOCK=true;       shift ;;
    *)                  echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Derive PROJECT_ROOT / FEATURE_KNOWLEDGE_DIR ──────────────────────────────
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ -z "$FEATURE_KNOWLEDGE_DIR" ]]; then
  FEATURE_KNOWLEDGE_DIR="$PROJECT_ROOT/.knowledge/features/$FEATURE_NAME"
fi
if [[ "$DOCTOR" != "true" ]]; then
  mkdir -p "$FEATURE_KNOWLEDGE_DIR/contracts" "$FEATURE_KNOWLEDGE_DIR/evaluations" \
           "$FEATURE_KNOWLEDGE_DIR/logs"
fi

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

# ─── Validation (skipped in --doctor: diagnosis must not require a feature) ───
if [[ "$DOCTOR" != "true" ]]; then
  if [[ -z "$FEATURE_NAME" || -z "$TASKS_PATH" || -z "$SPEC_DIR" ]]; then
    echo -e "${RED}Error: --feature-name, --tasks-path, and --spec-dir are required.${RESET}"
    exit 1
  fi

  if [[ ! -f "$TASKS_PATH" ]]; then
    echo -e "${RED}Error: tasks.md not found at: $TASKS_PATH${RESET}"
    exit 1
  fi
fi

# ─── Paths ───────────────────────────────────────────────────────────────────
PROGRESS_FILE="$FEATURE_KNOWLEDGE_DIR/progress.md"  # persistent audit trail
SESSION_FILE="$SPEC_DIR/session.md"             # transient pipeline state
CONTEXT_SUMMARY="$SPEC_DIR/context-summary.md"
STATUS_FILE="$SPEC_DIR/.pro-status.json"            # file-based status contract (preferred over stdout scrape)
LOCK_FILE="$FEATURE_KNOWLEDGE_DIR/.lock"            # single-orchestrator concurrency guard
LOOP_STATE_FILE="$FEATURE_KNOWLEDGE_DIR/loop-state.json"  # orchestrator-owned durable state
LOGS_DIR="$FEATURE_KNOWLEDGE_DIR/logs"              # per-iteration agent transcripts
BLOCKED_LOG="$FEATURE_KNOWLEDGE_DIR/blocked.md"     # deferred-blocker journal (fed back to the worker)
NOTIFY_LOG="$PROJECT_ROOT/.knowledge/metrics/notifications.jsonl"  # always-on event audit trail

# ─── Helper Functions ────────────────────────────────────────────────────────

log_info()    { echo -e "${CYAN}[Pro]${RESET} $*"; }
log_success() { echo -e "${GREEN}[Pro] ✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[Pro] ⚠${RESET} $*"; }
log_error()   { echo -e "${RED}[Pro] ✗${RESET} $*"; }

banner() {
  local phase="$1" iter="$2" run_n="$3" completed="$4" total="$5"
  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}  SpecKit Pro │ Loop Iteration ${iter} (run budget ${run_n}/${MAX_ITERATIONS})${RESET}"
  echo -e "${BLUE}  Feature: ${FEATURE_NAME}  │  Phase: ${phase}${RESET}"
  echo -e "${BLUE}  Progress: ${completed}/${total} tasks${RESET}"
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
    # Stage broadly, then DE-STAGE workspace paths. Exclude pathspecs are a
    # trap here: naming a gitignored (or partly-ignored, e.g. force-added
    # seals) dir in ':(exclude)...' makes `git add` exit 1 with the
    # addIgnoredFile advice on git 2.x. `git reset -- <path>` has no such
    # edge: it is a no-op when nothing under the path is staged.
    local stage_rc=0
    local destage="specs .knowledge/features .knowledge/metrics"
    commit_artifacts_enabled && destage=".knowledge/features .knowledge/metrics"
    git add -A -- . 2>/dev/null || stage_rc=$?
    # shellcheck disable=SC2086  # intentional word-split of the path list
    git reset -q -- $destage 2>/dev/null \
      || git rm -r -q --cached --ignore-unmatch -- $destage 2>/dev/null || true
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

  # Auto-detect fallbacks. Diagnostics MUST go to stderr — this function is
  # consumed via $(...), and a stdout warning used to be captured INTO the
  # resolved CLI name, silently routing e.g. copilot through the generic branch.
  for cli in copilot claude gemini codex; do
    if command -v "$cli" &>/dev/null; then
      log_warn "Agent CLI '$AGENT_CLI' not found; using '$cli'" >&2
      echo "$cli"
      return 0
    fi
  done

  log_error "No agent CLI found. Install one of: copilot, claude, gemini, codex" >&2
  exit 1
}

# ─── Generic config reader ─────────────────────────────────────────────────────
# cfg_get <section> <key> — echoes the first value found across the config
# cascade (local → installed → repo root), empty when unset anywhere. Same
# zero-dependency awk section walker as commit_artifacts_enabled.
cfg_get() {
  local section="$1" key="$2" cfg v
  for cfg in "$PROJECT_ROOT/.specify/extensions/pro/pro-config.local.yml" \
             "$PROJECT_ROOT/.specify/extensions/pro/pro-config.yml" \
             "$PROJECT_ROOT/pro-config.yml"; do
    [[ -f "$cfg" ]] || continue
    v=$(awk -v sec="^${section}:" -v key="^[[:space:]]*${key}:" \
      '$0 ~ sec {f=1; next} f && /^[^ ]/ {f=0} f && $0 ~ key {gsub(/["'"'"']/,"",$2); print $2; exit}' \
      "$cfg" 2>/dev/null)
    if [[ -n "$v" ]]; then echo "$v"; return 0; fi
  done
  return 0
}

# ─── Config-backed loop knobs (defect fix: documented keys were dead) ──────────
# README/pro-config.template.yml document loop.iteration_timeout,
# loop.max_wall_seconds and loop.no_progress_limit with precedence
# "flag > env > config > default", but the three values were only ever read from
# SPECKIT_PRO_* env and CLI flags — the config keys were silently ignored.
# Called once at the bottom of the script, AFTER arg parsing and AFTER
# PROJECT_ROOT is derived (cfg_get needs both — same lifecycle as the notify.*
# resolution inside notify_event). Config only fills the gap when neither a
# flag nor an env var explicitly set the knob (the *_SET trackers); non-numeric
# config values are ignored with a warning, keeping the built-in default.
resolve_loop_knobs() {
  local v
  if [[ "${ITERATION_TIMEOUT_SET:-0}" -eq 0 ]]; then
    v=$(cfg_get loop iteration_timeout)
    if [[ -n "$v" ]]; then
      if [[ "$v" =~ ^[0-9]+$ ]]; then
        ITERATION_TIMEOUT="$v"
      else
        log_warn "pro-config loop.iteration_timeout='$v' is not numeric — ignoring (keeping ${ITERATION_TIMEOUT}s)"
      fi
    fi
  fi
  if [[ "${MAX_WALL_SECONDS_SET:-0}" -eq 0 ]]; then
    v=$(cfg_get loop max_wall_seconds)
    if [[ -n "$v" ]]; then
      if [[ "$v" =~ ^[0-9]+$ ]]; then
        MAX_WALL_SECONDS="$v"
      else
        log_warn "pro-config loop.max_wall_seconds='$v' is not numeric — ignoring (keeping ${MAX_WALL_SECONDS:-unlimited})"
      fi
    fi
  fi
  if [[ "${NO_PROGRESS_LIMIT_SET:-0}" -eq 0 ]]; then
    v=$(cfg_get loop no_progress_limit)
    if [[ -n "$v" ]]; then
      if [[ "$v" =~ ^[0-9]+$ ]]; then
        NO_PROGRESS_LIMIT="$v"
      else
        log_warn "pro-config loop.no_progress_limit='$v' is not numeric — ignoring (keeping ${NO_PROGRESS_LIMIT})"
      fi
    fi
  fi
}

# ─── Agent-definition resolution (P0#3 residual fix) ──────────────────────────
# The old hardcoded `.github/agents/...` path exists in NEITHER the dev repo NOR
# installed consumers (.extensionignore excludes .github/), so every headless
# run used to drive a missing file. Resolve across every layout we ship; first
# readable wins:
#   1. $SPECKIT_PRO_AGENTS_DIR                  (explicit operator/test override)
#   2. <script-dir>/../../agents                (installed extension AND dev repo)
#   3. $PROJECT_ROOT/.specify/extensions/pro/agents
#   4. $PROJECT_ROOT/agents
#   5. $PROJECT_ROOT/.github/agents             (legacy layout)
resolve_agent_file() {
  local name="$1" d
  for d in "${SPECKIT_PRO_AGENTS_DIR:-}" \
           "$SCRIPT_DIR/../../agents" \
           "$PROJECT_ROOT/.specify/extensions/pro/agents" \
           "$PROJECT_ROOT/agents" \
           "$PROJECT_ROOT/.github/agents"; do
    [[ -n "$d" && -r "$d/$name" ]] && { echo "$d/$name"; return 0; }
  done
  return 1
}

# ─── Per-call timeout (P1#7 — the single cheapest "survive the night" change) ─
# Prefer coreutils timeout/gtimeout; fall back to a pure-bash watchdog so macOS
# without coreutils is still covered. is_timeout_rc folds the bin's rc 124 and
# the fallback's TERM/KILL (143/137) into one timeout verdict.
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"

run_with_timeout() {
  local secs="$1"; shift
  if ! [[ "$secs" =~ ^[0-9]+$ ]] || [[ "$secs" -le 0 ]]; then
    "$@"; return $?
  fi
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$secs" "$@"; return $?
  fi
  # Pure-bash fallback: run in background, TERM after the deadline. The watcher
  # MUST be detached from stdout/stderr — callers run us inside $(...), and a
  # watcher (or its sleep child) holding the substitution pipe would block the
  # caller for the full deadline even after the command finished.
  # Orphan fix: killing a subshell does NOT kill its children, so the old
  # `( sleep N && kill ... ) &` left one stray full-deadline sleep behind every
  # time the command finished first. A TERM-trap watcher is NOT enough either:
  # when SIGTERM is ignored at shell entry (no-tty scheduler/CI harnesses —
  # empirically reproduced) the trap never fires and the parent hangs on
  # `wait watcher` for the whole deadline. So the watcher POLLS: it re-checks
  # the command every second and exits BY ITSELF within ≤1s of the command
  # finishing — no signal delivery required, nothing outlives the call beyond
  # one transient `sleep 1`.
  "$@" &
  local cmd_pid=$!
  (
    deadline=$(( $(date +%s) + secs ))
    while kill -0 "$cmd_pid" 2>/dev/null; do
      if [[ "$(date +%s)" -ge "$deadline" ]]; then
        kill -TERM "$cmd_pid" 2>/dev/null
        exit 0
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  local watcher=$! rc=0
  wait "$cmd_pid" || rc=$?
  kill "$watcher" 2>/dev/null || true   # best-effort fast reap; the poller self-exits ≤1s anyway
  wait "$watcher" 2>/dev/null || true
  return $rc
}

is_timeout_rc() { [[ "$1" -eq 124 || "$1" -eq 143 || "$1" -eq 137 ]]; }

json_escape() {
  # Minimal JSON string escaper: backslash + quote escaped, newlines/tabs → space.
  # Remaining control bytes 0x00-0x1F (e.g. ANSI ESC \x1b from agent-CLI stderr)
  # are STRIPPED — raw control characters are invalid inside a JSON string and
  # used to make json.loads reject notifications.jsonl lines / webhook payloads.
  # Order matters: \n \r \t are converted to spaces FIRST so they survive; the
  # delete range deliberately skips \011 \012 \015 (already gone by then).
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

truncate_chars() {
  # truncate_chars <n> — first line of stdin, truncated to <n> CHARACTERS.
  # `head -c` truncates BYTES and can split a multibyte UTF-8 sequence,
  # producing invalid UTF-8 inside JSON payloads. macOS/BSD awk (20200816)
  # substr() is byte-based too, so the portable character-safe primitive here
  # is bash's own ${var:0:n}, which counts characters under a UTF-8 locale on
  # both bash 3.2/macOS and bash 4+/Linux (verified with 'café — ümlaut').
  local n="$1" line=""
  IFS= read -r line || true   # no trailing newline still populates line
  printf '%s' "${line:0:n}"
}

# ─── Notifications (P1#17 — wires the long-documented notify.* config) ────────
# notify_event <event> <severity:error|warning|info> <detail>
# Every notable event is ALWAYS appended to .knowledge/metrics/notifications.jsonl
# (the 3am audit trail), webhook or not. When a webhook URL is configured AND the
# matching gate is on (failure events → notify.on_failure, info → notify.on_complete),
# the event is also POSTed as JSON with a Slack-compatible "text" field.
# Best-effort by contract: notification problems must never abort the loop.
notify_event() {
  local event="$1" severity="$2" detail="$3"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$NOTIFY_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","event":"%s","severity":"%s","feature":"%s","run_id":"%s","iteration":%s,"detail":"%s"}\n' \
    "$ts" "$(json_escape "$event")" "$severity" "$(json_escape "$FEATURE_NAME")" \
    "$(json_escape "${RUN_ID:-}")" "${CURRENT_ITERATION:-0}" "$(json_escape "$detail")" \
    >> "$NOTIFY_LOG" 2>/dev/null || true

  local url gate
  url="$WEBHOOK_URL"
  [[ -z "$url" ]] && url=$(cfg_get notify webhook_url)
  [[ -z "$url" ]] && return 0
  if [[ "$severity" == "info" ]]; then
    gate="${NOTIFY_ON_COMPLETE:-$(cfg_get notify on_complete)}"
  else
    gate="${NOTIFY_ON_FAILURE:-$(cfg_get notify on_failure)}"
  fi
  [[ "$gate" == "true" ]] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "notify: curl not found — webhook skipped (event logged in $NOTIFY_LOG)" >&2
    return 0
  fi
  local text payload
  text="[SpecKit Pro] ${event} — feature ${FEATURE_NAME} (iteration ${CURRENT_ITERATION:-0}): ${detail}"
  payload=$(printf '{"text":"%s","event":"%s","severity":"%s","feature":"%s","run_id":"%s","iteration":%s,"detail":"%s","ts":"%s"}' \
    "$(json_escape "$text")" "$(json_escape "$event")" "$severity" "$(json_escape "$FEATURE_NAME")" \
    "$(json_escape "${RUN_ID:-}")" "${CURRENT_ITERATION:-0}" "$(json_escape "$detail")" "$ts")
  curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
    -d "$payload" "$url" >/dev/null 2>&1 \
    || log_warn "notify: webhook POST failed (event '$event') — recorded in $NOTIFY_LOG" >&2
}

# ─── Per-iteration transcript (P1#8a — the missing 3am audit trail) ───────────
# write_iter_log <name> <signal> <exit> <stdout> <stderr>
write_iter_log() {
  local name="$1" signal="$2" exit_code="$3" out="$4" err="$5"
  [[ -d "$LOGS_DIR" ]] || mkdir -p "$LOGS_DIR" 2>/dev/null || return 0
  {
    echo "# $name — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# signal: $signal | exit: $exit_code | cli: ${RESOLVED_CLI_NAME:-?} | model: $MODEL"
    echo "## stdout"
    printf '%s\n' "$out"
    if [[ -n "$err" ]]; then
      echo "## stderr"
      printf '%s\n' "$err"
    fi
  } > "$LOGS_DIR/${name}.log" 2>/dev/null || true
}

# ─── File-based status contract (P1#8b) ───────────────────────────────────────
# The worker MAY write {"status":"CONTINUE","reason":"..."} to
# <spec-dir>/.pro-status.json (pro.loop.md instructs it to). A file is an
# unambiguous channel: it survives CLI cost-footers, mid-answer tag mentions and
# missing tags. When present and parseable it OVERRIDES the stdout scrape —
# except BUDGET_STOP, the CLI's own budget brake, which always wins.
read_status_file() {
  [[ -f "$STATUS_FILE" ]] || return 0
  local status reason
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
s = str(d.get("status", "")).strip()
r = str(d.get("reason", "") or "").strip().replace("\n", " ")
if not s:
    sys.exit(0)
print(s + (":" + r if r and s in ("BLOCKED", "ERROR") else ""))
' "$STATUS_FILE" 2>/dev/null
  else
    status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS_FILE" 2>/dev/null | head -1)
    reason=$(sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS_FILE" 2>/dev/null | head -1)
    case "$status" in
      BLOCKED|ERROR) [[ -n "$reason" ]] && status="$status:$reason" ;;
    esac
    printf '%s' "$status"
  fi
}

apply_status_file_override() {
  # apply_status_file_override <current-signal> — echoes the effective signal
  # and consumes (deletes) the status file. Diagnostics go to stderr: callers
  # capture stdout via $(...).
  local current="$1" file_signal
  file_signal=$(read_status_file)
  rm -f "$STATUS_FILE" 2>/dev/null || true
  if [[ -z "$file_signal" ]]; then
    printf '%s' "$current"
    return 0
  fi
  case "$file_signal" in
    COMPLETE|CONTINUE|MAX_ITERATIONS|BLOCKED|BLOCKED:*|ERROR|ERROR:*)
      if [[ "$current" == "BUDGET_STOP" ]]; then
        printf '%s' "$current"
      else
        [[ "$file_signal" != "$current" ]] \
          && log_info "Status-file contract: '$file_signal' (stdout scrape said '$current')" >&2
        printf '%s' "$file_signal"
      fi
      ;;
    *)
      log_warn "Status file holds unknown status '$file_signal' — ignoring" >&2
      printf '%s' "$current"
      ;;
  esac
}

# ─── Durable loop state (P1#15 — resume must not depend on prose regex) ───────
# write_loop_state <iteration> <consecutive_failures> <no_progress_streak> \
#                  <completed> <total> <status>
write_loop_state() {
  local tmp="$LOOP_STATE_FILE.tmp.$$"
  printf '{"iteration":%s,"consecutive_failures":%s,"no_progress_streak":%s,"completed":%s,"total":%s,"status":"%s","run_id":"%s","updated_at":"%s"}\n' \
    "${1:-0}" "${2:-0}" "${3:-0}" "${4:-0}" "${5:-0}" "$(json_escape "${6:-running}")" \
    "$(json_escape "${RUN_ID:-}")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$LOOP_STATE_FILE" 2>/dev/null || true
}

read_loop_state_field() {
  # read_loop_state_field <key> — echoes the (string or numeric) value, empty when absent.
  [[ -f "$LOOP_STATE_FILE" ]] || return 0
  local v
  v=$(sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LOOP_STATE_FILE" 2>/dev/null | head -1)
  [[ -z "$v" ]] && v=$(sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$LOOP_STATE_FILE" 2>/dev/null | head -1)
  printf '%s' "$v"
}

# ─── Single-orchestrator lock (P1#16) ─────────────────────────────────────────
# noclobber-atomic create; contents = "<pid> <iso-ts>". A dead-PID lock is stale
# and taken over with a warning; a live one aborts (unless --force-lock).
LOCK_ACQUIRED=0
acquire_lock() {
  local attempt holder_pid
  for attempt in 1 2; do
    if ( set -C; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE" ) 2>/dev/null; then
      LOCK_ACQUIRED=1
      return 0
    fi
    holder_pid=$(awk '{print $1; exit}' "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
      if [[ "$FORCE_LOCK" == "true" ]]; then
        log_warn "Lock held by live PID $holder_pid — stealing it (--force-lock)."
        rm -f "$LOCK_FILE" 2>/dev/null || true
        continue
      fi
      log_error "Another orchestrator (PID $holder_pid) holds $LOCK_FILE for feature '$FEATURE_NAME'."
      log_error "Concurrent loops interleave tasks.md/progress.md writes and double-commit."
      log_error "Stop the other run first, or pass --force-lock if it is a confirmed crash leftover."
      exit 1
    fi
    log_warn "Stale lock (PID ${holder_pid:-?} not running) — taking over."
    rm -f "$LOCK_FILE" 2>/dev/null || true
  done
  log_error "Could not acquire $LOCK_FILE even after stale-lock takeover — giving up."
  exit 1
}

release_lock() {
  if [[ "${LOCK_ACQUIRED:-0}" -eq 1 ]]; then
    # Ownership check (defect fix): after a --force-lock steal the ORIGINAL
    # holder still has LOCK_ACQUIRED=1, and its EXIT trap used to rm the lock
    # unconditionally — deleting the NEW holder's lock. Only remove when the
    # lock file's recorded PID is ours; every step is set -e/trap safe.
    local holder=""
    holder=$(awk '{print $1; exit}' "$LOCK_FILE" 2>/dev/null) || holder=""
    if [[ "$holder" == "$$" ]]; then
      rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
    LOCK_ACQUIRED=0
  fi
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
          [[ -z "$detail" ]] && detail=$(printf '%s' "$err" | tr '\n' ' ' | truncate_chars 200)
          [[ -z "$detail" ]] && detail="agent reported is_error"
          signal="ERROR:$detail"
        fi
      else
        # Scrape the control tag out of .result. Guard the pipeline: under
        # `set -euo pipefail` a no-match grep (rc 1) fails the $() assignment
        # and silently killed the orchestrator — the ERROR:no-status-tag path
        # below was unreachable dead code.
        signal=$(printf '%s' "$result" | grep -oE "<$tag>[^<]+</$tag>" | tail -1 | sed 's/<[^>]*>//g') || signal=""
        [[ -z "$signal" ]] && signal="ERROR:no-status-tag"
      fi
      PARSE_SIGNAL="$signal"
      return 0
    fi

    # JSON capable but unparseable/partial → ERROR (counts toward breaker).
    # Distinguish a hard non-zero exit (process crash) from malformed output.
    if [[ "${exit_code:-0}" -ne 0 ]]; then
      local crash
      crash=$(printf '%s' "$err" | tr '\n' ' ' | truncate_chars 200)
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
  # Pipeline guarded: a no-match grep must yield UNKNOWN, not a pipefail death.
  LAST_SOURCE="text-fallback"
  signal=$(printf '%s' "$out" | grep -oE "<$tag>[^<]+</$tag>" | tail -1 | sed 's/<[^>]*>//g') || signal=""
  if [[ -z "$signal" ]]; then
    if [[ "${exit_code:-0}" -ne 0 ]]; then
      local tdetail
      tdetail=$(printf '%s' "$err" | tr '\n' ' ' | truncate_chars 200)
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

  # Deferred-blocker journal (P1#17): when previous iterations hit BLOCKED, hand
  # the worker the journal so it picks a different independent work unit instead
  # of re-running into the same wall.
  if [[ -s "$BLOCKED_LOG" ]]; then
    prompt_args="$prompt_args blocked-log=$BLOCKED_LOG"
  fi

  local agent_output agent_err agent_exit=0
  local agentfile
  if ! agentfile=$(resolve_agent_file "speckit.pro.loop.agent.md"); then
    log_error "Loop agent definition 'speckit.pro.loop.agent.md' not found in any known layout (run --doctor for the search list)."
    AGENT_SIGNAL="ERROR:agent-definition-missing"
    return 0
  fi

  # Consume-before-call: a stale status file from a previous iteration must
  # never be read as this iteration's verdict.
  rm -f "$STATUS_FILE" 2>/dev/null || true

  # Invoke the agent — run speckit.pro.loop command.
  # Different CLIs have different invocation patterns. Only the claude branch is
  # capability-driven (flags + separate stdout/stderr + defensive JSON parse);
  # copilot/gemini/generic stay the existing agent-file invocation (FR-007) and
  # are routed through the text-fallback parse rung. EVERY branch runs under the
  # per-call timeout (P1#7) — one hung CLI must not freeze the overnight run.
  case "$resolved_cli" in
    copilot)
      agent_output=$(
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" agent --model "$MODEL" "$agentfile" "$prompt_args" 2>&1
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
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$prompt_args" 2>"$tmp_err"
      ) || agent_exit=$?
      agent_err=$(cat "$tmp_err" 2>/dev/null || echo "")
      rm -f "$tmp_err" 2>/dev/null || true
      ;;
    gemini)
      agent_output=$(
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" run --model "$MODEL" "$agentfile" "$prompt_args" 2>&1
      ) || agent_exit=$?
      agent_err=""
      ;;
    *)
      # Generic fallback — run with the agent file as first arg
      agent_output=$(
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" "$agentfile" "$prompt_args" 2>&1
      ) || agent_exit=$?
      agent_err=""
      ;;
  esac

  # Normalize to a control signal. A timeout maps straight to ERROR (counts
  # toward the circuit breaker); otherwise parse_agent_result sets PARSE_SIGNAL
  # and the LAST_* exports IN THIS SHELL (no $(...) — a command substitution
  # would discard the LAST_* metrics).
  if [[ "$ITERATION_TIMEOUT" =~ ^[0-9]+$ && "$ITERATION_TIMEOUT" -gt 0 ]] \
     && [[ "$agent_exit" -ne 0 ]] && is_timeout_rc "$agent_exit"; then
    LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
    LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE="timeout"
    AGENT_SIGNAL="ERROR:iteration-timeout-${ITERATION_TIMEOUT}s"
  else
    parse_agent_result "$resolved_cli" "$agent_output" "$agent_err" "$agent_exit" "pro-status"
    AGENT_SIGNAL="$PARSE_SIGNAL"
  fi

  # File contract (P1#8b) beats the stdout scrape; BUDGET_STOP always wins.
  AGENT_SIGNAL=$(apply_status_file_override "$AGENT_SIGNAL")

  # Persist the transcript (P1#8a) — the audit trail for "what happened at 3am".
  write_iter_log "iter-${iter}" "$AGENT_SIGNAL" "$agent_exit" "$agent_output" "$agent_err"
}

# ─── Evaluator Functions ─────────────────────────────────────────────────────

run_evaluator() {
  local sprint="$1" resolved_cli="$2" revision="${3:-1}"
  # Contract-path alignment (critique R12 / D9): point the evaluator at the SAME
  # path /pro.contract writes and the seal is verified against — the feature
  # knowledge dir, NOT $SPEC_DIR/contracts.
  local contract_path="$FEATURE_KNOWLEDGE_DIR/contracts/sprint-${sprint}.md"
  local eval_output eval_err eval_exit=0
  local agentfile
  if ! agentfile=$(resolve_agent_file "speckit.pro.evaluate.agent.md"); then
    log_error "Evaluator agent definition 'speckit.pro.evaluate.agent.md' not found in any known layout (run --doctor)."
    EVAL_SIGNAL="ERROR:agent-definition-missing"
    return 0
  fi

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
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" agent --model "$MODEL" "$agentfile" "$eval_args" 2>&1
      ) || eval_exit=$?
      eval_err=""
      ;;
    claude)
      # Evaluator role ⇒ read-only tool set; --model is the evaluator model.
      CLAUDE_FLAGS_MODEL="$eval_model"
      build_claude_flags "$agentfile" evaluator
      local tmp_err
      tmp_err=$(mktemp 2>/dev/null || echo "/tmp/pro-orch-eval-$$.err")
      eval_output=$(
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$eval_args" 2>"$tmp_err"
      ) || eval_exit=$?
      eval_err=$(cat "$tmp_err" 2>/dev/null || echo "")
      rm -f "$tmp_err" 2>/dev/null || true
      ;;
    *)
      eval_output=$(
        run_with_timeout "$ITERATION_TIMEOUT" \
          "$resolved_cli" "$agentfile" "$eval_args" 2>&1
      ) || eval_exit=$?
      eval_err=""
      ;;
  esac

  # Normalize via the shared defensive parser (timeout ⇒ explicit ERROR).
  # parse_agent_result sets PARSE_SIGNAL and LAST_* IN THIS SHELL (no $(...)).
  # The caller reads EVAL_SIGNAL.
  if [[ "$ITERATION_TIMEOUT" =~ ^[0-9]+$ && "$ITERATION_TIMEOUT" -gt 0 ]] \
     && [[ "$eval_exit" -ne 0 ]] && is_timeout_rc "$eval_exit"; then
    LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
    LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE="timeout"
    EVAL_SIGNAL="ERROR:evaluator-timeout-${ITERATION_TIMEOUT}s"
  else
    parse_agent_result "$resolved_cli" "$eval_output" "$eval_err" "$eval_exit" "pro-eval"
    EVAL_SIGNAL="$PARSE_SIGNAL"
  fi
  write_iter_log "iter-${sprint}-eval-r${revision}" "$EVAL_SIGNAL" "$eval_exit" "$eval_output" "$eval_err"
}

handle_eval_result() {
  local eval_tag="$1" sprint="$2" revision="$3"
  local verdict score_or_issues

  # ── Rubric-seal tamper (D9) ── A rubric-mutated/rubric-unsealed verdict means
  # the committed sprint contract seal failed to verify. This is a hard,
  # un-retryable failure: loud operator alarm, return 2 (no revision retry).
  if printf '%s' "$eval_tag" | grep -qiE 'rubric-mutated|rubric-unsealed|rubric-weakened'; then
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
      # Strict score validation (P1#9): a malformed score ("82/100", "eighty",
      # empty) must never be silently accepted — the old `2>/dev/null` on the
      # arithmetic test swallowed exactly that class and passed the sprint.
      if [[ ! "$score" =~ ^[0-9]{1,3}$ ]]; then
        log_warn "Evaluator PASS carries malformed score '$score' (want PASS:<0-100>) — requesting revision"
        return 1  # needs revision — never accept an ungradeable verdict
      fi
      log_success "Evaluator: PASS (score: ${score}%)"
      if [[ "$score" -lt "$EVAL_THRESHOLD" ]]; then
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
      # FR-011: an absent/unknown/ERROR verdict is an explicit failure outcome —
      # unverified code must never pass by default (the old behavior here was
      # "treating as PASS", which shipped whatever the evaluator failed to grade).
      log_error "Evaluator output invalid — verdict '$verdict' is not PASS/NEEDS_REVISION/FAIL"
      log_error "Treating as FAIL:evaluator-output-invalid (unverified code never passes by default)"
      [[ -f "$PRO_REPORT" ]] && bash "$PRO_REPORT" event decision "${RUN_ID:--}" \
        evaluator_verdict fail-invalid-verdict "verdict='${verdict}' tag='$(printf '%s' "$eval_tag" | truncate_chars 120)'" \
        >/dev/null 2>&1 || true
      update_session "evaluate" "invalid" "Sprint $sprint: evaluator output invalid ($eval_tag)"
      return 2  # hard fail — same handling as FAIL, with its own recorded reason
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
  local resolved_cli consecutive_failures=0 iteration=1 no_progress_streak=0
  # Session continuity (D5): first call omits --session-id; we capture the
  # CLI-minted session UUID and --resume it thereafter. RUN_COST_USD is the
  # cumulative per-run budget accumulator (declared at file scope, reset here).
  SESSION_ID=""
  RUN_COST_USD=0

  # Resolve the agent CLI
  resolved_cli=$(detect_agent_cli)
  RESOLVED_CLI_NAME="$resolved_cli"

  # Single-orchestrator guard (P1#16): two loops on the same feature interleave
  # tasks.md/progress.md writes and double-commit. Must precede any file writes.
  acquire_lock

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

  # Determine starting iteration (resume mode). Orchestrator-owned state
  # (loop-state.json, P1#15) is authoritative; the progress.md label regex is
  # the legacy fallback for runs that predate the state file.
  if [[ "$RESUME" == "true" ]]; then
    local last_iter
    last_iter=$(read_loop_state_field iteration)
    if [[ "$last_iter" =~ ^[0-9]+$ && "$last_iter" -gt 0 ]]; then
      iteration=$(( last_iter + 1 ))
      log_info "Resuming from iteration $iteration (loop-state.json: last completed $last_iter)"
    elif [[ -f "$PROGRESS_FILE" ]]; then
      # checkpoint_commit persists labels like `iter3` / `circuit-breaker-iter5` to
      # PROGRESS_FILE (the "Loop Iteration N" banner is stdout-only), so resume must
      # read the label form that is actually written, not the banner text.
      last_iter=$(grep -oE 'iter[0-9]+' "$PROGRESS_FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1) || last_iter=""
      last_iter=${last_iter:-0}
      if [[ "$last_iter" -gt 0 ]]; then
        iteration=$(( last_iter + 1 ))
        log_info "Resuming from iteration $iteration (progress.md fallback: previous $last_iter)"
      fi
    fi
  fi

  # Relative iteration budget (P1#15): MAX_ITERATIONS bounds THIS run's
  # iterations. Resuming at iteration 13 with a budget of 8 runs 13..20 — the
  # old absolute comparison made exactly that resume a silent no-op.
  local start_iteration="$iteration"
  local wall_start
  wall_start=$(date +%s)

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
  while (( iteration - start_iteration < MAX_ITERATIONS )); do
    CURRENT_ITERATION="$iteration"

    # Pre-iteration: check if done
    if all_tasks_done; then
      break
    fi

    # ── Wall-clock budget (P1#7) — bound the whole run, not just each call ──
    if [[ "$MAX_WALL_SECONDS" =~ ^[0-9]+$ && "$MAX_WALL_SECONDS" -gt 0 ]]; then
      local wall_elapsed=$(( $(date +%s) - wall_start ))
      if (( wall_elapsed >= MAX_WALL_SECONDS )); then
        log_warn "Wall-clock budget (${MAX_WALL_SECONDS}s) reached after ${wall_elapsed}s — stopping (clean checkpoint)."
        read -r completed total <<< "$(count_tasks)"
        checkpoint_commit "stopped-wall-clock-iter${iteration}" "$completed" "$total"
        update_session "implement" "stopped_wall_clock" "Wall-clock budget ${MAX_WALL_SECONDS}s reached at iteration $iteration"
        write_loop_state "$(( iteration - 1 ))" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "stopped_wall_clock"
        notify_event wall_clock_stop warning "Wall-clock budget ${MAX_WALL_SECONDS}s reached at iteration $iteration (${completed}/${total} tasks)"
        exit 0
      fi
    fi

    local counts completed total
    read -r completed total <<< "$(count_tasks)"

    banner "implement" "$iteration" "$(( iteration - start_iteration + 1 ))" "$completed" "$total"
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
      write_loop_state "$(( iteration - 1 ))" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "stopped_budget"
      notify_event budget_stop warning "Cumulative budget cap ${MAX_BUDGET_USD} USD reached at iteration $iteration (${completed}/${total} tasks)"
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
      write_loop_state "$(( iteration - 1 ))" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "stopped_budget"
      notify_event budget_stop warning "CLI reported budget stop at iteration $iteration (~${RUN_COST_USD}/${MAX_BUDGET_USD} USD)"
      exit 0
    fi

    # ── Evaluator cycle (if enabled) ───────────────────────────────────────
    if [[ "$ENABLE_EVALUATOR" == true ]] && [[ "$agent_status" != "COMPLETE" ]] && [[ "$agent_status" != "ERROR:"* ]]; then
      local revision=1 eval_result
      while [[ "$revision" -le "$MAX_REVISIONS" ]]; do
        local eval_tag
        report_phase start evaluate
        run_evaluator "$iteration" "$resolved_cli" "$revision"
        eval_tag="$EVAL_SIGNAL"
        log_info "Evaluator tag: $eval_tag"
        # Telemetry hand-off for the evaluator call (best-effort).
        report_call evaluate "$eval_tag"
        report_phase stop evaluate "$eval_tag"

        # set -e guard: handle_eval_result returns 1 (revision) / 2 (hard fail)
        # as data, not as failure — a bare call would kill the orchestrator the
        # moment the evaluator asked for a revision.
        eval_result=0
        handle_eval_result "$eval_tag" "$iteration" "$revision" || eval_result=$?

        if [[ "$eval_result" -eq 0 ]]; then
          break  # Evaluator passed
        elif [[ "$eval_result" -eq 2 ]]; then
          # Hard fail (incl. rubric tamper) — circuit breaker, un-retryable.
          read -r completed total <<< "$(count_tasks)"
          checkpoint_commit "eval-fail-sprint${iteration}" "$completed" "$total"
          write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "eval_failed"
          notify_event eval_hard_fail error "Sprint $iteration failed evaluation: $(printf '%s' "$eval_tag" | truncate_chars 160)"
          report_call evaluate "$eval_tag" --cb-trip
          exit 1
        fi

        # NEEDS_REVISION — give generator another pass
        revision=$(( revision + 1 ))
        if [[ "$revision" -le "$MAX_REVISIONS" ]]; then
          log_info "Generator revision $revision/$MAX_REVISIONS..."
          local rev_args rev_output rev_err rev_exit=0
          local rev_agentfile
          if ! rev_agentfile=$(resolve_agent_file "speckit.pro.loop.agent.md"); then
            log_error "Loop agent definition missing for revision pass — skipping revision."
            continue
          fi
          rev_args="feature=$FEATURE_NAME tasks=$TASKS_PATH spec-dir=$SPEC_DIR"
          rev_args="$rev_args iteration=$iteration max=$MAX_ITERATIONS"
          # Read evaluator feedback from where the evaluator agent actually writes it
          # (FEATURE_KNOWLEDGE_DIR/evaluations — the only evaluations dir created at
          # L119), not SPEC_DIR/evaluations which never exists (revision-loop path fix).
          rev_args="$rev_args revision=$revision eval-feedback=$FEATURE_KNOWLEDGE_DIR/evaluations/sprint-${iteration}.md"
          # Run generator revision inline (brief pass — fix evaluator issues only).
          # Output is CAPTURED and logged on every branch — the old copilot/generic
          # branches discarded it (&>/dev/null), leaving the revision invisible.
          report_phase start revision
          case "$resolved_cli" in
            copilot)
              rev_output=$(
                run_with_timeout "$ITERATION_TIMEOUT" \
                  "$resolved_cli" agent --model "$MODEL" "$rev_agentfile" "$rev_args" 2>&1
              ) || rev_exit=$?
              rev_err=""
              ;;
            claude)
              # Capability-driven revision pass — separate stdout/stderr + parse.
              CLAUDE_FLAGS_MODEL="$MODEL"
              build_claude_flags "$rev_agentfile" revision
              local rev_tmp_err
              rev_tmp_err=$(mktemp 2>/dev/null || echo "/tmp/pro-orch-rev-$$.err")
              rev_output=$(
                run_with_timeout "$ITERATION_TIMEOUT" \
                  "$resolved_cli" "${CLAUDE_FLAGS[@]}" "$rev_args" 2>"$rev_tmp_err"
              ) || rev_exit=$?
              rev_err=$(cat "$rev_tmp_err" 2>/dev/null || echo "")
              rm -f "$rev_tmp_err" 2>/dev/null || true
              ;;
            *)
              rev_output=$(
                run_with_timeout "$ITERATION_TIMEOUT" \
                  "$resolved_cli" "$rev_agentfile" "$rev_args" 2>&1
              ) || rev_exit=$?
              rev_err=""
              ;;
          esac
          # Parse revision result, thread session, accumulate cost, hand off
          # the rework telemetry call (best-effort).
          parse_agent_result "$resolved_cli" "$rev_output" "$rev_err" "$rev_exit" "pro-status"
          log_info "Revision status: $PARSE_SIGNAL"
          write_iter_log "iter-${iteration}-rev-${revision}" "$PARSE_SIGNAL" "$rev_exit" "$rev_output" "$rev_err"
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
      MAX_ITERATIONS)
        # The worker's own documented safety tag (pro.loop.md) — it used to fall
        # into the unknown bucket and was "treated as CONTINUE".
        log_warn "Agent reports MAX_ITERATIONS — honoring its stop request."
        read -r completed total <<< "$(count_tasks)"
        checkpoint_commit "agent-max-iterations-iter${iteration}" "$completed" "$total"
        update_session "implement" "paused" "Agent emitted MAX_ITERATIONS at iteration $iteration"
        break
        ;;
      BLOCKED:*|BLOCKED)
        local reason="${agent_status#BLOCKED}"
        reason="${reason#:}"
        [[ -z "$reason" ]] && reason="(no reason given)"
        log_warn "Task blocked: $reason"
        # Deferred-blocker journal (P1#17): record the wall — the NEXT
        # iteration's prompt carries blocked-log=<path> so the worker picks a
        # different independent work unit instead of re-hitting it.
        echo "- iteration $iteration ($(date -u +%Y-%m-%dT%H:%M:%SZ)): $reason" >> "$BLOCKED_LOG" 2>/dev/null || true
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: $consecutive_failures consecutive blocks"
          read -r completed total <<< "$(count_tasks)"
          update_session "implement" "blocked" "Circuit breaker triggered: $reason"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "circuit_breaker"
          notify_event circuit_breaker error "3 consecutive BLOCKED — last: $reason (${completed}/${total} tasks)"
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
          write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "circuit_breaker"
          notify_event circuit_breaker error "3 consecutive errors — last: $(printf '%s' "$err_msg" | truncate_chars 160)"
          # cb-trip marker (no metric flags — the call's metrics were already sent).
          LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
          LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
          report_call implement "$agent_status" --cb-trip
          exit 1
        fi
        log_warn "Retrying... ($consecutive_failures/3 failures)"
        ;;
      *)
        # P1#6: UNKNOWN counts toward the breaker. A crashed CLI, expired auth
        # or rate-limit returns no tag at all — the old "treating as CONTINUE"
        # (plus a failure-counter reset) defanged the breaker exactly when it
        # was needed most.
        log_warn "Unknown generator status: '$agent_status' — counting toward circuit breaker"
        consecutive_failures=$(( consecutive_failures + 1 ))
        if [[ "$consecutive_failures" -ge 3 ]]; then
          log_error "Circuit breaker: $consecutive_failures consecutive unparseable statuses"
          read -r completed total <<< "$(count_tasks)"
          update_session "implement" "failed" "Circuit breaker: $consecutive_failures consecutive unknown statuses"
          checkpoint_commit "circuit-breaker-iter${iteration}" "$completed" "$total"
          write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$completed" "$total" "circuit_breaker"
          notify_event circuit_breaker error "3 consecutive unknown statuses — last: '$(printf '%s' "$agent_status" | truncate_chars 120)'"
          LAST_COST="" LAST_IN_TOK="" LAST_OUT_TOK="" LAST_CACHE_R="" LAST_CACHE_C=""
          LAST_TURNS="" LAST_DUR_MS="" LAST_SESSION_ID="" LAST_SOURCE=""
          report_call implement "$agent_status" --cb-trip
          exit 1
        fi
        log_warn "Retrying... ($consecutive_failures/3 failures)"
        ;;
    esac

    # ── No-progress watchdog (P1#6) ── the checkbox delta is the one progress
    # signal the agent can't get wrong by accident. CONTINUE/unknown statuses
    # with no new [x] for NO_PROGRESS_LIMIT consecutive iterations stop the run
    # with a diagnostic instead of burning the whole budget doing nothing.
    local post_completed post_total
    read -r post_completed post_total <<< "$(count_tasks)"
    if [[ "$NO_PROGRESS_LIMIT" =~ ^[0-9]+$ && "$NO_PROGRESS_LIMIT" -gt 0 ]]; then
      if (( post_completed > completed )); then
        no_progress_streak=0
      else
        no_progress_streak=$(( no_progress_streak + 1 ))
        if (( no_progress_streak >= NO_PROGRESS_LIMIT )); then
          log_error "Watchdog: no task completed in $no_progress_streak consecutive iterations (stuck at ${post_completed}/${post_total})."
          log_error "The loop is burning iterations without checkbox progress — stopping for operator review."
          log_error "Transcripts: $LOGS_DIR/iter-*.log"
          checkpoint_commit "watchdog-no-progress-iter${iteration}" "$post_completed" "$post_total"
          update_session "implement" "watchdog_stop" "No checkbox progress for $no_progress_streak iterations"
          write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$post_completed" "$post_total" "watchdog_stop"
          notify_event watchdog_no_progress error "No task progress for $no_progress_streak iterations (stuck at ${post_completed}/${post_total} tasks)"
          [[ -n "$RUN_ID" && -f "$PRO_REPORT" ]] && bash "$PRO_REPORT" event decision "$RUN_ID" \
            watchdog stop "no checkbox progress for $no_progress_streak iterations" >/dev/null 2>&1 || true
          exit 1
        fi
      fi
    fi

    # Durable per-iteration state (P1#15) — what resume and post-mortems read.
    write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$post_completed" "$post_total" "running"

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
    write_loop_state "$iteration" "$consecutive_failures" "$no_progress_streak" "$final_completed" "$final_total" "completed"
    notify_event run_complete info "All $final_total tasks complete in $((iteration - 1)) iterations"
    echo ""
    log_info "Next (chat pipeline): run pro.go Phase 7 in the agent —"
    log_info "  /speckit.pro.reconcile → /speckit.pro.local-review → /speckit.pro.evaluate → /speckit.pro.knowledge-sync (sync on PASS)"
    log_info "Hooks may also fire this chain on native /speckit.implement; /pro.go must not rely on hooks alone."
    exit 0
  else
    local remaining=$(( final_total - final_completed ))
    echo ""
    log_warn "Maximum iterations ($MAX_ITERATIONS this run) reached. $remaining tasks remain."
    print_progress_bar "$final_completed" "$final_total"
    log_info "Resume with: /speckit.pro.resume"
    log_info "Check status: /speckit.pro.status"

    checkpoint_commit "max-iterations-reached" "$final_completed" "$final_total"
    update_session "implement" "paused" "$remaining tasks remain after max iterations"
    write_loop_state "$(( iteration - 1 ))" "$consecutive_failures" "$no_progress_streak" "$final_completed" "$final_total" "paused"
    notify_event max_iterations warning "$remaining tasks remain after $MAX_ITERATIONS iterations this run"
    exit 1
  fi
}

# ─── Doctor mode (P1#13) ──────────────────────────────────────────────────────
# Prints resolved configuration + environment diagnosis and exits 0. Run it
# before an overnight run: it answers "will this even start?" without burning
# a single token.
run_doctor() {
  local cli="" ver="" caps="" p f ok=0
  echo ""
  echo "SpecKit Pro — orchestrator doctor"
  echo "─────────────────────────────────────────────"
  if cli=$(detect_agent_cli 2>/dev/null); then
    ver=$("$cli" --version 2>/dev/null | head -1) || ver=""
    caps=$(cli_capabilities "$cli")
    echo "agent CLI         : $cli${ver:+ ($ver)}"
    echo "capabilities      : ${caps:-(none — pure agent-file invocation)}"
  else
    echo "agent CLI         : NOT FOUND — install one of: copilot, claude, gemini, codex"
    ok=1
  fi
  for f in speckit.pro.loop.agent.md speckit.pro.evaluate.agent.md; do
    if p=$(resolve_agent_file "$f"); then
      echo "agent definition  : $f → $p"
    else
      echo "agent definition  : $f → MISSING (searched: \$SPECKIT_PRO_AGENTS_DIR, $SCRIPT_DIR/../../agents, .specify/extensions/pro/agents, agents/, .github/agents)"
      ok=1
    fi
  done
  echo "timeout binary    : ${TIMEOUT_BIN:-(none — pure-bash watchdog fallback)}"
  echo "python3           : $(command -v python3 >/dev/null 2>&1 && echo present || echo 'MISSING (JSON parse + status file degrade to sed)')"
  echo "curl              : $(command -v curl >/dev/null 2>&1 && echo present || echo 'missing (webhooks disabled)')"
  if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "git               : repo at $PROJECT_ROOT (branch $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo '?'), $(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ') dirty paths)"
  else
    echo "git               : NOT a repository — checkpoints will be skipped"
  fi
  local cfg found_cfg=""
  for cfg in "$PROJECT_ROOT/.specify/extensions/pro/pro-config.local.yml" \
             "$PROJECT_ROOT/.specify/extensions/pro/pro-config.yml" \
             "$PROJECT_ROOT/pro-config.yml"; do
    [[ -f "$cfg" ]] && found_cfg="$found_cfg $cfg"
  done
  echo "config files      :${found_cfg:- (none — built-in defaults only)}"
  echo ""
  echo "resolved knobs (flag > env > config > default)"
  echo "  max_iterations      = $MAX_ITERATIONS"
  echo "  checkpoint_frequency= $CHECKPOINT_FREQUENCY"
  echo "  model               = $MODEL"
  echo "  agent_cli           = $AGENT_CLI"
  echo "  iteration_timeout   = ${ITERATION_TIMEOUT}s"
  echo "  max_wall_seconds    = ${MAX_WALL_SECONDS:-unlimited}"
  echo "  no_progress_limit   = $NO_PROGRESS_LIMIT"
  echo "  max_budget_usd      = ${MAX_BUDGET_USD:-unlimited}"
  echo "  evaluator           = $ENABLE_EVALUATOR (threshold $EVAL_THRESHOLD, max revisions $MAX_REVISIONS)"
  local wh
  wh="$WEBHOOK_URL"; [[ -z "$wh" ]] && wh=$(cfg_get notify webhook_url)
  if [[ -n "$wh" ]]; then
    echo "  webhook             = configured (${wh%%\?*} — on_failure=${NOTIFY_ON_FAILURE:-$(cfg_get notify on_failure)}, on_complete=${NOTIFY_ON_COMPLETE:-$(cfg_get notify on_complete)})"
  else
    echo "  webhook             = not configured (events still logged to .knowledge/metrics/notifications.jsonl)"
  fi
  local envs
  envs=$(env | grep '^SPECKIT_PRO_' | cut -d= -f1 | tr '\n' ' ') || envs=""
  echo "  env overrides       : ${envs:-(none)}"
  if [[ -n "$FEATURE_NAME" ]]; then
    echo ""
    echo "feature checks ($FEATURE_NAME)"
    echo "  tasks.md            : $([[ -f "$TASKS_PATH" ]] && echo "$TASKS_PATH" || echo "MISSING ($TASKS_PATH)")"
    echo "  knowledge dir       : $FEATURE_KNOWLEDGE_DIR"
    echo "  lock                : $([[ -f "$LOCK_FILE" ]] && echo "HELD ($(cat "$LOCK_FILE" 2>/dev/null | head -1))" || echo free)"
    echo "  loop-state          : $([[ -f "$LOOP_STATE_FILE" ]] && cat "$LOOP_STATE_FILE" || echo none)"
  fi
  echo ""
  if [[ "$ok" -eq 0 ]]; then
    echo "verdict: READY"
  else
    echo "verdict: NOT READY — fix the MISSING items above before an unattended run"
  fi
  return 0
}

# ─── Traps: clean exit on Ctrl+C, SIGTERM, and any exit path ──────────────────
# Close a self-stamped run on ANY exit (success, failure, circuit-breaker, budget,
# or Ctrl-C) so the terminal path always produces a run-report + runs.jsonl line.
# Runs at most once; no-op when --run-id was supplied (the caller owns finish then).
finish_self_stamped() {
  [[ "${SELF_STAMPED:-0}" -eq 1 && -f "$PRO_REPORT" ]] || return 0
  SELF_STAMPED=0
  bash "$PRO_REPORT" finish --feature "$FEATURE_NAME" --run-id "$RUN_ID" \
    --max-iterations "$MAX_ITERATIONS" --progress-file "$PROGRESS_FILE" \
    --no-stdout >/dev/null 2>&1 || true
}

on_exit() {
  finish_self_stamped
  release_lock
}

on_term() {
  # SIGTERM (kill, systemd stop, CI cancel) — leave a final session entry +
  # notification instead of vanishing without a trace (P1#14).
  echo ""
  log_warn "SIGTERM received — recording final state. Run /speckit.pro.resume to continue."
  update_session "implement" "terminated" "SIGTERM at iteration ${CURRENT_ITERATION:-?}" 2>/dev/null || true
  notify_event terminated error "SIGTERM at iteration ${CURRENT_ITERATION:-?}" 2>/dev/null || true
  exit 143
}

trap on_exit EXIT
trap on_term TERM
trap 'echo ""; log_warn "Interrupted by user. Run /speckit.pro.resume to continue."; exit 130' INT

# Fill flag/env gaps in the loop knobs from pro-config (flag > env > config >
# default). Must run after arg parsing + PROJECT_ROOT derivation and before
# doctor/main consume the values.
resolve_loop_knobs

if [[ "$DOCTOR" == "true" ]]; then
  run_doctor
  exit 0
fi

main "$@"
