#!/usr/bin/env bash
# =============================================================================
# SpecKit Pro — Knowledge layout migration
# pro-knowledge-migrate.sh
#
# Moves legacy .repo-knowledge/ + .ai-knowledge/ into unified .knowledge/
#
# Usage:
#   pro-knowledge-migrate.sh [--dry-run] [--project-root <dir>]
# =============================================================================

set -euo pipefail

DRY_RUN=0
PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --project-root)  PROJECT_ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: pro-knowledge-migrate.sh [--dry-run] [--project-root <dir>]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd)

KNOWLEDGE="$PROJECT_ROOT/.knowledge"
FEATURES="$KNOWLEDGE/features"
METRICS="$KNOWLEDGE/metrics"
LEGACY_REPO="$PROJECT_ROOT/.repo-knowledge"
LEGACY_AI="$PROJECT_ROOT/.ai-knowledge"
GITIGNORE="$PROJECT_ROOT/.gitignore"

MOVED=0
SKIPPED=0
CONFLICTS=0
WARNINGS=()

log() { echo "[Pro] $*"; }
warn() { WARNINGS+=("$*"); echo "[Pro] WARN: $*" >&2; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $*"
  else
    eval "$@"
  fi
}

ensure_dir() {
  local d="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] mkdir -p $d"
  elif [[ ! -d "$d" ]]; then
    mkdir -p "$d"
  fi
}

# Move one file or directory; never overwrite destination.
move_path() {
  local src="$1" dest="$2"
  [[ ! -e "$src" ]] && return 0
  if [[ -e "$dest" ]]; then
    CONFLICTS=$((CONFLICTS + 1))
    warn "Conflict (dest exists, skipped): $src -> $dest"
    return 0
  fi
  local dest_parent
  dest_parent=$(dirname "$dest")
  ensure_dir "$dest_parent"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] mv $src $dest"
  else
    mv "$src" "$dest"
  fi
  MOVED=$((MOVED + 1))
  log "Moved: $src -> $dest"
}

# Move children of src_dir into dest_dir (not the directory node itself).
move_children() {
  local src_dir="$1" dest_dir="$2"
  [[ ! -d "$src_dir" ]] && return 0
  local entry
  for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
    [[ -e "$entry" ]] || continue
    local base
    base=$(basename "$entry")
    [[ "$base" == "." || "$base" == ".." ]] && continue
    move_path "$entry" "$dest_dir/$base"
  done
}

remove_if_empty() {
  local d="$1"
  [[ ! -d "$d" ]] && return 0
  if [[ -n "$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]]; then
    warn "Not removing non-empty directory: $d"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] rmdir $d"
  else
    rmdir "$d" 2>/dev/null || warn "Could not remove: $d"
    log "Removed empty directory: $d"
  fi
}

append_gitignore_line() {
  local line="$1"
  local pattern="$2"
  if [[ ! -f "$GITIGNORE" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] create $GITIGNORE with $line"
    else
      printf '%s\n' "$line" >"$GITIGNORE"
      log "Created $GITIGNORE"
    fi
    return 0
  fi
  if grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] append to .gitignore: $line"
  else
    printf '\n%s\n' "$line" >>"$GITIGNORE"
    log "Appended to .gitignore: $line"
  fi
  MOVED=$((MOVED + 1))
}

comment_out_gitignore_line() {
  local pattern="$1"
  [[ ! -f "$GITIGNORE" ]] && return 0
  if ! grep -qE "^[[:space:]]*${pattern}" "$GITIGNORE" 2>/dev/null; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] comment out .gitignore lines matching: $pattern"
  else
    # macOS/BSD sed
    sed -i '' -E "s|^([[:space:]]*)(${pattern}.*)|\1# migrated to .knowledge/ — \2|" "$GITIGNORE" 2>/dev/null \
      || sed -i -E "s|^([[:space:]]*)(${pattern}.*)|\1# migrated to .knowledge/ — \2|" "$GITIGNORE"
    log "Commented legacy .gitignore entry: $pattern"
  fi
}

log "Knowledge migration — project root: $PROJECT_ROOT"
[[ "$DRY_RUN" -eq 1 ]] && log "DRY RUN — no files will be modified"

ensure_dir "$FEATURES"
ensure_dir "$METRICS"

# ─── 1. .repo-knowledge/ → .knowledge/ (shared files) ───────────────────────
if [[ -d "$LEGACY_REPO" ]]; then
  log "Migrating shared knowledge: $LEGACY_REPO -> $KNOWLEDGE"
  move_children "$LEGACY_REPO" "$KNOWLEDGE"
  remove_if_empty "$LEGACY_REPO"
