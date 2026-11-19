#!/usr/bin/env bats
# The options that the plugin adds to srun, sbatch and salloc.

setup() {
  load helpers
  conf_remove
}

@test "srun --help lists the options of the plugin" {
  run user_sh <<'EOF2'
srun --runtime=apptainer --help
EOF2
  assert_status 0
  assert_output_has "Options provided by runtime/apptainer:" \
    "--container=image" "--apptainer-bind=" "--apptainer-args=" \
    "--apptainer-no-default-binds=yes|no"
}

@test "sbatch and salloc --help list the options of the plugin" {
  run user_sh <<'EOF2'
sbatch --runtime=apptainer --help && salloc --runtime=apptainer --help
EOF2
  assert_status 0
  [[ "$(grep -c -- "--apptainer-bind=" <<<"$output")" -eq 2 ]]
}

@test "--runtime=list names the plugin" {
  run user_sh <<'EOF2'
srun --runtime=list
EOF2
  assert_status 0
  assert_output_has "apptainer"
}

@test "--container without a value is an error" {
  run user_sh <<'EOF2'
srun --runtime=apptainer --container true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "--container requires a value"
}

@test "--apptainer-no-default-binds takes only yes or no" {
  run user_sh <<'EOF2'
srun --runtime=apptainer --container="$SIF" --apptainer-no-default-binds=maybe true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "requires yes or no"
}

@test "an option of the plugin is an error with a different runtime" {
  run user_sh <<'EOF2'
srun --runtime=none --apptainer-bind=/tmp true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "--apptainer-bind is not an option of runtime/none"
}
