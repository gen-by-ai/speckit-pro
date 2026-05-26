---
description: "First-pass implementation / test-gap / security review by local Ollama models. Writes findings as evidence-pack Markdown that the stronger evaluator (Claude) verifies — local model never has the final say."
---

# SpecKit Pro — Local Review (`pro.local-review`)

Runs **local Ollama workers** to do a first-pass review of recent changes before the stronger evaluator picks up. Writes three Markdown files under `<SPEC_DIR>/local-reviews/`:

| File                          | Reviewer focus                                          | Model (default)         |
|-------------------------------|---------------------------------------------------------|-------------------------|
| `implementation-review.md`    | Correctness, regression risk, contract violations       | `local_models.review_model`   |
| `test-gap-review.md`          | Acceptance criteria not actually exercised by tests     | `local_models.review_model`   |
| `security-review.md`          | Injection / authz / crypto / secrets / unsafe defaults  | `local_models.security_model` |

Each finding must include an **evidence pack** (file, lines, severity, category, what, evidence quote, why-it-matters, suggested patch, confidence, disproof, AC #). MDASH-inspired: a finding without a file and a line range is dropped. Low false-positive rate is the design goal — the evaluator stops trusting noisy reviewers.

## When this runs

- Manual: `/speckit.pro.local-review [--spec-dir <path>] [--base-ref <ref>] [--only <list>] [--force]`
- Pipeline: `pro.go` Phase 6b — automatically after the implement loop, before `/pro.evaluate`, if `local_models.enabled: true` and `local_models.auto_run.before_evaluate: true`.
- Hook: `after_implement` (chains before `pro.evaluate`, optional, opt-in).

## What "first-pass" means

Local reviews are **screens, not verdicts**. The chain is:

```
implement loop
    ↓
pro.local-review        ← writes drafts with evidence packs
    ↓
pro.evaluate (Claude)   ← reads drafts, verifies claims, decides PASS/NEEDS_REVISION/FAIL
```

The evaluator is bound by neither what the local model said nor what it missed. The drafts give it a faster start (fewer file reads, suggested places to look), not a binding ruling.

## User Input

```text
$ARGUMENTS
```

Optional flags:
- `--spec-dir <path>` — target feature directory; auto-detected otherwise.
- `--base-ref <ref>` — diff base for the change set. Defaults to the most recent `[Pro] Checkpoint` commit, falling back to `HEAD~1`.
- `--only <list>` — comma-separated subset of `implementation-review,test-gap-review,security-review`.
- `--force` — regenerate even if the file already exists.
- `--dry-run` — print what would happen without calling Ollama.

## Steps

### 1. Skip-if-not-configured

Load `local_models.*` from `pro-config.yml`. If `enabled: false` or Ollama is unreachable, print a one-line note and exit 0. Same graceful-degradation as `pro.local-prep`.

### 2. Build the diff snapshot

```bash
git -C <PROJECT_ROOT> diff --no-color <base-ref>...HEAD | head -n 800 > <diff-snapshot>
git -C <PROJECT_ROOT> diff --name-only <base-ref>...HEAD                > <changed-files>
```

The 800-line cap is deliberate — local 7B models lose calibration past ~8K tokens. Bigger features should split: run `pro.local-review` once per sprint, not at the very end.

### 3. Gather supporting context

For each review the driver feeds the model the smallest useful context bundle:

- **implementation-review**: diff, changed-files, latest sprint contract, risk-register.md
- **test-gap-review**: diff, changed-files, test-files-in-change-set, sprint contract, test-strategy.md
- **security-review**: diff, changed-files, sprint contract, risk-register.md, `.repo-knowledge/security.md` (if present)

### 4. Run the driver

Execute:
```bash
bash <EXTENSION_ROOT>/scripts/bash/pro-local-review.sh \
  --spec-dir <SPEC_DIR> \
  [--base-ref <ref>] [--only "<list>"] [--force]
```

The driver writes findings to `<SPEC_DIR>/local-reviews/`. Each file begins with the provenance banner.

### 5. Hand off to the evaluator

When the implement loop is finished, `/pro.evaluate` (Claude) reads:
- `<AI_KNOWLEDGE_DIR>/contracts/sprint-<N>.md` (acceptance criteria)
- `<SPEC_DIR>/local-reviews/*.md` (this command's output)
- The actual code

and forms the verdict. The local-review output is a **starting set of leads**, not the verdict.

## Evidence-pack contract (excerpt)

From `templates/local/implementation-review.prompt.md`:

> Every finding MUST include all eleven fields below. A finding without a file path and line range is not a finding — drop it.
> - File, Lines, Severity, Category, What, Evidence (quote), Why it matters, Suggested patch, Confidence, Disproof, Maps to AC

From `templates/local/security-review.prompt.md`:

> Prefer 3 high-confidence findings to 20 maybe-findings.

This is the MDASH lesson from `.dev-work/learning.md` baked into the prompt: low FP rate first, exhaustiveness second.

## What this command does NOT do

- It does not run tests. The evaluator decides when to run them.
- It does not commit anything.
- It does not write to spec.md / plan.md / tasks.md.
- It does not call Claude. It calls local Ollama. By design.

## Configuration knobs (excerpt)

```yaml
local_models:
  enabled: false
  review_model:   "qwen2.5-coder:7b"
  security_model: "qwen2.5-coder:7b"
  tasks:
    local_review: true
  auto_run:
    before_evaluate: true
```
