#!/usr/bin/env bash

cd /tmp

cat > debian10.def <<EOF
Bootstrap: docker
From: debian:10
%post
  apt update -y
  apt install -y zsh openssh-client openssh-sftp-server procps rsync
  # make this compatible to the host configuration on CentOS 7
  mkdir -p /usr/libexec/openssh
  ln -s /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server
EOF

test -f debian10.sif \
        || singularity build --fakeroot debian10.sif debian10.def

cat > centos7.def <<EOF
Bootstrap: docker
From: centos:7
%post
  yum install -y zsh openssh-clients openssh-server procps-ng rsync
EOF

test -f centos7.sif \
        || singularity build --fakeroot centos7.sif centos7.def

cat > centos_stream8.def <<EOF
Bootstrap: docker
From: quay.io/centos/centos:stream8
%post
  dnf install -y zsh openssh-clients openssh-server procps-ng rsync
EOF

test -f centos_stream8.sif \
        || singularity build --fakeroot centos_stream8.sif centos_stream8.def

cd - >/dev/null
