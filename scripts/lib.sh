#!/usr/bin/env bash
# lib.sh — the build phases as sourceable functions.
#
# SOURCE this (after common.sh); do not execute it. It defines the discrete
# phases that the thin drivers compose, so each concern is callable on its own
# and concretization (the dependency SOLVE) is not hidden inside the installer:
#
#   concretize.sh : gmx_prepare + gmx_concretize               (cheap solve/check)
#   build.sh      : + gmx_install + modulefile + verification    (the full build)
#   fetch.sh      : + gmx_fetch (after a login-node submodule clone)
#
# Deeper rationale (stacks, SIMD, the modulefile, tuning) lives in MAINTAINER.md.

# Source-once guard (these are pure definitions).
if [ -n "${_GMX_LIB_SOURCED:-}" ]; then return 0; fi
_GMX_LIB_SOURCED=1

GMX_SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

# --- Logging ---------------------------------------------------------------
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# --- Tunables (maintainer overrides; see MAINTAINER.md) --------------------
SPACK_JOBS="${SPACK_JOBS:-8}"
# cray stack: Cray PE modules backing the cray-mpich + cray-fftw externals.
# Versions MUST match the external prefixes in spack-env/cray/spack.yaml.
PRGENV_MODULE="${PRGENV_MODULE:-PrgEnv-gnu}"
CRAYPE_TARGET="${CRAYPE_TARGET:-craype-arm-grace}"
FFTW_MODULE="${FFTW_MODULE:-brics/cray-fftw/3.3.10.7}"
GCC_CXX="${GCC_CXX:-/usr/bin/g++-14}"

GMX_SUBMODULES=(spack spack-packages)

# True if vendor/<name> is an INITIALIZED submodule. An initialized submodule has
# its own .git; an uninitialized one is an empty directory, for which
# `git -C ... rev-parse --git-dir` would misleadingly succeed by walking UP to
# the superproject's .git — so test the submodule's own .git directly.
_gmx_submodule_present() { [ -e "$REPO_ROOT/vendor/$1/.git" ]; }

# --- Preflight -------------------------------------------------------------
gmx_validate_variant() {
  case "$GROMACS_STACK" in
    cray|spack) ;;
    *) die "GROMACS_STACK must be 'cray' or 'spack' (got '$GROMACS_STACK')" ;;
  esac
  case "$GROMACS_SIMD" in
    sve|neon) ;;
    *) die "GROMACS_SIMD must be 'sve' or 'neon' (got '$GROMACS_SIMD')" ;;
  esac
  info "Variant: $VARIANT (stack=$GROMACS_STACK simd=$GROMACS_SIMD; env: $SPACK_ENV_DIR)"
}

# Spack 1.0 needs CPython >=3.7 and <3.12 (it parses sources with ast.Str,
# removed in 3.12). common.sh points SPACK_PYTHON at python3; verify it here for
# a clear error rather than a deep Spack traceback later.
gmx_check_python() {
  local py ver
  py="${SPACK_PYTHON:-$(command -v python3 2>/dev/null || true)}"
  [ -n "$py" ] && [ -x "$py" ] \
    || die "no Python found to run Spack. Load one ('module load cray-python/3.11.7', or any python3 in [3.7,3.12)) and re-run — or use pixi."
  ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  case "$ver" in
    3.7|3.8|3.9|3.10|3.11) info "Spack Python: $py ($ver)" ;;
    *) die "Spack needs Python >=3.7 and <3.12 (found '${ver:-unknown}' at $py). Load a suitable one ('module load cray-python/3.11.7') — or use pixi." ;;
  esac
}

gmx_ensure_dirs() {
  mkdir -p "$PREFIX" "$SPACK_USER_CONFIG_PATH" "$SPACK_USER_CACHE_PATH"
}

gmx_check_submodules() {
  local sub
  for sub in "${GMX_SUBMODULES[@]}"; do
    _gmx_submodule_present "$sub" \
      || die "Submodule vendor/$sub is missing/uninitialized. Run: git submodule update --init --recursive --jobs 4"
  done
}

