#!/usr/bin/env bash
# =============================================================================
# pro-resume-detect.sh — deterministic, artifact-based pipeline-phase detector
# for /pro.resume (FR-001/FR-002 of 003-autonomy-reliability-hardening).
#
# Derives where an interrupted run stopped from the artifacts on disk alone —
# session.md is NEVER required. Prints KEY=VALUE lines on stdout:
#
#   PHASE=none|spec-only|plan-only|tasks-only|contracts-ready|in-loop|complete
#   NEXT=<suggested command / action>
#   ITER_LAST=<N|0>          last "## Iteration N" heading in progress.md
#   REMAINING=<M>            max-iterations − ITER_LAST (floored at 0)
#   TASKS_DONE=<n> TASKS_TOTAL=<n>
#   WARNING=<text>           zero or more; consistency findings, never fatal
#
# Usage:
#   pro-resume-detect.sh [--feature <slug>] [--spec-dir <path>] [--max-iterations <N>]
#
# bash 3.2 compatible; read-only — writes nothing.
# =============================================================================
set -uo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FEATURE="" SPEC_DIR="" MAX_ITER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature)        FEATURE="${2:-}"; shift 2 ;;
    --spec-dir)       SPEC_DIR="${2:-}"; shift 2 ;;
    --max-iterations) MAX_ITER="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# Resolve spec dir: explicit path > slug > single auto-detect.
if [[ -z "$SPEC_DIR" && -n "$FEATURE" ]]; then
  SPEC_DIR="$PROJECT_ROOT/specs/$FEATURE"
fi
if [[ -z "$SPEC_DIR" ]]; then
  n=0; only=""
  for d in "$PROJECT_ROOT/specs/"*/; do
    [[ -f "${d}spec.md" ]] && { only="$d"; n=$(( n + 1 )); }
  done
  if [[ "$n" -eq 1 ]]; then SPEC_DIR="${only%/}"; else
    echo "PHASE=none"
    echo "NEXT=/pro.go <description>  (no unambiguous feature dir — pass --feature)"
    [[ "$n" -gt 1 ]] && echo "WARNING=multiple feature dirs found; pass --feature <slug>"
    exit 0
  fi
fi
FEATURE="${FEATURE:-$(basename "$SPEC_DIR")}"
FKD="$PROJECT_ROOT/.knowledge/features/$FEATURE"

# Default max-iterations from pro-config (loop.max_iterations), fallback 20.
if [[ -z "$MAX_ITER" ]]; then
  for cfg in "$PROJECT_ROOT/.specify/extensions/pro/pro-config.local.yml" \
             "$PROJECT_ROOT/.specify/extensions/pro/pro-config.yml"; do
    if [[ -f "$cfg" ]]; then
      v="$(awk '/^loop:/{f=1;next} f&&/^[^ ]/{f=0} f&&/max_iterations:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$cfg" 2>/dev/null)"
      [[ -n "$v" ]] && { MAX_ITER="$v"; break; }
    fi
  done
fi
[[ "$MAX_ITER" =~ ^[0-9]+$ ]] || MAX_ITER=20

# ── Artifact census ──────────────────────────────────────────────────────────
has_spec=0;  [[ -f "$SPEC_DIR/spec.md"  ]] && has_spec=1
has_plan=0;  [[ -f "$SPEC_DIR/plan.md"  ]] && has_plan=1
has_tasks=0; [[ -f "$SPEC_DIR/tasks.md" ]] && has_tasks=1
has_contracts=0
ls "$FKD/contracts/sprint-"*.md >/dev/null 2>&1 && has_contracts=1
has_progress=0; [[ -f "$FKD/progress.md" ]] && has_progress=1
has_evals=0
ls "$FKD/evaluations/sprint-"*.md >/dev/null 2>&1 && has_evals=1

tasks_done=0; tasks_open=0
if [[ "$has_tasks" -eq 1 ]]; then
  tasks_done="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$SPEC_DIR/tasks.md" 2>/dev/null)"; tasks_done="${tasks_done:-0}"
  tasks_open="$(grep -cE '^[[:space:]]*- \[ \]' "$SPEC_DIR/tasks.md" 2>/dev/null)"; tasks_open="${tasks_open:-0}"
fi
tasks_total=$(( tasks_done + tasks_open ))

iter_last=0
if [[ "$has_progress" -eq 1 ]]; then
  iter_last="$(grep -E '^## Iteration [0-9]+' "$FKD/progress.md" 2>/dev/null | tail -1 | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
  [[ "$iter_last" =~ ^[0-9]+$ ]] || iter_last=0
fi
remaining=$(( MAX_ITER - iter_last )); [[ "$remaining" -lt 0 ]] && remaining=0

# ── Consistency checks (warnings, never fatal) ───────────────────────────────
if [[ -f "$SPEC_DIR/handoff.md" ]]; then
  hf_feat="$(grep -oE '[0-9]{3}-[a-z0-9-]+' "$SPEC_DIR/handoff.md" 2>/dev/null | head -1)"
  if [[ -n "$hf_feat" && "$hf_feat" != "$FEATURE" ]]; then
    echo "WARNING=handoff.md names feature '$hf_feat' (this is '$FEATURE') — ignoring handoff; loop should load progress.md + tasks.md instead"
  fi
fi
if [[ "$has_tasks" -eq 1 ]] && git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  last_ckpt_ts="$(git -C "$PROJECT_ROOT" log -1 --format=%ct --grep='\[Pro\] Checkpoint' 2>/dev/null)"
  if [[ "$last_ckpt_ts" =~ ^[0-9]+$ ]]; then
    tasks_mtime="$(stat -f %m "$SPEC_DIR/tasks.md" 2>/dev/null || stat -c %Y "$SPEC_DIR/tasks.md" 2>/dev/null)"
    if [[ "$tasks_mtime" =~ ^[0-9]+$ && "$tasks_mtime" -gt "$last_ckpt_ts" ]]; then
      echo "WARNING=tasks.md modified after the last checkpoint commit — verify task states before continuing"
    fi
  fi
fi

# ── Phase decision table (mirror of commands/pro.resume.md) ──────────────────
if   [[ "$has_spec" -eq 0 ]]; then
  PHASE="none";            NEXT="/pro.go <description>"
elif [[ "$has_plan" -eq 0 ]]; then
  PHASE="spec-only";       NEXT="/speckit.plan"
elif [[ "$has_tasks" -eq 0 ]]; then
  PHASE="plan-only";       NEXT="/speckit.tasks"
elif [[ "$tasks_total" -gt 0 && "$tasks_open" -eq 0 ]]; then
  PHASE="complete"
  if [[ "$has_evals" -eq 1 ]]; then NEXT="(done — already evaluated)"; else NEXT="Phase 7/8 wrap-up: /pro.reconcile → /pro.evaluate → run report"; fi
elif [[ "$has_progress" -eq 1 ]]; then
  PHASE="in-loop";         NEXT="implement loop, iteration $(( iter_last + 1 )) (remaining budget $remaining)"
elif [[ "$has_contracts" -eq 1 ]]; then
  PHASE="contracts-ready"; NEXT="implement loop, iteration 1"
else
  PHASE="tasks-only";      NEXT="/pro.contract then the implement loop"
fi

echo "PHASE=$PHASE"
echo "NEXT=$NEXT"
echo "ITER_LAST=$iter_last"
echo "REMAINING=$remaining"
echo "TASKS_DONE=$tasks_done"
echo "TASKS_TOTAL=$tasks_total"
