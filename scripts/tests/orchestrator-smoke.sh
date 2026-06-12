#!/usr/bin/env bash
# =============================================================================
# orchestrator-smoke.sh — hermetic state-machine checks for pro-orchestrate.sh.
#
# The missing test layer the v1.7 audit called for: a fake agent CLI (a script
# that emits scripted tags / mutates tasks.md / writes the status file) drives
# the orchestrator through every terminal path — completion, circuit breaker,
# UNKNOWN handling, watchdog, timeout, lockfile, resume budget, status-file
# contract, blocked journal, evaluator gates — without burning a single token.
#
# Each check runs in a private sandbox (own git repo, tasks.md, agents dir,
# metrics dir); the real repo and telemetry are never touched. Prints one
# PASS/FAIL line per check; exits non-zero on any FAIL.
#
# bash 3.2 compatible. Usage:
#   bash scripts/tests/orchestrator-smoke.sh
# =============================================================================
set -uo pipefail

# Hermeticity: leaked SPECKIT_PRO_* env overrides would skew sandboxed runs.
while IFS='=' read -r _v _; do
  case "$_v" in SPECKIT_PRO_*) unset "$_v" ;; esac
done < <(env)

# Resolve the repo root relative to THIS file, not the git toplevel — in an
# installed consumer repo the toplevel is the consumer root, and the suite
# ships as a consumer-runnable post-install self-check.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$ROOT/scripts/bash/pro-orchestrate.sh"
PASS_N=0; FAIL_N=0; FAILED=""

TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/orch-smoke.XXXXXX")"
cleanup() { rm -rf "$TMP_BASE" 2>/dev/null; }

result() { # result <name> <0|1 ok>
  if [[ "$2" -eq 0 ]]; then
    printf 'PASS %s\n' "$1"; PASS_N=$(( PASS_N + 1 ))
  else
    printf 'FAIL %s\n' "$1"; FAIL_N=$(( FAIL_N + 1 )); FAILED="$FAILED $1"
  fi
}

# ─── Fake agent CLI ───────────────────────────────────────────────────────────
# Invoked by the orchestrator's generic branch as: fake-agent <agentfile> <args>.
# Pops the first line of $FAKE_SCENARIO and acts on its space-separated tokens:
#   tick        mark the first `- [ ]` in tasks.md (parsed from args) as done
#   tickall     mark every checkbox done
#   sleep=N     sleep N seconds (timeout tests)
#   exit=N      exit with code N
#   silent      emit no status tag
#   file=S[:r]  write {"status":"S","reason":"r"} to <spec-dir>/.pro-status.json
#   <SIGNAL>    emit <pro-status>SIGNAL</pro-status> (underscores → spaces;
#               evaluator calls auto-switch to the <pro-eval> tag)
mkdir -p "$TMP_BASE/bin"
cat > "$TMP_BASE/bin/fake-agent" <<'FAKE'
#!/usr/bin/env bash
set -u
agentfile="${1:-}"
args="${2:-}"

if [[ -n "${FAKE_CALL_LOG:-}" ]]; then
  printf '%s | %s\n' "$agentfile" "$args" >> "$FAKE_CALL_LOG"
fi

tasks=$(printf '%s' "$args" | tr ' ' '\n' | sed -n 's/^tasks=//p' | head -1)
spec=$(printf '%s' "$args" | tr ' ' '\n' | sed -n 's/^spec-dir=//p' | head -1)

tag="pro-status"
case "$agentfile" in *evaluate*) tag="pro-eval" ;; esac

line=""
if [[ -n "${FAKE_SCENARIO:-}" && -s "$FAKE_SCENARIO" ]]; then
  line=$(head -1 "$FAKE_SCENARIO")
  tail -n +2 "$FAKE_SCENARIO" > "$FAKE_SCENARIO.tmp" && mv "$FAKE_SCENARIO.tmp" "$FAKE_SCENARIO"
fi
[[ -z "$line" ]] && line="silent"

