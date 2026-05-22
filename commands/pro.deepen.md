---
description: "Adversarial spec-deepening — challenges thin specs by investigating local + external sources first, then asks the human only the questions that no source can answer. Front-loads rigor so the implement loop has something worth executing."
---

# SpecKit Pro — Spec Deepener (`pro.deepen`)

A thin spec produces thin tasks, which produces an implement loop that quietly drops the helpers, error paths, invariants, and side effects nobody wrote down. `/pro.deepen` is the upstream fix: it reads the draft spec, runs it through a depth checklist, **investigates gaps autonomously from any source it can reach**, proposes cited patches, and asks the human only the questions that genuinely require human judgement.

It is **not** a one-shot Q&A like `/speckit.clarify`. It is a resource-aware investigator that respects the operator's time:

> *Cite or escalate.* Every proposed patch must reference a source. No source → it's a question for the human, never invented prose.

The investigator is **source-agnostic**. It describes the *kind* of source it needs (issue tracker, documentation system, code search) and discovers available tools at run time via capability matching. No specific MCP server, ticket tracker, or doc system is hardcoded.

## Modes

| Mode | What it does |
|---|---|
| (default) | **Investigate** — write `spec-patches.md` (cited proposals) and `spec-questions.md` (human-input needed). Does not modify `spec.md`. |
| `--apply` | **Apply** — read the now-answered questions file plus the patches file, merge into `spec.md` as a single git diff staged for review. Does not commit. |
| `--quick` | Investigate using **local sources only** (skip external capabilities). Useful for prototyping or offline. |

## User Input

```text
$ARGUMENTS
```

Parse from `$ARGUMENTS`:

| Argument | Required | Default | Meaning |
|---|---|---|---|
| `--feature` | no | derived from `check-prerequisites.sh` | Feature dir name |
| `--apply` | no | off | Switch to apply mode |
| `--quick` | no | off | Local sources only |
| `--time-budget` | no | `300` | Total wall-clock budget in seconds |
| `--per-source-budget` | no | `30` | Per-source budget in seconds |
| `--max-questions` | no | `10` | Cap on questions written to `spec-questions.md` |

## Prerequisites

1. Resolve **`FEATURE_DIR`** via `.specify/scripts/bash/check-prerequisites.sh --json`.
2. Verify `FEATURE_DIR/spec.md` exists.
3. Verify the spec is above a minimum threshold (has H1 title + at least one user story). Below threshold → exit with:
   ```
   [Pro] Deepen requires a draft spec with at least a title and one user story. Run /speckit.specify first.
   ```
   Rationale: garbage-in protection — an empty spec gives the investigator nothing to search for.

## Mode: investigate (default)

### Phase 1 — Depth Checklist Gap Analysis

Read `spec.md` (and `plan.md` if it exists). Grade coverage of each section in the **depth checklist**. For each, classify: `COMPLETE` / `PARTIAL` / `MISSING`.

| Section | What "complete" looks like |
|---|---|
| **Data model** | Each entity has fields + types + relationships + ownership (which bounded context writes it) |
| **Invariants** | Business rules that must never break, explicitly stated (not implied by user stories) |
| **Failure modes** | For each user story: what can fail, what the system does about it, what the user sees |
| **Side effects** | What happens off the request path: emails, webhooks, jobs, audit logs |
| **Authorization** | Who can do what, under what conditions; whose data is whose |
| **Idempotency / ordering** | Retries safe? Out-of-order events safe? Replays safe? |
| **Audit / observability** | What gets logged, with what fields, for what compliance/debugging purpose |
| **Integration boundaries** | Who calls in (consumers), who we call out to (dependencies), contracts |
| **Domain glossary** | Business terms used in the spec, with their precise meaning **in this context** |
| **Performance / scale** | Expected volume, latency requirements, growth assumptions |
| **Out-of-scope** | What this feature explicitly does *not* do (essential to prevent scope creep) |
| **Edge cases & failure states** | For every primary user flow, the input × state matrix is enumerated (see below). Each cell has an explicit expected behavior — not just "show an error" |