# fetch: clone any MISSING submodules instead of failing, so the login-node
# prefetch is self-sufficient. Concurrency-capped for the login node's ulimit -u.
gmx_clone_missing_submodules() {
  local jobs="${1:-4}" sub missing=()
  for sub in "${GMX_SUBMODULES[@]}"; do
    _gmx_submodule_present "$sub" || missing+=("vendor/$sub")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Cloning missing submodules (--jobs $jobs): ${missing[*]}"
    git -C "$REPO_ROOT" submodule update --init --recursive --jobs "$jobs" -- "${missing[@]}" \
      || die "submodule init failed for: ${missing[*]}"
  else
    info "Submodules already present — skipping clone"
  fi
}

# Load the toolchain modules. gcc@14.3.0 is an external (common.yaml) for BOTH
# stacks; GROMACS_STACK decides the MPI + FFT provider. For cray, PrgEnv-gnu is
# REQUIRED — it puts cray-mpich/libfabric/cray-pmi on the module path (so their
# externals resolve) and sets the CRAY_* lib paths used at build/link time.
gmx_load_toolchain() {
  if ! command -v module >/dev/null 2>&1; then
    local f
    for f in /opt/cray/pe/lmod/lmod/init/bash /etc/profile.d/lmod.sh \
             /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/bash; do
      # shellcheck source=/dev/null
      [ -f "$f" ] && . "$f" && break
    done
  fi
  if [ "$GROMACS_STACK" = cray ]; then
    command -v module >/dev/null 2>&1 \
      || die "no 'module' command found — cannot load $PRGENV_MODULE; the cray-mpich external will not resolve"
    module load "$PRGENV_MODULE" || die "could not 'module load $PRGENV_MODULE'"
    module load "$CRAYPE_TARGET" 2>/dev/null \
      || warn "could not load $CRAYPE_TARGET (target may default to generic aarch64)"
    module load "$FFTW_MODULE" \
      || die "could not load $FFTW_MODULE (backs the cray/spack.yaml fftw external)"
    if [ -n "${CRAY_MPICH_DIR:-}" ] && [ -d "${CRAY_MPICH_DIR:-/nonexistent}" ]; then
      info "cray-mpich: $CRAY_MPICH_DIR (v${CRAY_MPICH_VERSION:-?})"
    else
      die "CRAY_MPICH_DIR unset/missing after 'module load $PRGENV_MODULE' — cray-mpich external cannot resolve"
    fi
    [ -d "${FFTW_ROOT:-/nonexistent}" ] \
      || die "FFTW_ROOT unset/missing after 'module load $FFTW_MODULE' — cray-fftw external cannot resolve"
    info "cray-fftw: ${FFTW_ROOT}"
  else
    info "GROMACS_STACK=spack: building mpich + fftw from source; loading no Cray PE modules"
  fi
  if [ -x "$GCC_CXX" ]; then
    info "gcc (external): $("$GCC_CXX" --version 2>/dev/null | head -1)"
  else
    die "$GCC_CXX missing — the environment's gcc@14.3.0 external (common.yaml) cannot resolve"
  fi
}

gmx_bootstrap_spack() {
  [ -f "$SPACK_ROOT/share/spack/setup-env.sh" ] || die "vendored spack missing setup-env.sh"
  # shellcheck source=/dev/null
  . "$SPACK_ROOT/share/spack/setup-env.sh"
  spack --version || die "spack unavailable after sourcing setup-env.sh"
}

# Write Spack's config under PREFIX: install_tree persists per-version; the
# source/misc caches are SHARED across versions; build_stage is the transient,
# metadata-heavy compile area (node-local NVMe on a compute node).
gmx_write_config() {
  local build_stage="$WORKING_DIR"
  # mkdir -p returns 0 for an already-existing dir even when it is not writable,
  # so test writability explicitly rather than trust mkdir's exit status.
  mkdir -p "$build_stage" 2>/dev/null
  { [ -d "$build_stage" ] && [ -w "$build_stage" ]; } \
    || die "build stage not writable: $build_stage (set GROMACS_WORKING_DIR)"
  info "Install prefix (persistent): $PREFIX"
  info "Build stage    (transient):  $build_stage"
  cat > "$SPACK_USER_CONFIG_PATH/config.yaml" <<EOF
config:
  install_tree:
    root: $PREFIX/opt
  build_stage:
  - $build_stage
  source_cache: $GROMACS_SOURCE_CACHE
  misc_cache: $GROMACS_MISC_CACHE
  build_jobs: $SPACK_JOBS
EOF
}

