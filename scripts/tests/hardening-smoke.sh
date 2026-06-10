#!/usr/bin/env bash
# =============================================================================
# hardening-smoke.sh — hermetic smoke checks for feature 003 (autonomy &
# reliability hardening). Each check runs pro-report.sh & friends against a
# private temp metrics dir (SPECKIT_PRO_METRICS_DIR) — real telemetry is never
# touched. Prints one PASS/FAIL line per check; exits non-zero on any FAIL.
#
# bash 3.2 compatible. Usage:
#   bash scripts/tests/hardening-smoke.sh            # run all checks
#   bash scripts/tests/hardening-smoke.sh --selftest # include a failing fixture
# =============================================================================
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPORT="$ROOT/scripts/bash/pro-report.sh"
PASS_N=0; FAIL_N=0; FAILED=""

# Each check gets a fresh temp metrics dir; trap-free cleanup at the end.
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/hardening-smoke.XXXXXX")"
cleanup() { rm -rf "$TMP_BASE" 2>/dev/null; }

new_metrics_dir() {
  local d="$TMP_BASE/m$$RANDOM$1"
  mkdir -p "$d/runs"
  echo "$d"
}

result() { # result <name> <0|1 ok>
  if [[ "$2" -eq 0 ]]; then
    printf 'PASS %s\n' "$1"; PASS_N=$(( PASS_N + 1 ))
  else
    printf 'FAIL %s\n' "$1"; FAIL_N=$(( FAIL_N + 1 )); FAILED="$FAILED $1"
  fi
}

# ── Sprint 1 — contract rows 1.0–1.3 ─────────────────────────────────────────

check_single_run_baseline() { # row 1.0
  local M; M="$(new_metrics_dir base)"
  local rid
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" phase start "$rid" smoke-phase >/dev/null 2>&1 || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" phase stop  "$rid" smoke-phase >/dev/null 2>&1 || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" call "$rid" --phase smoke-phase --status complete --turns 1 >/dev/null 2>&1 || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$rid" --no-stdout >/dev/null 2>&1 || return 1
  python3 - "$M/runs/$rid.json" "$M/runs.jsonl" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert len(m.get("phases", [])) == 2, "expected 2 phase markers"
assert len(m.get("calls", []))  == 1, "expected 1 call entry"
lines = [l for l in open(sys.argv[2]).read().splitlines() if l.strip()]
assert len(lines) == 1 and json.loads(lines[0]).get("run_id"), "runs.jsonl must hold 1 parseable line"
PY
}

check_concurrent_manifest() { # row 1.1
  local M; M="$(new_metrics_dir conc)"
  local rid i
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  for i in 1 2 3 4 5 6 7 8; do
    SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" phase start "$rid" "p$i" >/dev/null 2>&1 &
  done
  wait
  python3 - "$M/runs/$rid.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
got = len(m.get("phases", []))
assert got == 8, "expected 8 phase events after concurrent writers, got %d" % got
PY
}

check_lifecycle_status() { # row 1.2
  local M; M="$(new_metrics_dir life)"
  local rid st
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  st="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$M/runs/$rid.json")"
  [[ "$st" == "open" ]] || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$rid" --no-stdout >/dev/null 2>&1 || return 1
  st="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$M/runs/$rid.json")"
  [[ "$st" == "finished" ]] || return 1
  # Legacy tolerance: a status-less manifest must not crash aggregate.
  printf '{"run_id":"legacy-x","started_at":"2026-01-01T00:00:00Z"}\n' > "$M/runs/legacy-x.json"
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" aggregate --last 3 >/dev/null 2>&1
}

check_current_pointer() { # row 1.3
  local M; M="$(new_metrics_dir cur)"
  local r1 r2 cur s1 s2
  r1="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  r2="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  cur="$(cat "$M/runs/.current")"
  [[ "$cur" == "$r2" ]] || return 1
  # Explicit --run-id must win over a stale/other .current.
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$r1" --no-stdout >/dev/null 2>&1 || return 1
  s1="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$M/runs/$r1.json")"
  s2="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$M/runs/$r2.json")"
  [[ "$s1" == "finished" ]] || return 1
  [[ "$s2" != "finished" ]] || return 1
  [[ "$(cat "$M/runs/.current")" == "$r2" ]] || return 1
}

# ── Sprint 2 — US1 resume (contract rows 2.0–2.4) ───────────────────────────