For each `PARTIAL` or `MISSING` section, generate **specific questions** — not "describe the data model", but "Quote has `bound_at` field — is it set on quote creation or on customer acceptance?".

#### Edge cases — the input × state matrix

Specs that ship without this matrix are the upstream cause of MP-1435-class regressions: a guard is added, the happy path still works, an unseen state breaks production. For every primary user flow in the spec, the **Edge Cases & Failure States** section must enumerate (with explicit expected behavior per cell):

| Axis | Required cells |
|---|---|
| **Inputs** | Empty/missing (every form field, every URL param, every required store slice). Invalid (wrong type, out-of-range, malformed). Boundary (zero, max, off-by-one). |
| **Authorization** | Logged out. Session expired. Insufficient role. Cross-tenant access attempt. |
| **Network** | Offline. Slow (>2s). Request fails (4xx). Request errors (5xx). Request times out. |
| **Concurrency** | Stale data (record changed since fetch). Optimistic-update collision. Double-submit. |
| **Re-entry** | Back button. Hard refresh mid-flow. Deep link bypassing prior step. Browser tab restored from suspend. |
| **State hydration** | Required Redux/zustand slice undefined. Required server-state cache empty. Required cookie absent. |

For each cell that applies to the flow, write a one-line **expected behavior** statement that an evaluator could verify by clicking the live app. "Show an error" is not acceptable; "Form renders with default values, BE call is skipped, no spinner persists" is acceptable.

If a cell genuinely does not apply (e.g. an unauthenticated marketing page has no Authorization axis), write `N/A — <one-sentence reason>`. Skipping silently is not allowed.

### Phase 2 — Autonomous Resolution (cite-or-escalate)

For each question, attempt resolution from sources in priority order. Time-box each source to `--per-source-budget` seconds. Stop on a confident match.

**Tier A — Local sources (always attempted):**

1. **`.repo-knowledge/`** — if it exists, search via `repo-ai search` against `.repo-knowledge/`. Fall back to grep over `INDEX.md` and follow links. This is the highest-trust source (human-curated).
2. **Codebase** — `repo-ai search` over the full repo if the index exists; otherwise `grep -r` for the entities/concepts named in the question. Read the top-k matching files (max 3 files, max 200 lines each).
3. **Sibling specs** — `grep` `specs/*/spec.md` and `specs/*/plan.md` for the entities/concepts in question. Prior decisions on the same area are highly relevant.
4. **Git history** — `git log --since='90 days ago' --all --grep='<keyword>' -- <relevant-paths>` for recent commit messages and PR titles touching the affected paths.

**Tier B — External capability-based sources (optional, skipped in `--quick`):**

At run time, scan available tools (MCP servers, CLI tools, integrations) and match by **capability** — never by specific name:

| Capability | Tool-name patterns to match | What to query |
|---|---|---|
| **Issue tracker** | names containing `jira`, `linear`, `github`, `gitlab`, `issue`, `ticket`, `pivotal`, `asana` | Fetch any ticket IDs (`[A-Z]+-[0-9]+` or `#NNN`) referenced in the spec heading or body. Search related tickets by title nouns. |
| **Documentation system** | names containing `confluence`, `notion`, `wiki`, `docs`, `page`, `coda`, `obsidian` | Search for design docs, RFCs, or ADRs whose titles match feature nouns or entity names. |
| **Discussion / chat** | names containing `slack`, `discord`, `teams`, `chat`, `mattermost` | Search recent threads (last 30 days) for entity names or ticket IDs. **Low signal** — use only when other sources came up empty. |
| **Code search** (external) | names containing `sourcegraph`, `github-search`, `code-search` | Cross-repo searches when the answer might live in a sibling repo. |

If no tool matches a given capability, skip that source **silently** — do not block, do not warn. The capability table is the only place tool names are referenced; the body of the investigator logic operates on capability handles.

If `deepen.sources.<category>: off` in config, skip the category regardless of available tools.

### Phase 3 — Cited Patch Proposals

