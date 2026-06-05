#!/usr/bin/env bash
# =============================================================================
# pro-fanout-common.sh — shared helpers for the SpecKit Pro fan-out engine
# (pro-fanout.sh / pro-scan.sh). Sourced; not executed.
#
# Responsibilities:
#   - ISO timestamps + JSONL telemetry append (.knowledge/metrics/)
#   - CPU/core detection + worker-count defaults & clamping
#   - Substrate detection (override → harness signal → CLI availability → sequential)
#   - A bounded, bash-3.2-safe worker-slot pool with manual per-worker timeout
#     and a consecutive-failure circuit breaker
#
# Design rules (same as pro-local-common.sh):
#   - Sourced: does NOT set -e/-u/-o pipefail (would leak into the caller).
#   - bash 3.2 compatible: no associative arrays, no `wait -n`, no `timeout` bin.
#   - No external deps beyond bash 3.2 / python3 (telemetry JSON) / coreutils.
#   - Never abort the parent on a worker failure — report and continue.
# =============================================================================

if [[ -t 2 ]]; then
  FO_RED=$'\033[0;31m'; FO_GREEN=$'\033[0;32m'; FO_YELLOW=$'\033[1;33m'
  FO_BLUE=$'\033[0;34m'; FO_DIM=$'\033[2m'; FO_RESET=$'\033[0m'
else
  FO_RED=""; FO_GREEN=""; FO_YELLOW=""; FO_BLUE=""; FO_DIM=""; FO_RESET=""
fi

fanout_log()  { printf "%s[fanout]%s %s\n"      "$FO_BLUE"   "$FO_RESET" "$*" >&2; }
fanout_warn() { printf "%s[fanout WARN]%s %s\n" "$FO_YELLOW" "$FO_RESET" "$*" >&2; }
fanout_err()  { printf "%s[fanout ERR]%s %s\n"  "$FO_RED"    "$FO_RESET" "$*" >&2; }
fanout_ok()   { printf "%s[fanout OK]%s %s\n"   "$FO_GREEN"  "$FO_RESET" "$*" >&2; }

fanout_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fanout_now_s()   { date -u +%s; }

# ── Telemetry ─────────────────────────────────────────────────────────────────
# fanout_telemetry <metrics_file> <event> <run_id> <portion_id> <substrate> [duration_ms] [error]
# Appends one JSONL line per worker event. No-op if metrics_file is empty.
# Uses python3 for robust JSON escaping (python3 is an engine dependency).
fanout_telemetry() {
  local mf="$1" event="$2" run_id="$3" portion="$4" substrate="$5"
  local dur="${6:-}" err="${7:-}"
  [[ -z "$mf" ]] && return 0
  mkdir -p "$(dirname "$mf")" 2>/dev/null
  if command -v python3 >/dev/null 2>&1; then
    TS="$(fanout_now_iso)" RUN="$run_id" EV="$event" POR="$portion" SUB="$substrate" \
    DUR="$dur" ERRMSG="$err" python3 - "$mf" <<'PY'
import json, os, sys
rec = {"ts": os.environ["TS"], "run_id": os.environ["RUN"],
       "event": os.environ["EV"], "substrate": os.environ["SUB"]}
if os.environ.get("POR"): rec["portion_id"] = os.environ["POR"]
if os.environ.get("DUR"): rec["duration_ms"] = int(os.environ["DUR"])
if os.environ.get("ERRMSG"): rec["error"] = os.environ["ERRMSG"]
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec) + "\n")
PY
  fi
}

# ── CPU / worker counts ───────────────────────────────────────────────────────
fanout_cores() {
  local n=""
  if command -v nproc >/dev/null 2>&1; then n="$(nproc 2>/dev/null)"
  elif command -v sysctl >/dev/null 2>&1; then n="$(sysctl -n hw.ncpu 2>/dev/null)"
  else n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"; fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=4
  echo "$n"
}

# fanout_default_workers <substrate>  → in-harness: min(16, cores-2); cli: cores-2
fanout_default_workers() {
  local substrate="$1" cores; cores="$(fanout_cores)"
  local n=$(( cores - 2 )); [[ "$n" -lt 1 ]] && n=1
  if [[ "$substrate" == "in-harness" && "$n" -gt 16 ]]; then n=16; fi
  echo "$n"
}

# fanout_clamp <requested> <substrate>  → clamp to the substrate ceiling, min 1
fanout_clamp() {
  local req="$1" substrate="$2"
  local ceil; ceil="$(fanout_default_workers "$substrate")"
  [[ "$req" =~ ^[0-9]+$ ]] || { echo "$ceil"; return; }
  [[ "$req" -lt 1 ]] && { echo 1; return; }
  [[ "$req" -gt "$ceil" ]] && { echo "$ceil"; return; }
  echo "$req"
}

