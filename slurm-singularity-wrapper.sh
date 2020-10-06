#!/bin/sh
exec singularity exec "$SINGULARITY_EXEC_CONTAINER" "$SINGULARITY_EXEC_JOB" "$@"
