#!/bin/bash
#SBATCH --job-name=gromacs-bench
#SBATCH --partition=grace
#SBATCH --nodes=2
#SBATCH --exclusive
#SBATCH --time=00:40:00
#SBATCH --output=logs/bench-%j.out
#
# Compare the built variants on identical work. Run from the repo root:
#   sbatch tests/benchmark.sbatch
#
# --exclusive matters here and only here: a benchmark that shares its nodes
# measures the neighbours as much as GROMACS. The smoke test does not need it.
#
# Budget: 2 nodes, well under 40 minutes. Each individual mdrun is ~30-60 s; the
# matrix is (variants) x (1,2 nodes) x (3 rank/thread ratios) x (repeats).
#
# All variants run against ONE tpr generated once, so the only thing differing
# between rows is the build.
#
# Results land in a TSV under logs/ and are summarised at the end of this log.
set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-$(pwd)}" || exit 1

export GROMACS_PREFIX="${GROMACS_PREFIX:-$PROJECTDIR/$USER/opt/$(uname -sm | tr ' ' -)}"
VARIANTS="${GROMACS_BENCH_VARIANTS:-cray-sve spack-sve cray-neon}"
NSTEPS="${GROMACS_BENCH_NSTEPS:-20000}"
BOX="${GROMACS_BENCH_BOX:-12.0}"

results="logs/bench-${SLURM_JOB_ID:-manual}.tsv"
printf 'variant\tsimd\tfft\tnodes\tranks\tomp\trep\tns_per_day\n' > "$results"

if ! command -v module >/dev/null 2>&1; then
  for f in /opt/cray/pe/lmod/lmod/init/bash /etc/profile.d/lmod.sh /usr/share/lmod/lmod/init/bash; do
    [ -f "$f" ] && . "$f" && break
  done
fi

echo "=== Generating the benchmark case (once, shared by every variant)"
# Any built variant's `gmx` can write the tpr — a tpr is a portable binary and
# GROMACS reads its own across builds of the same version. Use the first one
# that is actually built.
case_dir="${LOCALDIR:-/tmp}/gromacs-bench-case-${SLURM_JOB_ID:-$$}"
built=""
for v in $VARIANTS; do
  ( export GROMACS_STACK="${v%-*}" GROMACS_SIMD="${v##*-}"
    . scripts/common.sh
    [ -f "$MODULEFILE" ] ) && { built="$v"; break; }
done
[ -n "$built" ] || { echo "ERROR: none of the variants ($VARIANTS) is built"; exit 1; }

(
  export GROMACS_STACK="${built%-*}" GROMACS_SIMD="${built##*-}"
  . scripts/common.sh
  module use "$MODULEFILES_DIR" && module load "$MODULE_NAME"
  bash tests/make-case.sh "$case_dir" "$BOX" "$NSTEPS"
) || { echo "ERROR: could not generate the benchmark case"; exit 1; }
TPR="$case_dir/bench.tpr"

echo ""
echo "=== Running the matrix (nsteps=$NSTEPS, tpr=$TPR)"
for v in $VARIANTS; do
  echo ""
  echo "--- $v"
  # Each variant in its OWN process: `module load` state lives in environment
  # variables, so this is what stops a cray variant's PrgEnv from following the
  # spack variant into its runs.
  bash tests/bench-one.sh "$v" "$TPR" "$results" "$NSTEPS"
done

echo ""
echo "=== Results ($results)"
column -t -s $'\t' "$results" 2>/dev/null || cat "$results"

echo ""
echo "=== Best ns/day per variant x nodes (max over rank/thread ratios and repeats)"
awk -F'\t' 'NR>1 && $8 != "FAILED" {
    k = $1 "\t" $4
    if ($8+0 > best[k]) { best[k] = $8+0; geom[k] = $5 "x" $6 }
  }
  END {
    printf "%-12s %6s %12s %12s\n", "variant", "nodes", "ns/day", "ranks x omp"
    for (k in best) { split(k, a, "\t"); printf "%-12s %6s %12.2f %12s\n", a[1], a[2], best[k], geom[k] }
  }' "$results" | sort -k1,1 -k2,2n

echo ""
echo "BENCH_OK — $results"
