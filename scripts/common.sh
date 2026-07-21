#!/usr/bin/env bash
# Common environment for the build/task scripts. SOURCE this file; do not run it.
#
# Sets up the build context (vendored Spack, install PREFIX, selected variant)
# and puts the generated modulefiles on MODULEPATH so the built environment can
# be `module load`ed. Does NOT require pixi: pixi sources it via its activation
# hook, and `bash scripts/build.sh` (no pixi) sources it the same.
#
# Kept side-effect-light (only env vars + PATH) because it is sourced on every
# `pixi run`. Anything heavy (module loads, spack queries) lives in lib.sh.
# Deeper rationale lives in MAINTAINER.md.

# --- Repo root -------------------------------------------------------------
# pixi exports PIXI_PROJECT_ROOT; otherwise derive it from this file's path.
if [ -n "${PIXI_PROJECT_ROOT:-}" ]; then
  REPO_ROOT="$PIXI_PROJECT_ROOT"
else
  REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
fi
export REPO_ROOT

# --- Vendored Spack (vendor/spack submodule) -------------------------------
export SPACK_ROOT="$REPO_ROOT/vendor/spack"

# --- Env version (CalVer) --------------------------------------------------
# The environment is versioned by GROMACS_ENV_VERSION (CalVer, e.g. v2026.07.21),
# committed in the repo's ./VERSION file. This keeps independent builds in
# DISTINCT prefixes instead of silently overwriting a shared install. Bump it
# deliberately with scripts/bump-env-version.sh. NB: this is the ENVIRONMENT's
# version, distinct from the GROMACS version (pinned in spack-env/common.yaml).
if [ -z "${GROMACS_ENV_VERSION:-}" ]; then
  if [ -r "$REPO_ROOT/VERSION" ]; then
    GROMACS_ENV_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  fi
  GROMACS_ENV_VERSION="${GROMACS_ENV_VERSION:-unversioned}"
fi
# The version is embedded verbatim in install + modulefile paths. It is
# maintainer-controlled, but fail fast on a value that would escape or mangle
# those paths rather than create them silently.
case "$GROMACS_ENV_VERSION" in
  *[/\\]*|*..*|*[[:space:]]*)
    echo "ERROR: invalid GROMACS_ENV_VERSION '$GROMACS_ENV_VERSION' (no '/', '\\', '..' or whitespace — it forms install/module paths)" >&2
    return 1 2>/dev/null || exit 1 ;;
esac
export GROMACS_ENV_VERSION

# --- Build locations (the knobs that matter) -------------------------------
# BASE (GROMACS_PREFIX)  the per-arch container, SHARED across env versions.
#   Lives OUTSIDE the repo. Default $PROJECTDIR/$USER/opt/<sysname>-<machine>.
# PREFIX                 the VERSIONED install: $BASE/$GROMACS_ENV_VERSION. Holds
#   the Spack install tree (opt), the per-variant environment, and the
#   per-version Spack config. ALL variants share this one PREFIX/opt, so the
#   MPI/FFT-independent subtree is built once.
# WORKING_DIR (GROMACS_WORKING_DIR)  transient Spack build/compile stage ONLY. It
#   is metadata-heavy, so on a compute node point it at node-local NVMe — the
#   sbatch sets GROMACS_WORKING_DIR=$LOCALDIR/... to keep the build off the
#   shared (and often contended) Lustre. Defaults to $PREFIX/stage.
_arch_tag="$(uname -sm | tr ' ' -)"
export BASE="${GROMACS_PREFIX:-${PROJECTDIR:-${SCRATCH:-$HOME}}/$USER/opt/$_arch_tag}"
unset _arch_tag
export PREFIX="$BASE/$GROMACS_ENV_VERSION"
export WORKING_DIR="${GROMACS_WORKING_DIR:-$PREFIX/stage}"

# Redirect Spack's user config + cache under PREFIX (per-version) so the build is
# hermetic: it neither reads nor writes the user's global ~/.spack.
export SPACK_USER_CONFIG_PATH="${SPACK_USER_CONFIG_PATH:-$PREFIX/spack-config}"
export SPACK_USER_CACHE_PATH="${SPACK_USER_CACHE_PATH:-$PREFIX/spack-cache}"

