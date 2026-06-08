# `.knowledge/probes/` — evaluator regression net (committed)

This directory is the **committed regression net for the self-improvement loop**. Before
SpecKit Pro ever self-applies a change derived from its own learnings — a promoted ledger
entry (`improvements.md`) or a knowledge-sync auto-apply — `pro-improve-guard.sh check`
re-grades every fixture here through the evaluator (`speckit.pro.evaluate.agent.md`) and
**blocks the apply unless the evaluator still gets every probe right** (`/pro.go` Phase 7.5,
research decision D12). It is the test suite for the grader that gates the grader.

## Why this is committed (the one human-authored config path under `.knowledge/`)

`.knowledge/` is mostly **agent-written and gitignored** (`features/`, `metrics/`, `scan/`).
`probes/` is the deliberate exception: it is **human-authored config that ships in git**,
in the same committed-surface family as `improvements.md` and the per-sprint
`contracts/*.sha256` rubric seals (research "committed-surface carve-out"). It is distinct
from the gitignored **`metrics/`** path — probe *fixtures* are committed here; probe *run
telemetry* is written only under `.knowledge/metrics/probes/<run_id>.jsonl` and stays
ignored. There is no agent write path into this directory; growing it is a deliberate,
reviewed human act.

## Layout

```
.knowledge/probes/
├── README.md
├── known-good/<case>/fixture.md   + <case>/expected   # expected = ACCEPT
└── known-bad/<case>/fixture.md    + <case>/expected    # expected = REJECT
```

Each **case** is exactly two files:

- **`fixture.md`** — a tiny sealed-contract excerpt plus an `End state` section the
  evaluator can grade (kept to ~40 lines so a probe run is cheap). The fixture describes
  the end state inline, so the guard can use a static/`--probe` grade mode instead of
  booting an app.
- **`expected`** — one line, either `ACCEPT` or `REJECT`.

## Verdict mapping

The guard maps the evaluator verdict to a probe outcome:

| Evaluator emits        | Probe outcome |
| ---------------------- | ------------- |
| `<pro-eval>PASS:…`     | `ACCEPT`      |
| `NEEDS_REVISION:*`     | `REJECT`      |
| `FAIL:*`               | `REJECT`      |

The gate passes (exit 0, **APPLY-OK**) iff **every `known-good` case is ACCEPTed** AND
**no `known-bad` case is ACCEPTed**. Any miss → BLOCK. A missing/empty probe set is
**fail-closed** (exit 3): no probes means no proof the grader works, so no self-apply.

## How to grow it (from real disproven learnings)

The seed cases below bootstrap the net. **Grow it from reality**: when a sprint exposes a
failure mode the evaluator should have caught — a stub it waved through, a genuinely-clean
sprint it wrongly rejected, a learning a later run disproved — distill that into a new
minimal case so the grader can never regress on it again. A new `known-bad` for every class
of slip; a new `known-good` for every false rejection.

## Bootstrap

```
bash scripts/bash/pro-improve-guard.sh bootstrap
```

Seeds at least one `known-good` and one `known-bad` case if the set is empty. **Idempotent** —
it never overwrites an existing case.

## Seed cases

- **`known-good/seed-clean-pass/`** — a 1-row CRITICAL contract with an end state that
  genuinely satisfies it (no stubs/TODOs, a trivially-passing check). A correct evaluator
  returns `PASS` → `ACCEPT`.
- **`known-bad/seed-stub-implementation/`** — a 1-row CRITICAL contract with an end state
  whose body is `// TODO: implement` + `return null` while the self-report claims done.
  This is exactly the `/pro.evaluate` **Step 4a stub auto-FAIL** pattern, so a correct
  evaluator `REJECT`s it.
