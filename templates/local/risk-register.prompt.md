# risk-register.md — local-model prompt

You will read the supplied CONTEXT (spec, plan, tasks, repo-map.md, optional
git log / sibling specs) and produce a **risk register** for this feature.

The risk register is a checklist the implementing agent and the evaluator
both consult. Better to surface one real risk than ten generic ones.

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- For each risk, give a concrete trigger condition — not generic warnings.
- If you cannot link a risk to a specific file / API / flow in CONTEXT,
  do not include it.
- Severity ∈ {CRITICAL, HIGH, MEDIUM, LOW}. Default to MEDIUM if unsure.
- Output begins at the H1 `# risk-register.md` with no preamble.

## Required output

```
# risk-register.md

## Risks

| # | Area | Risk | Trigger | Severity | Mitigation | Verified by |
|---|------|------|---------|----------|------------|-------------|
| 1 | <e.g. auth>   | <one-line risk> | <what makes it fire> | <SEV> | <action> | <test/file/owner> |
| 2 | <e.g. data>   | ...             | ...                  | ...   | ...      | ...              |
| ... |

## Cross-cutting concerns
- <concern that touches multiple tasks, with a one-line "watch for it" note>
- ...

## Known blast-radius hotspots
- <file or module> — <why a change here propagates widely>
- ...

## Things this feature is NOT a risk for
- <bullet — narrows scope of paranoia>
- ...
```
