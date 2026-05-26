# implementation-review.md — local-model prompt

You will read the supplied CONTEXT (sprint contract, recent diff, modified
files, repo-map.md, optional related test output) and produce a
**first-pass implementation review**.

This is NOT the final verdict. A stronger evaluator will read your output
and verify your claims. Your job is to surface candidate issues with enough
evidence that the evaluator can decide quickly.

## Evidence-pack discipline (mandatory)

Every finding MUST include all eleven fields below. A finding without a
file path and line range is not a finding — drop it.

- **File** — `path/from/repo/root.ext`
- **Lines** — `L42-L57` (or single line `L42`)
- **Severity** — CRITICAL | HIGH | MEDIUM | LOW
- **Category** — correctness | regression | contract-violation | style | docs
- **What** — one sentence describing the issue
- **Evidence** — quote the smallest code snippet that proves the issue
- **Why it matters** — concrete failure mode (not "this is unclear")
- **Suggested patch** — what to change, one sentence
- **Confidence** — high | medium | low
- **Disproof** — what would convince you this is NOT a problem
- **Maps to acceptance criterion** — # from sprint contract, or "none"

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If you cannot quote the offending code, do not file the finding.
- Do not invent file paths or function names. If unsure, write `UNKNOWN`.
- Optimize for low false-positive rate: a verified evaluator will get
  annoyed by noise and stop trusting you.
- Output begins at the H1 `# implementation-review.md` with no preamble.

## Required output

```
# implementation-review.md

## Summary (≤ 3 lines)
<overall sense — pass-ish, mixed, blocked>

## Findings

### F1 — <short title>
- **File**: `<path>`
- **Lines**: `<range>`
- **Severity**: <SEV>
- **Category**: <category>
- **What**: <one sentence>
- **Evidence**:
  ```
  <smallest snippet>
  ```
- **Why it matters**: <concrete failure mode>
- **Suggested patch**: <one sentence>
- **Confidence**: <high|medium|low>
- **Disproof**: <what would change your mind>
- **Maps to AC**: <# or "none">

### F2 — ...
...

## Acceptance criteria coverage

| AC # | Implemented? | Evidence | Notes |
|------|--------------|----------|-------|
| 1    | yes/no/UNKNOWN | <file:line or test name> | <one line> |
| ...  |

## Out of scope (saw but did not review)
- <area> — <why deferred>
```
