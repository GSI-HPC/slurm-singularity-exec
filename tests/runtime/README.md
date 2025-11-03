# Runtime Integration Tests

This directory contains integration tests that verify the slurm-singularity-exec plugin works with actual Slurm daemons.

## Overview

The runtime tests:
1. Start a minimal Slurm cluster (slurmctld + slurmd) using Docker Compose
2. Build and install the slurm-singularity-exec plugin
3. Verify plugin files are installed (library and configuration)
4. Verify plugin CLI options appear in `sbatch --help` and `srun --help`
5. Verify SPANK plugin loads when jobs run (check slurmd logs)
6. Submit and run a containerized test job (if singularity/apptainer is available)

## Docker Compose Architecture

### Services

The test infrastructure consists of three services orchestrated by Docker Compose:

| Service | Purpose | Startup Order |
|---------|---------|---------------|
| **plugin-builder** | Builds the plugin once using CMake/Ninja | 1st (runs to completion) |
| **slurmctld** | Slurm controller - manages scheduling and cluster state | 2nd (after builder) |
| **slurmd** | Slurm compute node - executes jobs | 3rd (after builder and slurmctld) |

### Volumes

| Volume | Containers | Access | Purpose |
|--------|------------|--------|---------|
| `../..` → `/workspace` | All | Read-only (`:z`) | Source code and build scripts |
| `plugin-build` | All | Read-write | Shared build artifacts (plugin binaries) |
| `slurmctld-state` | slurmctld | Read-write | Controller state persistence |
| `slurmd-state` | slurmd | Read-write | Daemon state persistence |
| `munge-key` | slurmctld, slurmd | Read-write | Shared Munge authentication key |
| `job-spool` | slurmctld, slurmd | Read-write | Shared job output files |

### Build Flow

1. **plugin-builder** service:
   - Runs `entrypoint-plugin-builder.sh`
   - Configures and builds plugin with CMake to `/var/lib/slurm-plugin-build`
   - Exits when build completes (dependency satisfied)

2. **slurmctld** service (waits for plugin-builder):
   - Runs `entrypoint-slurmctld.sh`
   - Installs pre-built plugin from shared volume
   - Generates Munge authentication key
   - Starts slurmctld daemon

3. **slurmd** service (waits for plugin-builder and slurmctld):
   - Runs `entrypoint-slurmd.sh`
   - Installs pre-built plugin from shared volume
   - Waits for Munge key and slurmctld connectivity
   - Starts slurmd daemon

### Network

All services communicate via the `slurm-net` bridge network, allowing hostname-based service discovery.

## Quick Start

```bash
# Validate the setup
./validate-setup.sh

# Run the full integration tests
./run-tests.sh
```

## Files

- `Dockerfile` - Container image for Slurm cluster nodes
- `docker-compose.yml` - Orchestrates the Slurm cluster (plugin-builder, slurmctld, slurmd)
- `slurm-common.conf` - Common Slurm configuration settings
- `slurm-24.11.conf` - Version-specific Slurm configuration
- `plugstack.conf` - Plugin loading configuration
- `cgroup.conf` - Cgroup configuration
- `setup-slurm-config.sh` - Version detection and config selection
- `entrypoint-plugin-builder.sh` - Builds the plugin (runs once)
- `entrypoint-slurmctld.sh` - Startup script for controller node
- `entrypoint-slurmd.sh` - Startup script for compute node
- `test-integration.sh` - Integration test suite
- `run-tests.sh` - Test orchestration script
- `validate-setup.sh` - Quick validation of the setup

## Requirements

- Docker
- Docker Compose

## CI/CD

These tests run automatically in GitHub Actions for each push and pull request, testing against:
- Slurm 24.11 (Ubuntu 25.04 Plucky)

## Troubleshooting

If tests fail, check the logs:
```bash
cd tests/runtime
docker compose logs slurmctld
docker compose logs slurmd
```

Clean up containers:
```bash
docker compose down -v
```
