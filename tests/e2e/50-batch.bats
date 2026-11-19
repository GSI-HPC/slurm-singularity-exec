#!/usr/bin/env bats
# sbatch runs the batch script in the container.

setup() {
  load helpers
  conf_remove
}

@test "sbatch runs the batch script in the container" {
  run user_sh <<'EOF2'
export WEIRD='a b"c$d'
ulimit -S -s 4096
rm -f batch1.out
sbatch --wait -o batch1.out --container="$SIF" --wrap "$PROBE" >/dev/null
cat batch1.out
EOF2
  assert_status 0
  # shellcheck disable=SC2016
  assert_output_has "os=alpine" "tp=set" "stack=4096" 'weird=[a b"c$d]' "cwd=/home/$E2E_USER"
}

@test "#SBATCH lines select the plugin and the image" {
  run user_sh <<'EOF2'
cat >batch2.sh <<EOS
#!/bin/sh
#SBATCH --runtime=apptainer
#SBATCH --container=$SIF
#SBATCH --apptainer-bind=$FIX:/mnt/fix
#SBATCH --output=batch2.out
. /etc/os-release
echo "os=\$ID fix=\$(ls /mnt/fix | grep -c probe.sh)"
EOS
rm -f batch2.out
sbatch --wait batch2.sh >/dev/null
cat batch2.out
EOF2
  assert_status 0
  assert_output_has "os=alpine fix=1"
}

@test "SBATCH_CONTAINER names the image" {
  run user_sh <<'EOF2'
rm -f batch3.out
SBATCH_CONTAINER="$SIF" sbatch --wait -o batch3.out --wrap "$PROBE" >/dev/null
cat batch3.out
EOF2
  assert_status 0
  assert_output_has "os=alpine"
}

@test "the batch script gets the variables of the job" {
  run user_sh <<'EOF2'
rm -f batch4.out
sbatch --wait -o batch4.out --container="$SIF" --apptainer-bind="$FIX:/mnt/fix" \
  --wrap 'echo "container=$SLURM_CONTAINER bind=$SLURM_APPTAINER_BIND runtime=$SRUN_RUNTIME"' >/dev/null
cat batch4.out
EOF2
  assert_status 0
  assert_output_has "container=$E2E_SIF" "bind=$E2E_FIXTURES:/mnt/fix" "runtime=apptainer"
}

@test "sbatch --runtime=apptainer selects the plugin" {
  run user_sh <<'EOF2'
unset SBATCH_RUNTIME
rm -f batch6.out
SBATCH_APPTAINER_BIND="$FIX:/mnt/fix" sbatch --wait -o batch6.out --runtime=apptainer --container="$SIF" \
  --wrap '. /etc/os-release; echo "os=$ID fix=$(ls /mnt/fix | grep -c probe.sh)"' >/dev/null
cat batch6.out
EOF2
  assert_status 0
  assert_output_has "os=alpine fix=1"
}

@test "a batch script without an image runs on the host" {
  run user_sh <<'EOF2'
rm -f batch5.out
sbatch --wait -o batch5.out --wrap "$PROBE" >/dev/null
cat batch5.out
EOF2
  assert_status 0
  assert_output_has "in=host" "tp=set"
}
