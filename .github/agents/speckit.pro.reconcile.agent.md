---
description: Post-implement spec drift review — compares spec/plan/tasks to code and
  writes pro-drift.md before evaluate (fires via after_implement hook when configured).
---


<!-- Extension: pro -->
<!-- Config: .specify/extensions/pro/ -->
# SpecKit Pro — Spec Drift Reconciliation (`pro.reconcile`)

Structured **spec-vs-reality** review after `/speckit.implement`. Produces **`<FEATURE_DIR>/pro-drift.md`** so **`speckit.pro.evaluate`** can weigh known drift.

Follow **`commands/pro.reconcile.md`** (same content as `.specify/extensions/pro/commands/pro.reconcile.md`) step-by-step.

## User Input

```text
$ARGUMENTS
```

Optional: `--refresh-repo-ai` — rebuild local embeddings before retrieval queries.

## Quick checklist

1. Run **`check-prerequisites.sh --json`** → **`FEATURE_DIR`**.
2. Optionally run **`repo-ai search`** (see `.agents/skills/repo-ai-cli/SKILL.md`).
3. **`git diff`** / **`git status`** vs **`tasks.md`** completion state.
4. Write **`FEATURE_DIR/pro-drift.md`** using the template in the command file.
5. End with **`[Pro] Drift reconciliation complete — …`**.
