#!/usr/bin/env bash
# Auto-load the built GROMACS environment via Lmod — the one piece of activation
# pixi cannot do declaratively (an env var cannot run `module load`). Sourced by
# pixi on every `pixi run` / `pixi shell` (see [activation] in pixi.toml), AFTER
# common.sh — which puts the generated modulefiles on MODULEPATH and sets the
# variant. So this stays a thin shim; the modulefile is the source of truth.
#
# Deliberately a NO-OP until the environment is built: `module load` of a
# not-yet-generated modulefile just fails quietly. End users without pixi do not
# need this script at all — they activate the same environment directly with:
#   module use "$BASE/modulefiles" && module load gromacs-env/<version>/<variant>
#
# We do NOT source spack's setup-env.sh (its exported shell functions error
# noisily when pixi runs a command under /bin/sh); Lmod's `module` function is
# /bin/sh-safe, so we use it directly.

# pixi may source us under /bin/sh, which does not inherit the login shell's
# `module` function — initialize Lmod when absent (guarded so we never reset an
# already-set-up Lmod / its MODULEPATH in an interactive shell).
if ! command -v module >/dev/null 2>&1; then
  for f in /opt/cray/pe/lmod/lmod/init/sh /etc/profile.d/lmod.sh \
           /usr/share/lmod/lmod/init/sh /usr/share/lmod/lmod/init/bash; do
    # shellcheck source=/dev/null
    [ -f "$f" ] && . "$f" 2>/dev/null && break
  done
fi

if command -v module >/dev/null 2>&1; then
  module load "${MODULE_NAME:-gromacs-env}" 2>/dev/null || true
fi
