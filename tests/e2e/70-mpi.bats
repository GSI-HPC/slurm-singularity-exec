#!/usr/bin/env bats
# MPI in a container: the tasks connect to the PMIx server of the step.

setup() {
  load helpers
  conf_remove
}

@test "a PMIx client in a container connects to the PMIx server of the step" {
  [[ -n "$E2E_PMIX_CLIENT" && -n "$E2E_NODE_OS" ]] || skip "no PMIx client"
  run user_sh <<'EOF2'
srun --mpi=pmix -N"$NODES" -n"$NODES" --container="$NODE_OS" \
  --apptainer-bind=/usr "$PMIX_CLIENT" 2>&1
EOF2
  assert_status 0
  # helpers.bash sets E2E_NODES.
  # shellcheck disable=SC2153
  assert_output_has "pmix rank=0 size=$E2E_NODES"
  if ((E2E_NODES > 1)); then
    assert_output_has "pmix rank=1 size=$E2E_NODES"
  fi
}

@test "--apptainer-no-default-binds keeps the files of the PMIx server" {
  [[ -n "$E2E_PMIX_CLIENT" && -n "$E2E_NODE_OS" ]] || skip "no PMIx client"
  conf_write <<'EOF2'
Bind=/etc/hostname
EOF2
  run user_sh <<'EOF2'
srun --mpi=pmix -n2 --container="$NODE_OS" --apptainer-no-default-binds \
  --apptainer-bind=/usr "$PMIX_CLIENT" 2>&1
EOF2
  assert_status 0
  assert_output_has "pmix rank=0 size=2" "pmix rank=1 size=2"
}

@test "--sharens puts the tasks of a step on one node into one user namespace" {
  run user_sh <<'EOF2'
if ! srun -N1 --container=none apptainer exec --help | grep -q -- --sharens; then
  echo "no sharens"
  exit 0
fi
# The tasks join the namespace of the first task, which must not end first.
srun -N1 -n2 --container="$SIF" --apptainer-args=--sharens \
  sh -c 'readlink /proc/self/ns/user; sleep 2' 2>&1 | sort | uniq -c
EOF2
  [[ "$output" != "no sharens" ]] || skip "Apptainer has no --sharens"
  assert_status 0
  assert_output_has "2 user:"
}

@test "slurmd keeps no directory of a step in a container" {
  run user_sh <<'EOF2'
srun -N"$NODES" --container="$SIF" true || exit 1
for try in 1 2 3 4 5 6 7 8 9 10; do
  left=$(srun -N"$NODES" --container=none sh -c \
    'ls -d "$(scontrol show config | sed -n "s/^SlurmdSpoolDir *= *//p")"/apptainer.* 2>/dev/null')
  [ -z "$left" ] && echo "none left" && exit 0
  sleep 1
done
echo "left: $left"
exit 1
EOF2
  assert_status 0
  assert_output_has "none left"
}
