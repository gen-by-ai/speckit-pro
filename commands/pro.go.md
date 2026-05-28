---
description: "Full autonomous SDD pipeline: invokes native SpecKit commands in sequence with configurable quality gates between phases"
---

# SpecKit Pro — Pipeline Runner (`pro.go`)

Runs the native SpecKit pipeline — `specify → clarify → plan → tasks → implement` — with Pro quality gates, sprint contracts, and autonomous orchestration. Unlike the old monolithic runner, this is a **thin orchestrator**: all phase work is done by native SpecKit commands. When upstream improves `speckit.plan`, you automatically benefit.

## User Input

```text
$ARGUMENTS
```

The arguments are passed as the feature description to `/speckit.specify`. If empty, ask the user for a feature description before proceeding.

## Knowledge integration (mandatory when `knowledge.enabled: true`)

`/speckit.pro.go` must invoke `/speckit.pro.knowledge-sync` at every touchpoint below. Do not rely on hooks alone when running the full pipeline in chat — hooks may be skipped or disabled in the project.

| Step | Phase | Mode | Skip when |
|------|-------|------|-----------|
| 1 | 0 — start | `prime` | `knowledge.enabled: false` or `prime_before_specify: false` |
| 2 | 2.5 — after clarify | `prime` | `prime_before_plan: false` |
| 3 | 4 — after tasks | `prime` | `prime_before_contract: false` |
| 4 | 5a — before implement | `prime` | `prime_before_implement: false` |
| 5 | 6 — each loop iteration | `prime` | `prime_each_loop_iteration: false` |
| 6 | 7 — after evaluate PASS | `sync` | `sync_after_evaluate: false` |

Keep every `<pro-knowledge-prime>` block in context until the next prime replaces it. On first run with no `.knowledge/`, run `--mode bootstrap` first (or let auto-bootstrap run).

## Phase 0 — Knowledge Prime

Before *anything else*, ground the agent in repo-level context so the spec it's about to write doesn't reinvent terms, violate invariants, or duplicate work in an existing bounded context.

Skip entirely if any of the following is true:
- `knowledge.enabled: false` in `pro-config.yml`, or
- `knowledge.prime_before_specify: false`.

If `.knowledge/` is missing and `knowledge.auto_bootstrap: true`, run `/pro.knowledge-sync --mode bootstrap` first (creates starter files — edit `INDEX.md` and `domain/invariants.md` before treating output as authoritative).

Otherwise:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<$ARGUMENTS>"
```

The command emits a `<pro-knowledge-prime>` block to stdout — keep it in context for the remainder of `/pro.go`. It is **retrieval-only**: nothing is written, nothing is committed. If retrieval returns zero hits, surface the "unexplored territory" note before continuing — that's a signal to the human reviewer at the spec gate that this feature may need a new bounded context.

Keep the `<pro-knowledge-prime>` block in context for the entire pipeline. Replace template placeholders in `.knowledge/` with real decision-tree rules as soon as you can — primes are only as good as `INDEX.md` and `domain/invariants.md`.

## Pre-Flight: Existing-Feature Scan

Before generating a new spec, check whether the same work is already in flight. The single biggest reason features stall is duplicate planning — a new spec is created when an old one already covers the work.

1. **Detect the project root and specs directory**
   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   SPECS_DIR="$PROJECT_ROOT/specs"
   ```

2. **Ticket-ID match** — extract any `[A-Z]+-[0-9]+` patterns from `$ARGUMENTS` (Jira-style: `MP-1408`, `FDT-696`). For each ticket found, grep `specs/*/spec.md` and `specs/*/plan.md` for the same ticket. Also match the ticket against directory names (case-insensitive).

3. **Title match** — extract the 3 most distinctive nouns from `$ARGUMENTS` (skip stop-words). Grep `specs/*/spec.md` H1 headings for any of them.

4. **Phase classification** — for any feature dir that matches, classify its current phase by which artifacts exist:

   | Artifacts present | Phase | Suggested entry |
   |---|---|---|
   | spec.md only | `spec-only` | `/speckit.plan` |
   | spec.md + plan.md | `plan-only` | `/speckit.tasks` |
   | spec.md + plan.md + tasks.md (no contracts/) | `tasks-only` | `/pro.contract` then `/pro.pickup <feature>` |
   | + contracts/ but no `.knowledge/features/<feature>/` | `contracts-ready` | `/pro.pickup <feature>` |
   | + `.knowledge/features/<feature>/` exists | `in-loop` | `/pro.resume` |
   | tasks.md fully checked off | `complete` | (none — already done) |

