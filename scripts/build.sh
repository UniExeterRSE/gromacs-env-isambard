#!/usr/bin/env bash
# build.sh — build the GROMACS Spack environment for one variant.
#
# Produces `gmx` (thread-MPI) + `gmx_mpi` (MPI) and their Lmod modulefile under
# PREFIX. The phases live in scripts/lib.sh; this driver just composes them:
# prepare + concretize (the SOLVE — also standalone, scripts/concretize.sh) then
# install + view + modulefile + verification. All heavy output goes under PREFIX
# (outside the repo); re-runs are cheap (Spack skips already-built, content-
# addressed packages). Run on a compute node — see scripts/build.sbatch.
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/common.sh"
# shellcheck source=scripts/lib.sh
. "$_here/lib.sh"

gmx_prepare            # validate + python + submodules + modules + env + simd.yaml
gmx_concretize         # the dependency solve + variant assertions
gmx_install
gmx_regenerate_view
gmx_gen_modulefile
gmx_verify_build       # asserts SIMD / SVE width / target actually compiled in
gmx_report_linkage     # records what the module's LD_LIBRARY_PATH is buying

echo ""
echo "BUILD_OK — GROMACS environment built ($VARIANT)."
echo "Use it:  module use $MODULEFILES_DIR && module load $MODULE_NAME"
echo "         gmx -version ; \$GROMACS_MPI_LAUNCHER -n 48 gmx_mpi mdrun ..."
