# Dockerfile for runtime testing of slurm-singularity-exec
# Sets up a complete Slurm cluster with controller and compute nodes

ARG UBUNTU_VERSION=25.04
FROM ubuntu:${UBUNTU_VERSION}

# Install Slurm, Munge, and dependencies
RUN apt-get update -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        slurm-wlm \
        slurm-wlm-basic-plugins \
        slurmd \
        slurmctld \
        munge \
        cmake \
        g++ \
        ninja-build \
        libslurm-dev \
        curl \
        sudo \
        retry \
    && rm -rf /var/lib/apt/lists/*

# Try to install singularity-container if available (may not be in all Ubuntu versions)
RUN apt-get update -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y singularity-container || true \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories and files
RUN mkdir -p /var/spool/slurmctld \
             /var/spool/slurmd \
             /var/spool/slurm \
             /var/run/slurm \
             /etc/slurm \
             /etc/slurm/plugstack.conf.d \
    && chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/spool/slurm /var/run/slurm \
    && touch /etc/localtime

# Set working directory
WORKDIR /workspace

# Default command will be overridden in docker-compose
CMD ["/bin/bash"]
