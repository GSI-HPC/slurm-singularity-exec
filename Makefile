singularity-exec.so: main.cpp
	$(CXX) -std=c++2a -O2 -Wall -Wextra -fpic -shared -o $@ $<

install: singularity-exec.so singularity-exec.conf
	install slurm-singularity-wrapper.sh /usr/lib/slurm/
	install singularity-exec.so          /usr/lib/slurm/
	install singularity-exec.conf        /etc/slurm/plugstack.conf.d/

install-scp: singularity-exec.so singularity-exec.conf
	scp slurm-singularity-wrapper.sh slurm-test:/usr/lib/slurm/
	scp singularity-exec.so          slurm-test:/usr/lib/slurm/
	scp singularity-exec.conf        slurm-test:/etc/slurm/plugstack.conf.d/

help:
	@echo "... all"
	@echo "... install"
	@echo "... install-scp"

clean:
	rm -f singularity-exec.so
