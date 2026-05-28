---
description: "Generate a sprint contract from tasks.md — defines acceptance criteria before implementation starts. Fires automatically after /speckit.tasks via hook."
---

# SpecKit Pro — Sprint Contract Generator (`pro.contract`)

Generates a **sprint contract** from the current `tasks.md`. The contract defines what "done" means for the next implementation phase — bridging the gap between high-level task descriptions and concrete, testable acceptance criteria.

Inspired by the Anthropic harness pattern: the generator and evaluator must agree on success criteria *before* coding starts. This eliminates post-hoc rationalization.

This command is safe to call multiple times — it appends a versioned contract rather than overwriting.

## User Input

```text
$ARGUMENTS
```

Optional: `--spec-dir <path>` to target a specific feature. If omitted, auto-detect.

## Auto-Detection

If `--spec-dir` is not provided:

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` to find `FEATURE_DIR`
2. Fall back: find the most recently modified `tasks.md` under `specs/` or `features/`
3. If still not found: ask the user which feature to generate a contract for

## Steps

### 1. Load tasks.md

Read `<SPEC_DIR>/tasks.md`. Extract:
- Feature name (from H1 heading or filename)
- Total incomplete tasks grouped by phase/section
- The NEXT phase to be implemented (first section with `[ ]` items)

### 2. Determine sprint scope

The sprint scope = **one phase/section** of tasks (matching the loop worker's work unit concept).

If there are no phase sections, take the first ≤5 incomplete tasks as the sprint scope.

### 3. Read supporting context

To write meaningful acceptance criteria, read:
- `<SPEC_DIR>/spec.md` — user stories and business requirements
- `<SPEC_DIR>/plan.md` — technical architecture decisions
- **`.knowledge/`** (when present at `<PROJECT_ROOT>/.knowledge/`):
  - `domain/invariants.md` — any CRITICAL row in the contract must not contradict these rules
  - `domain/glossary.md` — use business terms consistently in Expected Behavior cells
  - `architecture.md` — sections that match the sprint scope (grep sprint nouns in headings)

When `knowledge.enabled: true`, `/pro.go` and `/pro.pickup` run `/pro.knowledge-sync --mode prime` before this command. If you are invoked standalone, run prime first:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<feature name + sprint scope>"
```

Keep `<pro-knowledge-prime>` in context while writing the contract.

If these files are large (>3000 words), only read the sections relevant to the sprint scope.

### 4. Generate the contract

Write the contract to `<FEATURE_KNOWLEDGE_DIR>/contracts/sprint-<N>.md` where N is the next sprint number (count existing contracts + 1).

Derive `<FEATURE_KNOWLEDGE_DIR>` as: `$(git rev-parse --show-toplevel)/.knowledge/features/<feature-name>`. Create the directory if it doesn't exist: `mkdir -p "$FEATURE_KNOWLEDGE_DIR/contracts"`.

Contract structure:

