#!/bin/bash
# Integration test script for runtime functionality testing
# This script runs inside a container and tests the Slurm-Singularity plugin

set -e

echo "=== Slurm Singularity Plugin Runtime Tests ==="
echo

# Test 1: Verify plugin files are installed
echo "Test 1: Verifying plugin installation..."
if [ -f "/usr/libexec/slurm-singularity-exec.so" ]; then
    echo "✓ Found plugin library: /usr/libexec/slurm-singularity-exec.so"
else
    echo "✗ ERROR: Plugin library not found at /usr/libexec/slurm-singularity-exec.so"
    exit 1
fi

if [ -f "/etc/slurm/plugstack.conf.d/singularity-exec.conf" ]; then
    echo "✓ Found plugin config: /etc/slurm/plugstack.conf.d/singularity-exec.conf"
else
    echo "✗ ERROR: Plugin config not found at /etc/slurm/plugstack.conf.d/singularity-exec.conf"
    exit 1
fi
echo

# Test 2: Check plugin CLI options in sbatch --help
echo "Test 2: Checking plugin CLI options in sbatch --help..."
if sbatch --help 2>&1 | grep -q "singularity-container"; then
    echo "✓ Found --singularity-container option"
else
    echo "✗ ERROR: --singularity-container option not found in sbatch --help"
    exit 1
fi

if sbatch --help 2>&1 | grep -q "singularity-bind"; then
    echo "✓ Found --singularity-bind option"
else
    echo "✗ ERROR: --singularity-bind option not found in sbatch --help"
    exit 1
fi

if sbatch --help 2>&1 | grep -q "singularity-args"; then
    echo "✓ Found --singularity-args option"
else
    echo "✗ ERROR: --singularity-args option not found in sbatch --help"
    exit 1
fi

if sbatch --help 2>&1 | grep -q "singularity-no-bind-defaults"; then
    echo "✓ Found --singularity-no-bind-defaults option"
else
    echo "✗ ERROR: --singularity-no-bind-defaults option not found in sbatch --help"
    exit 1
fi
echo

# Test 3: Check plugin CLI options in srun --help
echo "Test 3: Checking plugin CLI options in srun --help..."
if srun --help 2>&1 | grep -q "singularity-container"; then
    echo "✓ Found --singularity-container option in srun"
else
    echo "✗ ERROR: --singularity-container option not found in srun --help"
    exit 1
fi
echo

# Test 4: Check if singularity/apptainer is available
echo "Test 4: Checking for singularity/apptainer..."
SINGULARITY_CMD=""
if command -v singularity >/dev/null 2>&1; then
    SINGULARITY_CMD="singularity"
    echo "✓ Found singularity command"
elif command -v apptainer >/dev/null 2>&1; then
    SINGULARITY_CMD="apptainer"
    echo "✓ Found apptainer command"
else
    echo "⚠ Warning: Neither singularity nor apptainer found. Skipping container job test."
    SKIP_CONTAINER_TEST=true
fi
echo

# Test 5: Create a simple test container (if singularity/apptainer available)
if [ "$SKIP_CONTAINER_TEST" != "true" ]; then
    echo "Test 5: Creating a test container image..."
    # Use shared directory so container is accessible from both slurmctld and slurmd
    TEST_CONTAINER="/var/spool/slurm-jobs/test-debian.sif"
    if [ ! -f "$TEST_CONTAINER" ]; then
        # Create a minimal Debian container
        $SINGULARITY_CMD pull "$TEST_CONTAINER" docker://debian:stable-slim
        if [ $? -eq 0 ]; then
            echo "✓ Test container created: $TEST_CONTAINER"
        else
            echo "⚠ Warning: Failed to create test container. Skipping container job test."
            SKIP_CONTAINER_TEST=true
        fi
    else
        echo "✓ Test container already exists: $TEST_CONTAINER"
    fi
    echo
fi

# Test 6: Wait for Slurm to be ready
echo "Test 6: Waiting for Slurm cluster to be ready..."
if ! retry --times=30 --delay=2 -- scontrol ping >/dev/null 2>&1; then
    echo "✗ ERROR: Slurm controller not responding"
    exit 1
fi
echo "✓ Slurm controller is responding"

# Wait for node to be ready
if ! retry --times=30 --delay=2 -- bash -c 'sinfo -h -o "%T" 2>/dev/null | grep -qE "idle|mixed|alloc"'; then
    echo "✗ ERROR: No compute nodes are ready"
    echo "Showing sinfo output:"
    sinfo
    echo
    echo "Showing last 50 lines of slurmd logs:"
    tail -50 /var/log/slurm/slurmd.log 2>/dev/null || echo "Could not read slurmd logs"
    echo
    echo "Showing last 50 lines of slurmctld logs:"
    tail -50 /var/log/slurm/slurmctld.log 2>/dev/null || echo "Could not read slurmctld logs"
    exit 1
fi
echo "✓ Compute node is ready"
echo

# Show cluster status
echo "Cluster status:"
sinfo
echo

# Test 7: Verify job submission works (triggers SPANK plugin)
echo "Test 7: Verifying job submission works..."
# Submit a simple test job to verify Slurm is functional and trigger plugin loading
TEST_JOB_ID=$(sbatch --wrap="echo 'Test job running'; sleep 1" --output=/dev/null 2>&1 | awk '{print $NF}')
if [ -z "$TEST_JOB_ID" ]; then
    echo "✗ ERROR: Failed to submit test job"
    exit 1
fi

