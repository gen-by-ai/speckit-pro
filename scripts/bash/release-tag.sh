#!/usr/bin/env bash
# Create an annotated version tag and move the floating "latest" tag to the same commit.
#
# Usage:
#   ./scripts/bash/release-tag.sh v1.19.0
#
# Then push (script does not push main — only tags):
#   git push origin main
#   git push origin v1.19.0
#   git push origin refs/tags/latest --force

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <tag>   e.g. v1.19.0" >&2
  exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
  echo "Refuse to use 'latest' as the version tag — use vX.Y.Z" >&2
  exit 1
fi

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree is dirty — commit or stash before tagging." >&2
  exit 1
fi

COMMIT=$(git rev-parse HEAD)
MSG=$(grep -A1 "^## \\[${VERSION#v}\\]" CHANGELOG.md 2>/dev/null | tail -1 || true)
if [[ -z "$MSG" ]]; then
  MSG="SpecKit Pro $VERSION"
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Tag $VERSION already exists at $(git rev-parse "$VERSION")" >&2
  exit 1
fi

git tag -a "$VERSION" -m "SpecKit Pro $VERSION

$MSG"
git tag -f latest "$COMMIT"

echo ""
echo "Created:"
echo "  $VERSION  → $COMMIT"
echo "  latest    → $COMMIT (moved)"
echo ""
echo "Push:"
echo "  git push origin main"
echo "  git push origin $VERSION"
echo "  git push origin refs/tags/latest --force"
