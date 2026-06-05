#!/usr/bin/env bash
# update-all.sh — one-pass upgrade for any project that USES SpecKit Pro.
#
# Order of operations:
#   1. specify CLI            -> latest spec-kit release        (specify self upgrade)
#   2. base Spec Kit assets   -> latest templates/scripts        (specify init . --force)
#   3. coding-agent integrations (one or many; FIRST = default)
#   4. previously-registered extensions re-registered + updated  (init rebuilds the registry)
#   5. SpecKit Pro            -> latest (or pinned) release       (specify extension add --force)
#
# Preserved: specs/ and .knowledge/ are NEVER touched. An authored
# constitution.md and your pro-config*.yml are snapshotted and restored — the
# pro reinstall replaces the whole .specify/extensions/pro/ directory.
#
# Verified behavior of `specify init . --force` (tested, 2026-06):
#   - keeps extension *files* and an existing constitution.md, BUT
#   - REGENERATES .specify/extensions/.registry, re-registering only the
#     extensions init itself installs. Anything else (e.g. git, pro) survives on
#     disk but drops out of the registry — so step 4 re-registers them.
#
# Run from the ROOT of a spec-kit project. NOT for the pro source repo.

set -euo pipefail

usage() {
  cat <<'EOF'
update-all.sh — keep a SpecKit-Pro project fully up to date in one pass.

Usage:
  ./update-all.sh                       # claude only (default agent)
  ./update-all.sh claude copilot        # claude (default) + copilot
  ./update-all.sh claude gemini codex   # several agents; FIRST is the default
  ./update-all.sh --pin v1.20.0 claude  # pin pro to a tag instead of 'latest'
  ./update-all.sh --no-base claude      # skip step 2 (don't refresh base templates)

Options:
  --pin <tag>   Install pro from a specific tag (e.g. v1.20.0) instead of latest.
  --no-base     Skip the base-template refresh (specify init); safer, but you
                won't pick up new spec/plan/tasks templates.
  -h, --help    Show this help.

The FIRST positional agent is set as the default integration. Agents not
declared "multi-install safe" (e.g. copilot) are added with --force.
EOF
}

