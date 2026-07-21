#!/usr/bin/env bash
# gen-modulefile.sh — write the per-variant Lmod modulefile for VARIANT.
#
# To keep the modulefile auditable, the LOGIC (what goes on PATH/LD_*, the
# conditionals, ordering) lives in the version-controlled, syntax-highlighted
# scripts/gromacs-env.lua. THIS script only resolves the per-build paths and
# emits a flat Lua DATA table; the generated file then runs the committed logic
# with it:
#     local data = { ... }
#     assert(loadfile(".../gromacs-env.lua"))(data)
# (Lmod's sandbox forbids dofile() but allows loadfile() + an argument.)
#
# Called by build.sh after `env view regenerate`, but also runnable on its own to
# regenerate the modulefile without a full rebuild (the env must already be
# concretized + installed). For the cray variant, run with the Cray PE modules
# loaded (PrgEnv-gnu + cray-fftw) so CRAY_LD_LIBRARY_PATH is populated.
set -uo pipefail

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/common.sh
. "$_here/common.sh"

info() { echo "INFO: $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

case "$GROMACS_STACK" in cray|spack) ;; *) die "GROMACS_STACK must be 'cray' or 'spack' (got '$GROMACS_STACK')" ;; esac
case "$GROMACS_SIMD"  in sve|neon)   ;; *) die "GROMACS_SIMD must be 'sve' or 'neon' (got '$GROMACS_SIMD')" ;; esac

logic="$_here/gromacs-env.lua"
view="$SPACK_ENV_DIR/.spack-env/view"
[ -f "$logic" ] || die "missing modulefile logic: $logic"
[ -d "$view/bin" ] || die "Spack env view missing at $view — build it first: sbatch scripts/build.sbatch"
command -v spack >/dev/null 2>&1 || die "spack CLI not on PATH (common.sh should add it)"

# Snapshot the committed logic next to the generated modulefiles, under BASE, and
# have the modulefile loadfile() THAT copy — not the in-repo original — so
# `module load` stays self-contained: users must not depend on the repo path (it
# may have moved or been deleted since the build). Byte-identical to the tracked
# scripts/gromacs-env.lua, refreshed every build.
installed_logic="$MODULEFILES_DIR/gromacs-env.lua"

