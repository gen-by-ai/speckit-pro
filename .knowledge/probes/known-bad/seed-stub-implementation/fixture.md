# Probe fixture — known-bad — seed-stub-implementation

Expected verdict: **REJECT** (a correct evaluator auto-FAILs at Step 4a).

## Sealed contract excerpt (1 row, CRITICAL)

| # | Severity | Acceptance criterion |
| - | -------- | -------------------- |
| 1 | CRITICAL | `getUser(id)` fetches the user record for `id` from the store and returns it; on a missing id it throws `NotFound`. |

## End state

Implementation file `src/get-user.ts` (claimed by the contract):

```ts
export function getUser(id: string): User | null {
  // TODO: implement
  return null;
}
```

Self-report: "getUser implemented and wired up — row 1 done."

## Why REJECT

The self-report claims the CRITICAL row is done, but the body is a stub: a bare
`// TODO: implement` marker plus `return null`, with no fetch and no `NotFound` throw.
This matches `/pro.evaluate` **Step 4a — Stub & No-op Detection (auto-FAIL)**: the `TODO`
marker grep and the placeholder-return grep both fire on a non-test implementation file,
so it is an automatic `FAIL:stub-detected:src/get-user.ts` — no scoring discretion. A
correct evaluator therefore `REJECT`s, never trusting the self-report over the diff.