# Wait for job to complete
echo "  Waiting for job $TEST_JOB_ID to complete..."
retry --times=30 --delay=1 -- bash -c "scontrol show job $TEST_JOB_ID 2>/dev/null | grep -qE 'JobState=(COMPLETED|FAILED|CANCELLED)'" >/dev/null 2>&1

JOB_STATE=$(scontrol show job "$TEST_JOB_ID" 2>/dev/null | grep "JobState" | awk '{print $1}' | cut -d= -f2)
if [ "$JOB_STATE" = "COMPLETED" ]; then
    echo "✓ Test job completed successfully (JobID: $TEST_JOB_ID)"
elif [ "$JOB_STATE" = "COMPLETING" ]; then
    echo "✓ Test job completed (JobID: $TEST_JOB_ID)"
else
    echo "✗ ERROR: Test job did not complete properly (State: $JOB_STATE)"
    scontrol show job "$TEST_JOB_ID"
    exit 1
fi
echo

# Test 8: Submit a containerized test job (if container available)
if [ "$SKIP_CONTAINER_TEST" != "true" ]; then
    echo "Test 8: Submitting a containerized test job..."
JOB_SCRIPT=$(mktemp /tmp/test_job.XXXXXX.sh)
cat > "$JOB_SCRIPT" <<'JOBEOF'
#!/bin/bash
#SBATCH --job-name=test-singularity
#SBATCH --output=/var/spool/slurm-jobs/test_job_%j.out
#SBATCH --error=/var/spool/slurm-jobs/test_job_%j.err
#SBATCH --partition=debug
#SBATCH --time=00:01:00
#SBATCH --nodes=1
#SBATCH --ntasks=1

echo "Job started at: $(date)"
echo "Running on node: $(hostname)"
echo "Job ID: $SLURM_JOB_ID"

# Test command inside container
cat /etc/os-release | grep -i pretty

echo "Job completed at: $(date)"
JOBEOF

chmod +x "$JOB_SCRIPT"

# Submit the job with the container
JOB_ID=$(sbatch --singularity-container="$TEST_CONTAINER" "$JOB_SCRIPT" | awk '{print $NF}')
if [ -n "$JOB_ID" ]; then
    echo "✓ Job submitted successfully: Job ID $JOB_ID"
else
    echo "✗ ERROR: Failed to submit job"
    exit 1
fi
echo

# Test 9: Wait for job to complete
echo "Test 9: Waiting for job to complete..."
max_wait=120
waited=0
while true; do
    JOB_STATE=$(scontrol show job "$JOB_ID" 2>/dev/null | grep "JobState=" | sed 's/.*JobState=\([^ ]*\).*/\1/')
    
    if [ "$JOB_STATE" = "COMPLETED" ]; then
        echo "✓ Job completed successfully"
        break
    elif [ "$JOB_STATE" = "FAILED" ] || [ "$JOB_STATE" = "CANCELLED" ] || [ "$JOB_STATE" = "TIMEOUT" ]; then
        echo "✗ ERROR: Job failed with state: $JOB_STATE"
        scontrol show job "$JOB_ID"
        exit 1
    elif [ $waited -ge $max_wait ]; then
        echo "✗ ERROR: Job did not complete within ${max_wait}s"
        scontrol show job "$JOB_ID"
        scancel "$JOB_ID"
        exit 1
    fi
    
    echo "  Job state: $JOB_STATE (${waited}s/${max_wait}s)"
    sleep 3
    waited=$((waited + 3))
done
echo

# Test 10: Check job output
echo "Test 10: Checking job output..."
JOB_OUTPUT="/var/spool/slurm-jobs/test_job_${JOB_ID}.out"
if [ -f "$JOB_OUTPUT" ]; then
    echo "Job output:"
    cat "$JOB_OUTPUT"
    echo
    
    if grep -q "PRETTY_NAME" "$JOB_OUTPUT"; then
        echo "✓ Job produced expected output (found PRETTY_NAME)"
    else
        echo "✗ ERROR: Job output does not contain expected content"
        exit 1
    fi
else
    echo "✗ ERROR: Job output file not found: $JOB_OUTPUT"
    exit 1
fi
echo

# Test 11: Run containerized job via srun with multi-argument command
echo "Test 11: Testing srun with multi-argument command (bugfix from v3.2.0)..."
# This tests the fix for properly handling multi-argument commands in containerized srun jobs
SRUN_OUTPUT=$(mktemp /tmp/srun_output.XXXXXX)
if srun --singularity-container="$TEST_CONTAINER" /bin/bash -c 'echo "arg1 arg2 arg3"' > "$SRUN_OUTPUT" 2>&1; then
    if grep -q "arg1 arg2 arg3" "$SRUN_OUTPUT"; then
        echo "✓ srun multi-argument command executed successfully"
        echo "  Output: $(cat $SRUN_OUTPUT)"
    else
        echo "✗ ERROR: srun output does not contain expected content"
        echo "  Expected: 'arg1 arg2 arg3'"
        echo "  Got: $(cat $SRUN_OUTPUT)"
        rm -f "$SRUN_OUTPUT"
        exit 1
    fi
else
    echo "✗ ERROR: srun command failed"
    echo "  Output: $(cat $SRUN_OUTPUT)"
    rm -f "$SRUN_OUTPUT"
    exit 1
fi
rm -f "$SRUN_OUTPUT"
echo

else
    echo "Skipping containerized job tests (no singularity/apptainer available)"
    echo
fi

echo "=== All tests passed! ==="
exit 0
