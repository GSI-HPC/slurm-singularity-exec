#!/bin/sh
# Print the properties of a task that the tests examine, as key=value words:
#
#   os      ID of the operating system of the root file system
#   in      name of the Apptainer container, or "host"
#   rank    SLURM_PROCID
#   tp      variable that the TaskProlog of the cluster sets
#   stack   soft limit of the stack size
#   weird   variable with shell special characters from the submit shell
#   cwd     working directory
#
# The script runs in bash on the nodes and in the ash of BusyBox in the test
# image. Both have "ulimit -S -s", which POSIX does not define.
# shellcheck disable=SC1091,SC3045
printf 'os=%s in=%s rank=%s tp=%s stack=%s weird=[%s] cwd=%s\n' \
  "$(. /etc/os-release && echo "$ID")" \
  "${APPTAINER_NAME:-host}" \
  "${SLURM_PROCID:-unset}" \
  "${TP_MARK:-unset}" \
  "$(ulimit -S -s)" \
  "${WEIRD:-unset}" \
  "$PWD"
