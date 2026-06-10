#!/usr/bin/env bash
# =============================================================================
# pro-local-prep.sh — Run local Ollama workers to generate prep artifacts
#
# Inputs:  <SPEC_DIR>/spec.md, plan.md, tasks.md (+ optional .knowledge)
# Outputs: <SPEC_DIR>/{repo-map.md, context-pack.md, risk-register.md,
#                       test-strategy.md, open-questions.md}
#
# This is OPTIONAL augmentation. If local_models.enabled is false or Ollama
# is unreachable, the script prints a clear message and exits 0 — the
# parent pipeline must not abort because the local sidecar isn't running.
#
# Usage:
#   pro-local-prep.sh --spec-dir <path> [--only repo-map,context-pack,...]
#                     [--force] [--dry-run]
# =============================================================================

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/pro-local-common.sh
source "$SCRIPT_DIR/lib/pro-local-common.sh"

# ── Structured skip events (FR-004, audit B1) ────────────────────────────────
# Every self-skip/degradation emits one structured event so the run report can
# tell "disabled by config" from "sidecar down" from "driver error". Run-id "-"
# auto-resolves via the .current pointer (or spools pre-run). Best-effort:
# never fails, never adds noise.
# Usage: prep_skip_event <reason_class> <detail>
#        reason_class: disabled-by-config | environment-unavailable | error
prep_skip_event() {
  bash "$SCRIPT_DIR/pro-report.sh" event skip "-" local-prep "4b" "$1" "$2" \
    >/dev/null 2>&1 || true
}

# ── Args ─────────────────────────────────────────────────────────────────────
SPEC_DIR=""
ONLY=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-dir)  SPEC_DIR="$2"; shift 2 ;;
    --only)      ONLY="$2"; shift 2 ;;
    --force)     FORCE=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *)
      local_err "unknown arg: $1"; exit 1 ;;
  esac
done

PROJECT_ROOT="$(local_project_root)"

# Auto-detect spec dir from .specify/scripts/bash/check-prerequisites.sh if available
if [[ -z "$SPEC_DIR" ]]; then
  if [[ -x "$PROJECT_ROOT/.specify/scripts/bash/check-prerequisites.sh" ]]; then
    json="$("$PROJECT_ROOT/.specify/scripts/bash/check-prerequisites.sh" --json 2>/dev/null || true)"
    SPEC_DIR="$(python3 -c '
import json, sys
try:
  d = json.loads(sys.stdin.read() or "{}")
  print(d.get("FEATURE_DIR") or d.get("SPEC_DIR") or "")
except Exception:
  print("")
' <<<"$json")"
  fi
fi

if [[ -z "$SPEC_DIR" ]]; then
  # Fall back: most-recently modified spec.md under specs/
  SPEC_DIR="$(find "$PROJECT_ROOT/specs" -maxdepth 2 -name spec.md -type f 2>/dev/null \
    | xargs -I{} dirname {} 2>/dev/null \
    | xargs -I{} ls -dt {} 2>/dev/null \
    | head -n1)"
fi

if [[ -z "$SPEC_DIR" || ! -d "$SPEC_DIR" ]]; then
  local_err "could not determine SPEC_DIR. Pass --spec-dir <path>."
  exit 1
fi

# ── Load config + check Ollama ───────────────────────────────────────────────
local_load_config "$PROJECT_ROOT"
LOCAL_FEATURE="$(local_feature_from_spec_dir "$SPEC_DIR")"

if [[ "$LOCAL_ENABLED" != "true" ]]; then
  local_log "local prep is disabled by config — skipping (this is opt-in, not an error)."
  local_log "  Config: $LOCAL_CONFIG_PATH"
  local_log "  set local_models.enabled: true to use"
  if [[ "$LOCAL_CONFIG_PATH" == "$LOCAL_EXTENSION_ROOT/pro-config.template.yml" ]]; then
    prep_skip_event disabled-by-config "no pro-config found; local_models defaulting off"
  else
    prep_skip_event disabled-by-config "local_models.enabled=false in $(basename "$LOCAL_CONFIG_PATH")"
  fi
  exit 0
