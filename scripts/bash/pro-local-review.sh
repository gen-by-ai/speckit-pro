#!/usr/bin/env bash
# =============================================================================
# pro-local-review.sh — Run local Ollama workers to do first-pass review
#
# Reads the working diff + selected artifacts and writes:
#   <SPEC_DIR>/local-reviews/implementation-review.md
#   <SPEC_DIR>/local-reviews/test-gap-review.md
#   <SPEC_DIR>/local-reviews/security-review.md
#
# These are first-pass screens. The stronger evaluator (Claude / pro.evaluate)
# reads them and verifies — it is NOT bound by what the local model said.
#
# Usage:
#   pro-local-review.sh --spec-dir <path>
#                       [--base-ref <git-ref>]   # default: HEAD~1
#                       [--only implementation-review,test-gap-review,security-review]
#                       [--force] [--dry-run]
# =============================================================================

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/pro-local-common.sh
source "$SCRIPT_DIR/lib/pro-local-common.sh"

# ── Structured skip events (FR-004) ──────────────────────────────────────────
# Every self-skip/degradation emits one structured event so the run report can
# tell "disabled by config" from "sidecar down" from "review error". Run-id "-"
# auto-resolves via the .current pointer (or spools pre-run). Best-effort:
# never fails, never adds noise.
# Usage: review_skip_event <reason_class> <detail>
#        reason_class: disabled-by-config | environment-unavailable | error
review_skip_event() {
  bash "$SCRIPT_DIR/pro-report.sh" event skip "-" local-review "6b" "$1" "$2" \
    >/dev/null 2>&1 || true
}

SPEC_DIR=""
BASE_REF=""
ONLY=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-dir) SPEC_DIR="$2"; shift 2 ;;
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --only)     ONLY="$2"; shift 2 ;;
    --force)    FORCE=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *)          local_err "unknown arg: $1"; exit 1 ;;
  esac
done

PROJECT_ROOT="$(local_project_root)"

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

if [[ -z "$SPEC_DIR" || ! -d "$SPEC_DIR" ]]; then
  local_err "could not determine SPEC_DIR. Pass --spec-dir <path>."
  exit 1
fi

local_load_config "$PROJECT_ROOT"
LOCAL_FEATURE="$(local_feature_from_spec_dir "$SPEC_DIR")"

if [[ "$LOCAL_ENABLED" != "true" ]]; then
  local_log "local review is disabled by config — skipping (this is opt-in, not an error)."
  local_log "  Config: $LOCAL_CONFIG_PATH"
  local_log "  Fix:    set local_models.enabled: true in pro-config.yml"
  if [[ "$LOCAL_CONFIG_PATH" == "$LOCAL_EXTENSION_ROOT/pro-config.template.yml" ]]; then
    review_skip_event disabled-by-config "no pro-config found; local_models defaulting off"
  else
    review_skip_event disabled-by-config "local_models.enabled=false in $(basename "$LOCAL_CONFIG_PATH")"
  fi
  exit 0
fi
TASK_SWITCH="$(local_config_get local_models.tasks.local_review "$LOCAL_CONFIG_PATH")"
if [[ "$TASK_SWITCH" == "false" ]]; then
  local_log "local review is disabled by config — skipping (this is opt-in, not an error)."
  local_log "  Fix: set local_models.tasks.local_review: true in $(basename "$LOCAL_CONFIG_PATH")"
  review_skip_event disabled-by-config "local_models.tasks.local_review=false in $(basename "$LOCAL_CONFIG_PATH")"
  exit 0
fi
if ! local_check_reachable; then
  local_warn "Ollama not reachable at $LOCAL_BASE_URL — skipping local review (config enables it, but the sidecar is down)."
  local_warn "  Fix: start it with 'ollama serve' — or check the endpoint: curl $LOCAL_BASE_URL/api/tags"
  local_emit_skip pro-local-review ollama-unreachable "{\"base_url\":\"$LOCAL_BASE_URL\"}"
  review_skip_event environment-unavailable "Ollama unreachable at $LOCAL_BASE_URL"
  exit 0
fi

# ── Build diff snapshot ──────────────────────────────────────────────────────
DIFF_FILE="$(mktemp -t pro-diff.XXXXXX).md"
CHANGED_FILES="$(mktemp -t pro-files.XXXXXX).md"
TEST_FILES="$(mktemp -t pro-tests.XXXXXX).md"
trap 'rm -f "$DIFF_FILE" "$CHANGED_FILES" "$TEST_FILES"' EXIT

if [[ -z "$BASE_REF" ]]; then
  # Prefer the last checkpoint commit; fall back to HEAD~1.
  BASE_REF="$(git -C "$PROJECT_ROOT" log -1 --format=%H --grep='\[Pro\] Checkpoint' 2>/dev/null || true)"
  [[ -z "$BASE_REF" ]] && BASE_REF="HEAD~1"
fi

{
  echo "# diff $BASE_REF..HEAD (truncated to 800 lines)"
  echo
  echo '```diff'
  git -C "$PROJECT_ROOT" diff --no-color "$BASE_REF"...HEAD 2>/dev/null | head -n 800 || true
  echo '```'
} > "$DIFF_FILE"