For each gap that was resolved confidently from one or more sources, draft a spec patch. Each patch **must** include:

- **Target**: section name and (if possible) line range in `spec.md`
- **Proposed text**: a diff block (`-` for removed, `+` for added)
- **Evidence**: ≥1 cited source, each in the form `<source-type>:<locator>` (e.g. `code:src/policy/model.ts:42`, `issue:X-1408`, `docs:Confluence-Policy-Lifecycle-v3`)
- **Confidence**: `high` (multiple agreeing sources) / `medium` (one source, plausible) — `medium` requires human review before apply
- **Conflicts** (if any): if two sources disagreed, list both findings and tag the patch `CONFLICT — escalated to questions`

Write to **`<FEATURE_DIR>/spec-patches.md`** (overwrite each run):

```markdown
# Spec patches — <feature-name>

> Generated by /pro.deepen | <ISO timestamp> | budget used: <T>s/<B>s

## Summary
- High-confidence patches: <n>
- Medium-confidence (review): <n>
- Conflicts → questions: <n>

## Patches

### P1 — Data model: Quote entity (high)
Target: ## Key Entities, line 78
Evidence:
  - code:src/quotes/model.ts:14-32 (field definitions)
  - sibling-spec:specs/004-quote-binding/spec.md:42 (lifecycle states)
  - issue:X-1234 (Quote schema decision)

```diff
- **Quote**: A pricing offer for a customer
+ **Quote**:
+   - `id`: UUID, generated server-side
+   - `customer_id`: FK → Customer
+   - `state`: enum(draft, presented, accepted, bound, expired)
+   - `bound_at`: timestamp, nullable, immutable once set
+   - **Invariant**: once `state` ∈ {bound, expired}, no field except `state` may change
```
```

### Phase 4 — Human Interrogation

For each gap **not** resolved (no source found, or sources conflicted), write a focused question. **Aim for ≤ `--max-questions` (default 10)** — if more gaps remain, prioritize by:

1. Data model gaps (block schema)
2. Invariants (block downstream correctness)
3. Failure modes for P1 user stories
4. Edge-case matrix cells where the expected behavior is undecidable from sources (typical: "what does the UI show when the Redux slice is undefined on first render?")
5. Authorization
6. Everything else

Each question uses **multiple choice when possible** — the operator's time is the scarce resource:

```markdown
## Q1: Can a `Quote` be edited after `state = accepted`?
Section: Key Entities — Quote
Why we're asking: The spec implies edits are allowed (FR-007), but the code in src/quotes/model.ts:54 throws on any update after `accepted`. Sources disagree.

Sources consulted (no clear resolution):
- ✗ .repo-knowledge/: no entry for Quote lifecycle
- ⚠ code: src/quotes/model.ts:54 forbids edits post-accept
- ⚠ issue: X-1408 says "minor edits OK until bound"
- ✗ docs: no design doc on Quote edit policy

Options (check one or add free text):
- [ ] A: No edits after `accepted` — update FR-007 to remove edit capability post-accept
- [ ] B: Edits allowed until `bound` — update code in model.ts:54 to match
- [ ] C: Whitelist of edit-safe fields between `accepted` and `bound` — list which fields
- [ ] D: Other: ___________

Your answer:
```

Write to **`<FEATURE_DIR>/spec-questions.md`** (overwrite each run).

### Phase 5 — Summary

Print to stdout:

```
[Pro] Deepen complete — <feature>
  Depth coverage: <X>/<total> COMPLETE, <Y> PARTIAL, <Z> MISSING
  Auto-resolved: <H> high-confidence + <M> medium-confidence patches → spec-patches.md
  Human input needed: <Q> questions → spec-questions.md
  Sources used: <comma-separated list>  | Time: <T>s / <B>s budget
  Next:
    1. Open spec-questions.md and fill in answers
    2. Run /pro.deepen --apply to merge patches + answers into spec.md
```

## Mode: `--apply`