# Instantiate the directory environment under PREFIX from the tracked template,
# rewriting the relative `include: ../common.yaml` to an absolute path back into
# the repo (done literally in awk via index()/substr so nothing in the path is
# interpreted). The env's lockfile then lands outside the repo.
#
# ./simd.yaml is left relative: it is GENERATED next to the manifest by
# gmx_write_simd_config, and Spack resolves an include relative to the including
# file's own directory.
gmx_instantiate_env() {
  [ -f "$SPACK_ENV_TEMPLATE" ] || die "missing env template: $SPACK_ENV_TEMPLATE"
  mkdir -p "$SPACK_ENV_DIR"
  GMX_COMMON_YAML="$REPO_ROOT/spack-env/common.yaml" \
    awk '
      { i = index($0, "../common.yaml")
        if (i > 0) $0 = substr($0, 1, i-1) ENVIRON["GMX_COMMON_YAML"] substr($0, i + length("../common.yaml"))
        print }
    ' "$SPACK_ENV_TEMPLATE" > "$SPACK_ENV_DIR/spack.yaml" \
    || die "failed to generate $SPACK_ENV_DIR/spack.yaml from template"
  grep -q "$REPO_ROOT/spack-env/common.yaml" "$SPACK_ENV_DIR/spack.yaml" \
    || die "include rewrite produced no absolute common.yaml path in $SPACK_ENV_DIR/spack.yaml"
  info "Spack env instantiated at $SPACK_ENV_DIR (from $SPACK_ENV_TEMPLATE)"
}

# The SIMD axis, as a generated config scope included by every stack manifest.
#
# No custom Spack package is needed for this: the builtin gromacs package
# already has an `sve` variant, and its cmake_args maps
#   +sve -> -DGMX_SIMD=ARM_SVE        (default on a target with the sve feature)
#   ~sve -> -DGMX_SIMD=ARM_NEON_ASIMD
# The SVE vector LENGTH is not a variant: GROMACS' CMake reads
# /proc/sys/abi/sve_default_vector_length and bakes -msve-vector-bits=<n> in at
# configure time. On Isambard 3 that is 16 bytes = 128 bits, and login and
# compute nodes are the same Grace hardware, so the autodetect is correct
# wherever the build runs. gmx_verify_build asserts the value actually compiled
# in rather than trusting that.
gmx_write_simd_config() {
  local sve_flag
  case "$GROMACS_SIMD" in
    sve)  sve_flag='+sve' ;;
    neon) sve_flag='~sve' ;;
  esac
  cat > "$SPACK_ENV_DIR/simd.yaml" <<EOF
# Generated by scripts/lib.sh from GROMACS_SIMD=$GROMACS_SIMD. Do not edit.
# $sve_flag -> GMX_SIMD=$( [ "$GROMACS_SIMD" = sve ] && echo ARM_SVE || echo ARM_NEON_ASIMD )
packages:
  gromacs:
    require: ['$sve_flag']
EOF
  info "SIMD config: $SPACK_ENV_DIR/simd.yaml ($sve_flag)"
}

gmx_check_repos() {
  info "Environment package repos:"
  spack -e "$SPACK_ENV_DIR" repo list || die "spack repo list failed (check spack-env/common.yaml repo paths)"
}

# Everything a solve / install / fetch needs before touching specs.
gmx_prepare() {
  gmx_validate_variant
  gmx_check_python
  gmx_ensure_dirs
  gmx_check_submodules
  gmx_load_toolchain
  gmx_bootstrap_spack
  gmx_write_config
  gmx_instantiate_env
  gmx_write_simd_config
  gmx_check_repos
}

