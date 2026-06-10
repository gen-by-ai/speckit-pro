#!/usr/bin/env bash
# =============================================================================
# pro-local-common.sh — shared helpers for pro-local-prep / pro-local-review /
# pro-materialize. Sourced; not executed.
#
# Responsibilities:
#   - Locate project root, spec dir, feature knowledge dir (.knowledge/features/<feature>)
#   - Load local_models.* from pro-config.yml (best-effort, no yq dependency)
#   - Pick the right model per task via local_models.tasks_to_model routing
#   - Detect whether Ollama is reachable; emit clear guidance if not
#   - Run scripts/local/ollama-md.py with consistent flags
#   - Pretty banner / log helpers
#
# Design rules:
#   - Never abort the parent pipeline on local-model failure. Print a clear
#     warning and return non-zero — callers decide whether to continue.
#   - Never invent values. If pro-config.yml is missing, fall back to defaults
#     declared in this file and print the resolved values.
#   - No external dependencies beyond bash 3.2+ / python3 / curl.
# =============================================================================
#
# Note: This file is sourced. It deliberately does NOT set -u / -e / -o pipefail
# because those flags affect the calling shell. Drivers that source this lib
# set their own flags.

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  CLR_RED=$'\033[0;31m'
  CLR_GREEN=$'\033[0;32m'
  CLR_YELLOW=$'\033[1;33m'
  CLR_BLUE=$'\033[0;34m'
  CLR_DIM=$'\033[2m'
  CLR_RESET=$'\033[0m'
else
  CLR_RED=""; CLR_GREEN=""; CLR_YELLOW=""; CLR_BLUE=""; CLR_DIM=""; CLR_RESET=""
fi

local_log()  { printf "%s[local]%s %s\n"        "$CLR_BLUE"  "$CLR_RESET" "$*" >&2; }
local_warn() { printf "%s[local WARN]%s %s\n"   "$CLR_YELLOW" "$CLR_RESET" "$*" >&2; }
local_err()  { printf "%s[local ERR]%s %s\n"    "$CLR_RED"   "$CLR_RESET" "$*" >&2; }
local_ok()   { printf "%s[local OK]%s %s\n"     "$CLR_GREEN" "$CLR_RESET" "$*" >&2; }

# ── Paths ────────────────────────────────────────────────────────────────────
local_project_root() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

# Locate the extension root by walking up from this file's directory.
# Layout: <ext-root>/scripts/bash/lib/pro-local-common.sh
#                   <ext-root>/scripts/local/ollama-md.py
#                   <ext-root>/templates/local/*.prompt.md
# ${BASH_SOURCE[0]:-$0} keeps zsh-source debuggers happy.
_local_self="${BASH_SOURCE[0]:-$0}"
LOCAL_LIB_DIR="$( cd "$( dirname "$_local_self" )" && pwd )"
LOCAL_BASH_DIR="$( cd "$LOCAL_LIB_DIR/.." && pwd )"
LOCAL_SCRIPTS_DIR="$( cd "$LOCAL_BASH_DIR/.." && pwd )"
LOCAL_EXTENSION_ROOT="$( cd "$LOCAL_SCRIPTS_DIR/.." && pwd )"
unset _local_self
LOCAL_OLLAMA_PY="$LOCAL_SCRIPTS_DIR/local/ollama-md.py"
LOCAL_TEMPLATES_DIR="$LOCAL_EXTENSION_ROOT/templates/local"

