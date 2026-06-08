#!/usr/bin/env bash
# =============================================================================
# pro-otel-emit.sh — opt-in OpenTelemetry exporter for a finished /pro.go run.
#
# Invoked ONLY by pro-report.sh `finish` (after runs.jsonl is written) when
# `reporting.otel.enabled` resolves true. Emits, via OTLP/HTTP **JSON** (no
# protobuf / no OTel SDK dependency):
#   • one resource (service.name) carrying a trace with
#       - a per-run root span "speckit_pro.run" (GenAI semantic conventions +
#         speckit.* attributes + claude.session_id as the JOIN key into the
#         Claude Code CLAUDE_CODE_ENABLE_TELEMETRY stream)
#       - one child span per per_phase_durations_s entry (timed from the
#         manifest phases[] start/stop ts_s pairs)
#   • a metrics payload (gen_ai.client.token.usage by type, speckit.run.cost_usd,
#     speckit.run.duration_s, speckit.run.eval_score)
#
# Hard guarantees (D8 / telemetry-schema.md / config-schema.md reporting.otel.*):
#   • NEVER fatal. Self-skips (exit 0 + one log line) when disabled, endpoint
#     empty, python3/curl missing, or any curl POST fails.
#   • No fabricated values: any attribute/metric whose source value is null/
#     absent is SKIPPED entirely (never sent as a 0).
#   • bash 3.2 compatible (macOS default): no associative arrays / mapfile /
#     declare -A. python3 builds the JSON; curl POSTs it.
#
# Usage:
#   pro-otel-emit.sh --run-id <id> --manifest <path> --runs-log <path> \
#                    [--endpoint URL] [--headers "k=v,k2=v2"] \
#                    [--service-name NAME] [--timeout SECONDS]
#   (--endpoint/--headers/--service-name/--timeout override the resolved
#    reporting.otel.* config; absent ⇒ config value ⇒ documented default.)
# =============================================================================

set -uo pipefail

# ── Locate self + shared helpers ────────────────────────────────────────────
# Same fallback shim pro-report.sh uses: prefer the shared lib, but degrade to
# minimal stubs if the installed snapshot has drifted.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pro-fanout-common.sh
if [[ -f "$SCRIPT_DIR/lib/pro-fanout-common.sh" ]]; then
  . "$SCRIPT_DIR/lib/pro-fanout-common.sh"
else
  # Minimal fallbacks if the shared lib is unavailable (installed-snapshot drift).
  fanout_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  fanout_now_s()   { date -u +%s; }
  fanout_log()  { printf "[otel] %s\n"      "$*" >&2; }
  fanout_warn() { printf "[otel WARN] %s\n" "$*" >&2; }
  fanout_err()  { printf "[otel ERR] %s\n"  "$*" >&2; }
  fanout_ok()   { printf "[otel OK] %s\n"   "$*" >&2; }
  fanout_telemetry() { :; }
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

have_py()   { command -v python3 >/dev/null 2>&1; }
have_curl() { command -v curl    >/dev/null 2>&1; }

# ── Config walker (copied from pro-local-common.sh::local_config_get) ─────────
# Returns the scalar value for a dotted key path from a shallow YAML config.
# Empty string if not found. No yq dependency.
otel_config_get() {
  local key="$1" cfg="$2"
  [[ -f "$cfg" ]] || { echo ""; return 0; }
  have_py || { echo ""; return 0; }
  python3 - "$key" "$cfg" <<'PY'
import sys
key, cfg_path = sys.argv[1], sys.argv[2]
parts = key.split(".")
try:
    with open(cfg_path, encoding="utf-8") as f:
        lines = f.readlines()
except Exception:
    print(""); sys.exit(0)

def strip_comment(s):
    in_str = False
    for i, ch in enumerate(s):
        if ch in ("'", '"'):
            in_str = not in_str
        elif ch == "#" and not in_str:
            return s[:i]
    return s

stack = []
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
    k = k.strip(); v = v.strip()
    stack.append((indent, k))
    cur_path = [s[1] for s in stack]
    if cur_path == parts:
        target_value = v
        break

if target_value is None:
    print("")
else:
    if (target_value.startswith('"') and target_value.endswith('"')) or \
       (target_value.startswith("'") and target_value.endswith("'")):
        target_value = target_value[1:-1]
    print(target_value)
PY
}

