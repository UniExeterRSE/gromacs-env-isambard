# MAINTAINER.md — how this repo works, and how to keep it working

Orientation for whoever maintains the environment. [README.md](README.md) is for
people who just want `gmx`.

## The shape of it

```
VERSION                    the ENVIRONMENT version (CalVer). Selects the install
                           prefix and the module name. Not the GROMACS version.
spack-env/
  common.yaml              everything identical across variants: repos, the gcc
                           external, the CPU target pin, the GROMACS toggles
  cray/spack.yaml          stack: cray-mpich + cray-fftw as externals
  spack/spack.yaml         stack: mpich + fftw from source
scripts/
  common.sh                env only. Sourced everywhere, including by pixi on
                           every `pixi run`, so it stays side-effect-light.
  lib.sh                   the build PHASES as functions. All the logic is here.
  build.sh / concretize.sh / fetch.sh    thin drivers that compose those phases
  build.sbatch             the compute-node wrapper + the config block
  gen-modulefile.sh        resolves per-build paths -> a flat Lua data table
  gromacs-env.lua          the modulefile LOGIC (version-controlled, audited)
tests/                     see tests/README.md
vendor/spack               pinned Spack (submodule)
vendor/spack-packages      pinned package repo (submodule)
```

Two ideas carry most of the weight:

**The repo is not part of the deliverable.** Everything installs under
`$GROMACS_PREFIX/<version>` outside the repo, and the generated modulefile
contains only absolute paths into that prefix (including a *snapshot* of
`gromacs-env.lua`, copied to `$BASE/modulefiles/`). Delete or move the repo and
`module load` still works.

**Phases, not a script.** `lib.sh` defines `gmx_prepare`, `gmx_concretize`,
`gmx_install`, `gmx_verify_build`, … and the three drivers compose them. That is
why `concretize.sh` exists as a cheap, login-node-safe solve check running
*exactly* the solve the build will run, rather than an approximation of it.

## Variants: two axes, one install tree

`VARIANT = $GROMACS_STACK-$GROMACS_SIMD` — `cray|spack` × `sve|neon`. All four
combinations share `$PREFIX/opt`, so the MPI/FFT-independent subtree (cmake,
openblas, hwloc, perl, …) is built once.

The **stack** axis is a whole manifest (`spack-env/<stack>/spack.yaml`). The
**SIMD** axis is not: it is a two-line config scope,
`$SPACK_ENV_DIR/simd.yaml`, generated per build by `gmx_write_simd_config` and
included by both manifests. That asymmetry is deliberate — the SIMD choice is one
Spack variant, and duplicating a whole manifest for it would be four files to
keep in sync instead of two.

**There is no custom Spack package**, and that was a real decision. The obvious
approach — subclass or vendor the builtin `gromacs` package to force
`-DGMX_SIMD` and `-DGMX_SIMD_ARM_SVE_LENGTH` — turns out to be unnecessary:

- The builtin package already has an `sve` variant whose `cmake_args` maps
  `+sve → GMX_SIMD=ARM_SVE` and `~sve → GMX_SIMD=ARM_NEON_ASIMD` on aarch64.
- The SVE *length* is not a Spack variant at all. GROMACS' CMake reads
  `/proc/sys/abi/sve_default_vector_length` and bakes `-msve-vector-bits=<n>` in
  at configure time. On Isambard 3 that file reads `16` (bytes) — 128 bits — and
  login and compute nodes are the same Grace hardware, so the autodetect is right
  wherever the build runs.

Rather than patch the package to hard-code what it already gets right,
`gmx_verify_build` **asserts** the outcome from `gmx -version`. That is a
strictly better guarantee: it checks the binary that actually exists, not the
intent. If you ever cross-compile for different hardware, that assertion is what
will tell you, and *then* is the time to pass an explicit length.

## Tuning: every toggle, and why

`gmx -version` is the ground truth for all of this. Run it.

### Turned on