# --- Concretize (the dependency SOLVE) -------------------------------------
# Idempotent: plain `--fresh` is a no-op (~1s) when the lock already matches the
# manifest, and re-solves when the manifest changed. FORCE_CONCRETIZE=1 forces a
# full re-solve.
#
# `spack concretize --fresh` alone is NOT enough, and this bit us: it re-solves
# when the manifest's `specs:` change, but treats a change to the `packages:`
# config — a new external, a different prefix, a dropped `modules:` key — as "no
# new specs to concretize" and silently reuses the stale lock. The build then
# fails (or worse, succeeds) against configuration nobody wrote. So hash the
# three files that define the solve and force a full re-solve whenever that hash
# moves.
gmx_concretize() {
  local stamp="$SPACK_ENV_DIR/.config-hash"
  local now prev="" cflags=(--fresh)
  now="$(cat "$SPACK_ENV_DIR/spack.yaml" "$SPACK_ENV_DIR/simd.yaml" \
             "$REPO_ROOT/spack-env/common.yaml" 2>/dev/null | cksum | awk '{print $1"-"$2}')"
  [ -r "$stamp" ] && prev="$(cat "$stamp")"

  if [ "${FORCE_CONCRETIZE:-0}" = "1" ]; then
    info "FORCE_CONCRETIZE=1 — forcing a full re-solve"
    cflags=(-f --fresh)
  elif [ -n "$prev" ] && [ "$now" != "$prev" ]; then
    info "manifest/config changed since the last solve — forcing a full re-solve"
    cflags=(-f --fresh)
  fi

  info "Concretizing $ENV_NAME"
  spack -e "$SPACK_ENV_DIR" concretize "${cflags[@]}" || die "concretize failed"
  printf '%s\n' "$now" > "$stamp"
  gmx_assert_variant
}

# Assert the concretized lock actually matches the requested variant, so a
# mis-resolved external or a leaking PrgEnv can never silently produce the wrong
# stack — which would quietly invalidate the whole cray-vs-spack comparison.
gmx_assert_variant() {
  local lock="$SPACK_ENV_DIR/spack.lock"
  [ -f "$lock" ] || die "no spack.lock at $lock after concretize"
  if [ "$GROMACS_STACK" = cray ]; then
    grep -qE '"name":[[:space:]]*"mpich"' "$lock" \
      && die "a from-source mpich entered the solve; expected only cray-mpich. Is PrgEnv-gnu loaded and the cray-mpich external resolving?"
    grep -qE '"name":[[:space:]]*"cray-mpich"' "$lock" \
      || die "cray-mpich is not in the solve. Is PrgEnv-gnu loaded?"
    grep -q '/opt/cray/pe/fftw/' "$lock" \
      || die "the Cray FFTW external prefix is not in the solve; fftw may have gone from-source. Is $FFTW_MODULE loaded?"
    info "MPI provider: cray-mpich (external) — OK"
    info "FFT provider: cray-fftw (external) — OK"
  else
    grep -qE '"name":[[:space:]]*"cray-mpich"' "$lock" \
      && die "cray-mpich entered the GROMACS_STACK=spack solve; expected from-source mpich. Is a Cray PrgEnv leaking in?"
    grep -qE '"name":[[:space:]]*"mpich"' "$lock" \
      || die "no from-source mpich in the GROMACS_STACK=spack solve."
    grep -q '/opt/cray/pe/fftw/' "$lock" \
      && die "the Cray FFTW external prefix entered the GROMACS_STACK=spack solve; expected from-source fftw."
    info "MPI/FFT provider: from-source mpich + fftw — OK"
  fi
  # Both binaries must be in the solve — the README promises `gmx` and `gmx_mpi`.
  # Count nodes, not lines: spack.lock is JSON that may be on a single line.
  local n
  n="$(grep -o '"name":[[:space:]]*"gromacs"' "$lock" | wc -l)"
  [ "${n:-0}" -ge 2 ] \
    || die "expected two gromacs specs (~mpi and +mpi) in the solve, found ${n:-0}"
  info "GROMACS specs in solve: $n (thread-MPI + MPI) — OK"
}

# --- Fetch -----------------------------------------------------------------
gmx_fetch() {
  info "Fetching all sources for $ENV_NAME into $GROMACS_SOURCE_CACHE"
  spack -e "$SPACK_ENV_DIR" fetch || die "spack fetch failed"
  info "Sources cached — the compute-node build can now run offline."
}

# --- Install ---------------------------------------------------------------
gmx_install() {
  info "Installing the full environment (-j $SPACK_JOBS)"
  spack -e "$SPACK_ENV_DIR" install -j "$SPACK_JOBS" || die "install failed"
}

gmx_gen_modulefile() {
  bash "$GMX_SCRIPTS_DIR/gen-modulefile.sh" || die "gen-modulefile.sh failed"
}

