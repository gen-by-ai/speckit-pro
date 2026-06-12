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

- [2026-06-11] (v1.24 survive-the-night) status: proposed **Under `set -euo pipefail`, every `var=$(… | grep …)` is a death trap on the no-match path — guard each one with `|| var=""`.**
  Why: two latent production bugs had the same shape: the status-tag scrape pipeline killed the orchestrator on any tag-less agent answer (making the `ERROR:no-status-tag` branch unreachable dead code), and a bare `handle_eval_result; rc=$?` died the moment the evaluator returned NEEDS_REVISION. Both were unreachable in happy-path manual testing; the fake-agent state-machine suite hit them on its first run.
  Apply: grep orchestration scripts for `$(`…`grep`/unguarded function-calls-followed-by-`$?` under set -e; pin each terminal path with a hermetic fake-CLI test (scripts/tests/orchestrator-smoke.sh pattern) — error paths only execute at 3am, so only tests ever exercise them.
  Evidence: pro-orchestrate.sh parse_agent_result (pre-v1.24 rungs 1+2) + evaluator cycle; caught by orchestrator-smoke.sh checks unknown-counts-toward-breaker / statusfile-contract / eval-malformed-score-revision.  Promoted-by: —  Disproven-by: —

- [2026-06-10] (v1.23.1 post-release validation) status: proposed **Make the dev/test environment byte-identical to the consumer environment — divergence masks whole defect classes.**
  Why: the dev install shipped gitignored specs/ into the extension, so unshippable schema references "worked" locally (4 surfaces pointed at paths consumers can never have); separately, scratch-repo tests without .gitignore missed that exclude pathspecs naming gitignored dirs make `git add` exit 1 — every checkpoint would have failed in real consumer projects.
  Apply: keep .extensionignore aligned with what `git archive` ships (dev installs = consumer package); when testing git/FS behavior, replicate the consumer's ignore/config state in fixtures; smoke-test from the INSTALLED copy, not the source tree.
  Evidence: test-installed-v123 workflow (84 checks) → PKG-001/002/003 + the addIgnoredFile exit-1 repro; fixes in v1.23.1.  Promoted-by: —  Disproven-by: —

- [2026-06-10] (003-autonomy-reliability-hardening, eval PASS 87) status: proposed **Hunt default-branch fallbacks that return success — the worst silent failure is a catch-all that treats unknown states as OK.**
  Why: the orchestrator's evaluator-verdict fallback was `*) … treating as PASS; return 0` — a malformed/ERROR verdict shipped unverified code; three audits described it as a mere "implicit non-pass" until the code was read.
  Apply: when auditing failure handling, grep every `case` catch-all and `except`/`|| true` default for a success return; classify unknown states as explicit failures with a recorded reason.
  Evidence: pro-orchestrate.sh handle_eval_result (pre-fix ~line 820) vs the v1.23 fix; run run-20260610-042941-065f.  Promoted-by: —  Disproven-by: —

- [2026-06-10] (003-autonomy-reliability-hardening, eval PASS 87) status: proposed **Write pattern assertions per defect CLASS (repo-wide grep), not per file — single-file contract rows let sibling defects survive.**
  Why: sprint-3's row scoped `git add .` removal to pro-orchestrate.sh; the identical pattern lived on in pro-checkpoint.sh and the pro.go.md protocol and was only caught by the evaluator's repo-wide sweep, forcing a revision pass.
  Apply: when a contract row bans a code pattern, make its check `grep -r` the whole shipped surface (scripts/ + commands/), and name the defect class in the row, not the file.
  Evidence: check_checkpoint_patterns widened post-eval; evaluation sprint-7 finding #1.  Promoted-by: —  Disproven-by: —

- [2026-06-08] (002-self-improving-orchestration, eval PASS 90) **When implementation fans out across disjoint-file workers, add a dedicated cross-worker INTEGRATION review lens — the seams between independently-built files are where the real bugs hide.**
  Why: each of the 9 workers passed its own frozen contract, yet the seams between them held the worst bugs — `report_phase` emitted a different positional arg order than `cmd_phase` parsed (silent per-phase telemetry loss), and the OTel emitter read `per_phase_durations_s` as a dict while the reporter wrote a list (zero child spans). Neither shows up reviewing one file in isolation.
  Apply: in any multi-file fan-out, make one review lens verify producer↔consumer contracts end-to-end (emitted flags vs accepted flags; written JSON shape vs read shape; cross-file path agreement) and assert observable counts (N phases → N spans), not just per-file correctness.
  Evidence: adversarial triage 74→90; 1 integration bug caught pre-review + 2 HIGH integration bugs caught by the integration lens, all in cross-worker seams.  Promoted-by: —  Disproven-by: —

- [2026-06-08] (002-self-improving-orchestration, eval PASS 90) **Verify external-CLI flags against the installed binary, not docs/memory — and re-verify before shipping a flag-dependent fix.**
  Why: a research pass asserted `--system-prompt-file` exists; `claude --help` on the installed v2.1.116 showed it does NOT (it only appears inside the `--bare` blurb text). Building on the hallucinated flag would have re-introduced the very FR-001 bug being fixed.
  Apply: for any agent-CLI integration, run `<cli> --help` in the session and pin the verified flag surface into the plan/contracts; treat doc/memory claims about flags as unverified until checked.
  Evidence: the design critic + the build both keyed off the verified 2.1.116 surface (no `--system-prompt-file`, no `--max-turns`, `--max-budget-usd` per-invocation). Second incident 2026-06-10: spec-kit 0.10.1 renamed `init --ai`→`--integration` and dropped `--no-git`, breaking update-all.sh step 2 mid-run right after step 1 self-upgraded the CLI — fixed in v1.23.2 by probing `specify init --help` at runtime.  Promoted-by: —  Disproven-by: —

## Archived (low value / superseded)

<!-- Phase 8d curation moves low-value or superseded entries here to keep the active set ~50 lines. -->

_(none yet)_

## Pruned (disproven)

<!-- Phase 8d curation moves here any entry a later run disproved; disproven-by: records the run-id. -->

_(none yet)_