5. **Decision prompt** — if any matches found:
   ```
   ┌──────────────────────────────────────────────────────────────┐
   │  Possible overlap with existing feature(s):                  │
   │                                                              │
   │  • specs/<feature-1>  [phase: contracts-ready]               │
   │    Match: ticket MP-1408 in spec.md                          │
   │    → /pro.pickup <feature-1>                                 │
   │                                                              │
   │  • specs/<feature-2>  [phase: plan-only]                     │
   │    Match: title nouns "payment", "retry"                     │
   │    → /speckit.tasks then /pro.pickup <feature-2>             │
   └──────────────────────────────────────────────────────────────┘
   Resume one of these (1, 2, ...), start fresh anyway (n), or abort (a)?
   ```
   - `1`/`2` → invoke `/pro.pickup <feature>` and STOP this command.
   - `n` → continue to the run plan below.
   - `a` → abort.

6. **No matches** — silently continue to the run plan. Print one line: `[Pro] No overlapping features found — starting fresh.`

## Run Plan

Load config from `.specify/extensions/pro/pro-config.yml` (fall back to defaults):

| Key | Default | Meaning |
|---|---|---|
| `gates.after_specify` | `true` | Pause after spec for human review |
| `gates.after_plan` | `true` | Pause after plan for human review |
| `gates.after_tasks` | `false` | Pause after tasks (contract auto-generated by hook) |
| `quality.run_clarify` | `true` | Run `/speckit.clarify` after specify |
| `quality.run_analyze` | `true` | Run `/speckit.analyze` before implement |
| `loop.max_iterations` | `20` | Max implement loop iterations |
| `loop.checkpoint_frequency` | `3` | Commit every N iterations |
| `model` | `claude-sonnet-4.6` | Agent model for the loop |
| `agent_cli` | `copilot` | CLI binary for the loop |

Display the run plan and ask "Proceed? (yes/no)":

```
┌──────────────────────────────────────────────────────────────┐
│  SpecKit Pro — Pipeline Runner                               │
├──────────────────────────────────────────────────────────────┤
│  0. /pro.knowledge-sync --mode prime  (bootstrap if needed)  │
│  1. /speckit.specify    gate: [YES|NO]                       │
│  1c. /pro.deepen        (skipped if disabled; pauses for     │
│                          human Qs, then /pro.deepen --apply) │
│  2. /speckit.clarify    skip: [YES|NO]                       │
│  2.5 /pro.knowledge-sync prime (before plan)                   │
│  3. /speckit.plan       gate: [YES|NO]                       │
│  4. /speckit.tasks      → prime → pro.contract                │
│  4b. /pro.local-prep    → /pro.materialize                    │
│  5a. /pro.knowledge-sync prime (before implement)             │
│  5. /speckit.analyze    skip: [YES|NO]                       │
│  6. loop (+ prime each iter)  max: N                          │
│  7. reconcile → local-review → evaluate → knowledge-sync      │
├──────────────────────────────────────────────────────────────┤
│  Model: <model>  │  Agent CLI: <agent_cli>                   │
│  Local: <local_models.enabled>  (Ollama sidecar)             │
└──────────────────────────────────────────────────────────────┘
```

If the user says no: `Pipeline cancelled. Run /pro.go <description> to start again.`

> **Tip**: If you only want to *implement* an existing spec (not regenerate it), use `/pro.pickup <feature-dir>` instead — it skips planning and starts the loop directly.

## Phase Protocol

For each phase: **announce → execute → gate → update session**.

- **Announce**: `[Pro] Phase N — running /speckit.<cmd>`
- **Execute**: run the native SpecKit command with `EXECUTE_COMMAND`
- **Gate** (if `true`): ask `⏸ Review above. Press Enter to continue or type 'abort'.` If abort: print the feature directory for resuming with `/pro.resume` and stop.
- **Gate** (if `false`): print `[Pro] Auto-continuing...`
- **Update session**: append a one-line entry to `<FEATURE_DIR>/session.md`

## Phase Order

### Phase 1 — Specify
```
EXECUTE_COMMAND: /speckit.specify <$ARGUMENTS>
```
Gate: `gates.after_specify`