# Resolve the pro-config.yml location (same precedence as pro-local-common.sh::
# local_resolve_config), then the template, then this extension's template.
otel_resolve_config() {
  local root="$1" candidate
  for candidate in \
      "$root/.specify/extensions/pro/pro-config.local.yml" \
      "$root/.specify/extensions/pro/pro-config.yml" \
      "$root/pro-config.yml"; do
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  # Extension template lives at <ext-root>/pro-config.template.yml.
  # <ext-root>/scripts/bash/pro-otel-emit.sh ⇒ up two dirs.
  local ext_root; ext_root="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
  if [[ -n "$ext_root" && -f "$ext_root/pro-config.template.yml" ]]; then
    echo "$ext_root/pro-config.template.yml"; return 0
  fi
  echo ""
}

# =============================================================================
# Parse args
# =============================================================================
RUN_ID="" MANIFEST="" RUNS_LOG=""
OPT_ENDPOINT="" OPT_HEADERS="" OPT_SERVICE_NAME="" OPT_TIMEOUT=""
HAVE_ENDPOINT=0 HAVE_HEADERS=0 HAVE_SERVICE=0 HAVE_TIMEOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)       RUN_ID="${2:-}"; shift 2 ;;
    --manifest)     MANIFEST="${2:-}"; shift 2 ;;
    --runs-log)     RUNS_LOG="${2:-}"; shift 2 ;;
    --endpoint)     OPT_ENDPOINT="${2:-}"; HAVE_ENDPOINT=1; shift 2 ;;
    --headers)      OPT_HEADERS="${2:-}"; HAVE_HEADERS=1; shift 2 ;;
    --service-name) OPT_SERVICE_NAME="${2:-}"; HAVE_SERVICE=1; shift 2 ;;
    --timeout)      OPT_TIMEOUT="${2:-}"; HAVE_TIMEOUT=1; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  fanout_warn "otel export skipped: no --run-id"
  exit 0
fi

# =============================================================================
# Resolve reporting.otel.* (CLI flag overrides → config value → default)
# =============================================================================
CFG="$(otel_resolve_config "$PROJECT_ROOT")"

cfg_enabled="$(otel_config_get reporting.otel.enabled "$CFG")"
cfg_endpoint="$(otel_config_get reporting.otel.endpoint "$CFG")"
cfg_headers="$(otel_config_get reporting.otel.headers "$CFG")"
cfg_service="$(otel_config_get reporting.otel.service_name "$CFG")"
cfg_timeout="$(otel_config_get reporting.otel.timeout_seconds "$CFG")"

# enabled: explicit true required (default off).
ENABLED="${cfg_enabled:-false}"

# endpoint / headers / service / timeout: CLI flag wins when supplied.
if [[ "$HAVE_ENDPOINT" -eq 1 ]]; then ENDPOINT="$OPT_ENDPOINT"; else ENDPOINT="${cfg_endpoint:-}"; fi
if [[ "$HAVE_HEADERS"  -eq 1 ]]; then HEADERS="$OPT_HEADERS";  else HEADERS="${cfg_headers:-}";  fi
if [[ "$HAVE_SERVICE"  -eq 1 ]]; then SERVICE_NAME="$OPT_SERVICE_NAME"; else SERVICE_NAME="${cfg_service:-speckit-pro}"; fi
[[ -z "$SERVICE_NAME" ]] && SERVICE_NAME="speckit-pro"
if [[ "$HAVE_TIMEOUT"  -eq 1 ]]; then TIMEOUT="$OPT_TIMEOUT"; else TIMEOUT="${cfg_timeout:-5}"; fi
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=5

