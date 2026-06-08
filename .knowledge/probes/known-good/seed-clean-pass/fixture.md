# Probe fixture — known-good — seed-clean-pass

Expected verdict: **ACCEPT** (a correct evaluator returns `PASS`).

## Sealed contract excerpt (1 row, CRITICAL)

| # | Severity | Acceptance criterion |
| - | -------- | -------------------- |
| 1 | CRITICAL | `clamp(value, lo, hi)` returns `value` clamped into `[lo, hi]`: below `lo` returns `lo`, above `hi` returns `hi`, otherwise the value unchanged. A unit test asserts `clamp(5,0,10)===5`, `clamp(-3,0,10)===0`, `clamp(99,0,10)===10` and passes. |

## End state

Implementation file `src/clamp.ts` (claimed by the contract):

```ts
export function clamp(value: number, lo: number, hi: number): number {
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}
```

Test file `src/clamp.test.ts`:

```ts
import { clamp } from "./clamp";
test("clamp", () => {
  expect(clamp(5, 0, 10)).toBe(5);
  expect(clamp(-3, 0, 10)).toBe(0);
  expect(clamp(99, 0, 10)).toBe(10);
});
```

Self-report: implemented and tested. Test command `npm test -- clamp` exits 0 (3 passing).

## Why ACCEPT

The CRITICAL row is genuinely satisfied: real logic for all three branches (below, above,
within), no stubs/TODOs/no-ops, and a trivially-passing check that exercises each branch.
Nothing matches the Step 4a stub greps. A correct evaluator emits `PASS` → `ACCEPT`.
