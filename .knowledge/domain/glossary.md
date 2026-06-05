# Domain glossary

Business terms used in specs and UI — not internal code names unless they are user-visible.

| Term | Meaning | Owned by |
|------|---------|----------|
| Portion (Work Unit) | An independently analyzable slice of the codebase (a non-overlapping set of files) assigned to exactly one worker. | fan-out engine |
| Worker | One concurrent analysis unit — an in-harness sub-agent or a headless CLI process — with isolated context; consumes one Portion, emits one Partial Result. | fan-out engine |
| Substrate | The concurrency mechanism for a run: `in-harness` (sub-agents), `cli` (headless processes), or `sequential`. A pluggable interface. | fan-out engine |
| Fan-out Engine | The shared partition → dispatch → collect → merge orchestrator behind `/pro.scan` and the phase retrofits. | fan-out engine |
| Coverage Ledger | The per-Portion status table (analyzed / summarized / failed / truncated) accompanying a scan report — guarantees no silent coverage gaps. | fan-out engine |
| Tie-breaker worker | A worker spawned to adjudicate a disagreement between two workers about the same target; records both verdict and dissent. | fan-out engine |