{
  echo "# changed files ($BASE_REF..HEAD)"
  echo
  git -C "$PROJECT_ROOT" diff --name-only "$BASE_REF"...HEAD 2>/dev/null \
    | sed 's/^/- /' \
    | head -n 200
} > "$CHANGED_FILES"

{
  echo "# test files in change set"
  echo
  git -C "$PROJECT_ROOT" diff --name-only "$BASE_REF"...HEAD 2>/dev/null \
    | grep -Ei '(^|/)(test|spec|__tests__)(s)?/|(\.test\.|\.spec\.|_test\.)' \
    | sed 's/^/- /' \
    | head -n 200
} > "$TEST_FILES"

# ── Gather contract + supporting artifacts ───────────────────────────────────
FEATURE_KNOWLEDGE_DIR="$PROJECT_ROOT/.knowledge/features/$(basename "$SPEC_DIR")"
LATEST_CONTRACT="$(ls -1t "$FEATURE_KNOWLEDGE_DIR/contracts/"sprint-*.md 2>/dev/null | head -n1)"
RISK_REG="$SPEC_DIR/risk-register.md"
TEST_STRAT="$SPEC_DIR/test-strategy.md"
SECURITY_KB="$PROJECT_ROOT/.knowledge/security.md"

mkdir -p "$SPEC_DIR/local-reviews"

should_run() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }

run_review() {
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
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  if local_run_task "$task" "$prompt" "$out" "$@"; then
    local_ok "wrote $(basename "$out")"
    return 0
  else
    local rc=$?
    # Exit 3 = Ollama answered with an error; if the model is absent from
    # /api/tags this is the HTTP 404 model-not-found case — an environment
    # problem, not a review error. Emit once per missing model.
    if [[ "$rc" -eq 3 ]] && ! local_model_present "$model"; then
      local_warn "$task failed — model '$model' is not pulled (HTTP 404). Fix: ollama pull $model"
      if [[ "$MISSING_MODELS" != *" $model "* ]]; then
        MISSING_MODELS="$MISSING_MODELS$model "
        review_skip_event environment-unavailable "model '$model' not found on Ollama (HTTP 404) at $LOCAL_BASE_URL"
      fi
    else
      ERR_FAILED=$(( ERR_FAILED + 1 ))
      local_warn "$task failed (exit $rc) — continuing."
    fi
    return "$rc"
  fi
}

local_print_summary "local-review" \
  "Spec dir : $SPEC_DIR" \
  "Diff base: $BASE_REF" \
  "Models   : code=$LOCAL_MODEL_CODE  review=$LOCAL_MODEL_REVIEW  security=$LOCAL_MODEL_SECURITY"

FAILURES=0        # all failed artifacts (drives the human-readable summary)
ATTEMPTED=0       # generations actually invoked (exists-skip / dry-run excluded)
ERR_FAILED=0      # failures NOT attributable to a missing model (→ one aggregated error event)
MISSING_MODELS=" "  # space-delimited dedupe list for 404 model-not-found events

if should_run implementation-review; then
  args=( "$DIFF_FILE" "$CHANGED_FILES" )
  [[ -n "$LATEST_CONTRACT" ]] && args+=( "$LATEST_CONTRACT" )
  [[ -f "$RISK_REG" ]] && args+=( "$RISK_REG" )
  run_review implementation-review "$SPEC_DIR/local-reviews/implementation-review.md" "${args[@]}" || ((FAILURES++))
fi

if should_run test-gap-review; then
  args=( "$DIFF_FILE" "$CHANGED_FILES" "$TEST_FILES" )
  [[ -n "$LATEST_CONTRACT" ]] && args+=( "$LATEST_CONTRACT" )
  [[ -f "$TEST_STRAT" ]] && args+=( "$TEST_STRAT" )
  run_review test-gap-review "$SPEC_DIR/local-reviews/test-gap-review.md" "${args[@]}" || ((FAILURES++))
fi

if should_run security-review; then
  args=( "$DIFF_FILE" "$CHANGED_FILES" )
  [[ -n "$LATEST_CONTRACT" ]] && args+=( "$LATEST_CONTRACT" )
  [[ -f "$RISK_REG" ]] && args+=( "$RISK_REG" )
  [[ -f "$SECURITY_KB" ]] && args+=( "$SECURITY_KB" )
  run_review security-review "$SPEC_DIR/local-reviews/security-review.md" "${args[@]}" || ((FAILURES++))
fi

if (( FAILURES == 0 )); then
  local_ok "local-review complete — see $SPEC_DIR/local-reviews/"
else
  local_warn "local-review finished with $FAILURES failure(s)."
  # ONE aggregated error event for failures that weren't classified as
  # environment-unavailable above (FR-004: every degradation is recorded).
  if (( ERR_FAILED > 0 )); then
    review_skip_event error "$ERR_FAILED of $ATTEMPTED review artifacts failed"
  fi
fi

exit 0
