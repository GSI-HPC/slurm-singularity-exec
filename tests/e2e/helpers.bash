# shellcheck shell=bash
# The assert functions examine the variables that "run" of bats sets.
# shellcheck disable=SC2154
#
# Helpers of the end-to-end tests. Loaded by each .bats file.
#
# The tests run on the Docker host of a sind cluster (tests/e2e/run.sh
# creates it), or with E2E_BACKEND=local on a host that is a Slurm node
# itself. They use these variables:
#
#   E2E_BACKEND    sind (default) or local
#   E2E_USER       user that submits the jobs (default: alice)
#   E2E_HOST_DIR   state directory of the tests, as this shell sees it
#   E2E_NODE_DIR   the same directory, as the cluster nodes see it
#   E2E_FIXTURES   tests/e2e/fixtures, as the cluster nodes see it
#   E2E_SIF        test image, as the cluster nodes see it (default:
#                  alpine.sif in the state directory)
#   E2E_NODES      number of worker nodes (default: 2)
#   E2E_NODE_OS    image with the system directories of a node but without
#                  /usr, which a test binds into the container. A program
#                  of the node runs in it. (default: none, the tests that
#                  use it are skipped)
#   E2E_PMIX_CLIENT
#                  PMIx client in /usr of the nodes, built from
#                  fixtures/pmix_client.c (default: none, the tests that
#                  use it are skipped)
#   E2E_DEFAULT_RUNTIME
#                  DefRuntimePlugin of the cluster: apptainer or oci
#                  (default). With oci, the test user selects the plugin
#                  with the SRUN_RUNTIME, SBATCH_RUNTIME and SALLOC_RUNTIME
#                  variables.
#
# apptainer.conf of the cluster is a symbolic link to apptainer.conf in the
# state directory, so a test changes the configuration of all nodes with one
# file.

: "${E2E_BACKEND:=sind}"
: "${E2E_USER:=alice}"
: "${E2E_NODES:=2}"
: "${E2E_DEFAULT_RUNTIME:=oci}"
: "${E2E_HOST_DIR:?}"
: "${E2E_NODE_DIR:?}"
: "${E2E_FIXTURES:?}"
: "${E2E_SIF:=$E2E_NODE_DIR/alpine.sif}"
: "${E2E_NODE_OS:=}"
: "${E2E_PMIX_CLIENT:=}"

# as_user COMMAND...: run a command as the test user on the submit node.
as_user() {
  case "$E2E_BACKEND" in
    sind) sind exec -u "$E2E_USER" -- "$@" ;;
    local) runuser -u "$E2E_USER" -- env "PATH=${E2E_SLURM_BIN:+$E2E_SLURM_BIN:}$PATH" "$@" ;;
    *) echo "unknown E2E_BACKEND: $E2E_BACKEND" >&2 && return 2 ;;
  esac
}

# user_sh: run stdin as a bash script as the test user on the submit node.
# The script starts in the home directory of the user, which all nodes
# share, with these variables:
#
#   SIF     test image (Alpine Linux)
#   PROBE   script that prints the properties of a task, in the home
#           directory, which Apptainer binds into each container
#   FIX     directory of the fixtures
#   NODES   number of worker nodes
#   NODE_OS, PMIX_CLIENT
#           E2E_NODE_OS and E2E_PMIX_CLIENT
#
# The script is stored in a file first. Its standard input is empty, so
# that an srun in the script cannot read the remaining lines of the script.
#
# The shell of the test user expands the variables in the single quotes.
# shellcheck disable=SC2016
user_sh() {
  {
    printf 'cd || exit 1\n'
    printf 'export SIF=%q FIX=%q NODES=%q PROBE=$HOME/probe.sh\n' \
      "$E2E_SIF" "$E2E_FIXTURES" "$E2E_NODES"
    printf 'export NODE_OS=%q PMIX_CLIENT=%q\n' "$E2E_NODE_OS" "$E2E_PMIX_CLIENT"
    printf 'cp -p "$FIX/probe.sh" "$PROBE" || exit 1\n'
    if [[ "$E2E_DEFAULT_RUNTIME" != apptainer ]]; then
      printf 'export SRUN_RUNTIME=apptainer SBATCH_RUNTIME=apptainer SALLOC_RUNTIME=apptainer\n'
    fi
    cat
  } | as_user bash -c 'cat >"$HOME/.e2e-script.sh"' || return 2
  as_user bash -c 'exec bash "$HOME/.e2e-script.sh"' </dev/null
}

# conf_write: make stdin the apptainer.conf of all nodes.
conf_write() {
  cat >"$E2E_HOST_DIR/apptainer.conf"
  chmod 644 "$E2E_HOST_DIR/apptainer.conf"
}

# conf_remove: remove apptainer.conf from all nodes.
conf_remove() {
  rm -f "$E2E_HOST_DIR/apptainer.conf"
}

# assert_output_has WORD...: each word is in $output.
assert_output_has() {
  local word
  for word in "$@"; do
    if [[ "$output" != *"$word"* ]]; then
      printf 'expected in the output: %s\noutput:\n%s\n' "$word" "$output" >&2
      return 1
    fi
  done
}

# assert_output_lacks WORD...: no word is in $output.
assert_output_lacks() {
  local word
  for word in "$@"; do
    if [[ "$output" == *"$word"* ]]; then
      printf 'not expected in the output: %s\noutput:\n%s\n' "$word" "$output" >&2
      return 1
    fi
  done
}

# assert_status N: the exit status of the last run is N.
assert_status() {
  if [[ "$status" -ne "$1" ]]; then
    printf 'expected status %s, got %s\noutput:\n%s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}