fi

if ! local_check_reachable; then
  local_warn "Ollama not reachable at $LOCAL_BASE_URL — skipping local prep (config enables it, but the sidecar is down)."
  local_warn "  Check the endpoint:  curl $LOCAL_BASE_URL/api/tags  (is base_url right? is the model pulled?)"
  local_warn "  Start it:            ollama serve"
  local_emit_skip pro-local-prep ollama-unreachable "{\"base_url\":\"$LOCAL_BASE_URL\"}"
  prep_skip_event environment-unavailable "Ollama unreachable at $LOCAL_BASE_URL"
  exit 0
fi

# ── Gather inputs ────────────────────────────────────────────────────────────
SPEC_MD="$SPEC_DIR/spec.md"
PLAN_MD="$SPEC_DIR/plan.md"
TASKS_MD="$SPEC_DIR/tasks.md"

if [[ ! -f "$SPEC_MD" ]]; then
  local_err "missing $SPEC_MD — run /speckit.specify first."
  exit 1
fi

REPO_KNOWLEDGE_INDEX=""
[[ -f "$PROJECT_ROOT/.knowledge/INDEX.md" ]] && REPO_KNOWLEDGE_INDEX="$PROJECT_ROOT/.knowledge/INDEX.md"

# Generate a shallow file-tree snapshot for grounding repo-map.md.
TREE_SNAPSHOT="$(mktemp -t pro-tree.XXXXXX).md"
{
  echo "# repo-tree (depth 3, code-bearing dirs)"
  echo
  # Best-effort: prefer git ls-files if in repo, otherwise find with sensible ignores
  if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" ls-files | awk -F/ 'NF<=4' | sort | head -n 500
  else
    ( cd "$PROJECT_ROOT" && find . -maxdepth 4 -type f \
        -not -path './.git/*' -not -path './node_modules/*' \
        -not -path './.venv/*' -not -path './dist/*' -not -path './build/*' \
        | sort | head -n 500 )
  fi
} > "$TREE_SNAPSHOT"

trap 'rm -f "$TREE_SNAPSHOT"' EXIT

# ── Task runner ──────────────────────────────────────────────────────────────
should_run() {
  local task="$1"
  if [[ -z "$ONLY" ]]; then
    return 0
  fi
  [[ ",$ONLY," == *",$task,"* ]]
}

run_one() {
  local task="$1" out="$2"; shift 2
  local prompt="$LOCAL_TEMPLATES_DIR/$task.prompt.md"
  local model
  model="$(local_model_for_task "$task")"

  if [[ -f "$out" && "$FORCE" != "true" ]]; then
    local_log "$(printf "%-22s → %s  (exists, skip — pass --force to regenerate)" "$task" "$(basename "$out")")"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local_log "$(printf "DRY  %-22s → %s  [model=%s]" "$task" "$out" "$model")"
    return 0
  fi

  local_log "$(printf "%-22s → %s  [model=%s]" "$task" "$(basename "$out")" "$model")"
  ATTEMPTS=$((ATTEMPTS + 1))
  if local_run_task "$task" "$prompt" "$out" "$@"; then
    local_ok "wrote $(basename "$out")"
    return 0
  else
    local rc=$?
    local_warn "$task failed (exit $rc) — continuing with remaining artifacts."
    return "$rc"
  fi
}

# ── Run prep stages ──────────────────────────────────────────────────────────
local_print_summary "local-prep" \
  "Spec dir : $SPEC_DIR" \
  "Config   : $LOCAL_CONFIG_PATH" \
  "Base URL : $LOCAL_BASE_URL" \
  "Models   : default=$LOCAL_MODEL_DEFAULT  code=$LOCAL_MODEL_CODE  fast=$LOCAL_MODEL_FAST"

