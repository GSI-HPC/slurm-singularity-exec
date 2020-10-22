libdir=/usr/lib/slurm
etcdir=/etc/slurm
scphost=slurm-test

all: singularity-exec.so

test:
	echo $(libdir) $(etcdir)

singularity-exec.so: main.cpp Makefile
	$(CXX) -std=c++17 -O2 -Wall -Wextra -fpic -shared -static-libstdc++ -static-libgcc -o $@ $<

prepare-plugstack-conf:
	mkdir -p $(etcdir)/plugstack.conf.d
	grep -q '^\s*include\s\+$(etcdir)/plugstack.conf.d/*.conf' || \
	  echo 'include $(etcdir)/plugstack.conf.d/*.conf' >> $(etcdir)/plugstack.conf

install: singularity-exec.so singularity-exec.conf prepare-plugstack-conf
	install slurm-singularity-wrapper.sh $(libdir)/
	install singularity-exec.so          $(libdir)/
	install singularity-exec.conf        $(etcdir)/plugstack.conf.d/

install-scp: singularity-exec.so singularity-exec.conf
	scp slurm-singularity-wrapper.sh $(scphost):$(libdir)/
	scp singularity-exec.so          $(scphost):$(libdir)/
	scp singularity-exec.conf        $(scphost):$(etcdir)/plugstack.conf.d/

help:
	@echo "... all"
	@echo "... install"
	@echo "... install-scp"

clean:
	rm -f singularity-exec.so

.PHONY: help clean prepare-plugstack-conf
