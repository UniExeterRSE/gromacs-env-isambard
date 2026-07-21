-- scripts/gromacs-env.lua — GROMACS environment modulefile logic (Lmod / Lua).
--
-- This is the AUDITABLE half of activation. The generated per-variant modulefile
-- ($BASE/modulefiles/gromacs-env/<version>/<variant>.lua, written by
-- gen-modulefile.sh) only defines a flat table of per-build paths, then runs
-- THIS file with it:
--     assert(loadfile(".../modulefiles/gromacs-env.lua"))(data)
-- So everything below is static and version-controlled; only the path data
-- changes per build. (Lmod's sandbox forbids dofile() and reading undeclared
-- globals, so we pass the data as an argument and read it via `...`.)
--
-- Self-contained (setenv / prepend_path) — with ONE exception this file cannot
-- express: the cray variant needs `load()`/`try_load()` for PrgEnv-gnu, the
-- craype target and cray-fftw, so that `module load gromacs-env/...` alone is
-- enough to RUN gmx_mpi. Lmod resolves module hierarchy (MODULEPATH changes
-- from loading a compiler family) by statically scanning the TOP-LEVEL
-- modulefile source for `load(...)` calls — a `load()` reached only via this
-- file's `loadfile()` is invisible to that scan and silently does nothing. So
-- those Cray module loads are emitted directly into the generated per-build
-- modulefile by gen-modulefile.sh, BEFORE it calls into this file; this file
-- only consumes their effect.

local d = ...   -- per-build data table passed by the generated modulefile

-- There is no Spack view (see the `view: false` comment in the stack manifests):
-- the two GROMACS specs cannot share one merged tree. So everything below is
-- composed from the two install prefixes directly. `prefixes` is in
-- front-to-back order; each prepend_path pushes to the front, so iterate in
-- reverse to end up with the MPI build first.
local prefixes = {}
if d.gromacs_mpi  then prefixes[#prefixes + 1] = d.gromacs_mpi  end
if d.gromacs_tmpi then prefixes[#prefixes + 1] = d.gromacs_tmpi end

whatis("Name: gromacs-env/" .. d.version .. "/" .. d.variant)
whatis("GROMACS " .. (d.gromacs_version or "?") .. " for Isambard 3 (Grace/aarch64), "
  .. d.variant .. " build")
help([[
GROMACS ]] .. (d.gromacs_version or "?") .. [[ built with Spack for Isambard 3.

Provides two binaries:
  gmx      thread-MPI build. Single-node runs, and every prep/analysis tool
           (grompp, editconf, energy, trjconv, ...). No MPI launcher needed.
  gmx_mpi  MPI build. Multi-node runs, launched with $GROMACS_MPI_LAUNCHER
           (]] .. (d.launcher or "srun") .. [[).

Variant ']] .. d.variant .. [[' = <mpi/fft stack>-<simd>:
  cray  = system cray-mpich + system cray-fftw   |  spack = mpich + fftw from source
  sve   = GMX_SIMD=ARM_SVE (128-bit)             |  neon  = GMX_SIMD=ARM_NEON_ASIMD
Run `gmx -version` for the definitive build configuration.

Loading another gromacs-env/* swaps this one out.
]])

-- --- Binaries, libraries, headers -------------------------------------------
-- Each binary is reached through its OWN install prefix. That matters beyond
-- tidiness: GROMACS locates its data directory (share/gromacs/top — force
-- fields, spc216.gro, ...) by resolving its argv[0] back to an install prefix,
-- so `gmx` and `gmx_mpi` must not be reached through a shared symlink farm that
-- would make that ambiguous.
--
-- The lib/include/cmake entries are NOT needed to simply run gmx — Spack has
-- RPATH'd every dependency it built into the binaries. They are here for
-- (a) the system externals (cray-mpich, cray-fftw, libfabric), which are not
-- RPATH'd and genuinely do need LD_LIBRARY_PATH, and (b) anyone compiling
-- against libgromacs.
for i = #prefixes, 1, -1 do
  local p = prefixes[i]
  prepend_path("PATH", p .. "/bin")
  prepend_path("LD_LIBRARY_PATH", p .. "/lib64")
  prepend_path("LD_LIBRARY_PATH", p .. "/lib")
  prepend_path("LIBRARY_PATH", p .. "/lib64")
  prepend_path("LIBRARY_PATH", p .. "/lib")
  prepend_path("CPATH", p .. "/include")
  prepend_path("PKG_CONFIG_PATH", p .. "/lib/pkgconfig")
  prepend_path("PKG_CONFIG_PATH", p .. "/lib64/pkgconfig")
  prepend_path("CMAKE_PREFIX_PATH", p)
  prepend_path("MANPATH", p .. "/share/man")
end

-- Cray MPI/FFT runtime lib dirs (cray variant only; empty for spack).
-- d.cray_libs is in final front-to-back order, so prepend in reverse to preserve
-- it (each prepend pushes to the front).
for i = #d.cray_libs, 1, -1 do
  prepend_path("LD_LIBRARY_PATH", d.cray_libs[i])
end

-- --- How to launch ----------------------------------------------------------
-- The two stacks need different Slurm PMI plugins: cray-mpich speaks Slurm's
-- default cray_shasta PMI, the from-source MPICH speaks PMIx. That
-- is a property of THIS build, so the module states it rather than making every
-- job script guess. tests/ and any user script should use it:
--     $GROMACS_MPI_LAUNCHER -n 48 gmx_mpi mdrun ...
setenv("GROMACS_MPI_LAUNCHER", d.launcher)

-- Identity, for scripts that want to label output by build (tests/benchmark.sh
-- keys its results on these) and for humans reading `env`.
setenv("GROMACS_ENV_VARIANT", d.variant)
setenv("GROMACS_ENV_VERSION", d.version)
setenv("GROMACS_ENV_STACK", d.stack)
setenv("GROMACS_ENV_SIMD", d.simd)
setenv("GROMACS_TMPI_PREFIX", d.gromacs_tmpi)
setenv("GROMACS_MPI_PREFIX", d.gromacs_mpi)
setenv("SPACK_ENV", d.spack_env)
