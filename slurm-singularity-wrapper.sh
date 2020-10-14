#!/bin/sh
run_in() {
  local container="$1"
  shift
  local args="$SLURM_SINGULARITY_ARGS"
  unset SLURM_SINGULARITY_ARGS
  local bind="$SLURM_SINGULARITY_BIND"
  unset SLURM_SINGULARITY_BIND
  case "$container" in
    */*)
      # It's a path, so no standard vae.gsi.de container
      ;;
    *)
      container=/cvmfs/vae.gsi.de/$container/containers/user_container-production.sif
      ;;
  esac
  if [ -n "$args" ]; then
    echo "Warning: The wrapper script '$0' ignores singularity arguments ($args)" 1>&2
  fi
  if [ -z "$bind" ]; then
    exec singularity exec "$container" -- "$@"
  else
    exec singularity exec --bind "$bind" "$container" -- "$@"
  fi
}

run_in "$@"
