#!/usr/bin/env bats
# The bind paths and the Apptainer arguments of a job.

setup() {
  load helpers
  conf_remove
}

@test "--apptainer-bind adds a bind path" {
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-bind="$FIX:/mnt/fix:ro" ls /mnt/fix
EOF2
  assert_status 0
  assert_output_has "probe.sh"
}

@test "--apptainer-bind takes a list and adds up" {
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-bind="$FIX:/mnt/a" \
  --apptainer-bind="$FIX:/mnt/b,$FIX:/mnt/c" sh -c 'ls -d /mnt/a /mnt/b /mnt/c'
EOF2
  assert_status 0
  assert_output_has "/mnt/a" "/mnt/b" "/mnt/c"
}

@test "SRUN_APPTAINER_BIND adds a bind path" {
  run user_sh <<'EOF2'
SRUN_APPTAINER_BIND="$FIX:/mnt/env" srun --container="$SIF" ls /mnt/env
EOF2
  assert_status 0
  assert_output_has "probe.sh"
}

@test "the command line replaces SRUN_APPTAINER_BIND" {
  run user_sh <<'EOF2'
export SRUN_APPTAINER_BIND="$FIX:/mnt/env"
srun --container="$SIF" --apptainer-bind="$FIX:/mnt/cli" sh -c 'ls -d /mnt/cli; ls -d /mnt/env'
EOF2
  assert_output_has "/mnt/cli" "/mnt/env: No such file"
}

@test "--apptainer-args adds arguments to apptainer exec" {
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-args="--env MARK='a b'" --apptainer-args="--env MARK2=2" \
  sh -c 'echo "mark=[$MARK] mark2=[$MARK2]"'
EOF2
  assert_status 0
  assert_output_has "mark=[a b] mark2=[2]"
}

@test "--apptainer-args with a quote that is not closed is an error" {
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-args="--env 'open" true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "quote ' is not closed"
}