# (1) Self-skip: not enabled OR no endpoint.
if [[ "$ENABLED" != "true" ]]; then
  fanout_log "otel export skipped (reporting.otel.enabled is not true)"
  exit 0
fi
if [[ -z "$ENDPOINT" ]]; then
  fanout_log "otel export skipped (reporting.otel.endpoint is empty)"
  exit 0
fi
# Normalize: strip a trailing slash so ENDPOINT/v1/traces is well-formed.
ENDPOINT="${ENDPOINT%/}"

# (2) Capability gate: need python3 (build payload) AND curl (POST).
if ! have_py || ! have_curl; then
  fanout_log "otel export skipped (capability gap)"
  exit 0
fi

# (3) Build the two OTLP/HTTP JSON payloads with python3 (hand-built, no SDK).
TRACES_FILE="$(mktemp "${TMPDIR:-/tmp}/pro-otel-traces.XXXXXX" 2>/dev/null)" || TRACES_FILE=""
METRICS_FILE="$(mktemp "${TMPDIR:-/tmp}/pro-otel-metrics.XXXXXX" 2>/dev/null)" || METRICS_FILE=""
if [[ -z "$TRACES_FILE" || -z "$METRICS_FILE" ]]; then
  fanout_warn "otel export skipped (could not create temp files)"
  rm -f "$TRACES_FILE" "$METRICS_FILE" 2>/dev/null
  exit 0
fi

BUILD_RC=0
RUN_ID="$RUN_ID" MANIFEST="${MANIFEST:-}" RUNS_LOG="${RUNS_LOG:-}" SERVICE_NAME="$SERVICE_NAME" \
TRACES_OUT="$TRACES_FILE" METRICS_OUT="$METRICS_FILE" \
  python3 - <<'PY' || BUILD_RC=$?
import json, os, secrets, sys, time

run_id      = os.environ["RUN_ID"]
manifest_p  = os.environ.get("MANIFEST") or ""
runslog_p   = os.environ.get("RUNS_LOG") or ""
service     = os.environ.get("SERVICE_NAME") or "speckit-pro"
traces_out  = os.environ["TRACES_OUT"]
metrics_out = os.environ["METRICS_OUT"]