else
  log "No legacy $LEGACY_REPO (skip)"
fi

# ─── 2. .ai-knowledge/<feature>/ → .knowledge/features/<feature>/ ───────────
if [[ -d "$LEGACY_AI" ]]; then
  log "Migrating per-feature workspace: $LEGACY_AI -> $FEATURES"
  local_metrics_src="$LEGACY_AI/local-metrics.jsonl"
  if [[ -f "$local_metrics_src" ]]; then
    move_path "$local_metrics_src" "$METRICS/local-metrics.jsonl"
  fi
  for entry in "$LEGACY_AI"/* "$LEGACY_AI"/.[!.]* "$LEGACY_AI"/..?*; do
    [[ -e "$entry" ]] || continue
    base=$(basename "$entry")
    [[ "$base" == "." || "$base" == ".." ]] && continue
    [[ "$base" == "local-metrics.jsonl" ]] && continue
    if [[ -d "$entry" ]]; then
      move_path "$entry" "$FEATURES/$base"
    else
      # Loose file at legacy root — park under features/_legacy-root/
      ensure_dir "$FEATURES/_legacy-root"
      move_path "$entry" "$FEATURES/_legacy-root/$base"
    fi
  done
  remove_if_empty "$LEGACY_AI"
else
  log "No legacy $LEGACY_AI (skip)"
fi

# ─── 3. Bootstrap shared files if tree is still empty ───────────────────────
if [[ ! -f "$KNOWLEDGE/INDEX.md" && "$DRY_RUN" -eq 0 ]]; then
  for tpl in \
    "$PROJECT_ROOT/.specify/extensions/pro/templates/knowledge" \
    "$PROJECT_ROOT/templates/knowledge" \
    "$PROJECT_ROOT/templates/repo-knowledge"; do
    if [[ -d "$tpl" ]]; then
      log "Bootstrapping missing shared files from $tpl"
      while IFS= read -r -d '' f; do
        rel="${f#"$tpl"/}"
        [[ -z "$rel" || "$rel" == "README.md" ]] && continue
        dest="$KNOWLEDGE/$rel"
        [[ -e "$dest" ]] && continue
        ensure_dir "$(dirname "$dest")"
        cp "$f" "$dest"
        log "Bootstrapped: $rel"
        MOVED=$((MOVED + 1))
      done < <(find "$tpl" -type f -print0 2>/dev/null)
      break
    fi
  done
fi

# ─── 4. .gitignore ───────────────────────────────────────────────────────────
append_gitignore_line "# SpecKit Pro — workspace-only (unified .knowledge/ layout)" ".knowledge/features"
append_gitignore_line ".knowledge/features/" ".knowledge/features/"
append_gitignore_line ".knowledge/metrics/" ".knowledge/metrics/"
comment_out_gitignore_line '\.ai-knowledge'
comment_out_gitignore_line '\.repo-knowledge'

# ─── Summary ─────────────────────────────────────────────────────────────────
REPORT="$KNOWLEDGE/MIGRATION-REPORT.md"
if [[ "$DRY_RUN" -eq 0 ]]; then
  ensure_dir "$KNOWLEDGE"
  cat >"$REPORT" <<EOF
# Knowledge layout migration

> Generated by SpecKit Pro | $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Result

- **Moved:** $MOVED paths
- **Skipped (already present):** $SKIPPED gitignore lines
- **Conflicts (manual merge needed):** $CONFLICTS

## New layout

- Shared (commit): \`.knowledge/INDEX.md\`, \`domain/\`, \`architecture.md\`, …
- Per-feature (gitignore): \`.knowledge/features/<slug>/\`
- Metrics (gitignore): \`.knowledge/metrics/local-metrics.jsonl\`

## Next steps

1. Review \`pro-config.yml\` — \`knowledge.root_dir\` should be \`.knowledge\`, \`knowledge.features_subdir\` should be \`features\`.
2. Update \`local_models.metrics_file\` to \`.knowledge/metrics/local-metrics.jsonl\` if it still references \`.ai-knowledge/\`.
3. Run \`git status\` and commit shared \`.knowledge/\` files (not \`features/\` or \`metrics/\`).
4. Run \`/speckit.pro.knowledge-sync --mode prime\` on an active feature to verify.

EOF
  log "Wrote $REPORT"
fi

log "Done — moved: $MOVED, conflicts: $CONFLICTS, dry-run: $DRY_RUN"
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  log "Warnings: ${#WARNINGS[@]} (see stderr)"
fi

if [[ "$CONFLICTS" -gt 0 ]]; then
  exit 2
fi
exit 0