check_orphan_sweep() { # rows 2.0 + 2.1
  local M; M="$(new_metrics_dir orph)"
  local r1 r2 r3
  r1="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" phase start "$r1" partial-work >/dev/null 2>&1
  r2="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1   # leaves r1 open → swept
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$r2" --no-stdout >/dev/null 2>&1
  printf '{"run_id":"legacy-y","started_at":"2026-01-01T00:00:00Z"}\n' > "$M/runs/legacy-y.json"
  r3="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1   # sweeps nothing open except none
  python3 - "$M/runs/$r1.json" "$M/runs/$r2.json" "$M/runs/legacy-y.json" "$r2" <<'PY'
import json, sys
r1 = json.load(open(sys.argv[1]))
assert r1.get("status") == "interrupted", "open run must be swept to interrupted"
assert r1.get("interrupted_by") == sys.argv[4], "interrupted_by must name the sweeping run"
assert r1.get("interrupted_at"), "interrupted_at must be set"
assert len(r1.get("phases", [])) == 1, "partial data (phases[]) must be preserved"
r2 = json.load(open(sys.argv[2]))
assert r2.get("status") == "finished", "finished run must NOT be re-swept"
legacy = json.load(open(sys.argv[3]))
assert "status" not in legacy, "legacy status-less manifest must be left untouched"
PY
}

check_pending_adoption() { # row 2.2
  local M; M="$(new_metrics_dir pend)"
  mkdir -p "$M/runs"
  printf '{"ts":"2026-06-10T00:00:00Z","capability":"local-prep","reason_class":"environment-unavailable","detail":"pre-run"}\n' > "$M/runs/pending-skips.jsonl"
  printf 'NOT-JSON\n' >> "$M/runs/pending-skips.jsonl"
  local rid
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  [[ ! -f "$M/runs/pending-skips.jsonl" ]] || return 1   # spool must be cleared
  python3 - "$M/runs/$rid.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sk = m.get("skips", [])
assert len(sk) == 1 and sk[0]["capability"] == "local-prep", "valid pending skip must be adopted; malformed dropped"
PY
}

check_resume_detector() { # rows 2.3 + 2.4
  local DET="$ROOT/scripts/bash/pro-resume-detect.sh"
  local F="$TMP_BASE/detect-repo"
  rm -rf "$F"; mkdir -p "$F/specs/009-fixture" "$F/.knowledge/features/009-fixture/contracts"
  ( cd "$F" && git init -q . )
  local out
  expect_phase() { # expect_phase <expected>
    out="$(cd "$F" && bash "$DET" --feature 009-fixture --max-iterations 20)"
    printf '%s\n' "$out" | grep -q "^PHASE=$1$"
  }
  expect_phase none || return 1
  touch "$F/specs/009-fixture/spec.md";  expect_phase spec-only  || return 1
  touch "$F/specs/009-fixture/plan.md";  expect_phase plan-only  || return 1
  rmdir "$F/.knowledge/features/009-fixture/contracts" 2>/dev/null
  printf -- '- [ ] T001 a\n- [ ] T002 b\n' > "$F/specs/009-fixture/tasks.md"
  expect_phase tasks-only || return 1
  mkdir -p "$F/.knowledge/features/009-fixture/contracts"
  touch "$F/.knowledge/features/009-fixture/contracts/sprint-1.md"
  expect_phase contracts-ready || return 1
  printf '## Iteration 7 — ts\nstuff\n' > "$F/.knowledge/features/009-fixture/progress.md"
  out="$(cd "$F" && bash "$DET" --feature 009-fixture --max-iterations 20)"
  printf '%s\n' "$out" | grep -q '^PHASE=in-loop$'   || return 1
  printf '%s\n' "$out" | grep -q '^ITER_LAST=7$'     || return 1
  printf '%s\n' "$out" | grep -q '^REMAINING=13$'    || return 1
  printf -- '- [x] T001 a\n- [x] T002 b\n' > "$F/specs/009-fixture/tasks.md"
  expect_phase complete || return 1
  # row 2.4: stale handoff naming another feature → WARNING, phase unchanged
  printf -- '- [ ] T001 a\n' > "$F/specs/009-fixture/tasks.md"
  printf 'Feature: 002-other-thing context\n' > "$F/specs/009-fixture/handoff.md"
  out="$(cd "$F" && bash "$DET" --feature 009-fixture --max-iterations 20)"
  printf '%s\n' "$out" | grep -q '^WARNING=.*002-other-thing' || return 1
  printf '%s\n' "$out" | grep -q '^PHASE=in-loop$' || return 1
}

# ── Sprint 3 — US2 skip events (contract rows 3.0–3.5) ──────────────────────