### Phase 1b — Branch Convention Check

`/speckit.specify` creates a feature branch named `NNN-feature-name` (e.g. `001-payment-retry`). Many teams use a different convention (e.g. `<initials>/<TICKET>-<short>`, `feature/<TICKET>`, `dev/<area>/<short>`). Renaming the branch *before* any commits land avoids a force-push later.

1. **Look for a documented convention** (in priority order):
   - `.claude/rules/branch-naming*.md`
   - `.cursor/rules/branch-naming*.md` / `.cursor/rules/branch-naming*.mdc`
   - `CONTRIBUTING.md` — grep for "branch" in headings
   If found, parse the rule and skip to step 3.

2. **Heuristic from recent branches** (only if no rule file found):
   ```bash
   git for-each-ref --sort=-committerdate --count=30 \
     --format='%(refname:short)' refs/heads/ refs/remotes/origin/
   ```
   Strip `origin/` prefix. Look for a recurring pattern that **isn't** `^[0-9]{3}-`. If ≥ 3 of the last 30 branches share a non-default prefix structure (e.g. `xx/PROJ-####-...`, `feature/PROJ-####`, `bugfix/...`), treat that as the team convention.

3. **Prompt to rename** (if a convention was detected and current branch matches `^[0-9]{3}-`):
   ```
   Detected branch convention: <pattern> (e.g. <example from history>)
   Current branch: <NNN-feature-name>
   Rename to match? Suggested: <generated-name>
   (y / n / custom <name>)
   ```
   - `y` → `git branch -m <NNN-feature-name> <new-name>`
   - `custom <name>` → `git branch -m <NNN-feature-name> <name>`
   - `n` → keep as-is.

4. **Note the post-rename caveat**: SpecKit's `check-prerequisites.sh` validates the branch matches `^[0-9]{3}-` and may print "Not on a feature branch". The spec directory still works — that script is informational, not blocking. Print this once so the user isn't surprised.

5. **Skip silently** if: no convention detected, current branch already non-default, or running on `main`/`trunk` (which means the user has their own branching strategy already).

No gate.

### Phase 1c — Deepen (optional)

Adversarially audit the draft spec before clarify runs. The deepener investigates gaps autonomously from local sources (`.knowledge/`, code, sibling specs, git history) and from any capability-matched external sources (issue tracker, docs system), then asks the operator only the questions no source can answer.

Skip entirely if any of the following is true:
- `deepen.enabled: false` in `pro-config.yml` (default off — opt-in), or
- `deepen.run_after_specify: false`.

Otherwise:

```
EXECUTE_COMMAND: /pro.deepen
```

The command writes two files to `<FEATURE_DIR>/`:
- `spec-patches.md` — cited proposals (auto-resolved gaps)
- `spec-questions.md` — focused human-input file (≤10 questions, multiple-choice when possible)

**Pause for human input.** Print:
```
⏸ Deepen wrote <N> proposals and <M> questions to:
    specs/<feature>/spec-patches.md
    specs/<feature>/spec-questions.md

Fill in the answers, then resume with one of:
  /pro.deepen --apply   (merge patches + answers into spec.md)
  abort                 (skip deepen entirely; spec stays as-is)
```

Wait for the operator. When they return:
- If they ran `/pro.deepen --apply`, continue to Phase 2 (clarify).
- If they typed `abort`, log to `session.md` and continue to Phase 2.

Rationale: the whole point of deepen is to challenge the spec before any downstream phase consumes it. Auto-continuing would defeat the purpose.

### Phase 2 — Clarify
Skip if `quality.run_clarify: false`.
```
EXECUTE_COMMAND: /speckit.clarify
```
No gate (auto-continue).

### Phase 2.5 — Knowledge Prime (before plan, optional)

Re-ground the agent before technical planning widens scope.

Skip if `knowledge.enabled: false` or `knowledge.prime_before_plan: false`.

Otherwise, after Phase 2 (clarify) completes:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<spec.md H1 + first P1 user story title>"
```

Keep the new `<pro-knowledge-prime>` block in context through Phase 3.

### Phase 3 — Plan
```
EXECUTE_COMMAND: /speckit.plan
```
Gate: `gates.after_plan`

### Phase 4 — Tasks
```
EXECUTE_COMMAND: /speckit.tasks
```

**Knowledge prime (before contract)** — skip if `knowledge.enabled: false` or `knowledge.prime_before_contract: false`:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<spec.md H1 + plan.md top-level components>"
```

