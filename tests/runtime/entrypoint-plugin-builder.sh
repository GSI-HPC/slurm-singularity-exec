#!/bin/bash
# Entrypoint script for plugin-builder service
# Builds the slurm-singularity-exec plugin once for installation in all Slurm containers

set -e

echo "Building slurm-singularity-exec plugin..."
SRC_DIR="/workspace"
BUILD_DIR="/var/lib/slurm-plugin-build"

cmake -GNinja -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DSLURM_SYSCONFDIR=/etc/slurm \
    -DINSTALL_PLUGSTACK_CONF=ON \
    -DPLUGIN_BIND_ARG="/etc/slurm,/var/spool/slurm,/var/spool/slurmd,/var/run/munge" \
    -DPLUGIN_GLOBAL_ARG="--silent"

cmake --build "$BUILD_DIR"

echo "Plugin built successfully"