check_skip_events() { # rows 3.0 + 3.2
  local M; M="$(new_metrics_dir skev)"
  local rid
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" event skip "$rid" local-prep 4b disabled-by-config "k=false" >/dev/null 2>&1 || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" event skip "-" local-prep 4b environment-unavailable "ollama down" >/dev/null 2>&1 || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" event decision "-" phase_gate continue "unattended default" >/dev/null 2>&1 || return 1
  python3 - "$M/runs/$rid.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
classes = [s["reason_class"] for s in m.get("skips", [])]
assert classes == ["disabled-by-config", "environment-unavailable"], classes
for s in m["skips"]:
    assert set(s.keys()) <= {"ts","capability","phase","reason_class","detail","run_id"}, s.keys()
    assert s["ts"] and s["capability"], "schema fields required"
assert m.get("decisions") and m["decisions"][0]["gate"] == "phase_gate", "decision recorded"
PY
  [[ $? -eq 0 ]] || return 1
  # row 3.2 tail: no manifest AND no .current → spool, never lost
  local M2; M2="$(new_metrics_dir skev2)"
  SPECKIT_PRO_METRICS_DIR="$M2" bash "$REPORT" event skip "-" early-cap 0 error "pre-run" >/dev/null 2>&1 || return 1
  grep -q '"capability": "early-cap"' "$M2/runs/pending-skips.jsonl"
}

check_skip_render() { # row 3.3
  local M; M="$(new_metrics_dir skrd)"
  local rid
  rid="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$rid" --no-stdout >/dev/null 2>&1 || return 1
  grep -q '_none — every enabled capability ran._' "$M/run-report.md" || return 1
  local rid2
  rid2="$(SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" start 2>/dev/null)" || return 1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" event skip "$rid2" materialize 4b environment-unavailable "148 UNKNOWN markers" >/dev/null 2>&1
  SPECKIT_PRO_METRICS_DIR="$M" bash "$REPORT" finish --run-id "$rid2" --no-stdout >/dev/null 2>&1 || return 1
  grep -q '| materialize | 4b | environment-unavailable |' "$M/run-report.md" || return 1
  python3 - "$M/runs.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows[-1]["skip_count"] == 1 and rows[-2]["skip_count"] == 0, (rows[-2].get("skip_count"), rows[-1].get("skip_count"))
PY
}

check_unknown_counter() { # row 3.4
  local D="$TMP_BASE/unk"
  rm -rf "$D"; mkdir -p "$D"
  printf '# P1\n- UNKNOWN\n  - UNKNOWN  \ntext about UNKNOWN things\n- UNKNOWNx\n' > "$D/a.md"
  printf '# P2\nall good\n' > "$D/b.md"
  local out
  out="$(. "$ROOT/scripts/bash/lib/pro-local-common.sh" 2>/dev/null; local_count_unknown_markers "$D")" || return 1
  [[ "$out" == "2 1 2" ]]
}

check_checkpoint_patterns() { # row 3.5 (static assertions)
  local F="$ROOT/scripts/bash/pro-orchestrate.sh"
  ! grep -q 'git add \. 2>/dev/null || true' "$F" || return 1
  grep -q ":(exclude)specs" "$F" || return 1
  grep -q ":(exclude).knowledge/features" "$F" || return 1
  grep -q ":(exclude).knowledge/metrics" "$F" || return 1
}

# ── Harness self-test (contract row 1.4) ─────────────────────────────────────
check_failing_fixture() { return 1; }   # only registered under --selftest

check_harness_selftest() {
  local out rc=0
  out="$(bash "$0" --selftest 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || return 1
  printf '%s\n' "$out" | grep -q '^FAIL selftest-fixture$' || return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────
SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

result single-run-baseline   "$(check_single_run_baseline >/dev/null 2>&1; echo $?)"
result concurrent-manifest   "$(check_concurrent_manifest >/dev/null 2>&1; echo $?)"
result lifecycle-status      "$(check_lifecycle_status    >/dev/null 2>&1; echo $?)"
result current-pointer       "$(check_current_pointer     >/dev/null 2>&1; echo $?)"
result orphan-sweep          "$(check_orphan_sweep        >/dev/null 2>&1; echo $?)"
result pending-adoption      "$(check_pending_adoption    >/dev/null 2>&1; echo $?)"
result resume-detector       "$(check_resume_detector     >/dev/null 2>&1; echo $?)"
result skip-events           "$(check_skip_events         >/dev/null 2>&1; echo $?)"
result skip-render           "$(check_skip_render         >/dev/null 2>&1; echo $?)"
result unknown-counter       "$(check_unknown_counter     >/dev/null 2>&1; echo $?)"
result checkpoint-patterns   "$(check_checkpoint_patterns >/dev/null 2>&1; echo $?)"
if [[ "$SELFTEST" -eq 1 ]]; then
  result selftest-fixture    "$(check_failing_fixture     >/dev/null 2>&1; echo $?)"
else
  result harness-selftest    "$(check_harness_selftest    >/dev/null 2>&1; echo $?)"
fi

cleanup
printf -- '── %d passed, %d failed%s ──\n' "$PASS_N" "$FAIL_N" "${FAILED:+ (${FAILED# })}"
[[ "$FAIL_N" -eq 0 ]]
