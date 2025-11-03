#!/bin/bash
# Common script to setup Slurm configuration based on version
# Usage: source setup-slurm-config.sh <daemon-name>
#   daemon-name: slurmctld or slurmd

set -e

DAEMON_NAME="$1"

if [[ -z "$DAEMON_NAME" ]]; then
    echo "ERROR: Daemon name required (slurmctld or slurmd)"
    exit 1
fi

# Detect Slurm version and use appropriate config
# Handle both "slurm X.Y.Z" and "slurm-wlm X.Y.Z" formats
SLURM_VERSION=$($DAEMON_NAME -V | grep -oP 'slurm(-wlm)? \K[0-9]+\.[0-9]+' || echo "unknown")
echo "Detected Slurm version: $SLURM_VERSION"

# Copy common config first
cp /workspace/tests/runtime/slurm-common.conf /etc/slurm/slurm-common.conf

# Copy version-specific config
if [[ "$SLURM_VERSION" == "24.11" ]]; then
    echo "Using Slurm 24.11 configuration (proctrack/linuxproc)"
    cp /workspace/tests/runtime/slurm-24.11.conf /etc/slurm/slurm.conf
elif [[ "$SLURM_VERSION" == "unknown" ]]; then
    echo "ERROR: Could not detect Slurm version"
    echo "The daemon '$DAEMON_NAME -V' command failed or produced unexpected output"
    echo "Please ensure Slurm is properly installed and accessible"
    exit 1
else
    echo "ERROR: Unsupported Slurm version: $SLURM_VERSION"
    echo "Only version 24.11 is currently supported"
    echo "If you are using a newer version, please add configuration in tests/runtime/"
    exit 1
fi

cp /workspace/tests/runtime/plugstack.conf /etc/slurm/plugstack.conf
cp /workspace/tests/runtime/cgroup.conf /etc/slurm/cgroup.conf

echo "Slurm configuration setup complete"