```markdown
# Sprint Contract — Sprint <N>

Feature: <feature name from spec.md>
Generated: <ISO timestamp>
Scope: <phase/section name>

## Tasks in Scope

- [ ] <task 1 from tasks.md>
- [ ] <task 2>
...

## Acceptance Criteria

Each row asserts one (user flow × state) cell from the spec's Edge Cases & Failure States section. Severity defaults to CRITICAL for happy paths and silent-failure rows; MEDIUM/LOW only for cosmetic or telemetry concerns.

| #     | User Flow | State              | Expected Behavior                        | Severity | Failure Mode | Browser Test                                                | Verified By                  |
|-------|-----------|--------------------|------------------------------------------|----------|--------------|-------------------------------------------------------------|------------------------------|
| 1.0   | <flow>    | Happy path         | <one-line user-visible behavior>         | CRITICAL | loud         | `browser-tests/<flow>/01-happy.sh`                          | `<unit-test-file>`           |
| 1.1   | <flow>    | Empty store/cache  | <expected — explicit, not "show error">  | CRITICAL | silent       | `browser-tests/<flow>/02-empty-store.sh`                    | `<unit-test-file>`           |
| 1.2   | <flow>    | Invalid URL param  | <expected>                               | CRITICAL | loud         | `browser-tests/<flow>/03-invalid-param.sh`                  | `<unit-test-file>`           |
| 1.3   | <flow>    | BE returns 5xx     | <expected — must not be blank UI>        | CRITICAL | silent       | `browser-tests/<flow>/04-be-error.sh`                       | `<unit-test-file>`           |
| 1.4   | <flow>    | Network slow (>2s) | <expected — must not hang>               | MEDIUM   | silent       | `browser-tests/<flow>/05-slow.sh`                           | `<unit-test-file>`           |

### Row schema — required columns

- **User Flow** — one of the primary flows from `spec.md`. Same flow may appear in multiple rows.
- **State** — one cell from the input × state matrix in the spec's Edge Cases & Failure States section. Re-use the spec's exact label so the evaluator can cross-reference.
- **Expected Behavior** — what a user sees when this state hits. Must be a single observable fact. "Form renders with defaults, BE call skipped, no spinner persists" — yes. "Handles the error" — no.
- **Severity** — CRITICAL / MEDIUM / LOW. See the Severity Guide below.
- **Failure Mode** — `silent` or `loud`.
  - `silent`: regression produces no error, no stack trace, no log line. UI just looks wrong (blank panel, stuck spinner, no-op button). **All `silent` rows are auto-promoted to CRITICAL** regardless of what severity you typed — silent failures are the worst class because no monitoring catches them.
  - `loud`: regression produces a console error, a 4xx/5xx response, or a visible error message the user/operator notices.
- **Browser Test** — path (relative to `<spec-dir>/`) of the agent-browser script that asserts this row. See `## Browser-test coverage rule` below.
- **Verified By** — path of the unit/integration test file that covers the same behavior at the code-unit level. For pure-UI rows where no code-unit test makes sense, write `browser-only` (the Browser Test column carries the full burden).

### Browser-test coverage rule (the ≥3 rule)

For every **user-facing flow** the sprint touches, the contract MUST include:

1. **One happy-path row** (`State = "Happy path"`), and
2. **At least three edge-case rows** drawn from distinct axes of the spec's input × state matrix (e.g. one Input cell + one State-hydration cell + one Network cell — three axes, not three cells of the same axis).

A sprint that adds a guard, a short-circuit, or any branching control flow to an existing function MUST add a row for **each** new branch — both the guarded path and the original path. This is the MP-1435 lesson: the bug was a new branch with no row covering it. Concretely: if your diff introduces `if (X) { earlyReturn(); }`, you need a row asserting behavior when `X` is true.

If a flow's matrix genuinely has fewer than three relevant edge cases, document why in `## Notes for Evaluator` and the evaluator may waive the rule. Silent waivers are not acceptable.

### How to Verify — runbook per row

For every row, the Browser Test path must point to a script that exists by end-of-sprint and that the evaluator can run with one command. The script's PASS/FAIL output is the definitive verdict — the evaluator does not re-judge the behavior in prose. See `templates/browser-test-template.sh` for the canonical shape.

For each CRITICAL row, the "Expected Behavior" cell must read as a single fact that the script can grep for or that agent-browser can assert. Vague phrasing here means an unfalsifiable test.

```
GOOD: Form renders, ACH+CARD trays visible, no loader after 2s
BAD:  Form works correctly
```

## Out of Scope (Explicit Deferrals)

- <anything from spec.md or plan.md NOT in this sprint>

## Edge-Case Waivers

> Rows from the spec's Edge Cases & Failure States matrix that this sprint intentionally does NOT cover. Every waiver must cite the reason and the sprint in which it will be addressed. Empty section = no waivers.

- <state cell from spec>: <why deferred, which sprint>

## Definition of Done