# --- Post-build verification ----------------------------------------------
# `gmx -version` prints the exact build configuration: SIMD kind, FFT library,
# MPI library and the literal compiler flag line. That makes it the ground truth
# for every "did the toggle actually take effect?" question, so assert on it
# instead of trusting the manifest. A build that silently fell back to scalar
# SIMD, the wrong SVE width, or an unexpected FFT library is worse than a failed
# build: it would look fine and just be slow.
gmx_verify_build() {
  # shellcheck source=/dev/null
  . "$GMX_SCRIPTS_DIR/activate.sh"
  local out expect_simd
  case "$GROMACS_SIMD" in
    sve)  expect_simd="ARM_SVE" ;;
    neon) expect_simd="ARM_NEON_ASIMD" ;;
  esac

  command -v gmx     >/dev/null 2>&1 || die "gmx not on PATH after loading $MODULE_NAME"
  command -v gmx_mpi >/dev/null 2>&1 || die "gmx_mpi not on PATH after loading $MODULE_NAME"

  local bin
  for bin in gmx gmx_mpi; do
    out="$("$bin" -version 2>&1)" || die "$bin -version failed"
    echo "$out" | grep -E "GROMACS version|SIMD instructions|FFT library|MPI library|C\+\+ compiler flags" \
      | sed "s/^/INFO: [$bin] /"

    echo "$out" | grep -q "SIMD instructions:.*$expect_simd" \
      || die "$bin was built with the wrong SIMD (wanted $expect_simd). Got: $(echo "$out" | grep 'SIMD instructions:')"

    if [ "$GROMACS_SIMD" = sve ]; then
      # The compile-time SVE width. GROMACS reads it from
      # /proc/sys/abi/sve_default_vector_length; Grace is 128-bit. A binary built
      # with the wrong width is either slow or illegal-instruction at runtime.
      echo "$out" | grep -q -- "-msve-vector-bits=128" \
        || die "$bin was not compiled with -msve-vector-bits=128 (Grace SVE is 128-bit). Flags: $(echo "$out" | grep 'C++ compiler flags')"
    fi
  done

  # The Spack target pin (common.yaml: `target=neoverse_v2`) reaching the
  # compiler. Deliberately NOT checked against `gmx -version`: that reports
  # CMAKE_CXX_FLAGS only, and Spack does not put the target flag there. Spack's
  # compiler wrapper `preextend`s $SPACK_TARGET_ARGS_CXX onto every compile
  # invocation instead, so the recorded per-install build environment is the
  # real evidence.
  local envfile spec
  for spec in 'gromacs~mpi' 'gromacs+mpi'; do
    envfile="$(spack -e "$SPACK_ENV_DIR" location -i "$spec" 2>/dev/null)/.spack/spack-build-env.txt"
    [ -r "$envfile" ] || { warn "no recorded build env at $envfile — cannot verify the CPU target pin"; continue; }
    grep -q "SPACK_TARGET_ARGS_CXX=-mcpu=neoverse-v2" "$envfile" \
      || die "the target pin did not reach the compiler wrapper in $envfile (expected SPACK_TARGET_ARGS_CXX=-mcpu=neoverse-v2)"
  done
  info "CPU target: -mcpu=neoverse-v2 injected by the compiler wrapper — OK"

  # MPI vs thread-MPI must be the right way round for each binary.
  gmx -version 2>&1 | grep -q "MPI library:.*thread_mpi" \
    || warn "gmx does not report thread_mpi"
  gmx_mpi -version 2>&1 | grep -qi "MPI library:.*MPI" \
    || warn "gmx_mpi does not report an MPI library"

  info "Build verification passed for $VARIANT"
}

# What the deliverable actually needs at run time. Recorded in the build log
# because it is the evidence behind README's "a module load is required on the
# cray stack, but barely on the spack stack" claim: Spack RPATHs its own
# packages into the binary, but system externals (cray-mpich, cray-fftw,
# libfabric) are NOT RPATH'd and resolve only via LD_LIBRARY_PATH.
gmx_report_linkage() {
  # shellcheck source=/dev/null
  . "$GMX_SCRIPTS_DIR/activate.sh"
  local exe
  exe="$(command -v gmx_mpi 2>/dev/null)" || return 0
  info "Runtime linkage of $exe:"
  ldd "$exe" 2>/dev/null | sed 's/^/INFO:   /'
  info "Unresolved WITHOUT the module (what LD_LIBRARY_PATH is buying you):"
  env -u LD_LIBRARY_PATH ldd "$exe" 2>/dev/null | grep -i "not found" | sed 's/^/INFO:   /' \
    || info "  (none — the binary is self-contained via RPATH)"
}
