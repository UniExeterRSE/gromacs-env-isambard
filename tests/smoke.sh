#!/usr/bin/env bash
# smoke.sh — verify one built variant end to end, inside a Slurm allocation.
#
# Normally reached via `sbatch tests/smoke.sbatch`; runnable directly inside an
# existing allocation (salloc) too. Everything it checks is something that has
# actually gone wrong in a Spack HPC build at some point:
#
#   1. the module loads and puts both binaries on PATH
#   2. the binaries report the SIMD / FFT / MPI they were MEANT to be built with
#      (a build that silently fell back to scalar SIMD still runs — just slowly)
#   3. gmx (thread-MPI) can find its own data files through the view
#   4. gmx_mpi's ranks really span TWO nodes and really see each other
#      (a broken PMI setup produces N independent 1-rank simulations, each of
#      which "succeeds")
#   5. the physics agrees with the single-rank reference — i.e. the domain
#      decomposition and the interconnect are not corrupting the result
#   6. mdrun completes and reports a performance number
#
# Ends with SMOKE_OK.
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/../scripts/common.sh"

info() { echo "INFO: $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "PASS: $*"; }

[ -n "${SLURM_JOB_ID:-}" ] || die "not inside a Slurm allocation — use: sbatch tests/smoke.sbatch"

NODES="${SLURM_JOB_NUM_NODES:-1}"
RANKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-24}"
OMP="${SLURM_CPUS_PER_TASK:-6}"
RANKS=$((NODES * RANKS_PER_NODE))
WORK="${GROMACS_TEST_DIR:-${LOCALDIR:-/tmp}/gromacs-smoke-$VARIANT-${SLURM_JOB_ID}}"

echo "=== GROMACS smoke test: variant=$VARIANT"
echo "    nodes=$NODES ranks=$RANKS ranks/node=$RANKS_PER_NODE omp=$OMP"
echo "    workdir=$WORK"
echo ""

# --- 1. The module ----------------------------------------------------------
if ! command -v module >/dev/null 2>&1; then
  for f in /opt/cray/pe/lmod/lmod/init/bash /etc/profile.d/lmod.sh /usr/share/lmod/lmod/init/bash; do
    # shellcheck source=/dev/null
    [ -f "$f" ] && . "$f" && break
  done
fi
[ -f "$MODULEFILE" ] || die "variant '$VARIANT' is not built (no modulefile at $MODULEFILE)"
module use "$MODULEFILES_DIR"
module load "$MODULE_NAME" || die "module load $MODULE_NAME failed"
command -v gmx     >/dev/null 2>&1 || die "gmx not on PATH after 'module load $MODULE_NAME'"
command -v gmx_mpi >/dev/null 2>&1 || die "gmx_mpi not on PATH after 'module load $MODULE_NAME'"
ok "module load $MODULE_NAME -> $(command -v gmx), $(command -v gmx_mpi)"

LAUNCHER="${GROMACS_MPI_LAUNCHER:?the modulefile did not export GROMACS_MPI_LAUNCHER}"
info "MPI launcher for this variant: $LAUNCHER"

# --- 2. Build configuration is what was asked for ---------------------------
case "$GROMACS_SIMD" in
  sve)  want_simd="ARM_SVE" ;;
  neon) want_simd="ARM_NEON_ASIMD" ;;
  *)    die "unexpected GROMACS_SIMD=$GROMACS_SIMD" ;;
esac
ver="$(gmx_mpi -version 2>&1)" || die "gmx_mpi -version failed"
echo "$ver" | grep -E "GROMACS version|Precision|SIMD instructions|FFT library|MPI library|C\+\+ compiler flags" | sed 's/^/    /'
echo "$ver" | grep -q "SIMD instructions:.*$want_simd" \
  || die "gmx_mpi reports the wrong SIMD (wanted $want_simd)"
ok "SIMD is $want_simd"
if [ "$GROMACS_SIMD" = sve ]; then
  echo "$ver" | grep -q -- "-msve-vector-bits=128" \
    || die "gmx_mpi was not compiled for 128-bit SVE (Grace's vector length)"
  ok "SVE vector length compiled in is 128 bits"
fi
# The FFT library must come from the stack we asked for, otherwise the
# cray-vs-spack comparison is measuring nothing.
fftline="$(echo "$ver" | grep 'FFT library:')"
info "$fftline"

# --- 3. gmx (thread-MPI) can find its bundled data --------------------------
mkdir -p "$WORK" || die "cannot create $WORK"
cd "$WORK" || die
bash "$_here/make-case.sh" "$WORK/case" 12.0 2000 > case.log 2>&1 \
  || { tail -30 case.log; die "make-case.sh failed (see $WORK/case.log) — usually gmx cannot find share/gromacs/top"; }
