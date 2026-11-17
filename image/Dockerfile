# syntax=docker/dockerfile:1
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Node image for sind (https://github.com/GSI-HPC/sind) with Slurm 26.11.
#
# The image is the sind node image of Slurm 26.05 with three changes:
#
#   - Slurm 26.11, the first release with the runtime plugin interface,
#     replaces Slurm 26.05. It is built with the configure options of sind.
#   - Apptainer is installed from EPEL, without the setuid starter.
#   - /usr/src/slurm holds the headers of the configured Slurm source tree,
#     and meson and ninja are installed. A runtime plugin compiles in the
#     image against the Slurm that loads it:
#
#       meson setup build -Dslurm_source=/usr/src/slurm --prefix=/usr --libdir=lib64
#
# Build:
#   mise run image
#
# The image is for linux/amd64 only.

# The base image supplies Rocky Linux 10, systemd, munge, MariaDB, sshd and
# the MPI stack (UCX, PMIx, PRRTE, Open MPI) with libjwt.
ARG BASE_IMAGE=ghcr.io/gsi-hpc/sind-node:26.05.6@sha256:b32c9fa946b7dc3ebbc856c0af2690e1bb0f5abb1d05b2930791cef0d7a77401

# Slurm 26.11 has no release yet. The image builds a commit of the
# slurm-26.11 branch, which git verifies by its hash. SLURM_VERSION is the
# version that this commit reports. When SchedMD publishes 26.11.0, build
# the release tarball instead.
ARG SLURM_COMMIT=85de8ed517d6a1de84ee4fea5a46d2088edc64d6
ARG SLURM_VERSION=26.11.0-0rc2

# ==============================================================================
# Stage: slurm-builder: compile Slurm
# ==============================================================================
FROM ${BASE_IMAGE} AS slurm-builder

# The base image has the libraries of PMIx and libjwt with their headers.
# The other development packages are those of the Slurm build of sind.
# hadolint ignore=DL3041
RUN dnf -y install \
        bzip2 \
        dbus-devel \
        diffutils \
        flex \
        gcc \
        gcc-c++ \
        git-core \
        hwloc-devel \
        jansson-devel \
        json-c-devel \
        libbpf-devel \
        libevent-devel \
        llhttp-devel \
        make \
        mariadb-devel \
        munge-devel \
        openssl-devel \
        pam-devel \
        perl \
        perl-ExtUtils-MakeMaker \
        pkgconf \
        python3 \
        readline-devel \
        tar \
    && dnf clean all

ARG SLURM_COMMIT

# make install skips contribs/, so nss_slurm is built and installed on its
# own, as sind does. The image has no libtool .la files, and the debug
# sections are stripped from each ELF file except srun, whose MPIR symbols
# parallel debuggers read.
#
# The last step keeps the headers of the configured tree (config.h and
# slurm/slurm_version.h included), which a plugin for an internal interface
# of Slurm includes.
WORKDIR /tmp/slurm
RUN git init -q . && \
    git fetch -q --depth 1 https://github.com/SchedMD/slurm.git "${SLURM_COMMIT}" && \
    git checkout -q FETCH_HEAD && \
    test "$(git rev-parse HEAD)" = "${SLURM_COMMIT}" && \
    ./configure \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc/slurm \
        --localstatedir=/var \
        --runstatedir=/run \
        --disable-static \
        --with-munge \
        --with-pmix \
        --with-jwt \
        --with-json \
        --with-pam_dir=/usr/lib64/security \
        --with-systemdsystemunitdir=/usr/lib/systemd/system && \
    make -j"$(nproc)" && \
    make -j"$(nproc)" -C contribs/nss_slurm && \
    DESTDIR=/install make install && \
    DESTDIR=/install make -C contribs/nss_slurm install && \
    find /install -name '*.la' -delete && \
    find /install -type f ! -name srun \
        -exec sh -c 'test "$(head -c 4 "$1" | tail -c 3)" = ELF' sh {} \; \
        -exec strip --strip-debug {} + && \
    mkdir -p /install/usr/src/slurm && \
    find . -name '*.h' -exec cp --parents -t /install/usr/src/slurm {} + && \
    git rev-parse HEAD > /install/usr/src/slurm/COMMIT && \
    rm -rf /tmp/slurm/* /tmp/slurm/.git

# ==============================================================================
# Stage: node: the sind node image
# ==============================================================================
FROM ${BASE_IMAGE} AS node

# Apptainer comes from EPEL, which the base image enables. It runs
# containers without the setuid starter: it needs user namespaces and, to
# mount an image file, /dev/fuse in the node. gcc is in the base image;
# meson and ninja build a plugin in the image.
# hadolint ignore=DL3041
RUN dnf -y install \
        apptainer \
        meson \
        ninja-build \
        squashfs-tools \
    && dnf clean all

# Remove the plugins, the libraries and the headers of Slurm 26.05. The
# programs, the units and the manual pages have the same names in 26.11.
RUN rm -rf /usr/lib64/slurm /usr/lib64/libslurm* /usr/include/slurm

COPY --from=slurm-builder /install/usr /usr

ARG SLURM_VERSION

# Fail the build without the parts that sind and the plugin need.
RUN ldconfig && \
    slurmctld -V && \
    test "$(slurmctld -V)" = "slurm ${SLURM_VERSION}" && \
    test -e /usr/lib64/libnss_slurm.so.2 && \
    test -e /usr/lib64/slurm/auth_slurm.so && \
    test -e /usr/lib64/slurm/mpi_pmix.so && \
    test -e /usr/lib64/slurm/runtime_oci.so && \
    test -e /usr/lib64/slurm/serializer_json.so && \
    test -e /usr/src/slurm/config.h && \
    test -e /usr/src/slurm/slurm/slurm_version.h && \
    test -e /usr/src/slurm/src/interfaces/runtime.h && \
    test -x /usr/sbin/slurmrestd && \
    apptainer --version && \
    meson --version

ARG SLURM_COMMIT

# The labels replace those of the base image. The source label links the
# package in the GitHub Container Registry to the repository.
LABEL org.opencontainers.image.title="sind-node with Slurm 26.11 and Apptainer" \
      org.opencontainers.image.description="Slurm node for sind to test runtime plugins with Apptainer" \
      org.opencontainers.image.source="https://github.com/GSI-HPC/slurm-singularity-exec" \
      org.opencontainers.image.version="${SLURM_VERSION}" \
      sind.slurm.version="${SLURM_VERSION}" \
      sind.slurm.commit="${SLURM_COMMIT}"