This sprint is DONE when:
1. All CRITICAL rows pass — both the Browser Test script (exit 0) AND the Verified By unit/integration test (green)
2. All tasks are marked [x] in tasks.md
3. No broken imports, no missing wiring, no stub function bodies
4. All prior sprints' Browser Test scripts in `browser-tests/**` still pass (regression carry-forward)
5. The Edge-Case Waivers section is either empty or every entry cites a deferring sprint

## Notes for Evaluator

<any ambiguities the evaluator should know about — and any edge-case waiver justifications>
```

### Severity Guide

- **CRITICAL** — functional requirements that, if missing, mean the feature is broken from a user's perspective. **Includes every `silent` failure mode regardless of the original severity choice.** Sprint cannot PASS without these.
- **MEDIUM** — visible quality issues (loud edge cases, slow paths, error message ergonomics). Sprint enters NEEDS_REVISION if these fail.
- **LOW** — polish (telemetry, log message format, inline help copy). Doesn't block sprint completion but is logged.

**Criteria writing rules:**
- Every CRITICAL row that touches the UI MUST have a Browser Test entry — no exceptions. "Verified by reading code" is not sufficient.
- Write Expected Behavior as **verifiable facts**, not vague intentions. The Browser Test script encodes the assertion; the contract row must be specific enough for that to be writable.
- For every CRITICAL row, the Browser Test path is created EITHER before the implementation (TDD-style — script fails first, then loop makes it pass) OR alongside it within the same task. A task is not marked `[x]` until its Browser Test script exists and passes.
- Include at least one happy-path CRITICAL row per major user flow.
- For each CRITICAL row, prefer a Browser Test that can be re-run by the evaluator and by every future sprint (regression carryforward). The script should be hermetic — clear cookies/storage, no dependence on prior runs.

### 5. Create sprint pointer

Write/update `<FEATURE_KNOWLEDGE_DIR>/contracts/current.md` with a single line pointing to the latest contract:

```
sprint-<N>
```

This is how the loop worker and evaluator find the current contract without needing explicit args.

### 5b. Scaffold the browser-tests directory

For every row in the Acceptance Criteria table, ensure the parent directory of its `Browser Test` path exists under `<SPEC_DIR>/browser-tests/<flow>/`. Do NOT create empty files — the loop owns writing the actual scripts. Just create the directories so the loop can drop scripts in without permission errors:

```bash
SPEC_DIR=<path-to-feature-dir>
while IFS= read -r flow; do
  mkdir -p "${SPEC_DIR}/browser-tests/${flow}"
done < <(awk -F'|' '/browser-tests\//{match($0, /browser-tests\/[^/]+/); print substr($0, RSTART+15, RLENGTH-15)}' "${CONTRACT_FILE}" | sort -u)
```

If the parent project does not yet have `templates/browser-test-template.sh` (because the extension was added before v1.12.0), copy the canonical template into the spec dir for reference:

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
EXT_TEMPLATE="${PROJECT_ROOT}/.specify/extensions/pro/templates/browser-test-template.sh"
[ -f "${EXT_TEMPLATE}" ] && cp "${EXT_TEMPLATE}" "${SPEC_DIR}/browser-tests/_template.sh"
```

### 6. Checkpoint

```bash
git add .
git commit -m "[Pro] Sprint <N> contract generated — <phase name>"
```

If no git changes: skip commit.

### 7. Output

Print a summary:

```
╔═══════════════════════════════════════════════════════════╗
║  Sprint Contract Generated ✓                              ║
╠═══════════════════════════════════════════════════════════╣
║  Sprint: <N>                                              ║
║  Scope:  <phase name>                                     ║
║  Tasks:  <N tasks in scope>                               ║
║  File:   <FEATURE_KNOWLEDGE_DIR>/contracts/sprint-<N>.md          ║
╚═══════════════════════════════════════════════════════════╝

CRITICAL criteria: <N>
MEDIUM criteria:   <N>
LOW criteria:      <N>

The evaluator will grade the next sprint against these criteria.
Review: <FEATURE_KNOWLEDGE_DIR>/contracts/sprint-<N>.md
```
