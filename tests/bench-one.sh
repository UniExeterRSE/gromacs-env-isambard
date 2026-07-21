#!/usr/bin/env bash
# bench-one.sh — time one built variant across a few rank/thread geometries and
# append the results to a TSV.
#
# Deliberately a SEPARATE process from the driver (tests/benchmark.sbatch): it
# `module load`s a variant, and Lmod's state lives in environment variables, so
# running each variant in its own process is what keeps a cray build's PrgEnv
# from leaking into the next variant's run. Nothing is unloaded; the process just
# exits.
#
# Usage (inside a Slurm allocation):
#   bash tests/bench-one.sh <variant> <tpr> <results.tsv> [nsteps]
#     variant     e.g. cray-sve  (must be <stack>-<simd>)
set -uo pipefail

variant="${1:?usage: bench-one.sh <variant> <tpr> <results.tsv> [nsteps]}"
tpr="${2:?missing tpr}"
results="${3:?missing results file}"
nsteps="${4:-20000}"

export GROMACS_STACK="${variant%-*}"
export GROMACS_SIMD="${variant##*-}"

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/../scripts/common.sh"

info() { echo "INFO: [$variant] $*"; }
warn() { echo "WARN: [$variant] $*" >&2; }

if ! command -v module >/dev/null 2>&1; then
  for f in /opt/cray/pe/lmod/lmod/init/bash /etc/profile.d/lmod.sh /usr/share/lmod/lmod/init/bash; do
    # shellcheck source=/dev/null
    [ -f "$f" ] && . "$f" && break
  done
fi
if [ ! -f "$MODULEFILE" ]; then
  warn "not built (no $MODULEFILE) — skipping"
  exit 0
fi
module use "$MODULEFILES_DIR"
module load "$MODULE_NAME" || { warn "module load failed — skipping"; exit 0; }
LAUNCHER="${GROMACS_MPI_LAUNCHER:-srun}"

fft="$(gmx_mpi -version 2>&1 | grep -m1 'FFT library:' | sed 's/.*: *//')"
simd="$(gmx_mpi -version 2>&1 | grep -m1 'SIMD instructions:' | sed 's/.*: *//')"
info "SIMD=$simd  FFT=$fft  launcher=$LAUNCHER"

MAXNODES="${SLURM_JOB_NUM_NODES:-1}"
work="${LOCALDIR:-/tmp}/gromacs-bench-$variant-${SLURM_JOB_ID:-$$}"
mkdir -p "$work"

# Geometries. 144 cores/node, so ranks_per_node * omp == 144 in every case.
# Two ratios, because "how many OpenMP threads per rank?" is the single biggest
# runtime knob a GROMACS user has on a many-core node, and the answer is
# machine-specific — this measures it here rather than repeating folklore.
#   24 x 6  : 6 threads/rank, 12 ranks per NUMA domain
#   36 x 4  : 4 threads/rank, more ranks, more DD communication, less OpenMP
#   72 x 2  : 2 threads/rank, close to flat MPI
GEOMETRIES="${GROMACS_BENCH_GEOMETRIES:-24:6 36:4 72:2}"
REPEATS="${GROMACS_BENCH_REPEATS:-2}"

for nodes in $(seq 1 "$MAXNODES"); do
  for geom in $GEOMETRIES; do
    rpn="${geom%%:*}"; omp="${geom##*:}"
    ranks=$((nodes * rpn))
    for rep in $(seq 1 "$REPEATS"); do
      d="$work/n${nodes}_r${rpn}_t${omp}_$rep"
      mkdir -p "$d"
      export OMP_NUM_THREADS="$omp"
      # shellcheck disable=SC2086
      (cd "$d" && $LAUNCHER -N "$nodes" -n "$ranks" -c "$omp" --cpu-bind=cores \
          gmx_mpi mdrun -s "$tpr" -nsteps "$nsteps" -resetstep $((nsteps / 5)) \
                        -ntomp "$omp" -pin on -noconfout -g md.log -e ener.edr \
          > run.out 2>&1)
      rc=$?
      perf="$(grep -E '^Performance:' "$d/md.log" 2>/dev/null | awk '{print $2}')"
      if [ $rc -ne 0 ] || [ -z "$perf" ]; then
        warn "nodes=$nodes ranks=$ranks omp=$omp rep=$rep FAILED (rc=$rc); see $d/run.out"
        perf="FAILED"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$variant" "$simd" "$fft" "$nodes" "$ranks" "$omp" "$rep" "$perf" >> "$results"
      info "nodes=$nodes ranks=$ranks omp=$omp rep=$rep -> ${perf} ns/day"
    done
  done
done
