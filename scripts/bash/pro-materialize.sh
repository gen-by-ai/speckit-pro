#!/usr/bin/env bash
# =============================================================================
# pro-materialize.sh — Materialize tasks.md into per-task packets
#
# Splits tasks.md into one Markdown file per task under
#   <SPEC_DIR>/task-packets/TASK-NNN-<slug>.md
#
# Each packet is a small, self-contained context bundle the implementer
# can read instead of the whole spec/plan/tasks set.
#
# If local_models.enabled is true AND Ollama is reachable, packets are
# refined by the local model using templates/local/task-packet.prompt.md.
# Otherwise a deterministic skeleton packet is written (still useful).
#
# Usage:
#   pro-materialize.sh --spec-dir <path>
#                      [--start N] [--end N]
#                      [--only NNN,NNN,...]
#                      [--force] [--dry-run]
# =============================================================================

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/pro-local-common.sh
source "$SCRIPT_DIR/lib/pro-local-common.sh"

SPEC_DIR=""
ONLY_IDS=""
START_ID=""
END_ID=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec-dir) SPEC_DIR="$2"; shift 2 ;;
    --only)     ONLY_IDS="$2"; shift 2 ;;
    --start)    START_ID="$2"; shift 2 ;;
    --end)      END_ID="$2"; shift 2 ;;
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

TASKS_MD="$SPEC_DIR/tasks.md"
SPEC_MD="$SPEC_DIR/spec.md"
PLAN_MD="$SPEC_DIR/plan.md"
REPO_MAP="$SPEC_DIR/repo-map.md"
PACKETS_DIR="$SPEC_DIR/task-packets"

if [[ ! -f "$TASKS_MD" ]]; then
  local_err "$TASKS_MD not found — run /speckit.tasks first."
  exit 1
fi

mkdir -p "$PACKETS_DIR"
local_load_config "$PROJECT_ROOT"
LOCAL_FEATURE="$(local_feature_from_spec_dir "$SPEC_DIR")"

USE_LOCAL=false
if [[ "$LOCAL_ENABLED" == "true" ]]; then
  if local_check_reachable; then
    USE_LOCAL=true
  else
    local_emit_skip pro-materialize ollama-unreachable "{\"base_url\":\"$LOCAL_BASE_URL\"}"
  fi
fi

# ── Parse tasks.md → JSON-ish stream of (id, title, section, body) ───────────
EXTRACTED="$(mktemp -t pro-tasks.XXXXXX).json"
trap 'rm -f "$EXTRACTED"' EXIT

python3 - "$TASKS_MD" > "$EXTRACTED" <<'PY'
import json, re, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = f.read()

# A "task line" in SpecKit tasks.md is a checkbox bullet, optionally with an ID.
# We accept these shapes:
#   - [ ] T001 Title goes here
#   - [ ] **T001** Title
#   - [x] T010 Title
#   - [ ] Title with no ID (we assign NNN)
task_re = re.compile(r'^\s*-\s*\[( |x|X)\]\s*(\*\*)?(T\d{2,4}|\d{2,4})?(\*\*)?\s*(.*)$')

section = ""
tasks = []
auto = 0
for line in raw.splitlines():
    h = re.match(r'^#{1,6}\s+(.*)$', line)
    if h:
        section = h.group(1).strip()
        continue
    m = task_re.match(line)
    if not m:
        continue
    done = m.group(1).lower() == "x"
    tid_raw = (m.group(3) or "").upper().lstrip("T")
    title = m.group(5).strip()
    if not tid_raw:
        auto += 1
        tid_raw = f"AUTO{auto:03d}"
    # Normalize ID to NNN form
    try:
        tid = f"{int(tid_raw):03d}"
    except ValueError:
        tid = tid_raw
    tasks.append({
        "id": tid,
        "raw_id": tid_raw,
        "done": done,
        "title": title,
        "section": section,
    })

json.dump(tasks, sys.stdout, indent=2)
PY

TOTAL="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$EXTRACTED")"
if [[ "$TOTAL" == "0" ]]; then
  local_warn "no tasks parsed from $TASKS_MD"
  exit 0
fi

local_print_summary "materialize" \
  "Spec dir   : $SPEC_DIR" \
  "Tasks file : $TASKS_MD" \
  "Found      : $TOTAL task(s)" \
  "Packets    : $PACKETS_DIR" \
  "Local model: $([[ "$USE_LOCAL" == "true" ]] && echo "yes ($LOCAL_MODEL_CODE)" || echo "no — writing skeletons")"

slugify() {
  printf "%s" "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-40
}

selected() {
  local id="$1"
  if [[ -n "$ONLY_IDS" ]]; then
    [[ ",$ONLY_IDS," == *",$id,"* ]] && return 0 || return 1
  fi
  if [[ -n "$START_ID" && "$id" < "$START_ID" ]]; then return 1; fi
  if [[ -n "$END_ID"   && "$id" > "$END_ID"   ]]; then return 1; fi
  return 0
}

