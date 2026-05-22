---
description: "Evaluate a completed sprint against its contract — strict QA review with concrete feedback for the generator"
---

# SpecKit Pro — Sprint Evaluator

This command runs a **strict QA evaluation** of a completed generator sprint. It compares the implementation against the sprint contract and produces a verdict with actionable feedback.

Inspired by the Anthropic harness pattern: separating the generator from the evaluator eliminates self-praise bias — agents cannot reliably grade their own work.

## User Input

```text
$ARGUMENTS
```

Parse from `$ARGUMENTS`:

| Argument | Required | Description |
|---|---|---|
| `feature` | yes | Feature directory name |
| `spec-dir` | yes | Absolute path to spec directory |
| `sprint` | yes | Sprint/iteration number being evaluated |
| `contract` | yes | Path to sprint contract file |
| `tasks` | yes | Path to tasks.md |
| `ai-knowledge-dir` | no | Absolute path to `.ai-knowledge/<feature>` dir (default: derived from git root) |

Derive `<ai-knowledge-dir>` the same way as the loop: `$(git rev-parse --show-toplevel)/.ai-knowledge/<feature>`.

## Evaluation Steps

### Step 1 — Calibrate Against Past Evaluations

Before scoring anything, read all files in `<ai-knowledge-dir>/evaluations/` (sorted oldest → newest). Look for:
- **Score drift**: are scores trending too high/low across sprints?
- **Recurring failures**: issues the generator keeps reintroducing (log these as higher severity this sprint)
- **Resolved issues**: things previously flagged that are now genuinely fixed

Use this to set your scoring bar. If Sprint 1 scored 72 and Sprint 2 scored 91 with no obvious quality jump, your evaluator is drifting generous — correct for it.

### Step 1b — Read drift reconciliation (if present)

If **`<FEATURE_DIR>/pro-drift.md`** exists (from `/speckit.pro.reconcile`), read the **DRIFT** rows before scoring. Known document-vs-code mismatch **without** an updated spec or contract should normally **cap** the verdict below PASS unless the drift is explicitly acceptable (document why in the evaluation). Treat reconcile output as context, not a substitute for contract criteria.

### Step 2 — Load the Sprint Contract

Read `<ai-knowledge-dir>/contracts/sprint-<N>.md`. The acceptance criteria table is the definitive definition of "done". Every CRITICAL criterion must pass for the sprint to pass.

### Step 3 — Live Browser Testing (mandatory when contract has Browser Test rows)

Boot the app:

```bash
bash <ai-knowledge-dir>/init.sh   # start the dev server
```

If the app fails to start, mark all UI/API rows as FAIL with reason `app-not-startable` and emit `<pro-eval>FAIL:app-not-startable</pro-eval>` — do not proceed to static review. A sprint that broke the app is not graded on code.

Then run the browser-test suite. **The contract's Browser Test column is the source of truth — you do not invent your own probes.** Run every script the contract lists:

```bash
SPEC_DIR=<resolved spec dir>
SUITE_LOG="${SPEC_DIR}/browser-tests/_eval-sprint-<N>.log"
mkdir -p "$(dirname "${SUITE_LOG}")"

# This-sprint scripts (referenced from this sprint's contract rows)
THIS_SPRINT_FAILED=0
while IFS= read -r script; do
  echo "──────── $(basename "${script}") ────────" | tee -a "${SUITE_LOG}"
  if bash "${script}" 2>&1 | tee -a "${SUITE_LOG}"; then
    echo "PASS: ${script}" | tee -a "${SUITE_LOG}"
  else
    echo "FAIL: ${script}" | tee -a "${SUITE_LOG}"
    THIS_SPRINT_FAILED=$((THIS_SPRINT_FAILED + 1))
  fi
done < <(awk -F'|' '/browser-tests\//{match($0, /browser-tests\/[^[:space:]\`]+\.sh/); if (RSTART) print substr($0, RSTART, RLENGTH)}' "${CONTRACT_FILE}" | sed "s|^|${SPEC_DIR}/|")
```

