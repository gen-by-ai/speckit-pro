#!/usr/bin/env bash
# Browser test — Sprint Contract row {{ROW_ID}}
# Feature: {{FEATURE_NAME}} | User flow: {{USER_FLOW}} | State: {{STATE}}
# Severity: {{SEVERITY}}
#
# This script is a durable, replayable acceptance probe written by the loop and
# executed by the evaluator. It runs the live app via agent-browser, exercises
# one contract row, and exits 0 (PASS) or non-zero (FAIL with reason on stderr).
#
# Conventions:
#   - Always idempotent: a re-run on a stable build must produce the same verdict
#   - Hermetic setup: never depend on global browser state — clear cookies/storage
#   - Time-boxed: no step waits longer than 10s; explicit timeouts only
#   - One assertion focus: each script asserts ONE contract row, not many
#   - Exit codes: 0 = PASS, 1 = FAIL (test assertion), 2 = ERROR (app/infra problem)
#
# The full suite (this and siblings) is invoked by the evaluator with:
#     for f in <feature>/browser-tests/**/*.sh; do bash "$f" || exit 1; done

set -e
set -o pipefail

APP_URL="${APP_URL:-http://localhost:3000}"
TEST_NAME="$(basename "$0" .sh)"

fail() { echo "FAIL [${TEST_NAME}]: $*" >&2; exit 1; }
err()  { echo "ERROR [${TEST_NAME}]: $*" >&2; exit 2; }
pass() { echo "PASS [${TEST_NAME}]"; exit 0; }

# ─── Setup: hermetic browser state ────────────────────────────────────────────
# Open the target page, then clear any persistent state so this script does not
# depend on what ran before it.

agent-browser open "${APP_URL}{{TARGET_PATH}}" || err "could not open app — is it running?"
agent-browser eval "localStorage.clear(); sessionStorage.clear(); document.cookie.split(';').forEach(c => { document.cookie = c.replace(/^ +/, '').replace(/=.*/, '=;expires=' + new Date().toUTCString() + ';path=/'); })"

# ─── State preparation: put the app into the state this row tests ─────────────
# Examples by state-type:
#
#   Happy path:        (nothing — fresh open is the happy path)
#
#   Empty store:       (already done above by sessionStorage.clear())
#
#   Invalid URL param: agent-browser open "${APP_URL}/policy/NOT-A-NUMBER"
#
#   Logged out:        agent-browser eval "fetch('/api/auth/logout',{method:'POST'})"
#                      agent-browser reload
#
#   Network slow:      agent-browser eval "/* override fetch with 5s delay */"
#
#   BE error:          (point at a fixture that returns 500, or use a request
#                       interceptor — see agent-browser docs for cdp.interceptRequest)

# {{STATE_PREPARATION_BLOCK}}

# ─── Assertions: verify the user-visible behavior the contract row promises ───

# Wait for the DOM to settle. Prefer waitFor over fixed sleeps.
agent-browser wait-for "{{READY_SELECTOR}}" --timeout 5000 \
  || fail "expected element {{READY_SELECTOR}} did not appear within 5s — likely blank UI"

# Positive assertion: the surface this row covers must render non-empty content.
BODY_TEXT="$(agent-browser get text "{{ASSERT_SELECTOR}}" || true)"
[ -n "$(echo "${BODY_TEXT}" | tr -d '[:space:]')" ] \
  || fail "{{ASSERT_SELECTOR}} rendered empty — state {{STATE}} produces no UI"

# Negative assertion: the failure-mode the contract row guards against must NOT
# appear. Examples: error toast for happy path, infinite spinner for any path.
SPINNER_VISIBLE="$(agent-browser eval "!!document.querySelector('[data-testid=\"loader\"]:not([aria-hidden=\"true\"])')" || echo "false")"
[ "${SPINNER_VISIBLE}" != "true" ] \
  || fail "loader still visible after 5s — loading state never terminated (MP-1435-class bug)"

# Add row-specific assertions below. Keep each one a single grep-able fact.
# {{ADDITIONAL_ASSERTIONS}}

pass