# Download caches: SHARED at BASE and version-INDEPENDENT — Spack's source and
# misc caches are content-addressed, so a new env version reuses already-
# downloaded sources instead of re-fetching. lib.sh writes these into the
# per-version Spack config.
export GROMACS_SOURCE_CACHE="${GROMACS_SOURCE_CACHE:-$BASE/source-cache}"
export GROMACS_MISC_CACHE="${GROMACS_MISC_CACHE:-$BASE/misc-cache}"

# --- Build variant: <stack>-<simd> -----------------------------------------
# GROMACS_STACK  cray  - system cray-mpich + system cray-fftw (externals) [default]
#                spack - mpich + fftw built from source (portable fallback)
# GROMACS_SIMD   neon  - GMX_SIMD=ARM_NEON_ASIMD                             [default]
#                sve   - GMX_SIMD=ARM_SVE (128-bit on Grace)
# neon is the default because it MEASURED faster on this hardware: 12-17% ahead
# of SVE across every geometry benchmarked (see MAINTAINER.md "Tuning"). Grace
# implements SVE2 and NEON on the same four 128-bit pipelines, so SVE brings
# predication and gather/scatter but no extra width, and for GROMACS' non-bonded
# kernels that trade does not pay. Note this inverts the Spack package's own
# default (+sve).
# These are two orthogonal axes; together they name the variant, the Spack
# environment directory and the modulefile. All variants share $PREFIX/opt.
# lib.sh validates both values; kept default-only here to stay side-effect-light.
export GROMACS_STACK="${GROMACS_STACK:-cray}"
export GROMACS_SIMD="${GROMACS_SIMD:-neon}"
export VARIANT="$GROMACS_STACK-$GROMACS_SIMD"
# The Spack directory environment is GENERATED under PREFIX (so its lockfile
# lands outside the repo). The tracked spack-env/<stack>/spack.yaml is
# the TEMPLATE lib.sh instantiates from. See MAINTAINER.md.
export SPACK_ENV_TEMPLATE="$REPO_ROOT/spack-env/$GROMACS_STACK/spack.yaml"
export SPACK_ENV_DIR="$PREFIX/spack-env/$VARIANT"
export ENV_NAME="gromacs-isambard-$VARIANT"
# Lmod activation. MODULE_NAME is what you `module load`; MODULEFILE backs it and
# doubles as the "is this variant built?" sentinel. The modulefiles live in ONE
# shared, version-INDEPENDENT tree ($BASE/modulefiles) keyed by version + variant,
# so a single `module use $BASE/modulefiles` makes `module avail gromacs-env` list
# every built version x variant side by side.
export MODULEFILES_DIR="$BASE/modulefiles"
export MODULE_NAME="gromacs-env/$GROMACS_ENV_VERSION/$VARIANT"
export MODULEFILE="$MODULEFILES_DIR/gromacs-env/$GROMACS_ENV_VERSION/$VARIANT.lua"

# Make the vendored spack CLI available so `spack ...` / `pixi run spack ...` work.
case ":${PATH:-}:" in
  *":$SPACK_ROOT/bin:"*) : ;;
  *) export PATH="$SPACK_ROOT/bin${PATH:+:$PATH}" ;;
esac

# Put the generated modulefiles on MODULEPATH (idempotent) so `module load
# gromacs-env/...` resolves in any shell that sources this file. An end user with
# neither pixi nor this file just runs `module use $BASE/modulefiles` once.
case ":${MODULEPATH:-}:" in
  *":$MODULEFILES_DIR:"*) : ;;
  *) export MODULEPATH="$MODULEFILES_DIR${MODULEPATH:+:$MODULEPATH}" ;;
esac

# Spack 1.0 must run under Python < 3.12 (it uses ast.Str). Pin it to whatever
# python3 is on PATH now (pixi's 3.11, or a `module load`ed cray-python).
if [ -z "${SPACK_PYTHON:-}" ] && command -v python3 >/dev/null 2>&1; then
  SPACK_PYTHON="$(command -v python3)"; export SPACK_PYTHON
fi