signal=""
rc=0
no_tag=0
for tok in $line; do
  case "$tok" in
    tick)
      if [[ -n "$tasks" && -f "$tasks" ]]; then
        awk 'done==0 && /^- \[ \]/ { sub(/^- \[ \]/, "- [x]"); done=1 } { print }' \
          "$tasks" > "$tasks.tmp" && mv "$tasks.tmp" "$tasks"
      fi
      ;;
    tickall)
      if [[ -n "$tasks" && -f "$tasks" ]]; then
        sed 's/^- \[ \]/- [x]/' "$tasks" > "$tasks.tmp" && mv "$tasks.tmp" "$tasks"
      fi
      ;;
    sleep=*) sleep "${tok#sleep=}" ;;
    exit=*)  rc="${tok#exit=}" ;;
    silent)  no_tag=1 ;;
    file=*)
      fs="${tok#file=}"
      st="${fs%%:*}"; rs=""
      [[ "$fs" == *:* ]] && rs="${fs#*:}"
      if [[ -n "$spec" ]]; then
        printf '{"status":"%s","reason":"%s"}\n' "$st" "$(printf '%s' "$rs" | tr '_' ' ')" > "$spec/.pro-status.json"
      fi
      ;;
    *) signal="$tok" ;;
  esac
done

echo "fake-agent processed: $line"
if [[ "$no_tag" -eq 0 && -n "$signal" ]]; then
  # Underscores become spaces in the REASON only — the status word itself
  # (e.g. MAX_ITERATIONS) must arrive verbatim.
  status_part="${signal%%:*}"
  reason_part=""
  [[ "$signal" == *:* ]] && reason_part="$(printf '%s' "${signal#*:}" | tr '_' ' ')"
  printf '<%s>%s%s</%s>\n' "$tag" "$status_part" "${reason_part:+:$reason_part}" "$tag"
fi
exit "$rc"
FAKE
chmod +x "$TMP_BASE/bin/fake-agent"

# ─── Sandbox builder ──────────────────────────────────────────────────────────
make_sandbox() { # make_sandbox <name> <total_tasks> [done_tasks] — echoes path
  local name="$1" total="$2" done_n="${3:-0}" S i
  S="$TMP_BASE/$name"
  mkdir -p "$S/specs/001-t" "$S/agents"
  ( cd "$S" && git init -q 2>/dev/null && git config user.email t@t.t \
    && git config user.name t && git commit -q --allow-empty -m init ) || return 1
  : > "$S/specs/001-t/tasks.md"
  i=1
  while [[ "$i" -le "$total" ]]; do
    if [[ "$i" -le "$done_n" ]]; then
      echo "- [x] T$i task" >> "$S/specs/001-t/tasks.md"
    else
      echo "- [ ] T$i task" >> "$S/specs/001-t/tasks.md"
    fi
    i=$(( i + 1 ))
  done
  printf '# fake loop agent\n' > "$S/agents/speckit.pro.loop.agent.md"
  printf '# fake evaluate agent\n' > "$S/agents/speckit.pro.evaluate.agent.md"
  : > "$S/scenario.txt"
  echo "$S"
}

scenario() { # scenario <sandbox> <line>...
  local S="$1"; shift
  local l
  : > "$S/scenario.txt"
  for l in "$@"; do echo "$l" >> "$S/scenario.txt"; done
}

ORCH_OUT=""; ORCH_RC=0
run_orch() { # run_orch <sandbox> [extra orchestrator args...]
  local S="$1"; shift
  ORCH_OUT=$(
    cd "$S" && \
    PATH="$TMP_BASE/bin:$PATH" \
    FAKE_SCENARIO="$S/scenario.txt" \
    FAKE_CALL_LOG="$S/calls.log" \
    SPECKIT_PRO_AGENTS_DIR="$S/agents" \
    SPECKIT_PRO_METRICS_DIR="$S/.knowledge/metrics" \
    bash "$ORCH" \
      --feature-name 001-t \
      --tasks-path "$S/specs/001-t/tasks.md" \
      --spec-dir "$S/specs/001-t" \
      --agent-cli fake-agent \
      --checkpoint-frequency 100 \
      "$@" 2>&1
  )
  ORCH_RC=$?
}

KDIR() { echo "$1/.knowledge/features/001-t"; }

# ─── Checks ───────────────────────────────────────────────────────────────────

check_complete_first_iteration() {
  local S; S="$(make_sandbox complete 3)" || return 1
  scenario "$S" "tickall COMPLETE"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Implementation Complete" || return 1
  grep -q '"status":"completed"' "$(KDIR "$S")/loop-state.json" || return 1
  [[ -f "$(KDIR "$S")/logs/iter-1.log" ]] || return 1
  grep -q '"event":"run_complete"' "$S/.knowledge/metrics/notifications.jsonl" || return 1
}

check_already_complete() {
  local S; S="$(make_sandbox precheck 2 2)" || return 1
  run_orch "$S"
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "already complete" || return 1
  [[ ! -s "$S/calls.log" ]] || return 1   # no agent call burned
}

check_breaker_on_errors() {
  local S; S="$(make_sandbox breaker 3)" || return 1
  scenario "$S" "ERROR:boom" "ERROR:boom" "ERROR:boom"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  grep -q '"event":"circuit_breaker"' "$S/.knowledge/metrics/notifications.jsonl" || return 1
  grep -q '"status":"circuit_breaker"' "$(KDIR "$S")/loop-state.json" || return 1
}

check_unknown_counts_toward_breaker() {
  local S; S="$(make_sandbox unknown 3)" || return 1
  scenario "$S" "silent" "silent" "silent"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "counting toward circuit breaker" || return 1
  grep -q '"status":"circuit_breaker"' "$(KDIR "$S")/loop-state.json" || return 1
}

check_watchdog_no_progress() {
  local S; S="$(make_sandbox watchdog 4)" || return 1
  scenario "$S" "CONTINUE" "CONTINUE" "CONTINUE" "CONTINUE" "CONTINUE"
  run_orch "$S" --no-progress-limit 3
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Watchdog: no task completed" || return 1
  grep -q '"event":"watchdog_no_progress"' "$S/.knowledge/metrics/notifications.jsonl" || return 1
}

check_iteration_timeout() {
  local S; S="$(make_sandbox timeout 3)" || return 1
  scenario "$S" "sleep=3 CONTINUE" "sleep=3 CONTINUE" "sleep=3 CONTINUE"
  run_orch "$S" --iteration-timeout 1
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "iteration-timeout-1s" || return 1
}

check_lock_live_refused() {
  local S; S="$(make_sandbox locklive 2)" || return 1
  mkdir -p "$(KDIR "$S")"
  printf '%s %s\n' "$$" "now" > "$(KDIR "$S")/.lock"   # our own live PID
  scenario "$S" "tickall COMPLETE"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Another orchestrator" || return 1
  [[ ! -s "$S/calls.log" ]] || return 1
}

check_lock_stale_takeover() {
  local S; S="$(make_sandbox lockstale 2)" || return 1
  mkdir -p "$(KDIR "$S")"
  printf '99999999 then\n' > "$(KDIR "$S")/.lock"       # dead PID
  scenario "$S" "tickall COMPLETE"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Stale lock" || return 1
  [[ ! -f "$(KDIR "$S")/.lock" ]] || return 1           # released on exit
}

check_resume_relative_budget() {
  local S; S="$(make_sandbox resume 4 2)" || return 1
  mkdir -p "$(KDIR "$S")"
  printf '{"iteration":5,"consecutive_failures":0,"no_progress_streak":0,"completed":2,"total":4,"status":"paused","run_id":"","updated_at":"x"}\n' \
    > "$(KDIR "$S")/loop-state.json"
  scenario "$S" "tick CONTINUE" "tickall COMPLETE"
  run_orch "$S" --resume --max-iterations 2
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Resuming from iteration 6" || return 1
  [[ -f "$(KDIR "$S")/logs/iter-6.log" && -f "$(KDIR "$S")/logs/iter-7.log" ]] || return 1
}

check_statusfile_overrides_stdout() {
  local S; S="$(make_sandbox statusfile 2)" || return 1
  scenario "$S" "tickall file=COMPLETE silent"          # no tag on stdout at all
  run_orch "$S"
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "Status-file contract" || return 1
  [[ ! -f "$S/specs/001-t/.pro-status.json" ]] || return 1   # consumed
}

check_blocked_journal_fed_back() {
  local S; S="$(make_sandbox blocked 4)" || return 1
  scenario "$S" "BLOCKED:db_locked" "tick CONTINUE" "tickall COMPLETE"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  grep -q "db locked" "$(KDIR "$S")/blocked.md" || return 1
  # iteration 2's prompt must carry the journal path
  sed -n '2p' "$S/calls.log" | grep -q "blocked-log=" || return 1
}

check_agent_max_iterations_tag() {
  local S; S="$(make_sandbox maxtag 2)" || return 1
  scenario "$S" "MAX_ITERATIONS"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "honoring its stop request" || return 1
}

check_run_iteration_budget() {
  local S; S="$(make_sandbox budget 3)" || return 1
  scenario "$S" "tick CONTINUE" "tick CONTINUE"
  run_orch "$S" --max-iterations 1
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  grep -q '"status":"paused"' "$(KDIR "$S")/loop-state.json" || return 1
  [[ "$(wc -l < "$S/calls.log" | tr -d ' ')" -eq 1 ]] || return 1   # exactly 1 iteration
}

check_doctor_mode() {
  local S; S="$(make_sandbox doctor 1)" || return 1
  local out rc=0
  out=$(
    cd "$S" && \
    PATH="$TMP_BASE/bin:$PATH" \
    SPECKIT_PRO_AGENTS_DIR="$S/agents" \
    bash "$ORCH" --doctor --agent-cli fake-agent 2>&1
  ) || rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s' "$out" | grep -q "orchestrator doctor" || return 1
  printf '%s' "$out" | grep -q "verdict: READY" || return 1
}

check_eval_invalid_verdict_hard_fails() {
  local S; S="$(make_sandbox evalbad 2)" || return 1
  scenario "$S" "tick CONTINUE" "silent"                # generator OK, evaluator emits nothing
  run_orch "$S" --enable-evaluator --max-revisions 1
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  grep -q '"event":"eval_hard_fail"' "$S/.knowledge/metrics/notifications.jsonl" || return 1
}

check_eval_malformed_score_revises() {
  local S; S="$(make_sandbox evalscore 2)" || return 1
  # gen → eval (malformed score → revision) → revision pass → eval (clean PASS) → iter2 gen completes
  scenario "$S" "tick CONTINUE" "PASS:82/100" "CONTINUE" "PASS:90" "tickall COMPLETE"
  run_orch "$S" --enable-evaluator --max-revisions 2
  [[ "$ORCH_RC" -eq 0 ]] || return 1
  printf '%s' "$ORCH_OUT" | grep -q "malformed score" || return 1
  [[ -f "$(KDIR "$S")/logs/iter-1-eval-r1.log" ]] || return 1
}

check_notifications_are_valid_json() {
  local S; S="$(make_sandbox jsonl 3)" || return 1
  scenario "$S" 'BLOCKED:weird_"quote"_and_\backslash' "ERROR:x" "ERROR:y"
  run_orch "$S"
  [[ "$ORCH_RC" -eq 1 ]] || return 1
  python3 - "$S/.knowledge/metrics/notifications.jsonl" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
assert lines, "no notification lines"
for l in lines:
    json.loads(l)
PY
}

# ─── Run ──────────────────────────────────────────────────────────────────────
echo "── orchestrator-smoke: state-machine checks (fake agent CLI) ──"
check_complete_first_iteration;       result complete-first-iteration $?
check_already_complete;               result already-complete-precheck $?
check_breaker_on_errors;              result circuit-breaker-on-errors $?
check_unknown_counts_toward_breaker;  result unknown-counts-toward-breaker $?
check_watchdog_no_progress;           result watchdog-no-progress $?
check_iteration_timeout;              result iteration-timeout $?
check_lock_live_refused;              result lock-live-refused $?
check_lock_stale_takeover;            result lock-stale-takeover $?
check_resume_relative_budget;         result resume-relative-budget $?
check_statusfile_overrides_stdout;    result statusfile-contract $?
check_blocked_journal_fed_back;       result blocked-journal-feedback $?
check_agent_max_iterations_tag;       result agent-max-iterations-tag $?
check_run_iteration_budget;           result run-iteration-budget $?
check_doctor_mode;                    result doctor-mode $?
check_eval_invalid_verdict_hard_fails; result eval-invalid-verdict-hard-fail $?
check_eval_malformed_score_revises;   result eval-malformed-score-revision $?
check_notifications_are_valid_json;   result notifications-valid-json $?

echo ""
echo "── $PASS_N passed, $FAIL_N failed ──"
[[ -n "$FAILED" ]] && echo "failed:$FAILED"
cleanup
[[ "$FAIL_N" -eq 0 ]]
