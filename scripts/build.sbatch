#!/bin/bash
#SBATCH --job-name=gromacs-build
#SBATCH --partition=grace
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem-per-cpu=1600M
#SBATCH --time=02:00:00
#SBATCH --output=logs/build-%j.out
#
# Build one GROMACS variant on a Grace compute node. Run from the repo root:
#   sbatch scripts/build.sbatch                                    # cray-neon (default)
#   sbatch --export=ALL,GROMACS_STACK=spack scripts/build.sbatch   # spack-neon
#   sbatch --export=ALL,GROMACS_SIMD=sve scripts/build.sbatch      # cray-sve
#
# Why a compute node: the login nodes cap user processes (ulimit -u 1900), which
# a full parallel build can exhaust. Why these resources: grace allocates memory
# pro-rata (230400 MB / 144 cores = 1600 MB/core), so --mem-per-cpu=1600M claims
# a node's full per-core share and scales with --cpus-per-task; Slurm's default
# (~1 GiB/core) is too little for GROMACS' heavier C++ translation units. A
# small, short, non-exclusive job backfills sooner than an exclusive one.
#
# The three variants SHARE one install tree, so whichever you build first pays
# for the common subtree (cmake, openblas, hwloc, ...) and the others are much
# faster. Build them one at a time: concurrent Spack installs into the same tree
# race on the database lock.
set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-$(pwd)}" || exit 1

# ---- Configuration: everything this build needs, set explicitly -----------
# GROMACS_STACK (cray|spack) and GROMACS_SIMD (neon|sve) are deliberately NOT
# defaulted here — scripts/common.sh owns those defaults, and re-stating them in
# every sbatch is how they drift. Override either via --export (see above).
# BASE: the per-arch container, shared across env versions (Lustre; survives the
# job). common.sh installs into the VERSIONED prefix $GROMACS_PREFIX/<version>,
# with the version read from ./VERSION.
export GROMACS_PREFIX="${GROMACS_PREFIX:-$PROJECTDIR/$USER/opt/$(uname -sm | tr ' ' -)}"
# Transient Spack build stage; node-local NVMe (fast, off the contended Lustre).
# $LOCALDIR is Isambard's per-node local disk; edit if your system differs.
# One stage dir for every variant: Spack keys its build stage by package hash, so
# sharing it lets a rebuild reuse an unpacked source rather than re-extract it.
# Variants are built one at a time anyway (they share the install tree's lock).
export GROMACS_WORKING_DIR="${GROMACS_WORKING_DIR:-$LOCALDIR/gromacs-build}"
export SPACK_JOBS="${SPACK_JOBS:-${SLURM_CPUS_PER_TASK:-32}}"
# ---------------------------------------------------------------------------

echo "host=$(hostname) jobid=${SLURM_JOB_ID:-?} cpus=${SLURM_CPUS_PER_TASK:-?}"
echo "  GROMACS_ENV_VERSION=${GROMACS_ENV_VERSION:-$(cat VERSION 2>/dev/null || echo '?')}  (install -> \$GROMACS_PREFIX/<version>)"
echo "  GROMACS_PREFIX(base)=$GROMACS_PREFIX"
echo "  GROMACS_WORKING_DIR=$GROMACS_WORKING_DIR"

# Spack 1.0 needs Python in [3.7,3.12); Isambard ships cray-python. (build.sh
# re-checks and fails with a clear hint if it is missing/too new.)
if ! command -v module >/dev/null 2>&1; then
  for f in /opt/cray/pe/lmod/lmod/init/bash /etc/profile.d/lmod.sh /usr/share/lmod/lmod/init/bash; do
    [ -f "$f" ] && . "$f" && break
  done
fi
module load cray-python/3.11.7 || { echo "ERROR: could not load cray-python/3.11.7"; exit 1; }

bash scripts/build.sh

# Prefer pixi? It supplies the Python, so drop the cray-python load and replace
# the line above with:   exec pixi run build      (the config above still applies)
