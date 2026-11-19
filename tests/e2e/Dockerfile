# syntax=docker/dockerfile:1
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Node image of the end-to-end tests: the sind node image with the plugin
# of this source tree. The build context is the root of the repository:
#
#   mise run e2e:image

ARG NODE_IMAGE=ghcr.io/gsi-hpc/slurm-runtime-apptainer/sind-node:26.11

FROM ${NODE_IMAGE}

COPY meson.build meson.options /usr/src/slurm-runtime-apptainer/
COPY etc /usr/src/slurm-runtime-apptainer/etc
COPY src /usr/src/slurm-runtime-apptainer/src
COPY tests/unit /usr/src/slurm-runtime-apptainer/tests/unit

# The plugin compiles against the headers of the Slurm in the image, and
# goes into the plugin directory of that Slurm.
RUN meson setup /tmp/build /usr/src/slurm-runtime-apptainer \
        --prefix=/usr \
        --libdir=lib64 \
        -Dplugin=enabled \
        -Dslurm_source=/usr/src/slurm && \
    meson test -C /tmp/build --print-errorlogs && \
    meson install -C /tmp/build && \
    rm -rf /tmp/build && \
    test -e /usr/lib64/slurm/runtime_apptainer.so

# A PMIx client for the MPI tests, see tests/e2e/70-mpi.bats.
COPY tests/e2e/fixtures/pmix_client.c /tmp/pmix_client.c
RUN gcc -Wall -Werror -O2 -o /usr/libexec/e2e-pmix-client /tmp/pmix_client.c -lpmix && \
    rm /tmp/pmix_client.c
