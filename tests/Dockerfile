# Dockerfile for testing slurm-singularity-exec
# Mirrors the GitHub Actions workflow environment

ARG UBUNTU_VERSION=noble
FROM ubuntu:${UBUNTU_VERSION}

# Install build and test dependencies
RUN apt-get update -y && \
    apt-get install -y \
        cmake \
        g++ \
        ninja-build \
        libslurm-dev \
        bats \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /workspace

# Default build directory (can be overridden via BUILD_DIR env var)
ENV BUILD_DIR=build

# Default command: clean, configure, build, and test
CMD rm -rf ${BUILD_DIR} && \
    cmake -GNinja -S . -B ${BUILD_DIR} && \
    cmake --build ${BUILD_DIR} && \
    ctest --test-dir ${BUILD_DIR} --output-on-failure
