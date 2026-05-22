# Sprint Contract — Sprint {{SPRINT_NUMBER}}

Feature: {{FEATURE_NAME}}
Created: {{TIMESTAMP}}
Status: PROPOSED | RATIFIED | SUPERSEDED

---

## Scope

**Work unit**: {{WORK_UNIT_NAME}}
**Tasks covered** (from tasks.md):

```
{{TASK_LIST}}
```

---

## Acceptance Criteria

> Each row asserts one (user flow × state) cell from the spec's Edge Cases & Failure States section.
> Every user-facing flow needs: 1 happy-path row + ≥3 edge-case rows drawn from distinct matrix axes.
> Any new branching control flow (guards, short-circuits) needs a row per branch.
> See `commands/pro.contract.md` for full row schema.

| # | User Flow | State | Expected Behavior | Severity | Failure Mode | Browser Test | Verified By |
|---|---|---|---|---|---|---|---|
| 1.0 | {{flow_1}} | Happy path | {{expected_1_0}} | CRITICAL | loud | `browser-tests/{{flow_1_slug}}/01-happy.sh` | `{{unit_test_1}}` |
| 1.1 | {{flow_1}} | {{edge_state_1_1}} | {{expected_1_1}} | CRITICAL | silent | `browser-tests/{{flow_1_slug}}/02-{{edge_slug_1_1}}.sh` | `{{unit_test_2}}` |
| 1.2 | {{flow_1}} | {{edge_state_1_2}} | {{expected_1_2}} | CRITICAL | loud | `browser-tests/{{flow_1_slug}}/03-{{edge_slug_1_2}}.sh` | `{{unit_test_3}}` |
| 1.3 | {{flow_1}} | {{edge_state_1_3}} | {{expected_1_3}} | MEDIUM | silent | `browser-tests/{{flow_1_slug}}/04-{{edge_slug_1_3}}.sh` | `browser-only` |

**Severity guide**:
- CRITICAL — sprint fails if not met (core functionality broken). All `silent` failure-mode rows are auto-promoted to CRITICAL regardless of typed severity.
- MEDIUM — sprint needs revision if not met
- LOW — informational; doesn't block sprint

**Failure-mode guide**:
- `silent` — regression produces no error/stack trace/log line; UI just looks wrong (blank panel, stuck spinner, no-op button). Worst class — no monitoring catches it.
- `loud` — regression produces a console error, 4xx/5xx, or visible error message.

---

## Out of Scope

The following will NOT be implemented in this sprint (deferred):

- {{out_of_scope_1}}

---

## Edge-Case Waivers

> Rows from the spec's Edge Cases & Failure States matrix that this sprint intentionally does NOT cover.
> Every waiver must cite a reason and the sprint in which it will be addressed.

- {{waiver_or_none}}

---

## Technical Constraints

- Follow tech stack from plan.md: {{TECH_STACK_SUMMARY}}
- No new dependencies without noting them here
- New files created: {{EXPECTED_NEW_FILES}}
- Files modified: {{EXPECTED_MODIFIED_FILES}}

---

## Definition of Done

This sprint is DONE when:

1. All CRITICAL rows pass — both the Browser Test script (`exit 0`) AND the Verified By unit/integration test (green)
2. All tasks in `tasks.md` are marked `[x]`
3. No broken imports, no missing wiring, no stub function bodies (`TODO`, `throw new Error('not implemented')`, empty function bodies in implementation files)
4. All prior sprints' Browser Test scripts under `browser-tests/**` still pass (regression carry-forward — no new sprint may regress an older one)
5. Edge-Case Waivers section is either empty or every entry cites a deferring sprint

---

## Ratification

> The evaluator must sign off on this contract before implementation starts.
> If the evaluator rejects, generator revises the contract.

- [ ] Generator proposed: {{TIMESTAMP}}
- [ ] Evaluator ratified: _pending_
- [ ] Notes: _none_
