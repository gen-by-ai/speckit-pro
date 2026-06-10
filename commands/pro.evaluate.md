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
| `knowledge-feature-dir` | no | Absolute path to `.knowledge/features/<feature>` dir (default: derived from git root) |

Derive `<knowledge-feature-dir>` the same way as the loop: `$(git rev-parse --show-toplevel)/.knowledge/features/<feature>`.

## Evaluation Steps

### Step 0 — Evaluator independence + skeptical stance

Before anything else, set your stance. You are the **adversary** of the generator, not its teammate. Your job is to find the ways this sprint falls short of the contract, not to confirm that it succeeded. Assume the implementation is wrong until the evidence (passing Browser Test scripts, green Verified-By tests, code you have actually read) proves otherwise. Treat the generator's own claims — the contents of `progress.md`, `handoff.md`, commit messages, and any "done" assertions — as unverified marketing copy. They are inputs to find evidence for, never evidence themselves.

**Shared-model check.** If the evaluator model is the **same** model as the generator (i.e. `evaluation.evaluator_model` is empty/unset, so the evaluator runs on the primary model), there is no genuine independence — a model is a weak grader of its own output and will rationalize its own mistakes. When this is the case:

- Adopt an explicitly harsher skeptical posture for the entire evaluation: actively hunt for self-serving interpretations and refuse to extend any benefit of the doubt.
- Stamp a disclosure line into the evaluation prose (`<knowledge-feature-dir>/evaluations/sprint-<N>.md`) and into the run-report note, of the form:

  ```
  SHARED-MODEL: evaluator and generator are the same model (<model-id>) — independence reduced; applied stricter skeptical review.
  ```

  Use the concrete model id when known; otherwise `SHARED-MODEL: evaluator == generator (primary model) — independence reduced; applied stricter skeptical review.`

If the evaluator runs on a distinct `evaluation.evaluator_model`, skip the disclosure line and proceed normally — but keep the adversarial stance regardless.

### Step 1 — Calibrate Against Past Evaluations

Before scoring anything, read all files in `<knowledge-feature-dir>/evaluations/` (sorted oldest → newest). Look for:
- **Score drift**: are scores trending too high/low across sprints?
- **Recurring failures**: issues the generator keeps reintroducing (log these as higher severity this sprint)
- **Resolved issues**: things previously flagged that are now genuinely fixed

Use this to set your scoring bar. If Sprint 1 scored 72 and Sprint 2 scored 91 with no obvious quality jump, your evaluator is drifting generous — correct for it.

### Step 1b — Read drift reconciliation (if present)

If **`<FEATURE_DIR>/pro-drift.md`** exists (from `/speckit.pro.reconcile`), read the **DRIFT** rows before scoring. Known document-vs-code mismatch **without** an updated spec or contract should normally **cap** the verdict below PASS unless the drift is explicitly acceptable (document why in the evaluation). Treat reconcile output as context, not a substitute for contract criteria.

### Step 1c — Check repo invariants (if present)

If **`<PROJECT_ROOT>/.knowledge/domain/invariants.md`** exists, read it (and any bounded-context files linked from `INDEX.md` for paths touched this sprint).

- Any **clear violation** of a stated invariant → at least one CRITICAL failure row in the evaluation and verdict capped at **NEEDS_REVISION** (or **FAIL** if the violation is in production paths).
- Cite evidence as `invariant:<file>:<heading>` in the evaluation prose.
- If `<FEATURE_DIR>/pro-knowledge.md` exists from a prior sync, note whether this sprint's changes align with its proposals.

### Step 1.5 — Verify the rubric seal (hard gate)