Then ensure a sprint contract exists. The `after_tasks` hook usually fires `/pro.contract`; if it did not:

```
EXECUTE_COMMAND: /pro.contract
```

Gate: `gates.after_tasks`

### Phase 4b — Local Prep (optional, Ollama sidecar)

Offload token-heavy prep Markdown to a local model so the implement loop reads tight artifacts instead of regenerating them. From `.dev-work/dev.md`: Claude becomes a premium worker, not the whole factory.

Skip entirely if any of the following is true:
- `local_models.enabled: false` in `pro-config.yml`, or
- `local_models.auto_run.after_tasks: false`, or
- the Ollama HTTP endpoint at `local_models.base_url` is unreachable (the driver self-detects within 3 seconds).

Otherwise, run both commands in sequence — `pro.local-prep` first (produces `repo-map.md` + dependents), then `pro.materialize` (consumes `repo-map.md` for the task packets):

```
EXECUTE_COMMAND: /pro.local-prep
EXECUTE_COMMAND: /pro.materialize
```

Both commands self-skip with a single-line note if local models are disabled or Ollama isn't running — they never abort the pipeline. They write under `<SPEC_DIR>/`:

- `repo-map.md` — files / patterns / test commands / risks / unknowns
- `risk-register.md` — concrete risks with triggers, severity, mitigation, verifier
- `test-strategy.md` — commands + case ideas grounded in CI
- `open-questions.md` — ≤ 10 sharp questions, multiple-choice when possible
- `context-pack.md` — compiled ≤ 1500-word bundle the loop reads instead of spec+plan+tasks
- `task-packets/TASK-NNN-<slug>.md` — one packet per task

Every local artifact is prepended with a provenance banner (`Generated by local model <name>... Claims require verification before implementation.`) — that banner is intentional: it stops downstream agents (and humans in PR review) from treating local output as ground truth.

No gate. Auto-continue. If both commands self-skip, this phase is a no-op.

### Phase 5a — Knowledge Prime (before implement, optional)

Skip if `knowledge.enabled: false` or `knowledge.prime_before_implement: false`.

Otherwise, immediately before Phase 6:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<spec.md H1 + next incomplete tasks.md phase heading>"
```

### Phase 5 — Analyze
Skip if `quality.run_analyze: false`.
```
EXECUTE_COMMAND: /speckit.analyze
```
If analyze reports CRITICAL issues, pause regardless of gate setting:
```
⚠  Analysis found CRITICAL issues. Resolve before implementing? (yes/no/force)
```
- `yes` → pause for human to fix
- `no` → abort pipeline
- `force` → continue despite issues (log a warning to session.md)

### Phase 5b — Initializer Setup

Before the implement loop, set up the workspace state directory. This phase has four steps: derive paths, write `.gitignore` rules, generate a stack-aware `init.sh`, and seed `AGENT.md` with real project facts (not placeholders).

#### 5b.1 — Derive paths

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FEATURE_KNOWLEDGE_DIR="$PROJECT_ROOT/.knowledge/features/<feature-slug>"
mkdir -p "$FEATURE_KNOWLEDGE_DIR/contracts" "$FEATURE_KNOWLEDGE_DIR/evaluations"
```

#### 5b.2 — Ensure `.gitignore` excludes workspace state

`.knowledge/features/` and `.knowledge/metrics/` are machine-generated workspace state and **must not** land in feature-branch commits intended for PR review. Read `<PROJECT_ROOT>/.gitignore`. If it does not contain `.knowledge/features/`, append:

```
# SpecKit Pro — workspace-only autonomous-run state (never commit)
.knowledge/features/
.knowledge/metrics/
```

For `specs/`, behavior depends on `commit_artifacts` config (default `false`):
- `commit_artifacts: false` — also append `specs/` to `.gitignore` and warn:
  ```
  [Pro] Note: specs/ is now gitignored. To share specs with teammates, set commit_artifacts: true in pro-config.yml.
  ```
- `commit_artifacts: true` — leave `specs/` alone; the team versions specs intentionally.

If `.gitignore` already contains either pattern, skip silently.

#### 5b.3 — Stack-aware `init.sh`

If `<FEATURE_KNOWLEDGE_DIR>/init.sh` already exists, skip. Otherwise, **detect the stack** by checking which markers exist in `<PROJECT_ROOT>` (or in the most relevant subdir per `plan.md`):

