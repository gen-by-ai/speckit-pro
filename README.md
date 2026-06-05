<div align="center">
  <h1>⚡ SpecKit Pro</h1>
  <h3><em>SpecKit on steroids — built for long autonomous work.</em></h3>
</div>

<p align="center">
  <a href="https://github.com/github/spec-kit"><img src="https://img.shields.io/badge/Built%20on-Spec%20Kit-blue" alt="Built on Spec Kit"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"/></a>
  <img src="https://img.shields.io/badge/SpecKit-%3E%3D0.8.0-orange" alt="SpecKit >=0.8.0"/>
</p>

---

**SpecKit Pro** is a [Spec Kit](https://github.com/github/spec-kit) extension: native commands (`specify`, `plan`, `tasks`, `implement`) plus a **self-healing loop**, separate **evaluator**, sprint **contracts**, live **browser tests**, and a unified **`.knowledge/`** base. **Local Ollama** handles prep and first-pass review by default; Claude verifies. No Ollama? Those steps skip silently — the pipeline still runs. It augments Spec Kit — it does not replace it.

## At a glance

| You get | How |
|--------|-----|
| Full pipeline in one shot | `/speckit.pro.go <description>` |
| Resume stuck features | `/speckit.pro.pickup <feature>` |
| Hands-off implement loop | Generator → reconcile → evaluate → retry |
| Honest QA | Evaluator + agent-browser (not self-grading) |
| Domain memory | `.knowledge/` primes specs; syncs after PASS |
| Thin specs → depth | `/speckit.pro.deepen` (opt-in) |
| Parallel deep analysis | `/speckit.pro.scan` — fan out across workers; adaptive in-harness/CLI |
| Local-first offload | Ollama prep/review by default; skips if unavailable |

## Quick start

```bash
# 1. Install
specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/latest.zip

# 2. Config
cp .specify/extensions/pro/pro-config.template.yml .specify/extensions/pro/pro-config.yml

# 3. Verify
specify extension list   # → SpecKit Pro (version from extension.yml)

# 4. (Recommended) Local models — pipeline tries Ollama by default
brew install ollama && ollama serve &
ollama pull qwen2.5-coder:7b
# Without Ollama, /pro.local-* steps skip in ~3s — no setup required
```

**New feature (typical):**

```
/speckit.pro.go "Payment retry with exponential backoff"
```

Review at the **spec** and **plan** gates; the rest auto-continues by default.

**Already planned but never built?**

```
/speckit.pro.status          # what's stuck?
/speckit.pro.pickup <feature>
```

**Upgrading from `.repo-knowledge/` + `.ai-knowledge/`?**

```
/speckit.pro.knowledge-migrate    # dry-run, then apply
```

## Commands

| Command | Use when |
|---------|----------|
| `/speckit.pro.go` | New feature — full pipeline |
| `/speckit.pro.pickup` | Spec/plan/tasks exist, loop never ran |
| `/speckit.pro.status` | Dashboard (workspace or one feature) |
| `/speckit.pro.resume` | Interrupted run |
| `/speckit.pro.deepen` | Spec too thin → questions → `--apply` |
| `/speckit.pro.reconcile` | Spec vs code drift (before evaluate) |
| `/speckit.pro.evaluate` | Strict QA (auto after implement) |
| `/speckit.pro.knowledge-sync` | Prime/sync `.knowledge/` |
| `/speckit.pro.knowledge-migrate` | Legacy → `.knowledge/` layout (once) |
| `/speckit.pro.local-prep` | Prep artifacts (auto when Ollama up) |
| `/speckit.pro.local-review` | First-pass review (auto when Ollama up) |
| `/speckit.pro.local-metrics` | Local model quality dashboard |
| `/speckit.pro.compress` | Write `handoff.md` for next sprint |
| `/speckit.pro.checkpoint` | Commit + snapshot now |

Alias: `/speckit.pro.run` = `/speckit.pro.go`

Per-command detail lives in [`commands/`](commands/) (e.g. `pro.go.md`, `pro.loop.md`).

## How it works

```
/pro.go: prime → specify → [deepen] → clarify → prime → plan → tasks → prime → contract
    → local prep* → prime → analyze → loop (prime each iter*) → reconcile
    → local review* → evaluate → knowledge-sync (on PASS)
```
\* Ollama / loop primes skip cleanly when disabled or unreachable

Each loop iteration: load contract + `handoff.md` → implement one work unit → checkpoint. The **evaluator** is a fresh agent; it must not grade its own work. On **PASS**, optional knowledge sync proposes updates to shared `.knowledge/`.

**Stop conditions:** all tasks done, max iterations, or circuit breaker after consecutive failures. Resume with `/speckit.pro.resume`.

## Configuration

Edit `.specify/extensions/pro/pro-config.yml` (from `pro-config.template.yml`):

- **`gates.after_specify` / `gates.after_plan`** — usually `true` (human review)
- **`evaluation.enabled`** — generator/evaluator split
- **`knowledge.enabled`** — `.knowledge/` prime/sync (default `true`)
- **`local_models.enabled`** — local prep/review (default `true`; set `false` to never try Ollama)
- **`commit.commit_artifacts`** — `false` keeps `specs/` out of PR commits

Env overrides: `SPECKIT_PRO_MODEL`, `SPECKIT_PRO_MAX_ITERATIONS`, `SPECKIT_PRO_AGENT_CLI`.

## `.knowledge/` (one tree)

| Zone | Path | Git |
|------|------|-----|
| Team docs | `.knowledge/INDEX.md`, `domain/`, `decisions/` | Commit |
| Per-feature state | `.knowledge/features/<slug>/` | Gitignore |
| Metrics | `.knowledge/metrics/` | Gitignore |

`features/<slug>/` holds `AGENT.md`, `contracts/`, `evaluations/`, `progress.md`, `init.sh`. First run can auto-bootstrap templates; curate `INDEX.md` and `domain/invariants.md` for real value.

## Local Ollama (default on)

Pro **always attempts** local prep (`repo-map.md`, `context-pack.md`, task packets) and first-pass review after the implement loop. Output is draft-only; `/speckit.pro.evaluate` verifies. If Ollama is not running, drivers exit in seconds with a one-line skip — **no error, no abort**.

```bash
ollama pull qwen2.5-coder:7b   # recommended once; optional for first run
```

Tune with `/speckit.pro.local-metrics`. Disable entirely: `local_models.enabled: false`. See [`commands/pro.local-prep.md`](commands/pro.local-prep.md).

## Installation & updates

```bash
specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/latest.zip
# update: specify extension remove pro && re-add with latest.zip (always current release)
# pin:    .../archive/refs/tags/v1.19.0.zip
```

From source: `specify extension add --dev /path/to/speckit-pro`

Updating replaces `.specify/extensions/pro/` only — your `specs/` and `.knowledge/features/` are untouched.

## Agent CLIs

`copilot` (default), `claude`, `gemini`, `codex` — set via `agent_cli` in config.

## Tips

1. Gate on **plan**, not just spec — highest leverage review point.
2. Use **`/speckit.pro.pickup`** before re-planning a feature that already has `tasks.md`.
3. Keep **`AGENT.md`** — the loop's project memory; don't reset each sprint.
4. Ensure **`init.sh`** starts the app fast; evaluator needs a running app for UI criteria.
5. Curate **`.knowledge/`** after bootstrap; merge `pro-knowledge.md` proposals after PASS.
6. Watch **`/speckit.pro.status`** during long runs.
7. Enable **deepen** for non-trivial features (`deepen.enabled: true`).
8. Pull an Ollama model when you can — default pipeline uses it; without it, steps skip cleanly. Tune with **`/speckit.pro.local-metrics`**.

## More detail

- [CHANGELOG.md](CHANGELOG.md) — release notes
- [commands/](commands/) — full command specs
- [pro-config.template.yml](pro-config.template.yml) — all toggles

## Contributing · License

Contributions welcome — [CONTRIBUTING.md](CONTRIBUTING.md). MIT — see [LICENSE](LICENSE). Built on [GitHub Spec Kit](https://github.com/github/spec-kit).