# ── Config ───────────────────────────────────────────────────────────────────
# Minimal YAML reader for `local_models.*` keys. We do not depend on yq;
# instead we accept that pro-config is shallow and well-structured. Keys we
# care about are scalar children of `local_models:` or `local_models.tasks:`,
# `local_models.routes:`.
#
# Returns the value for a dotted path, e.g. local_models.default_model.
# Empty string if not found.
local_config_get() {
  local key="$1" cfg="$2"
  [[ -f "$cfg" ]] || { echo ""; return 0; }
  python3 - "$key" "$cfg" <<'PY'
import sys, re
key, cfg_path = sys.argv[1], sys.argv[2]
parts = key.split(".")
# A tiny indentation-based YAML walker. Good enough for our shallow config.
with open(cfg_path, encoding="utf-8") as f:
    lines = f.readlines()

def strip_comment(s):
    # Naive — fine for our config; we never store '#' inside quoted strings.
    in_str = False
    for i, ch in enumerate(s):
        if ch in ("'", '"'):
            in_str = not in_str
        elif ch == "#" and not in_str:
            return s[:i]
    return s

stack = []  # list of (indent, key)
path = []   # resolved path matches parts so far
target_indent = None
target_value = None

for raw in lines:
    line = strip_comment(raw).rstrip()
    if not line.strip():
        continue
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    while stack and stack[-1][0] >= indent:
        stack.pop()
    if ":" not in stripped:
        continue
    k, _, v = stripped.partition(":")
    k = k.strip()
    v = v.strip()
    stack.append((indent, k))
    cur_path = [s[1] for s in stack]
    if cur_path == parts:
        target_value = v
        break

if target_value is None:
    print("")
else:
    # Unquote
    if (target_value.startswith('"') and target_value.endswith('"')) or \
       (target_value.startswith("'") and target_value.endswith("'")):
        target_value = target_value[1:-1]
    print(target_value)
PY
}

# Resolve the pro-config.yml location for the current project.
local_resolve_config() {
  local root="$1"
  local candidate
  for candidate in \
      "$root/.specify/extensions/pro/pro-config.local.yml" \
      "$root/.specify/extensions/pro/pro-config.yml" \
      "$root/pro-config.yml"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  # Fall back to the extension's template — never errors, but everything
  # will be defaults.
  echo "$LOCAL_EXTENSION_ROOT/pro-config.template.yml"
}

# ── Defaults (mirror pro-config.template.yml local_models section) ───────────
LOCAL_DEFAULT_ENABLED="false"
LOCAL_DEFAULT_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
LOCAL_DEFAULT_MODEL="qwen2.5-coder:7b"
LOCAL_DEFAULT_FAST_MODEL="llama3.2:3b"
LOCAL_DEFAULT_CODE_MODEL="qwen2.5-coder:7b"
LOCAL_DEFAULT_REVIEW_MODEL="qwen2.5-coder:7b"
LOCAL_DEFAULT_SECURITY_MODEL="qwen2.5-coder:7b"
LOCAL_DEFAULT_TIMEOUT="180"
LOCAL_DEFAULT_NUM_CTX="8192"
LOCAL_DEFAULT_TEMPERATURE="0.2"

