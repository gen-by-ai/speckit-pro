---
description: "One-shot migration from legacy .repo-knowledge/ + .ai-knowledge/ to unified .knowledge/ — moves files, updates .gitignore, patches pro-config, and writes a report"
---

# SpecKit Pro — Knowledge Layout Migration (`pro.knowledge-migrate`)

Moves an existing project from the **legacy two-folder layout** to the **unified `.knowledge/` tree** (v1.16+). Safe to run once per repo; idempotent for paths already migrated.

| Legacy | New |
|--------|-----|
| `.repo-knowledge/*` | `.knowledge/` (root — **commit**) |
| `.ai-knowledge/<feature>/` | `.knowledge/features/<feature>/` (**gitignore**) |
| `.ai-knowledge/local-metrics.jsonl` | `.knowledge/metrics/local-metrics.jsonl` |

## User Input

```text
$ARGUMENTS
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--dry-run` | off | Print planned moves only; do not modify files |
| `--project-root` | `git rev-parse --show-toplevel` | Repo root when not run from a git checkout |

## Execution (agent runs this end-to-end)

### 1. Dry-run first

From the repository root:

```bash
bash .specify/extensions/pro/scripts/bash/pro-knowledge-migrate.sh --dry-run
```

If developing SpecKit Pro itself:

```bash
bash scripts/bash/pro-knowledge-migrate.sh --dry-run
```

Read the output. If **conflicts** are reported (destination already exists), resolve manually or merge the legacy file into the existing `.knowledge/` copy before applying.

### 2. Apply migration

```bash
bash .specify/extensions/pro/scripts/bash/pro-knowledge-migrate.sh
```

Exit codes: `0` = success; `2` = conflicts remain (inspect stderr).

This script:

- Creates `.knowledge/features/` and `.knowledge/metrics/`
- Moves `.repo-knowledge/*` → `.knowledge/` (never overwrites)
- Moves each `.ai-knowledge/<feature>/` → `.knowledge/features/<feature>/`
- Moves `.ai-knowledge/local-metrics.jsonl` → `.knowledge/metrics/local-metrics.jsonl`
- Bootstraps shared templates if `.knowledge/INDEX.md` is still missing
- Appends `.knowledge/features/` and `.knowledge/metrics/` to `.gitignore`
- Comments out legacy `.ai-knowledge` / `.repo-knowledge` gitignore lines
- Removes empty legacy directories
- Writes **`.knowledge/MIGRATION-REPORT.md`**

### 3. Patch `pro-config.yml`

Edit **`.specify/extensions/pro/pro-config.yml`** (create from template if missing):

| Key | Target value |
|-----|----------------|
| `knowledge.root_dir` | `.knowledge` |
| `knowledge.features_subdir` | `features` |
| `knowledge.enabled` | `true` (unless intentionally off) |
| `local_models.metrics_file` | `.knowledge/metrics/local-metrics.jsonl` |

Replace any remaining:

- `root_dir: ".repo-knowledge"` → `root_dir: ".knowledge"`
- `metrics_file: ".ai-knowledge/local-metrics.jsonl"` → `.knowledge/metrics/local-metrics.jsonl`

Do **not** change unrelated keys.

### 4. Verify no stale references in project docs

```bash
git grep -E '\.repo-knowledge|\.ai-knowledge' -- ':!.git' ':!CHANGELOG.md' || true
```

For each hit in **project-owned** files (README, AGENTS.md, team runbooks): update to `.knowledge/` paths or remove obsolete instructions. Do not rewrite SpecKit Pro extension source inside `node_modules` or vendored copies.

### 5. Smoke test

```bash
/speckit.pro.knowledge-sync --mode prime --query "migration smoke test"
```

Expect `[Pro] Knowledge prime complete` or a bootstrap message — not `No .knowledge/ found`.

### 6. Git commit guidance (operator)

Suggest a single commit for **shared** knowledge only:

```bash
git add .knowledge/INDEX.md .knowledge/architecture.md .knowledge/domain .knowledge/decisions .knowledge/runbooks .knowledge/MIGRATION-REPORT.md .gitignore
git add .specify/extensions/pro/pro-config.yml
# Do NOT: git add .knowledge/features/ .knowledge/metrics/
git status
```

Commit message example:

```
chore(pro): migrate to unified .knowledge/ layout

Move legacy .repo-knowledge and .ai-knowledge into .knowledge/ with
features/ and metrics/ gitignored. Update pro-config and .gitignore.
```

## Output protocol

End stdout with:

```
[Pro] Knowledge migration complete — moved N paths, C conflicts. See .knowledge/MIGRATION-REPORT.md
[Pro] Knowledge migration dry-run complete — see log above; re-run without --dry-run to apply
[Pro] Knowledge migration blocked — C conflicts; resolve manually then re-run
[Pro] Nothing to migrate — already on .knowledge/ layout
```

If neither `.repo-knowledge/` nor `.ai-knowledge/` exists and `.knowledge/INDEX.md` exists:

```
[Pro] Nothing to migrate — already on .knowledge/ layout
```

## When to run

- Once per repository when upgrading SpecKit Pro to **v1.16+**
- Before enabling `knowledge.enabled` on a project that used the old paths
- After cloning a repo that still documents `.repo-knowledge/` in its README

## What this command does *not* do

- Does not merge conflicting duplicate files (reports conflict, exit 2)
- Does not commit to git (operator commits shared files only)
- Does not delete non-empty legacy dirs with leftover files
- Does not rewrite `specs/` or feature `pro-knowledge.md` files