| Marker | Stack | Default smoke test |
|---|---|---|
| `package.json` with `tsconfig.json` | TypeScript / Node | `tsc --noEmit` (scoped to feature dirs if repo is large) |
| `package.json` no TS | Node | `node -e "require('./package.json')"` + `npm run lint` if defined |
| `go.mod` | Go | `go build ./...` |
| `pyproject.toml` or `requirements.txt` | Python | `python -c "import <main_module>"` + `ruff check` if available |
| `Cargo.toml` | Rust | `cargo check --all-targets` |
| `Gemfile` | Ruby | `bundle exec rake -T > /dev/null` |
| Multiple / unclear | mixed | fallback: just print `OK` and let the loop populate it later |

For large monorepos, **scope the smoke test to files the feature touches**. Read `plan.md` for the touched paths and constrain the check to those (e.g. `tsc --noEmit` against a tsconfig that only includes the feature dir). The user's auto-memory often contains hints like "Local backend tests don't work" — if such a memory exists, prefer compile-only checks over runtime tests.

Generate a real, runnable script — not commented-out placeholders:

```bash
#!/usr/bin/env bash
# init.sh — smoke test for autonomous loop iterations
# Generated <ISO timestamp> by /pro.go for feature: <feature-slug>
# Edit freely; the loop runs this at the top of every iteration.
set -e

cd "$(git rev-parse --show-toplevel)"

# <stack-specific commands here, derived from detection>

echo "[init.sh] smoke test: OK"
```

Make executable: `chmod +x "$FEATURE_KNOWLEDGE_DIR/init.sh"`.

#### 5b.4 — AGENT.md prepopulation

Create `<FEATURE_KNOWLEDGE_DIR>/AGENT.md` only if it doesn't already exist. Seed it from real project files, not placeholders. Read these in parallel and extract relevant lines:

- **`package.json`** scripts → `dev`, `start`, `test`, `lint`, `build`, `typecheck`
- **`Makefile`** → first 30 targets (or all `## comment`-style documented targets)
- **`.github/workflows/*.yml`** — `run:` lines in any `lint`, `test`, `typecheck`, `format` jobs (these are the canonical CI commands; running them locally before committing avoids CI surprises)
- **`.claude/rules/*.md`** + **`.cursor/rules/*.mdc`** — project conventions; quote any rule headings + first sentence
- **`CLAUDE.md`** / **`.cursorrules`** / **`AGENTS.md`** at project root — paste relevant short excerpts (max ~500 chars total)
- **Project memory** — if `~/.claude/projects/-<encoded-project-path>/memory/` exists, scan `feedback_*.md` and `reference_*.md` for entries whose names suggest project-relevance (testing, lint, build, branch, CI, deploy). Pull each entry's one-line summary into Known Gotchas.

Layout:

```markdown
# Project Agent Notes

Generated: <ISO timestamp> (by /pro.go for <feature-slug>)
Last updated: <ISO timestamp>

## How to Start the App
- `<command from package.json:scripts.dev or start>` — dev server
- `<command from Makefile dev target if exists>`

## How to Run Tests
- Unit: `<from package.json:scripts.test or go test ./... etc>`
- Lint: `<lint command — exact same one CI runs>`
- Typecheck: `<from scripts.typecheck or tsc --noEmit>`
- (Note: if local tests require Docker/services not available, prefer compile-only — let CI run the full suite)

## CI Commands (from .github/workflows)
- `<job name>`: `<command>` ← the loop should run this before declaring done
- ...

## Project Conventions (from .claude/rules, .cursor/rules)
- <rule heading>: <one-line summary>
- ...

## Known Gotchas
- <from project memory entries — keep verbatim where possible>

## Build Learnings
(populated by loop iterations — do not edit; the loop appends here)
```

**Why prepopulate**: the loop currently *discovers* facts like "yarn test needs Docker" mid-sprint and writes them in. Seeding AGENT.md from CI workflows + project rules + memory shortcuts that discovery and prevents iteration 1 from failing on environmental issues that were already known.

These files live at **project root** under `.knowledge/features/<feature-slug>/`. They persist across extension updates.

### Phase 6 — Implement Loop

> **Phase 6b — Local Review (optional, Ollama sidecar)** runs automatically after the loop completes, before `/pro.evaluate`. It is documented after the loop body below (see "Phase 6b" at the end of this section).


