# SpecKit Pro — Improvements Ledger

This file is the **cross-run memory** of the `/pro.go` harness. It is the mechanism
that turns the pipeline from a fixed prompt into something that gets better every run.

- **Written at Phase 8** (`/pro.go` → "Run Report & Self-Improvement"): after a run, a
  curated, actionable learning is appended under _Active learnings_.
- **Read at Phase 0** (`/pro.go` → "Run Start"): the next run loads this file and applies
  the learnings throughout — before specify, while planning, while implementing.

Unlike `.knowledge/metrics/` (machine telemetry, gitignored), this file is **committed**,
so a whole team's runs compound into shared operating wisdom.

> **Promotion is human-gated — the harness never self-promotes.** Phase 0 applies **only
> the entries under `## Promoted`**. Phase 8 (after a run) **appends** to `## Proposed` and
> **curates** the four sections — it never moves an entry into `## Promoted` on its own. A
> human reviews proposals and promotes the ones worth applying (running the Phase 7.5 probe
> gate first is recommended). This keeps the ledger from becoming a reward-hacking channel:
> unvetted lessons can be recorded, but they cannot steer the next run until a person vouches
> for them.

## How to write a good learning

A learning earns its place only if it is **actionable** — it names a habit, a config key,
or a task-shaping rule that a future run can actually follow. "Do better" is not a learning.

New entries are written as **`status: proposed`** with an **`Evidence:`** line (so the claim
is auditable) and an empty **`Promoted-by:`** / **`Disproven-by:`** run-id slot that records
which run a human promotion, or a later disproof, was tied to:

```markdown
- [YYYY-MM-DD] (<feature-slug>, eval <verdict> <score>) status: proposed **<one-line lesson>.**
  Why: <root cause observed this run>.
  Apply: <concrete change a future run should make>.
  Evidence: <run-id / file:line / metric the claim rests on>.
  Promoted-by: <run-id, filled when a human promotes>  Disproven-by: <run-id, filled if a later run refutes it>.
```

On promotion a human flips `status: proposed` → `status: promoted`, fills `Promoted-by:`,
and moves the entry into `## Promoted`. Keep each entry ≤3 lines of prose (the Evidence /
Promoted-by line is in addition).

**Active-entry bound (~50 lines).** `Promoted` + `Proposed` together are the *active* set and
are kept to roughly **50 lines** (`reporting.improvements.max_entries`, default 50), enforced
by **Phase 8d curation**: lowest-value entries are moved to `## Archived`, and entries a later
run disproved are moved to `## Pruned` (with `Disproven-by:` filled). A clean PASS with no
anomalies needs no new entry — a stale learning is worse than none.

## Promoted (applied at Phase 0)

<!-- Only these entries are applied at Phase 0. A human promotes into this section; the harness never self-promotes. Newest first. -->

- [2026-06-05] (meta — harness capability) status: promoted **The implement loop can now fan out independent `[P]` tasks across concurrent sub-agents.**
  Why: until v1.22 Phase 6 was strictly serial ("you are the loop"), so multi-task work-units ran one-at-a-time even when tasks touched disjoint files.
  Apply: for work-units with 2+ file-disjoint `[P]` tasks, set `parallel.phases.implement: true` and dispatch them in parallel; check `run-report.md` afterward for the parallelization factor.
  Evidence: v1.22 shipped Phase 6 parallel implement loop (CHANGELOG [1.22]).  Promoted-by: v1.22 (shipped capability)  Disproven-by: —

- [2026-06-05] (meta — observability) status: promoted **Every run now has a `run-report.md` + a line in `runs.jsonl`.**
  Why: runs were previously untrackable (no duration, no produced-file counts, no recorded verdict).
  Apply: at the start of a run, skim `pro-report.sh aggregate --last 10` for trends; if eval scores trend down, the most recent learnings here are the first suspects.
  Evidence: v1.22 shipped `pro-report.sh` start/finish/aggregate (CHANGELOG [1.22]).  Promoted-by: v1.22 (shipped capability)  Disproven-by: —

## Proposed (awaiting human promotion)

<!-- Phase 8 appends here. NOT applied at Phase 0 until a human promotes into ## Promoted. Newest first. -->

- [2026-06-08] (002-self-improving-orchestration, eval PASS 90) **When implementation fans out across disjoint-file workers, add a dedicated cross-worker INTEGRATION review lens — the seams between independently-built files are where the real bugs hide.**
  Why: each of the 9 workers passed its own frozen contract, yet the seams between them held the worst bugs — `report_phase` emitted a different positional arg order than `cmd_phase` parsed (silent per-phase telemetry loss), and the OTel emitter read `per_phase_durations_s` as a dict while the reporter wrote a list (zero child spans). Neither shows up reviewing one file in isolation.
  Apply: in any multi-file fan-out, make one review lens verify producer↔consumer contracts end-to-end (emitted flags vs accepted flags; written JSON shape vs read shape; cross-file path agreement) and assert observable counts (N phases → N spans), not just per-file correctness.
  Evidence: adversarial triage 74→90; 1 integration bug caught pre-review + 2 HIGH integration bugs caught by the integration lens, all in cross-worker seams.  Promoted-by: —  Disproven-by: —

- [2026-06-08] (002-self-improving-orchestration, eval PASS 90) **Verify external-CLI flags against the installed binary, not docs/memory — and re-verify before shipping a flag-dependent fix.**
  Why: a research pass asserted `--system-prompt-file` exists; `claude --help` on the installed v2.1.116 showed it does NOT (it only appears inside the `--bare` blurb text). Building on the hallucinated flag would have re-introduced the very FR-001 bug being fixed.
  Apply: for any agent-CLI integration, run `<cli> --help` in the session and pin the verified flag surface into the plan/contracts; treat doc/memory claims about flags as unverified until checked.
  Evidence: the design critic + the build both keyed off the verified 2.1.116 surface (no `--system-prompt-file`, no `--max-turns`, `--max-budget-usd` per-invocation).  Promoted-by: —  Disproven-by: —

## Archived (low value / superseded)

<!-- Phase 8d curation moves low-value or superseded entries here to keep the active set ~50 lines. -->

_(none yet)_

## Pruned (disproven)

<!-- Phase 8d curation moves here any entry a later run disproved; disproven-by: records the run-id. -->

_(none yet)_
