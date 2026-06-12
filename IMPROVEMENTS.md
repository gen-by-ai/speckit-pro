# SpecKit Pro — Reliability & Autonomy Audit

Deep review of v1.7.0 (`3d2db21`). Findings verified against the actual scripts; the P0 shell bugs were reproduced empirically. Ordered by impact on unattended runs.

---

## Status as of v1.24 (verified 2026-06-11)

Every finding below was re-verified against the current code; the remaining open items were closed in v1.24 (see CHANGELOG). Per-finding state:

| Finding | Status | Resolution |
|---|---|---|
| P0#1 `grep -c \|\| echo 0` | ✅ fixed (v1.23) | `\|\| true` + `[[:space:]]`, race-free single-read counting |
| P0#2 CLI invocations | ✅ fixed (v1.23 claude, v1.24 PowerShell) | capability-gated flag table; PS `--system-prompt` path bug → `--append-system-prompt` + permission flags |
| P0#3 stale agent profiles | ✅ fixed (v1.24) | `resolve_agent_file` searches override → extension → project → legacy layouts; hardcoded `.github/agents/` (which shipped nowhere) removed from all branches, both shells |
| P0#4 wrong contract/eval paths | ✅ fixed (v1.23) | everything keys off `FEATURE_KNOWLEDGE_DIR` |
| P0#5 silent revision no-op | ✅ fixed (v1.23 path, v1.24 visibility) | revision output captured + logged on every branch; `&>/dev/null` removed |
| P1#6 UNKNOWN = success | ✅ fixed (v1.24) | UNKNOWN + `MAX_ITERATIONS` handled; UNKNOWN counts toward breaker (both shells); no-progress watchdog on the checkbox delta (`--no-progress-limit`) |
| P1#7 no timeouts | ✅ fixed (v1.24) | `--iteration-timeout` on every call (coreutils or pure-bash watchdog) + `--max-wall-seconds` run budget |
| P1#8 invisible output / stdout scraping | ✅ fixed (v1.24) | per-iteration transcripts in `.knowledge/features/<f>/logs/`; file-based status contract `<spec-dir>/.pro-status.json` preferred over scrape |
| P1#9 eval score parsing | ✅ fixed (v1.23 verdicts, v1.24 scores) | unknown verdict ⇒ FAIL; `PASS:<malformed>` ⇒ revision (strict `^[0-9]{1,3}$`) |
| P1#10 sprint numbering / ratification | ⚠ partially addressed | contracts sealed + verified (v1.22 D9 seals); a unified `contracts/index.json` registry remains future work |
| P1#11 init.sh vs serve.sh | ⚠ partially addressed | init.sh documented as fast smoke (<30s, no servers); serve/stop split remains future work |
| P1#12 flagship features in pro.go inline mode | ⚠ partially addressed | tasks dispatch as sub-agents; evaluator runs as separate command (not a fully isolated subagent) |
| P1#13 dead config/env | ✅ fixed (v1.24) | `SPECKIT_PRO_*` env overrides on all major knobs (flag > env > default), `cfg_get` config reader, `--doctor` prints the resolved world + READY verdict |
| P1#14 checkpoint safety | ✅ fixed (v1.23 staging/verify, v1.24 TERM) | scoped stage+destage, verified commits, SIGTERM trap writes final state + notification |
| P1#15 resume arithmetic | ✅ fixed (v1.24) | durable `loop-state.json` (authoritative resume source) + relative iteration budget — resume at 13 with max 8 runs 13..20 |
| P1#16 no concurrency guard | ✅ fixed (v1.24) | noclobber-atomic lockfile with PID + staleness takeover + `--force-lock` |
| P1#17 BLOCKED handling + notifications | ✅ fixed (v1.24) | deferred-blocker journal fed back to the worker (`blocked-log=`); `notify.*` config wired (always-on `notifications.jsonl` + optional Slack-compatible webhook) |
| P2 version drift / README / read-only evaluator / banner / count patterns | ✅ fixed (v1.23–v1.24) | — |
| P2 `git diff HEAD~1` eval guidance | ⚠ open | checkpoint-relative diff still future work |
| P2 handoff "Last verdict" | ⚠ open | template placeholder exists; wiring future work |
| "Missing test layer" (order-of-attack #5) | ✅ fixed (v1.24) | `scripts/tests/orchestrator-smoke.sh`: 17 hermetic state-machine checks driven by a fake agent CLI — zero tokens |

**New in v1.24 beyond the audit:** cross-run analytics (`pro-analytics.sh` + `/speckit.pro.analytics`: per-feature rollups, failure taxonomy, cost-per-task, composite health grade with cron-able `--gate`); two latent production bugs found *by the new test layer* (a `set -e`/pipefail death on any tag-less agent answer that made `ERROR:no-status-tag` unreachable, and a `set -e` death the moment the evaluator returned NEEDS_REVISION) — exactly the class of bug the audit predicted such a harness would catch.

---

## P0 — Bugs that break runs today

### 1. Completion detection is broken — successful runs exit 1
`pro-orchestrate.sh:135-147` (`count_tasks`, `all_tasks_done`):

```bash
incomplete=$(grep -cE '^\s*- \[ \]' "$TASKS_PATH" 2>/dev/null || echo 0)
```

When there are **zero** matches, `grep -c` prints `0` *and* exits 1, so `|| echo 0` runs too → `incomplete` becomes `"0\n0"`. Then `[[ "$incomplete" -eq 0 ]]` throws `syntax error in expression` and `all_tasks_done` returns **false** — exactly when all tasks are done. Reproduced:

```
incomplete=[0
0]
bash: [[: 0
0: syntax error in expression
all_tasks_done: FALSE
```

Consequences: the "already complete" pre-check never fires; the post-loop success path is unreachable; a fully completed run prints "Maximum iterations reached. 0 tasks remain." and **exits 1**. The loop only ends early if the agent happens to emit `COMPLETE`.

The same `|| echo 0` pattern is in `pro-status.sh:64-65,118` and `pro-checkpoint.sh:44-45`.

**Fix:** `grep -c` already prints the count on no-match; replace `|| echo 0` with `|| true`. Also replace `\s` with `[[:space:]]` — `\s` in ERE is a GNU extension and unreliable on macOS/BSD grep, which can silently zero all task counts on the README's primary platform.

### 2. The `claude` (and `gemini`/`codex`) invocations cannot work
`pro-orchestrate.sh:256-261`:

```bash
claude --model "$MODEL" --print --system-prompt ".github/agents/speckit.pro.loop.agent.md" "$prompt_args"
```

Three independent failures:

1. `--system-prompt` takes a **string**, not a file path. The agent's system prompt becomes the literal text `.github/agents/speckit.pro.loop.agent.md`; the user message is `feature=... tasks=...`. The worker runs with **no instructions at all**.
2. Non-interactive `claude -p` cannot approve tool use. Without `--permission-mode acceptEdits` / `--dangerously-skip-permissions` / pre-configured `allowedTools`, every file edit is denied — zero work possible even with a correct prompt.
3. `gemini run <file>` and the generic fallback (`codex <file> <args>`) are likewise unverified invocation shapes; the revision pass (line 477-486) special-cases only `copilot` and sends every other CLI through the generic branch.

**Fix:** per-CLI invocation table, e.g. `claude -p --permission-mode acceptEdits --append-system-prompt "$(cat "$AGENT_FILE")" "$prompt_args"`, validated by a `--dry-run` self-test command (see #13). Fail fast at startup if the resolved CLI doesn't support the required flags, instead of looping 20 times producing nothing.

### 3. The orchestrator drives stale agent profiles (three sources of truth)
There are three divergent definitions of the loop worker:

| File | State |
|---|---|
| `commands/pro.loop.md` | v1.7 — AGENT.md, init.sh, Scope of Autonomy, `.ai-knowledge/`, complexity routing |
| `.github/agents/speckit.pro.loop.agent.md` | **v1.4-era** — none of the above; writes contracts/progress to `<spec-dir>/` |
| `agents/speckit.pro.loop.agent.md` (shipped) | Thin shim → "Follow the instructions in `commands/speckit.pro.loop.md`" — **a path that doesn't exist** (file is `commands/pro.loop.md`; installed location is `.specify/extensions/pro/commands/`) |

The orchestrator hardcodes `.github/agents/speckit.pro.loop.agent.md`, which `.extensionignore` **excludes from distribution**. So orchestrated runs either use the stale v1.4 profile (dev repo) or a missing file (installed projects). Everything added in v1.5–v1.7 — `.ai-knowledge/`, smoke tests, Scope of Autonomy, AGENT.md self-update — is silently absent from the execution path it was built for. Same story for the evaluator: `agents/speckit.pro.evaluate.agent.md` has **no browser testing and no calibration step** (both only in `commands/pro.evaluate.md`), so the README's flagship "evaluator clicks through the live app" doesn't happen in orchestrated runs.

**Fix:** one canonical source (`commands/*.md`), agent profiles generated from it at install/build time, orchestrator path resolved relative to the extension install dir (not CWD-dependent `.github/...`), and a CI check that diffs generated profiles against source.

### 4. Contract & evaluation paths point to the wrong directory
v1.5 moved contracts/evaluations/progress to `.ai-knowledge/<feature>/`, but:

- `pro-orchestrate.sh:292` passes `contract=$SPEC_DIR/contracts/sprint-N.md` to the evaluator.
- `pro-orchestrate.sh:475` passes `eval-feedback=$SPEC_DIR/evaluations/sprint-N.md` to the revision pass — the evaluator writes feedback to `.ai-knowledge/`, so the generator revises against a **non-existent file**.
- `pro-orchestrate.ps1` has no `.ai-knowledge` concept at all (`$ProgressFile = $SpecDir/progress.md`).
- `pro.status.md:31`, `pro.resume.md:25`, `pro-status.sh:141`, `pro-checkpoint.sh:67` still read `progress.md` from the spec dir → status/resume report "no iterations logged" mid-run.

**Fix:** compute `AI_KNOWLEDGE_DIR` once, pass `--ai-knowledge-dir` to every sub-invocation (the arg already exists), and sweep every consumer. Add a path-consistency smoke test.

### 5. The revision loop is a silent no-op
`pro-orchestrate.sh:469-489`: revision output is discarded (`&>/dev/null || true`), its status tag is never parsed, the feedback path is wrong (#4), and non-copilot CLIs get a broken invocation (#2). After `MAX_REVISIONS` the sprint is accepted anyway and `CONTINUE` resets the failure counter — the quality gate fails **open**. On Windows, `pro-orchestrate.ps1` has no evaluator support whatsoever (no `-EnableEvaluator`, no `run_evaluator` equivalent).

**Fix:** treat a revision like a normal iteration (logged, status-parsed, timed out); after max revisions escalate to `BLOCKED` (human review) rather than silently continuing; port the evaluator cycle to PowerShell or document it as bash-only.

---

## P1 — Design gaps limiting safe autonomy

### 6. Unknown status is treated as success — the watchdog defangs itself
`pro-orchestrate.sh:531-534`: any unparseable/missing tag → "treating as CONTINUE" **and `consecutive_failures=0`**. A crashed CLI, expired auth, or rate-limit returns no tag, so the circuit breaker can never trip; the loop burns all 20 iterations doing nothing. `agent_exit` is captured but never inspected. The documented `MAX_ITERATIONS` tag also lands in this bucket.

**Fix:** UNKNOWN increments `consecutive_failures`; non-zero CLI exit increments it too with exponential backoff; and add a **no-progress watchdog** — if the completed-task count hasn't increased for N iterations, stop with a diagnostic regardless of what tags claim. Checkbox delta is the one progress signal the agent can't get wrong by accident.

### 7. No timeouts anywhere
One hung CLI call (network stall, interactive prompt waiting for stdin) freezes the entire overnight run. **Fix:** wrap every agent/evaluator invocation in `timeout "${ITERATION_TIMEOUT:-1800}"`, treat timeout as `ERROR:`, and put an overall wall-clock budget on the run. This is the single cheapest "runs survive the night" change.

### 8. Agent output is invisible and unlogged; status travels via stdout scraping
All generator output is swallowed by command substitution — the operator watching the terminal sees nothing, and nothing is persisted. Status is scraped from stdout tags, which is fragile: a CLI cost-footer after the tag is survivable, but an agent that *mentions* a tag after its real one is misparsed (`tail -1`), and **the PowerShell version takes the FIRST regex match** — quoting the protocol early poisons it.

**Fix:**
- `tee` every iteration to `.ai-knowledge/<feature>/logs/iter-N.log` (the missing audit trail for "what did it actually do at 3am").
- Move the status channel to a **file contract**: the worker writes `{"status":"CONTINUE","reason":...}` to `<spec-dir>/.pro-status.json`; orchestrator reads and deletes it. Stdout stays human-readable; a missing file is unambiguously a failure. This one change removes the largest class of misparse failures.

### 9. Evaluator score parsing is erratic; gate defaults open
`handle_eval_result` (`pro-orchestrate.sh:332-360`), verified behavior:

| Evaluator emits | Result |
|---|---|
| `PASS:82` | correct |
| `PASS:82/100` | bash arithmetic → `82/100 = 0` → spurious revision of a good sprint |
| `PASS:eighty` / `PASS:` | error suppressed by `2>/dev/null` → **accepted** |
| unknown verdict | "treating as PASS" |

**Fix:** validate with `[[ "$score" =~ ^[0-9]{1,3}$ ]]`; anything malformed → `NEEDS_REVISION`, unknown verdict → failure, never pass. Pin the format in both evaluator definitions (they currently also disagree on scoring: 40/30/20/5/5 weighted rubric in the command vs ≥80%-criteria thresholds in the agent profile).

### 10. Three incompatible sprint-numbering schemes; contract ratification unimplemented
`pro.contract.md` numbers contracts `count(existing)+1` and writes a `contracts/current.md` pointer that **nothing reads** (verified). The loop and evaluator key contracts by **iteration number**. So after the `after_tasks` hook creates `sprint-1.md`, iteration 2+ finds no contract and the generator **writes its own contract and is then graded against it** — grading your own homework, which defeats the generator/evaluator split. `contract-template.md` promises "evaluator must ratify before implementation starts"; no command implements ratification.

**Fix:** define sprint = work unit. Keep a `contracts/index.json` (work-unit → contract file → status: proposed/ratified/evaluated). Loop consumes the next unratified contract; if missing, the orchestrator (not the generator mid-sprint) triggers `pro.contract`, optionally with a cheap evaluator ratification pass. This also gives `pro.status` real sprint visibility.

### 11. `init.sh` conflates smoke test and dev server — evaluator can hang or fail everything
`pro.go.md` Phase 5b generates an init.sh that *starts the dev server*; `pro.evaluate.md` Step 3 runs `bash init.sh` to "start the dev server" with no backgrounding, readiness probe, or teardown. A foreground server blocks forever (see #7 — no timeout); a backgrounded one is never killed, so the next iteration's smoke test hits "address already in use" → init.sh exits non-zero → "mark all UI criteria FAIL". The loop runs init.sh every iteration too, doubling the exposure.

**Fix:** split contracts: `init.sh` = fast non-interactive checks (<30s, no servers); `serve.sh` = start in background, write PID file, poll readiness endpoint, and a `stop.sh`/trap for teardown. Evaluator: serve → test → **always teardown** (trap on EXIT).

### 12. The flagship features don't run in the flagship path
`pro.go.md` Phase 6: "**You are the loop.** Do NOT run pro-orchestrate.sh." In this inline mode there is **no evaluator step at all** (steps 1–9 never invoke `pro.evaluate`; the `after_implement` hook doesn't fire because `/speckit.implement` is never called) and no real context reset (one chat context grows across all iterations; handoff.md is written but the same agent keeps its accumulated history). The README's two headline claims — independent evaluation and per-sprint context resets — hold only in the script path, which is itself broken for most CLIs (#2).

**Fix:** in `pro.go` inline mode, dispatch each iteration as a **fresh subagent** (Task-tool/agent dispatch, handoff.md as its only input — a true reset) and run `pro.evaluate` as a separate subagent between sprints. Where subagents aren't available, state explicitly in the banner that evaluation and resets are degraded.

### 13. Config and env overrides are dead code
No script reads `pro-config.yml` or any `SPECKIT_PRO_*` variable (verified). The README documents env overrides; the template documents a 4-level priority cascade; none of it is wired. Meanwhile `evaluation.enabled` defaults to `true` in `extension.yml`, `false` in `pro-config.template.yml`, `false` in the script — the flagship feature is off unless someone passes `--enable-evaluator` by hand.

**Fix:** a small `load_config()` (grep/awk or `yq` when present): config file → env → CLI flags, plus a `pro-orchestrate.sh --doctor` mode that prints resolved config, resolved CLI + version, flag support, agent-file existence, and git state, then exits. Reconcile the three defaults.

### 14. Checkpointing can crash the run, lie about success, and stage secrets
- `git add .` stages everything not ignored — `.env`, junk, half-written artifacts.
- `pro-orchestrate.sh:155`: a failing `git commit` (pre-commit hook) under `set -euo pipefail` **kills the orchestrator mid-run**, unstaged.
- `pro-checkpoint.sh:92-94`: commit errors are `2>/dev/null`'d, then `git rev-parse --short HEAD` reports the *previous* commit as the new checkpoint — "Checkpoint created ✓" with a stale hash.
- Only an INT trap exists; SIGTERM/crash leaves no final session entry or checkpoint.

**Fix:** guard the commit (`if git commit ...; then`), verify `new_hash != old_hash`, use an explicit pathspec or `git add -A -- ':(exclude).env*'`, optionally `--no-verify` for checkpoint commits, and add `trap ... EXIT TERM` that writes a final session entry + best-effort checkpoint.

### 15. Resume arithmetic can make resume a no-op
`pro.resume.md` instructs restarting with `--max-iterations <remaining_iterations>` **and** `--resume`. The script resumes at `last_iter+1` and loops `while iteration <= MAX_ITERATIONS` — resume at iteration 13 with max 8 never executes a single iteration and exits "max reached". The resume point itself is parsed by regex from agent-authored `progress.md` prose.

**Fix:** persist orchestrator-owned state (`.ai-knowledge/<feature>/loop-state.json`: iteration, consecutive_failures, started_at) and make the iteration budget relative (`iterations_this_run`), independent of the absolute counter.

### 16. No concurrency guard
Two orchestrators (or orchestrator + manual `/speckit.pro.loop`) on the same feature interleave writes to `tasks.md`/`progress.md` and double-commit. **Fix:** `flock`/lockfile on `.ai-knowledge/<feature>/.lock` with PID + staleness detection.

### 17. BLOCKED retries the same wall three times, then dies
A `BLOCKED` sprint just increments the failure counter and re-spawns the same work unit; after 3 the run exits. README promises the loop "will emit BLOCKED and wait for you" — it doesn't wait, and it can't skip. **Fix:** on BLOCKED, mark the work unit deferred and proceed to the next independent unit (the parallelism metadata in tasks.md already encodes independence); only halt when nothing unblocked remains. Wire the existing-but-unimplemented `notify.on_failure` webhook so a 3am block pings the operator instead of silently dying.

---

## P2 — Drift and smaller correctness issues

- **Version drift:** `extension.yml` says 1.6.0; CHANGELOG and git say 1.7.0.
- **README vs reality:** README says `/speckit.pro.compress` writes `handoff.md`; the command writes `context-summary.md`. The loop arg table documents a `context-summary` key the command body never uses. Termination table says circuit breaker = "3 consecutive failures"; BLOCKED also counts.
- **Evaluator not constrained read-only:** nothing forbids the evaluator from "helpfully" fixing code, contaminating the gen/eval split. Add an explicit hard rule (and, where supported, a read-only tool allowlist for the evaluator invocation).
- **`git diff HEAD~1` guidance** (`pro.evaluate.md` Step 4) is wrong with `checkpoint_frequency=3` — most sprints are uncommitted at eval time; HEAD~1 shows the previous checkpoint's diff. Use working-tree diff against the last checkpoint tag.
- **Banner mislabels** iteration count as task progress (`pro-orchestrate.sh:130`).
- **`count_tasks` completed-pattern** `'^\s*- \[x\]|\s*- \[X\]'` — second alternative is unanchored (matches mid-line text).
- **Handoff "Last verdict" is always `AWAITING_EVAL`** — the generator writes handoff.md before evaluation, and the evaluator never updates it. Have the orchestrator (or evaluator) patch the verdict line so the next sprint actually sees evaluator feedback — today the feedback loop into the next sprint's context relies on a file path that's wrong anyway (#4).

---

## Suggested order of attack

1. **Make the engine truthful** (P0 #1, #6, #9): fix `grep -c`, treat UNKNOWN/exit-codes as failures, validate scores. ~30 lines of shell; converts silent failure into loud failure.
2. **Make the engine actually run** (P0 #2, #3, #4, #5): correct per-CLI invocations + permission flags, single-source agent profiles, `.ai-knowledge` path sweep, real revision pass. This is the gap between "demo" and "tool".
3. **Make it survive the night** (P1 #7, #8, #11, #14, #15, #16): timeouts, per-iteration logs + file-based status contract, serve/teardown split, safe checkpoints, durable loop state, lockfile.
4. **Make autonomy honest** (P1 #10, #12, #13, #17): unified sprint registry with ratification, evaluator + true resets in `pro.go` mode, wired config, BLOCKED-skip + notifications.
5. **Add the missing test layer:** a `tests/` harness with a fake agent CLI (a script that emits scripted tags/outputs) so the orchestrator's state machine — termination, circuit breaker, revisions, resume — is testable without burning tokens. Nearly every P0 above would have been caught by one such test.
