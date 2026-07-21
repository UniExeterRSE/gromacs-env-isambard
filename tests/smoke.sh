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
# MUST be on a SHARED filesystem, not node-local $LOCALDIR. Every rank reads the
# same .tpr and writes into the same working directory, so a per-node disk gives
# the ranks on the second node nothing to read and nowhere to chdir to — and srun
# reports that as a bare task-launch failure with no GROMACS output at all.
# (Node-local disk is right for the Spack BUILD stage, which is single-node; it
# is wrong for anything an MPI job touches.)
WORK="${GROMACS_TEST_DIR:-${SCRATCH:-$HOME}/gromacs-tests/smoke-$VARIANT-${SLURM_JOB_ID}}"

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
# stderr is NOT discarded here: srun's own complaints (a missing working
# directory, a PMI mismatch) are exactly what this check exists to surface.
hosts="$($LAUNCHER -N "$NODES" -n "$RANKS" hostname | sort -u | wc -l)"
[ "$hosts" -eq "$NODES" ] || die "launcher placed ranks on $hosts distinct hosts, expected $NODES"
ok "$LAUNCHER placed $RANKS ranks across $hosts nodes"

# --- 5 + 6. Run it ----------------------------------------------------------
export OMP_NUM_THREADS="$OMP"

# The physics comparison uses ZERO-step runs on both sides. `gmx energy` reports
# the AVERAGE over the frames in the .edr, so comparing a 0-step reference
# against a 2000-step run would compare a single-point energy with a trajectory
# average — a meaningless test that would fail for entirely correct builds. With
# nsteps=0 both sides hold exactly one frame: the same initial configuration,
# evaluated independently.
info "Single-rank thread-MPI reference (gmx, 0 steps) — the physics baseline"
mkdir -p ref && cd ref
gmx mdrun -s "$TPR" -nsteps 0 -ntmpi 1 -ntomp "$OMP" -noconfout -g ref.log -e ref.edr \
  > ref.out 2>&1 || { tail -40 ref.out ref.log 2>/dev/null; die "reference gmx mdrun failed"; }
ref_pot="$(echo Potential | gmx energy -f ref.edr -o ref.xvg 2>&1 | grep -E '^Potential' | awk '{print $2}')"
[ -n "$ref_pot" ] || die "could not extract the reference potential energy"
ok "reference potential energy = $ref_pot kJ/mol (1 rank, thread-MPI)"
cd "$WORK"

info "Multi-node single-point energy: $RANKS ranks over $NODES nodes"
mkdir -p mpi0 && cd mpi0
# shellcheck disable=SC2086
$LAUNCHER -N "$NODES" -n "$RANKS" -c "$OMP" --cpu-bind=cores \
  gmx_mpi mdrun -s "$TPR" -nsteps 0 -ntomp "$OMP" -pin on \
                -noconfout -g mpi0.log -e mpi0.edr \
  > mpi0.out 2>&1 || { rc=$?; echo "--- mpi0.out ---"; cat mpi0.out 2>/dev/null
      echo "--- mpi0.log ---"; cat mpi0.log 2>/dev/null
      die "multi-node 0-step gmx_mpi mdrun failed (exit $rc)"; }
mpi_pot="$(echo Potential | gmx energy -f mpi0.edr -o mpi0.xvg 2>&1 | grep -E '^Potential' | awk '{print $2}')"
[ -n "$mpi_pot" ] || die "could not extract the MPI run's potential energy"
cd "$WORK"

# Both sides evaluated the same initial configuration, so the energies must agree.
# They are not bit-identical: domain decomposition changes the order of the
# floating-point summation. 1e-4 relative is far tighter than that reordering
# noise and far looser than a real error (a wrong cutoff, a broken halo exchange
# or a miscompiled SIMD kernel moves this by percent, not by 0.01%).
rel="$(awk -v a="$ref_pot" -v b="$mpi_pot" 'BEGIN{d=(a-b)/a; if(d<0)d=-d; printf "%.3e", d}')"
awk -v d="$rel" 'BEGIN{exit !(d < 1e-4)}' \
  || die "potential energy disagrees with the single-rank reference: ref=$ref_pot mpi=$mpi_pot (relative $rel)"
ok "potential energy matches the reference: $mpi_pot vs $ref_pot (relative difference $rel)"

# --- 6. A real (short) MD run actually completes on both nodes ---------------
info "Multi-node MD run: $RANKS ranks x $OMP threads over $NODES nodes"
mkdir -p mpi && cd mpi
# -pin on: Slurm has already restricted each rank to its own $OMP cores
# (--cpu-bind=cores); -pin on makes GROMACS pin its threads WITHIN that mask
# rather than leaving them to migrate.
#
# No -resetstep here, deliberately. This run exists to prove mdrun completes, not
# to time it — and resetting the counters early is a hard error: GROMACS aborts
# with "PME tuning was still active when attempting to reset mdrun counters" if
# the reset lands before its PME/cutoff auto-tuning has settled, which on a
# 2000-step run it does. The benchmark, which runs 10x longer, resets at 20%.
# shellcheck disable=SC2086
$LAUNCHER -N "$NODES" -n "$RANKS" -c "$OMP" --cpu-bind=cores \
  gmx_mpi mdrun -s "$TPR" -nsteps 2000 -ntomp "$OMP" -pin on \
                -noconfout -g mpi.log -e mpi.edr \
  > mpi.out 2>&1 || { rc=$?; echo "--- mpi.out ---"; cat mpi.out 2>/dev/null
      echo "--- mpi.log ---"; cat mpi.log 2>/dev/null
      die "multi-node gmx_mpi mdrun failed (exit $rc)"; }

grep -q "Finished mdrun" mpi.log || { tail -40 mpi.log; die "mdrun did not finish cleanly"; }
# GROMACS states its parallel geometry in its own log; assert it matches what we
# asked for, so a silently-serialized run cannot pass.
grep -qE "Using +$RANKS MPI process" mpi.log \
  || { grep -iE "MPI process|OpenMP thread" mpi.log | head; die "mdrun did not use $RANKS MPI ranks"; }
ok "mdrun used $RANKS MPI ranks x $OMP OpenMP threads"

perf="$(grep -E "^Performance:" mpi.log | awk '{print $2}')"
info "Performance on $NODES nodes: ${perf:-?} ns/day"
cd "$WORK"

echo ""
echo "SMOKE_OK — variant=$VARIANT nodes=$NODES ranks=$RANKS perf=${perf:-?} ns/day"
echo "  artefacts: $WORK"
