#!/bin/bash
# Quick validation script to check the runtime test setup

set -e

echo "=== Runtime Test Setup Validation ==="
echo

# Check 1: Validate Docker is available
echo "Check 1: Docker availability..."
if ! command -v docker >/dev/null 2>&1; then
    echo "✗ ERROR: Docker not found"
    exit 1
fi
echo "✓ Docker is available"
echo

# Check 2: Validate Docker Compose is available
echo "Check 2: Docker Compose availability..."
if ! docker compose version >/dev/null 2>&1; then
    echo "✗ ERROR: Docker Compose not found"
    exit 1
fi
echo "✓ Docker Compose is available"
echo

# Check 3: Validate docker-compose.yml syntax
echo "Check 3: Validating docker-compose.yml..."
cd "$(dirname "$0")"
if ! docker compose config >/dev/null 2>&1; then
    echo "✗ ERROR: docker-compose.yml has syntax errors"
    exit 1
fi
echo "✓ docker-compose.yml is valid"
echo

# Check 4: Validate Dockerfile can be built
echo "Check 4: Building Docker image..."
if ! docker build -f Dockerfile -t slurm-test:validation --build-arg UBUNTU_VERSION=${UBUNTU_VERSION:-noble} ../.. 2>&1 | tail -5; then
    echo "✗ ERROR: Failed to build Docker image"
    exit 1
fi
echo "✓ Docker image builds successfully"
echo

# Check 5: Validate shell scripts syntax
echo "Check 5: Validating shell scripts..."
for script in entrypoint-slurmctld.sh entrypoint-slurmd.sh test-integration.sh run-tests.sh; do
    if ! bash -n "$script"; then
        echo "✗ ERROR: $script has syntax errors"
        exit 1
    fi
    echo "  ✓ $script syntax is valid"
done
echo

echo "=== All validation checks passed! ==="
echo
echo "The runtime test infrastructure is ready."
echo "To run the full integration tests, execute: ./run-tests.sh"
echo
exit 0