| Toggle | Setting | Why |
|---|---|---|
| CPU target | `target=neoverse_v2` (`common.yaml`, `packages: all`) | The `-march=native`/`-mtune=native` equivalent. Spack's compiler wrapper turns it into `-mcpu=neoverse-v2`. Pinned rather than left native so the solve is identical wherever it runs. Asserted post-build. |
| SIMD | `+sve` → `GMX_SIMD=ARM_SVE`, 128-bit | See the SIMD note below. |
| `+openmp` | on | Essential on a 144-core node: GROMACS wants a handful of OpenMP threads per rank, not one rank per core. |
| `+hwloc` | on | Topology-aware pinning. Matters here — 2 NUMA domains per node, and GROMACS pins by default. |
| `build_type` | `Release` | `-O3 -DNDEBUG`. |
| `~double` | mixed precision | The standard GROMACS configuration and roughly 2× the throughput of `+double`. Add a `gromacs +double` spec if a project genuinely needs it. |
| `+shared` | on | A fully static `gmx` is unachievable anyway — cray-mpich and libfabric are shared-only. |
| FFT | `fftw3` (cray-fftw or from-source fftw) | GROMACS' PME goes through the single-precision FFTW3 API. MKL is x86-only; ARMPL is not installed on this system. |
| BLAS/LAPACK | `openblas threads=none`, **the same in both stacks** | Only analysis tools (normal modes, covariance) touch it; `mdrun`'s inner loops never do. Identical in both stacks on purpose, so the cray-vs-spack benchmark isolates exactly two things: MPI and FFT. `threads=none` because a threaded BLAS under GROMACS' own pinned threads oversubscribes. |

### Turned off

`~cuda ~opencl ~sycl` (the grace nodes have no GPU), `~cp2k` (would drag in a
whole CP2K build). **`~plumed` is deliberately *not* listed**: GROMACS 2026.1 has
no `plumed` variant at all, so requiring `~plumed` makes the solve fail with
"cannot satisfy a requirement for package 'gromacs'". If you pin an older GROMACS
that does have it, add it back.

### The SIMD question

Neoverse-V2 implements SVE2 and NEON on the *same* four 128-bit pipelines, so
unlike a 256-bit SVE machine (Neoverse-V1) SVE buys predication and
gather/scatter but **no extra width**. Which wins for GROMACS' non-bonded kernels
is therefore an empirical question on this hardware, not a foregone conclusion —
which is why `neon` is a first-class variant and `tests/benchmark.sbatch`
measures it rather than this document asserting it.

**Measured answer: NEON wins, clearly.** `tests/benchmark.sbatch`, ~170k-atom
SPC/E water, PME, `-notunepme`, best of 2 repeats, ns/day:

| variant | 1 node, 24×6 | 1 node, 36×4 | 1 node, 72×2 | 2 nodes, 48×6 | 2 nodes, 72×4 | 2 nodes, 144×2 |
|---|---|---|---|---|---|---|
| **cray-neon** | 105.6 | **106.1** | 104.1 | 150.4 | 149.9 | **181.7** |
| cray-sve  | 90.6 | 90.9 | 89.2 | 147.2 | 147.9 | 161.6 |
| spack-sve | 90.1 | 90.5 | 89.4 | 137.5 | 132.6 | 161.1 |

NEON is **+17% on one node** and **+12% on two** over the identical build with
SVE, at every geometry, with repeat-to-repeat spread under 0.5%. That is why
`GROMACS_SIMD` defaults to `neon` here — **inverting the Spack package's own
`+sve` default**, deliberately and on evidence.

The result is not surprising once stated: Grace implements SVE2 and NEON on the
*same* four 128-bit pipelines, so SVE brings predication and gather/scatter but
no extra width, and GROMACS' non-bonded kernels are hand-tuned fixed-width code
that gains nothing from predication while paying for it. On a 256-bit SVE machine
(Neoverse-V1) the answer would very likely flip — which is exactly why this is a
variant and a benchmark rather than a hard-coded choice.

