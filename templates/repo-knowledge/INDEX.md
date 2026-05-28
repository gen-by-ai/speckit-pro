# Repo knowledge — decision tree

> Seeded by SpecKit Pro. Replace placeholders with real routing rules.
> Format: **if you are touching X, read Y, then Z**

## By area

- If you are touching **authentication or sessions**, read [domain/glossary.md](domain/glossary.md), then [architecture.md](architecture.md#authentication).
- If you are touching **API contracts or HTTP handlers**, read [architecture.md](architecture.md), then [domain/invariants.md](domain/invariants.md).
- If you are touching **persistence or migrations**, read [architecture.md](architecture.md#data), then [domain/invariants.md](domain/invariants.md).
- If you are changing **cross-cutting behavior** (logging, errors, idempotency), read [domain/invariants.md](domain/invariants.md) before editing code.

## By artifact

- New **business term** or enum → update [domain/glossary.md](domain/glossary.md) after merge (see `pro-knowledge.md` from `/pro.knowledge-sync`).
- New **endpoint or module** → update [architecture.md](architecture.md) after merge.
- **Irreversible design choice** → add a draft under `decisions/` (see `pro-knowledge-adr-draft.md`).