WROTE=0
SKIPPED=0
FAILED=0

# Iterate tasks
COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$EXTRACTED")"
for IDX in $(seq 0 $((COUNT-1))); do
  ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["id"])' "$EXTRACTED" "$IDX")"
  TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["title"])' "$EXTRACTED" "$IDX")"
  SECTION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["section"])' "$EXTRACTED" "$IDX")"

  selected "$ID" || { ((SKIPPED++)); continue; }

  SLUG="$(slugify "$TITLE")"
  [[ -z "$SLUG" ]] && SLUG="task"
  OUT="$PACKETS_DIR/TASK-${ID}-${SLUG}.md"

  if [[ -f "$OUT" && "$FORCE" != "true" ]]; then
    local_log "$(printf "TASK-%s  → %s  (exists, skip)" "$ID" "$(basename "$OUT")")"
    ((SKIPPED++)); continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    local_log "$(printf "DRY  TASK-%s  → %s" "$ID" "$OUT")"
    ((WROTE++)); continue
  fi

  # Build a per-task prompt with the task injected
  PROMPT_FILE="$(mktemp -t pro-tp.XXXXXX).md"
  TASK_CTX="$(mktemp -t pro-tc.XXXXXX).md"
  {
    cat "$LOCAL_TEMPLATES_DIR/task-packet.prompt.md"
    echo
    echo "## THIS TASK"
    echo
    echo "- **TASK id**: TASK-${ID}"
    echo "- **Title**: ${TITLE}"
    echo "- **Section**: ${SECTION:-<none>}"
    echo
    echo "Use exactly \`# TASK-${ID} — ${TITLE}\` as the H1."
  } > "$PROMPT_FILE"
  {
    echo "# task context"
    echo
    echo "- id: TASK-${ID}"
    echo "- title: ${TITLE}"
    echo "- section: ${SECTION:-<none>}"
  } > "$TASK_CTX"

  if [[ "$USE_LOCAL" == "true" ]]; then
    args=( --model "$LOCAL_MODEL_CODE"
           --prompt-file "$PROMPT_FILE"
           --out-file "$OUT"
           --base-url "$LOCAL_BASE_URL"
           --timeout "$LOCAL_TIMEOUT"
           --temperature "$LOCAL_TEMPERATURE"
           --num-ctx "$LOCAL_NUM_CTX"
           --task "task-packet"
           --context-file "$TASK_CTX"
           --context-file "$SPEC_MD"
           --context-file "$PLAN_MD"
           --context-file "$TASKS_MD" )
    [[ -n "$LOCAL_FEATURE" ]] && args+=( --feature "$LOCAL_FEATURE" )
    [[ -n "${LOCAL_METRICS_FILE:-}" ]] && args+=( --metrics-file "$LOCAL_METRICS_FILE" )
    [[ -f "$REPO_MAP" ]] && args+=( --context-file "$REPO_MAP" )

    if python3 "$LOCAL_OLLAMA_PY" "${args[@]}"; then
      local_ok "TASK-${ID}: $(basename "$OUT")"
      ((WROTE++))
    else
      local_warn "TASK-${ID}: local generation failed — writing skeleton"
      cat > "$OUT" <<EOF
# TASK-${ID} — ${TITLE}

> _Skeleton packet (local model unavailable). Fill in before implementation._

## Goal
${TITLE}

## Section
${SECTION:-<none>}

## Acceptance criteria
- [ ] <derive from the task line in tasks.md>

## Files likely to change
- UNKNOWN

## Files to read first
- specs/$(basename "$SPEC_DIR")/spec.md
- specs/$(basename "$SPEC_DIR")/plan.md

## Test plan
- UNKNOWN

## Risks / edge cases
- UNKNOWN

## Out of scope for this packet
- UNKNOWN
EOF
      ((WROTE++)); ((FAILED++))
    fi
  else
    cat > "$OUT" <<EOF
# TASK-${ID} — ${TITLE}

> _Skeleton packet (local models disabled or unreachable). Fill in before implementation._

## Goal
${TITLE}

## Section
${SECTION:-<none>}

## Acceptance criteria
- [ ] <derive from the task line in tasks.md>

## Files likely to change
- UNKNOWN

## Files to read first
- specs/$(basename "$SPEC_DIR")/spec.md
- specs/$(basename "$SPEC_DIR")/plan.md

## Test plan
- UNKNOWN

## Risks / edge cases
- UNKNOWN

## Out of scope for this packet
- UNKNOWN
EOF
    local_log "TASK-${ID}: skeleton written"
    ((WROTE++))
  fi

  rm -f "$PROMPT_FILE" "$TASK_CTX"
done

local_ok "materialize: wrote $WROTE, skipped $SKIPPED, local-generation failures $FAILED"
exit 0