**cray vs spack is a tie at the optimum, and a cray win everywhere else.** At the
best geometry (2 nodes, 144×2) the two stacks are within 0.4% — a from-source
MPICH on the CXI provider matches cray-mpich when the decomposition suits it. But
at 48×6 and 72×4 on two nodes, cray-mpich leads by 7% and 12%, and on one node
they are identical (0.4%). So the difference is entirely in **multi-node
communication**, which is what you would expect, and cray-mpich is the more
forgiving choice when the geometry is not optimal. `cray` stays the default
stack; `spack` is a genuinely usable fallback, not a toy.

**Ranks × threads matters more than either.** Going from 48×6 to 144×2 on two
nodes is worth +21% on cray-neon — larger than the SIMD choice and much larger
than the MPI choice. Note the ordering *inverts* between one node (more OpenMP
slightly better) and two (many more ranks clearly better), so single-node tuning
does not transfer. See the README section on this.

**On reading that table.** The three benchmarked variants are a deliberate
two-factor design, not an arbitrary set: each comparison holds the other factor
fixed.

- `cray-neon` vs `cray-sve` — isolates **SIMD** (same MPI, same FFT).
- `cray-sve` vs `spack-sve` — isolates **MPI + FFT** (same SIMD).

That is why the default benchmark set is those three and not all four
combinations: a fourth (`spack-neon`) adds a redundant cell and pushes the matrix
past the job's time budget. `spack-neon` *is* built and tested — it is what
`GROMACS_STACK=spack` now produces — it is simply not needed to answer either
question. Add it with `GROMACS_BENCH_VARIANTS` if you want the full grid.

To re-measure after any change: `sbatch tests/benchmark.sbatch` (2 exclusive
nodes, ~50 min).

### The rank × thread question

Not a build toggle, but the biggest runtime knob, so the benchmark measures it
too: `24×6`, `36×4`, `72×2` ranks×threads per node. All keep
`ranks_per_node × OMP == 144` and use a threads-per-rank that divides 72, so no
rank straddles a NUMA domain. See README "Multiple nodes".

## Two Spack traps this repo works around

Both cost real build time to discover; neither is obvious from the outside.

**1. `spack concretize --fresh` ignores `packages:` changes.** It re-solves when
the manifest's `specs:` change, but a change to the *configuration* — a new
external, a different prefix, a dropped `modules:` key — is reported as
`No new specs to concretize` and the stale lock is reused. The build then runs
against configuration nobody wrote. So `gmx_concretize` hashes the three files
that actually define the solve (`spack.yaml`, `simd.yaml`, `common.yaml`), stores
the hash next to the lock, and forces `-f --fresh` whenever it moves. If you edit
a manifest and the solve looks suspiciously unchanged, that guard is what should
have caught it — check `$SPACK_ENV_DIR/.config-hash`.

**2. `modules:` on an external can break the install.** Spack honours it by
running `module load` in its *own* build subshell, which does not inherit the
job's `MODULEPATH`. For a site module tree — `/tools/brics` here — that fails the
install outright with `Module 'brics/cray-fftw/3.3.10.7' could not be loaded`.
None of the externals in this repo carry a `modules:` key: the `prefix:` is all
Spack needs to put the right `-I`/`-L` on the compiler wrapper, and `lib.sh`
loads the module in the *build shell* separately, which is where
`CRAY_LD_LIBRARY_PATH` needs to exist for `gen-modulefile.sh`.

## The two stacks

| | `cray` (default) | `spack` |
|---|---|---|
| MPI | system **cray-mpich** 9.1.0 (external) | **mpich** from source, `device=ch4 netmod=ofi pmi=pmi2 +slurm` |
| FFT | system **cray-fftw** 3.3.10.7, `arm_grace` build (external) | **fftw** 3.3.10 from source |
| Launcher | `srun` (Slurm `MpiDefault=cray_shasta`) | `srun --mpi=pmi2` |

The `spack` stack still declares **two** system externals, and neither is a
shortcut:

- **libfabric** — the Slingshot **CXI** provider is closed-source HPE hardware
  support that does not exist in a from-source libfabric. Without it a
  from-source MPICH cannot use the interconnect at all, and the multi-node half
  of the comparison would be meaningless.
