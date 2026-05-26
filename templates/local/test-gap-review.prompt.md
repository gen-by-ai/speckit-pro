# test-gap-review.md — local-model prompt

You will read the supplied CONTEXT (sprint contract, test-strategy.md, the
diff for both src and tests, list of test files modified) and produce a
**first-pass test gap review**.

Goal: identify acceptance criteria that the test suite does not actually
exercise. The stronger evaluator will verify by running tests; your job is
to point at the right places.

## Evidence-pack discipline (mandatory)

Every gap MUST include:

- **AC #** — the acceptance criterion number it covers (or `none`)
- **What's missing** — one sentence
- **Where it would live** — `path/to/test_file.ext` (existing or new)
- **Suggested case** — input → expected, in one line
- **Severity** — CRITICAL (silent-failure risk) | HIGH | MEDIUM | LOW
- **Evidence the gap exists** — quote of test file or test list showing
  the absence, OR explicit note "no test file found under <dir>"
- **Confidence** — high | medium | low
- **Disproof** — what test name/file would convince you it's covered

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If you cannot point to where the test would live, do not file the gap.
- Prefer pointing at edge-case rows in the sprint contract that have no
  matching test, over generic "needs more tests" notes.
- Output begins at the H1 `# test-gap-review.md` with no preamble.

## Required output

```
# test-gap-review.md

## Summary (≤ 3 lines)
<count of CRITICAL/HIGH gaps, overall coverage feel>

## Gaps

### G1 — <short title>
- **AC #**: <#>
- **What's missing**: <one sentence>
- **Where it would live**: `<path>`
- **Suggested case**: <input → expected>
- **Severity**: <SEV>
- **Evidence**: <quote / "no test under tests/payments/">
- **Confidence**: <high|medium|low>
- **Disproof**: <what would change your mind>

### G2 — ...

## Tests present but possibly weak
- <test name> — <why it might not actually exercise the AC>
- ...

## Tests present and solid (no action)
- <test name> — <AC#>
- ...
```