Any failure in this-sprint scripts → at least NEEDS_REVISION. Any failure of a CRITICAL row → outright FAIL unless the row is in the contract's Edge-Case Waivers section.

### Step 3b — Regression Carry-Forward (mandatory)

Run **every** browser-test script from previous sprints, not just this one's. A sprint that breaks earlier sprints' tests has regressed the feature even if its own contract is satisfied.

```bash
REGRESSED=0
shopt -s globstar nullglob
for script in "${SPEC_DIR}"/browser-tests/**/*.sh; do
  [ "$(basename "${script}")" = "_template.sh" ] && continue
  if ! bash "${script}" >> "${SUITE_LOG}" 2>&1; then
    echo "REGRESSION: ${script}" | tee -a "${SUITE_LOG}"
    REGRESSED=$((REGRESSED + 1))
  fi
done
```

If `REGRESSED > 0`, the verdict is at minimum NEEDS_REVISION with reason `regression-carryforward-failed`. The generator must fix the regression before the sprint can pass, even if its own work is otherwise correct.

This is the structural fix for the MP-1435 class of bug: a future sprint cannot silently re-break a behavior that an earlier sprint asserted.

### Step 4 — Static Code Review

Read the actual code files changed this sprint (check `git diff HEAD~1` or the handoff.md file list). Verify:
- Edge cases and error paths (not just happy path)
- Security issues: SQL injection, XSS, hardcoded secrets, broken auth
- Broken imports or wiring
- Branch-symmetry: for every new branch in the diff (every new `if`, `?:`, `&&` short-circuit, early `return`), confirm the contract has a Browser Test row asserting that branch's behavior. Missing row = NEEDS_REVISION with reason `unrostered-branch:<file>:<line>`.

### Step 4a — Stub & No-op Detection (auto-FAIL)

Run these greps against every file in the sprint diff. **Any match in a file the contract claims to have implemented is an automatic FAIL** — no scoring discretion, no "but it mostly works." The sprint reverts to the generator with reason `stub-detected:<file>:<line>`:

```bash
# Skip test files and template files — they legitimately use these markers
SPRINT_FILES=$(git diff --name-only HEAD~1 | grep -v -E '(test|spec|template|fixture)' || true)

for f in ${SPRINT_FILES}; do
  grep -nE 'TODO|FIXME|XXX|HACK' "${f}" && echo "STUB: ${f} — uncompleted marker"
  grep -nE 'throw new Error\(['"'"'"]not[ -]?implement|raise NotImplementedError' "${f}" \
    && echo "STUB: ${f} — explicit not-implemented"
  grep -nE 'return\s*(null|undefined|\{\s*\}|\[\s*\])\s*(//|#|/\*).*(stub|placeholder|todo|temp)' "${f}" \
    && echo "STUB: ${f} — placeholder return"
  # Detect functions whose body is a single bare return / pass / nothing
  grep -nB1 -E '^\s*(return\s*;?\s*$|pass\s*$|return\s+null\s*;?\s*$)' "${f}" \
    && echo "STUB: ${f} — empty function body (manual review)"
  # JSX-only empty fragments / null renders
  grep -nE 'return\s*\(\s*<>\s*</>\s*\)|return\s*null\s*;?\s*//' "${f}" \
    && echo "STUB: ${f} — empty JSX render"
  # Silent catches that swallow errors
  grep -nE 'catch\s*\([^)]*\)\s*\{\s*\}' "${f}" \
    && echo "STUB: ${f} — silent catch swallows errors"
done
```

Test files are exempt because mock helpers and fixtures legitimately use `TODO` and `null` returns. Implementation files have no excuse.

### Step 4b — Wiring / Reachability Check

For every new file the sprint adds (`git diff --diff-filter=A --name-only HEAD~1`), confirm something imports it:

```bash
for new_file in $(git diff --diff-filter=A --name-only HEAD~1); do
  # Skip route/page files (loaded by convention) and test/template files
  case "${new_file}" in
    */routes/*|*/pages/*|*/app/*) continue ;;
    *test*|*spec*|*template*|*fixture*) continue ;;
  esac
  basename_no_ext="$(basename "${new_file}" | sed -E 's/\.(ts|tsx|js|jsx|py|go|rb)$//')"
  if ! grep -rE "(from|import|require).*${basename_no_ext}" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.py' --include='*.go' --include='*.rb' --exclude="$(basename "${new_file}")" > /dev/null 2>&1; then
    echo "DANGLING: ${new_file} — no inbound references"
  fi
done
```

Any DANGLING file → at minimum NEEDS_REVISION with reason `dangling-file:<path>`. New files that nothing imports are stubs in disguise.

### Step 5 — Write Evaluation & Verdict

Write evaluation to `<ai-knowledge-dir>/evaluations/sprint-<N>.md`.
Apply the four severity tiers: CRITICAL / MEDIUM / LOW / INFO.
Output `<pro-eval>VERDICT:details</pro-eval>` as final line.

## Output Protocol

The final line of your response must be one of:
- `<pro-eval>PASS:<score></pro-eval>` — sprint accepted, loop continues
- `<pro-eval>NEEDS_REVISION:<issues></pro-eval>` — generator gets another pass
- `<pro-eval>FAIL:<reason></pro-eval>` — sprint failed, human review required

## Evaluation Criteria

Grade each sprint on (after Steps 3, 3b, 4a, 4b have all passed — those are hard gates that bypass scoring entirely if they fail):

### 1. Browser-Test Coverage (35%)
Did every CRITICAL contract row's Browser Test script execute and pass? Did the prior sprints' scripts still pass (regression carry-forward)? A sprint that ticked every box but skipped writing the required scripts scores 0 here regardless of code quality.

### 2. Contract Completeness (25%)
Is everything the contract specified actually implemented and wired up? Does every new branch (guard, short-circuit, early return) have a contract row covering it?

### 3. Correctness (20%)
Does the implementation behave correctly across the full edge-case matrix from the spec — not just the happy path? Bias toward `silent` failure modes; they cost more to miss than `loud` ones.

### 4. Code Quality (10%)
No security bugs, no broken imports, no obvious logic errors. (Stub detection already auto-failed at Step 4a — this score grades only what remains.)

### 5. Spec Alignment (5%)
Does the implementation match the user stories in spec.md?

### 6. Revisability (5%)
Can the **next iteration safely build on this code**? Penalise: deep magic, undocumented side-effects, hardcoded values that will need changing, circular dependencies, missing browser-test scripts that would let a future sprint re-verify behavior.

### Hard-gate matrix (failures here bypass scoring entirely)

| Gate | Failure → |
|---|---|
| App fails to start (Step 3) | `FAIL:app-not-startable` |
| Any CRITICAL Browser Test FAIL (Step 3) | `FAIL:critical-browser-test-failed:<script>` |
| Any regression-carryforward FAIL (Step 3b) | `NEEDS_REVISION:regression-carryforward-failed:<count>` |
| Stub/no-op detected in non-test file (Step 4a) | `FAIL:stub-detected:<file>:<line>` |
| Dangling new file (Step 4b) | `NEEDS_REVISION:dangling-file:<path>` |
| New branch with no contract row (Step 4) | `NEEDS_REVISION:unrostered-branch:<file>:<line>` |

## What NOT to Do

- Do not be generous because the generator "tried"
- Do not pass a sprint because most things work — CRITICAL failures are blocking
- Do not accept stub implementations
- Do not skip reading the actual code files
- **Do not be sycophantic** — if you feel the urge to write "this is great work" or "impressive progress", that is a signal you are inflating the score. Grade against criteria only. The generator and evaluator are separate agents precisely so the evaluator has no emotional investment in the output. A generous evaluator wastes everyone's next sprint.