# ---- args -------------------------------------------------------------------
PRO_TAG="latest"
DO_BASE=1
AGENTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pin)     PRO_TAG="${2:?--pin needs a tag, e.g. v1.20.0}"; shift 2 ;;
    --pin=*)   PRO_TAG="${1#*=}"; shift ;;
    --no-base) DO_BASE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; while [[ $# -gt 0 ]]; do AGENTS+=("$1"); shift; done ;;
    -*)        echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         AGENTS+=("$1"); shift ;;
  esac
done
[[ ${#AGENTS[@]} -eq 0 ]] && AGENTS=(claude)
PRIMARY="${AGENTS[0]}"
PRO_URL="https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/${PRO_TAG}.zip"

# ---- preflight --------------------------------------------------------------
command -v specify >/dev/null 2>&1 || { echo "specify CLI not found on PATH." >&2; exit 3; }

if [[ ! -d .specify ]]; then
  echo "No .specify/ in $(pwd) — run this from the root of a spec-kit project." >&2
  exit 1
fi

# Refuse to run inside the speckit-pro SOURCE checkout (root extension.yml with id: pro).
if [[ -f extension.yml ]] && grep -qE '^[[:space:]]*id:[[:space:]]*"?pro"?[[:space:]]*$' extension.yml; then
  echo "Refusing: this looks like the speckit-pro SOURCE repo." >&2
  echo "Run this in a project that USES pro. To dev-test from source here:" >&2
  echo "  specify extension add --dev . --force" >&2
  exit 1
fi

echo "Agents:  ${AGENTS[*]}   (default: $PRIMARY)"
echo "Pro:     $PRO_TAG       Refresh base templates: $([[ $DO_BASE -eq 1 ]] && echo yes || echo no)"
echo

# ---- snapshot the non-regenerable, gitignored bits --------------------------
BK="$(mktemp -d "${TMPDIR:-/tmp}/speckit-up.XXXXXX")"
trap 'rm -rf "$BK"' EXIT

[[ -f .specify/memory/constitution.md ]] && cp -f .specify/memory/constitution.md "$BK/constitution.md"

shopt -s nullglob
for f in .specify/extensions/pro/pro-config.yml .specify/extensions/pro/pro-config.local.yml; do
  [[ -f "$f" ]] && cp -f "$f" "$BK/"
done
shopt -u nullglob

# Snapshot registered extension ids — init rebuilds the registry and drops
# anything it doesn't install itself, so we must re-register them in step 4.
EXTS=()
REG=".specify/extensions/.registry"
if [[ -f "$REG" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r id; do [[ -n "$id" ]] && EXTS+=("$id"); done < <(
      python3 - "$REG" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print("\n".join(json.load(fh).get("extensions", {}).keys()))
except Exception:
    pass
PY
    )
  fi
  # Fallback when python3 is absent OR its JSON parse produced nothing:
  # extension ids are the 4-space-indented object keys under "extensions".
  if [[ ${#EXTS[@]} -eq 0 ]]; then
    while IFS= read -r id; do [[ -n "$id" ]] && EXTS+=("$id"); done < <(
      grep -oE '^    "[^"]+": \{' "$REG" | sed -E 's/^    "([^"]+)".*/\1/'
    )
  fi
fi

# ---- 1. specify CLI ---------------------------------------------------------
echo "==> 1/5  Upgrading specify CLI"
specify self upgrade || echo "    (self upgrade skipped/failed — continuing; try 'specify self check')" >&2

# ---- 2. base templates/scripts + primary integration ------------------------
if [[ $DO_BASE -eq 1 ]]; then
  echo "==> 2/5  Refreshing base templates/scripts + primary integration ($PRIMARY)"
  specify init . --ai "$PRIMARY" --force --no-git
else
  echo "==> 2/5  Skipped base refresh (--no-base); ensuring primary integration ($PRIMARY)"
  specify integration upgrade "$PRIMARY" --force 2>/dev/null \
    || specify integration install "$PRIMARY" --force
fi
specify integration use "$PRIMARY" >/dev/null 2>&1 || true

# ---- 3. additional agent integrations ---------------------------------------
echo "==> 3/5  Setting up additional agents"
for a in "${AGENTS[@]:1}"; do
  echo "    - $a"
  specify integration upgrade "$a" --force 2>/dev/null \
    || specify integration install "$a" --force \
    || echo "      (could not set up '$a' — is its CLI installed?)" >&2
done

# ---- 4. re-register extensions the registry rebuild may have dropped ---------
echo "==> 4/5  Restoring & updating other extensions (pro handled in step 5)"
FAILED_EXTS=()
# Length-guard the loop: under `set -u`, bash 3.2 treats "${EXTS[@]}" on an empty
# array as an unbound-variable error, so never expand it unguarded.
if [[ ${#EXTS[@]} -gt 0 ]]; then
  for id in "${EXTS[@]}"; do
    [[ "$id" == "pro" ]] && continue   # handled explicitly in step 5
    echo "    - $id"
    specify extension add "$id" --force 2>/dev/null \
      || specify extension update "$id" 2>/dev/null \
      || { echo "      (could not restore '$id' from catalog)" >&2; FAILED_EXTS+=("$id"); }
  done
fi

# ---- 5. SpecKit Pro ---------------------------------------------------------
echo "==> 5/5  Reinstalling SpecKit Pro ($PRO_TAG)"
# pro ships as a raw GitHub archive (not in any spec-kit catalog), so
# `extension add --from <url>` shows an "Untrusted Source" confirmation that
# --force does NOT suppress. Auto-confirm it so the script runs unattended —
# this is our own published release. (Pipe a 'y'; printf finishes before the
# CLI reads, so no SIGPIPE under `set -o pipefail`.)
printf 'y\n' | specify extension add pro --from "$PRO_URL" --force

# ---- restore snapshotted bits (pro reinstall replaced .specify/extensions/pro/)
[[ -f "$BK/constitution.md" ]] && cp -f "$BK/constitution.md" .specify/memory/constitution.md
shopt -s nullglob
for f in "$BK"/pro-config*.yml; do
  cp -f "$f" ".specify/extensions/pro/$(basename "$f")" && echo "    restored $(basename "$f")"
done
shopt -u nullglob

echo
if [[ ${#FAILED_EXTS[@]} -gt 0 ]]; then
  echo "⚠ Completed with warnings — could not restore: ${FAILED_EXTS[*]}" >&2
  echo "  Re-run the script, or add them manually:  specify extension add <id>" >&2
fi
echo "Installed extensions:"
specify extension list
if [[ ${#FAILED_EXTS[@]} -gt 0 ]]; then exit 1; fi
echo "✓ All up to date."
