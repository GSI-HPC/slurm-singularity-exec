#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end tests of the plugin on a sind cluster.
#
#   tests/e2e/run.sh              image, up, test, down
#   tests/e2e/run.sh image        build the node image with the plugin
#   tests/e2e/run.sh up           create the cluster and the test image
#   tests/e2e/run.sh test [ARG]   run the tests (ARG: arguments of bats)
#   tests/e2e/run.sh logs         write the logs of the nodes to .e2e/logs
#   tests/e2e/run.sh summary      print the failed tests and the errors of slurmd
#   tests/e2e/run.sh down         delete the cluster
#
# Variables:
#
#   NODE_IMAGE            sind node image with Slurm 26.11 and Apptainer
#   E2E_DEFAULT_RUNTIME   DefRuntimePlugin of the cluster: oci (default, as
#                         Slurm) or apptainer
#   E2E_KEEP              not empty: keep the cluster after the tests
#
# The script needs Docker, sind and bats. The Docker host must permit user
# namespaces to a process without privileges, see "prepare" in
# .github/workflows/ci.yml.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STATE=$ROOT/.e2e

: "${NODE_IMAGE:=ghcr.io/gsi-hpc/slurm-runtime-apptainer/sind-node:26.11}"
: "${E2E_DEFAULT_RUNTIME:=oci}"
: "${E2E_KEEP:=}"

E2E_IMAGE=slurm-runtime-apptainer-e2e:local
WORKERS=2

# Test image: the root file system of Alpine Linux.
ALPINE_URL=https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.8-x86_64.tar.gz
ALPINE_SHA256=2d7f46af9b7e86ad64ebeba3fe9b75b62dd5b259e708afb2ab21268f627696e5

# sind takes the cluster of each command from this variable.
export SIND_CLUSTER=runtime-apptainer

# Variables of tests/e2e/helpers.bash. sind mounts the working directory of
# "sind create cluster" at /data in each node, and the home directories are
# on a volume that all nodes share.
export E2E_BACKEND=sind
export E2E_DEFAULT_RUNTIME
export E2E_NODES=$WORKERS
export E2E_HOST_DIR=$STATE
export E2E_NODE_DIR=/data/.e2e
export E2E_FIXTURES=/data/tests/e2e/fixtures
export E2E_SIF=/home/e2e/alpine.sif
export E2E_NODE_OS=/home/e2e/node-os
export E2E_PMIX_CLIENT=/usr/libexec/e2e-pmix-client

log() {
  printf '== %s\n' "$*" >&2
}

image() {
  log "build $E2E_IMAGE from $NODE_IMAGE"
  docker build \
    --build-arg "NODE_IMAGE=$NODE_IMAGE" \
    --file "$ROOT/tests/e2e/Dockerfile" \
    --tag "$E2E_IMAGE" \
    "$ROOT"
}

cluster_config() {
  cat <<CONFIG
kind: Cluster
name: $SIND_CLUSTER
defaults:
  image: $E2E_IMAGE
  cpus: 2
  memory: 3g
  tmpSize: 1g
  # Apptainer mounts the image file with FUSE in a user namespace.
  devices: [/dev/fuse]
  securityOpt: [seccomp=unconfined, apparmor=unconfined, systempaths=unconfined]
users:
  - alice
slurm:
  main: |
    TaskProlog=$E2E_FIXTURES/taskprolog.sh
    SlurmdDebug=debug
CONFIG
  if [[ "$E2E_DEFAULT_RUNTIME" == apptainer ]]; then
    printf '    DefRuntimePlugin=runtime/apptainer\n'
  fi
  cat <<CONFIG
nodes:
  - role: controller
  - role: worker
    count: $WORKERS
CONFIG
}

