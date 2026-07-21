# gromacs-env-isambard

A reproducible Spack build of **GROMACS 2026.1** for the **Isambard 3**
supercomputer (NVIDIA Grace / Neoverse-V2, aarch64, no GPU). It turns a pinned
Spack into a ready-to-use environment you load with one `module` command — after
which `gmx` and `gmx_mpi` just work, with no Spack knowledge required.

You do **not** need to know Spack or [pixi](https://pixi.sh) to use this repo.
The steps below use plain `git`, `module` and `sbatch`. A pixi shortcut is
offered at the end for those who want it.

## What you actually get

Two binaries and one modulefile:

| Binary | Built with | Use it for |
|--------|-----------|------------|
| `gmx` | thread-MPI | everything on **one node**, and every prep/analysis tool (`grompp`, `editconf`, `energy`, `trjconv`, …). No MPI launcher, no `srun`. |
| `gmx_mpi` | real MPI | **multi-node** `mdrun`, launched with `$GROMACS_MPI_LAUNCHER` |

Both are installed because GROMACS built `+mpi` provides *only* `gmx_mpi`, and
paying MPI startup for `gmx editconf` is a poor trade. They are the same GROMACS
version and build configuration otherwise.

### Why a module, and not "just a binary"

The binaries are **dynamically linked**, and a fully static `gmx` is not
achievable on the `cray` variant — cray-mpich and libfabric ship as shared
objects only. Spack **RPATHs everything it built itself** into the binary, so
those dependencies resolve with no environment at all; the **system externals**
do not. Every build runs `ldd` with `LD_LIBRARY_PATH` stripped and records the
result in its own log (`gmx_report_linkage`), so this is measured, not asserted.
As built here:

| Variant | Unresolved without the module | Meaning |
|---|---|---|
| `cray-*` | `libfabric.so.1 => not found` | `gmx_mpi` **will not start** without the module's `LD_LIBRARY_PATH` |
| `spack-*` | *(none)* | the binaries are **fully self-contained via RPATH** — only `PATH` is needed |

So `module load` is the delivery mechanism, exactly as in the LFRic environment:
it is *required* on the `cray` variant and merely *convenient* on the `spack`
one. The modulefile carries absolute paths, so it keeps working even if this repo
moves or is deleted.

If you specifically need a relocatable, hand-it-to-someone binary, the `spack`
variant is already that — it is one system library short of static, and that one
(`libfabric`) it does not need at all.

## Variants

A variant is `<stack>-<simd>`. The two axes are independent and all variants
share one Spack install tree, so building the second and third is much cheaper
than the first.

| Axis | Value | Meaning |
|------|-------|---------|
| `GROMACS_STACK` | `cray` *(default)* | system **cray-mpich** + system **cray-fftw** (Grace-tuned HPE builds) |
| | `spack` | **mpich** + **fftw** built from source; portability / comparison |
| `GROMACS_SIMD` | `sve` *(default)* | `GMX_SIMD=ARM_SVE`, 128-bit (Grace's SVE vector length) |
| | `neon` | `GMX_SIMD=ARM_NEON_ASIMD`, the fixed-128-bit alternative |

The SIMD axis exists because it is a genuinely open question on this hardware:
Neoverse-V2 implements SVE2 and NEON on the *same* four 128-bit pipelines, so SVE
buys predication and gather/scatter but no extra width. `tests/benchmark.sbatch`
answers it for your system rather than guessing — see
[MAINTAINER.md](MAINTAINER.md#tuning) for the measured result.

## Prerequisites

- An Isambard 3 account, and the basics: a **login node** (where you clone and
  submit) versus a **compute node** (where the build runs, via `sbatch`).
- Nothing else. All sources are public; there are no private submodules.

---

## Build the environment (without pixi)

Run this from a **login node**. The submodule clone fetches Spack itself; the
heavy build runs on a compute node.

```bash
# 1. Clone the repo and fetch the vendored Spack.
git clone <repo-url> gromacs-env-isambard
cd gromacs-env-isambard
git submodule update --init --recursive --jobs 4

# 2. Build on a compute node, one variant at a time.
#    The config block at the top of scripts/build.sbatch sets WHERE things go.
sbatch scripts/build.sbatch                                    # cray-sve (default)
sbatch --export=ALL,GROMACS_STACK=spack scripts/build.sbatch   # spack-sve
sbatch --export=ALL,GROMACS_SIMD=neon scripts/build.sbatch     # cray-neon
```

Each job writes its log to `logs/build-<jobid>.out`; a successful run ends with
`BUILD_OK`. The first variant takes roughly 40–70 minutes from scratch; the
others are much faster because they reuse the shared install tree.

> **Build one at a time.** All variants install into the same Spack tree, and
> concurrent installs race on its database lock.

> **Why a compute node?** The login nodes cap user processes (`ulimit -u` 1900),
> which a full parallel build can exhaust. `sbatch` also gets you a node's worth
> of memory: `--mem-per-cpu=1600M` claims Grace's full per-core share
> (230400 MB / 144 cores), because Slurm's ~1 GiB/core default OOM-kills the
> heavier GROMACS C++ translation units.

Everything installs under a **versioned** prefix `$GROMACS_PREFIX/<version>`
(default base `$PROJECTDIR/$USER/opt/Linux-aarch64`, version read from the
repo's `VERSION` file), which is **outside the repo** — see
[Configuration](#configuration).

### Optional: pre-fetch the sources on the login node

To do the network I/O up front and make the compute-node build offline-safe:

```bash
bash scripts/fetch.sh                             # cray-sve
GROMACS_STACK=spack bash scripts/fetch.sh         # spack-sve
```

Needs a Python in [3.7, 3.12) — `module load cray-python/3.11.7`, or use pixi.

### Optional: check the solve without building

```bash
bash scripts/concretize.sh     # ~1 minute, login-node safe, ends CONCRETIZE_OK
```

---

## Use it

```bash
# Point at the base you built into (the default is shown):
export GROMACS_PREFIX="$PROJECTDIR/$USER/opt/$(uname -sm | tr ' ' -)"

module use "$GROMACS_PREFIX/modulefiles"
module avail gromacs-env                       # every built version x variant
module load gromacs-env/v2026.07.21/cray-sve   # or .../spack-sve, .../cray-neon

gmx -version          # the definitive record of how this build was configured
```

A bare `module load gromacs-env` resolves to the most-recently-built version's
`cray-sve`; `module load gromacs-env/<version>` to that version's `cray-sve`.

### Single node

`gmx` needs no launcher. GROMACS' own thread-MPI handles a whole Grace node:

```bash
gmx grompp -f md.mdp -c conf.gro -p topol.top -o run.tpr
gmx mdrun -s run.tpr -ntmpi 24 -ntomp 6 -pin on
```

### Multiple nodes

Use `gmx_mpi` under `$GROMACS_MPI_LAUNCHER`, which the module sets to whatever
this variant's MPI actually needs (`srun` for cray-mpich, `srun --mpi=pmi2` for
the from-source mpich). Do not hard-code `srun` — that is the one thing that
differs between the two stacks.

```bash
#SBATCH --nodes=2 --ntasks-per-node=24 --cpus-per-task=6
module load gromacs-env/v2026.07.21/cray-sve
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK

$GROMACS_MPI_LAUNCHER -c $SLURM_CPUS_PER_TASK --cpu-bind=cores \
    gmx_mpi mdrun -s run.tpr -ntomp $SLURM_CPUS_PER_TASK -pin on
```

**Ranks × threads.** A Grace node is 144 cores in 2 NUMA domains of 72. Keep
`ranks_per_node × OMP_NUM_THREADS == 144` and make the threads-per-rank a divisor
of 72 so no rank straddles a NUMA domain. `24 × 6` is a good default; the
benchmark measures `24×6`, `36×4` and `72×2` so you can pick from data. Let Slurm
bind (`-c $OMP --cpu-bind=cores`) and let GROMACS pin inside that mask
(`-pin on`) — using neither, or both without the mask, is the usual cause of a
mysteriously slow run.

---

## Test it

A self-contained acceptance test that submits to the compute nodes, exercises
MPI across **two** nodes and checks the physics. It needs no downloads: the
simulation is generated from data that ships inside GROMACS itself (a solvated
SPC/E water box, PME + LINCS, ~172k atoms).

```bash
sbatch tests/smoke.sbatch                                    # cray-sve
sbatch --export=ALL,GROMACS_STACK=spack tests/smoke.sbatch   # spack-sve
sbatch --export=ALL,GROMACS_SIMD=neon tests/smoke.sbatch     # cray-neon
```

2 nodes for well under 20 minutes. A successful run ends with `SMOKE_OK`. It
asserts, in order: the module puts both binaries on `PATH`; they report the SIMD
/ FFT / MPI they were *meant* to be built with (including `-msve-vector-bits=128`
for the SVE builds); `gmx` can find its bundled data; the
launcher really spreads ranks over two distinct hosts; `mdrun` really used all 48
ranks; and the potential energy agrees with a single-rank reference to better
than 1e-4 relative — i.e. the domain decomposition and interconnect are not
corrupting the result.

Then, to compare the variants on identical work:

```bash
sbatch tests/benchmark.sbatch     # 2 exclusive nodes, < 40 min, ends BENCH_OK
```

Results are written to `logs/bench-<jobid>.tsv` and summarised at the end of the
job log. See [MAINTAINER.md](MAINTAINER.md#tuning) for what the numbers said.

---

## Using pixi instead (optional)

[pixi](https://pixi.sh) is **only a convenience for the build**: it supplies the
Python that runs Spack and gives you task shortcuts, and it auto-loads the built
module on every `pixi run`. Nothing here is required.

```bash
pixi run submodule-init      # = the git submodule update above
pixi run concretize          # = scripts/concretize.sh (cray-sve)
pixi run fetch               # = scripts/fetch.sh — pre-fetch on a login node
pixi run build               # = scripts/build.sh — run on a compute node
pixi run build-spack         # = the spack-sve variant
pixi run build-neon          # = the cray-neon variant
pixi run versions            # report the built configuration (gmx -version)
pixi run smoke               # = sbatch tests/smoke.sbatch
pixi run benchmark           # = sbatch tests/benchmark.sbatch
```

The heavy build still needs a compute node: either submit `scripts/build.sbatch`
(its last lines show how to switch it to `exec pixi run build`), or use
`pixi run concretize` for a quick login-node check first.

---

## Configuration

The build is configured entirely through environment variables. The sbatch
scripts set them explicitly in a config block at the top.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `GROMACS_STACK` | `cray` | MPI + FFT provider: `cray` or `spack`. |
| `GROMACS_SIMD` | `sve` | SIMD kernel: `sve` or `neon`. |
| `GROMACS_ENV_VERSION` | contents of `./VERSION` | **Environment version** (CalVer). Selects the install prefix `$GROMACS_PREFIX/<version>` and the module name. Bump it with `bash scripts/bump-env-version.sh`. Distinct from the GROMACS version, which is pinned in `spack-env/common.yaml`. |
| `GROMACS_PREFIX` | `$PROJECTDIR/$USER/opt/<arch>` | **Base** install location, shared across versions. The install goes to `$GROMACS_PREFIX/$GROMACS_ENV_VERSION`; the modulefiles tree and download caches sit at the base and are version-independent. Outside the repo. |
| `GROMACS_WORKING_DIR` | `$PREFIX/stage` | **Transient** Spack build scratch. The sbatch points this at node-local NVMe (`$LOCALDIR/…`) to keep the build off shared Lustre. Safe to delete anytime. |
| `SPACK_JOBS` | `$SLURM_CPUS_PER_TASK` | Parallel build jobs. |
| `FETCH_JOBS` | `4` | Concurrency cap for the login-node pre-fetch. |
| `GROMACS_BENCH_*` | see `tests/benchmark.sbatch` | Benchmark matrix: `VARIANTS`, `NSTEPS`, `BOX`, `REPEATS`, `GEOMETRIES`. |

To publish a rebuilt environment without disturbing one already in use:
`bash scripts/bump-env-version.sh`, commit `VERSION`, rebuild — the new build
lands in a fresh prefix and appears alongside the old one in `module avail`.

## Cleaning up

There is no clean task — removal is a plain `rm`:

```bash
rm -rf "$GROMACS_PREFIX/$(cat VERSION)"   # just this version
rm -rf "$GROMACS_PREFIX"                  # ALL versions + modulefiles + caches
```

## Troubleshooting

- **`fork: Resource temporarily unavailable` during a build.** You are building
  on a login node — submit `scripts/build.sbatch` instead.
- **`gmx_mpi: error while loading shared libraries: libfabric.so.1`.** The module
  is not loaded (or you are on the `cray` variant in a shell that unloaded
  PrgEnv-gnu). These system libraries are not RPATH'd; see
  [Why a module](#why-a-module-and-not-just-a-binary).
- **A multi-node run behaves like N independent 1-rank runs.** Wrong PMI plugin.
  Use `$GROMACS_MPI_LAUNCHER`, not a hard-coded `srun`. `tests/smoke.sbatch`
  checks for exactly this.
- **`There is no domain decomposition for N ranks`.** Too many ranks for the
  system size. Use fewer ranks and more OpenMP threads per rank.
- **A run is inexplicably ~2x slow.** Almost always thread pinning. Check
  `md.log` for GROMACS' own affinity warnings, and see the ranks × threads note
  above.

## More documentation

- [`MAINTAINER.md`](MAINTAINER.md) — how it works inside, every toggle and why,
  the benchmark results, and how to maintain it.
- [`tests/README.md`](tests/README.md) — what the tests check and what they cost.