# ── Substrate detection ───────────────────────────────────────────────────────
# fanout_detect_substrate <override> <cli_bin>
# Precedence: explicit override → harness signal (SPECKIT_FANOUT_INHARNESS=1)
#             → CLI availability (command -v) → sequential.
fanout_detect_substrate() {
  local override="${1:-auto}" cli_bin="${2:-}"
  case "$override" in
    in-harness|cli|sequential) echo "$override"; return 0 ;;
  esac
  if [[ "${SPECKIT_FANOUT_INHARNESS:-}" == "1" ]]; then echo "in-harness"; return 0; fi
  local b
  for b in "$cli_bin" copilot claude gemini codex; do
    [[ -n "$b" ]] && command -v "$b" >/dev/null 2>&1 && { echo "cli"; return 0; }
  done
  echo "sequential"
}

# ── Bounded worker-slot pool (manual timeout + circuit breaker) ────────────────
# The caller defines a function:  fanout_dispatch_one <portion_id>
#   - runs the worker (writes its own result file), returns 0 on success.
#
# fanout_run_pool <max_slots> <timeout_s> <metrics_file> <run_id> <substrate> \
#                 <cb_max> <portion_id...>
# Sets globals: FANOUT_OK_COUNT FANOUT_FAIL_COUNT FANOUT_TIMEOUT_COUNT
# Returns: 0 normally; 3 if the circuit breaker tripped.
fanout_run_pool() {
  local max_slots="$1" timeout_s="$2" mf="$3" run_id="$4" substrate="$5" cb_max="$6"
  shift 6
  local queue=("$@")
  [[ "$max_slots" -lt 1 ]] && max_slots=1

  FANOUT_OK_COUNT=0; FANOUT_FAIL_COUNT=0; FANOUT_TIMEOUT_COUNT=0
  local consec_fail=0 broke=0 qi=0 qn=${#queue[@]}
  local a_pid=() a_start=() a_portion=()   # parallel arrays of active workers

  while :; do
    # launch while slots free and queue has work and breaker not tripped
    while [[ "$broke" -eq 0 && "${#a_pid[@]}" -lt "$max_slots" && "$qi" -lt "$qn" ]]; do
      local pid_name="${queue[$qi]}"; qi=$(( qi + 1 ))
      fanout_telemetry "$mf" dispatch "$run_id" "$pid_name" "$substrate"
      ( fanout_dispatch_one "$pid_name" ) &
      local bgpid=$!
      a_pid+=("$bgpid"); a_start+=("$(fanout_now_s)"); a_portion+=("$pid_name")
    done

    [[ "${#a_pid[@]}" -eq 0 ]] && break   # nothing running; done (or broke)

    sleep 1
    local now; now="$(fanout_now_s)"
    local keep_pid=() keep_start=() keep_portion=() i=0
    while [[ "$i" -lt "${#a_pid[@]}" ]]; do
      local p="${a_pid[$i]}" st="${a_start[$i]}" por="${a_portion[$i]}"
      if ! kill -0 "$p" 2>/dev/null; then
        wait "$p"; local rc=$?
        local dur=$(( (now - st) * 1000 ))
        if [[ "$rc" -eq 0 ]]; then
          FANOUT_OK_COUNT=$(( FANOUT_OK_COUNT + 1 )); consec_fail=0
          fanout_telemetry "$mf" complete "$run_id" "$por" "$substrate" "$dur"
        else
          FANOUT_FAIL_COUNT=$(( FANOUT_FAIL_COUNT + 1 )); consec_fail=$(( consec_fail + 1 ))
          fanout_telemetry "$mf" fail "$run_id" "$por" "$substrate" "$dur" "exit $rc"
        fi
      elif [[ "$timeout_s" -gt 0 && $(( now - st )) -ge "$timeout_s" ]]; then
        kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null
        FANOUT_TIMEOUT_COUNT=$(( FANOUT_TIMEOUT_COUNT + 1 )); consec_fail=$(( consec_fail + 1 ))
        local dur=$(( (now - st) * 1000 ))
        fanout_telemetry "$mf" timeout "$run_id" "$por" "$substrate" "$dur" "timeout ${timeout_s}s"
        fanout_warn "worker timed out on portion $por (${timeout_s}s)"
      else
        keep_pid+=("$p"); keep_start+=("$st"); keep_portion+=("$por")
      fi
      i=$(( i + 1 ))
    done
    a_pid=("${keep_pid[@]}"); a_start=("${keep_start[@]}"); a_portion=("${keep_portion[@]}")

    if [[ "$cb_max" -gt 0 && "$consec_fail" -ge "$cb_max" ]]; then
      broke=1
      fanout_err "circuit breaker: $consec_fail consecutive worker failures — aborting remaining dispatch"
      local q
      for q in "${a_pid[@]}"; do kill -TERM "$q" 2>/dev/null; done
    fi
  done

  [[ "$broke" -eq 1 ]] && return 3
  return 0
}
