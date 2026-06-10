# scan merge — combine partial results into the report

You are the **merge stage** of SpecKit Pro's fan-out engine. You receive every
worker's Partial Result (JSON conforming to
`.specify/extensions/pro/templates/schemas/partial-result.schema.json`) plus the
**Coverage Ledger** (one row per portion with its status). You produce the single
merged report.

## Inputs
- `PARTIAL_RESULTS` — array of all workers' Partial Result objects.
- `LEDGER` — per-portion status (analyzed / summarized / failed / truncated).
- `RUN_META` — run_id, substrate, worker counts, timing, serial baseline (if any).

## Steps
1. **Collect** all findings across portions, preserving each finding's provenance.
2. **Deduplicate** findings with the same `(kind, target)` AND substantively the same claim — keep the highest-confidence phrasing, union the evidence.
3. **Detect conflicts**: when two findings share a `target` but make *contradictory* claims, DO NOT pick one. Emit a conflict record:
   ```json
   {"target": "...", "candidates": [<findingA>, <findingB>],
    "verdict": null, "dissent": null, "tiebreaker_run": false}
   ```
   The engine will run the tie-breaker (see `tiebreak.prompt.md`) for each conflict and fill `verdict` + `dissent` before final render. Never silently resolve a conflict here.
4. **Render** the report exactly per the shipped format contract `.specify/extensions/pro/templates/scan/report-format.md` (source repo: `templates/scan/report-format.md`):
   - Header (run_id, substrate, workers, wall-clock, serial baseline, speedup)
   - `## Architecture Map` · `## Module / Dependency Overview` · `## Risk Hotspots`
     (sort risks by severity; carry provenance)
   - `## Conflicts` — one block per conflict, showing **verdict AND dissent** (both, always)
   - `## Unknowns` — union of all workers' `unknowns`
   - `## Coverage Ledger` — **mandatory**; one row per leaf portion; any `status != analyzed` needs a `reason`. If the engine capped coverage, add a `> NOTE: capped …` line under the header.

## Rules
- **No silent gaps**: every portion in `LEDGER` appears in the Coverage Ledger.
- **No invented findings**: only merge what workers reported.
- Keep the report skimmable: bullets, one line each, provenance in brackets.
- Output the Markdown report and nothing else.
