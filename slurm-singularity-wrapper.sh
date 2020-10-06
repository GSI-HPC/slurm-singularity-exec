#!/bin/sh
run_in() {
  local container="$1"
  shift
  exec singularity exec "$container" "$@"
}

run_in "$@"
