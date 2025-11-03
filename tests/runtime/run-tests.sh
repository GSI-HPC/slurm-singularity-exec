#!/bin/bash
# Runner script for integration tests
# This script orchestrates the docker-compose cluster and runs tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration - can be overridden via environment variables
: "${RETRY_TIMES:=15}"
: "${RETRY_DELAY:=2}"
: "${JOB_RETRY_DELAY:=1}"
: "${JOB_MAX_WAIT:=120}"
: "${JOB_POLL_INTERVAL:=3}"
: "${LOG_TAIL_LINES:=100}"

echo "::group::Clean up previous containers"
docker compose down -v 2>/dev/null || true
echo "::endgroup::"

echo "::group::Build Docker images with buildx cache"
# Build both services using buildx bake for proper cache support
# Set BUILDX_BAKE_ENTITLEMENTS_FS=0 to allow filesystem access without explicit --allow flags
export BUILDX_BAKE_ENTITLEMENTS_FS=0

# If BUILDX_CACHE_FROM/TO are set, use them; otherwise build without cache
if [ -n "${BUILDX_CACHE_FROM}" ] && [ -n "${BUILDX_CACHE_TO}" ]; then
  docker buildx bake \
    --file docker-compose.yml \
    --set "*.cache-from=${BUILDX_CACHE_FROM}" \
    --set "*.cache-to=${BUILDX_CACHE_TO}" \
    --load \
    slurmctld slurmd
else
  docker buildx bake \
    --file docker-compose.yml \
    --load \
    slurmctld slurmd
fi
echo "::endgroup::"

echo "::group::Start Slurm cluster"
docker compose up -d --no-build
echo "::endgroup::"

echo "::group::Wait for services"
echo "Waiting for slurmctld to be ready..."
# Give slurmctld up to RETRY_TIMES * RETRY_DELAY seconds to start
for i in $(seq 1 $RETRY_TIMES); do
    if docker compose exec -T slurmctld scontrol ping >/dev/null 2>&1; then
        echo "✓ Slurm cluster is ready (attempt $i/$RETRY_TIMES)"
        break
    fi
    if [ $i -eq $RETRY_TIMES ]; then
        echo "ERROR: slurmctld not ready after $((RETRY_TIMES * RETRY_DELAY)) seconds"
        docker compose logs slurmctld
        exit 1
    fi
    sleep $RETRY_DELAY
done
echo "::endgroup::"

echo "::group::Run integration tests"
set +e  # Temporarily disable exit on error
docker compose exec -T \
    -e RETRY_TIMES="$RETRY_TIMES" \
    -e RETRY_DELAY="$RETRY_DELAY" \
    -e JOB_RETRY_DELAY="$JOB_RETRY_DELAY" \
    -e JOB_MAX_WAIT="$JOB_MAX_WAIT" \
    -e JOB_POLL_INTERVAL="$JOB_POLL_INTERVAL" \
    slurmctld /workspace/tests/runtime/test-integration.sh
TEST_EXIT_CODE=$?
set -e  # Re-enable exit on error
echo "::endgroup::"

# Additional verification: Check for SPANK plugin loading in slurmd container logs
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "::group::Verify SPANK plugin loading in logs"
    if docker compose logs slurmd 2>&1 | grep -q "Loaded plugin slurm-singularity-exec.so"; then
        echo "✓ Found SPANK plugin loading message in slurmd container logs"
    else
        echo "⚠ Warning: SPANK plugin loading message not found in slurmd logs"
        echo "  This may indicate the plugin is not being loaded by slurmstepd"
    fi
    echo "::endgroup::"
fi

# Show logs if tests failed
if [ $TEST_EXIT_CODE -ne 0 ]; then
    echo "::group::slurmctld logs (last $LOG_TAIL_LINES lines)"
    docker compose logs --tail="$LOG_TAIL_LINES" slurmctld
    echo "::endgroup::"

    echo "::group::slurmd logs (last $LOG_TAIL_LINES lines)"
    docker compose logs --tail="$LOG_TAIL_LINES" slurmd
    echo "::endgroup::"

    echo "::group::Container status"
    docker compose ps
    echo "::endgroup::"
fi

echo "::group::Clean up"
docker compose down -v
echo "::endgroup::"

exit $TEST_EXIT_CODE