> **You are the loop.** Do NOT try to run `pro-orchestrate.sh` — that script calls back into the agent CLI and cannot work inside VS Code Chat. Execute each iteration directly and keep going until all tasks are done or `<loop.max_iterations>` is reached.

For each iteration N = 1, 2, 3 … up to `<loop.max_iterations>`:

---

**0. Knowledge prime (each iteration)** — skip if `knowledge.enabled: false` or `knowledge.prime_each_loop_iteration: false`:

```
EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<spec.md H1> <current work-unit heading>"
```

Keep `<pro-knowledge-prime>` in context for this iteration (same rules as `pro.loop.md`).

**Print at the start of every iteration:**
```
[Pro] ── Iteration <N>/<max> ────────────────────────────────
```

**1. Load context**

Context-loading priority (cheapest sufficient bundle wins):

1. If `<SPEC_DIR>/handoff.md` exists AND N > 1:
   - Load `<SPEC_DIR>/handoff.md` and `<SPEC_DIR>/tasks.md` (lean context reset).
2. Else if `<SPEC_DIR>/context-pack.md` exists (written by `/pro.local-prep` in Phase 4b):
   - Load `<SPEC_DIR>/context-pack.md` and `<SPEC_DIR>/tasks.md` — the context-pack is the compiled ≤ 1500-word substitute for spec + plan + tasks. Mind its banner: claims need verification before action.
3. Otherwise (first iteration, no handoff, no context-pack):
   - Load `<SPEC_DIR>/spec.md`, `<SPEC_DIR>/plan.md`, `<SPEC_DIR>/tasks.md`
   - Load last 10 entries of `<FEATURE_KNOWLEDGE_DIR>/progress.md` (if file exists)
   - Load `<SPEC_DIR>/session.md` (if exists)

If the work unit corresponds to a known task ID and `<SPEC_DIR>/task-packets/TASK-<id>-<slug>.md` exists (written by `/pro.materialize`), load that packet too — it replaces the need to re-derive the work unit's scope from scratch.

Always load `<FEATURE_KNOWLEDGE_DIR>/AGENT.md` if it exists — it contains project-specific commands and gotchas discovered in previous iterations.

**2. Smoke test**

If `<FEATURE_KNOWLEDGE_DIR>/init.sh` exists, run it in the terminal:
```bash
bash <FEATURE_KNOWLEDGE_DIR>/init.sh
```
- Exit 0 → note `[smoke-test: OK]` in the progress entry
- Non-zero → fix the break before implementing new features, log the fix

**3. Check completion**

Count lines matching `- [ ]` in `tasks.md`. If zero: stop the loop and print the completion banner below.

Count to show: `<completed>/<total> tasks (<N-1> iterations used)`.

**4. Find next work unit & sprint contract**

Find the first incomplete phase/section in `tasks.md` (a heading whose tasks still contain `- [ ]`).

Check for `<FEATURE_KNOWLEDGE_DIR>/contracts/sprint-<N>.md`:
- If it exists: read it — implement against its acceptance criteria, not just the task list.
- If it does NOT exist: create it now (see `pro.loop.md` Sprint Contract section for the required format). The contract is your commitment to the evaluator.

**5. Implement**

Implement all tasks in the work unit. For each task:
- Write the code
- Verify the acceptance criteria (including edge cases)
- Mark the task `- [x]` in `tasks.md` immediately when done

Follow the Scope of Autonomy rules from `pro.loop.md`: never delete files, never `git push`, never run `--force` commands.

Signal underspecified requirements with `<pro-uncertainty>…</pro-uncertainty>` in the progress entry.

**6. Append to progress log**

Append to `<FEATURE_KNOWLEDGE_DIR>/progress.md` (create with header if missing):

```markdown
## Iteration <N> — <ISO timestamp>
**Work Unit**: <phase/section name>
**Tasks completed**: <count this iteration>
**Cumulative**: <completed>/<total> (<percentage>%)
**Files modified**: <list>

### Summary
<2-3 sentences>

### Decisions made
<architectural/implementation decisions>

### Issues encountered
<problems, workarounds, deferred items>

---
```

**7. Write handoff**

Write `<SPEC_DIR>/handoff.md` (≤400 words). See `pro.loop.md` Handoff Artifact section for the exact required format. This replaces the full artifact load for the next iteration — keep it tight.