The contract is the rubric. Before you read a single acceptance criterion to grade against, prove the rubric was not tampered with after it was sealed by `/pro.contract` (see that command's `## Rubric immutability` section). A generator that quietly loosened its own contract — softened an Expected Behavior, downgraded a CRITICAL row, deleted an edge case — is reward-hacking, and you must refuse to grade against the mutated bar.

Resolve `CONTRACT_FILE` to `<knowledge-feature-dir>/contracts/sprint-<N>.md` and `SEAL` to the same path with `.md` replaced by `.sha256`. Recompute the hash of the contract with the **same ladder** `/pro.contract` used to seal it, then compare:

```bash
CONTRACT_FILE="<knowledge-feature-dir>/contracts/sprint-<N>.md"
SEAL="${CONTRACT_FILE%.md}.sha256"

if command -v python3 >/dev/null 2>&1; then
  RECOMPUTED=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CONTRACT_FILE")
elif command -v shasum >/dev/null 2>&1; then
  RECOMPUTED=$(shasum -a 256 "$CONTRACT_FILE" | cut -d' ' -f1)
elif command -v sha256sum >/dev/null 2>&1; then
  RECOMPUTED=$(sha256sum "$CONTRACT_FILE" | cut -d' ' -f1)
else
  RECOMPUTED=UNSEALED   # honest capability gap on the verify side too
fi
```

Then branch on the seal:

- **Seal file absent** while `evaluation.enabled` AND `sprint_contracts` are both true → fail-closed for tamper: emit `<pro-eval>FAIL:rubric-unsealed</pro-eval>` and stop. A missing seal on a run that is supposed to seal contracts means the seal was deleted or never committed — treat it as tampering, not as a capability gap. (If `evaluation` or `sprint_contracts` is off, there is no seal expectation — skip this gate.)
- **Seal == `UNSEALED`** (the contract was honestly sealed with no hashing tool available at the time) → log a WARN to the evaluation prose ("rubric seal is UNSEALED — hashing tool was unavailable at contract time; integrity not cryptographically verifiable") and **proceed** to grading. This is a known, disclosed gap, not tamper.
- **Recomputed hash != the value in `SEAL`** → the contract changed after it was sealed: emit `<pro-eval>FAIL:rubric-mutated:sprint-<N></pro-eval>` and stop. Do not grade. This routes to operator review with no revision retry — a reward-hacking loop must not be able to "fix" the seal by re-running.
- **Recomputed hash == the value in `SEAL`** → the rubric is intact; proceed (to Step 1.6 if the contract was amended mid-run, otherwise Step 2).

**Amended contracts.** If `${CONTRACT_FILE%.md}.sha256.history` exists, the contract was amended mid-run via `/pro.contract --amend` — each amendment appends the superseded seal to the history file and re-seals. None of the branches above change: the **current** seal must still verify against the current contract, and a mismatch is still `FAIL:rubric-mutated`. But a verified seal on an amended contract is not the end of the story — proceed to Step 1.6 and audit what the amendments did before grading.

This gate runs before scoring and before any browser test. A tampered or missing rubric is a categorical failure that bypasses the rest of the evaluation.

### Step 1.6 — Amendment audit (when the contract was amended mid-run)

Run this step when `${CONTRACT_FILE%.md}.sha256.history` exists **or** any contract row contains `amended-mid-run`. Otherwise skip it entirely. The amend path exists so an unattended loop can ADD scope it discovered mid-run — it must never become a side door for loosening the bar.

1. **Enumerate amended rows.** Find every contract row whose text contains `amended-mid-run` and list them in the evaluation output (`<knowledge-feature-dir>/evaluations/sprint-<N>.md`) under an **"Amended rows"** heading: row id, a one-line summary of the criterion, and who amended it — `unattended` or `operator`, straight from the marker.
2. **Verify amendments only ADDED scope.** Reconstruct the pre-amendment contract if cheaply possible — the seal history proves a prior version existed, and if the feature dir has git history for the contract file, diff it (`git log --follow -- "${CONTRACT_FILE}"`, then diff the pre-amendment revision against the current file). Check that no pre-existing row was edited, deleted, severity-lowered, or had its Expected Behavior relaxed. Legitimate amendments append new rows; they touch nothing that was already sealed.
3. **Any pre-existing criterion weakened** → emit `<pro-eval>FAIL:rubric-weakened:sprint-<N></pro-eval>` and stop. Do not grade. This is the same severity class as `rubric-mutated` — a "weakened by amendment" rubric is reward-hacking with a paper trail — and it routes to operator review with no revision retry.
4. **Reconstruction not possible** (no git history for the contract file) → say so explicitly in the evaluation output and grade the amended rows as normal contract rows, but flag `amendment-unverifiable` in the notes. Never silently skip the audit.

### Step 2 — Load the Sprint Contract

Read `<knowledge-feature-dir>/contracts/sprint-<N>.md`. The acceptance criteria table is the definitive definition of "done". Every CRITICAL criterion must pass for the sprint to pass.

### Step 3 — Live Browser Testing (mandatory when contract has Browser Test rows)

Boot the app:

```bash
bash <knowledge-feature-dir>/init.sh   # start the dev server
```

If the app fails to start, mark all UI/API rows as FAIL with reason `app-not-startable` and emit `<pro-eval>FAIL:app-not-startable</pro-eval>` — do not proceed to static review. A sprint that broke the app is not graded on code.

Then run the browser-test suite. **The contract's Browser Test column is the source of truth — you do not invent your own probes.** Run every script the contract lists. Before executing each script, verify it actually exists on disk — a typo'd path or a never-written script must not read as a generic test failure (or worse, slip through):

```bash
SPEC_DIR=<resolved spec dir>
SUITE_LOG="${SPEC_DIR}/browser-tests/_eval-sprint-<N>.log"
mkdir -p "$(dirname "${SUITE_LOG}")"

# This-sprint scripts (referenced from this sprint's contract rows)
THIS_SPRINT_FAILED=0
while IFS= read -r script; do
  echo "──────── $(basename "${script}") ────────" | tee -a "${SUITE_LOG}"
  if [ ! -f "${script}" ]; then
    echo "FAIL:test-script-not-found:${script}" | tee -a "${SUITE_LOG}"
    THIS_SPRINT_FAILED=$((THIS_SPRINT_FAILED + 1))
    continue
  fi
  if bash "${script}" 2>&1 | tee -a "${SUITE_LOG}"; then
    echo "PASS: ${script}" | tee -a "${SUITE_LOG}"
  else
    echo "FAIL: ${script}" | tee -a "${SUITE_LOG}"
    THIS_SPRINT_FAILED=$((THIS_SPRINT_FAILED + 1))
  fi
done < <(awk -F'|' '/browser-tests\//{match($0, /browser-tests\/[^[:space:]\`]+\.sh/); if (RSTART) print substr($0, RSTART, RLENGTH)}' "${CONTRACT_FILE}" | sed "s|^|${SPEC_DIR}/|")
```

Any failure in this-sprint scripts → at least NEEDS_REVISION. Any failure of a CRITICAL row → outright FAIL unless the row is in the contract's Edge-Case Waivers section.

A missing script is reported as `test-script-not-found:<path>` — distinct from a script that runs and fails — so the operator knows whether to write the test or fix the code. It still counts as a failed CRITICAL row (a missing test is not a free pass), but the suite continues to the next script rather than aborting, so one bad path cannot mask the results of the rest of the suite.

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

Grade the **END STATE of the working tree** against the contract — what the code actually does right now — NEVER the generator's self-report in `progress.md` or `handoff.md`; those are claims to verify against the tree, not evidence of completion.

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

### Step 4c — Local-Review Verdict Capture (telemetry, layer 1)

If `<FEATURE_DIR>/local-reviews/` exists (written by `/pro.local-review`), the local Ollama models gave you a head start: candidate findings with full evidence packs. Your job here is to record **how good those drafts were** so we can measure the local stack's quality over time — precision (kept ÷ produced) and recall (agreed ÷ (agreed + missed-by-local)) per review type.

This step is telemetry, not gatekeeping. The verdict you assign here does not change PASS/NEEDS_REVISION/FAIL by itself — it just writes events to the metrics file. The hard gates above already decided severity.

**Skip entirely if** `<FEATURE_DIR>/local-reviews/` does not exist (local sidecar was off or unreachable when the sprint ran). No metrics events, no warning.

Otherwise:

1. **Resolve the metrics file path**:
   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   METRICS_FILE="${SPECKIT_PRO_METRICS_FILE:-$PROJECT_ROOT/.knowledge/metrics/local-metrics.jsonl}"
   mkdir -p "$(dirname "$METRICS_FILE")"
   ```

2. **For each `local-reviews/*.md` file**, parse the findings (markers `### F1 — …`, `### G1 — …`, `### S1 — …` per the templates) and decide one verdict per finding:

   | Verdict     | Meaning                                                                                          |
   |-------------|--------------------------------------------------------------------------------------------------|
   | `agreed`    | I read the cited file:line, the evidence holds, and the finding is a real issue.                 |
   | `kept`      | Real but lower severity than the local model said (or vice-versa) — see `severity_delta`.        |
   | `dropped`   | False positive: cited code does not have the claimed problem, OR is unreachable, OR has guard.   |
   | `unverifiable` | Cited file/line no longer exists, or the evidence is too thin to verify in budget.            |

3. **Also record findings the local model MISSED** that you caught fresh in Step 4. For each, append a `missed` event with a synthetic `finding_ref` like `NEW-impl-1`. Recall depends on this — without these events, recall is meaningless.

4. **Append one JSONL line per finding** to `$METRICS_FILE`:

   ```json
   {"type":"verdict","ts":"2026-05-26T12:34:56Z","feature":"<FEATURE>","sprint":<N>,
    "review_type":"implementation-review|test-gap-review|security-review",
    "finding_ref":"F1|G1|S1|NEW-impl-1",
    "verdict":"agreed|kept|dropped|unverifiable|missed",
    "severity_delta":-1|0|+1,
    "notes":"one-line evaluator note"}
   ```

   The bash one-liner that does this cleanly:
   ```bash
   python3 - <<'PY' >> "$METRICS_FILE"
   import json, datetime as dt
   rec = {
     "type":"verdict",
     "ts": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"),
     "feature": "<FEATURE>",
     "sprint": <N>,
     "review_type": "<TYPE>",
     "finding_ref": "<REF>",
     "verdict": "<VERDICT>",
     "severity_delta": <DELTA>,
     "notes": "<NOTE>",
   }
   print(json.dumps(rec, separators=(",",":")))
   PY
   ```

5. **Calibration hint**: if you find yourself dropping ≥ 50 % of one review type's findings, that's a signal worth recording in your evaluation prose (`<knowledge-feature-dir>/evaluations/sprint-<N>.md`) — the local model or its prompt template may need tuning. Run `/pro.local-metrics --feature <feature>` afterwards to see the trend.

**Why this step exists**: from `.dev-work/learning.md` (MDASH lesson 4) — "prove the model didn't just memorize the answer". The evaluator is the only authority that can grade the local stack's output. Anything else is self-reporting and drifts.

### Step 5 — Write Evaluation & Verdict

Write evaluation to `<knowledge-feature-dir>/evaluations/sprint-<N>.md`.
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
| Rubric seal mismatch (Step 1.5) | `FAIL:rubric-mutated:sprint-<N>` |
| Rubric seal absent w/ contracts enabled (Step 1.5) | `FAIL:rubric-unsealed` |
| Mid-run amendment weakened a pre-existing criterion (Step 1.6) | `FAIL:rubric-weakened:sprint-<N>` — same severity class as rubric-mutated |
| App fails to start (Step 3) | `FAIL:app-not-startable` |
| Any CRITICAL Browser Test FAIL (Step 3) | `FAIL:critical-browser-test-failed:<script>` |
| Contract-listed Browser Test script missing from disk (Step 3) | `FAIL:test-script-not-found:<path>` — counted as a failed CRITICAL row, distinct from a test that runs and fails |
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