# Load resolved settings into LOCAL_* globals. Must be called once before
# local_run_task / local_check_reachable.
local_load_config() {
  local root="$1"
  LOCAL_CONFIG_PATH="$(local_resolve_config "$root")"

  local v
  v="$(local_config_get local_models.enabled "$LOCAL_CONFIG_PATH")"
  LOCAL_ENABLED="${v:-$LOCAL_DEFAULT_ENABLED}"

  v="$(local_config_get local_models.base_url "$LOCAL_CONFIG_PATH")"
  LOCAL_BASE_URL="${v:-$LOCAL_DEFAULT_BASE_URL}"

  v="$(local_config_get local_models.default_model "$LOCAL_CONFIG_PATH")"
  LOCAL_MODEL_DEFAULT="${v:-$LOCAL_DEFAULT_MODEL}"

  v="$(local_config_get local_models.fast_model "$LOCAL_CONFIG_PATH")"
  LOCAL_MODEL_FAST="${v:-$LOCAL_DEFAULT_FAST_MODEL}"

  v="$(local_config_get local_models.code_model "$LOCAL_CONFIG_PATH")"
  LOCAL_MODEL_CODE="${v:-$LOCAL_DEFAULT_CODE_MODEL}"

  v="$(local_config_get local_models.review_model "$LOCAL_CONFIG_PATH")"
  LOCAL_MODEL_REVIEW="${v:-$LOCAL_DEFAULT_REVIEW_MODEL}"

  v="$(local_config_get local_models.security_model "$LOCAL_CONFIG_PATH")"
  LOCAL_MODEL_SECURITY="${v:-$LOCAL_DEFAULT_SECURITY_MODEL}"

  v="$(local_config_get local_models.timeout_seconds "$LOCAL_CONFIG_PATH")"
  LOCAL_TIMEOUT="${v:-$LOCAL_DEFAULT_TIMEOUT}"

  v="$(local_config_get local_models.num_ctx "$LOCAL_CONFIG_PATH")"
  LOCAL_NUM_CTX="${v:-$LOCAL_DEFAULT_NUM_CTX}"

  v="$(local_config_get local_models.temperature "$LOCAL_CONFIG_PATH")"
  LOCAL_TEMPERATURE="${v:-$LOCAL_DEFAULT_TEMPERATURE}"

  v="$(local_config_get local_models.metrics_file "$LOCAL_CONFIG_PATH")"
  if [[ -n "$v" ]]; then
    # Expand a leading "~/" or relative path against $root for predictability.
    case "$v" in
      /*)   LOCAL_METRICS_FILE="$v" ;;
      ~/*)  LOCAL_METRICS_FILE="${HOME}/${v#~/}" ;;
      *)    LOCAL_METRICS_FILE="$root/$v" ;;
    esac
  else
    LOCAL_METRICS_FILE="$root/.knowledge/metrics/local-metrics.jsonl"
  fi

  # local_models.telemetry: true|false (default true). When false, drivers
  # pass an empty --metrics-file and ollama-md.py becomes a no-op telemetrically.
  v="$(local_config_get local_models.telemetry "$LOCAL_CONFIG_PATH")"
  LOCAL_TELEMETRY="${v:-true}"
  [[ "$LOCAL_TELEMETRY" == "true" ]] || LOCAL_METRICS_FILE=""

  export OLLAMA_BASE_URL="$LOCAL_BASE_URL"
  export SPECKIT_PRO_METRICS_FILE="$LOCAL_METRICS_FILE"
}

# Best-effort feature slug for telemetry: takes a spec dir like
# /repo/specs/001-foo and returns "001-foo".
local_feature_from_spec_dir() {
  local d="$1"
  if [[ -n "$d" ]]; then
    basename "$d"
  fi
}

# Resolve which model to use for a named task. Task names follow the prompt
# template names without extension: repo-map, context-pack, task-packet,
# test-strategy, risk-register, implementation-review, test-gap-review,
# security-review, open-questions.
local_model_for_task() {
  case "$1" in
    repo-map|context-pack|open-questions|test-strategy|risk-register)
      echo "$LOCAL_MODEL_DEFAULT" ;;
    task-packet|implementation-review|test-gap-review)
      echo "$LOCAL_MODEL_CODE" ;;
    security-review)
      echo "$LOCAL_MODEL_SECURITY" ;;
    fast|summarize|markdown-cleanup)
      echo "$LOCAL_MODEL_FAST" ;;
    *)
      echo "$LOCAL_MODEL_DEFAULT" ;;
  esac
}

# ── Reachability ─────────────────────────────────────────────────────────────
# Returns 0 if Ollama responds to /api/tags within 3 seconds; non-zero otherwise.
local_check_reachable() {
  curl -fsS --max-time 3 "$LOCAL_BASE_URL/api/tags" >/dev/null 2>&1
}

# Returns 0 if the named model is present in `ollama list`. Doesn't pull.
local_model_present() {
  local model="$1"
  curl -fsS --max-time 3 "$LOCAL_BASE_URL/api/tags" 2>/dev/null \
    | python3 -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for m in data.get("models", []):
    if m.get("name") == want or m.get("model") == want:
        sys.exit(0)
sys.exit(1)
' "$model"
}

# ── Run one Ollama task ──────────────────────────────────────────────────────
# Usage: local_run_task <task-name> <prompt-file> <out-file> [context-file...]
# Picks the model via local_model_for_task. Passes --task / --feature /
# --metrics-file for telemetry (layer 1). Returns ollama-md.py's exit code.
local_run_task() {
  local task="$1" prompt="$2" out="$3"
  shift 3
  local model
  model="$(local_model_for_task "$task")"
  if [[ ! -f "$prompt" ]]; then
    local_err "prompt template missing: $prompt"
    return 1
  fi
  if [[ ! -f "$LOCAL_OLLAMA_PY" ]]; then
    local_err "ollama-md.py missing at $LOCAL_OLLAMA_PY"
    return 1
  fi
  local feature="${LOCAL_FEATURE:-}"
  local args=(
    --model "$model"
    --prompt-file "$prompt"
    --out-file "$out"
    --base-url "$LOCAL_BASE_URL"
    --timeout "$LOCAL_TIMEOUT"
    --temperature "$LOCAL_TEMPERATURE"
    --num-ctx "$LOCAL_NUM_CTX"
    --task "$task"
  )
  [[ -n "$feature" ]] && args+=( --feature "$feature" )
  [[ -n "${LOCAL_METRICS_FILE:-}" ]] && args+=( --metrics-file "$LOCAL_METRICS_FILE" )
  local ctx
  for ctx in "$@"; do
    [[ -f "$ctx" ]] || continue
    args+=( --context-file "$ctx" )
  done
  python3 "$LOCAL_OLLAMA_PY" "${args[@]}"
}

# ── Telemetry: emit one skip event ───────────────────────────────────────────
# When the driver self-skips before invoking any ollama-md.py call (Ollama
# unreachable, model missing, etc.), we still want one record so the
# dashboard can show how often the local stack is unavailable when wanted.
# Disabled-by-config skips are NOT logged — that's user intent, not a problem.
#
# Usage: local_emit_skip <driver-name> <reason> [extra-json-fragment]
local_emit_skip() {
  local driver="$1" reason="$2" extra="${3:-}"
  [[ -n "${LOCAL_METRICS_FILE:-}" ]] || return 0
  [[ "${LOCAL_TELEMETRY:-true}" == "true" ]] || return 0
  local feature="${LOCAL_FEATURE:-}"
  python3 - "$LOCAL_METRICS_FILE" "$driver" "$reason" "$feature" "$extra" <<'PY'
import json, sys, datetime as dt, os
path, driver, reason, feature, extra = sys.argv[1:6]
rec = {
    "type": "skip",
    "ts": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"),
    "driver": driver,
    "reason": reason,
    "feature": feature,
}
if extra:
    try:
        rec.update(json.loads(extra))
    except Exception:
        rec["extra"] = extra
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, separators=(",",":")) + "\n")
except OSError:
    pass
PY
}

# ── Packet quality ───────────────────────────────────────────────────────────
# Count structured "- UNKNOWN" placeholder lines across *.md in a dir.
# Prints "<markers> <files-with-markers> <files-total>". Prose mentions of
# UNKNOWN don't count — only lines that are exactly a "- UNKNOWN" bullet.
local_count_unknown_markers() {
  local dir="$1" total=0 hit_files=0 files=0 f n
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    files=$(( files + 1 ))
    n="$(grep -cE '^[[:space:]]*- UNKNOWN[[:space:]]*$' "$f" 2>/dev/null)"; n="${n:-0}"
    if [[ "$n" -gt 0 ]]; then
      total=$(( total + n ))
      hit_files=$(( hit_files + 1 ))
    fi
  done
  echo "$total $hit_files $files"
}

# ── Pretty summary ───────────────────────────────────────────────────────────
local_print_summary() {
  local title="$1"; shift
  printf "\n%s┌─ %s ───────────────────────────────────────────────────%s\n" \
    "$CLR_BLUE" "$title" "$CLR_RESET" >&2
  while [[ $# -gt 0 ]]; do
    printf "%s│%s  %s\n" "$CLR_BLUE" "$CLR_RESET" "$1" >&2
    shift
  done
  printf "%s└──────────────────────────────────────────────────────────%s\n" \
    "$CLR_BLUE" "$CLR_RESET" >&2
}
