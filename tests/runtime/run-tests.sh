#!/bin/bash
# Runner script for integration tests
# This script orchestrates the docker-compose cluster and runs tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
# Give slurmctld up to 30 seconds to start (15 retries * 2 seconds)
RETRIES=15
DELAY=2
for i in $(seq 1 $RETRIES); do
    if docker compose exec -T slurmctld scontrol ping >/dev/null 2>&1; then
        echo "✓ Slurm cluster is ready (attempt $i/$RETRIES)"
        break
    fi
    if [ $i -eq $RETRIES ]; then
        echo "ERROR: slurmctld not ready after $((RETRIES * DELAY)) seconds"
        docker compose logs slurmctld
        exit 1
    fi
    sleep $DELAY
done
echo "::endgroup::"

echo "::group::Run integration tests"
set +e  # Temporarily disable exit on error
docker compose exec -T slurmctld /workspace/tests/runtime/test-integration.sh
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
    echo "::group::slurmctld logs (last 100 lines)"
    docker compose logs --tail=100 slurmctld
    echo "::endgroup::"

    echo "::group::slurmd logs (last 100 lines)"
    docker compose logs --tail=100 slurmd
    echo "::endgroup::"

    echo "::group::Container status"
    docker compose ps
    echo "::endgroup::"
fi

echo "::group::Clean up"
docker compose down -v
echo "::endgroup::"

exit $TEST_EXIT_CODE
