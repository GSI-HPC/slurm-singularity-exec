#!/bin/bash
# Entrypoint script for slurmd container

set -e

echo "Starting slurmd container..."

# Setup Slurm configuration (version detection and config files)
source /workspace/tests/runtime/setup-slurm-config.sh slurmd

# Install the pre-built plugin
echo "Installing slurm-singularity-exec plugin..."
BUILD_DIR="/var/lib/slurm-plugin-build"
cmake --install "$BUILD_DIR"
echo "Plugin installed in slurmd"

# Create loop devices for Singularity
echo "Creating loop devices for Singularity..."
for i in {0..7}; do
    mknod -m 0660 "/dev/loop$i" b 7 "$i" 2>/dev/null || true
done
chgrp disk /dev/loop* 2>/dev/null || true

# Wait for Munge key to be created by slurmctld
echo "Waiting for Munge key..."
if ! retry --times=30 --delay=1 -- test -f /etc/munge/munge.key; then
    echo "ERROR: Munge key not found"
    exit 1
fi

echo "Munge key found, ensuring correct permissions..."
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# Verify munge key
echo "Munge key info:"
ls -la /etc/munge/munge.key

# Start Munge
echo "Starting Munge..."
mkdir -p /var/run/munge /var/log/munge
chown munge:munge /var/run/munge /var/log/munge
sudo -u munge /usr/sbin/munged --force

# Wait for Munge to be ready
echo "Waiting for Munge to be ready..."
sleep 3

# Test Munge
echo "Testing Munge..."
munge -n | unmunge || echo "Warning: Munge test failed"

# Wait for slurmctld to be ready
echo "Waiting for slurmctld to respond..."
if ! retry --times=30 --delay=1 -- scontrol ping >/dev/null 2>&1; then
    echo "ERROR: slurmctld not responding"
    exit 1
fi
echo "✓ slurmctld is responding"

# Start slurmd
echo "Starting slurmd..."
mkdir -p /var/spool/slurmd /var/run/slurm /run/slurm
chown -R slurm:slurm /var/spool/slurmd /var/run/slurm
chmod 755 /var/spool/slurmd
chmod 755 /run/slurm

echo "Slurm configuration:"
grep -E "^(ClusterName|SlurmctldHost|NodeName|ProctrackType|TaskPlugin)" /etc/slurm/slurm.conf || true

# Verify slurmstepd exists and is executable
echo "Checking slurmstepd..."
if [ -f /usr/sbin/slurmstepd ]; then
    echo "✓ slurmstepd found at /usr/sbin/slurmstepd"
    ls -lh /usr/sbin/slurmstepd
    /usr/sbin/slurmstepd -V || echo "Warning: Could not get slurmstepd version"
else
    echo "✗ ERROR: slurmstepd not found!"
    exit 1
fi

# Start slurmd in foreground
echo "Starting slurmd daemon..."
exec /usr/sbin/slurmd -D -vvvv
