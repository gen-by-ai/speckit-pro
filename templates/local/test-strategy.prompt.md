# test-strategy.md — local-model prompt

You will read the supplied CONTEXT (spec, plan, tasks, repo-map.md, existing
test files if present) and produce a **test strategy** for this feature.

This is a draft for the implementing agent. It does not need to be exhaustive
— it needs to be specific and grounded in what the project actually uses.

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- Prefer commands that appear in CI workflows in CONTEXT — those are the
  canonical ones the project actually runs.
- If a tool/framework is not visible in CONTEXT, write `UNKNOWN`.
- Do not write actual test code. List test cases as bullets.
- Output begins at the H1 `# test-strategy.md` with no preamble.

## Required output

```
# test-strategy.md

## Test commands (run these locally before declaring done)
- <command>
- ...

## Unit test cases
- <component / function> — <what to assert, including the negative path>
- ...

## Integration test cases
- <flow> — <inputs, expected state changes, what to assert>
- ...

## Browser / e2e cases (if UI is in scope)
- <user flow> — <what the test should click/assert>
- ...

## Edge cases (per user flow × state matrix)
- <flow> × <empty store> — <expected behavior>
- <flow> × <slow network> — <expected behavior>
- <flow> × <permission denied> — <expected behavior>
- ...

## Test gaps to flag for human review
- <area where coverage is questionable>
- ...

## Out of scope (this feature does not own)
- <area>
- ...
```
