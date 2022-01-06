libdir=/usr/lib$(shell uname -m | grep -q x86_64 && echo 64)/slurm
libexec=/usr/libexec
etcdir=/etc/slurm
incdir=/usr/include/slurm

all: singularity-exec.so

test:
	echo $(libdir) $(libexec) $(etcdir)

singularity-exec.so: main.cpp Makefile
	$(CXX) -std=c++17 -O2 -Wall -Wextra -fpic -shared -static-libstdc++ -static-libgcc -I$(incdir) -o $@ $<

prepare-plugstack-conf:
	mkdir -p $(etcdir)/plugstack.conf.d
	test -f $(etcdir)/plugstack.conf || \
	  echo 'include $(etcdir)/plugstack.conf.d/*.conf' > $(etcdir)/plugstack.conf

singularity-exec-conf: prepare-plugstack-conf
	echo 'required $(libdir)/singularity-exec.so default= script=$(libexec)/slurm-singularity-wrapper.sh bind=/etc/slurm,/var/run/munge,/var/spool/slurm args=""' > $(etcdir)/plugstack.conf.d/singularity-exec.conf

install: singularity-exec.so prepare-plugstack-conf singularity-exec-conf
	install singularity-exec.so          $(libdir)/
	install slurm-singularity-wrapper.sh $(libexec)/

help:
	@echo "... all"
	@echo "... install"

clean:
	rm -f singularity-exec.so

.PHONY: help clean prepare-plugstack-conf singularity-exec-conf
