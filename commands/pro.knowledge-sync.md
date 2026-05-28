---
description: "Repo-level knowledge-base renewal — primes new specs with relevant domain/architecture context, and reconciles `.knowledge/` against code changes after a passing sprint"
---

# SpecKit Pro — Knowledge Base Sync (`pro.knowledge-sync`)

Maintains the unified **`.knowledge/`** tree: shared team docs at the repo root (commit to git) plus per-feature workspace under **`features/<slug>/`** (gitignored). Captures domain language, architecture, invariants, and autonomous-run state the loop would otherwise rediscover every iteration.

This command has two modes, intended for two hook points:

| Mode | When it fires | What it does |
|---|---|---|
| `prime` (read) | `before_specify`, `before_plan`, `before_implement`, top of `/pro.go`, `/pro.pickup`, each `/pro.loop` iteration | Retrieves relevant `.knowledge/` chunks and surfaces a `<pro-knowledge-prime>` block |
| `sync` (write) | `after_implement`, **only after evaluator PASS** | Diffs the sprint's code changes against claims in `.knowledge/`, writes proposed updates to `<FEATURE_DIR>/pro-knowledge.md` for human review |
| `bootstrap` (seed) | First run when `.knowledge/` is missing and `knowledge.auto_bootstrap: true` | Copies starter templates into `.knowledge/` (does not overwrite existing files) |

`pro.knowledge-sync` **never** silently mutates `.knowledge/`. All write-side output is a per-feature review file (mirrors the `pro-drift.md` pattern from `/pro.reconcile`).

## User Input

```text
$ARGUMENTS
```

Parse from `$ARGUMENTS`:

| Argument | Required | Default | Meaning |
|---|---|---|---|
| `--mode` | no | `sync` | `sync` \| `prime` \| `bootstrap` |
| `--feature` | no | derived from `check-prerequisites.sh` | Feature dir name |
| `--query` | no | derived (prime only) | Override the retrieval query string |
| `--auto-apply` | no | from config | `none` \| `additive` — what classes of edit may auto-merge (never `destructive`) |

