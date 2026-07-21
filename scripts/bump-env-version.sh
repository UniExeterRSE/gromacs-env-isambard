#!/usr/bin/env bash
# bump-env-version.sh — set the environment version (CalVer) in ./VERSION.
#
# The build is versioned by GROMACS_ENV_VERSION, read from ./VERSION by
# scripts/common.sh. Bumping it makes the NEXT build land in a FRESH prefix
# ($BASE/<version>) and a fresh module (gromacs-env/<version>/<variant>) instead of
# overwriting the current one — so a rebuild can be shared without disturbing the
# environment others are already loading. This is the ENVIRONMENT's version,
# deliberately distinct from the GROMACS version itself (pinned in
# spack-env/common.yaml).
#
# Usage:
#   bash scripts/bump-env-version.sh            # -> v$(date +%Y.%m.%d) (today, CalVer)
#   bash scripts/bump-env-version.sh v2026.07.01  # explicit version
# Then review + commit the change: git add VERSION && git commit.
set -euo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
repo_root="$(cd -- "$_here/.." && pwd)"
version_file="$repo_root/VERSION"

new="${1:-v$(date +%Y.%m.%d)}"
# Basic sanity: a single non-empty token that is safe to embed in paths. The
# version forms install/module directory paths ($BASE/<version>,
# modulefiles/.../<version>), so reject whitespace and any path separator or
# traversal ('/', '\', '..').
case "$new" in
  ''|*[[:space:]]*) echo "ERROR: invalid version '$new' (want a single token, e.g. v2026.07.01)" >&2; exit 1 ;;
  */*|*\\*|*..*)    echo "ERROR: invalid version '$new' (no '/', '\\' or '..' — it forms install/module paths)" >&2; exit 1 ;;
esac

old="$(tr -d '[:space:]' < "$version_file" 2>/dev/null || true)"
printf '%s\n' "$new" > "$version_file"

echo "VERSION: ${old:-(none)} -> $new"
echo "Next build installs to:  \$BASE/$new   (module: gromacs-env/$new/<variant>)"
echo "Commit it:  git add VERSION && git commit -m \"Bump env version to $new\""