# --- Lua literal helpers (the only quoting this script does) ----------------
lua_q()  { local s=${1:-}; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
lua_qn() { if [ -n "${1:-}" ]; then lua_q "$1"; else printf 'nil'; fi; }
lua_list() {
  local x out=""
  for x in "$@"; do
    [ -n "$out" ] && out+=", "
    out+="$(lua_q "$x")"
  done
  [ -n "$out" ] && printf '{ %s }' "$out" || printf '{}'
}

# --- Resolve the per-build, hash-addressed install prefixes -----------------
# Two gromacs specs share the environment, distinguished only by ~mpi/+mpi, so
# `spack location -i gromacs` alone is ambiguous — always qualify.
gromacs_tmpi="$(spack -e "$SPACK_ENV_DIR" location -i gromacs~mpi 2>/dev/null || true)"
gromacs_mpi="$(spack -e "$SPACK_ENV_DIR" location -i gromacs+mpi 2>/dev/null || true)"
[ -n "$gromacs_tmpi" ] || die "cannot locate the installed 'gromacs~mpi' (thread-MPI) spec — is the '$VARIANT' env fully built?"
[ -n "$gromacs_mpi" ]  || die "cannot locate the installed 'gromacs+mpi' spec — is the '$VARIANT' env fully built?"
[ -x "$gromacs_tmpi/bin/gmx" ]     || die "no gmx in $gromacs_tmpi/bin"
[ -x "$gromacs_mpi/bin/gmx_mpi" ]  || die "no gmx_mpi in $gromacs_mpi/bin"

gromacs_version="$(spack -e "$SPACK_ENV_DIR" find --format '{version}' gromacs+mpi 2>/dev/null | head -1)"

# --- Launcher ---------------------------------------------------------------
# See gromacs-env.lua: the PMI plugin differs per MPI implementation.
if [ "$GROMACS_STACK" = cray ]; then
  launcher="srun"                 # Slurm MpiDefault=cray_shasta, which is cray-mpich's
else
  launcher="srun --mpi=pmi2"      # from-source mpich built pmi=pmi2
fi

# --- Cray PE prerequisites + runtime lib dirs (cray variant only) -----------
prgenv_module=""; craype_target=""; fftw_module=""
cray_libs=()
if [ "$GROMACS_STACK" = cray ]; then
  prgenv_module="${PRGENV_MODULE:-PrgEnv-gnu}"
  craype_target="${CRAYPE_TARGET:-craype-arm-grace}"
  fftw_module="${FFTW_MODULE:-brics/cray-fftw/3.3.10.7}"
  if [ -n "${CRAY_MPICH_DIR:-}" ]; then
    _OLDIFS=$IFS; IFS=:
    for _d in $CRAY_MPICH_DIR/lib${CRAY_LD_LIBRARY_PATH:+:$CRAY_LD_LIBRARY_PATH}; do
      [ -n "$_d" ] && cray_libs+=("$_d")
    done
    IFS=$_OLDIFS
  else
    warn "CRAY_MPICH_DIR unset — the modulefile will lack the Cray MPI lib paths."
    warn "Re-run with the Cray PE modules loaded (PrgEnv-gnu + $fftw_module)."
  fi
  # These are NOT RPATH'd into gmx_mpi, so without them gmx_mpi will not start.
  for _d in /opt/cray/libfabric/2.3.1/lib64 /opt/cray/pe/lib64 /opt/cray/pals/1.8/lib; do
    [ -d "$_d" ] && cray_libs+=("$_d")
  done
fi
cray_libs_lua='{}'; [ ${#cray_libs[@]} -gt 0 ] && cray_libs_lua="$(lua_list "${cray_libs[@]}")"

# --- Emit the data table + a call into the committed logic ------------------
mkdir -p "$(dirname "$MODULEFILE")" "$MODULEFILES_DIR"
cp -f "$logic" "$installed_logic" || die "failed to snapshot logic to $installed_logic"
info "Writing Lmod modulefile ($MODULEFILE)"

# Cray module prerequisites MUST be literal load()/try_load() calls at the TOP
# LEVEL of this generated file, not inside gromacs-env.lua reached via
# loadfile(): Lmod resolves module hierarchy (MODULEPATH changes from loading a
# compiler family) by statically scanning the top-level modulefile source for
# load(...) calls, so a load() only reachable via loadfile() is invisible to that
# scan and silently does nothing.
cray_loads=""
if [ "$GROMACS_STACK" = cray ]; then
  cray_loads="load($(lua_q "$prgenv_module"))
try_load($(lua_q "$craype_target"))
load($(lua_q "$fftw_module"))
"
fi

cat > "$MODULEFILE" <<EOF
-- Generated by gen-modulefile.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Do not edit.
-- Per-build path data for the $VARIANT variant; the logic that consumes it is
-- version-controlled (and audited) in scripts/gromacs-env.lua.
${cray_loads}local data = {
  version         = $(lua_q  "$GROMACS_ENV_VERSION"),
  variant         = $(lua_q  "$VARIANT"),
  stack           = $(lua_q  "$GROMACS_STACK"),
  simd            = $(lua_q  "$GROMACS_SIMD"),
  gromacs_version = $(lua_qn "$gromacs_version"),
  -- Absolute paths to the (under-PREFIX) Spack env + its view, so the modulefile
  -- never derives them from the repo: the deliverable stays repo-independent.
  spack_env       = $(lua_q  "$SPACK_ENV_DIR"),
  view            = $(lua_q  "$view"),
  gromacs_tmpi    = $(lua_q  "$gromacs_tmpi"),
  gromacs_mpi     = $(lua_q  "$gromacs_mpi"),
  launcher        = $(lua_q  "$launcher"),
  cray_libs       = $cray_libs_lua,
}
assert(loadfile($(lua_q "$installed_logic")))(data)
EOF

# Default selectors so a bare `module load` picks a sensible target: cray-sve is
# the project default variant, and the most-recently-built version becomes the
# bare-`gromacs-env` default. Both files are rewritten (idempotently) each build.
mkdir -p "$MODULEFILES_DIR/gromacs-env/$GROMACS_ENV_VERSION"
cat > "$MODULEFILES_DIR/gromacs-env/$GROMACS_ENV_VERSION/.modulerc.lua" <<EOF
-- Generated by gen-modulefile.sh. Within $GROMACS_ENV_VERSION, default variant = cray-sve.
module_version("gromacs-env/$GROMACS_ENV_VERSION/cray-sve", "default")
EOF
cat > "$MODULEFILES_DIR/gromacs-env/.modulerc.lua" <<EOF
-- Generated by gen-modulefile.sh. Bare 'module load gromacs-env' default =
-- the most recently built version's cray-sve variant.
module_version("gromacs-env/$GROMACS_ENV_VERSION/cray-sve", "default")
EOF

info "Modulefile written. Load it with:"
info "  module use $MODULEFILES_DIR && module load $MODULE_NAME"
