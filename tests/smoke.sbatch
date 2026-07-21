#!/bin/bash
#SBATCH --job-name=gromacs-smoke
#SBATCH --partition=grace
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=24
#SBATCH --cpus-per-task=6
#SBATCH --time=00:20:00
#SBATCH --output=logs/smoke-%j.out
#
# The acceptance test: does this build actually work, across two nodes, over the
# real interconnect? Run from the repo root, once per built variant:
#   sbatch tests/smoke.sbatch                                        # cray-sve (default)
#   sbatch --export=ALL,GROMACS_STACK=spack tests/smoke.sbatch       # spack-sve
#   sbatch --export=ALL,GROMACS_SIMD=neon tests/smoke.sbatch         # cray-neon
#
# Budget: 2 nodes for well under 20 minutes (the MD itself is ~1 minute). It is
# deliberately cheap enough to re-run after any change to the environment.
#
# Geometry: 24 MPI ranks x 6 OpenMP threads per node = 144 cores, 2 nodes = 48
# ranks. 6 contiguous cores per rank means no rank straddles the node's two NUMA
# domains, and 24 ranks/node keeps ~7000 atoms per rank — comfortably above the
# point where GROMACS' domain decomposition gives up.
#
# A successful run ends with SMOKE_OK.
set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-$(pwd)}" || exit 1

export GROMACS_STACK="${GROMACS_STACK:-cray}"
export GROMACS_SIMD="${GROMACS_SIMD:-sve}"
export GROMACS_PREFIX="${GROMACS_PREFIX:-$PROJECTDIR/$USER/opt/$(uname -sm | tr ' ' -)}"

exec bash tests/smoke.sh
