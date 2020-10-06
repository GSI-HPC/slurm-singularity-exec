singularity-exec.so: main.cpp
	$(CXX) -std=c++2a -O2 -Wall -Wextra -fpic -shared -o $@ $<

install: singularity-exec.so singularity-exec.conf
	scp slurm-singularity-wrapper.sh slurm-test:/usr/lib/slurm/
	scp singularity-exec.so          slurm-test:/usr/lib/slurm/
	scp singularity-exec.conf        slurm-test:/etc/slurm/plugstack.conf.d/
