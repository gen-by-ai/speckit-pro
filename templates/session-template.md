# Session State
# Created by SpecKit Pro | https://github.com/github/spec-kit-pro
# ─────────────────────────────────────────────────────────────────────────────
# This file tracks the state of an autonomous pipeline run.
# It is maintained automatically — do not edit by hand unless resuming manually.
# ─────────────────────────────────────────────────────────────────────────────

Feature: {{FEATURE_NAME}}
Branch: {{GIT_BRANCH}}
Pipeline started: {{START_TIMESTAMP}}
Config: .specify/extensions/pro/pro-config.yml

---

## Pipeline Configuration

| Phase | Gate | Quality | Status |
|---|---|---|---|
| specify | {{GATE_SPECIFY}} | — | ○ pending |
| clarify | {{GATE_CLARIFY}} | {{QUALITY_CLARIFY}} | ○ pending |
| plan | {{GATE_PLAN}} | — | ○ pending |
| tasks | {{GATE_TASKS}} | — | ○ pending |
| analyze | {{GATE_ANALYZE}} | {{QUALITY_ANALYZE}} | ○ pending |
| implement | — | loop max {{MAX_ITERATIONS}} | ○ pending |

---

## Session Log

<!-- Session entries are appended here automatically by SpecKit Pro -->
