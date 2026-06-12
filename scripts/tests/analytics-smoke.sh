#!/usr/bin/env bash
# =============================================================================
# analytics-smoke.sh — hermetic checks for pro-analytics.sh export / import.
#
# The cross-repo insights loop: `export` must produce one portable, valid
# bundle (analytics + failures + improvements-ledger learnings) from any repo;
# `import` must roll up bundles from many repos and feed learnings into the
# local improvements ledger as deduped status:proposed entries.
#
# Each check runs in a private sandbox (own git repo, .knowledge/ tree); the
# real repo and telemetry are never touched. Prints one PASS/FAIL line per
# check; exits non-zero on any FAIL.
#
# bash 3.2 compatible. Usage:
#   bash scripts/tests/analytics-smoke.sh
# =============================================================================
set -uo pipefail

# Hermeticity: SPECKIT_PRO_* overrides (METRICS_DIR above all) would leak into
# every sandboxed invocation and redirect writes OUTSIDE the sandbox.
while IFS='=' read -r _v _; do
  case "$_v" in SPECKIT_PRO_*) unset "$_v" ;; esac
done < <(env)

# Resolve the script under test relative to THIS file, not the git toplevel —
# in an installed consumer repo the toplevel is the consumer root, and the
# suite ships as a consumer-runnable post-install self-check.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANALYTICS="$ROOT/scripts/bash/pro-analytics.sh"
PASS_N=0; FAIL_N=0; FAILED=""

TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/analytics-smoke.XXXXXX")"
cleanup() { rm -rf "$TMP_BASE" 2>/dev/null; }
trap cleanup EXIT

result() { # result <name> <0|1 ok>
  if [[ "$2" -eq 0 ]]; then
    printf 'PASS %s\n' "$1"; PASS_N=$(( PASS_N + 1 ))
  else
    printf 'FAIL %s\n' "$1"; FAIL_N=$(( FAIL_N + 1 )); FAILED="$FAILED $1"
  fi
}

# make_repo <dir> <feature-slug> — sandbox repo with telemetry + a 1-entry ledger.
make_repo() {
  local dir="$1" feat="$2"
  mkdir -p "$dir/.knowledge/metrics"
  ( cd "$dir" && git init -q . )
  printf '{"run_id":"r1","feature":"%s","eval_verdict":"PASS","eval_score":85,"iterations":3,"tasks_done":5,"tasks_total":5,"duration_s":600,"total_cost_usd":2.5}\n{"run_id":"r2","feature":"%s","eval_verdict":"FAIL","eval_score":55,"iterations":5,"tasks_done":2,"tasks_total":5,"duration_s":900,"total_cost_usd":3.0}\n' \
    "$feat" "$feat" > "$dir/.knowledge/metrics/runs.jsonl"
  printf '{"ts":"2026-06-11T01:00:00Z","event":"circuit_breaker","feature":"%s","iteration":4,"detail":"3 consecutive errors in /private/path"}\n' \
    "$feat" > "$dir/.knowledge/metrics/notifications.jsonl"
  printf '# Ledger\n\n## Promoted\n\n## Proposed\n\n- [2026-06-11] (%s) status: proposed **Lesson from %s.**\n  Why: because.\n  Apply: do the thing.\n  Evidence: run-r1.  Promoted-by: —  Disproven-by: —\n' \
    "$feat" "$feat" > "$dir/.knowledge/improvements.md"
}

# fresh_ledger <dir> — minimal target ledger matching the shipped template shape.
fresh_ledger() {
  printf '# SpecKit Pro — Improvements Ledger\n\n## Promoted (applied at Phase 0)\n\n## Proposed (awaiting human promotion)\n\n<!-- Phase 8 appends here. -->\n' \
    > "$1/.knowledge/improvements.md"
}

# ─── export ───────────────────────────────────────────────────────────────────

check_export_bundle_valid() {
  local d="$TMP_BASE/exp-valid"; make_repo "$d" "feat-a"
  ( cd "$d" && bash "$ANALYTICS" export --stdout ) 2>/dev/null | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert b["schema"] == "speckit-pro/insights-bundle"
assert b["schema_version"] == 1
assert b["generated_at"]
assert b["source"]["repo"]
assert b["window"]["runs"] == 2
assert "feat-a" in b["analytics"]["features"]
assert isinstance(b["analytics"]["health"]["score"], (int, float))
assert b["analytics"]["taxonomy"].get("circuit_breaker") == 1
assert len(b["failures"]) == 1 and b["failures"][0]["event"] == "circuit_breaker"
assert len(b["learnings"]["proposed"]) == 1
' 2>/dev/null
}

