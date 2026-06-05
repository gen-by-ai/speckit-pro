# Repo knowledge — decision tree

> Seeded by SpecKit Pro. Replace placeholders with real routing rules.
> Format: **if you are touching X, read Y, then Z**

## By area

- If you are touching **authentication or sessions**, read [domain/glossary.md](domain/glossary.md), then [architecture.md](architecture.md#authentication).
- If you are touching **API contracts or HTTP handlers**, read [architecture.md](architecture.md), then [domain/invariants.md](domain/invariants.md).
- If you are touching **persistence or migrations**, read [architecture.md](architecture.md#data), then [domain/invariants.md](domain/invariants.md).
- If you are changing **cross-cutting behavior** (logging, errors, idempotency), read [domain/invariants.md](domain/invariants.md) before editing code.
- If you are adding **parallel/concurrent analysis** or touching `scripts/bash/pro-fanout*` / `scripts/local/partition.py` / `/pro.scan`, read [architecture.md](architecture.md#parallel-deep-analysis-fan-out-engine), then respect: no second `.knowledge/` write path; clamp concurrency to `min(16, cores−2)` (in-harness) / `cores−2` (cli); never fork a native `/speckit.*` command; the Coverage Ledger must cover every portion.

## By artifact

- New **business term** or enum → update [domain/glossary.md](domain/glossary.md) after merge (see `pro-knowledge.md` from `/pro.knowledge-sync`).
- New **endpoint or module** → update [architecture.md](architecture.md) after merge.
- **Irreversible design choice** → add a draft under `decisions/` (see `pro-knowledge-adr-draft.md`).