# ── Load the per-run manifest (phases[] timing, feature, calls fallback) ──
manifest = {}
if manifest_p and os.path.isfile(manifest_p):
    try:
        with open(manifest_p, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except Exception:
        manifest = {}

# ── Load this run's rolled-up summary line from runs.jsonl ──
summary = {}
if runslog_p and os.path.isfile(runslog_p):
    try:
        with open(runslog_p, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    rec = json.loads(ln)
                except Exception:
                    continue
                if rec.get("run_id") == run_id:
                    summary = rec  # last match wins (the line just appended)
    except Exception:
        summary = {}

# Prefer the rolled-up summary, fall back to the manifest for shared keys.
def pick(*keys):
    for src in (summary, manifest):
        for k in keys:
            if k in src and src[k] is not None:
                return src[k]
    return None

# ── Span / trace id generation (random hex via secrets) ──
def trace_id():  return secrets.token_hex(16)   # 16 bytes -> 32 hex chars
def span_id():   return secrets.token_hex(8)    # 8 bytes  -> 16 hex chars

trace_hex = trace_id()
root_span_hex = span_id()

# ── Timing: bound the root span to the run's wall-clock if we can ──
def to_int(v):
    try:
        return int(v)
    except Exception:
        return None

def to_float(v):
    try:
        return float(v)
    except Exception:
        return None

NS = 1_000_000_000
started_s = to_int(manifest.get("started_at_s"))
phases = manifest.get("phases") or []

# Determine run start / end nanos from phase ts_s if available, else manifest
# start + now.
phase_ts = [to_int(p.get("ts_s")) for p in phases if isinstance(p, dict)]
phase_ts = [t for t in phase_ts if t is not None]
if phase_ts:
    run_start_s = min([started_s] + phase_ts) if started_s is not None else min(phase_ts)
    run_end_s = max(phase_ts)
else:
    run_start_s = started_s if started_s is not None else int(time.time())
    run_end_s = int(time.time())
if run_end_s <= run_start_s:
    run_end_s = run_start_s + 1  # avoid a zero/negative-duration span
root_start_ns = run_start_s * NS
root_end_ns = run_end_s * NS

# ── Attribute helpers (SKIP nulls — never fabricate a 0) ──
def kv_str(key, val):
    return {"key": key, "value": {"stringValue": str(val)}}

def kv_int(key, val):
    return {"key": key, "value": {"intValue": int(val)}}

def kv_double(key, val):
    return {"key": key, "value": {"doubleValue": float(val)}}

def add_str(attrs, key, val):
    if val is None:
        return
    s = str(val)
    if s == "":
        return
    attrs.append(kv_str(key, s))

def add_int(attrs, key, val):
    iv = to_int(val)
    if iv is None:
        return
    attrs.append(kv_int(key, iv))

def add_double(attrs, key, val):
    dv = to_float(val)
    if dv is None:
        return
    attrs.append(kv_double(key, dv))

# ── Pull the values we report (each may be None ⇒ skipped) ──
feature   = pick("feature")
models    = pick("models") or {}
gen_model = models.get("generator") if isinstance(models, dict) else None
eval_model = models.get("evaluator") if isinstance(models, dict) else None
session_id = pick("session_id")
cost_usd  = pick("total_cost_usd")
input_tokens  = pick("input_tokens")
output_tokens = pick("output_tokens")
cache_read    = pick("cache_read_tokens")
cache_creation = pick("cache_creation_tokens")
eval_verdict  = pick("eval_verdict")
eval_score    = pick("eval_score")
human_interventions = pick("human_interventions")
rework_count        = pick("rework_count")
cb_trips            = pick("circuit_breaker_trips")
completion_state    = pick("completion_state")
cli                 = pick("cli")
per_phase = pick("per_phase_durations_s") or {}
duration_s = pick("duration_s")

# ── Root span attributes (GenAI conventions + speckit.* + join key) ──
root_attrs = []
# GenAI semantic conventions
add_str(root_attrs, "gen_ai.operation.name", "speckit_pro.run")
add_str(root_attrs, "gen_ai.request.model", gen_model)
add_int(root_attrs, "gen_ai.usage.input_tokens", input_tokens)
add_int(root_attrs, "gen_ai.usage.output_tokens", output_tokens)
# speckit.* run facts
add_str(root_attrs, "speckit.run_id", run_id)
add_str(root_attrs, "speckit.feature", feature)
add_str(root_attrs, "speckit.eval_verdict", eval_verdict)
add_int(root_attrs, "speckit.eval_score", eval_score)
add_double(root_attrs, "speckit.cost_usd", cost_usd)
add_int(root_attrs, "speckit.human_interventions", human_interventions)
add_int(root_attrs, "speckit.rework_count", rework_count)
add_int(root_attrs, "speckit.circuit_breaker_trips", cb_trips)
# JOIN key into Claude Code's own telemetry stream
add_str(root_attrs, "claude.session_id", session_id)

# ── Child spans: one per per_phase_durations_s entry, timed from phases[] ──
# Build start/stop ts_s pairs per phase from the manifest events.
phase_start = {}
phase_stop = {}
for p in phases:
    if not isinstance(p, dict):
        continue
    name = p.get("phase")
    ev = p.get("event")
    ts = to_int(p.get("ts_s"))
    if name is None or ts is None:
        continue
    if ev == "start":
        # first start wins
        phase_start.setdefault(name, ts)
    elif ev == "stop":
        # last stop wins
        phase_stop[name] = ts

child_spans = []
# per_phase_durations_s is a LIST of {phase,seconds} (the shape pro-report.sh writes,
# which preserves first-seen phase order); tolerate a dict too for forward-compat.
if isinstance(per_phase, list):
    phase_items = [(r.get("phase"), r.get("seconds")) for r in per_phase if isinstance(r, dict)]
elif isinstance(per_phase, dict):
    phase_items = list(per_phase.items())
else:
    phase_items = []
for pname, pdur in phase_items:
    cstart = phase_start.get(pname)
    cstop = phase_stop.get(pname)
    if cstart is None:
        # No timing in manifest — derive a window from the duration inside the
        # root span so the child still nests, without fabricating wall-clock.
        d = to_int(pdur)
        cstart = run_start_s
        cstop = run_start_s + (d if d is not None else 0)
    if cstop is None or cstop < cstart:
        d = to_int(pdur)
        cstop = cstart + (d if d is not None else 0)
    if cstop <= cstart:
        cstop = cstart + 1
    cattrs = []
    add_str(cattrs, "speckit.phase", str(pname))
    add_int(cattrs, "speckit.phase.duration_s", pdur)
    child_spans.append({
        "traceId": trace_hex,
        "spanId": span_id(),
        "parentSpanId": root_span_hex,
        "name": "speckit_pro.phase.%s" % pname,
        "kind": 1,  # SPAN_KIND_INTERNAL
        "startTimeUnixNano": str(cstart * NS),
        "endTimeUnixNano": str(cstop * NS),
        "attributes": cattrs,
    })

root_span = {
    "traceId": trace_hex,
    "spanId": root_span_hex,
    "name": "speckit_pro.run",
    "kind": 1,  # SPAN_KIND_INTERNAL
    "startTimeUnixNano": str(root_start_ns),
    "endTimeUnixNano": str(root_end_ns),
    "attributes": root_attrs,
}

resource_attrs = [kv_str("service.name", service)]

traces_payload = {
    "resourceSpans": [
        {
            "resource": {"attributes": resource_attrs},
            "scopeSpans": [
                {
                    "scope": {"name": "speckit-pro", "version": "1.23"},
                    "spans": [root_span] + child_spans,
                }
            ],
        }
    ]
}

# ── Metrics payload (skip any metric whose source value is null) ──
metric_time_ns = str(root_end_ns)

def gauge(name, unit, value, attrs=None):
    dp = {
        "asDouble": float(value),
        "timeUnixNano": metric_time_ns,
        "startTimeUnixNano": str(root_start_ns),
    }
    if attrs:
        dp["attributes"] = attrs
    return {
        "name": name,
        "unit": unit,
        "gauge": {"dataPoints": [dp]},
    }

def sum_int(name, unit, value, attrs=None):
    dp = {
        "asInt": int(value),
        "timeUnixNano": metric_time_ns,
        "startTimeUnixNano": str(root_start_ns),
    }
    if attrs:
        dp["attributes"] = attrs
    return {
        "name": name,
        "unit": unit,
        "sum": {
            "dataPoints": [dp],
            "aggregationTemporality": 2,  # CUMULATIVE
            "isMonotonic": True,
        },
    }

metrics = []

# gen_ai.client.token.usage — one data point per token type present.
token_dps = []
def token_dp(token_type, value):
    iv = to_int(value)
    if iv is None:
        return None
    return {
        "asInt": iv,
        "timeUnixNano": metric_time_ns,
        "startTimeUnixNano": str(root_start_ns),
        "attributes": [kv_str("gen_ai.token.type", token_type)],
    }
for tt, val in (("input", input_tokens), ("output", output_tokens),
                ("cache_read", cache_read), ("cache_creation", cache_creation)):
    dp = token_dp(tt, val)
    if dp is not None:
        token_dps.append(dp)
if token_dps:
    metrics.append({
        "name": "gen_ai.client.token.usage",
        "unit": "{token}",
        "sum": {
            "dataPoints": token_dps,
            "aggregationTemporality": 2,
            "isMonotonic": False,
        },
    })

if to_float(cost_usd) is not None:
    metrics.append(gauge("speckit.run.cost_usd", "USD", to_float(cost_usd)))
if to_float(duration_s) is not None:
    metrics.append(gauge("speckit.run.duration_s", "s", to_float(duration_s)))
elif run_end_s > run_start_s:
    # Fall back to the span's own wall-clock window (a real measured value).
    metrics.append(gauge("speckit.run.duration_s", "s", float(run_end_s - run_start_s)))
if to_float(eval_score) is not None:
    metrics.append(gauge("speckit.run.eval_score", "1", to_float(eval_score)))

metrics_payload = {
    "resourceMetrics": [
        {
            "resource": {"attributes": resource_attrs},
            "scopeMetrics": [
                {
                    "scope": {"name": "speckit-pro", "version": "1.23"},
                    "metrics": metrics,
                }
            ],
        }
    ]
}

try:
    with open(traces_out, "w", encoding="utf-8") as fh:
        json.dump(traces_payload, fh)
    with open(metrics_out, "w", encoding="utf-8") as fh:
        json.dump(metrics_payload, fh)
except Exception as e:
    sys.stderr.write("payload build failed: %s\n" % e)
    sys.exit(4)

# Report how many spans/metrics we built (stderr only).
sys.stderr.write("built %d span(s) + %d metric(s)\n" % (1 + len(child_spans), len(metrics)))
PY

if [[ "$BUILD_RC" -ne 0 ]]; then
  fanout_warn "otel export skipped (payload build failed, rc=$BUILD_RC)"
  rm -f "$TRACES_FILE" "$METRICS_FILE" 2>/dev/null
  exit 0
fi

# (4) Parse --headers ("k=v,k2=v2") into repeated curl -H args (bash 3.2-safe).
CURL_HDR_ARGS=()
if [[ -n "$HEADERS" ]]; then
  OLD_IFS="$IFS"; IFS=','
  for _pair in $HEADERS; do
    IFS="$OLD_IFS"
    # trim surrounding whitespace
    _pair="${_pair#"${_pair%%[![:space:]]*}"}"
    _pair="${_pair%"${_pair##*[![:space:]]}"}"
    [[ -z "$_pair" ]] && { IFS=','; continue; }
    if [[ "$_pair" == *"="* ]]; then
      _k="${_pair%%=*}"; _v="${_pair#*=}"
      # trim key whitespace
      _k="${_k#"${_k%%[![:space:]]*}"}"; _k="${_k%"${_k##*[![:space:]]}"}"
      CURL_HDR_ARGS+=( -H "${_k}: ${_v}" )
    fi
    IFS=','
  done
  IFS="$OLD_IFS"
fi

# POST one OTLP/HTTP JSON payload. Returns curl's exit code (caller decides).
# NOTE: bash 3.2 + `set -u` errors on "${arr[@]}" when the array is empty, so
# the optional header args are expanded with the ${arr[@]+...} guard.
otel_post() {
  local url="$1" body_file="$2"
  curl -sS -o /dev/null \
    --max-time "$TIMEOUT" \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    ${CURL_HDR_ARGS[@]+"${CURL_HDR_ARGS[@]}"} \
    --data-binary "@$body_file"
}

POST_OK=1
# Guard each curl call (set -uo pipefail is active; -e is NOT — but be explicit).
rc=0
otel_post "$ENDPOINT/v1/traces" "$TRACES_FILE" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  fanout_warn "otel export failed: traces POST to $ENDPOINT/v1/traces (curl exit $rc)"
  POST_OK=0
fi
rc=0
otel_post "$ENDPOINT/v1/metrics" "$METRICS_FILE" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  fanout_warn "otel export failed: metrics POST to $ENDPOINT/v1/metrics (curl exit $rc)"
  POST_OK=0
fi

rm -f "$TRACES_FILE" "$METRICS_FILE" 2>/dev/null

if [[ "$POST_OK" -eq 1 ]]; then
  printf "[otel OK] exported run %s to %s (traces + metrics)\n" "$RUN_ID" "$ENDPOINT" >&2
fi

# NEVER fatal.
exit 0
