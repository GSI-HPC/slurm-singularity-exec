#!/bin/sh
run_in() {
  local container="$1"
  local args="$SLURM_SINGULARITY_ARGS"
  unset SLURM_SINGULARITY_ARGS
  shift
  case "$container" in
    */*)
      # It's a path, so no standard vae.gsi.de container
      ;;
    *)
      container=/cvmfs/vae.gsi.de/$container/containers/user_container-production.sif
      ;;
  esac
  exec singularity exec $args "$container" -- "$@"
}

run_in "$@"
