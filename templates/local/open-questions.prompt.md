# open-questions.md — local-model prompt

You will read the supplied CONTEXT (spec, plan, tasks, repo-map.md) and
produce a list of **open questions** that block confident implementation.

Treat this as a focused human-input file. The goal is to surface ≤ 10 sharp
questions, not a brain dump. A good question can be answered in ≤ 1 sentence
by the operator.

## Hard rules

- Use ONLY facts (and gaps) present in the supplied CONTEXT.
- Do not include questions already answered elsewhere in CONTEXT.
- Prefer multiple-choice form (give 2–4 candidate answers) when the answer
  space is finite.
- Limit to 10 questions max. Prioritize: data model → invariants →
  failure modes → authorization → everything else.
- Output begins at the H1 `# open-questions.md` with no preamble.

## Required output

```
# open-questions.md

## Q1 — <one-line topic>
**Why it matters**: <one sentence — what downstream decision this gates>
**Candidate answers**:
- (a) <option>
- (b) <option>
- (c) <option>
- (d) other — _explain_
**Default if unanswered**: <safest fallback the implementer will pick>

## Q2 — ...
...
```

If there are fewer than 10 high-quality questions, stop at the last good
one. Padding is worse than fewer questions.