**8. Checkpoint commit**

If `N % <loop.checkpoint_frequency> == 0` OR all tasks are complete:
```bash
git add .
git commit -m "[Pro] Checkpoint: iteration <N> — <work unit name> (<completed>/<total> tasks)"
```
Log the commit hash in `<FEATURE_KNOWLEDGE_DIR>/progress.md`.

**9. Update AGENT.md**

Review what you learned this iteration. If you discovered anything new about how to build, run, or test this project, append it to `<FEATURE_KNOWLEDGE_DIR>/AGENT.md`. Keep each bullet under 20 words. This file is read at the top of every future iteration.

**Print at the end of every iteration:**
```
[Pro] ── Iteration <N> complete — <completed>/<total> tasks ─
```

Then immediately begin iteration N+1 without waiting for user input. **Do not stop between iterations.**

---

The `pro-orchestrate.sh` script is the correct runner when invoked from a terminal (not VS Code Chat). It passes `--knowledge-feature-dir` to each loop invocation and handles circuit-breaking for long runs.

### Phase 6b — Local Review (optional, Ollama sidecar)

After the implement loop completes and before `/pro.evaluate` runs, hand the change set to local models for a first-pass screen. The evaluator (Claude) reads the resulting drafts and verifies — it is **not bound by** what the local model said or missed.

Skip entirely if any of the following is true:
- `local_models.enabled: false` in `pro-config.yml`, or
- `local_models.auto_run.before_evaluate: false`, or
- Ollama is unreachable at `local_models.base_url` (driver self-detects within 3 seconds).

Otherwise:
```
EXECUTE_COMMAND: /pro.local-review
```

Writes three evidence-pack files under `<SPEC_DIR>/local-reviews/`:
- `implementation-review.md` — correctness, regression risk, contract violations
- `test-gap-review.md` — acceptance criteria not exercised by tests
- `security-review.md` — injection / authz / crypto / secrets / unsafe defaults

Each finding must include: file, lines, severity, category, what, evidence quote, why-it-matters, suggested patch, confidence, disproof condition, mapping to AC #. MDASH-inspired: a finding without a file and a line range is dropped. Low false-positive rate is the design goal — see `templates/local/*-review.prompt.md`.

When `/pro.evaluate` runs next, it loads these drafts alongside the sprint contract. They are leads, not verdicts.

No gate. Auto-continue. Self-skips silently if local models are off.

### Phase 7 — Post-implement (reconcile, evaluate, knowledge sync)

Run **after** the implement loop finishes (all tasks `[x]` or max iterations with operator consent to stop). This phase is part of `/pro.go` — do not defer to hooks only.

**7a. Reconcile** — always run when the loop produced code changes:

```
EXECUTE_COMMAND: /pro.reconcile
```

**7b. Local review** — same rules as Phase 6b (if not already run after the last sprint):

```
EXECUTE_COMMAND: /pro.local-review
```

**7c. Evaluate** — mandatory for a completed pipeline:

```
EXECUTE_COMMAND: /pro.evaluate
```

Parse the evaluator's `<pro-eval>` tag from stdout. Proceed to 7d only if the verdict is **PASS**.

**7d. Knowledge sync** — skip if `knowledge.enabled: false` or `knowledge.sync_after_evaluate: false`. Otherwise (PASS required):

```
EXECUTE_COMMAND: /pro.knowledge-sync
```

Default mode is `sync`. Writes `<FEATURE_DIR>/pro-knowledge.md` and may auto-apply additive edits per `knowledge.auto_apply_tier`. If the evaluator did not PASS, print `[Pro] Skipping knowledge-sync — evaluator did not PASS.` and do not run sync.

Append to `session.md`: `Phase 7 complete — reconcile, evaluate, knowledge-sync (if PASS).`

## Completion

After Phase 7 (and all prior phases) complete successfully:

```
╔═══════════════════════════════════════════════════════════╗
║  SpecKit Pro — Pipeline Complete ✓                        ║
╠═══════════════════════════════════════════════════════════╣
║  Feature:  <name>                                         ║
║  Tasks:    <completed>/<total>                            ║
║  Branch:   <git branch>                                   ║
╚═══════════════════════════════════════════════════════════╝

Next: /pro.status <feature>   — detailed progress
      Review <FEATURE_DIR>/pro-drift.md and pro-knowledge.md (if written)
```