grep -q CASE_OK case.log || { tail -30 case.log; die "make-case.sh did not report CASE_OK"; }
ok "$(grep CASE_OK case.log)"
TPR="$WORK/case/bench.tpr"

# --- 4. The ranks really span two nodes -------------------------------------
# Checked separately from mdrun, because a PMI misconfiguration makes mdrun look
# like it worked: each rank silently becomes its own MPI_COMM_WORLD of size 1.
hosts="$($LAUNCHER -N "$NODES" -n "$RANKS" hostname 2>/dev/null | sort -u | wc -l)"
[ "$hosts" -eq "$NODES" ] || die "launcher placed ranks on $hosts distinct hosts, expected $NODES"
ok "$LAUNCHER placed $RANKS ranks across $hosts nodes"

# --- 5 + 6. Run it ----------------------------------------------------------
export OMP_NUM_THREADS="$OMP"

info "Single-rank thread-MPI reference (gmx, 0 steps) — the physics baseline"
mkdir -p ref && cd ref
gmx mdrun -s "$TPR" -nsteps 0 -ntmpi 1 -ntomp "$OMP" -noconfout -g ref.log -e ref.edr \
  > ref.out 2>&1 || { tail -40 ref.out ref.log 2>/dev/null; die "reference gmx mdrun failed"; }
ref_pot="$(echo Potential | gmx energy -f ref.edr -o ref.xvg 2>/dev/null | grep -E '^Potential' | awk '{print $2}')"
[ -n "$ref_pot" ] || die "could not extract the reference potential energy"
ok "reference potential energy = $ref_pot kJ/mol (1 rank, thread-MPI)"
cd "$WORK"

info "Multi-node MPI run: $RANKS ranks x $OMP threads over $NODES nodes"
mkdir -p mpi && cd mpi
# -pin on: Slurm has already restricted each rank to its own $OMP cores
# (--cpu-bind=cores); -pin on makes GROMACS pin its threads WITHIN that mask
# rather than leaving them to migrate. -resetstep discards the startup and
# load-balancing warmup from the timing.
# shellcheck disable=SC2086
$LAUNCHER -N "$NODES" -n "$RANKS" -c "$OMP" --cpu-bind=cores \
  gmx_mpi mdrun -s "$TPR" -nsteps 2000 -resetstep 500 -ntomp "$OMP" -pin on \
                -noconfout -g mpi.log -e mpi.edr \
  > mpi.out 2>&1 || { tail -60 mpi.out mpi.log 2>/dev/null; die "multi-node gmx_mpi mdrun failed"; }

grep -q "Finished mdrun" mpi.log || { tail -40 mpi.log; die "mdrun did not finish cleanly"; }
# GROMACS states its parallel geometry in the log; assert it matches what we asked
# for, so a silently-serialized run cannot pass.
grep -qE "Using +$RANKS MPI process" mpi.log \
  || { grep -iE "MPI process|OpenMP thread" mpi.log | head; die "mdrun did not use $RANKS MPI ranks"; }
ok "mdrun used $RANKS MPI ranks x $OMP OpenMP threads"

mpi_pot="$(echo Potential | gmx energy -f mpi.edr -o mpi.xvg 2>/dev/null | grep -E '^Potential' | awk '{print $2}')"
[ -n "$mpi_pot" ] || die "could not extract the MPI run's potential energy"

# The two runs start from the same tpr, so their step-0 energies must agree.
# They are not bit-identical: domain decomposition changes the order of the
# floating-point summation. 1e-4 relative is far tighter than that reordering
# noise and far looser than a real error (a wrong cutoff, a broken halo exchange
# or a miscompiled SIMD kernel moves this by percent, not by 0.01%).
rel="$(awk -v a="$ref_pot" -v b="$mpi_pot" 'BEGIN{d=(a-b)/a; if(d<0)d=-d; printf "%.3e", d}')"
awk -v d="$rel" 'BEGIN{exit !(d < 1e-4)}' \
  || die "potential energy disagrees with the single-rank reference: ref=$ref_pot mpi=$mpi_pot (relative $rel)"
ok "potential energy matches the reference: $mpi_pot vs $ref_pot (relative difference $rel)"

perf="$(grep -E "^Performance:" mpi.log | awk '{print $2}')"
info "Performance on $NODES nodes: ${perf:-?} ns/day"

echo ""
echo "SMOKE_OK — variant=$VARIANT nodes=$NODES ranks=$RANKS perf=${perf:-?} ns/day"
echo "  artefacts: $WORK"
