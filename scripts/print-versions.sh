#!/usr/bin/env bash
# Ensure the environment is active and report the build configuration. The
# authoritative answer to "how was this built?" is `gmx -version`, so print it.
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/common.sh"
# shellcheck source=scripts/activate.sh
. "$_here/activate.sh"

if [ ! -f "$MODULEFILE" ]; then
  echo "Variant '$VARIANT' is not built yet (no modulefile at $MODULEFILE)."
  echo "  Build it on a compute node (from the repo root):"
  echo "    sbatch scripts/build.sbatch                                                  # cray-sve (default)"
  echo "    sbatch --export=ALL,GROMACS_STACK=spack scripts/build.sbatch                 # spack-sve"
  echo "    sbatch --export=ALL,GROMACS_SIMD=neon scripts/build.sbatch                   # cray-neon"
  exit 1
fi

echo "Variant: $VARIANT   (module: $MODULE_NAME)"
echo "Launcher: ${GROMACS_MPI_LAUNCHER:-?}"
echo ""
gmx -version 2>&1 | grep -E "GROMACS version|Precision|SIMD instructions|FFT library|MPI library|C\+\+ compiler:|C\+\+ compiler flags"