- **slurm** — MPICH's hydra links `libslurm` for nodelist parsing and needs
  Slurm's `pmi2.h`. Building a second Slurm from source would not match the
  running one.

Everything genuinely comparable — the MPI implementation, the FFT library — is
from source.

The launcher difference is the one thing a user could get wrong, so the module
states it rather than making job scripts guess: `$GROMACS_MPI_LAUNCHER`. Nothing
in `tests/` hard-codes `srun`.

`gmx_assert_variant` runs after every concretize and fails the build if the wrong
MPI or FFT entered the solve. That guard is what stops a leaking `PrgEnv` from
quietly turning the `spack` stack into a second `cray` stack and invalidating
every number the benchmark produces. Keep it.

## The modulefile

Split in two, for the same reason as the LFRic environment:

- `scripts/gromacs-env.lua` — the **logic**, version-controlled and reviewable.
- `scripts/gen-modulefile.sh` — resolves this build's paths and emits a flat Lua
  **data** table plus `assert(loadfile(<snapshot>))(data)`.

(Lmod's sandbox forbids `dofile()` but allows `loadfile()` with an argument.)

Two things must stay as they are:

1. **The Cray `load()` calls are emitted at the top level** of the generated
   modulefile, not inside `gromacs-env.lua`. Lmod resolves module hierarchy by
   *statically scanning the top-level modulefile source* for `load(...)`, so a
   `load()` reachable only through `loadfile()` is invisible to that scan and
   silently does nothing.
2. **The per-spec install prefixes go on `PATH` ahead of the view.** Both GROMACS
   builds land in one view, but GROMACS finds its own `share/gromacs/top` by
   resolving `argv[0]` back to an install prefix. Invoking each binary through
   its real prefix keeps that unambiguous. `tests/smoke.sh` check 3 is the
   regression test for this.

`gen-modulefile.sh` is runnable standalone, so a modulefile fix does not need a
rebuild — but for the `cray` variant, run it with the Cray PE modules loaded so
`CRAY_LD_LIBRARY_PATH` is populated.

## Routine maintenance

**Bump GROMACS.** Edit the `@2026.1` pin in `spack-env/common.yaml`, then
`bash scripts/bump-env-version.sh && bash scripts/concretize.sh`. Check the
`plumed` note above if you move backwards. Rebuild all variants and re-run
`tests/smoke.sbatch` for each.

**Bump Spack.** Move the `vendor/spack` / `vendor/spack-packages` submodules,
`bash scripts/concretize.sh` for both stacks, and read the diff in the
concretized specs before building. `spack-packages` is where the `gromacs`
package lives, so its content is a real input to this environment.

**Bump the Cray PE.** The version constants appear in exactly two places and
**must agree**: the `externals:` prefixes in `spack-env/cray/spack.yaml` and the
`*_MODULE` variables at the top of `scripts/lib.sh` (mirrored in
`gen-modulefile.sh`). `gmx_assert_variant` catches a mismatch at concretize time
rather than at link time.

**Publish a rebuild without disturbing users.** `bash scripts/bump-env-version.sh`,
commit `VERSION`, rebuild. The new build lands in a fresh
`$GROMACS_PREFIX/<version>` and appears alongside the old one in
`module avail gromacs-env`.

## Notes on the build job

`scripts/build.sbatch` requests `--cpus-per-task=32 --mem-per-cpu=1600M`. The
memory figure is not arbitrary: `grace` allocates memory pro-rata
(230400 MB / 144 cores = 1600 MB/core), so this claims a node's full per-core
share and scales with `--cpus-per-task`. Slurm's ~1 GiB/core default OOM-kills
`cc1plus` on GROMACS' heavier C++ translation units. A small, short,
non-exclusive job also backfills sooner than an exclusive one.

`GROMACS_WORKING_DIR` points at node-local NVMe (`$LOCALDIR`). Spack's build
stage is metadata-heavy; keeping it off shared Lustre is worth a noticeable
chunk of the build time.

Build variants **one at a time** — concurrent Spack installs into the shared tree
race on its database lock.
