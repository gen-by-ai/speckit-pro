---
description: "Repo-level knowledge-base renewal — primes new specs with relevant domain/architecture context, and reconciles `.repo-knowledge/` against code changes after a passing sprint"
---

# SpecKit Pro — Knowledge Base Sync (`pro.knowledge-sync`)

Maintains a curated, repo-level Markdown knowledge base (`.repo-knowledge/`) that captures **business domain, architecture, decisions, and bounded contexts** — facts that don't live in any single feature spec and that the loop otherwise has to rediscover every iteration.

This command has two modes, intended for two hook points:

| Mode | When it fires | What it does |
|---|---|---|
| `prime` (read) | `before_specify`, top of `/pro.go`, top of `/pro.pickup` | Retrieves the top-k `.repo-knowledge/` chunks relevant to the feature, surfaces them to the next agent before the spec is written |
| `sync` (write) | `after_implement`, **only after evaluator PASS** | Diffs the sprint's code changes against claims in `.repo-knowledge/`, writes proposed updates to `<FEATURE_DIR>/pro-knowledge.md` for human review |

`pro.knowledge-sync` **never** silently mutates `.repo-knowledge/`. All write-side output is a per-feature review file (mirrors the `pro-drift.md` pattern from `/pro.reconcile`).

## User Input

```text
$ARGUMENTS
```

Parse from `$ARGUMENTS`:

| Argument | Required | Default | Meaning |
|---|---|---|---|
| `--mode` | no | `sync` | `sync` \| `prime` |
| `--feature` | no | derived from `check-prerequisites.sh` | Feature dir name |
| `--query` | no | derived (prime only) | Override the retrieval query string |
| `--auto-apply` | no | from config | `none` \| `additive` — what classes of edit may auto-merge (never `destructive`) |
| `--refresh-repo-ai` | no | off | Rebuild `repo-ai` index before retrieval (slow; only if it exists) |

## Prerequisites

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` from the repo root and parse **`FEATURE_DIR`**.
2. Derive **`PROJECT_ROOT`** = `git rev-parse --show-toplevel`.
3. **`KNOWLEDGE_DIR`** = `<PROJECT_ROOT>/.repo-knowledge` (note: **versioned**, unlike `.ai-knowledge/`).
4. If `KNOWLEDGE_DIR` does not exist, print:
   ```
   [Pro] No .repo-knowledge/ found — skipping (run /pro.knowledge-sync --mode bootstrap to seed one, or create it by hand).
   ```
   Exit 0. This makes the command safe to wire as a hook before the operator has chosen to adopt the pattern.

## Mode: `prime` (read-only retrieval)

Purpose: ground the **next** agent invocation in repo-level context before it writes a spec or plans tasks, so it doesn't reinvent terms, violate invariants, or duplicate a bounded context that already exists.

### 1. Build the retrieval query

Order of preference for the query string:

1. Explicit `--query "<text>"` if passed.
2. `$ARGUMENTS` minus the flag arguments (typical for `/pro.go <description>`).
3. Concatenation of `spec.md` H1 + first user story title (when called after specify).

Keep the query under ~200 chars — short, distinctive nouns and verbs work better than full sentences for embedding retrieval.

### 2. Retrieve from `.repo-knowledge/` via `repo-ai`

If `repo-ai/vectordb/index.json` exists:

```bash
repo-ai search "<query>" --top-k 8 --root .repo-knowledge
```

If `repo-ai` is not installed but `KNOWLEDGE_DIR/INDEX.md` exists, fall back to a deterministic two-stage scan:

1. `grep -n -i "<each query keyword>"` over `KNOWLEDGE_DIR/INDEX.md` to find decision-tree entries.
2. For each matched entry, follow the relative links and read the linked files (max 5 files, max 200 lines each).

### 3. Emit a prime block

Print to stdout (this is what the next agent will see in context):

```markdown
<pro-knowledge-prime>
Retrieved <N> chunks from .repo-knowledge/ relevant to: "<query>"

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

Purpose: when a sprint successfully passes evaluation, reconcile what was just built against the knowledge base. Propose updates so `.repo-knowledge/` doesn't rot. The operator approves before any edit graduates from `pro-knowledge.md` into the knowledge base.

