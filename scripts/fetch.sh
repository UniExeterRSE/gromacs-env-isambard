#!/usr/bin/env bash
# fetch.sh — pre-download every source on the LOGIN NODE.
#
# Runs the network/IO-heavy work on a login node so the compute-node build stays
# offline: clone the pinned submodules (if missing), concretize the selected
# variant, then `spack fetch` every from-source package into the persistent
# source cache ($BASE/source-cache). The subsequent build then installs from a
# warm cache and fetches nothing.
#
# Shares the prepare + concretize phases with build.sh (scripts/lib.sh), so the
# solve here is exactly the one the build uses. Concurrency is capped
# (FETCH_JOBS, default 4) for the login node's small `ulimit -u`.
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/common.sh"
# shellcheck source=scripts/lib.sh
. "$_here/lib.sh"

FETCH_JOBS="${FETCH_JOBS:-4}"

# Cap git's submodule fetch concurrency for this whole process tree — including
# any clones Spack itself performs — so a --recursive clone cannot fan out past
# FETCH_JOBS at any nesting level and trip the login node's `ulimit -u`.
# Injected via GIT_CONFIG_* (git >= 2.31) so it reaches every `git` we spawn.
_gc_n="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${_gc_n}=submodule.fetchJobs"
export "GIT_CONFIG_VALUE_${_gc_n}=$FETCH_JOBS"
export GIT_CONFIG_COUNT="$((_gc_n + 1))"

info "VARIANT=$VARIANT  FETCH_JOBS=$FETCH_JOBS (login-node ulimit -u cap)"

gmx_clone_missing_submodules "$FETCH_JOBS"
gmx_prepare
gmx_concretize
gmx_fetch

echo "FETCH_OK ($VARIANT)"
