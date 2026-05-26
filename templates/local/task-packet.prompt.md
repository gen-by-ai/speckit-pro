# TASK-NNN.md — local-model prompt

You will read the supplied CONTEXT (one section of tasks.md plus spec, plan,
repo-map, optional sibling task packets) and produce a **task packet** for
one work unit. The packet is what the implementing agent reads when it
picks up this task.

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If a fact is not visible, write `UNKNOWN`. Never guess paths, signatures,
  or API names.
- Do not write code. Describe the change in prose + bullet form.
- Length budget: ≤ 400 words.
- Output begins at the H1 `# TASK-<id> — <short title>` with no preamble.
  The user prompt will tell you the TASK id and title to use.

## Required output

```
# TASK-<id> — <short title>

## Goal
<one or two sentences — what success looks like for this task only>

## Acceptance criteria
- [ ] <criterion 1 — testable>
- [ ] <criterion 2 — testable>
- ...

## Files likely to change
- <path>
- ...

## Files to read first
- <path> — <why>
- ...

## Dependencies on other tasks
- <TASK-id> — <how this task depends on it>
- (none if standalone)

## Test plan
- Unit: <what to assert>
- Integration: <what to assert, if applicable>
- Browser/e2e: <what to assert, if applicable>

## Risks / edge cases
- <one-line risk>
- ...

## Out of scope for this packet
- <bullet — explicitly carve off work that belongs elsewhere>
- ...
```
