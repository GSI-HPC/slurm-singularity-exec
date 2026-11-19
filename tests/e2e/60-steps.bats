#!/usr/bin/env bats
# The steps of a job use the options of the job.

setup() {
  load helpers
  conf_remove
}

@test "the steps of salloc use the image of the job" {
  run user_sh <<'EOF2'
salloc --container="$SIF" srun "$PROBE" 2>&1
EOF2
  assert_status 0
  assert_output_has "os=alpine" "tp=set"
}

@test "a step can select a different image" {
  run user_sh <<'EOF2'
salloc --container="$SIF" sh -c 'srun --container=none "$PROBE"; srun "$PROBE"' 2>&1
EOF2
  assert_status 0
  assert_output_has "in=host" "in=alpine.sif"
}

@test "the steps of a batch job use the bind paths of the job" {
  run user_sh <<'EOF2'
rm -f steps1.out
sbatch --wait -o steps1.out --apptainer-bind="$FIX:/mnt/job" \
  --wrap "srun --container=$SIF ls /mnt/job" >/dev/null
cat steps1.out
EOF2
  assert_status 0
  assert_output_has "probe.sh"
}

@test "a step can replace the bind paths of the job" {
  run user_sh <<'EOF2'
rm -f steps2.out
sbatch --wait -o steps2.out --apptainer-bind="$FIX:/mnt/job" \
  --wrap "srun --container=$SIF --apptainer-bind=$FIX:/mnt/step sh -c 'ls -d /mnt/step; ls -d /mnt/job'" >/dev/null
cat steps2.out
EOF2
  assert_output_has "/mnt/step" "/mnt/job: No such file"
}

@test "the steps of a job use the runtime of the job" {
  run user_sh <<'EOF2'
unset SRUN_RUNTIME SBATCH_RUNTIME
rm -f steps3.out
sbatch --wait -o steps3.out --runtime=apptainer --container=none \
  --wrap "srun --container=$SIF $PROBE" >/dev/null
cat steps3.out
EOF2
  assert_status 0
  assert_output_has "os=alpine"
}