up() {
  mkdir -p "$STATE"
  rm -f "$STATE/apptainer.conf"

  if ! echo "$ALPINE_SHA256  $STATE/alpine-minirootfs.tar.gz" | sha256sum --check --status 2>/dev/null; then
    log "download the root file system of Alpine Linux"
    curl -fsSL --retry 3 -o "$STATE/alpine-minirootfs.tar.gz" "$ALPINE_URL"
    echo "$ALPINE_SHA256  $STATE/alpine-minirootfs.tar.gz" | sha256sum --check --quiet
  fi

  log "create the cluster $SIND_CLUSTER (DefRuntimePlugin: $E2E_DEFAULT_RUNTIME)"
  cluster_config >"$STATE/cluster.yaml"
  (cd "$ROOT" && sind create cluster --config "$STATE/cluster.yaml")

  # All nodes mount one configuration volume at /etc/slurm, and only the
  # controller can write it. The link lets a test change apptainer.conf of
  # all nodes with one file in the state directory.
  sind ssh controller -- ln -sfn "$E2E_NODE_DIR/apptainer.conf" /etc/slurm/apptainer.conf

  # root builds the image: a build without privileges needs a /tmp that
  # permits the execution of programs, which the nodes do not have.
  log "build the test image $E2E_SIF"
  sind exec -- bash -s <<SCRIPT
set -euo pipefail
rm -rf /var/tmp/e2e
mkdir -p /var/tmp/e2e/rootfs /var/tmp/e2e/tmp "$(dirname "$E2E_SIF")"
tar -xzf $E2E_NODE_DIR/alpine-minirootfs.tar.gz -C /var/tmp/e2e/rootfs
APPTAINER_TMPDIR=/var/tmp/e2e/tmp apptainer build --force $E2E_SIF /var/tmp/e2e/rootfs
chmod 644 $E2E_SIF
rm -rf /var/tmp/e2e

# An image with the layout of the node but without /usr: a test binds /usr
# of the node, and a program of the node runs in the container.
rm -rf $E2E_NODE_OS
mkdir -p $E2E_NODE_OS/{dev,etc,home,proc,run,sys,tmp,usr,var/tmp}
for dir in bin lib lib64 sbin; do
  ln -s usr/\$dir $E2E_NODE_OS/\$dir
done
SCRIPT

  sind exec -- scontrol version
  sind exec -- sinfo
  sind exec -- srun --runtime=list

  log "start a step without a container on each worker"
  sind exec -u alice -- srun -N"$WORKERS" hostname
}

run_tests() {
  cd "$ROOT"
  if (($# == 0)); then
    set -- tests/e2e
  fi
  bats --print-output-on-failure "$@" | tee "$STATE/bats.tap"
}

# A short report for a CI log: the tests that failed, and the most frequent
# error messages of slurmd and slurmstepd on the first worker.
summary() {
  if [[ -r "$STATE/bats.tap" ]]; then
    printf 'passed: %s, failed: %s\n' \
      "$(grep -c '^ok ' "$STATE/bats.tap")" "$(grep -c '^not ok ' "$STATE/bats.tap")"
    grep '^not ok ' "$STATE/bats.tap" | cut -c1-100 | head -n 50
  else
    echo "no test results: the cluster did not start"
  fi
  if [[ -r "$STATE/logs/worker-0.log" ]]; then
    echo "errors in the log of worker-0:"
    grep -E '(slurmd|slurmstepd)\[[0-9]+\]: ' "$STATE/logs/worker-0.log" |
      grep -i -E 'error|fatal|fail' |
      sed -E 's/^.*(slurmd|slurmstepd)\[[0-9]+\]: //; s/[0-9]+/N/g' |
      sort | uniq -c | sort -rn | cut -c1-220 | head -n 25
  fi
}

logs() {
  local node

  mkdir -p "$STATE/logs"
  for node in controller $(seq -f 'worker-%g' 0 $((WORKERS - 1))); do
    # The complete journal: slurmstepd is not in the unit of slurmd.
    sind ssh "$node" -- journalctl --no-pager \
      >"$STATE/logs/$node.log" 2>&1 || true
  done
  log "logs of the nodes: $STATE/logs"
}

down() {
  sind delete cluster "$SIND_CLUSTER" || true
}

# Each step runs as a process of its own, so that a command that fails
# stops the step, and the logs and the cluster are handled after it.
all() {
  local status=0

  "$0" image
  "$0" up && "$0" test "$@" || status=$?
  if ((status != 0)); then
    logs
  fi
  if [[ -z "$E2E_KEEP" ]]; then
    down
  fi
  return "$status"
}

case "${1:-all}" in
  image) image ;;
  up) up ;;
  test) shift && run_tests "$@" ;;
  logs) logs ;;
  summary) summary ;;
  down) down ;;
  all) shift || true && all "$@" ;;
  *) echo "usage: $0 [image|up|test|logs|summary|down]" >&2 && exit 2 ;;
esac
