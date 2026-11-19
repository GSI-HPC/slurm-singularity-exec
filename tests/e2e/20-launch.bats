#!/usr/bin/env bats
# srun starts the tasks of a step in the container.

setup() {
  load helpers
  conf_remove
}

@test "srun runs each task in the container" {
  run user_sh <<'EOF2'
srun -N"$NODES" -n"$NODES" --container="$SIF" "$PROBE" | sort
EOF2
  assert_status 0
  assert_output_has "os=alpine in=alpine.sif rank=0" "os=alpine in=alpine.sif rank=$((E2E_NODES - 1))"
  [[ "$(grep -c os=alpine <<<"$output")" -eq "$E2E_NODES" ]]
}

@test "the task keeps the TaskProlog, the limits and the job environment" {
  run user_sh <<'EOF2'
export WEIRD='a b"c$d'
ulimit -S -s 4096
srun --container="$SIF" "$PROBE"
EOF2
  assert_status 0
  # shellcheck disable=SC2016
  assert_output_has "os=alpine" "tp=set" "stack=4096" 'weird=[a b"c$d]' "cwd=/home/$E2E_USER"
}

@test "a task without --container runs on the host" {
  run user_sh <<'EOF2'
srun "$PROBE"
EOF2
  assert_status 0
  assert_output_has "in=host" "tp=set"
  assert_output_lacks "os=alpine"
}

@test "--container=none runs the task on the host" {
  run user_sh <<'EOF2'
srun --container=none "$PROBE" && srun --container= "$PROBE"
EOF2
  assert_status 0
  [[ "$(grep -c in=host <<<"$output")" -eq 2 ]]
}

@test "SRUN_CONTAINER names the image" {
  run user_sh <<'EOF2'
SRUN_CONTAINER="$SIF" srun "$PROBE"
EOF2
  assert_status 0
  assert_output_has "os=alpine"
}

@test "--runtime=apptainer selects the plugin" {
  run user_sh <<'EOF2'
unset SRUN_RUNTIME
srun --runtime=apptainer --container="$SIF" --apptainer-bind="$FIX:/mnt/fix" \
  sh -c '. /etc/os-release; echo "os=$ID fix=$(ls /mnt/fix | grep -c probe.sh)"'
EOF2
  assert_status 0
  assert_output_has "os=alpine fix=1"
}

@test "the variables of srun work when only --runtime selects the plugin" {
  run user_sh <<'EOF2'
unset SRUN_RUNTIME
SRUN_CONTAINER="$SIF" SRUN_APPTAINER_BIND="$FIX:/mnt/fix" srun --runtime=apptainer \
  sh -c '. /etc/os-release; echo "os=$ID fix=$(ls /mnt/fix | grep -c probe.sh)"'
EOF2
  assert_status 0
  assert_output_has "os=alpine fix=1"
}

@test "--runtime=none runs the task on the host" {
  run user_sh <<'EOF2'
srun --runtime=none "$PROBE"
EOF2
  assert_status 0
  assert_output_has "in=host"
}

@test "the exit status of the task is the exit status of srun" {
  run user_sh <<'EOF2'
srun --container="$SIF" sh -c 'exit 7'
EOF2
  assert_status 7
}

@test "the task reads the standard input of srun" {
  run user_sh <<'EOF2'
echo from-stdin | srun --container="$SIF" cat
EOF2
  assert_status 0
  assert_output_has "from-stdin"
}

@test "a command that only the image has runs" {
  run user_sh <<'EOF2'
srun --container="$SIF" apk --version
EOF2
  assert_status 0
  assert_output_has "apk-tools"
}

@test "the task gets the variables of the step" {
  run user_sh <<'EOF2'
srun --container="$SIF" sh -c 'echo "container=$SLURM_CONTAINER runtime=$SRUN_RUNTIME step=$SLURM_STEP_ID"'
EOF2
  assert_status 0
  assert_output_has "container=$E2E_SIF" "runtime=apptainer" "step=0"
}

@test "an image that does not exist is an error" {
  run user_sh <<'EOF2'
srun --container=/nonexistent.sif true
EOF2
  [[ "$status" -ne 0 ]]
  assert_output_has "/nonexistent.sif"
}

@test "scontrol shows the image of the job" {
  run user_sh <<'EOF2'
job=$(sbatch --parsable --container="$SIF" --wrap 'sleep 60')
scontrol show job "$job"
scancel "$job"
EOF2
  assert_status 0
  assert_output_has "Container=$E2E_SIF"
}

@test "scancel ends the tasks in the container" {
  run user_sh <<'EOF2'
srun --container="$SIF" -J e2e-cancel sh -c 'echo started; sleep 600' &
pid=$!
for _ in $(seq 60); do
  squeue -h -n e2e-cancel -t RUNNING -o %i | grep -q . && break
  sleep 1
done
sleep 2
scancel -n e2e-cancel
wait "$pid"
echo "srun=$?"
EOF2
  assert_status 0
  assert_output_has "started" "srun="
  assert_output_lacks "srun=0"
}
