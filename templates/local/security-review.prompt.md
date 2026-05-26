# security-review.md — local-model prompt

You will read the supplied CONTEXT (sprint contract, diff, modified files,
risk-register.md, optional .repo-knowledge security.md) and produce a
**first-pass security review**.

This review is a screening pass. A stronger model (and ideally a human)
makes the final judgement on exploitability and severity.

## Evidence-pack discipline (mandatory)

For each finding, fill the full evidence pack — these tickets often end up
in real backlogs, so each one must be auditable:

- **File** — `path/from/repo/root.ext`
- **Lines** — `L42-L57`
- **Class** — injection | authn | authz | crypto | deserialization |
  ssrf | secrets | path-traversal | unsafe-default | config | logging |
  supply-chain | other
- **Severity** — CRITICAL | HIGH | MEDIUM | LOW
- **Vulnerable path** — quote the data/control flow (input → sink)
- **Attacker-controlled input** — where it enters
- **Trust boundary crossed** — public-edge | tenant-edge | privilege-edge | none
- **Preconditions** — what state is required for exploit
- **Exploitability reasoning** — 2–4 lines on why this is reachable
- **Minimal trigger** — one line, the smallest input that demonstrates it
- **Suggested patch** — one sentence
- **Regression test** — where it would live, what it asserts
- **Confidence** — high | medium | low
- **Disproof** — what evidence would invalidate the finding

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If you cannot identify a concrete attacker-controlled input, do not file
  the finding — speculative "could be unsafe" reports cause alert fatigue.
- Mark UNKNOWN for any field the CONTEXT cannot support.
- Prefer 3 high-confidence findings to 20 maybe-findings.
- Output begins at the H1 `# security-review.md` with no preamble.

## Required output

```
# security-review.md

## Summary (≤ 3 lines)
<count by class + severity, overall risk feel>

## Findings

### S1 — <short title>
- **File**: `<path>`
- **Lines**: `<range>`
- **Class**: <class>
- **Severity**: <SEV>
- **Vulnerable path**:
  ```
  <input source → ... → sink>
  ```
- **Attacker-controlled input**: <where>
- **Trust boundary crossed**: <which>
- **Preconditions**: <state required>
- **Exploitability reasoning**: <2–4 lines>
- **Minimal trigger**: <one line>
- **Suggested patch**: <one sentence>
- **Regression test**: <path + assertion>
- **Confidence**: <high|medium|low>
- **Disproof**: <what changes your mind>

### S2 — ...

## Anti-findings (looked at, decided NOT a finding)
- <area / pattern> — <why dismissed, one line>
- ...
```