### 1. Guard: only proceed on evaluator PASS

Read the latest evaluation file: `<AI_KNOWLEDGE_DIR>/evaluations/sprint-<N>.md` (highest `N`).

- No evaluations dir or no files → print `[Pro] No evaluations found — skipping knowledge-sync (sync runs only after a passing sprint).` and exit 0.
- Final line matches `<pro-eval>NEEDS_REVISION:` or `<pro-eval>FAIL:` → print `[Pro] Last sprint did not pass — skipping knowledge-sync to avoid recording unverified code into the knowledge base.` and exit 0.
- Final line matches `<pro-eval>PASS:` → continue.

Rationale: updating docs against not-yet-verified code corrupts the knowledge base. Drift on failure is normal; drift on PASS is the only kind worth recording.

### 2. Compute the change surface

```bash
git diff --name-only HEAD~1   # or the full sprint range if multi-commit
git diff --stat HEAD~1
```

Build a list of changed files. Short-circuit if the change set touches **only** test files, fixtures, comments, or paths none of `.repo-knowledge/` references:

- Quick check: grep `.repo-knowledge/` for each changed file's basename and parent directory.
- Zero hits across all changed files → print `[Pro] No knowledge-relevant changes detected — skipping (only tests/fixtures touched).` and exit 0.

This short-circuit is the single most important cost control. Most sprints don't move the knowledge needle.

### 3. Classify the diff into proposal tiers

For each changed file, classify against `.repo-knowledge/` claims and propose updates. Use **three tiers**:

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
- [ ] **If clarifying proposals > 0:** Edit `.repo-knowledge/` files to incorporate the suggested patches, then delete this file.
- [ ] **If only auto-applied:** Review the auto-edits in `git diff .repo-knowledge/`; commit or revert as a single follow-up commit.

## Retrieval notes

- Queried `repo-ai` with: "<query>"
- Top hits considered: <list of (file, score)>
```

### 5. Apply additive edits (if policy allows)

If `--auto-apply additive` (or config `knowledge.auto_apply_tier: additive`):

- Apply only the proposals tagged `Additive — auto-applied`.
- Edit `.repo-knowledge/` files in place.
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

This is a **draft**, not a real ADR. It graduates to `.repo-knowledge/decisions/ADR-NNNN-*.md` only when a human moves and edits it. The point is to make the cost of recording a decision lower than the cost of ignoring it.

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
| `before_specify` | `prime` | First step of `/pro.go` and `/pro.pickup`, before any spec generation | `KNOWLEDGE_DIR` missing |
| `after_implement` | `sync` | Last step in the after_implement chain (after `pro.evaluate`) | Evaluator did not PASS; only tests/fixtures changed; `KNOWLEDGE_DIR` missing |

## Why this exists

Specs describe **one feature**. `AGENT.md` describes **how to run the project**. Neither captures the layer above: *what does the business mean by "policy", which bounded contexts own writes to `customer`, what invariants must never break*. Without that layer, every new feature rediscovers the domain from code — slowly, and often wrong.

`.repo-knowledge/` is that layer. This command keeps it from rotting. It is **disabled by default** (see `knowledge.enabled` in `pro-config.yml`) — turn it on only after running `/pro.knowledge-sync --mode bootstrap` (or hand-writing an initial `.repo-knowledge/INDEX.md`) and reviewing the seed content. An auto-generated knowledge base that nobody curates is worse than no knowledge base, because the loop will trust its own slop.

## Expected `.repo-knowledge/` layout

```
.repo-knowledge/                # versioned, committed
├── INDEX.md                    # decision tree: "if touching X, read Y, then Z"
├── architecture.md             # systems map + entry points per area
├── domain/
│   ├── glossary.md             # business terms, not code terms
│   ├── <bounded-context>.md    # one per business capability
│   └── invariants.md           # rules that must never break
├── decisions/
│   └── ADR-NNNN-*.md           # accepted decisions, append-only history
└── runbooks/
    └── <flow>.md               # end-to-end traces
```

`INDEX.md` is the decision tree, not a TOC. Each entry should be in the form **"if you are touching X, read Y, then Z"** — the loop traverses it like a router during `prime`.