1. Read `<FEATURE_DIR>/spec-questions.md`. For each question, look for a non-empty "Your answer:" line or a checked option. If any question is unanswered, print which ones and exit 1:
   ```
   [Pro] Apply blocked — <N> questions still unanswered: Q1, Q3, Q5. Fill them in and re-run.
   ```
2. Read `<FEATURE_DIR>/spec-patches.md`. Parse all patches.
3. For each `medium`-confidence patch, require the operator to have annotated it `APPROVED` or `REJECTED` in the patches file (search for `Confidence: medium` blocks; reject if status is missing). Print which need review:
   ```
   [Pro] Apply blocked — <N> medium-confidence patches need APPROVED/REJECTED in spec-patches.md: P3, P7.
   ```
4. Apply all approved patches plus translated human answers to `spec.md` as a single in-place edit.
5. **Do not commit.** Leave the diff in the working tree for the operator's review (`git diff specs/<feature>/spec.md`).
6. Print:
   ```
   [Pro] Deepen --apply complete — <N> patches + <M> human answers merged into spec.md.
     Review: git diff specs/<feature>/spec.md
     Commit if satisfied: git add ... && git commit -m "deepen: <feature>"
   ```

## Design Rules

1. **Cite or escalate.** No source → no patch. Period.
2. **Time-boxed.** Hard budget per source and per run. Investigation is not a research project.
3. **Conflicts surface, never resolve silently.** If two sources disagree, the patch becomes a question.
4. **Multiple choice over open-ended.** Respect the operator's time. Free text is the last option, not the only one.
5. **Re-runnable.** Cheap enough to invoke after every clarify or plan edit. Idempotent on output files.
6. **Never silent mutation.** `spec.md` is only modified in `--apply` mode, and even then only stages the diff — no auto-commit.
7. **Capability-based source discovery.** Tool names appear only in the capability-detection table. The investigator body operates on capability handles (`issue-tracker.fetch(id)`, `docs.search(query)`).
8. **Graceful degradation.** Missing sources are silent skips, not errors. A run with only `.repo-knowledge/` + code should still produce useful questions.

## Output Protocol

End stdout with one of:

```
[Pro] Deepen complete — <N> patches, <M> questions. See spec-patches.md and spec-questions.md.
[Pro] Deepen --apply complete — applied <N> patches and <M> answers. Review git diff.
[Pro] Deepen skipped — <reason>
[Pro] Deepen blocked — <reason>
```

If `FEATURE_DIR` cannot be resolved:

```
[Pro] ERROR: Could not resolve FEATURE_DIR — run from a Spec Kit feature workspace or pass --feature.
```

## Hook Behavior

When fired from **`after_specify`** (the recommended position), runs in investigate mode and pauses the pipeline. The operator answers the questions, runs `/pro.deepen --apply`, and then resumes `/pro.go` (or proceeds manually to `/speckit.clarify` → `/speckit.plan`).

The native `/speckit.clarify` step is **not replaced** by `/pro.deepen` — they have different jobs. Clarify is a single-pass Q&A focused on the user-facing description. Deepen is a structural audit focused on what the spec needs for the implementation to be coherent. Run deepen first; clarify will then have less to ask.

## Why this exists

Three observations from running SpecKit Pro in production:

1. **Specs generated from one-line descriptions are shallow.** The template has placeholders for user stories and FRs; it has no required sections for data model, invariants, side effects, or domain glossary. The agent fills what the template asks for and nothing else.
2. **Thin specs cause "small code parts to be missed" downstream.** The implement loop ticks off "the big idea" of each task; the helpers, error classes, validation, audit logs, and config keys that were never specified never get implemented.
3. **AI is bad at substituting for the deep thinking phase, but good at scaffolding it.** Asking the agent "do you have any clarifying questions?" produces a couple of generic ones. Asking it "investigate each section against this depth checklist, look up what you can from sources, and ask the human only what no source can answer" produces a structured interrogation that genuinely deepens the spec.

`/pro.deepen` is the upstream lever. Invest 5 minutes of agent investigation + 10 minutes of focused human input here, save 30 minutes of bad implementation downstream — and produce a spec that future features can build on without rediscovering the same domain from scratch.
