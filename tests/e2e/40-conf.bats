#!/usr/bin/env bats
# The site configuration in apptainer.conf.

setup() {
  load helpers
  conf_remove
}

teardown() {
  conf_remove
}

@test "Bind adds bind paths to each container" {
  conf_write <<EOF2
Bind=$E2E_FIXTURES:/mnt/site,$E2E_FIXTURES:/mnt/site2
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-bind="$FIX:/mnt/job" sh -c 'ls -d /mnt/site /mnt/site2 /mnt/job'
EOF2
  assert_status 0
  assert_output_has "/mnt/site" "/mnt/site2" "/mnt/job"
}

@test "--apptainer-no-default-binds leaves out the paths of Bind" {
  conf_write <<EOF2
Bind=$E2E_FIXTURES:/mnt/site
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-no-default-binds --apptainer-bind="$FIX:/mnt/job" \
  sh -c 'ls -d /mnt/job; ls -d /mnt/site'
srun --container="$SIF" --apptainer-no-default-binds=no sh -c 'echo "kept=$(ls -d /mnt/site)"'
EOF2
  assert_output_has "/mnt/job" "/mnt/site: No such file" "kept=/mnt/site"
}

@test "ExecArgs adds arguments to apptainer exec" {
  conf_write <<'EOF2'
ExecArgs="--env 'SITE_MARK=a b' --env SITE_MARK2=2"
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" sh -c 'echo "site=[$SITE_MARK] site2=[$SITE_MARK2]"'
EOF2
  assert_status 0
  assert_output_has "site=[a b] site2=[2]"
}

@test "GlobalArgs adds arguments to apptainer" {
  conf_write <<'EOF2'
GlobalArgs=--debug
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" true
EOF2
  assert_status 0
  assert_output_has "DEBUG"
}

@test "AllowUserArgs=no refuses --apptainer-args" {
  conf_write <<'EOF2'
AllowUserArgs=no
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" --apptainer-args=--no-home true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "--apptainer-args is not permitted"
}

@test "DefaultImage is the image of a step that names none" {
  conf_write <<EOF2
DefaultImage=$E2E_SIF
EOF2
  run user_sh <<'EOF2'
srun "$PROBE"
EOF2
  assert_status 0
  assert_output_has "os=alpine" "tp=set"
}

@test "--container=none switches off DefaultImage" {
  conf_write <<EOF2
DefaultImage=$E2E_SIF
EOF2
  run user_sh <<'EOF2'
srun --container=none "$PROBE" && srun --container= "$PROBE"
EOF2
  assert_status 0
  [[ "$(grep -c in=host <<<"$output")" -eq 2 ]]
}

@test "Executable can be a wrapper of the site" {
  conf_write <<EOF2
Executable=$E2E_FIXTURES/wrapper.sh
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" sh -c 'echo "wrapper=$WRAPPER_MARK"'
EOF2
  assert_status 0
  assert_output_has "wrapper=set"
}

@test "an Executable that does not exist is an error" {
  conf_write <<'EOF2'
Executable=no-such-apptainer
EOF2
  run user_sh <<'EOF2'
srun --container="$SIF" true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "cannot find the program no-such-apptainer"
}

@test "a key that the plugin does not know stops the step" {
  conf_write <<'EOF2'
NoSuchKey=1
EOF2
  run user_sh <<'EOF2'
timeout 60 srun --container="$SIF" true
EOF2
  [[ "$status" -ne 0 ]]
}
