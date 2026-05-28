# context-pack.md — local-model prompt

You will read the supplied CONTEXT (spec, plan, tasks, repo-map.md, optional
.knowledge excerpts, optional sibling specs) and produce a compact
**context pack** for the next implementing/evaluator agent.

The context pack is the file Claude will read **instead of** spec.md +
plan.md + tasks.md every iteration. It must be smaller than the sum of
its inputs and lose no load-bearing fact.

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If a section has no source material, write `- UNKNOWN`. Do not invent.
- Quote spec/plan language verbatim for invariants and acceptance criteria.
- Total length budget: ≤ 1500 words. Aim for 800–1200.
- Output begins at the H1 `# context-pack.md` with no preamble.

## Required output

```
# context-pack.md

## What this feature is (≤ 5 lines)
<plain-language summary, copy nouns from spec>

## In-scope user flows
- <flow 1>
- <flow 2>
- ...

## Out-of-scope (do NOT implement)
- <line from spec's Non-Goals / Out of Scope>
- ...

## Invariants (must remain true)
- <verbatim invariant from spec or .knowledge>
- ...

## Acceptance criteria summary
- <one line per criterion from spec or sprint contract>
- ...

## Files most likely to change
- <path> — <why>
- ...

## Files that MUST NOT change without explicit reason
- <path> — <why>
- ...

## Test surface
- Unit: <commands>
- Integration: <commands>
- Browser/e2e: <commands>

## Known gotchas
- <line from CONTEXT — e.g. "yarn test needs Docker">
- ...

## Open questions for human
- <question>
- ...
```