## Prerequisites

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` from the repo root and parse **`FEATURE_DIR`**.
2. Derive **`PROJECT_ROOT`** = `git rev-parse --show-toplevel`.
3. **`KNOWLEDGE_DIR`** = `<PROJECT_ROOT>/<knowledge.root_dir>` (default `.knowledge`). Shared files (`INDEX.md`, `domain/`, …) live here and are **versioned**. Legacy: if `INDEX.md` is missing but `.repo-knowledge/INDEX.md` exists, use `.repo-knowledge` and print: run `/speckit.pro.knowledge-migrate`.
4. **`FEATURE_KNOWLEDGE_DIR`** = `<KNOWLEDGE_DIR>/<knowledge.features_subdir>/<feature>` (default `features/`). Legacy: `.ai-knowledge/<feature>` if the new path does not exist yet.
5. If `KNOWLEDGE_DIR` does not exist:
   - **`--mode bootstrap`**, or **`knowledge.auto_bootstrap: true`** with `knowledge.enabled: true` → run [Mode: bootstrap](#mode-bootstrap-seed-starter-tree) below, then continue if the invoked mode was `prime` or `sync`.
   - Otherwise print `[Pro] No .knowledge/ found — skipping (run /pro.knowledge-migrate, /pro.knowledge-sync --mode bootstrap, or set knowledge.auto_bootstrap: true).` and exit 0.
6. If `knowledge.enabled: false` in `pro-config.yml` and `--mode` is not `bootstrap`, exit 0 with `[Pro] knowledge.enabled is false — skipping.`

## Mode: bootstrap (seed starter tree)

Creates `.knowledge/` from extension templates when the directory is missing or sparse. **Never overwrites** an existing file.

1. Resolve template root (first match):
   - `<PROJECT_ROOT>/.specify/extensions/pro/templates/knowledge/`
   - `<PROJECT_ROOT>/templates/knowledge/` (when developing SpecKit Pro itself)
   - Legacy: `templates/repo-knowledge/` (same layout)
2. Copy each file into **`KNOWLEDGE_DIR`** root preserving relative paths (`INDEX.md`, `architecture.md`, `domain/*.md`, `decisions/README.md`). **Do not** copy into `features/` or `metrics/`.
3. `mkdir -p` for `domain/`, `decisions/`, `runbooks/`, `features/`, `metrics/`.
4. If `runbooks/` is empty, add `runbooks/README.md` with one line: `End-to-end traces go here (request → handlers → DB → side effects).`
5. Print:
   ```
   [Pro] Bootstrapped .knowledge/ from templates — edit INDEX.md and domain/invariants.md before relying on primes.
   ```
6. Exit 0 unless the caller also requested `prime` or `sync` in the same invocation (then continue into that mode).

## Mode: `prime` (read-only retrieval)

Purpose: ground the **next** agent invocation in repo-level context before it writes a spec or plans tasks, so it doesn't reinvent terms, violate invariants, or duplicate a bounded context that already exists.

### 1. Build the retrieval query

Order of preference for the query string:

1. Explicit `--query "<text>"` if passed.
2. `$ARGUMENTS` minus the flag arguments (typical for `/pro.go <description>`).
3. Concatenation of `spec.md` H1 + first user story title (when called after specify).

Keep the query under ~200 chars — short, distinctive nouns and verbs work better for keyword matching.

### 2. Retrieve from `.knowledge/` (grep + link follow)

If `KNOWLEDGE_DIR/INDEX.md` exists, run a deterministic two-stage scan:

1. `grep -n -i "<each query keyword>"` over `KNOWLEDGE_DIR/INDEX.md` to find decision-tree entries.
2. For each matched entry, follow the relative links and read the linked files (max 5 files, max 200 lines each).

If `INDEX.md` is missing, grep the top-level `.knowledge/*.md` files for the same keywords (max 5 files, max 200 lines each).

**Always include** (if present, max 120 lines each — these are small and high-signal):
- `domain/invariants.md`
- `domain/glossary.md`
- The `architecture.md` section whose heading best matches a query keyword

### 3. Emit a prime block

Print to stdout (this is what the next agent will see in context):

```markdown
<pro-knowledge-prime>
Retrieved <N> chunks from .knowledge/ relevant to: "<query>"

## Decision-tree entry points
- INDEX.md → <heading or rule that matched>

## Domain notes
- <file>:<heading> — <one-line excerpt>

## Architecture notes
- <file>:<heading> — <one-line excerpt>

## Active invariants
- <invariants.md heading> — <one-line excerpt>

## Decisions to respect
- ADR-<NNNN> <title> — <status: accepted/superseded> — <one-line summary>
</pro-knowledge-prime>
```

If retrieval returned zero hits, emit an empty block with a single line: `No relevant prior knowledge found — this feature appears to be in unexplored territory. Consider whether a new bounded context or ADR will be needed.`

### 4. Exit

Print: `[Pro] Knowledge prime complete — surfaced <N> chunks for: "<query>".`

The prime mode does **not** write any files. It is pure retrieval.

## Mode: `sync` (post-implement renewal)

Purpose: when a sprint successfully passes evaluation, reconcile what was just built against the knowledge base. Propose updates so `.knowledge/` doesn't rot. The operator approves before any edit graduates from `pro-knowledge.md` into the knowledge base.

### 1. Guard: only proceed on evaluator PASS

Read the latest evaluation file: `<FEATURE_KNOWLEDGE_DIR>/evaluations/sprint-<N>.md` (highest `N`).

- No evaluations dir or no files → print `[Pro] No evaluations found — skipping knowledge-sync (sync runs only after a passing sprint).` and exit 0.
- Final line matches `<pro-eval>NEEDS_REVISION:` or `<pro-eval>FAIL:` → print `[Pro] Last sprint did not pass — skipping knowledge-sync to avoid recording unverified code into the knowledge base.` and exit 0.
- Final line matches `<pro-eval>PASS:` → continue.

Rationale: updating docs against not-yet-verified code corrupts the knowledge base. Drift on failure is normal; drift on PASS is the only kind worth recording.

### 2. Compute the change surface

```bash
git diff --name-only HEAD~1   # or the full sprint range if multi-commit
git diff --stat HEAD~1
```

Build a list of changed files. Short-circuit if the change set touches **only** test files, fixtures, comments, or paths none of `.knowledge/` references:

- Quick check: grep `.knowledge/` for each changed file's basename and parent directory.
- Zero hits across all changed files → print `[Pro] No knowledge-relevant changes detected — skipping (only tests/fixtures touched).` and exit 0.

This short-circuit is the single most important cost control. Most sprints don't move the knowledge needle.

### 3. Classify the diff into proposal tiers

For each changed file, classify against `.knowledge/` claims and propose updates. Use **three tiers**:

| Tier | Examples | Auto-apply policy |
|---|---|---|
| `additive` | New endpoint not yet in `architecture.md`; new module not in the file inventory; new term in a type/enum that should join `glossary.md` | Auto-apply if `--auto-apply additive` (default per config) |
| `clarifying` | Existing description that's now imprecise (e.g. "POST /x returns JSON" but it now returns an envelope `{data, meta}`) | Always proposal-only, never auto-apply |
| `breaking` | Edit to `invariants.md` ("payments are always idempotent" → no longer true); ADR status change; bounded-context boundary moved | Always proposal-only; flag as **`REVIEW REQUIRED`** with high prominence |

**Never** auto-edit:
- Files under `decisions/` (ADRs are append-only history)
- `invariants.md`
- Any file in `domain/` (business language is human-curated)

### 4. Write `pro-knowledge.md`

Write to `<FEATURE_DIR>/pro-knowledge.md` (overwrite each run):

```markdown
# Knowledge sync — <feature-name>

> Generated by SpecKit Pro Knowledge Sync | <ISO timestamp>
> Feature dir: <FEATURE_DIR>
> Sprint evaluated: sprint-<N> (PASS, score <X>/100)

## Summary

- **Additive proposals:** <n>  (<a> auto-applied)
- **Clarifying proposals:** <n>  (review-required)
- **Breaking proposals:** <n>  (review-required, blocks merge)

## Proposals

### Additive — auto-applied
- ✅ `architecture.md` — added `POST /auth/refresh` to API surface table (line 142)
- ✅ `glossary.md` — added term `RefreshToken` from `src/auth/types.ts`

### Additive — pending (auto-apply disabled)
- [ ] `architecture.md` — would add new module `src/billing/proration/`

### Clarifying — REVIEW REQUIRED
- [ ] `architecture.md:#payment-flow` — description says "POST /pay returns 200 with token"; code now returns `{data: {token}, meta: {...}}`. Suggested patch in fenced block below.
  ```diff
  - POST /pay returns 200 with token
  + POST /pay returns 200 with `{ data: { token }, meta: {...} }`
  ```

### Breaking — REVIEW REQUIRED (blocks merge)
- ⚠ `invariants.md` — "All writes go through `repo.save()`" — sprint introduced direct `db.exec()` calls in `src/billing/refund.ts`. Either revert the direct call, or update the invariant **and** open an ADR explaining why.

## Recommended follow-ups

- [ ] **If breaking proposals > 0:** Resolve before merging the feature branch.
- [ ] **If clarifying proposals > 0:** Edit `.knowledge/` files to incorporate the suggested patches, then delete this file.
- [ ] **If only auto-applied:** Review the auto-edits in `git diff .knowledge/`; commit or revert as a single follow-up commit.

## Retrieval notes

- Query keywords: <list>
- Files read: <list of paths from INDEX.md link follow>
```

### 5. Apply additive edits (if policy allows)

If `--auto-apply additive` (or config `knowledge.auto_apply_tier: additive`):

- Apply only the proposals tagged `Additive — auto-applied`.
- Edit `.knowledge/` files in place.
- **Do not commit.** Leave the edits staged in the working tree for the operator's next checkpoint commit to pick up. (Same scope-of-autonomy stance as the rest of the loop: never push, never make irreversible changes alone.)

If policy is `none`, every proposal goes into the review file unchanged.

### 6. ADR proposal (optional, if any breaking-tier item exists)

If any `breaking` proposal exists, scaffold a draft ADR at `<FEATURE_DIR>/pro-knowledge-adr-draft.md`:

```markdown
# ADR-<auto-incremented>: <title>

Status: DRAFT — proposed by knowledge-sync after sprint-<N>
Date: <ISO timestamp>

## Context
<what changed in the sprint that conflicts with an existing invariant>

## Decision
<placeholder — human fills in>

## Consequences
<placeholder>

## Supersedes
- <existing ADR if applicable>
```

This is a **draft**, not a real ADR. It graduates to `.knowledge/decisions/ADR-NNNN-*.md` only when a human moves and edits it. The point is to make the cost of recording a decision lower than the cost of ignoring it.

## Output Protocol

End stdout with one of:

```
[Pro] Knowledge sync complete — A additive (X auto-applied), C clarifying, B breaking. See <FEATURE_DIR>/pro-knowledge.md
[Pro] Knowledge sync skipped — <reason>
[Pro] Knowledge prime complete — surfaced N chunks for: "<query>"
```

If `<FEATURE_DIR>` cannot be resolved (sync mode only):

```
[Pro] ERROR: Could not resolve FEATURE_DIR — run from a Spec Kit feature workspace or pass --feature.
```

## Hook Behavior

| Hook | Mode | Position | Skip conditions |
|---|---|---|---|
| `/pro.go` Phase 0 | `prime` | Pipeline start | `prime_before_specify: false` |
| `/pro.go` Phase 2.5 | `prime` | Before plan | `prime_before_plan: false` |
| `/pro.go` Phase 4 | `prime` | After tasks, before contract | `prime_before_contract: false` |
| `/pro.go` Phase 5a | `prime` | Before implement loop | `prime_before_implement: false` |
| `/pro.go` Phase 6 | `prime` | Each loop iteration | `prime_each_loop_iteration: false` |
| `/pro.go` Phase 7d | `sync` | After `pro.evaluate` PASS | `sync_after_evaluate: false` |
| Hooks (`before_specify`, etc.) | `prime`/`sync` | Native SpecKit phases when not using `/pro.go` | Same skip flags |
| `/pro.pickup` | `prime` + Phase 7 `sync` | Pickup entry and post-loop | Same as `/pro.go` |

## Why this exists

Specs describe **one feature**. `AGENT.md` describes **how to run the project**. Neither captures the layer above: *what does the business mean by "policy", which bounded contexts own writes to `customer`, what invariants must never break*. Without that layer, every new feature rediscovers the domain from code — slowly, and often wrong.

`.knowledge/` is that layer. This command keeps it from rotting. **`knowledge.enabled` defaults to `true`** — on first run, `auto_bootstrap` seeds a starter tree you should edit (especially `INDEX.md` and `domain/invariants.md`). Treat auto-seeded placeholders as scaffolding, not ground truth, until a human replaces them.

## Expected `.knowledge/` layout

```
.knowledge/
├── INDEX.md, architecture.md, domain/, decisions/, runbooks/   # COMMIT (team truth)
├── features/<slug>/          # GITIGNORE — AGENT.md, contracts/, progress.md, init.sh
└── metrics/local-metrics.jsonl
```

Legacy: `.repo-knowledge/` + `.ai-knowledge/<slug>/` — still read if not migrated. Run **`/speckit.pro.knowledge-migrate`** once to move everything into `.knowledge/`.

`INDEX.md` is the decision tree, not a TOC. Each entry should be in the form **"if you are touching X, read Y, then Z"** — the loop traverses it like a router during `prime`.
