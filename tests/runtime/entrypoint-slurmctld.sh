#!/bin/bash
# Entrypoint script for slurmctld container

set -e

echo "Starting slurmctld container..."

# Setup Slurm configuration (version detection and config files)
source /workspace/tests/runtime/setup-slurm-config.sh slurmctld

# Install the pre-built plugin
echo "Installing slurm-singularity-exec plugin..."
BUILD_DIR="/var/lib/slurm-plugin-build"
cmake --install "$BUILD_DIR"
echo "Plugin installed in slurmctld"

echo "Plugin configuration:"
cat /etc/slurm/plugstack.conf.d/singularity-exec.conf

# Create Munge key if it doesn't exist (shared volume)
if [ ! -f /etc/munge/munge.key ]; then
    echo "Creating Munge key..."
    dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
else
    echo "Munge key already exists, ensuring correct permissions..."
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
fi

# Start Munge
echo "Starting Munge..."
mkdir -p /var/run/munge
chown munge:munge /var/run/munge
sudo -u munge /usr/sbin/munged --force

# Wait for Munge to be ready and verify it works
echo "Verifying Munge functionality..."
if ! retry --times=10 --delay=1 -- bash -c 'echo "test" | munge | unmunge >/dev/null 2>&1'; then
    echo "ERROR: Munge failed to start properly"
    exit 1
fi
echo "✓ Munge is operational"

# Start slurmctld
echo "Starting slurmctld..."
mkdir -p /var/spool/slurmctld /var/run/slurm
chown -R slurm:slurm /var/spool/slurmctld /var/run/slurm

# Start slurmctld in foreground
echo "Starting slurmctld daemon..."
exec /usr/sbin/slurmctld -D -vvvv
