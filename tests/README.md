# tests/

Two Slurm jobs. Both are self-contained: the simulation they run is **generated
from data that ships inside GROMACS**, so nothing here downloads anything or
depends on a third-party host being reachable from a compute node.

| | What it answers | Cost |
|---|---|---|
| `smoke.sbatch` | *Does this build work, correctly, across two nodes?* | 2 nodes, < 20 min (the MD itself is ~1 min), non-exclusive |
| `benchmark.sbatch` | *Which variant is faster, and at what ranks × threads?* | 2 nodes exclusive, < 40 min |

```bash
# from the repo root
sbatch tests/smoke.sbatch                                    # cray-sve (default)
sbatch --export=ALL,GROMACS_STACK=spack tests/smoke.sbatch   # spack-sve
sbatch --export=ALL,GROMACS_SIMD=neon  tests/smoke.sbatch    # cray-neon

sbatch tests/benchmark.sbatch                                # all built variants
```

`smoke` ends with `SMOKE_OK`, `benchmark` with `BENCH_OK`.

## The case (`make-case.sh`)

A cubic box of SPC/E water — 12 nm by default, ~57k molecules, ~172k atoms —
built by `gmx solvate` from `spc216.gro` and `oplsaa.ff/spce.itp`, both of which
live in every GROMACS install's `share/gromacs/top`. Run parameters: PME
(0.12 nm grid), Verlet cutoffs at 1.0 nm, h-bond constraints, 2 fs steps, fixed
random seeds.

Unremarkable physics, chosen because it exercises exactly the things this build
gets right or wrong:

- the **SIMD non-bonded kernels** — the SVE-vs-NEON question;
- the **FFT library** — cray-fftw vs from-source fftw, via PME;
- once on more than one node, the **MPI halo exchange and PME transposes**.

Trajectory output is off: writing frames would benchmark Lustre, not GROMACS.
The seeds are fixed so every build and every node count starts from bit-identical
initial conditions, which is what makes the cross-build energy comparison
meaningful.

## What `smoke.sh` actually asserts

In order, each one a failure mode that a real Spack HPC build has produced:

1. **The module works** — it loads and puts both `gmx` and `gmx_mpi` on `PATH`.
2. **The binary is what was ordered** — `gmx_mpi -version` reports the expected
   `SIMD instructions`, and for SVE builds the compiler flags contain
   `-msve-vector-bits=128`. A build that silently fell back to a narrower vector
   or to scalar SIMD *still runs*; it is just quietly slow, which is worse than a
   failed build.
3. **`gmx` finds its own data** — `make-case.sh` needs `share/gromacs/top`, which
   GROMACS locates by resolving its own `argv[0]`. This is the check that the
   modulefile's `PATH` ordering (real install prefixes ahead of the shared view)
   is right.
4. **The ranks really span two nodes** — checked *separately* from `mdrun`, with
   a bare `hostname`, because a wrong PMI plugin does not error: every rank
   silently becomes its own `MPI_COMM_WORLD` of size 1 and you get N independent
   simulations that all "succeed".
5. **`mdrun` used every rank** — asserted from `md.log`'s own statement of its
   parallel geometry.
6. **The physics is intact** — the potential energy from the 48-rank run agrees
   with a 1-rank thread-MPI reference to better than `1e-4` relative. Domain
   decomposition reorders the floating-point summation, so they are not
   bit-identical; but a wrong cutoff, a broken halo exchange or a miscompiled
   SIMD kernel moves this by percent, not by 0.01%.

## The benchmark matrix

`benchmark.sbatch` generates the case **once** and runs every built variant
against that same `.tpr`, so the only thing differing between rows is the build.
Each variant runs in its own process (`bench-one.sh`), because `module load`
state lives in environment variables — that is what stops a `cray` variant's
`PrgEnv-gnu` from following the `spack` variant into its runs.

Matrix: variants × {1, 2} nodes × {24×6, 36×4, 72×2} ranks×threads × 2 repeats.
Every geometry keeps `ranks_per_node × OMP_NUM_THREADS == 144` and makes the
threads-per-rank a divisor of 72, so no rank straddles a NUMA domain. The
rank/thread ratio is the biggest runtime knob a GROMACS user has on a 144-core
node, and the best value is machine-specific — measuring it beats repeating
folklore.

Timing uses `-resetstep` to discard startup and load-balancing warmup, and
`--exclusive` because a benchmark sharing its nodes measures the neighbours too.

Override the matrix with `GROMACS_BENCH_VARIANTS`, `GROMACS_BENCH_NSTEPS`,
`GROMACS_BENCH_BOX`, `GROMACS_BENCH_GEOMETRIES`, `GROMACS_BENCH_REPEATS`.

Results: `logs/bench-<jobid>.tsv`, plus a best-per-variant summary at the end of
the job log. The conclusions drawn from them are recorded in
[`../MAINTAINER.md`](../MAINTAINER.md#tuning).