check_export_writes_default_file() {
  local d="$TMP_BASE/exp-file"; make_repo "$d" "feat-b"
  ( cd "$d" && bash "$ANALYTICS" export ) >/dev/null 2>&1
  local f
  f=$(ls "$d"/.knowledge/metrics/insights-*.json 2>/dev/null | head -1)
  [[ -n "$f" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null
}

check_export_anonymize() {
  local d="$TMP_BASE/exp-anon"; make_repo "$d" "secret-feature"
  local out
  out=$( cd "$d" && bash "$ANALYTICS" export --stdout --anonymize 2>/dev/null )
  # repo dir name and feature name must not appear in metrics; failures lose detail
  ! printf '%s' "$out" | grep -q "exp-anon" || return 1
  echo "$out" | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert b["source"]["anonymized"] is True
assert b["source"]["branch"] is None
assert all("secret-feature" not in f for f in b["analytics"]["features"])
assert all("detail" not in row for row in b["failures"])
' 2>/dev/null
}

check_export_learnings_only() {
  # No telemetry at all — export still succeeds on the strength of the ledger.
  local d="$TMP_BASE/exp-ledger-only"
  mkdir -p "$d/.knowledge"
  ( cd "$d" && git init -q . )
  printf '# Ledger\n\n## Proposed\n\n- [2026-06-11] (x) status: proposed **Ledger-only lesson.**\n  Why: w.\n' \
    > "$d/.knowledge/improvements.md"
  ( cd "$d" && bash "$ANALYTICS" export --stdout ) 2>/dev/null | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert b["window"]["runs"] == 0
assert len(b["learnings"]["proposed"]) == 1
' 2>/dev/null
}

# ─── import ───────────────────────────────────────────────────────────────────

setup_two_bundles() { # writes $TMP_BASE/bundle-{alpha,beta}.json once
  [[ -f "$TMP_BASE/bundle-alpha.json" ]] && return 0
  local r d
  for r in alpha beta; do
    d="$TMP_BASE/src-$r"; make_repo "$d" "feat-$r"
    ( cd "$d" && bash "$ANALYTICS" export --out "$TMP_BASE/bundle-$r.json" ) >/dev/null 2>&1
  done
  [[ -f "$TMP_BASE/bundle-alpha.json" && -f "$TMP_BASE/bundle-beta.json" ]]
}

check_import_rollup() {
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-rollup"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  local out
  out=$( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-alpha.json" "$TMP_BASE/bundle-beta.json" 2>/dev/null )
  printf '%s' "$out" | grep -q "2 bundles" &&
  printf '%s' "$out" | grep -q "circuit_breaker" &&
  printf '%s' "$out" | grep -q "across 2 repos" &&
  printf '%s' "$out" | grep -q "Collected learnings (2)"
}

check_import_json() {
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-json"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-alpha.json" "$TMP_BASE/bundle-beta.json" --json ) 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["bundles"] == 2 and len(r["sources"]) == 2
assert r["taxonomy"]["circuit_breaker"] == {"total": 2, "repos": 2}
assert len(r["learnings"]) == 2
' 2>/dev/null
}

check_import_to_ledger_appends() {
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-ledger"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  fresh_ledger "$d"
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-alpha.json" "$TMP_BASE/bundle-beta.json" --to-ledger ) >/dev/null 2>&1
  grep -q "Lesson from feat-alpha" "$d/.knowledge/improvements.md" &&
  grep -q "Lesson from feat-beta"  "$d/.knowledge/improvements.md" &&
  grep -q "Imported-from:"         "$d/.knowledge/improvements.md" &&
  # entries must land in ## Proposed, never ## Promoted
  ! sed -n '/## Promoted/,/## Proposed/p' "$d/.knowledge/improvements.md" | grep -q "Lesson from"
}

check_import_to_ledger_dedupes() {
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-dedupe"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  fresh_ledger "$d"
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-alpha.json" --to-ledger ) >/dev/null 2>&1
  local out n
  out=$( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-alpha.json" --to-ledger 2>/dev/null )
  printf '%s' "$out" | grep -q "appended 0 entries" || return 1
  n=$(grep -c "Lesson from feat-alpha" "$d/.knowledge/improvements.md")
  [[ "$n" -eq 1 ]]
}

check_import_invalid_handling() {
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-invalid"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  echo "not json" > "$TMP_BASE/garbage.json"
  # mixed valid+invalid → succeeds on the valid one
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/garbage.json" "$TMP_BASE/bundle-alpha.json" ) >/dev/null 2>&1 || return 1
  # only invalid → exit 1
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/garbage.json" ) >/dev/null 2>&1 && return 1
  # no files at all → exit 1 with usage hint
  ( cd "$d" && bash "$ANALYTICS" import ) >/dev/null 2>&1 && return 1
  return 0
}

check_flag_value_validation() {
  # A value-taking flag with no/bad value must ERROR, never hang (a bare
  # `shift 2` with one arg left is a non-consuming no-op → infinite loop) and
  # never silently pass (a typo'd --gate is a dead cron alarm).
  local d="$TMP_BASE/flag-val"; make_repo "$d" "feat-v"
  ( cd "$d" && bash "$ANALYTICS" health --gate ) >/dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt 50 ]]; do sleep 0.1; i=$(( i + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; fi
  wait "$pid" 2>/dev/null; [[ $? -ne 0 ]] || return 1
  ( cd "$d" && bash "$ANALYTICS" health --gate abc )   >/dev/null 2>&1 && return 1
  ( cd "$d" && bash "$ANALYTICS" summary --last abc )  >/dev/null 2>&1 && return 1
  ( cd "$d" && bash "$ANALYTICS" health --gate 50 )    >/dev/null 2>&1 || return 1
  return 0
}

check_import_malformed_nested() {
  # Wrong-TYPED nested fields (not just missing) must skip that bundle loudly
  # and never abort the batch or half-merge it.
  setup_two_bundles || return 1
  local d="$TMP_BASE/imp-nested"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  printf '{"schema":"speckit-pro/insights-bundle","schema_version":1,"analytics":"oops"}\n' > "$TMP_BASE/bad-nested.json"
  printf '{"schema":"speckit-pro/insights-bundle","schema_version":1,"learnings":{"proposed":"a string, not a list"}}\n' > "$TMP_BASE/bad-learn.json"
  local out
  out=$( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bad-nested.json" "$TMP_BASE/bad-learn.json" "$TMP_BASE/bundle-alpha.json" --json 2>/dev/null ) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["bundles"] == 1 and len(r["sources"]) == 1
assert all(len(l["entry"]) > 1 for l in r["learnings"])  # never per-character garbage
' 2>/dev/null || return 1
  # all-malformed → exit 1
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bad-nested.json" ) >/dev/null 2>&1 && return 1
  return 0
}

check_to_ledger_no_bold_dedupe() {
  # Entries WITHOUT a bold **title** must still dedupe across re-imports.
  local d="$TMP_BASE/imp-nobold"; mkdir -p "$d/.knowledge"; ( cd "$d" && git init -q . )
  fresh_ledger "$d"
  printf '{"schema":"speckit-pro/insights-bundle","schema_version":1,"generated_at":"2026-06-12T00:00:00Z","source":{"repo":"nb"},"learnings":{"proposed":["- [2026-06-11] (nb) status: proposed plain lesson without bold title.\\n  Why: w."]}}\n' > "$TMP_BASE/bundle-nobold.json"
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-nobold.json" --to-ledger ) >/dev/null 2>&1
  ( cd "$d" && bash "$ANALYTICS" import "$TMP_BASE/bundle-nobold.json" --to-ledger ) >/dev/null 2>&1
  local n
  n=$(grep -c "plain lesson without bold title" "$d/.knowledge/improvements.md")
  [[ "$n" -eq 1 ]]
}

check_anonymize_unmatched_filter() {
  # --anonymize with a --feature filter that matches nothing must still mask it.
  local d="$TMP_BASE/anon-filter"; make_repo "$d" "feat-x"
  ( cd "$d" && bash "$ANALYTICS" export --stdout --anonymize --feature secret-name 2>/dev/null ) \
    | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert "secret-name" not in json.dumps(b)
' 2>/dev/null
}

# ─── Run ──────────────────────────────────────────────────────────────────────

check_export_bundle_valid;         result export-bundle-valid $?
check_export_writes_default_file;  result export-writes-default-file $?
check_export_anonymize;            result export-anonymize-masks-identity $?
check_export_learnings_only;       result export-learnings-only $?
check_import_rollup;               result import-cross-repo-rollup $?
check_import_json;                 result import-json-valid $?
check_import_to_ledger_appends;    result import-to-ledger-appends $?
check_import_to_ledger_dedupes;    result import-to-ledger-dedupes $?
check_import_invalid_handling;     result import-invalid-handling $?
check_flag_value_validation;       result flag-value-validation $?
check_import_malformed_nested;     result import-malformed-nested-skipped $?
check_to_ledger_no_bold_dedupe;    result to-ledger-no-bold-dedupe $?
check_anonymize_unmatched_filter;  result anonymize-unmatched-filter $?

echo ""
echo "analytics-smoke: $PASS_N passed, $FAIL_N failed${FAILED:+ —$FAILED}"
[[ "$FAIL_N" -eq 0 ]]
