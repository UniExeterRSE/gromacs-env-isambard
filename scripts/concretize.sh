#!/usr/bin/env bash
# concretize.sh — concretize the selected variant (the dependency SOLVE) and
# assert the resulting lock matches it.
#
# This is the SOLVE phase on its own — shared by build.sh (which then installs)
# and fetch.sh (which then downloads sources). Run it standalone as the cheap,
# login-node-safe check that a manifest change still solves correctly, without
# the multi-hour install.
#
# The solve is single-process and idempotent: a no-op (~1s) when the lock already
# matches the manifest. Set FORCE_CONCRETIZE=1 to force a fresh re-solve. Needs a
# Python in [3.7, 3.12) (module load cray-python/3.11.7, or use pixi).
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/common.sh"
# shellcheck source=scripts/lib.sh
. "$_here/lib.sh"

gmx_prepare
gmx_concretize

echo "CONCRETIZE_OK ($VARIANT)"