FAILURES=0
ATTEMPTS=0

# Stage 1: repo-map.md (needed by later stages; produce first)
if should_run repo-map; then
  if [[ -n "$REPO_KNOWLEDGE_INDEX" ]]; then
    run_one repo-map "$SPEC_DIR/repo-map.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" "$TREE_SNAPSHOT" "$REPO_KNOWLEDGE_INDEX" || ((FAILURES++))
  else
    run_one repo-map "$SPEC_DIR/repo-map.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" "$TREE_SNAPSHOT" || ((FAILURES++))
  fi
fi

REPO_MAP_OUT="$SPEC_DIR/repo-map.md"
HAS_REPO_MAP=false
[[ -s "$REPO_MAP_OUT" ]] && HAS_REPO_MAP=true

# Stage 2: risk-register.md, test-strategy.md, open-questions.md (parallel-safe but run serial for low concurrency)
if should_run risk-register; then
  if $HAS_REPO_MAP; then
    run_one risk-register "$SPEC_DIR/risk-register.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" "$REPO_MAP_OUT" || ((FAILURES++))
  else
    run_one risk-register "$SPEC_DIR/risk-register.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" || ((FAILURES++))
  fi
fi

if should_run test-strategy; then
  if $HAS_REPO_MAP; then
    run_one test-strategy "$SPEC_DIR/test-strategy.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" "$REPO_MAP_OUT" || ((FAILURES++))
  else
    run_one test-strategy "$SPEC_DIR/test-strategy.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" || ((FAILURES++))
  fi
fi

if should_run open-questions; then
  if $HAS_REPO_MAP; then
    run_one open-questions "$SPEC_DIR/open-questions.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" "$REPO_MAP_OUT" || ((FAILURES++))
  else
    run_one open-questions "$SPEC_DIR/open-questions.md" "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" || ((FAILURES++))
  fi
fi

# Stage 3: context-pack.md (compiles other artifacts; run LAST)
if should_run context-pack; then
  ctx_args=( "$SPEC_MD" "$PLAN_MD" "$TASKS_MD" )
  $HAS_REPO_MAP && ctx_args+=( "$REPO_MAP_OUT" )
  [[ -s "$SPEC_DIR/risk-register.md" ]] && ctx_args+=( "$SPEC_DIR/risk-register.md" )
  [[ -s "$SPEC_DIR/test-strategy.md" ]] && ctx_args+=( "$SPEC_DIR/test-strategy.md" )
  [[ -n "$REPO_KNOWLEDGE_INDEX" ]] && ctx_args+=( "$REPO_KNOWLEDGE_INDEX" )
  run_one context-pack "$SPEC_DIR/context-pack.md" "${ctx_args[@]}" || ((FAILURES++))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
if (( FAILURES == 0 )); then
  local_ok "local-prep complete — wrote artifacts to $SPEC_DIR"
  exit 0
else
  local_warn "local-prep finished with $FAILURES failure(s) — see warnings above."
  # FR-004: ONE aggregated event for per-artifact failures, with the right
  # reason class. All prep tasks route to LOCAL_MODEL_DEFAULT, so if that
  # model isn't pulled (the HTTP 404 case ollama-md.py logs), this is an
  # environment problem — not a driver bug.
  if ! local_model_present "$LOCAL_MODEL_DEFAULT"; then
    prep_skip_event environment-unavailable "model '$LOCAL_MODEL_DEFAULT' not found at $LOCAL_BASE_URL — $FAILURES of $ATTEMPTS prep artifacts failed (pull it: ollama pull $LOCAL_MODEL_DEFAULT)"
  else
    prep_skip_event error "$FAILURES of $ATTEMPTS prep artifacts failed (see warnings)"
  fi
  # Still exit 0: this is augmentation, not a blocker.
  exit 0
fi
